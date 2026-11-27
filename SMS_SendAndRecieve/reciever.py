import hashlib
import json
import os
import re
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

from SMS import send_sms  # also loads .env into os.environ
from nimbus_codec import MapPin, decode, encode, encode_pins
from relay_guard import MAX_BODY_BYTES, RateLimiter, mask_number, verify_webhook

DATA_DIR = PROJECT_ROOT / "Data"


API_URL = os.getenv("NIMBUS_API_URL", "https://nimbus-worker.gozocharlyz.workers.dev/api").rstrip("/")

CACHE_DIR = DATA_DIR / "sms_replies"

WEBHOOK_PATH = "/sms"
WEBHOOK_ID = "my-incoming-sms"  # must match HOOK_ID in run_reciever.py
WEBHOOK_SIGNING_KEY = os.getenv("SMS_WEBHOOK_SIGNING_KEY", "")
LIMITER = RateLimiter(DATA_DIR / "relay_limits.sqlite3")


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

    if isinstance(payload, dict) and payload.get("id"):
        # sms-gate envelope id; reused verbatim across retries (per their docs).
        msg_id = f"{payload.get('deviceId', '')}:{payload['id']}"
    raw_key = f"id:{msg_id}" if msg_id else f"msg:{sender}:{msg_text}"
    return hashlib.sha256(raw_key.encode("utf-8")).hexdigest()

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
    # Cloudflare rejects the default Python-urllib user agent with 403.
    request = urllib.request.Request(
        f"{API_URL}/towns/{town_code}/updates",
        headers={"Accept": "application/json", "User-Agent": "ProjectNimbus-SMS/1.0"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload.get("update")


def now_hhmm() -> str:
    return datetime.now().strftime("%H%M")


def _name_suffix(name) -> str:
    """':Barangay_Wawa' so the app can show the real place name (letters/digits only)."""
    clean = re.sub(r"[^A-Za-z0-9]+", "_", str(name or "")).strip("_")[:24]
    return f":{clean}" if clean else ""


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
            # No PAGASA storm, but the LGU's class suspension and advisory still apply.
            lgu_notice = str(update.get("notice") or "").strip()
            notice = "No current storm update administered by PAGASA."
            if lgu_notice:
                notice = f"{lgu_notice}. {notice}" if not lgu_notice.endswith(".") else f"{lgu_notice} {notice}"
            if weather:
                notice += f" Local weather: {weather['temperature']:.0f}C, rain {weather['rain_mm']:.1f}mm, wind {weather['wind']:.0f}/gust {weather['gust']:.0f} km/h."
            fields = ["W0", "R0", "G0", f"C{int(update.get('classes', 0) or 0)}"]
            return encode("Q", town_code, fields, time, notice)

        evac = update.get("evacuationCenters") or []
        evac_field = ""
        if evac:
            first = evac[0]
            evac_field = f"E1{first.get('status', 'O')}"
        # `signal` is the PAGASA wind signal written by nimbus_sync.py; older
        # updates stored it in `classes`, so fall back to that.
        signal = update.get("signal", update.get("classes", 0))
        fields = [
            f"W{int(signal or 0)}",
            f"R{int(update.get('rain', 0))}",
            f"G{int(update.get('gusts', 0))}",
        ]
        if evac_field:
            fields.append(evac_field)
        fields.append(f"C{int(update.get('classes', 0))}")
        notice = str(
            update.get("notice")
            or update.get("pagasaNotice")
            or "PAGASA weather update"
        )
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
            f"A{i}{area.get('level', 'L')}{area.get('status', 'C')}{_name_suffix(area.get('name'))}"
            for i, area in enumerate(update.get("floodAreas") or [], 1)
        ]
        return encode("F", town_code, fields, time, str(update.get("notice", "")))

    if type_ == "E":
        fields = [
            f"S{i}{center.get('status', 'O')}{int(center.get('percentFull', 0))}{_name_suffix(center.get('name'))}"
            for i, center in enumerate(update.get("evacuationCenters") or [], 1)
        ]
        return encode("E", town_code, fields, time, str(update.get("notice", "")))

    if type_ == "R":
        fields = [
            f"R{i}{road.get('status', 'O')}{_name_suffix(road.get('name'))}"
            for i, road in enumerate(update.get("roadStatuses") or [], 1)
        ]
        return encode("R", town_code, fields, time, str(update.get("notice", "")))

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

    # The payload is signed, so the envelope id is trustworthy for de-duplicating
    # sms-gate retries; the claim is atomic (SQLite primary key).
    key = _reply_key(payload, msg_text, sender)
    if not LIMITER.claim(key):
        print(f"Duplicate/retry detected ({key[:12]}); skipped reply.", flush=True)
        return

    match = __import__("re").fullmatch(r"NB1 ASK ([QFERPA]) ((?:\d{4}|\d{10}))", msg_text.strip())
    if match:
        type_, town_code = match.groups()
        # "A" = everything: one request, one reply per update type.
        types = ["Q", "P", "F", "E", "R"] if type_ == "A" else [type_]
        try:
            update = fetch_update(town_code)
        except Exception:
            update = None
            fetch_failed = True
        else:
            fetch_failed = False
        replies = []
        for t in types:
            reply = None
            if not fetch_failed:
                try:
                    reply = build_reply(t, town_code, update)
                    cache_reply(t, town_code, reply)
                except Exception:
                    reply = None
            reply = reply or cached_reply(t, town_code)
            if reply:
                replies.append(reply)
        if not replies:
            replies = [f"NIMBUS: Could not retrieve {town_code}. Try again later."[:160]]
        # One request counts once against the rate limits, however many replies it gets.
        allowed, reason = LIMITER.allow(sender)
        if not allowed:
            print(f"Rate limit ({reason}) for {mask_number(sender)}; no reply sent.", flush=True)
            return
        for reply in replies:
            print(f"Reply to {mask_number(sender)} built: {reply!r}", flush=True)
            sent = send_sms(sender, reply)
            print(f"Reply sent to {mask_number(sender)}: {sent}", flush=True)
        return

    compact = msg_text.startswith("NB1~P~")
    if compact:
        print("LGU pin snapshot received and persisted by the API sync path.", flush=True)


class SMSHandler(BaseHTTPRequestHandler):
    def _reply(self, code: int) -> None:
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        """Handle a signed sms-gate.app webhook. Anything else is rejected."""
        if self.path.split("?", 1)[0] != WEBHOOK_PATH:
            return self._reply(404)
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._reply(400)
        if length <= 0 or length > MAX_BODY_BYTES:
            return self._reply(413 if length > MAX_BODY_BYTES else 400)
        raw = self.rfile.read(length)

        ok, reason = verify_webhook(
            raw,
            self.headers.get("X-Signature"),
            self.headers.get("X-Timestamp"),
            WEBHOOK_SIGNING_KEY,
        )
        if not ok:
            print(f"Rejected webhook: {reason}", flush=True)
            return self._reply(401)

        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return self._reply(400)
        if not isinstance(payload, dict):
            return self._reply(400)
        if payload.get("webhookId") not in (None, WEBHOOK_ID):
            print("Rejected webhook: unexpected webhookId", flush=True)
            return self._reply(403)
        if payload.get("event") not in (None, "sms:received"):
            return self._reply(204)

        # Acknowledge first so sms-gate does not retry while we build the reply.
        self._reply(200)
        try:
            handle_incoming_sms(payload)
        except Exception as error:  # keep serving other requests
            print(f"Error handling webhook: {type(error).__name__}: {error}", flush=True)

    def log_message(self, format: str, *args) -> None:
        """Override to prevent logging to stderr."""
        return


def main():
    missing = [
        name
        for name in ("SMS_WEBHOOK_SIGNING_KEY", "NIMBUS_SMS_SIGNING_KEY")
        if not os.getenv(name)
    ]
    if missing:
        raise SystemExit(
            "Refusing to start: set " + " and ".join(missing) + " in .env. "
            "SMS_WEBHOOK_SIGNING_KEY is in the SMS Gateway app under Settings > "
            "Webhooks > Signing Key; NIMBUS_SMS_SIGNING_KEY is the shared key the "
            "NIMBUS app is built with."
        )
    # Only cloudflared (on this machine) should reach the webhook.
    server = ThreadingHTTPServer(("127.0.0.1", 5001), SMSHandler)
    print("Listening on http://127.0.0.1:5001/sms (signed webhooks only)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        print("Server stopped.", flush=True)


if __name__ == "__main__":
    main()
