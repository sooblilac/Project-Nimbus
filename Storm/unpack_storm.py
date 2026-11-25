#frontend unpacker
import json
import re
from datetime import time
from pathlib import Path

TYPE = "S"

class UnpackError(ValueError):
    """The message is corrupted, or isn't a storm message we understand."""


def _load_town_names():
    path = Path(__file__).resolve().parent.parent / "Data" / "towns.json"
    try:
        with path.open("r", encoding="utf-8") as f:
            towns = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise UnpackError(f"Could not read town data {path}: {e}") from e
    return {town["code"]: town["name"] for town in towns}


TOWN_NAMES = _load_town_names()


_MESSAGE = re.compile(
    r"NB1 (?P<type>\S) (?P<town>\S+) "
    r"W(?P<warning>[0-5]) R(?P<rain>[0-4]) "
    r"G(?P<gusts>\d{1,3}) T(?P<hour>\d{2})(?P<minute>\d{2})$"
)


def unpack_storm(message: str) -> str:
    """Unpack a checksum-free storm message into a readable string."""
    m = _MESSAGE.fullmatch(message.strip())
    if not m:
        raise UnpackError("message is not in the expected format")
    if m["type"] != TYPE:
        raise UnpackError(f"not a storm message (type {m['type']!r})")

    try:
        issued = time(int(m["hour"]), int(m["minute"]))
    except ValueError as e:
        raise UnpackError("invalid issue time") from e

    gusts = int(m["gusts"])
    if gusts > 500:
        raise UnpackError("gust speed out of range")

    fields = {
        "town_code": m["town"],
        "warning_level": int(m["warning"]),
        "rain": int(m["rain"]),
        "gusts_kph": gusts,
        "issued_time": issued,
    }
    return describe_storm(fields)

RAIN_TEXT = {
    0: "No significant rain",
    1: "Light rain",
    2: "Moderate rain",
    3: "Heavy rain",
    4: "Intense rain",
}

def describe_storm(fields, town_names=None):
    """Turn unpacked fields into a readable message.
    `town_names` is an optional {code: name} dict for the app."""
    names = TOWN_NAMES if town_names is None else town_names
    town = names.get(fields["town_code"], fields["town_code"])
    level = fields["warning_level"]
    signal = f"Wind Signal No. {level}" if level else "No wind signal"
    return (
        f"{town}: {signal}. {RAIN_TEXT[fields['rain']]}. "
        f"Gusts up to {fields['gusts_kph']} km/h. "
        f"Issued {fields['issued_time']:%I:%M %p}."
    )

if __name__ == "__main__":
    import sys

    try:
        packed = sys.stdin.read()
        print(unpack_storm(packed))
    except UnpackError as exc:
        print(f"Invalid storm message: {exc}", file=sys.stderr)
        raise SystemExit(1)