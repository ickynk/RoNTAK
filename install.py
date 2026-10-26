"""Installs (or updates) the RoNTAK mod into Ready or Not.

Run "Install RoNTAK.bat", or:  python install.py [game folder]

1. Finds Ready or Not through Steam (or asks for the folder).
2. Checks that UE4SS is installed.
3. Copies mod/RoNTAK into UE4SS's Mods folder. Files in the mod's bridge
   folder are kept; a config.lua you edited is backed up as config.lua.bak.
4. Saves the bridge folder for "Start RoNTAK.bat".
"""

import filecmp
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "companion"))
import gamefinder  # noqa: E402

MOD_SOURCE = HERE / "mod" / gamefinder.MOD_NAME
UE4SS_RELEASES = "https://github.com/UE4SS-RE/RE-UE4SS/releases"


def copy_mod(target: Path) -> list:
    """Copies the mod into target (…/Mods/RoNTAK). Returns notes for the user."""
    notes = []
    for source in MOD_SOURCE.rglob("*"):
        rel = source.relative_to(MOD_SOURCE)
        if rel.parts[0] == "bridge" or "__pycache__" in rel.parts:
            continue
        dest = target / rel
        if source.is_dir():
            dest.mkdir(parents=True, exist_ok=True)
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        if rel.name == "config.lua" and dest.exists() and not filecmp.cmp(source, dest, shallow=False):
            shutil.copy2(dest, dest.with_name("config.lua.bak"))
            notes.append(f"Your edited config.lua was saved as {dest.with_name('config.lua.bak')}")
        shutil.copy2(source, dest)
    (target / "bridge").mkdir(parents=True, exist_ok=True)
    return notes


def install(win64: Path) -> Path:
    target = gamefinder.mods_dir(win64) / gamefinder.MOD_NAME
    for note in copy_mod(target):
        print("  " + note)
    bridge = target / "bridge"
    gamefinder.save_settings(bridge=str(bridge))
    return target


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    print("RoNTAK installer\n")

    win64 = gamefinder.win64_from(argv[0]) if argv else gamefinder.find_win64()
    while not win64:
        answer = gamefinder.ask_path(
            "Couldn't find Ready or Not. Paste the game's folder (Steam: right-click Ready or Not >\n"
            "Manage > Browse local files, then copy the address bar), or leave empty to cancel:")
        if not answer:
            return 1
        win64 = gamefinder.win64_from(answer)
        if not win64:
            print(f"  No Ready or Not program (ReadyOrNot...-Win64-Shipping.exe) found in: {answer}")
            exes = gamefinder.shipping_exes(answer)
            if exes:
                print("  Found instead: " + ", ".join(exes))
                print("  Please tell the RoNTAK developer this name.")
            else:
                print("  Paste the folder that holds ReadyOrNot.exe (the one Steam's Browse local files opens).")
            print()
    print(f"Ready or Not: {win64}")

    if not gamefinder.ue4ss_installed(win64):
        print("\nUE4SS is not installed yet. RoNTAK needs it to run inside the game.")
        print(f"  1. Download the latest UE4SS zip from {UE4SS_RELEASES}")
        print(f"  2. Extract everything into: {win64}")
        print("  3. Run this installer again.")
        return 1
    print("UE4SS: installed")

    target = install(win64)
    print(f"\nInstalled RoNTAK into {target}")
    print("Next: start the game, then double-click \"Start RoNTAK.bat\".")
    return 0


if __name__ == "__main__":
    code = main()
    sys.exit(code)
