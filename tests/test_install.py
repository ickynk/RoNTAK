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


# The real UE4SS_v3.0.1.zip layout (flat), trimmed.
UE4SS_ZIP = make_zip({
    "dwmapi.dll": "new loader",
    "UE4SS.dll": "new ue4ss",
    "UE4SS-settings.ini": "default settings",
    "README.md": "readme",
    "Mods/mods.txt": "; built-in mods\nBPModLoaderMod : 1\nKeybinds : 1\nNewBuiltIn : 1\n",
    "Mods/Keybinds/Scripts/main.lua": "new keybinds",
    "Mods/shared/UEHelpers/UEHelpers.lua": "new helpers",
})
# A later build that keeps UE4SS in a ue4ss folder.
NESTED_ZIP = make_zip({
    "dwmapi.dll": "nested loader",
    "ue4ss/UE4SS.dll": "nested ue4ss",
    "ue4ss/UE4SS-settings.ini": "nested settings",
    "ue4ss/Mods/mods.txt": "Keybinds : 1\n",
    "ue4ss/Mods/Keybinds/Scripts/main.lua": "nested keybinds",
})


def add_mods(mods_folder: Path, mods: dict, mods_txt: str = None):
    for mod, text in mods.items():
        (mods_folder / mod / "Scripts").mkdir(parents=True, exist_ok=True)
        (mods_folder / mod / "Scripts" / "main.lua").write_text(text)
    if mods_txt is not None:
        (mods_folder / "mods.txt").write_text(mods_txt)


def release(tag, prerelease=False):
    assets = [f"zDEV-UE4SS_{tag}.zip", "zCustomGameConfigs.zip", f"UE4SS_{tag}.zip"]
    return {"tag_name": tag, "prerelease": prerelease, "draft": False,
            "assets": [{"name": a, "browser_download_url": "https://example/" + a} for a in assets]}


