#frontend unpacker

import re
from datetime import time

TYPE = "S"

class UnpackError(ValueError):
    """The message is corrupted, or isn't a storm message we understand."""


_MESSAGE = re.compile(
    r"NB1 (?P<type>\S) (?P<town>\S+) "
    r"W(?P<warning>[0-5]) R(?P<rain>[0-4]) "
    r"G(?P<gusts>\d{1,3}) T(?P<hour>\d{2})(?P<minute>\d{2})$"
)


def unpack_storm(message):
    """Reverse of pack_storm. Returns a dict of the fields, or raises UnpackError."""
    message = message.strip()

    body, sep, tail = message.rpartition(" K")
    if not sep or not re.fullmatch(r"\d{4}", tail):
        raise UnpackError("missing or malformed checksum")

    try:
        expected = sum(body.encode("ascii")) % 10000
    except UnicodeEncodeError as e:
        raise UnpackError("message contains non-ASCII characters") from e
    if expected != int(tail):
        raise UnpackError("checksum mismatch, the message was corrupted")

    m = _MESSAGE.match(body)
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

    return {
        "town_code": m["town"],
        "warning_level": int(m["warning"]),
        "rain": int(m["rain"]),
        "gusts_kph": gusts,
        "issued_time": issued,
    }


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
    town = (town_names or {}).get(fields["town_code"], fields["town_code"])
    level = fields["warning_level"]
    signal = f"Wind Signal No. {level}" if level else "No wind signal"
    return (
        f"{town}: {signal}. {RAIN_TEXT[fields['rain']]}. "
        f"Gusts up to {fields['gusts_kph']} km/h. "
        f"Issued {fields['issued_time']:%I:%M %p}."
    )