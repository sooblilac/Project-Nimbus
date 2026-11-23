"""Tests for storm_adapter.py. Run from nimbus-pack:  python3 -m unittest discover -s tests -v"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from pack_storm import PackError  # noqa: E402
from storm_adapter import BulletinError, gusts_kph, issued_at, load_bulletin, storm_reply, warning_level  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DECODER = os.environ.get("NIMBUS_UNPACK_JS", os.path.join(HERE, "..", "..", "nimbus-unpack", "unpack.js"))
# What the teammate's parseBulletin.js produced from the real Typhoon Samuel bulletin 2F (9 Nov 2026).
SAMUEL = load_bulletin(os.path.join(HERE, "samuel_2F.bulletin.json"))


def bulletin(**over):
    b = json.loads(json.dumps(SAMUEL))
    b.update(over)
    return b


class RealSamuelBulletin(unittest.TestCase):
    def test_the_reply(self):
        reply = storm_reply("0517", SAMUEL, rain=3)
        self.assertTrue(reply.startswith("NB1 Q 0517 W0 R3 G160 T1700 K"), reply)

    def test_each_part(self):
        self.assertEqual(issued_at(SAMUEL), datetime(2026, 11, 9, 17, 0))
        self.assertEqual(gusts_kph(SAMUEL), 160)
        self.assertEqual(warning_level(SAMUEL), "0")

    def test_the_app_decoder_reads_it_back(self):
        if not (shutil.which("node") and os.path.exists(DECODER)):
            self.skipTest("node or the decoder is not available")
        with open(os.path.join(HERE, "towns.fixture.json")) as f:
            towns = json.load(f)
        for t in towns:
            t["packFlood"], t["packRoads"] = [z["name"] for z in t["flood"]], [r["name"] for r in t["roads"]]
        reply = storm_reply("0517", SAMUEL, rain=3)
        out = subprocess.run(["node", os.path.join(HERE, "decode_cli.js"), DECODER], input=json.dumps({"towns": towns, "messages": [reply]}),
                             capture_output=True, text=True, check=True)
        res = json.loads(out.stdout)[0]
        self.assertTrue(res["ok"] and res["data"]["valid"], res)
        d = res["data"]
        self.assertEqual((d["w"], d["r"], d["g"], d["t"], d["town"]), ("0", 3, 160, "1700", "0517"))


class IssueTime(unittest.TestCase):
    def test_forms(self):
        cases = {"5:00 PM, 09 November 2026": datetime(2026, 11, 9, 17, 0),
                 "11:00 PM, 03 November 2025": datetime(2025, 11, 3, 23, 0),
                 "12:00 AM, 01 December 2026": datetime(2026, 12, 1, 0, 0),
                 "12:30 PM, 01 December 2026": datetime(2026, 12, 1, 12, 30),
                 "5:00 pm, 9 november 2026": datetime(2026, 11, 9, 17, 0),
                 " 8:05 AM , 15 JULY 2026 ": datetime(2026, 7, 15, 8, 5)}
        for text, want in cases.items():
            with self.subTest(text=text):
                self.assertEqual(issued_at({"issued": text}), want)

    def test_bad_forms(self):
        for bad in [None, "", "5 PM, 09 November 2026", "17:00, 09 November 2026", "13:00 PM, 09 November 2026",
                    "0:30 AM, 09 November 2026", "5:00 PM, 09 Novembre 2026", "5:00 PM, 31 November 2026", "5:00 PM 09 November 2026", 1700]:
            with self.subTest(bad=bad), self.assertRaises(BulletinError):
                issued_at({"issued": bad})


class WarningLevel(unittest.TestCase):
    def test_none_hoisted(self):
        self.assertEqual(warning_level({"windSignals": {"noneHoisted": True, "rawText": "No Wind Signal is currently hoisted"}}), "0")

    def test_signals_in_effect_takes_the_highest(self):
        # Synthetic text: we have not seen a real bulletin with signals up yet.
        for text, want in [("TCWS #3 Storm-force winds: Batanes", "3"), ("TCWS #1 ... TCWS #2 ... TCWS #4", "4"),
                           ("Tropical Cyclone Wind Signal No. 2", "2"), ("Wind Signal #5", "5"), ("TCWS No. 1", "1"), ("tcws 2", "2")]:
            with self.subTest(text=text):
                self.assertEqual(warning_level({"windSignals": {"noneHoisted": False, "rawText": text}}), want)

    def test_unreadable_signals_are_an_error_not_a_guess(self):
        for sig in [{"noneHoisted": False, "rawText": "Strong winds expected over Luzon"}, {"noneHoisted": False, "rawText": None}, {}, None]:
            with self.subTest(sig=sig), self.assertRaises(BulletinError):
                warning_level({"windSignals": sig})
        with self.assertRaises(BulletinError):
            warning_level({})


class Gusts(unittest.TestCase):
    def test_values(self):
        for value, want in [(160, 160), (160.0, 160), (159.6, 160), (0, 0)]:
            self.assertEqual(gusts_kph({"intensity": {"gustsKph": value}}), want)

    def test_unusable(self):
        for bad in [None, "160", True, -5, [160]]:
            with self.subTest(bad=bad), self.assertRaises(BulletinError):
                gusts_kph({"intensity": {"gustsKph": bad}})
        with self.assertRaises(BulletinError):
            gusts_kph({})


class StormReply(unittest.TestCase):
    def test_rain_is_required(self):
        with self.assertRaises(BulletinError):
            storm_reply("0517", SAMUEL, rain=None)

    def test_values_the_packer_rejects_stay_rejected(self):
        with self.assertRaises(PackError):
            storm_reply("0517", SAMUEL, rain=9)
        with self.assertRaises(PackError):
            storm_reply("517", SAMUEL, rain=3)
        with self.assertRaises(PackError):
            storm_reply("0517", bulletin(intensity={"gustsKph": 999}), rain=3)

    def test_both_error_types_are_value_errors(self):
        for fn in (lambda: storm_reply("0517", {}, rain=3), lambda: storm_reply("0517", SAMUEL, rain=9)):
            with self.assertRaises(ValueError):
                fn()


class LoadBulletin(unittest.TestCase):
    def test_missing_and_broken_files(self):
        with self.assertRaises(BulletinError):
            load_bulletin(os.path.join(HERE, "does-not-exist.json"))
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write("{not json")
        try:
            with self.assertRaises(BulletinError):
                load_bulletin(f.name)
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()