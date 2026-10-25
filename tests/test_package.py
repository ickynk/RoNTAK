"""Tests for the release ZIP (tools/package.py)."""

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import package  # noqa: E402


class PackageTest(unittest.TestCase):
    def test_zip_contents(self):
        (ROOT / "mod" / "RoNTAK" / "bridge" / "state.json").write_text("{}")  # a runtime file
        try:
            target = package.build("9.9.9", Path(tempfile.mkdtemp()))
        finally:
            (ROOT / "mod" / "RoNTAK" / "bridge" / "state.json").unlink()
        self.assertEqual(target.name, "RoNTAK-9.9.9.zip")
        names = set(zipfile.ZipFile(target).namelist())
        for expected in ("RoNTAK/README.md", "RoNTAK/Install RoNTAK.bat", "RoNTAK/Start RoNTAK.bat",
                         "RoNTAK/install.py", "RoNTAK/mod/RoNTAK/Scripts/main.lua", "RoNTAK/mod/RoNTAK/enabled.txt",
                         "RoNTAK/mod/RoNTAK/bridge/.keep", "RoNTAK/companion/server.py",
                         "RoNTAK/companion/gamefinder.py", "RoNTAK/companion/web/index.html",
                         "RoNTAK/docs/01-setup.md"):
            self.assertIn(expected, names)
        self.assertFalse(any("/tests/" in n or "__pycache__" in n or n.endswith("settings.json") for n in names))
        self.assertNotIn("RoNTAK/mod/RoNTAK/bridge/state.json", names)

    def test_batch_files_keep_windows_line_endings(self):
        for name in ("Install RoNTAK.bat", "Start RoNTAK.bat"):
            data = (ROOT / name).read_bytes()
            self.assertIn(b"\r\n", data)
            self.assertNotIn(b"/dev/null", data)
            self.assertEqual(data.count(b"\n"), data.count(b"\r\n"), name)


if __name__ == "__main__":
    unittest.main()
