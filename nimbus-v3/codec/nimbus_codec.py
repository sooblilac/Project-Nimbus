"""Nimbus SMS format NB1 for the Python backend. Mirrors nimbus-codec.js line for line.

    NB1 <type> <town> <field> ... T<hhmm> [/<notice>] K<signature>
    NB1~P~<town>~<pin>...~T<hhmm>~K<signature> for multipart-safe pin snapshots

K is the first 4 bytes (8 hex digits) of HMAC-SHA256(key, body), where body is
everything before " K" / "~K". The key comes from NIMBUS_SMS_SIGNING_KEY (or
set_signing_key). Encoding without a key raises; decoding without a key marks
every reply invalid.
Run `python3 nimbus_codec.py` to check against test_vectors.json (signed with
TEST_VECTOR_KEY).
"""
from __future__ import annotations

import hashlib
import hmac
import os
import re
from dataclasses import dataclass, field
from typing import Optional

VERSION = "NB1"
MAX_SMS = 160


SIGNATURE_HEX = 8
TEST_VECTOR_KEY = "nimbus-test-vectors-key"  # public; only for test_vectors.json
_signing_key: Optional[str] = os.environ.get("NIMBUS_SMS_SIGNING_KEY") or None


def set_signing_key(key: Optional[str]) -> None:
    global _signing_key
    _signing_key = key or None


