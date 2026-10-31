"""Tests for finding the game (companion/gamefinder.py) and installing the mod (install.py)."""

import io
import json
import sys
import tempfile
import zipfile
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
    (win64 / "ReadyOrNot-Win64-Shipping.exe").write_text("")
    if ue4ss == "3.x":
        (win64 / "ue4ss").mkdir()
        (win64 / "ue4ss" / "UE4SS.dll").write_text("")
    elif ue4ss == "old":
        (win64 / "UE4SS.dll").write_text("")
    return win64


def make_zip(files: dict) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, text in files.items():
            z.writestr(name, text)
    return buf.getvalue()


UE4SS_ZIP = make_zip({
    "dwmapi.dll": "new loader",
    "ue4ss/UE4SS.dll": "new ue4ss",
    "ue4ss/UE4SS-settings.ini": "default settings",
    "ue4ss/Mods/mods.txt": "default mods",
})


def fake_github(experimental=True):
    """Stands in for install.fetch: GitHub's release API and the download."""
    def release(tag, assets):
        return json.dumps({"tag_name": tag, "assets": [
            {"name": a, "browser_download_url": "https://example/" + a} for a in assets]}).encode()

    def fetch(url):
        if url.endswith("experimental-latest"):
            if not experimental:
                raise OSError("404")
            return release("experimental-latest", ["zDEV-UE4SS_v3.0.1-400-gabc.zip", "UE4SS_v3.0.1-400-gabc.zip"])
        if url.endswith("/latest"):
            return release("v3.0.1", ["zCustomGameConfigs.zip", "UE4SS_v3.0.1.zip"])
        return UE4SS_ZIP
    return fetch


class GameFinderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        gamefinder.SETTINGS_FILE = self.tmp / "settings.json"
        # Tests swap in fake questions and downloads; never the real ones.
        real = (install.ask_yes_no, install.fetch)
        install.ask_yes_no = lambda question, default=False: self.fail("unexpected question: " + question)
        install.fetch = lambda url: self.fail("unexpected download: " + url)
        self.addCleanup(lambda: setattr(install, "ask_yes_no", real[0]) or setattr(install, "fetch", real[1]))

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

    def test_other_exe_names_and_pasted_exe(self):
        win64 = self.tmp / "Ready Or Not" / "ReadyOrNot" / "Binaries" / "Win64"
        win64.mkdir(parents=True)
        exe = win64 / "ReadyOrNotSteam-Win64-Shipping.exe"
        exe.write_text("")
        for pasted in (win64, self.tmp / "Ready Or Not", exe, f'"{win64}"'):
            self.assertEqual(gamefinder.win64_from(pasted), win64, pasted)
        # A different project folder name is found too.
        other = self.tmp / "g2" / "RON" / "Binaries" / "Win64"
        other.mkdir(parents=True)
        (other / "ReadyOrNot-Win64-Shipping.exe").write_text("")
        self.assertEqual(gamefinder.win64_from(self.tmp / "g2"), other)

    def test_unknown_exe_is_reported(self):
        win64 = self.tmp / "game" / "Proj" / "Binaries" / "Win64"
        win64.mkdir(parents=True)
        (win64 / "Something-Win64-Shipping.exe").write_text("")
        self.assertIsNone(gamefinder.win64_from(self.tmp / "game"))
        self.assertEqual([Path(p).name for p in gamefinder.shipping_exes(self.tmp / "game")],
                         ["Something-Win64-Shipping.exe"])

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
        # Tests swap in fake questions and downloads; never the real ones.
        real = (install.ask_yes_no, install.fetch)
        install.ask_yes_no = lambda question, default=False: self.fail("unexpected question: " + question)
        install.fetch = lambda url: self.fail("unexpected download: " + url)
        self.addCleanup(lambda: setattr(install, "ask_yes_no", real[0]) or setattr(install, "fetch", real[1]))
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
        install.ask_yes_no = lambda question, default=False: False  # "no" to downloading UE4SS
        self.assertEqual(install.main([str(bare)]), 1)
        self.assertFalse((bare / "Mods").exists())

    def test_main_downloads_ue4ss_when_missing(self):
        bare = make_game(self.tmp / "bare", None)
        install.ask_yes_no = lambda question, default=False: True
        install.fetch = fake_github()
        self.assertEqual(install.main([str(bare)]), 0)
        self.assertTrue((bare / "dwmapi.dll").is_file())
        self.assertTrue((bare / "ue4ss" / "Mods" / "RoNTAK" / "Scripts" / "main.lua").is_file())

    def test_ue4ss_release_picks_main_zip_and_falls_back_to_stable(self):
        install.fetch = fake_github(experimental=False)
        version, name, url = install.find_ue4ss_release()
        self.assertEqual((version, name), ("v3.0.1", "UE4SS_v3.0.1.zip"))
        install.fetch = fake_github()
        self.assertEqual(install.find_ue4ss_release()[1], "UE4SS_v3.0.1-400-gabc.zip")

    def test_ue4ss_update_keeps_settings_and_backs_up(self):
        win64 = self.win64
        (win64 / "dwmapi.dll").write_text("old loader")
        (win64 / "ue4ss" / "UE4SS-settings.ini").write_text("my settings")
        (win64 / "ue4ss" / "Mods").mkdir(parents=True, exist_ok=True)
        (win64 / "ue4ss" / "Mods" / "mods.txt").write_text("my mods")
        install.fetch = fake_github()
        self.assertTrue(install.get_ue4ss(win64, update=True))
        self.assertEqual((win64 / "dwmapi.dll").read_text(), "new loader")
        self.assertEqual((win64 / "ue4ss" / "UE4SS-settings.ini").read_text(), "my settings")
        self.assertEqual((win64 / "ue4ss" / "Mods" / "mods.txt").read_text(), "my mods")
        backups = list(win64.glob("ue4ss_backup_*.zip"))
        self.assertEqual(len(backups), 1)
        with zipfile.ZipFile(backups[0]) as z:
            self.assertIn("dwmapi.dll", z.namelist())

    def test_ue4ss_zip_with_unsafe_paths_is_refused(self):
        with self.assertRaises(ValueError):
            install.extract_ue4ss(make_zip({"dwmapi.dll": "x", "../evil.txt": "x"}), self.tmp / "w")
        with self.assertRaises(ValueError):
            install.extract_ue4ss(make_zip({"readme.txt": "not ue4ss"}), self.tmp / "w")

    def test_main_installs(self):
        install.ask_yes_no = lambda question, default=False: False  # no UE4SS update
        self.assertEqual(install.main([str(self.win64)]), 0)


if __name__ == "__main__":
    unittest.main()
