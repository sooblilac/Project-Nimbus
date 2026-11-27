"""PAGASA parser JSON -> Nimbus API -> SMS relay."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PARSER = ROOT / "pagasa_parser"
sys.path.insert(0, str(ROOT))

from Storm.local_wind import WindModelError, local_impact
from Storm.rain import rain_levels
from Storm.pack_storm import PackError, pack_storm


# Cloudflare rejects the default Python-urllib user agent with 403.
USER_AGENT = "ProjectNimbus-Sync/1.0"


def post_json(url: str, body: dict | None = None, token: str | None = None, method: str = "POST"):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def login(api_url: str) -> str:
    result = post_json(
        f"{api_url}/auth/login",
        {"username": os.getenv("NIMBUS_LGU_USERNAME", "demo"), "password": os.getenv("NIMBUS_LGU_PASSWORD", "nimbusdemo26")},
    )
    token = result.get("accessToken")
    if not token:
        raise RuntimeError("LGU login did not return an access token")
    return token


def fetch_live_bulletin(pdf: str | None = None) -> dict:
    """Parse the latest live PAGASA PDF (or a saved one). Return {} when none is available."""
    command = ["node", "index.js", str(Path(pdf).resolve())] if pdf else ["npm", "start"]
    result = subprocess.run(command, cwd=PARSER, capture_output=True, text=True)
    if result.returncode != 0:
        return {}
    path = PARSER / "output" / "bulletin.json"
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def bulletin_is_active(bulletin: dict) -> bool:
    if not bulletin:
        return False
    position = bulletin.get("currentPosition") or {}
    headline = str(bulletin.get("headline") or "").lower()
    if position.get("outsidePAR"):
        return False
    if "has exited the philippine area of responsibility" in headline:
        return False
    if bulletin.get("isFinal") and (bulletin.get("windSignals") or {}).get("noneHoisted"):
        return False
    return bool(bulletin.get("name") or bulletin.get("category"))


def bulletin_notice(bulletin: dict) -> str:
    name = str(bulletin.get("name") or "Storm").strip()
    category = str(bulletin.get("category") or "Weather disturbance").strip()
    headline = str(bulletin.get("headline") or "").strip()
    return f"PAGASA {category} {name}. {headline}".strip()[:500]


def pagasa_title(bulletin: dict) -> str:
    """Short storm line for SMS, e.g. 'Typhoon FRANCISCO #12, moving W Northwestward at 25 km/h'."""
    name = str(bulletin.get("name") or "Storm").strip().upper()
    category = str(bulletin.get("category") or "Tropical cyclone").strip()
    number = str(bulletin.get("bulletinNumber") or "").strip()
    title = f"{category} {name}" + (f" #{number}" if number else "")
    movement = bulletin.get("movement") or {}
    heading = compass(str(movement.get("text") or ""))
    speed = movement.get("speedKph")
    if heading:
        title += f", {heading}" + (f" {speed} km/h" if speed else "")
    return title


def compass(text: str) -> str:
    """'West Northwestward at 25 km/h' -> 'WNW'; '' when there is no heading."""
    words = text.split(" at ")[0].lower().replace("ward", "").split()
    short = {"north": "N", "south": "S", "east": "E", "west": "W", "northeast": "NE",
             "northwest": "NW", "southeast": "SE", "southwest": "SW"}
    letters = "".join(short.get(w, "") for w in words)
    if letters:
        return letters
    return "stationary" if "stationary" in text.lower() else ""


# What PAGASA's Tropical Cyclone Wind Signals mean for a household (wind range, lead
# time, action). Short enough to fit an SMS next to the storm line.
SIGNAL_ADVICE = {
    1: "39-61 km/h winds in 36h. Secure loose items, charge phones.",
    2: "62-88 km/h winds in 24h. Stay indoors, ready go-bag, expect power cuts.",
    3: "89-117 km/h winds in 18h. Evacuate weak houses and flood/landslide areas.",
    4: "118-184 km/h winds in 12h. Evacuate now to a sturdy shelter.",
    5: "185+ km/h winds in 12h. Extreme threat to life. Stay sheltered.",
}


def pagasa_advice(signal: int, rain: int, gusts: int) -> str:
    """Plain-language interpretation of the town's signal, rain and gusts."""
    parts = []
    if signal in SIGNAL_ADVICE:
        parts.append(SIGNAL_ADVICE[signal])
    elif gusts >= 39:
        parts.append(f"No signal here; gusts to {gusts} km/h. Monitor updates.")
    else:
        parts.append("No wind signal here. Monitor updates.")
    if rain >= 3:
        parts.append("Heavy rain: watch for floods, landslides.")
    elif rain == 2:
        parts.append("Moderate rain: avoid low areas.")
    return " ".join(parts)


