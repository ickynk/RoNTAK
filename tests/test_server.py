"""Tests for the companion server's HTTP API."""

import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "companion"))
import server  # noqa: E402


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bridge = Path(tempfile.mkdtemp())
        cls.maps = Path(tempfile.mkdtemp())
        server.MAPS_DIR = cls.maps
        server.Handler.bridge = cls.bridge
        server.Handler.queue = server.CommandQueue(cls.bridge)
        cls.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def call(self, method, path, body=None, raw=False):
        data = body if raw else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(self.base + path, data=data, method=method)
        try:
            with urllib.request.urlopen(req) as res:
                return res.status, json.loads(res.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_page_asks_for_fresh_scripts(self):
        with urllib.request.urlopen(self.base + "/") as res:
            html = res.read().decode()
            self.assertEqual(res.headers["Cache-Control"], "no-cache")
        for name in ("style.css", "geo.js", "app.js"):
            self.assertRegex(html, rf'"{name}\?v=\d+"')
        with urllib.request.urlopen(self.base + "/app.js?v=1") as res:
            self.assertIn(b"drawFloorImage", res.read())

    def test_state_missing_then_present(self):
        (self.bridge / "state.json").unlink(missing_ok=True)
        status, body = self.call("GET", "/api/state")
        self.assertFalse(body["connected"])
        (self.bridge / "state.json").write_text(json.dumps({"level": "X", "officers": []}))
        status, body = self.call("GET", "/api/state")
        self.assertTrue(body["connected"])
        self.assertEqual(body["level"], "X")

    def test_rooms(self):
        (self.bridge / "rooms.json").unlink(missing_ok=True)
        self.assertEqual(self.call("GET", "/api/rooms")[1], {"level": None, "rooms": []})
        (self.bridge / "rooms.json").write_text(json.dumps({"level": "X", "rooms": [{"name": "Kitchen"}]}))
        self.assertEqual(self.call("GET", "/api/rooms")[1]["rooms"][0]["name"], "Kitchen")

    def test_command_written_for_mod(self):
        status, cmd = self.call("POST", "/api/command", {
            "team": "blue", "action": "breach_clear",
            "target": {"door": "Door_C_1", "location": {"x": 1, "y": 2}},
            "options": {"breach": "c2", "grenade": "flashbang", "junk": "x"},
        })
        self.assertEqual(status, 200)
        doc = json.loads((self.bridge / "commands.json").read_text())
        last = doc["commands"][-1]
        self.assertEqual(last["id"], cmd["id"])
        self.assertEqual(last["options"], {"breach": "c2", "grenade": "flashbang"})
        self.assertEqual(last["target"]["location"], {"x": 1.0, "y": 2.0, "z": 0.0})

    def test_hold_and_character_target(self):
        status, cmd = self.call("POST", "/api/command", {
            "team": "red", "action": "restrain", "hold": True,
            "target": {"character": "Suspect_1"}, "options": {"scan": "snap"},
        })
        self.assertEqual(status, 200)
        last = json.loads((self.bridge / "commands.json").read_text())["commands"][-1]
        self.assertEqual((last["hold"], last["target"], last["options"]), (True, {"character": "Suspect_1"}, {"scan": "snap"}))
        status, cmd = self.call("POST", "/api/command", {"team": "gold", "action": "go", "hold": True})
        last = json.loads((self.bridge / "commands.json").read_text())["commands"][-1]
        self.assertNotIn("hold", last)  # GO itself is never held

    def test_command_validation(self):
        self.assertEqual(self.call("POST", "/api/command", {"team": "green", "action": "hold"})[0], 400)
        self.assertEqual(self.call("POST", "/api/command", {"team": "red", "action": "dance"})[0], 400)

    def test_map_save_load_and_image(self):
        self.assertEqual(self.call("GET", "/api/maps/Level1")[1]["floors"], [])
        self.call("PUT", "/api/maps/Level1", {"floors": [{"name": "1F", "anchors": []}], "rooms": []})
        self.assertEqual(self.call("GET", "/api/maps/Level1")[1]["floors"][0]["name"], "1F")
        status, _ = self.call("PUT", "/api/maps/Level1/plan.png", b"\x89PNG fake", raw=True)
        self.assertEqual(status, 200)
        with urllib.request.urlopen(self.base + "/maps/Level1/plan.png") as res:
            self.assertEqual(res.read(), b"\x89PNG fake")

    def test_rejects_unsafe_names(self):
        self.assertEqual(self.call("PUT", "/api/maps/..%2F..%2Fetc", {"floors": []})[0], 400)
        self.assertEqual(self.call("PUT", "/api/maps/Level1/evil.exe", b"x", raw=True)[0], 400)


if __name__ == "__main__":
    unittest.main()


class MockCamerasTest(unittest.TestCase):
    def test_cctv_wired_after_ten_seconds_and_helicopter_marks_suspect(self):
        import mock
        game = mock.MockGame()
        cams = game.cameras()
        self.assertEqual(cams["cctv"], {"wired": False, "cameras": []})
        self.assertEqual((game.spotted["source"], game.spotted["status"]), ("helicopter", "tracked"))
        game.clock = 25  # 20 s tracked, then lost
        cams = game.cameras()
        self.assertTrue(cams["cctv"]["wired"])
        self.assertEqual(len(cams["cctv"]["cameras"]), 2)
        self.assertEqual(game.spotted["status"], "last_seen")
        self.assertEqual(cams["drones"][0]["view"]["fov"], 90.0)
        self.assertEqual(game.officers[1].state()["status"], "injured")
        for clock in range(10, 60):  # the civilian walks into the Living Room camera's view
            game.clock = clock
            game.cameras()
            if game.cctv_spotted and game.cctv_spotted["status"] == "tracked":
                break
        self.assertEqual((game.cctv_spotted["source"], game.cctv_spotted["camera"]), ("cctv", "Living Room"))
