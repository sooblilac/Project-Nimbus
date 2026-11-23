from pathlib import Path
from storm_adapter import load_bulletin, storm_reply
from unpack_storm import unpack_storm, describe_storm

HERE = Path(__file__).resolve().parent
bulletin = load_bulletin(HERE / "pagasa_parser" / "output" / "bulletin.json")

code = "0001"   # test code, will depend on the sms request later
packed = storm_reply(code, bulletin, rain=3)
print("PACKED:  ", packed)

fields = unpack_storm(packed)
print("UNPACKED:", fields)

town_names = {"0001": "Batangas City"}
print("MESSAGE: ", describe_storm(fields, town_names))