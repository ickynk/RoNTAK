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


# A 10 x 6 m building split by an inner wall at x = 500 into two 5 x 6 m rooms, with
# a 100 cm doorway (door marker at its hinge) in the inner wall and a 60 cm window gap
# in the outer wall of the left room. Walls are traced lines [x1, y1, x2, y2] in cm.
WALLS = [
    [0, 0, 1000, 0], [1000, 0, 1000, 600], [1000, 600, 0, 600],
    [0, 600, 0, 350], [0, 290, 0, 0],             # window gap y 290-350
    [500, 0, 500, 250], [500, 350, 500, 600],     # doorway y 250-350
]
DOORS = [{"x": 500, "y": 250}]


@unittest.skipUnless(shutil.which("node"), "node not installed")
class RoomsFromWallsTest(unittest.TestCase):
    def rooms(self, walls=WALLS, doors=DOORS):
        return geo(f"Geo.roomsFromWalls({json.dumps(walls)}, {json.dumps(doors)})")

    @staticmethod
    def area(poly):
        return abs(sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]))) / 2 / 10000

    def test_two_rooms_split_at_the_door(self):
        rooms = sorted(self.rooms(), key=lambda p: min(x for x, _ in p))
        self.assertEqual(len(rooms), 2)
        for poly, (lo, hi) in zip(rooms, ((0, 500), (500, 1000))):
            xs = [x for x, _ in poly]
            ys = [y for _, y in poly]
            # Each room fills its half of the building, give or take the wall thickness
            # (and the doorway, which the two rooms share).
            self.assertTrue(lo - 5 <= min(xs) <= lo + 40 and hi - 40 <= max(xs) <= hi + 20, (min(xs), max(xs)))
            self.assertTrue(0 <= min(ys) <= 40 and 560 <= max(ys) <= 605, (min(ys), max(ys)))
            self.assertTrue(24 <= self.area(poly) <= 30, self.area(poly))  # 5 x 6 m = 30 m2 minus walls
            self.assertLessEqual(len(poly), 12)  # simplified to a few corners

    def test_ordinary_doorways_close_without_a_marker(self):
        self.assertEqual(len(self.rooms(doors=[])), 2)

    def test_wide_openings_need_door_markers(self):
        wide = WALLS[:5] + [[500, 0, 500, 200], [500, 400, 500, 600]]  # 2 m double doorway, y 200-400
        self.assertEqual(len(self.rooms(walls=wide, doors=[])), 1)
        self.assertEqual(len(self.rooms(walls=wide, doors=[{"x": 500, "y": 200}, {"x": 500, "y": 400}])), 2)

    def test_no_walls_no_rooms(self):
        self.assertEqual(self.rooms(walls=[]), [])


if __name__ == "__main__":
    unittest.main()
