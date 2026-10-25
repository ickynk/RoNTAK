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

## Try it now (no game needed)

1. Install Python 3 from <https://www.python.org/downloads/>. On the first installer screen, tick **"Add python.exe to PATH"**.
2. Download this repository (green **Code** button → **Download ZIP**) and unzip it.
3. Open the `companion` folder, click the address bar, type `cmd`, and press Enter.
4. Run:
   ```
   python server.py --mock
   ```
5. Open <http://127.0.0.1:8080> in your browser. You'll see a test house with four simulated officers.
   Tap a door, pick a team and an order, and press the big button.

## Use it with the game

Follow the guides in order:

1. [docs/01-setup.md](docs/01-setup.md): install UE4SS and the mod, start the companion
2. [docs/03-maps.md](docs/03-maps.md): floors, floor plan images and rooms
3. [docs/04-orders.md](docs/04-orders.md): every order, when it's available, and Hold for GO

If a game update breaks something: [docs/02-discovery.md](docs/02-discovery.md).

## Running the tests

```
pip install lupa
python -m unittest discover -s tests -v
```

## Notes

- Use this in single-player. Script mods can break, or be unwelcome, in public multiplayer lobbies.
- Game updates can rename things. If an order stops working after a patch, run the discovery steps again.
