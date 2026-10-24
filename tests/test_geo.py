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
    def test_three_floors(self):
        bands = geo("Geo.floorBands([2090, 2100, 2140, 2420, 2430, 2480, 2780, 2790])")
        self.assertEqual([(b["zMin"], b["zMax"]) for b in bands], [(-1e7, 2280), (2280, 2630), (2630, 1e7)])

    def test_single_floor(self):
        self.assertEqual(geo("Geo.floorBands([0, 5, 10])"), [{"zMin": -1e7, "zMax": 1e7}])

    def test_lone_landing_door_joins_nearest_floor(self):
        bands = geo("Geo.floorBands([0, 10, 250, 600, 610])")
        self.assertEqual([b["zMax"] for b in bands], [425, 1e7])

    def test_no_heights(self):
        self.assertEqual(geo("Geo.floorBands([])"), [])


if __name__ == "__main__":
    unittest.main()
