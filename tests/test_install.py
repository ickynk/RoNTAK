"""Tests for finding the game (companion/gamefinder.py) and installing the mod (install.py)."""

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "companion"))
sys.path.insert(0, str(ROOT))
import gamefinder  # noqa: E402
import install  # noqa: E402

VDF = r'''
"libraryfolders"
{
	"0"
	{
		"path"		"C:\\Program Files (x86)\\Steam"
		"apps" { "228980" "1" }
	}
	"1"
	{
		"path"		"D:\\SteamLibrary"
		"apps" { "1144200" "1" }
	}
}
'''


def make_game(library: Path, ue4ss: str = "3.x") -> Path:
    win64 = library / gamefinder.GAME_FOLDER / gamefinder.WIN64
    win64.mkdir(parents=True)
    (win64 / gamefinder.GAME_EXE).write_text("")
    if ue4ss == "3.x":
        (win64 / "ue4ss").mkdir()
        (win64 / "ue4ss" / "UE4SS.dll").write_text("")
    elif ue4ss == "old":
        (win64 / "UE4SS.dll").write_text("")
    return win64


class GameFinderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        gamefinder.SETTINGS_FILE = self.tmp / "settings.json"

    def test_library_folders(self):
        self.assertEqual(gamefinder.library_folders(VDF),
                         [Path("C:\\Program Files (x86)\\Steam"), Path("D:\\SteamLibrary")])

    def test_steam_libraries_reads_vdf(self):
        root = self.tmp / "Steam"
        (root / "steamapps").mkdir(parents=True)
        (root / "steamapps" / "libraryfolders.vdf").write_text(VDF)
        libs = gamefinder.steam_libraries(root)
        self.assertEqual(libs[:3], [root, Path("C:\\Program Files (x86)\\Steam"), Path("D:\\SteamLibrary")])

    def test_find_game_in_second_library(self):
        win64 = make_game(self.tmp / "lib2")
        self.assertEqual(gamefinder.find_win64([self.tmp / "lib1", self.tmp / "lib2"]), win64)
        self.assertIsNone(gamefinder.find_win64([self.tmp / "lib1"]))

    def test_win64_from_any_folder_the_user_pastes(self):
        win64 = make_game(self.tmp / "lib")
        game = self.tmp / "lib" / gamefinder.GAME_FOLDER
        for pasted in (win64, game, game / "ReadyOrNot"):
            self.assertEqual(gamefinder.win64_from(pasted), win64, pasted)
        self.assertIsNone(gamefinder.win64_from(self.tmp))

    def test_ue4ss_layouts(self):
        new = make_game(self.tmp / "a", "3.x")
        old = make_game(self.tmp / "b", "old")
        none = make_game(self.tmp / "c", None)
        self.assertEqual(gamefinder.mods_dir(new), new / "ue4ss" / "Mods")
        self.assertEqual(gamefinder.mods_dir(old), old / "Mods")
        self.assertTrue(gamefinder.ue4ss_installed(new) and gamefinder.ue4ss_installed(old))
        self.assertFalse(gamefinder.ue4ss_installed(none))

    def test_settings(self):
        self.assertEqual(gamefinder.load_settings(), {})
        gamefinder.save_settings(lan=True)
        gamefinder.save_settings(bridge="X")
        self.assertEqual(gamefinder.load_settings(), {"lan": True, "bridge": "X"})


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        gamefinder.SETTINGS_FILE = self.tmp / "settings.json"
        self.win64 = make_game(self.tmp / "lib")

    def test_install_copies_mod_and_saves_bridge(self):
        target = install.install(self.win64)
        self.assertEqual(target, self.win64 / "ue4ss" / "Mods" / "RoNTAK")
        self.assertTrue((target / "Scripts" / "main.lua").is_file())
        self.assertTrue((target / "enabled.txt").is_file())
        self.assertTrue((target / "bridge").is_dir())
        self.assertEqual(gamefinder.load_settings()["bridge"], str(target / "bridge"))

    def test_update_keeps_bridge_files_and_backs_up_edited_config(self):
        target = install.install(self.win64)
        (target / "bridge" / "state.json").write_text("{}")
        config = target / "Scripts" / "config.lua"
        config.write_text(config.read_text() + "\n-- my change\n")
        notes = install.copy_mod(target)
        self.assertTrue((target / "bridge" / "state.json").is_file())
        self.assertIn("-- my change", (target / "Scripts" / "config.lua.bak").read_text())
        self.assertNotIn("-- my change", config.read_text())
        self.assertEqual(len(notes), 1)

    def test_unchanged_config_is_not_backed_up(self):
        target = install.install(self.win64)
        self.assertEqual(install.copy_mod(target), [])
        self.assertFalse((target / "Scripts" / "config.lua.bak").exists())

    def test_main_stops_without_ue4ss(self):
        bare = make_game(self.tmp / "bare", None)
        self.assertEqual(install.main([str(bare)]), 1)
        self.assertFalse((bare / "Mods").exists())

    def test_main_installs(self):
        self.assertEqual(install.main([str(self.win64)]), 0)


if __name__ == "__main__":
    unittest.main()
