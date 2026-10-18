# RoNTAK

An ATAK-style tactical map and team orders mod for **Ready or Not**.

- Live map with floor plans, your position, and every SWAT officer, colored by team
- Tap a **door**, a **room**, or a **spot** on the map, pick **RED / BLUE / GOLD**, and give an order:
  Stack Up, Breach & Clear (Kick / Shotgun / C2 / Ram / Leader + Flash / Stinger / CS), Open & Clear,
  Mirror Door, Wedge Door, Move To, Fall In, Hold, Search & Secure
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
Ready or Not's internals are not publicly documented, so the mod includes tools to find these names on your
own install (F8 / F9 in game). See [docs/02-discovery.md](docs/02-discovery.md).

## Project status

| Part | Status |
| --- | --- |
| ATAK interface (map, teams, orders, calibration, room drawing) | Done; tested against the simulated game |
| Companion server and file bridge | Done; tested |
| Mod: tracking, order dispatch, discovery and sniffer tools | Done; tested against a fake UE4SS. **Not yet run in the real game** |
| Game class/function names in `config.lua` | **To find on your PC** (docs/02) |
| Floor plans for each level | **To add** (docs/03) |
| Drawing the map on the in-game ATAK device itself | Phase 2 (docs/04) |

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
2. [docs/02-discovery.md](docs/02-discovery.md): find the game's names and fill in `config.lua`
3. [docs/03-maps.md](docs/03-maps.md): add floor plans and rooms for each level
4. [docs/04-in-game-device.md](docs/04-in-game-device.md): Phase 2, show it on the in-game ATAK

## Running the tests

```
pip install lupa
python -m unittest discover -s tests -v
```

## Notes

- Use this in single-player. Script mods can break, or be unwelcome, in public multiplayer lobbies.
- Game updates can rename things. If an order stops working after a patch, run the discovery steps again.
