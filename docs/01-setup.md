# 1. Install

About 10 minutes, once. You need Ready or Not (Steam) on Windows.

## Step 1: Install Python

1. Go to <https://www.python.org/downloads/> and download Python 3.
2. Run the installer. On the first screen, tick **"Add python.exe to PATH"**, then click **Install Now**.

## Step 2: Download RoNTAK

1. Open the RoNTAK repository on GitHub and click **Releases** (right-hand side).
2. Under the newest release, download **RoNTAK-x.y.z.zip**.
3. Right-click the ZIP → **Extract All…**, and pick a folder you'll keep, for example `Documents\RoNTAK`.

## Step 3: Install UE4SS (the mod loader)

1. In Steam, right-click **Ready or Not** → **Manage** → **Browse local files**.
2. Open `ReadyOrNot` → `Binaries` → `Win64`. You should see a program named like
   `ReadyOrNot…-Win64-Shipping.exe`.
3. Download the latest `UE4SS_v….zip` from <https://github.com/UE4SS-RE/RE-UE4SS/releases> (not the
   `zDEV` one).
4. Extract **everything** in it into that `Win64` folder.

> If the game crashes on start with UE4SS, check the UE4SS GitHub issues or the Ready or Not modding
> community for a compatible build. The game's engine version changes with major updates.

## Step 4: Install the mod

Double-click **`Install RoNTAK.bat`** in the RoNTAK folder. It:

- finds Ready or Not through Steam (on any drive),
- checks that UE4SS is installed,
- copies the mod into UE4SS's `Mods` folder, and
- remembers where it put it.

If it can't find the game, it asks you to paste the game's folder (from step 3.1).

Run it again after downloading a newer RoNTAK to update. If you edited `config.lua`, your version is kept as
`config.lua.bak`.

## Step 5: Play

1. Start Ready or Not and load into a mission.
2. Double-click **`Start RoNTAK.bat`**. The ATAK screen opens in your browser.
3. The first time, it asks whether phones and tablets on your Wi-Fi may connect. Answer **y** to use a phone
   as your ATAK. Anyone on your network could then give orders, so answer **n** on shared networks.
4. The dot at the top turns **green ("Live")** while you're in a mission.

Keep the `Start RoNTAK.bat` window open while you play; closing it stops the ATAK screen.

### Use a phone or tablet

1. On the PC's ATAK screen, press **Phone**.
2. Connect the phone to the same Wi-Fi and scan the QR code, or type the address shown.
3. If the phone can't connect, allow Python through Windows Firewall on **Private** networks when Windows asks,
   or check that the phone isn't on a guest network.

To change your phone answer later, start with `Start RoNTAK.bat --lan` (allow) or `Start RoNTAK.bat --local`
(this PC only). The choice is remembered.

## What you'll see

- **The map:** your arrow, your officers (red and blue dots), doors (yellow closed, green open, orange locked,
  purple wedged), and surrendered, restrained or downed people.
- **Cameras:** the air unit, drone and (once wired) CCTV, with the people the air unit tracks. Press **Cams** to
  hide them. See [03-maps.md](03-maps.md#cameras-helicopter-drone-and-cctv).
- **Roster:** each officer's health: **OK**, **INJURED** (with health %), **DOWN**, **INCAPACITATED** or **KIA**.
  On the map, injured officers get an orange ring and downed or dead officers an ✕.
- **Orders:** pick a team, tap a door, room, person or spot, choose an order and press the big button. See
  [04-orders.md](04-orders.md).
- **No floor plan yet:** until you add one, markers sit on a dark grid. See [03-maps.md](03-maps.md).

If something doesn't work after a game update, see [02-discovery.md](02-discovery.md).

## Try it without the game

`Start RoNTAK.bat --mock` opens the ATAK screen with a simulated house and team, so you can try every order
without Ready or Not.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| "Python 3 is not installed" | Step 1, then run the `.bat` again. Make sure "Add python.exe to PATH" was ticked |
| Installer says UE4SS is not installed | Step 3: the UE4SS files must be in the same folder as the game's `…-Win64-Shipping.exe` |
| ATAK screen stays "Waiting for game" | Load into a mission. Check the UE4SS console shows `[RoNTAK] INFO loaded` |
| Installer can't find the game | Paste the folder Steam's **Browse local files** opens. If it still fails, it prints the program names it found: send them to the RoNTAK developer |
| No **Phone** button | It's hidden on screens narrower than a phone; widen the window. After an update, refresh the page |
| "Port 8080 is in use" | RoNTAK is already running: open <http://127.0.0.1:8080>, or close the other window |
| Phone can't connect | Same Wi-Fi as the PC; allow Python in Windows Firewall (Private networks) |

## Manual install (without the .bat files)

1. Copy `mod\RoNTAK` into UE4SS's `Mods` folder: `Win64\ue4ss\Mods` (or `Win64\Mods` with older UE4SS).
2. In the `companion` folder, run:
   ```
   python server.py --bridge "C:\...\Mods\RoNTAK\bridge"
   ```