def signature(text: str, key: Optional[str] = None) -> str:
    """First 4 bytes of HMAC-SHA256(key, text) as 8 upper-case hex digits."""
    key = key or _signing_key
    if not key:
        raise RuntimeError("NIMBUS_SMS_SIGNING_KEY is not set; cannot sign NIMBUS SMS.")
    digest = hmac.new(key.encode("utf-8"), text.encode("utf-8"), hashlib.sha256).digest()
    return digest[: SIGNATURE_HEX // 2].hex().upper()


def _signature_valid(body: str, given: str) -> bool:
    if not _signing_key or len(given) != SIGNATURE_HEX:
        return False
    return hmac.compare_digest(signature(body), given.upper())


def clean_notice(text: str) -> str:
    """Keeps a notice in the plain SMS character set so one reply stays one SMS."""
    text = re.sub("[‘’]", "'", text)
    text = re.sub("[“”]", '"', text)
    text = re.sub("[–—]", "-", text)
    text = re.sub(r"[^\x20-\x7E]", "", text)
    return re.sub(r"\s+", " ", text).strip()


def encode(type_: str, town_code: str, fields: list[str], time: str, notice: str = "") -> str:
    body = " ".join([VERSION, type_, town_code, *fields, "T" + time])
    if notice:
        body += " /" + notice
    return body + " K" + signature(body)


@dataclass
class MapPin:
    category: str
    label: str
    latitude: float
    longitude: float
    status: str
    intensity: int


def encode_pins(town_code: str, pins: list[MapPin], time: str) -> str:
    category_codes = {"flood": "F", "evacuation": "E", "road": "R"}
    status_codes = {"F": {"F", "W", "C"}, "E": {"O", "F", "X"}, "R": {"O", "L", "X"}}
    fields = []
    for pin in pins:
        category = category_codes.get(pin.category)
        if (
            category is None
            or pin.status not in status_codes[category]
            or not 0 <= pin.intensity <= 100
            or not -90 <= pin.latitude <= 90
            or not -180 <= pin.longitude <= 180
        ):
            raise ValueError(f"Invalid map pin: {pin.label}")
        label = re.sub(r"\s+", "_", clean_notice(pin.label).replace("|", " "))
        if not label:
            raise ValueError("Map pin labels cannot be empty")

        def coord(value: float) -> int:
            scaled = abs(value) * 100000
            rounded = int(scaled + 0.5)
            return -rounded if value < 0 else rounded

        fields.append(
            f"{category}|{pin.status}|{pin.intensity}|"
            f"{coord(pin.latitude)}|{coord(pin.longitude)}|{label}"
        )
    body = "~".join([VERSION, "P", town_code, *fields, "T" + time])
    return body + "~K" + signature(body)


@dataclass
class Storm:
    warning: str
    rain: int
    gusts: int
    evac_site: int
    evac_status: str
    classes: int


@dataclass
class Item:
    index: int
    level: Optional[str] = None
    now: Optional[str] = None
    status: Optional[str] = None
    percent_full: Optional[int] = None
    custom_name: Optional[str] = None


@dataclass
class Reply:
    version: str
    type: str
    town_code: str
    time: str
    notice: str
    valid: bool
    storm: Optional[Storm] = None
    items: list[Item] = field(default_factory=list)
    pins: list[MapPin] = field(default_factory=list)


_FLOOD = re.compile(r"^A(\d+)([HML])([FWC])(?::(\S+))?$")
_EVAC = re.compile(r"^S(\d+)([OFX])(\d+)$")
_ROAD = re.compile(r"^R(\d+)([OLX])(?::(\S+))?$")
_PIN = re.compile(r"^([FER])\|([A-Z])\|(\d{1,3})\|(-?\d{1,8})\|(-?\d{1,9})\|([A-Za-z0-9_.'-]+)$")


def _parse_field(type_: str, part: str) -> Optional[Item]:
    if type_ == "F" and (m := _FLOOD.match(part)):
        return Item(int(m[1]), level=m[2], now=m[3], custom_name=m[4].replace("_", " ") if m[4] else None)
    if type_ == "E" and (m := _EVAC.match(part)):
        return Item(int(m[1]), status=m[2], percent_full=int(m[3]))
    if type_ == "R" and (m := _ROAD.match(part)):
        return Item(int(m[1]), status=m[2], custom_name=m[3].replace("_", " ") if m[3] else None)
    return None


def _parse_pin(part: str) -> Optional[MapPin]:
    match = _PIN.fullmatch(part)
    if not match:
        return None
    category_code, status = match[1], match[2]
    intensity, latitude, longitude = int(match[3]), int(match[4]), int(match[5])
    valid_status = {
        "F": {"F", "W", "C"},
        "E": {"O", "F", "X"},
        "R": {"O", "L", "X"},
    }[category_code]
    if (
        status not in valid_status
        or intensity > 100
        or abs(latitude) > 9000000
        or abs(longitude) > 18000000
    ):
        return None
    category = {"F": "flood", "E": "evacuation", "R": "road"}[category_code]
    return MapPin(
        category,
        match[6].replace("_", " "),
        latitude / 100000,
        longitude / 100000,
        status,
        intensity,
    )


def decode(sms: str) -> Optional[Reply]:
    """Returns None for anything that isn't an NB1 reply."""
    compact_pins = sms.startswith(VERSION + "~P~")
    marker = "~K" if compact_pins else " K"
    k = sms.rfind(marker)
    if k < 0 or not sms.startswith(VERSION + ("~" if compact_pins else " ")):
        return None
    body = sms[:k]
    n = body.find(" /")
    parts = (body[:n] if n >= 0 else body).split("~" if compact_pins else " ")
    if len(parts) < 4:
        return None
    type_, items, time_part = parts[1], parts[3:-1], parts[-1]
    if not re.fullmatch(r"T\d{4}", time_part):
        return None
    reply = Reply(parts[0], type_, parts[2], time_part[1:], body[n + 2:] if n >= 0 else "",
                  _signature_valid(body, sms[k + len(marker):]))
    if type_ == "Q":
        f = {p[0]: p[1:] for p in items}
        e = re.match(r"^(\d+)([OFX]?)$", f.get("E", "0"))
        reply.storm = Storm(f.get("W", ""), int(f.get("R", 0)), int(f.get("G", 0)),
                            int(e[1]) if e else 0, e[2] if e else "", int(f.get("C", 0)))
    elif type_ == "P":
        for part in items:
            pin = _parse_pin(part)
            if pin is None:
                return None
            reply.pins.append(pin)
    else:
        for part in items:
            item = _parse_field(type_, part)
            if item is None:
                return None
            reply.items.append(item)
    return reply


if __name__ == "__main__":
    import json
    import pathlib

    set_signing_key(TEST_VECTOR_KEY)
    vectors = json.loads((pathlib.Path(__file__).parent / "test_vectors.json").read_text())
    for v in vectors:
        if "tampered" in v:
            assert decode(v["tampered"]).valid is False
            continue
        if v["type"] == "P":
            pins = [MapPin(**pin) for pin in v["pins"]]
            sms = encode_pins(v["town"], pins, v["time"])
        else:
            sms = encode(v["type"], v["town"], v["fields"], v["time"], v["notice"])
        assert sms == v["sms"], (sms, v["sms"])
        reply = decode(sms)
        assert reply.valid and reply.type == v["type"] and reply.notice == v["notice"]
        assert len(reply.items) == len(v["decoded"]["items"])
        assert len(reply.pins) == len(v["decoded"].get("pins", []))
    print(f"{len(vectors)} vectors passed")
