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
from Storm.rain import RainError, rain_level
from Storm.pack_storm import PackError, pack_storm


def post_json(url: str, body: dict | None = None, token: str | None = None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Accept": "application/json"}
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


def town_list():
    towns = json.loads((ROOT / "Data" / "towns.json").read_text(encoding="utf-8"))
    demo = {
        "0412": ("Batangas City", "0401005000"),
        "0517": ("Naga City", "0501724000"),
        "0837": ("Tacloban City", "0831600000"),
        "1374": ("Marikina City", "1380700000"),
    }
    output = []
    for legacy, (name, psgc) in demo.items():
        town = next((item for item in towns if item["name"] == name), None)
        if town:
            output.append((town, legacy, psgc))
    return output


def main() -> None:
    api_url = os.getenv("NIMBUS_API_URL", "http://127.0.0.1:8080/api").rstrip("/")
    bulletin = fetch_live_bulletin()
    active = bulletin_is_active(bulletin)
    token = login(api_url)
    published = 0

    for town, legacy_code, psgc_code in town_list():
        if not active:
            body = {
                "classes": 0,
                "notice": "No current storm update administered by PAGASA.",
                "floodAreas": [],
                "evacuationCenters": [],
                "roadStatuses": [],
                "mapPins": [],
                "rain": 0,
                "gusts": 0,
                "pagasaActive": False,
            }
        else:
            try:
                impact = local_impact(bulletin, town["lat"], town["lon"])
                warning = str(impact.signal)
                gusts = impact.gusts_kph
            except WindModelError:
                warning = "0"
                gusts = int((bulletin.get("intensity") or {}).get("gustsKph") or 0)
            try:
                rain = rain_level(town["lat"], town["lon"])
            except RainError:
                rain = 0

            body = {
                "classes": int(warning),
                "notice": bulletin_notice(bulletin),
                "floodAreas": [],
                "evacuationCenters": [],
                "roadStatuses": [],
                "mapPins": [],
                "rain": rain,
                "gusts": gusts,
                "pagasaActive": True,
                "pagasaName": str(bulletin.get("name") or ""),
                "pagasaBulletin": str(bulletin.get("bulletinNumber") or ""),
                "issuedAt": str(bulletin.get("issued") or ""),
            }

        for api_code in (legacy_code, psgc_code):
            post_json(f"{api_url}/towns/{api_code}/updates", body, token)
            published += 1

    print(f"PAGASA sync: active={active}, published={published}")


if __name__ == "__main__":
    main()
