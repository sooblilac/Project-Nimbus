import hashlib
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import urllib.request

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent

if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))
if str(PROJECT_ROOT / "nimbus-v3" / "codec") not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT / "nimbus-v3" / "codec"))

from SMS import send_sms
from nimbus_codec import MapPin, decode, encode, encode_pins

DATA_DIR = PROJECT_ROOT / "Data"

SEEN_DIR = DATA_DIR / ".replied"
COOLDOWN_SECONDS = 300  # 5 minutes; adjust as needed

API_URL = os.getenv("NIMBUS_API_URL", "http://127.0.0.1:8080/api").rstrip("/")

CACHE_DIR = DATA_DIR / "sms_replies"


def _reply_key(payload, msg_text: str, sender: str) -> str:
    # Prefer a gateway message/event ID if present; otherwise hash sender + text
    msg_id = None
    if isinstance(payload, dict):
        box = payload
        for key in ("payload", "data"):
            if isinstance(box.get(key), dict):
                box = box[key]
                break
        msg_id = (
            box.get("id")
            or box.get("messageId")
            or box.get("message_id")
            or box.get("eventId")
            or payload.get("id")
            or payload.get("messageId")
        )

    raw_key = f"id:{msg_id}" if msg_id else f"msg:{sender}:{msg_text}"
    return hashlib.sha256(raw_key.encode("utf-8")).hexdigest()

def _claim_reply_slot(key: str) -> bool:
    """Return True if this message hasn't been replied to within COOLDOWN_SECONDS."""
    SEEN_DIR.mkdir(parents=True, exist_ok=True)
    marker = SEEN_DIR / f"{key}.lock"
    now = time.time()

    if marker.exists():
        age = now - marker.stat().st_mtime
        if age < COOLDOWN_SECONDS:
            return False

    marker.write_text(str(now), encoding="utf-8")
    return True

def extract_sms_fields(payload) -> tuple[str, str | None]:
    """Return (message_text, sender_number) from an incoming SMS payload."""
    if isinstance(payload, str):
        try:
            payload = json.loads(payload)
        except json.JSONDecodeError:
            return payload, None

    if not isinstance(payload, dict):
        return "", None

    box = payload
    for key in ("payload", "data"):
        if isinstance(box.get(key), dict):
            box = box[key]
            break

    msg = (
        box.get("message")
        or box.get("text")
        or box.get("body")
        or payload.get("message")
        or payload.get("text")
        or ""
    )
    if isinstance(msg, dict):
        msg = msg.get("text", "")

    sender = (
        box.get("phoneNumber")
        or box.get("phone_number")
        or box.get("from")
        or box.get("sender")
        or payload.get("phoneNumber")
        or payload.get("from")
    )

    return str(msg), str(sender) if sender else None

def fetch_update(town_code: str):
    with urllib.request.urlopen(f"{API_URL}/towns/{town_code}/updates", timeout=15) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload.get("update")


def now_hhmm() -> str:
    return datetime.now().strftime("%H%M")


def build_reply(type_: str, town_code: str, update: dict | None):
    update = update or {
        "classes": 0,
        "notice": "No LGU update is currently available.",
        "floodAreas": [],
        "evacuationCenters": [],
        "roadStatuses": [],
        "mapPins": [],
    }
    time = now_hhmm()

    if type_ == "Q":
        if update.get("pagasaActive") is False:
            weather = None
            try:
                weather = fetch_local_weather(town_code)
            except Exception:
                pass
            notice = "No current storm update administered by PAGASA."
            if weather:
                notice += f" Local weather: {weather['temperature']:.0f}C, rain {weather['rain_mm']:.1f}mm, wind {weather['wind']:.0f}/gust {weather['gust']:.0f} km/h."
            fields = ["W0", "R0", "G0", "C0"]
            return encode("Q", town_code, fields, time, notice)

        evac = update.get("evacuationCenters") or []
        evac_field = ""
        if evac:
            first = evac[0]
            evac_field = f"E1{first.get('status', 'O')}"
        fields = [
            f"W{int(update.get('classes', 0))}",
            f"R{int(update.get('rain', 0))}",
            f"G{int(update.get('gusts', 0))}",
        ]
        if evac_field:
            fields.append(evac_field)
        fields.append(f"C{int(update.get('classes', 0))}")
        notice = str(update.get("notice") or "PAGASA weather update")
        try:
            weather = fetch_local_weather(town_code)
            if weather:
                notice += (
                    f" Local weather: {weather['temperature']:.0f}C, "
                    f"rain {weather['rain_mm']:.1f}mm, "
                    f"wind {weather['wind']:.0f}/gust {weather['gust']:.0f} km/h."
                )
        except Exception:
            pass
        return encode("Q", town_code, fields, time, notice)

    if type_ == "F":
        fields = [
            f"A{i}{area.get('level', 'L')}{area.get('status', 'C')}"
            for i, area in enumerate(update.get("floodAreas") or [], 1)
        ]
        return encode("F", town_code, fields or ["A1LC"], time, str(update.get("notice", "")))

    if type_ == "E":
        fields = [
            f"S{i}{center.get('status', 'O')}{int(center.get('percentFull', 0))}"
            for i, center in enumerate(update.get("evacuationCenters") or [], 1)
        ]
        return encode("E", town_code, fields or ["S1O0"], time, str(update.get("notice", "")))

    if type_ == "R":
        fields = [
            f"R{i}{road.get('status', 'O')}"
            for i, road in enumerate(update.get("roadStatuses") or [], 1)
        ]
        return encode("R", town_code, fields or ["R1O"], time, str(update.get("notice", "")))

    if type_ == "P":
        pins = [
            MapPin(
                category=pin["category"],
                label=pin["label"],
                latitude=float(pin["latitude"]),
                longitude=float(pin["longitude"]),
                status=pin["status"],
                intensity=int(pin["intensity"]),
            )
            for pin in (update.get("mapPins") or [])
        ]
        return encode_pins(town_code, pins, time)

    raise ValueError("unsupported Nimbus request type")


