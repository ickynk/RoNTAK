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
# Where UE4SS keeps its files, relative to Win64. 2.x and the 3.0.x releases
# are "flat" (everything in Win64); later builds are "nested" (everything but
# the proxy DLL in a ue4ss folder). The layout is read from the files, never
# assumed.
LAYOUTS = {
    "flat": {"dll": "UE4SS.dll", "settings": "UE4SS-settings.ini", "mods": "Mods"},
    "nested": {"dll": "ue4ss/UE4SS.dll", "settings": "ue4ss/UE4SS-settings.ini", "mods": "ue4ss/Mods"},
}
# The DLL the game loads, which starts UE4SS (2.x: xinput1_3.dll, 3.x: dwmapi.dll).
PROXY_DLLS = ("dwmapi.dll", "xinput1_3.dll")
LOADER_EXTRAS = ("UE4SS.pdb", "UE4SS.log")


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


def installed_layout(win64: Path):
    if (win64 / LAYOUTS["nested"]["dll"]).is_file():
        return "nested"
    if (win64 / LAYOUTS["flat"]["dll"]).is_file():
        return "flat"
    return None


def zip_layout(names) -> str:
    for layout in ("nested", "flat"):
        if LAYOUTS[layout]["dll"] in names:
            return layout
    raise ValueError("this doesn't look like a UE4SS release (no UE4SS.dll)")


def backup_ue4ss(win64: Path) -> Path:
    """Zips the current UE4SS: loader files, settings and the Mods folders."""
    backup = win64 / f"ue4ss_backup_{time.strftime('%Y%m%d_%H%M%S')}.zip"
    files = [win64 / name for name in PROXY_DLLS + LOADER_EXTRAS + ("UE4SS.dll", "UE4SS-settings.ini")]
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


def move_mods(source: Path, dest: Path) -> list:
    """Moves mod folders from source into dest (folders dest already has stay
    as they are), then removes source. Returns notes."""
    moved = []
    dest.mkdir(parents=True, exist_ok=True)
    for child in sorted(source.iterdir()):
        if child.is_dir() and not (dest / child.name).exists():
            shutil.move(str(child), str(dest / child.name))
            moved.append(child.name)
    shutil.rmtree(source, ignore_errors=True)
    return [f"Moved {len(moved)} mod folder(s) to {dest}: {', '.join(moved)}"] if moved else []


def extract_ue4ss(data: bytes, win64: Path) -> list:
    """Installs a UE4SS release zip into Win64 over whatever UE4SS is there.
    UE4SS's own files are replaced; mods you added stay (moved if the new
    version keeps mods elsewhere); mods.txt is merged with yours; your
    settings are kept unless the old UE4SS was a different generation.
    Returns notes for the user."""
    notes = []
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        for name in names:
            rel = PurePosixPath(name)
            if rel.is_absolute() or ".." in rel.parts:
                raise ValueError(f"unsafe path in the zip: {name}")
        new = LAYOUTS[zip_layout(names)]
        old_name = installed_layout(win64)
        old = LAYOUTS.get(old_name)

        old_list = old and win64 / old["mods"] / "mods.txt"
        old_list_text = old_list.read_text(encoding="utf-8", errors="replace") if old_list and old_list.is_file() else None
        # An old proxy DLL the new version doesn't use would start a second UE4SS.
        stale_proxies = [p for p in PROXY_DLLS if p not in names and (win64 / p).is_file()] if old else []
        keep_settings = old is new and not stale_proxies and (win64 / new["settings"]).is_file()
        if old and old is not new:
            for name in (old["dll"], old["settings"]):
                (win64 / name).unlink(missing_ok=True)
        for proxy in stale_proxies:
            (win64 / proxy).unlink()
            notes.append(f"Removed the old loader {proxy}")
        for extra in LOADER_EXTRAS:
            (win64 / extra).unlink(missing_ok=True)

        mods_list = new["mods"] + "/mods.txt"
        for name in names:
            dest = win64.joinpath(*PurePosixPath(name).parts)
            if name == new["settings"] and keep_settings:
                notes.append(f"Kept your {name}")
                continue
            content = z.read(name)
            if name == mods_list and old_list_text:
                content = merge_mod_lists(content.decode("utf-8", errors="replace"), old_list_text).encode("utf-8")
                notes.append("Merged your mod list into the new mods.txt")
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(content)

    if old and old is not new and (win64 / old["mods"]).is_dir():
        notes += move_mods(win64 / old["mods"], win64 / new["mods"])
    if old_name == "nested" and new is LAYOUTS["flat"]:
        shutil.rmtree(win64 / "ue4ss", ignore_errors=True)  # in the backup
    return notes


def repair_misplaced_mods(win64: Path) -> list:
    """Undoes an earlier installer mistake: with a flat UE4SS (UE4SS.dll in
    Win64), mods had been moved into Win64/ue4ss/Mods, where UE4SS doesn't
    look. Moves them back to Win64/Mods and restores mods.txt from the newest
    backup. Returns notes (empty when there was nothing to fix)."""
    stray = win64 / "ue4ss" / "Mods"
    if installed_layout(win64) != "flat" or not stray.is_dir():
        return []
    notes = move_mods(stray, win64 / "Mods")
    mods_list = win64 / "Mods" / "mods.txt"
    if not mods_list.is_file():
        for backup in sorted(win64.glob("ue4ss_backup_*.zip"), reverse=True):
            with zipfile.ZipFile(backup) as z:
                if "Mods/mods.txt" in z.namelist():
                    mods_list.write_bytes(z.read("Mods/mods.txt"))
                    notes.append(f"Restored mods.txt from {backup.name}")
                    break
    if not any(f.is_file() for f in (win64 / "ue4ss").rglob("*")):
        shutil.rmtree(win64 / "ue4ss", ignore_errors=True)
    return ["Repaired your UE4SS mods folder:"] + notes


def get_ue4ss(win64: Path, update: bool) -> bool:
    """Downloads the newest stable UE4SS 3.0.x and installs it into win64. An
    existing UE4SS is backed up first."""
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
    if update:
        print(f"  Backed up your current UE4SS to {backup_ue4ss(win64)}")
    try:
        notes = extract_ue4ss(data, win64)
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
        for note in repair_misplaced_mods(win64):
            print("  " + note)
        print("UE4SS: installed")
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
