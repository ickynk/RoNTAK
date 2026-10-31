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

# UE4SS releases; the newest stable 3.0.x is used: the line recommended for
# Ready or Not since its move to Unreal Engine 5. Change UE4SS_SERIES to move on.
UE4SS_RELEASES_API = "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases?per_page=100"
UE4SS_SERIES = re.compile(r"^v?3\.0\.(\d+)$")
# The main download, e.g. UE4SS_v3.0.1.zip (not zDEV-..., zCustomGameConfigs.zip...).
UE4SS_ASSET = re.compile(r"^UE4SS_v[^/]*\.zip$")
# Kept as they are when updating (your own UE4SS settings).
UE4SS_KEEP = {"ue4ss/UE4SS-settings.ini"}
MODS_LIST = "ue4ss/Mods/mods.txt"
# UE4SS 2.x kept everything directly in Win64: these are its loader files,
# removed when it is replaced (only if UE4SS.dll is there, so it is UE4SS's).
OLD_LOADER_FILES = ("UE4SS.dll", "xinput1_3.dll", "UE4SS.pdb", "UE4SS-settings.ini", "UE4SS.log")


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "RoNTAK-installer"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def ask_yes_no(question: str, default: bool = False) -> bool:
    hint = "Y/n" if default else "y/N"
    answer = input(f"{question} ({hint}) > ").strip().lower()
    return default if not answer else answer.startswith("y")


def find_ue4ss_release():
    """(version, file name, download URL) of the newest stable UE4SS 3.0.x, or None."""
    try:
        releases = json.loads(fetch(UE4SS_RELEASES_API))
    except (OSError, ValueError):
        return None
    best = None
    for release in releases if isinstance(releases, list) else []:
        tag = release.get("tag_name", "")
        match = UE4SS_SERIES.match(tag)
        if not match or release.get("prerelease") or release.get("draft"):
            continue
        asset = next((a for a in release.get("assets", []) if UE4SS_ASSET.match(a.get("name", ""))), None)
        if asset and (best is None or int(match.group(1)) > best[0]):
            best = (int(match.group(1)), tag, asset["name"], asset["browser_download_url"])
    return best[1:] if best else None


def old_layout(win64: Path) -> bool:
    """UE4SS 2.x: UE4SS.dll and Mods directly in Win64, no ue4ss folder."""
    return (win64 / "UE4SS.dll").is_file() and not (win64 / "ue4ss").is_dir()


def backup_ue4ss(win64: Path) -> Path:
    """Zips the current UE4SS: loader files, settings and the Mods folder."""
    backup = win64 / f"ue4ss_backup_{time.strftime('%Y%m%d_%H%M%S')}.zip"
    files = [win64 / name for name in OLD_LOADER_FILES + ("dwmapi.dll",)]
    for folder in (win64 / "ue4ss", win64 / "Mods"):
        if folder.is_dir():
            files += [f for f in folder.rglob("*") if "bridge" not in f.relative_to(win64).parts]
    with zipfile.ZipFile(backup, "w", zipfile.ZIP_DEFLATED) as z:
        for f in files:
            if f.is_file():
                z.write(f, f.relative_to(win64).as_posix())
    return backup


def mod_name(line: str):
    """"RoNTAK : 1" -> "RoNTAK"; None for comments and blank lines."""
    line = line.strip()
    if not line or line.startswith(";") or ":" not in line:
        return None
    return line.split(":", 1)[0].strip()


def merge_mod_lists(new_text: str, old_text: str) -> str:
    """The new mods.txt, keeping your on/off choice for mods in both and
    adding the mods only your old list has."""
    old = {mod_name(l): l.strip() for l in old_text.splitlines() if mod_name(l)}
    lines, seen = [], set()
    for line in new_text.splitlines():
        name = mod_name(line)
        if name:
            seen.add(name)
        lines.append(old.get(name, line.rstrip()) if name else line.rstrip())
    extra = [l for n, l in old.items() if n not in seen]
    return "\n".join(lines + extra) + "\n"