def cache_reply(type_: str, town_code: str, sms: str) -> None:
    directory = CACHE_DIR / town_code
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{type_}.sms").write_text(sms, encoding="utf-8")


def cached_reply(type_: str, town_code: str) -> str | None:
    path = CACHE_DIR / town_code / f"{type_}.sms"
    return path.read_text(encoding="utf-8") if path.is_file() else None


TOWN_ALIASES = {
    "0412": ("0401005000", 13.7567, 121.0584),
    "0517": ("0501724000", 13.61917, 123.18139),
    "0837": ("0831600000", 11.24333, 125.00472),
    "1374": ("1380700000", 14.6481, 121.1133),
}


def town_location(town_code: str):
    if town_code in TOWN_ALIASES:
        return TOWN_ALIASES[town_code][1:]
    for legacy, (psgc, latitude, longitude) in TOWN_ALIASES.items():
        if town_code == psgc:
            return latitude, longitude
    return None


def fetch_local_weather(town_code: str):
    location = town_location(town_code)
    if location is None:
        return None
    latitude, longitude = location
    url = (
        "https://api.open-meteo.com/v1/forecast?"
        f"latitude={latitude}&longitude={longitude}"
        "&current=temperature_2m,precipitation,wind_speed_10m,wind_gusts_10m"
        "&timezone=Asia%2FManila"
    )
    with urllib.request.urlopen(url, timeout=10) as response:
        data = json.loads(response.read().decode("utf-8"))
    current = data.get("current") or {}
    return {
        "temperature": current.get("temperature_2m"),
        "rain_mm": current.get("precipitation"),
        "wind": current.get("wind_speed_10m"),
        "gust": current.get("wind_gusts_10m"),
    }


def handle_incoming_sms(payload, saved_path: Path | None = None) -> None:
    """Handle an NB1 ASK request or save an LGU P pin snapshot, then reply when needed."""
    msg_text, sender = extract_sms_fields(payload)
    if not sender:
        print("No sender number found in payload; skipped reply.", flush=True)
        return

    key = _reply_key(payload, msg_text, sender)
    if not _claim_reply_slot(key):
        print(f"Duplicate/retry detected ({key[:12]}); skipped reply.", flush=True)
        return

    match = __import__("re").fullmatch(r"NB1 ASK ([QFERP]) ((?:\d{4}|\d{10}))", msg_text.strip())
    if match:
        type_, town_code = match.groups()
        try:
            update = fetch_update(town_code)
            reply = build_reply(type_, town_code, update)
            cache_reply(type_, town_code, reply)
        except Exception:
            reply = cached_reply(type_, town_code)
            if not reply:
                reply = f"NIMBUS: Could not retrieve {town_code}. Try again later."[:160]
        print(f"Reply built: {reply!r}", flush=True)
        sent = send_sms(sender, reply)
        print(f"Reply sent: {sent}", flush=True)
        return

    compact = msg_text.startswith("NB1~P~")
    if compact:
        print("LGU pin snapshot received and persisted by the API sync path.", flush=True)


class SMSHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        """Handle incoming SMS messages."""
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)
        payload = body.decode("utf-8")

        # Log the incoming payload for debugging
        print(f"Received payload: {payload}", flush=True)

        # Handle the payload
        handle_incoming_sms(payload)

        self.send_response(200)
        self.end_headers()

    def log_message(self, format: str, *args) -> None:
        """Override to prevent logging to stderr."""
        return


def main():
    server = ThreadingHTTPServer(("0.0.0.0", 5001), SMSHandler)
    print("Listening on http://localhost:5001/sms", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        print("Server stopped.", flush=True)


if __name__ == "__main__":
    main()
