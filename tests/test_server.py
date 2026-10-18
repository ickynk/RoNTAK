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

    def test_state_missing_then_present(self):
        (self.bridge / "state.json").unlink(missing_ok=True)
        status, body = self.call("GET", "/api/state")
        self.assertFalse(body["connected"])
        (self.bridge / "state.json").write_text(json.dumps({"level": "X", "officers": []}))
        status, body = self.call("GET", "/api/state")
        self.assertTrue(body["connected"])
        self.assertEqual(body["level"], "X")

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
