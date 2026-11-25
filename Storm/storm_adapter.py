import json
from pathlib import Path
import subprocess
import re
from datetime import datetime
import shutil

from .pack_storm import PackError, pack_storm
from .local_wind import local_impact, WindModelError
from .rain import rain_level

current = Path(__file__).resolve().parent
base_dir = current.parent


def main():
    data = load_bulletin()
    print(data)
    print(TOWNS)

class BulletinError(ValueError):
    """The bulletin is missing something we need, or it isn't in the shape we expect."""


def load_towns():
    path_to_town = base_dir / "Data" / "towns.json"
    try:
        with open(path_to_town, "r", encoding="utf-8") as f:
            towns = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise BulletinError(f"Could not read town data {path_to_town}: {e}") from e
    return {town["code"]: town for town in towns}


TOWNS = load_towns()


def load_bulletin(path=None):
    if path is not None:
        # A specific file was given: just read it, no polling
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            raise BulletinError(f"Could not read bulletin {path}: {e}")

    path_to_json = base_dir / "pagasa_parser" / "output" / "bulletin.json"
    bat_path = base_dir / "pagasa_parser" / "poll.bat"

    if path_to_json.is_file():
        print("DATA ALREADY EXISTS")
    else:
        try:
            subprocess.run([str(bat_path)], check=True, cwd=bat_path.parent)
            print("DATA POLLED")
        except (subprocess.CalledProcessError, OSError) as e:
            print(f"COULD NOT POLL ({e}), TRYING ARCHIVE")
            load_from_archive(base_dir)

    with open(path_to_json, "r", encoding="utf-8") as f:
        return json.load(f)


def load_from_archive(base_dir):
    """No active storm: download past bulletins with pagasa-archiver and parse the newest one."""
    parser_dir = base_dir / "pagasa_parser"
    archive_dir = parser_dir / "archive"
    archive_dir.mkdir(exist_ok=True)

    npx = shutil.which("npx")
    if npx is None:
        raise BulletinError("npx not found, is Node installed?")

    try:
        subprocess.run([npx, "--yes", "pagasa-archiver"], check=True, cwd=archive_dir)

        pdfs = sorted(archive_dir.glob("*_TCB#*.pdf"))   # TCBs only, skip advisories
        if not pdfs:
            raise BulletinError("the archive had no bulletins to use")

        subprocess.run(["node", "index.js", str(pdfs[-1])], check=True, cwd=parser_dir)
    except (subprocess.CalledProcessError, OSError) as e:
        raise BulletinError(f"could not load from the archive: {e}") from e
    print("DATA FROM ARCHIVE")


def issued_at(bulletin):
    """'5:00 PM, 09 November 2026' -> datetime(2026, 11, 9, 17, 0) (Philippine local time)."""
    text = bulletin.get("issued")
    try:
        return datetime.strptime(str(text).strip(), "%I:%M %p, %d %B %Y")
    except ValueError as e:
        raise BulletinError(f"cannot read the issue time from {text!r}") from e


def warning_level(bulletin):
    """'0' when no wind signal is hoisted, otherwise the highest signal number (1-5) in the signal text."""
    signals = bulletin.get("windSignals") or {}
    if signals.get("noneHoisted"):
        return "0"
    levels = re.findall(r"(?:TCWS|wind\s+signals?)\s*(?:no\.?|number|#)?\s*([1-5])", signals.get("rawText") or "", re.I)
    if not levels:
        raise BulletinError("wind signals may be in effect, but the signal level could not be read from the bulletin")
    return str(max(int(n) for n in levels))


def gusts_kph(bulletin):
    g = (bulletin.get("intensity") or {}).get("gustsKph")
    if g is None:
        raise BulletinError("the bulletin has no gust speed")
    return int(round(g))


def storm_reply(code, bulletin, rain=None):
    try:
        town = TOWNS[code]
    except KeyError as e:
        raise PackError(f"unknown town code {code!r}") from e

    try:
        impact = local_impact(bulletin, town["lat"], town["lon"])
        signal = str(impact.signal)
        gusts = impact.gusts_kph
    except WindModelError:
        signal = warning_level(bulletin)
        gusts = gusts_kph(bulletin)

    if rain is None:
        rain = rain_level(town["lat"], town["lon"])

    return pack_storm(code, issued_at(bulletin), signal, rain, gusts)


if __name__ == "__main__":
    main()