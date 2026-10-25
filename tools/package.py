"""Builds the release ZIP: dist/RoNTAK-<version>.zip with a RoNTAK/ folder inside.

    python tools/package.py            # version from the VERSION file
    python tools/package.py v0.2.0     # or given (e.g. the release tag)

Contains what a player needs: the mod, the companion (with saved maps), the
docs and the two .bat files. Tests, tools and local files are left out.
"""

import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

INCLUDE = [
    "README.md", "VERSION", "install.py", "Install RoNTAK.bat", "Start RoNTAK.bat",
    "docs", "mod", "companion",
]
# Never shipped: caches, this PC's settings, and runtime files in the bridge folder.
EXCLUDE_NAMES = {"__pycache__", "settings.json", ".DS_Store"}


def included(path: Path) -> bool:
    rel = path.relative_to(ROOT)
    if any(part in EXCLUDE_NAMES for part in rel.parts):
        return False
    if rel.parts[:3] == ("mod", "RoNTAK", "bridge") and path.name != ".keep":
        return False
    return path.suffix != ".pyc"


def files() -> list:
    result = []
    for name in INCLUDE:
        path = ROOT / name
        if path.is_file():
            result.append(path)
        else:
            result += sorted(p for p in path.rglob("*") if p.is_file() and included(p))
    return result


def build(version: str, out_dir: Path = ROOT / "dist") -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / f"RoNTAK-{version}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for path in files():
            z.write(path, Path("RoNTAK") / path.relative_to(ROOT))
    return target


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    version = argv[0].lstrip("v") if argv else (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    target = build(version)
    print(f"Built {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
