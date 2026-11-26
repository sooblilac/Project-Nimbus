import hashlib
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parent

if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from SMS import send_sms
from Storm.pack_storm import temp_vowel_reply

DATA_DIR = PROJECT_ROOT / "Data"

SEEN_DIR = DATA_DIR / ".replied"
COOLDOWN_SECONDS = 300  # 5 minutes; adjust as needed


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

def handle_incoming_sms(payload, saved_path: Path | None = None) -> None:
    """Process a newly received SMS: build temp vowel reply and send it back once."""
    msg_text, sender = extract_sms_fields(payload)
    if not sender:
        print("No sender number found in payload; skipped reply.", flush=True)
        return

    key = _reply_key(payload, msg_text, sender)
    if not _claim_reply_slot(key):
        print(f"Duplicate/retry detected ({key[:12]}); skipped reply.", flush=True)
        return

    reply = temp_vowel_reply(msg_text)
    print(f"Reply built: {reply!r}", flush=True)

    sent = send_sms(sender, reply)
    print(f"Reply sent: {sent}", flush=True)

def write_to_storm(payload) -> Path:
    """Atomically write an incoming SMS record into the Data folder."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%S%fZ")
    record = {
        "received_at": now.isoformat(),
        "data": payload,
    }

    final_path = DATA_DIR / f"sms_{stamp}.json"
    fd, tmp_name = tempfile.mkstemp(prefix=".sms_", suffix=".tmp", dir=str(DATA_DIR))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(record, f, indent=2, ensure_ascii=False)
        os.replace(tmp_name, final_path)
    except Exception:
        if os.path.exists(tmp_name):
            os.remove(tmp_name)
        raise

    return final_path

class SMSHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/sms":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length).decode("utf-8", errors="replace")

        try:
            payload = json.loads(raw_body) if raw_body else None
        except json.JSONDecodeError:
            payload = raw_body

        print("New message arrived:", flush=True)
        print(payload, flush=True)

        saved_path = write_to_storm(payload)
        print(f"Saved to Data: {saved_path}", flush=True)

        try:
            handle_incoming_sms(payload, saved_path)
        except Exception as exc:
            print(f"Error in handle_incoming_sms: {exc}", flush=True)

        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, format, *args):
        return

def main():
    server = ThreadingHTTPServer(("0.0.0.0", 5000), SMSHandler)
    print("Listening on http://localhost:5000/sms", flush=True)
    print(f"Writing incoming SMS files to: {DATA_DIR}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()