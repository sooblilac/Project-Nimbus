"""PAGASA parser JSON -> Nimbus API -> SMS relay."""

from __future__ import annotations

import json
import os
import subprocess
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


def post_json(url: str, body: dict | None = None, token: str | None = None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")
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


def fetch_live_bulletin() -> dict:
    """Fetch the latest live PAGASA PDF and parse it. Return {} when none is available."""
    result = subprocess.run(["npm", "start"], cwd=PARSER, capture_output=True, text=True)
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
    }


def main() -> None:
    api_url = os.getenv(
        "NIMBUS_API_URL", "https://nimbus-worker.gozocharlyz.workers.dev/api"
    ).rstrip("/")
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
