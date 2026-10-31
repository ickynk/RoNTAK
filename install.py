"""Installs (or updates) the RoNTAK mod into Ready or Not.

Run "Install RoNTAK.bat", or:  python install.py [game folder]

1. Finds Ready or Not through Steam (or asks for the folder).
2. Checks that UE4SS is installed; offers to download and install it (or
   update it) from UE4SS's GitHub releases.
3. Copies mod/RoNTAK into UE4SS's Mods folder. Files in the mod's bridge
   folder are kept; a config.lua you edited is backed up as config.lua.bak.
4. Saves the bridge folder for "Start RoNTAK.bat".
"""

import filecmp
import io
import json
import re
import shutil
import sys
import time
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

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


# UE4SS --------------------------------------------------------------------------

# Newest first: the rolling experimental build supports current Unreal Engine 5
# games; the last stable release is the fallback.
UE4SS_RELEASE_APIS = (
    "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest",
    "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/latest",
)
# The main download, e.g. UE4SS_v3.0.1-394-g437a8ff.zip (not zDEV-..., zCustomGameConfigs...).
UE4SS_ASSET = re.compile(r"^UE4SS_v[^/]*\.zip$")
# Your own UE4SS settings and mod list are kept when updating.
UE4SS_KEEP = {"ue4ss/UE4SS-settings.ini", "ue4ss/Mods/mods.txt", "ue4ss/Mods/mods.json"}


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "RoNTAK-installer"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def ask_yes_no(question: str, default: bool = False) -> bool:
    hint = "Y/n" if default else "y/N"
    answer = input(f"{question} ({hint}) > ").strip().lower()
    return default if not answer else answer.startswith("y")


def find_ue4ss_release():
    """(version, file name, download URL) of the newest UE4SS, or None."""
    for api in UE4SS_RELEASE_APIS:
        try:
            release = json.loads(fetch(api))
        except (OSError, ValueError):
            continue
        for asset in release.get("assets", []):
            if UE4SS_ASSET.match(asset.get("name", "")):
                return release.get("tag_name") or asset["name"], asset["name"], asset["browser_download_url"]
    return None


def backup_ue4ss(win64: Path) -> Path:
    """Zips the current UE4SS files (loader DLL and the ue4ss folder, without mods)."""
    backup = win64 / f"ue4ss_backup_{time.strftime('%Y%m%d_%H%M%S')}.zip"
    with zipfile.ZipFile(backup, "w", zipfile.ZIP_DEFLATED) as z:
        if (win64 / "dwmapi.dll").is_file():
            z.write(win64 / "dwmapi.dll", "dwmapi.dll")
        for f in (win64 / "ue4ss").rglob("*"):
            rel = f.relative_to(win64)
            if f.is_file() and rel.parts[:2] != ("ue4ss", "Mods"):
                z.write(f, rel.as_posix())
    return backup


def extract_ue4ss(data: bytes, win64: Path) -> list:
    """Extracts a UE4SS release zip into Win64. Files in UE4SS_KEEP that
    already exist are left alone. Returns the kept files."""
    kept = []
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        if "dwmapi.dll" not in names and "ue4ss/UE4SS.dll" not in names:
            raise ValueError("this doesn't look like a UE4SS release (no dwmapi.dll / ue4ss/UE4SS.dll)")
        for name in names:
            rel = PurePosixPath(name)
            if rel.is_absolute() or ".." in rel.parts:
                raise ValueError(f"unsafe path in the zip: {name}")
            dest = win64.joinpath(*rel.parts)
            if name in UE4SS_KEEP and dest.exists():
                kept.append(name)
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(z.read(name))
    return kept


def get_ue4ss(win64: Path, update: bool) -> bool:
    """Downloads the newest UE4SS and installs it into win64."""
    print("  Looking up the newest UE4SS on GitHub...")
    release = find_ue4ss_release()
    if not release:
        print("  Couldn't reach GitHub. Check your internet connection, or install UE4SS by hand.")
        return False
    version, name, url = release
    print(f"  Downloading {name} ({version})...")
    try:
        data = fetch(url)
    except OSError as e:
        print(f"  Download failed: {e}")
        return False
    if update:
        print(f"  Backed up your current UE4SS to {backup_ue4ss(win64)}")
    try:
        kept = extract_ue4ss(data, win64)
    except (ValueError, zipfile.BadZipFile, OSError) as e:
        print(f"  Couldn't install UE4SS: {e}")
        return False
    for name in kept:
        print(f"  Kept your {name}")
    print(f"  UE4SS {version} installed into {win64}")
    return True


def manual_ue4ss_steps(win64: Path):
    print(f"  1. Download the newest UE4SS zip from {UE4SS_RELEASES}")
    print(f"  2. Extract everything into: {win64}")
    print("  3. Run this installer again.")


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
        print("\nUE4SS (the mod loader RoNTAK runs in) is not installed yet.")
        if not ask_yes_no("Download and install the newest UE4SS now?", default=True) or not get_ue4ss(win64, update=False):
            print("\nTo install UE4SS yourself:")
            manual_ue4ss_steps(win64)
            return 1
    else:
        print("UE4SS: installed")
        if not (win64 / "ue4ss").is_dir():
            # Older UE4SS (UE4SS.dll and Mods directly in Win64): a new one on top
            # would mean two loaders, so it is only replaced by hand.
            print("  (Older UE4SS layout: to update it, remove its files from Win64 first, then run this again.)")
        elif ask_yes_no("Update UE4SS to the newest version? Only needed if a game update broke it; "
                        "your UE4SS settings and mod list are kept, and the old version is backed up"):
            get_ue4ss(win64, update=True)

    target = install(win64)
    print(f"\nInstalled RoNTAK into {target}")
    print("Next: start the game, then double-click \"Start RoNTAK.bat\".")
    return 0


if __name__ == "__main__":
    code = main()
    sys.exit(code)
