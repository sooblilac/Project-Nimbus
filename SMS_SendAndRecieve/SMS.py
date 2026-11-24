import base64
import json
import os
import ssl
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent

def main() -> None:
    number = input("Phone number (e.g. 0917 123 4567): ").strip()
    message = input("Message: ").strip()
    if not number or not message:
        print("Number and message are both required.")
        return
    send_sms(number, message)

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
USERNAME = os.environ["SMS_USERNAME"]
PASSWORD = os.environ["SMS_PASSWORD"]


def http_request(method: str, url: str, payload: dict | None = None) -> tuple[int, str]:
    """Send an HTTP request with Basic Auth using standard library urllib."""
    token = base64.b64encode(f"{USERNAME}:{PASSWORD}".encode("utf-8")).decode("ascii")
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {
        "Authorization": f"Basic {token}",
        "User-Agent": "ProjectNimbus-SMS/1.0",
        "Accept": "application/json",
    }
    if data is not None:
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15, context=SSL_CONTEXT) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        return e.code, body

def show(label: str, status_code: int, body: str) -> None:
    """Print status code and body of a response."""
    print(f"\n--- {label} ---")
    print("Status:", status_code)
    if not body:
        print("(empty response)")
        return
    try:
        print(json.dumps(json.loads(body), indent=2))
    except ValueError:
        print(body)


def to_ph_number(num: str) -> str:
    """Convert 0917 123 4567 -> +639171234567."""
    num = num.replace(" ", "").replace("-", "")
    if num.startswith("+63"):
        return num
    if num.startswith("63"):
        return "+" + num
    if num.startswith("0"):
        return "+63" + num[1:]
    return "+63" + num


def phone_online() -> bool:
    """Ask the server for the registered devices and print the reply."""
    try:
        status_code, body = http_request("GET", f"{BASE_URL}/device")
        show("Devices", status_code, body)
        if not (200 <= status_code < 300):
            return False
        parsed = json.loads(body) if body else None
        return bool(parsed)
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as e:
        print("Device check failed:", e)
        return False


def send_sms(number: str, message: str, retries: int = 3) -> bool:
    """Send an SMS and print the server's reply."""
    number = to_ph_number(number)
    for attempt in range(1, retries + 1):
        try:
            status_code, body = http_request(
                "POST",
                f"{BASE_URL}/message",
                payload={"textMessage": {"text": message}, "phoneNumbers": [number]},
            )
            show(f"Send attempt {attempt} to {number}", status_code, body)
            if 200 <= status_code < 300:
                return True
            if 400 <= status_code < 500:
                print("Request was rejected, so retrying won't help.")
                return False
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            print(f"Attempt {attempt} failed:", e)
        time.sleep(3)
    return False


if __name__ == "__main__":
    main()