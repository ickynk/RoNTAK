"""Tests for companion/web/geo.js, run through Node (skipped if Node is missing)."""

import json
import shutil
import subprocess
import unittest
from pathlib import Path

GEO = Path(__file__).resolve().parent.parent / "companion" / "web" / "geo.js"


def geo(expr):
    script = f"const Geo = require({json.dumps(str(GEO))}); console.log(JSON.stringify({expr}));"
    return json.loads(subprocess.run(["node", "-e", script], capture_output=True, text=True, check=True).stdout)


@unittest.skipUnless(shutil.which("node"), "node not installed")
class FloorBandsTest(unittest.TestCase):
    def bands(self, zs):
        return [(round(b["z"]), round(b["zMin"]), round(b["zMax"])) for b in geo(f"Geo.floorBands({zs})")]

    def test_ridgeline_three_floors_with_stair_doors_in_between(self):
        # Heights seen on Ridgeline: Ground ~2100, 1st ~2480, 2nd ~2780, plus stairs and landings.
        zs = [2087, 2087, 2141, 1941, 2342, 2419, 2449, 2479, 2480, 2486, 2486, 2496, 2598, 2779, 2782, 2782]
        self.assertEqual(self.bands(zs), [(2105, -10000000, 2288), (2471, 2288, 2626), (2781, 2626, 10000000)])

    def test_single_floor(self):
        self.assertEqual(self.bands([0, 5, 10]), [(5, -10000000, 10000000)])

    def test_lone_doors_do_not_make_floors(self):
        self.assertEqual(len(self.bands([0, 10, 250, 600, 610])), 2)

    def test_no_heights(self):
        self.assertEqual(geo("Geo.floorBands([])"), [])


if __name__ == "__main__":
    unittest.main()
