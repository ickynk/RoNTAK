# 1. Setup

You'll install UE4SS (the mod loader), copy in the RoNTAK mod, and start the companion app.

## Step 1: Find the game folder

1. In Steam, right-click **Ready or Not** → **Manage** → **Browse local files**.
2. Open `ReadyOrNot` → `Binaries` → `Win64`.
3. You should see `ReadyOrNot-Win64-Shipping.exe`. **This is the "Win64 folder"** used below.
   Copy its path from the address bar, for example
   `C:\Program Files (x86)\Steam\steamapps\common\Ready Or Not\ReadyOrNot\Binaries\Win64`.

## Step 2: Install UE4SS

1. Go to <https://github.com/UE4SS-RE/RE-UE4SS/releases>.
2. Download the latest `UE4SS_v….zip`. Avoid the `zDEV` one for now.
3. Extract **everything** in the zip into the Win64 folder.
4. Check: next to `ReadyOrNot-Win64-Shipping.exe` you should now have `dwmapi.dll` and a `ue4ss` folder.
   Older UE4SS versions put `UE4SS.dll`, `UE4SS-settings.ini`, and `Mods` directly in Win64. Either layout works.
5. Open `UE4SS-settings.ini` (inside `ue4ss`, or in Win64) in Notepad and set:
   ```ini
   ConsoleEnabled = 1
   GuiConsoleEnabled = 1
   GuiConsoleVisible = 1
   ```
   This gives you a console window that shows `[RoNTAK]` messages.
6. Start the game once. A UE4SS console window should open next to it. Quit the game.

> If the game crashes on start with UE4SS, check the UE4SS GitHub issues or the Ready or Not modding
> community for a compatible build. The game's engine version changes with major updates.

## Step 3: Install the RoNTAK mod

1. Find the `Mods` folder from step 2: `Win64\ue4ss\Mods` (or `Win64\Mods`).
2. Copy this repository's `mod\RoNTAK` folder into it. You should have `...\Mods\RoNTAK\Scripts\main.lua`.
3. `RoNTAK` already contains an `enabled.txt` file, which tells UE4SS to load it.
4. Start the game and load into a mission. The UE4SS console should show:
   ```
   [RoNTAK] INFO  loaded, bridge folder: ...\Mods\RoNTAK\bridge
   ```
5. Copy that bridge folder path. You need it in the next step.

## Step 4: Start the companion

1. Install Python 3 from <https://www.python.org/downloads/>, ticking **"Add python.exe to PATH"**.
2. Open this repository's `companion` folder, click the address bar, type `cmd`, and press Enter.
3. Run this, with your bridge path in quotes:
   ```
   python server.py --bridge "C:\...\Mods\RoNTAK\bridge"
   ```
4. Open <http://127.0.0.1:8080>. The dot at the top turns **green ("Live")** while you're in a mission.

### Use a phone or tablet as your ATAK

1. Add `--lan`:
   ```
   python server.py --bridge "C:\...\Mods\RoNTAK\bridge" --lan
   ```
2. The server prints an address like `http://192.168.1.20:8080`. Open it on a phone on the same Wi-Fi.
3. If it won't load, allow Python through Windows Firewall on **Private** networks when Windows asks.

## What you'll see

- **The map:** your arrow, your officers (red and blue dots), and the doors (yellow closed, green open,
  orange known-locked) move live while you're in a mission.
- **Orders:** pick a team, tap a door, room, or spot, choose an order, and press the big button. Options your
  team has no gear for are greyed out.
- **No floor plan yet:** until you add one, markers sit on a dark grid. See [03-maps.md](03-maps.md).

If something doesn't work after a game update, see [02-discovery.md](02-discovery.md).

Next: [03-maps.md](03-maps.md)
