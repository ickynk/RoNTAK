# RoNTAK

An ATAK-style tactical map and team orders mod for **Ready or Not**.

- Live map with floor plans, your position, and every SWAT officer, colored by team
- Tap a **door**, a **room**, a **person** or a **spot** on the map, pick **RED / BLUE / GOLD**, and give an order:
  - Doors: Stack Up, Breach & Clear (Kick / Shotgun / C2 / Ram / Leader + Flash / Stinger / CS / 9-Bang /
    Launcher, any stack side), Open & Clear, Move & Clear, Scan Room, Mirror, Pick Lock, Check for Traps,
    Disarm Trap, Wedge, Remove Wedge, Close Door
  - Spots: Move To, Cover Area, Deploy Grenade, Drop Chemlight
  - People (only once surrendered, restrained or down): Restrain, Report
  - Team-wide: Fall In, Hold, Search & Secure
- **Cameras**: the air unit's sight line and the people it tracks, drone view cone, and CCTV cones once the
  cameras are wired (the feed you are watching highlighted), with suspects and civilians in a camera's view marked,
  then shown at their last known position
- **Roster health**: OK / injured (with %) / down / KIA for each officer
- **Floor plans from the game**: press F11 on each floor for an exact top-down plan and its walls (traced with
  the game's collision), lined up automatically; show the plan, or just the walls on white or blueprint blue
- **Rooms found automatically** from the traced walls, ready to name
- **Hold for GO**: set up orders for both teams and start them together (GO on screen, or F5 in game)
- Options the selected team has no gear for are greyed out, with counts (e.g. "C2 ×1")
- Doors show their state (closed, open, broken, wedged, known locked, known trap) and only offer orders that fit
- Each order shows whether the game accepted it
- Works on a second monitor, or on a phone or tablet on your Wi-Fi, like real ATAK

## How it works

```
 Ready or Not  ──UE4SS──►  RoNTAK mod (Lua)  ──state.json──►  companion server  ──►  ATAK screen
 (the game)    ◄─────────  config.lua        ◄─commands.json─  (Python)            ◄──  (browser / phone)
```

1. **The mod** (`mod/RoNTAK`) runs inside the game through [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).
   It reads officer, door, and player positions, and turns ATAK orders into the same game
   functions the in-game command wheel uses.
2. **The companion** (`companion/`) is a small Python server that shows the ATAK screen in a browser.
   It needs nothing installed except Python.

All game-specific names (classes, functions, enum values) are in **one file**: `mod/RoNTAK/Scripts/config.lua`.
It ships filled in and tested. If a game update breaks something, the mod has tools to find the new names
(F7 / F8 / F9 in game); see [docs/02-discovery.md](docs/02-discovery.md).

## Project status

**v0.1**: all orders tested in game (October 2026).

| Part | Status |
| --- | --- |
| Live map: player, officers by team, doors with open / locked state | Working in game |
| Orders: stack up, breach / open / move & clear with breaching tools and grenades, mirror, wedge, move, fall in, hold, search & secure | Working in game |
| More orders: pick lock, traps, remove wedge, close door, scan room, cover area, chemlight, grenade at a spot, restrain / report, Hold for GO | Added (to be confirmed in game) |
| Gear-aware options (counts, greyed-out options) | Working in game |
| Floors: automatic from door heights, auto-switching as you move | Working in the companion |
| Officer names from the roster | Added (to be confirmed in game) |
| Floor plan images (community maps) and named rooms | Add per level; line up by tapping two doors (docs/03) |
| Cameras: helicopter tracking, drone, CCTV (wired + live feed) | Added (to be confirmed in game) |
| Install: `Install RoNTAK.bat`, `Start RoNTAK.bat`, phone QR code, release ZIP | Added (to be confirmed on a fresh PC) |

## Install

1. Install [Python 3](https://www.python.org/downloads/) (tick **"Add python.exe to PATH"**).
2. Download **RoNTAK-x.y.z.zip** from this repository's **Releases** and extract it.
3. Double-click **`Install RoNTAK.bat`**. It finds the game, offers to download and install
   [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) (the mod loader) if you don't have it, and installs the mod.
4. Start a mission, then double-click **`Start RoNTAK.bat`**. Press **Phone** on the ATAK screen to open it on
   a phone or tablet.

Step by step, with where to find everything: [docs/01-setup.md](docs/01-setup.md).
To try it without the game: `Start RoNTAK.bat --mock`.

## Guides

1. [docs/01-setup.md](docs/01-setup.md): install, first start, phone, troubleshooting
2. [docs/03-maps.md](docs/03-maps.md): floors, floor plan images and rooms
3. [docs/04-orders.md](docs/04-orders.md): every order, when it's available, and Hold for GO

If a game update breaks something: [docs/02-discovery.md](docs/02-discovery.md).

## Making a release

1. Update `VERSION`, then merge into `main`.
2. On GitHub: **Releases** → **Draft a new release**, create a tag like `v0.2.0` on `main`, and publish.
3. A GitHub Action runs the tests and attaches `RoNTAK-0.2.0.zip` to the release within a few minutes.

## Running the tests

```
pip install lupa
python -m unittest discover -s tests -v
```

## Notes

- Use this in single-player. Script mods can break, or be unwelcome, in public multiplayer lobbies.
- Game updates can rename things. If an order stops working after a patch, run the discovery steps again.
