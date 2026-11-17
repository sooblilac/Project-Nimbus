import json
import re
from datetime import datetime

from pack_storm import pack_storm


class BulletinError(ValueError):
    """The bulletin is missing something we need, or it isn't in the shape we expect."""


def load_bulletin(path):
    # No active storm means no bulletin file, so a missing file is a normal case.
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise BulletinError(f"cannot read the bulletin at {path}: {e}") from e


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


def storm_reply(town_code, bulletin, rain):
    """The storm reply for one town. `rain` is the 0-4 rain level (the bulletin does not provide one)."""
    return pack_storm(town_code, issued_at(bulletin), warning_level(bulletin), rain, gusts_kph(bulletin))