from pathlib import Path
from storm_adapter import load_bulletin, storm_reply

HERE = Path(__file__).resolve().parent
bulletin = load_bulletin(HERE / "pagasa_parser" / "output" / "bulletin.json")

code = "0001"   # will depend on the sms request, but for now just used as a test code
print(storm_reply(code, bulletin, rain=3))