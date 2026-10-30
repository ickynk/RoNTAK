"""Finds Ready or Not, UE4SS and the RoNTAK mod on this PC, and keeps the
companion's settings (companion/settings.json). Standard library only."""

import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SETTINGS_FILE = HERE / "settings.json"

GAME_FOLDER = Path("steamapps") / "common" / "Ready Or Not"
WIN64 = Path("ReadyOrNot") / "Binaries" / "Win64"
# The game's program in Binaries/Win64. Its exact name has changed between
# builds (e.g. ReadyOrNot-Win64-Shipping.exe, ReadyOrNotSteam-Win64-Shipping.exe).
GAME_EXE_PATTERN = "ReadyOrNot*-Win64-Shipping.exe"
MOD_NAME = "RoNTAK"


# Settings --------------------------------------------------------------------

def load_settings() -> dict:
    try:
        return json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_settings(**changes) -> dict:
    settings = load_settings()
    settings.update(changes)
    SETTINGS_FILE.write_text(json.dumps(settings, indent=2), encoding="utf-8")
    return settings


# Steam -----------------------------------------------------------------------

def steam_root():
    """Steam's install folder from the Windows registry, or None."""
    if sys.platform != "win32":
        return None
    import winreg
    for hive, key, value in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
                             (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath")):
        try:
            with winreg.OpenKey(hive, key) as k:
                return Path(winreg.QueryValueEx(k, value)[0])
        except OSError:
            continue
    return None


def library_folders(vdf_text: str) -> list:
    """The "path" entries of Steam's steamapps/libraryfolders.vdf."""
    return [Path(p.replace("\\\\", "\\")) for p in re.findall(r'"path"\s+"([^"]+)"', vdf_text)]


def steam_libraries(root=None) -> list:
    root = Path(root) if root else steam_root()
    libraries = []
    if root:
        libraries.append(root)
        try:
            libraries += library_folders((root / "steamapps" / "libraryfolders.vdf").read_text(encoding="utf-8"))
        except OSError:
            pass
    # Common places, in case Steam isn't in the registry.
    for drive in "CDEFG":
        libraries += [Path(f"{drive}:/Program Files (x86)/Steam"), Path(f"{drive}:/SteamLibrary")]
    unique = []
    for lib in libraries:
        if lib not in unique:
            unique.append(lib)
    return unique


# Game, UE4SS, mod ------------------------------------------------------------

def is_win64(folder: Path) -> bool:
    try:
        return any(f.is_file() for f in folder.glob(GAME_EXE_PATTERN))
    except OSError:
        return False


def win64_from(path) -> "Path | None":
    """The game's Binaries/Win64 folder from a path the user gave: the Win64
    folder itself, the game's .exe, the game folder, or any folder in between."""
    path = Path(str(path).strip().strip('"')).expanduser()
    if path.is_file():
        path = path.parent
    candidates = [path, path / "Binaries" / "Win64", path / WIN64, path / "Ready Or Not" / WIN64]
    try:
        # The game folder with a differently named project folder inside.
        candidates += sorted(path.glob("*/Binaries/Win64"))
    except OSError:
        pass
    for candidate in candidates:
        if is_win64(candidate):
            return candidate
    return None


def shipping_exes(path) -> list:
    """Names of *-Shipping.exe files under a pasted folder, to explain why it was not accepted."""
    path = Path(str(path).strip().strip('"')).expanduser()
    found = []
    for pattern in ("*-Shipping.exe", "*/Binaries/Win64/*-Shipping.exe", "*/*/Binaries/Win64/*-Shipping.exe"):
        try:
            found += [str(f) for f in path.glob(pattern)]
        except OSError:
            pass
    return found[:5]


def find_win64(libraries=None) -> "Path | None":
    for lib in libraries if libraries is not None else steam_libraries():
        found = win64_from(lib / GAME_FOLDER)
        if found:
            return found
    return None


def ue4ss_installed(win64: Path) -> bool:
    return (win64 / "ue4ss" / "UE4SS.dll").is_file() or (win64 / "UE4SS.dll").is_file()


def mods_dir(win64: Path) -> Path:
    """UE4SS's Mods folder: Win64/ue4ss/Mods (UE4SS 3.x) or Win64/Mods (older)."""
    if (win64 / "ue4ss").is_dir():
        return win64 / "ue4ss" / "Mods"
    return win64 / "Mods"


def bridge_dir(win64: Path) -> Path:
    return mods_dir(win64) / MOD_NAME / "bridge"


def find_bridge() -> "Path | None":
    """The bridge folder from settings, else from the installed game."""
    saved = load_settings().get("bridge")
    if saved and Path(saved).is_dir():
        return Path(saved)
    win64 = find_win64()
    if win64 and bridge_dir(win64).is_dir():
        return bridge_dir(win64)
    return None


def ask_path(prompt: str) -> str:
    print(prompt)
    return input("> ").strip().strip('"')


if __name__ == "__main__":
    win64 = find_win64()
    print("Ready or Not:", win64 or "not found")
    if win64:
        print("UE4SS installed:", ue4ss_installed(win64))
        print("Mods folder:", mods_dir(win64))
    print("Bridge:", find_bridge() or "not found")