def fake_github(releases=None):
    """Stands in for install.fetch: GitHub's release list and the download."""
    releases = releases or [release("experimental-latest", True), release("v3.0.1"), release("v3.0.0"),
                            release("v2.5.2")]

    def fetch(url):
        if url == install.UE4SS_RELEASES_API:
            return json.dumps(releases).encode()
        assert url == "https://example/UE4SS_v3.0.1.zip", url
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
        # A leftover ue4ss folder without UE4SS.dll in it doesn't count.
        (old / "ue4ss" / "Mods").mkdir(parents=True)
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
        self.assertEqual((bare / "UE4SS.dll").read_text(), "new ue4ss")
        # 3.0.x is flat: RoNTAK goes in Win64/Mods, where UE4SS 3.0.1 looks.
        self.assertTrue((bare / "Mods" / "RoNTAK" / "Scripts" / "main.lua").is_file())
        self.assertFalse((bare / "ue4ss").exists())

    def test_ue4ss_release_is_the_newest_stable_3_0_x(self):
        install.fetch = fake_github()
        self.assertEqual(install.find_ue4ss_release()[:2], ("v3.0.1", "UE4SS_v3.0.1.zip"))
        # Later series, pre-releases and experimental builds are passed over.
        install.fetch = fake_github([release("v4.0.0"), release("v3.1.0"), release("v3.0.9", prerelease=True),
                                     release("v3.0.10"), release("v3.0.2"), release("experimental-latest", True)])
        self.assertEqual(install.find_ue4ss_release()[:2], ("v3.0.10", "UE4SS_v3.0.10.zip"))
        install.fetch = fake_github([release("v4.0.0"), release("experimental-latest", True)])
        self.assertIsNone(install.find_ue4ss_release())

    def test_merge_mod_lists_keeps_choices_and_added_mods(self):
        new = "; built-in mods\nBPModLoaderMod : 1\nKeybinds : 1\nNewBuiltIn : 1\n"
        old = "BPModLoaderMod : 1\nKeybinds : 0\nRoNTAK : 1\nMyMod : 0\n"
        self.assertEqual(install.merge_mod_lists(new, old),
                         "; built-in mods\nBPModLoaderMod : 1\nKeybinds : 0\nNewBuiltIn : 1\nRoNTAK : 1\nMyMod : 0\n")

    def test_update_from_2x_replaces_ue4ss_and_keeps_added_mods(self):
        win64 = make_game(self.tmp / "old", "old")             # 2.x: UE4SS.dll and xinput1_3.dll in Win64
        (win64 / "xinput1_3.dll").write_text("old proxy")
        (win64 / "UE4SS-settings.ini").write_text("old 2.x settings")
        add_mods(win64 / "Mods", {"RoNTAK": "rontak", "MyMod": "mine", "Keybinds": "old keybinds"},
                 "Keybinds : 0\nRoNTAK : 1\nMyMod : 1\n")
        (win64 / "Mods" / "RoNTAK" / "bridge").mkdir()
        (win64 / "Mods" / "RoNTAK" / "bridge" / "rooms.json").write_text("{}")
        install.fetch = fake_github()
        self.assertTrue(install.get_ue4ss(win64, update=True))
        mods = win64 / "Mods"
        self.assertFalse((win64 / "xinput1_3.dll").exists())  # one loader only
        self.assertEqual((win64 / "dwmapi.dll").read_text(), "new loader")
        self.assertEqual((win64 / "UE4SS.dll").read_text(), "new ue4ss")
        self.assertEqual((win64 / "UE4SS-settings.ini").read_text(), "default settings")  # 2.x settings replaced
        # Added mods untouched where they were; built-ins are the new versions.
        self.assertEqual((mods / "MyMod" / "Scripts" / "main.lua").read_text(), "mine")
        self.assertEqual((mods / "RoNTAK" / "bridge" / "rooms.json").read_text(), "{}")
        self.assertEqual((mods / "Keybinds" / "Scripts" / "main.lua").read_text(), "new keybinds")
        self.assertEqual((mods / "mods.txt").read_text(),
                         "; built-in mods\nBPModLoaderMod : 1\nKeybinds : 0\nNewBuiltIn : 1\nRoNTAK : 1\nMyMod : 1\n")
        self.assertFalse((win64 / "ue4ss").exists())
        self.assertEqual(gamefinder.mods_dir(win64), mods)
        with zipfile.ZipFile(next(win64.glob("ue4ss_backup_*.zip"))) as z:
            self.assertTrue({"UE4SS.dll", "xinput1_3.dll", "UE4SS-settings.ini", "Mods/MyMod/Scripts/main.lua",
                             "Mods/mods.txt"} <= set(z.namelist()))

    def test_update_same_version_keeps_settings_and_mods(self):
        win64 = make_game(self.tmp / "same", None)
        for name, text in (("dwmapi.dll", "loader"), ("UE4SS.dll", "ue4ss"), ("UE4SS-settings.ini", "my settings")):
            (win64 / name).write_text(text)
        add_mods(win64 / "Mods", {"RoNTAK": "rontak"}, "RoNTAK : 1\n")
        install.fetch = fake_github()
        self.assertTrue(install.get_ue4ss(win64, update=True))
        self.assertEqual((win64 / "UE4SS-settings.ini").read_text(), "my settings")
        self.assertEqual((win64 / "UE4SS.dll").read_text(), "new ue4ss")
        self.assertEqual((win64 / "Mods" / "RoNTAK" / "Scripts" / "main.lua").read_text(), "rontak")
        self.assertIn("RoNTAK : 1", (win64 / "Mods" / "mods.txt").read_text())

    def test_moving_between_flat_and_nested_layouts(self):
        # From a nested build to the flat 3.0.x: mods move to Win64/Mods, the ue4ss folder goes.
        win64 = self.win64                                      # nested: ue4ss/UE4SS.dll
        add_mods(win64 / "ue4ss" / "Mods", {"RoNTAK": "rontak"}, "RoNTAK : 1\n")
        self.assertEqual(install.extract_ue4ss(UE4SS_ZIP, win64)[-1], f"Moved 1 mod folder(s) to {win64 / 'Mods'}: RoNTAK")
        self.assertFalse((win64 / "ue4ss").exists())
        self.assertEqual((win64 / "Mods" / "RoNTAK" / "Scripts" / "main.lua").read_text(), "rontak")
        self.assertIn("RoNTAK : 1", (win64 / "Mods" / "mods.txt").read_text())
        # And back to a nested build.
        install.extract_ue4ss(NESTED_ZIP, win64)
        self.assertFalse((win64 / "UE4SS.dll").exists() or (win64 / "Mods").exists())
        self.assertEqual((win64 / "ue4ss" / "Mods" / "RoNTAK" / "Scripts" / "main.lua").read_text(), "rontak")
        self.assertEqual(gamefinder.mods_dir(win64), win64 / "ue4ss" / "Mods")

    def test_repairs_mods_moved_into_ue4ss_folder_by_mistake(self):
        """What the previous installer did with UE4SS 3.0.1: flat UE4SS, but mods in Win64/ue4ss/Mods."""
        win64 = make_game(self.tmp / "broken", None)
        for name in ("dwmapi.dll", "UE4SS.dll", "UE4SS-settings.ini"):
            (win64 / name).write_text("3.0.1")
        add_mods(win64 / "ue4ss" / "Mods", {"RoNTAK": "rontak", "MyMod": "mine", "Keybinds": "keybinds"})
        with zipfile.ZipFile(win64 / "ue4ss_backup_20261031_184500.zip", "w") as z:
            z.writestr("Mods/mods.txt", "Keybinds : 1\nRoNTAK : 1\nMyMod : 1\n")
        notes = install.repair_misplaced_mods(win64)
        self.assertEqual(notes[0], "Repaired your UE4SS mods folder:")
        self.assertFalse((win64 / "ue4ss").exists())
        for mod in ("RoNTAK", "MyMod", "Keybinds"):
            self.assertTrue((win64 / "Mods" / mod / "Scripts" / "main.lua").is_file(), mod)
        self.assertEqual((win64 / "Mods" / "mods.txt").read_text(), "Keybinds : 1\nRoNTAK : 1\nMyMod : 1\n")
        self.assertEqual(gamefinder.mods_dir(win64), win64 / "Mods")
        self.assertEqual(install.repair_misplaced_mods(win64), [])  # nothing left to repair
        # The installer then puts RoNTAK in Win64/Mods and points the companion there.
        install.install(win64)
        self.assertEqual(gamefinder.load_settings()["bridge"], str(win64 / "Mods" / "RoNTAK" / "bridge"))

    def test_main_repairs_before_installing(self):
        win64 = make_game(self.tmp / "broken", None)
        for name in ("dwmapi.dll", "UE4SS.dll"):
            (win64 / name).write_text("3.0.1")
        add_mods(win64 / "ue4ss" / "Mods", {"RoNTAK": "rontak"})
        install.ask_yes_no = lambda question, default=False: False  # no UE4SS update
        self.assertEqual(install.main([str(win64)]), 0)
        self.assertTrue((win64 / "Mods" / "RoNTAK" / "Scripts" / "main.lua").is_file())
        self.assertFalse((win64 / "ue4ss").exists())

    def test_ue4ss_zip_with_unsafe_paths_is_refused(self):
        with self.assertRaises(ValueError):
            install.extract_ue4ss(make_zip({"dwmapi.dll": "x", "../evil.txt": "x"}), self.tmp / "w")
        with self.assertRaises(ValueError):
            install.extract_ue4ss(make_zip({"readme.txt": "not ue4ss"}), self.tmp / "w")
        with self.assertRaises(ValueError):
            install.extract_ue4ss(make_zip({"UE4SS.dll": "x", "/abs/evil.txt": "x"}), self.tmp / "w")

    def test_main_installs(self):
        install.ask_yes_no = lambda question, default=False: False  # no UE4SS update
        self.assertEqual(install.main([str(self.win64)]), 0)


if __name__ == "__main__":
    unittest.main()