LOCATIONS = ROOT / "nimbus-v3" / "flutter_app" / "assets" / "data" / "philippine_locations.json"

# Fields this script owns. Everything else in a town update (classes, notice,
# flood areas, evacuation centers, roads, map pins) belongs to the LGU and is
# carried over untouched, because the API replaces the whole update on POST.
PAGASA_FIELDS = (
    "signal",
    "rain",
    "gusts",
    "pagasaActive",
    "pagasaNotice",
    "pagasaName",
    "pagasaBulletin",
    "issuedAt",
    "pagasaTitle",
    "pagasaAdvice",
)
LGU_DEFAULTS = {
    "classes": 0,
    "notice": "",
    "floodAreas": [],
    "evacuationCenters": [],
    "roadStatuses": [],
    "mapPins": [],
}


def get_json(url: str):
    request = urllib.request.Request(
        url, headers={"Accept": "application/json", "User-Agent": USER_AGENT}
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def town_list():
    """Every city/municipality in the app's catalog, with the codes residents
    use: the PSGC ID, plus the legacy four-digit ID where one exists."""
    output = []
    for item in json.loads(LOCATIONS.read_text(encoding="utf-8")):
        codes = [item["code"]]
        if item.get("legacyCode"):
            codes.append(item["legacyCode"])
        output.append((item["latitude"], item["longitude"], codes))
    return output


def pagasa_fields(bulletin: dict, active: bool, lat: float, lon: float, rain: int | None) -> dict:
    if not active:
        return {
            "signal": 0,
            "rain": 0,
            "gusts": 0,
            "pagasaActive": False,
            "pagasaNotice": "No current storm update administered by PAGASA.",
            "pagasaName": "",
            "pagasaBulletin": "",
            "issuedAt": "",
            "pagasaTitle": "",
            "pagasaAdvice": "",
        }
    try:
        impact = local_impact(bulletin, lat, lon)
        signal = int(impact.signal)
        gusts = int(impact.gusts_kph)
    except WindModelError:
        signal = 0
        gusts = int((bulletin.get("intensity") or {}).get("gustsKph") or 0)
    return {
        "signal": signal,
        "rain": rain or 0,
        "gusts": gusts,
        "pagasaActive": True,
        "pagasaNotice": bulletin_notice(bulletin),
        "pagasaName": str(bulletin.get("name") or ""),
        "pagasaBulletin": str(bulletin.get("bulletinNumber") or ""),
        "issuedAt": str(bulletin.get("issued") or ""),
        "pagasaTitle": pagasa_title(bulletin),
        "pagasaAdvice": pagasa_advice(signal, rain or 0, gusts),
    }


def render_pages(pdf: str, out_dir: str) -> list[Path]:
    """Bulletin pages as ~1200px JPEGs: pdftoppm (Linux/CI) or PDFKit + sips (macOS)."""
    out = Path(out_dir)
    if shutil.which("pdftoppm"):
        subprocess.run(["pdftoppm", "-jpeg", "-jpegopt", "quality=60", "-scale-to", "1200",
                        pdf, str(out / "p")], check=True, capture_output=True)
    elif shutil.which("swift") and shutil.which("sips"):
        subprocess.run(["swift", str(PARSER / "render_pages.swift"), pdf, str(out)],
                       check=True, capture_output=True)
        for page in out.glob("*.jpg"):
            subprocess.run(["sips", "-Z", "1200", "-s", "formatOptions", "60", str(page)],
                           check=True, capture_output=True)
    else:
        return []
    def number(path: Path) -> int:
        return int("".join(ch for ch in path.stem if ch.isdigit()) or 0)
    return sorted(out.glob("*.jpg"), key=number)


def upload_pages(api_url: str, pdf: str, token: str) -> int:
    """Store the bulletin's page images with the drill so the app can show the source."""
    with tempfile.TemporaryDirectory() as tmp:
        try:
            pages = render_pages(str(Path(pdf).resolve()), tmp)
        except subprocess.CalledProcessError as error:
            print(f"Could not render bulletin pages: {error}", file=sys.stderr)
            return 0
        for n, page in enumerate(pages, 1):
            request = urllib.request.Request(
                f"{api_url}/drill/pages/{n}", data=page.read_bytes(), method="POST",
                headers={"Content-Type": "image/jpeg", "User-Agent": USER_AGENT,
                         "Authorization": f"Bearer {token}"})
            urllib.request.urlopen(request, timeout=60).read()
        return len(pages)


def run_drill(api_url: str, pdf: str | None) -> None:
    """Replay a saved bulletin as a storm drill, kept apart from live town data.

    Residents only see it when their app is in Storm drill mode; replies are marked DRILL.
    """
    token = login(api_url)
    if pdf is None:
        post_json(f"{api_url}/drill", None, token, method="DELETE")
        print("Storm drill ended.")
        return
    bulletin = fetch_live_bulletin(pdf)
    if not bulletin:
        raise SystemExit(f"Could not parse {pdf}")
    active = bulletin_is_active(bulletin)
    towns = town_list()
    rains = rain_levels([(lat, lon) for lat, lon, _ in towns]) if active else [0] * len(towns)
    affected = {}
    for (lat, lon, codes), rain in zip(towns, rains):
        fields = pagasa_fields(bulletin, active, lat, lon, rain)
        if fields["signal"] or fields["rain"] >= 2:
            for code in codes:
                affected[code] = fields
    state = {
        "source": Path(pdf).name,
        "title": pagasa_title(bulletin),
        "issued": str(bulletin.get("issued") or ""),
        "headline": str(bulletin.get("headline") or "")[:300],
        "default": pagasa_fields(bulletin, active, 0, 0, 0) | {"signal": 0, "gusts": 0, "rain": 0,
                                                              "pagasaAdvice": pagasa_advice(0, 0, 0)},
        "towns": affected,
    }
    post_json(f"{api_url}/drill", state, token)
    pages = upload_pages(api_url, pdf, token)
    by_signal = {}
    for f in affected.values():
        by_signal[f["signal"]] = by_signal.get(f["signal"], 0) + 1
    print(f"Storm drill started: {state['title']} ({state['issued']}); "
          f"towns by signal {dict(sorted(by_signal.items()))}; {pages} bulletin page(s) attached")


def main() -> None:
    api_url = os.getenv(
        "NIMBUS_API_URL", "https://nimbus-worker.gozocharlyz.workers.dev/api"
    ).rstrip("/")
    if "--drill-off" in sys.argv:
        return run_drill(api_url, None)
    if "--drill" in sys.argv:
        return run_drill(api_url, sys.argv[sys.argv.index("--drill") + 1])
    bulletin = fetch_live_bulletin()
    active = bulletin_is_active(bulletin)
    towns = town_list()

    # One request for every town's current update, so LGU data can be kept.
    current = {
        row["townCode"]: row.get("update") or {}
        for row in get_json(f"{api_url}/towns").get("towns", [])
    }

    # Rain only matters during an active storm; batch it to spare Open-Meteo.
    rains = rain_levels([(lat, lon) for lat, lon, _ in towns]) if active else [0] * len(towns)

    token = None
    published = skipped = failed = 0
    for (lat, lon, codes), rain in zip(towns, rains):
        fields = pagasa_fields(bulletin, active, lat, lon, rain)
        for code in codes:
            existing = current.get(code, {})
            if all(existing.get(key) == value for key, value in fields.items()):
                skipped += 1
                continue
            body = {key: existing.get(key, default) for key, default in LGU_DEFAULTS.items()}
            body.update(
                {
                    key: value
                    for key, value in existing.items()
                    if key not in ("townCode", "updatedAt")
                }
            )
            body.update(fields)
            if token is None:
                token = login(api_url)
            try:
                post_json(f"{api_url}/towns/{code}/updates", body, token)
                published += 1
            except OSError as error:
                failed += 1
                print(f"Could not publish {code}: {error}", file=sys.stderr)

    print(
        f"PAGASA sync: active={active}, towns={len(towns)}, "
        f"published={published}, unchanged={skipped}, failed={failed}"
    )


if __name__ == "__main__":
    main()
