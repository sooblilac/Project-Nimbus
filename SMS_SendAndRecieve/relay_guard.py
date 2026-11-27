"""Security checks for the SMS relay webhook.

- verify_webhook: checks the sms-gate.app payload signature
  (HMAC-SHA256 of raw body + X-Timestamp, hex) and rejects stale timestamps.
- RateLimiter: persistent per-number and global send caps, so a leaked key or a
  noisy resident can't drain the gateway SIM or get it flagged as a spammer.
- mask_number: keeps phone numbers out of logs.

Configuration (environment / .env):
  SMS_WEBHOOK_SIGNING_KEY        required; Settings -> Webhooks -> Signing Key in the
                                 SMS Gateway app on the gateway phone
  RELAY_MAX_PER_NUMBER_10MIN     default 5
  RELAY_MAX_PER_NUMBER_DAY       default 30
  RELAY_MAX_GLOBAL_HOUR          default 300
  RELAY_MAX_GLOBAL_DAY           default 2000
"""
from __future__ import annotations

import hashlib
import hmac
import os
import sqlite3
import threading
import time
from pathlib import Path

MAX_BODY_BYTES = 64 * 1024
TIMESTAMP_TOLERANCE_SECONDS = 300


def verify_webhook(
    raw_body: bytes,
    signature: str | None,
    timestamp: str | None,
    key: str,
    now: float | None = None,
) -> tuple[bool, str]:
    """Return (ok, reason). Follows docs.sms-gate.app/features/webhooks/#payload-signing."""
    if not key:
        return False, "signing key not configured"
    if not signature or not timestamp:
        return False, "missing signature headers"
    try:
        ts = int(timestamp)
    except ValueError:
        return False, "bad timestamp"
    now = time.time() if now is None else now
    if abs(now - ts) > TIMESTAMP_TOLERANCE_SECONDS:
        return False, "stale timestamp"
    expected = hmac.new(
        key.encode("utf-8"), raw_body + timestamp.encode("utf-8"), hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(expected, signature.strip().lower()):
        return False, "bad signature"
    return True, "ok"


def mask_number(number: str | None) -> str:
    digits = "".join(ch for ch in str(number or "") if ch.isdigit())
    return f"***{digits[-4:]}" if len(digits) >= 4 else "***"


def _normalize(number: str) -> str:
    digits = "".join(ch for ch in number if ch.isdigit())
    return digits[-10:] if len(digits) >= 10 else digits


class RateLimiter:
    """Sliding-window send limits stored in SQLite (survives restarts)."""

    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.execute("CREATE TABLE IF NOT EXISTS sends (number TEXT, at REAL)")
        self._db.execute("CREATE INDEX IF NOT EXISTS sends_number_at ON sends (number, at)")
        self._db.execute("CREATE TABLE IF NOT EXISTS claims (key TEXT PRIMARY KEY, at REAL)")
        self._db.commit()
        self._lock = threading.Lock()
        env = lambda name, default: int(os.getenv(name, default))  # noqa: E731
        self.per_number_10min = env("RELAY_MAX_PER_NUMBER_10MIN", 5)
        self.per_number_day = env("RELAY_MAX_PER_NUMBER_DAY", 30)
        self.global_hour = env("RELAY_MAX_GLOBAL_HOUR", 300)
        self.global_day = env("RELAY_MAX_GLOBAL_DAY", 2000)

    def claim(self, key: str, now: float | None = None) -> bool:
        """Atomically mark a webhook delivery as handled; False if already seen."""
        now = time.time() if now is None else now
        with self._lock:
            self._db.execute("DELETE FROM claims WHERE at < ?", (now - 7 * 86400,))
            try:
                self._db.execute("INSERT INTO claims (key, at) VALUES (?, ?)", (key, now))
                self._db.commit()
                return True
            except sqlite3.IntegrityError:
                return False

    def allow(self, number: str, now: float | None = None) -> tuple[bool, str]:
        """Check every cap; on success, record the send. Returns (ok, reason)."""
        now = time.time() if now is None else now
        n = _normalize(number)
        with self._lock:
            self._db.execute("DELETE FROM sends WHERE at < ?", (now - 86400,))

            def count(where: str, args: tuple) -> int:
                return self._db.execute(f"SELECT COUNT(*) FROM sends WHERE {where}", args).fetchone()[0]

            if count("number = ? AND at >= ?", (n, now - 600)) >= self.per_number_10min:
                return False, "per-number 10-minute limit"
            if count("number = ? AND at >= ?", (n, now - 86400)) >= self.per_number_day:
                return False, "per-number daily limit"
            if count("at >= ?", (now - 3600,)) >= self.global_hour:
                return False, "global hourly limit"
            if count("at >= ?", (now - 86400,)) >= self.global_day:
                return False, "global daily limit"
            self._db.execute("INSERT INTO sends (number, at) VALUES (?, ?)", (n, now))
            self._db.commit()
            return True, "ok"
