"""Nimbus SMS format NB1 for the Python backend. Mirrors nimbus-codec.js line for line.

    NB1 <type> <town> <field> ... T<hhmm> [/<notice>] K<signature>

The K signature is a demo checksum. A real gateway signs with HMAC-SHA256.
Run `python3 nimbus_codec.py` to check against test_vectors.json.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

VERSION = "NB1"
MAX_SMS = 160


def signature(text: str) -> str:
    """h = h * 31 + char code, kept to 32 bits; returns the low 16 bits as 4 hex digits."""
    h = 0
    for ch in text:
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    return f"{h & 0xFFFF:04X}"


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


_FLOOD = re.compile(r"^A(\d+)([HML])([FWC])(?::(\S+))?$")
_EVAC = re.compile(r"^S(\d+)([OFX])(\d+)$")
_ROAD = re.compile(r"^R(\d+)([OLX])(?::(\S+))?$")


def _parse_field(type_: str, part: str) -> Optional[Item]:
    if type_ == "F" and (m := _FLOOD.match(part)):
        return Item(int(m[1]), level=m[2], now=m[3], custom_name=m[4].replace("_", " ") if m[4] else None)
    if type_ == "E" and (m := _EVAC.match(part)):
        return Item(int(m[1]), status=m[2], percent_full=int(m[3]))
    if type_ == "R" and (m := _ROAD.match(part)):
        return Item(int(m[1]), status=m[2], custom_name=m[3].replace("_", " ") if m[3] else None)
    return None


def decode(sms: str) -> Optional[Reply]:
    """Returns None for anything that isn't an NB1 reply."""
    k = sms.rfind(" K")
    if k < 0 or not sms.startswith(VERSION + " "):
        return None
    body = sms[:k]
    n = body.find(" /")
    parts = (body[:n] if n >= 0 else body).split(" ")
    if len(parts) < 4:
        return None
    type_, items, time_part = parts[1], parts[3:-1], parts[-1]
    if not re.fullmatch(r"T\d{4}", time_part):
        return None
    reply = Reply(parts[0], type_, parts[2], time_part[1:], body[n + 2:] if n >= 0 else "",
                  signature(body) == sms[k + 2:])
    if type_ == "Q":
        f = {p[0]: p[1:] for p in items}
        e = re.match(r"^(\d+)([OFX]?)$", f.get("E", "0"))
        reply.storm = Storm(f.get("W", ""), int(f.get("R", 0)), int(f.get("G", 0)),
                            int(e[1]) if e else 0, e[2] if e else "", int(f.get("C", 0)))
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

    vectors = json.loads((pathlib.Path(__file__).parent / "test_vectors.json").read_text())
    for v in vectors:
        if "tampered" in v:
            assert decode(v["tampered"]).valid is False
            continue
        sms = encode(v["type"], v["town"], v["fields"], v["time"], v["notice"])
        assert sms == v["sms"], (sms, v["sms"])
        reply = decode(sms)
        assert reply.valid and reply.type == v["type"] and reply.notice == v["notice"]
        assert len(reply.items) == len(v["decoded"]["items"])
    print(f"{len(vectors)} vectors passed")