def extract_ue4ss(data: bytes, win64: Path, old_mods_list: "str | None" = None) -> list:
    """Extracts a UE4SS release zip into Win64. Your UE4SS settings are kept,
    mods.txt is merged with yours, other files are replaced. Returns notes."""
    notes = []
    mods_list = win64 / "ue4ss" / "Mods" / "mods.txt"
    if old_mods_list is None and mods_list.is_file():
        old_mods_list = mods_list.read_text(encoding="utf-8", errors="replace")
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        if "dwmapi.dll" not in names and "ue4ss/UE4SS.dll" not in names:
            raise ValueError("this doesn't look like a UE4SS release (no dwmapi.dll / ue4ss/UE4SS.dll)")
        for name in names:
            rel = PurePosixPath(name)
            if rel.is_absolute() or ".." in rel.parts:
                raise ValueError(f"unsafe path in the zip: {name}")
        for name in names:
            dest = win64.joinpath(*PurePosixPath(name).parts)
            if name in UE4SS_KEEP and dest.exists():
                notes.append(f"Kept your {name}")
                continue
            data_out = z.read(name)
            if name == MODS_LIST and old_mods_list:
                data_out = merge_mod_lists(data_out.decode("utf-8", errors="replace"), old_mods_list).encode("utf-8")
                notes.append("Merged your mod list into the new mods.txt")
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data_out)
    return notes


def migrate_old_mods(win64: Path) -> list:
    """After replacing a UE4SS 2.x: moves the mods you added from Win64/Mods into
    ue4ss/Mods (UE4SS's own mods there are now the new versions) and removes
    the old folder's leftovers (they are in the backup)."""
    notes = []
    old, new = win64 / "Mods", win64 / "ue4ss" / "Mods"
    if not old.is_dir():
        return notes
    for child in sorted(old.iterdir()):
        if child.is_dir() and not (new / child.name).exists():
            shutil.move(str(child), str(new / child.name))
            notes.append(f"Moved your mod {child.name} to {new}")
    shutil.rmtree(old, ignore_errors=True)
    return notes


def get_ue4ss(win64: Path, update: bool) -> bool:
    """Downloads the latest stable UE4SS and installs it into win64. An existing
    UE4SS is backed up first; an old (2.x) one is replaced, keeping your mods."""
    print("  Looking up the latest UE4SS 3.0.x release on GitHub...")
    release = find_ue4ss_release()
    if not release:
        print("  Couldn't reach GitHub. Check your internet connection, or install UE4SS by hand.")
        return False
    version, name, url = release
    print(f"  Downloading {name} ({version})...")
    try:
        data = fetch(url)
        zipfile.ZipFile(io.BytesIO(data)).testzip()
    except (OSError, zipfile.BadZipFile) as e:
        print(f"  Download failed: {e}")
        return False
    migrating = old_layout(win64)
    old_mods_list = None
    if update:
        print(f"  Backed up your current UE4SS to {backup_ue4ss(win64)}")
    if migrating:
        old_list = win64 / "Mods" / "mods.txt"
        old_mods_list = old_list.read_text(encoding="utf-8", errors="replace") if old_list.is_file() else None
        for old_file in OLD_LOADER_FILES:
            (win64 / old_file).unlink(missing_ok=True)
    try:
        notes = extract_ue4ss(data, win64, old_mods_list)
        if migrating:
            notes += migrate_old_mods(win64)
    except (ValueError, zipfile.BadZipFile, OSError) as e:
        print(f"  Couldn't install UE4SS: {e}")
        return False
    for note in notes:
        print("  " + note)
    print(f"  UE4SS {version} installed into {win64}")
    return True


def manual_ue4ss_steps(win64: Path):
    print(f"  1. Download the latest UE4SS 3.0.x zip (UE4SS_v3.0.....zip) from {UE4SS_RELEASES}")
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
        if not ask_yes_no("Download and install UE4SS 3.0.x (latest stable) now?", default=True) or not get_ue4ss(win64, update=False):
            print("\nTo install UE4SS yourself:")
            manual_ue4ss_steps(win64)
            return 1
    else:
        print("UE4SS: installed" + (" (older 2.x layout)" if old_layout(win64) else ""))
        if ask_yes_no("Update UE4SS to the latest stable 3.0.x? UE4SS's own files are replaced; your mods and "
                      "mod list are kept, and the old version is backed up first"):
            get_ue4ss(win64, update=True)

    target = install(win64)
    print(f"\nInstalled RoNTAK into {target}")
    print("Next: start the game, then double-click \"Start RoNTAK.bat\".")
    return 0


if __name__ == "__main__":
    code = main()
    sys.exit(code)
