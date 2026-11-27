import base64
import json
import os
import re
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent   # folder this script lives in
TUNNEL_LOG = HERE / "tunnel.log"

def find_env_file(start: Path) -> Path | None:
    """Look for .env in the script folder and up to two parent folders."""
    for folder in [start, start.parent, start.parent.parent]:
        if folder is None:
            continue
        candidate = folder / ".env"
        if candidate.is_file():
            return candidate
    return None

def load_env_file(path: Path | None) -> None:
    """Load KEY=VALUE pairs from a .env file into os.environ."""
    if path is None or not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        os.environ.setdefault(key, val)

def build_ssl_context() -> ssl.SSLContext:
    """Use MSYS2 / system CA certs when available so urllib verifies HTTPS."""
    candidates = [
        os.environ.get("SSL_CERT_FILE"),
        r"C:\msys64\usr\ssl\certs\ca-bundle.crt",
        r"C:\msys64\ucrt64\etc\ssl\cert.pem",
        r"C:\msys64\etc\ssl\certs\ca-certificates.crt",
    ]
    for cert_path in candidates:
        if cert_path and Path(cert_path).is_file():
            return ssl.create_default_context(cafile=cert_path)
    return ssl.create_default_context()

env_path = find_env_file(HERE)
load_env_file(env_path)

if "SMS_USERNAME" not in os.environ or "SMS_PASSWORD" not in os.environ:
    checked_from = str(env_path) if env_path else f"{HERE} (and parent folders)"
    raise RuntimeError(
        f"Missing SMS_USERNAME or SMS_PASSWORD (checked {checked_from}). "
        "Add them to your .env file or set them as environment variables."
    )

SSL_CONTEXT = build_ssl_context()
BASE_URL = "https://api.sms-gate.app/3rdparty/v1"
AUTH = (os.environ["SMS_USERNAME"], os.environ["SMS_PASSWORD"])
HOOK_ID = "my-incoming-sms"

def http_request(method: str, url: str, auth: tuple[str, str], payload: dict | None = None):
    """Send an HTTP request with Basic Auth using standard library urllib."""
    token = base64.b64encode(f"{auth[0]}:{auth[1]}".encode("utf-8")).decode("ascii")
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {
        "Authorization": f"Basic {token}",
        "User-Agent": "ProjectNimbus-SMS/1.0",
        "Accept": "application/json",
        "Connection": "close",
    }
    if data is not None:
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60, context=SSL_CONTEXT) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        return e.code, body

def start_tunnel():
    """Start cloudflared and return (process, public_url)."""
    log = open(TUNNEL_LOG, "w", encoding="utf-8")
    proc = subprocess.Popen(
        ["cloudflared", "tunnel", "--url", "http://127.0.0.1:5001"],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    for _ in range(60):                      # wait up to ~30 seconds
        time.sleep(0.5)
        with open(TUNNEL_LOG, encoding="utf-8") as f:
            m = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", f.read())
        if m:
            return proc, m.group(0)
    proc.terminate()
    raise RuntimeError("Tunnel URL not found, check tunnel.log")

def register(url: str) -> None:
    """Replace the old webhook with one pointing at the new tunnel URL."""
    try:
        http_request("DELETE", f"{BASE_URL}/webhooks/{HOOK_ID}", AUTH)
    except (urllib.error.URLError, TimeoutError, OSError):
        pass

    status, text = http_request(
        "POST",
        f"{BASE_URL}/webhooks",
        AUTH,
        payload={"id": HOOK_ID, "url": f"{url}/sms", "event": "sms:received"},
    )
    print("Webhook registration:", status, text)
    if not (200 <= status < 300):
        print("[WARNING] Webhook did NOT register. Incoming replies will not be forwarded to /sms.")

def pagasa_poll_loop():
    interval = int(os.getenv("PAGASA_SYNC_INTERVAL_SECONDS", "900"))
    project_root = HERE.parent
    sync_script = project_root / "nimbus_sync.py"
    while True:
        try:
            result = subprocess.run(
                [sys.executable, str(sync_script)],
                cwd=project_root,
                capture_output=True,
                text=True,
                timeout=240,
            )
            output = (result.stdout + result.stderr).strip()
            print(output or f"PAGASA sync exit: {result.returncode}", flush=True)
        except Exception as error:
            print(f"PAGASA sync failed: {error}", flush=True)
        time.sleep(interval)

def main():
    receiver = subprocess.Popen([sys.executable, str(HERE / "reciever.py")])
    tunnel = None
    poller = threading.Thread(target=pagasa_poll_loop, daemon=True)
    poller.start()
    try:
        time.sleep(2)                        # let receiver start
        tunnel, url = start_tunnel()
        print("Tunnel address:", url)
        register(url)

        print("\nRunning. Press Ctrl+C to stop.\n")
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        if tunnel is not None:
            tunnel.terminate()
        receiver.terminate()

if __name__ == "__main__":
    main()