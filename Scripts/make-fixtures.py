#!/usr/bin/env python3
"""Generates the anonymized test fixtures in Tests/Fixtures.

The fixtures are synthetic. They follow the schema described for the tested Mac
(batteryGaugingMitigationInfo > batteryPackData > <pack>), with an invented pack
identifier and invented extra keys that exist only to prove that unrelated
content is preserved. They are not copies of a real system file.
"""
import datetime as dt
import os
import plistlib
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "Tests", "Fixtures")
PACK = "FIXTUREPACK0000001"
Y2030 = dt.datetime(2030, 1, 1, 0, 0, 0)


def document(dod0, qmax, qual, full_date, full_req):
    return {
        "batteryGaugingMitigationInfo": {
            "batteryPackCount": 1,
            "batteryPackData": {
                PACK: {
                    "lastDOD0Update": dod0,
                    "lastQMaxUpdate": qmax,
                    "lastQualQMaxDate": qual,
                    # Invented keys: must survive every operation untouched.
                    "fixtureCycleCountAtLastUpdate": 212,
                    "fixtureQMaxHistory": [4381, 4377, 4370],
                    "fixtureRatio": 0.5,
                },
            },
            "lastFullChargeDate": full_date,
            "lastFullChargeReq": full_req,
            "fixtureOne": 1,
            "fixtureFlag": True,
            "fixtureNote": "synthetic fixture",
        },
        "fixtureSchemaVersion": 1,
    }


STATES = {
    # Before the workaround: 2026 dates and a pending full-charge request.
    "original": document(
        dt.datetime(2026, 10, 30, 21, 14, 5),
        dt.datetime(2026, 9, 18, 7, 2, 41),
        dt.datetime(2026, 9, 18, 7, 2, 41),
        dt.datetime(2026, 10, 2, 3, 55, 10),
        True,
    ),
    # All five values applied.
    "applied": document(Y2030, Y2030, Y2030, Y2030, False),
    # After the macOS update: only lastDOD0Update was rewritten, near boot.
    "post-update": document(dt.datetime(2026, 11, 9, 8, 31, 17), Y2030, Y2030, Y2030, False),
}


def write(name, value, fmt):
    suffix = "binary" if fmt == plistlib.FMT_BINARY else "xml"
    path = os.path.join(OUT, f"{name}.{suffix}.plist")
    with open(path, "wb") as handle:
        plistlib.dump(value, handle, fmt=fmt, sort_keys=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, value in STATES.items():
        write(name, value, plistlib.FMT_BINARY)
        write(name, value, plistlib.FMT_XML)

    info = lambda d: d["batteryGaugingMitigationInfo"]
    base = lambda: document(Y2030, Y2030, Y2030, Y2030, False)

    two = base()
    info(two)["batteryPackData"]["FIXTUREPACK0000002"] = dict(info(two)["batteryPackData"][PACK])
    info(two)["batteryPackCount"] = 2
    write("invalid-two-packs", two, plistlib.FMT_XML)

    count = base()
    info(count)["batteryPackCount"] = 2
    write("invalid-pack-count", count, plistlib.FMT_BINARY)

    missing = base()
    del info(missing)["batteryPackData"][PACK]["lastQMaxUpdate"]
    write("invalid-missing-key", missing, plistlib.FMT_BINARY)

    wrong_date = base()
    info(wrong_date)["batteryPackData"][PACK]["lastDOD0Update"] = "2030-01-01T00:00:00Z"
    write("invalid-date-as-string", wrong_date, plistlib.FMT_XML)

    wrong_bool = base()
    info(wrong_bool)["lastFullChargeReq"] = 0
    write("invalid-bool-as-integer", wrong_bool, plistlib.FMT_BINARY)

    write("invalid-no-root-key", {"somethingElse": {}}, plistlib.FMT_XML)

    with open(os.path.join(OUT, "invalid-not-a-plist.plist"), "wb") as handle:
        handle.write(b"bplist00" + bytes(range(1, 20)))


if __name__ == "__main__":
    main()
