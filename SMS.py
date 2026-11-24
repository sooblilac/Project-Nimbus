import time
import requests

"""Info form the phone that will send the messeges"""
BASE_URL = "https://api.sms-gate.app/3rdparty/v1"
USERNAME = "XU74WT"
PASSWORD = "y_aaft3tosqmme"

def main():

    # poll()
    # get_inbox()

    reciever_num = "+639274234858"
    msg_to_reciever = "This is a test message :3"

    if phone_online():
        send_sms(reciever_num, msg_to_reciever)
    else:
        print("Phone is offline")

def phone_online() -> bool:
    """Check that the cloud server accepts your login and lists a device."""
    try:
        r = requests.get(f"{BASE_URL}/device", auth=(USERNAME, PASSWORD), timeout=10)
        r.raise_for_status()
        devices = r.json()
        print("Devices:", devices)
        return bool(devices)
    except requests.RequestException as e:
        print("Check failed:", e)
        return False

def send_sms(number: str, message: str, retries: int = 3) -> bool:
    """Send an SMS via the cloud relay. Number in +63XXXXXXXXXX format."""
    if not phone_online():
        print("Phone not reachable, not sending.")
        return False
    for attempt in range(retries):
        try:
            r = requests.post(
                f"{BASE_URL}/message",
                auth=(USERNAME, PASSWORD),
                json={"message": message, "phoneNumbers": [number]},
                timeout=15,
            )
            r.raise_for_status()
            print("Message succesfuly sent to: " + number)
            print("\"" + message + "\"")
            return True
        except requests.RequestException as e:
            print(f"Attempt {attempt + 1} failed: {e}")
            time.sleep(3)
    return False

def get_inbox():
    r = requests.get(f"{BASE_URL}/inbox", auth=(USERNAME, PASSWORD), timeout=30)
    r.raise_for_status()
    return r.json()

def poll(interval=10):
    seen = set()
    while True:
        try:
            for msg in get_inbox():
                msg_id = msg.get("id") or str(msg)   # adjust to the real field name
                if msg_id not in seen:
                    seen.add(msg_id)
                    print("New message:", msg)
        except requests.RequestException as e:
            print("Poll failed:", e)
        time.sleep(interval)

main()