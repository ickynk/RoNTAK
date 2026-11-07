# 4. Orders reference

Pick a team (**RED**, **BLUE** or **GOLD** for both), tap something on the map, pick an order, and press the
big button. The panel only lists orders that fit what you tapped. An order that fits but can't be given right
now is greyed out with the reason, for example "no multitool on BLUE" or "door is locked".

## Door (closed)

| Order | Options | Notes |
| --- | --- | --- |
| Stack Up | Stack side | Stacks on the side of the door the team is on |
| Breach & Clear | Breach (Kick / Shotgun / C2 / Ram / Leader), Grenade, Stack side | Breaching tools and grenades show how many the team has |
| Open & Clear | Grenade, Stack side | Not on a door your team knows is locked |
| Mirror Door | | Needs a mirror (optiwand) |
| Pick Lock | | Needs a multitool or lockpick gun; hidden once the team knows the door is unlocked |
| Check for Traps | | |
| Disarm Trap | | Only when your team knows of a trap (red **!** on the door); needs a multitool |
| Wedge Door | | Needs a wedge |
| Remove Wedge | | Only on a wedged door (purple) |

## Door (open or broken)

| Order | Options |
| --- | --- |
| Stack Up | Stack side |
| Move & Clear | Grenade, Stack side |
| Scan Room | Slice / Slide / Snap / Center |
| Close Door | (not on a broken door) |

## Room

Tapping inside a named room gives the door orders for the room's door nearest the selected team (pick another
with the **Entry** buttons), plus the spot orders below aimed at the room's middle.

## Spot on the map

| Order | Options |
| --- | --- |
| Move To | |
| Cover Area | |
| Deploy Grenade | Flash / Stinger / CS / 9-Bang |
| Drop Chemlight | Needs a chemlight |

## People

Only people who are no longer a threat appear on the map, so it never shows suspects your team hasn't dealt
with. Suspects are orange diamonds and civilians are green circles. The letter shows their state:

- **S**: surrendered
- **R**: restrained
- **✕**: down (incapacitated or dead)

Reported people are faded.

| Order | When |
| --- | --- |
| Restrain | Not yet restrained |
| Report | Restrained or down, and not yet reported |

## Team-wide (always available)

Fall In, Hold, Search & Secure.

## Hold for GO

Tick **Hold for GO** under the order button to set up orders without starting them:

1. With **Hold for GO** ticked, give RED its order (for example Breach & Clear on the kitchen door).
2. Give BLUE its order (for example Breach & Clear on the hallway door).
3. The **Held for GO** box lists both. Press **GO**, or press **F5** in game, to start them at the same time.
   **Clear** drops them.

Each team holds one order; a new one replaces it. A GOLD order replaces held RED and BLUE orders, and the other
way round.

## Reinforcements: calling in more teams

Two extra teams can be called in during a mission:

| Team | Operators | Gear copied from | Call in |
| --- | --- | --- | --- |
| **GREEN** | Echo, Foxtrot | Alpha, Beta | **Call in GREEN** on the ATAK screen, or **Page Up** in game |
| **YELLOW** | Golf, Hotel | Charlie, Delta | **Call in YELLOW**, or **Page Down** in game |

Calling in needs the native part of RoNTAK, **RoNTAKNative** (version 0.2 or newer: see `native/README.md`);
without it the button says so and nothing is spawned.

They arrive one per second at the mission's **entry point**, where your squad stood when the mission began
(or next to you if that's full, or with `spawn_at = "player"` in `config.reinforcements`), and show up on the map
and roster in their colour. Calling a team
again only replaces operators who are dead or missing. If a call-in fails, hover over its button to see why (the
UE4SS console also says `reinforcements: …`).

They join the squad's officer list and take orders **as their own teams**:

- **On the ATAK screen:** the **GREEN** and **YELLOW** team buttons appear next to RED / BLUE / GOLD while the
  team is on scene. Orders sent with them go to that team only.
- **With the in-game command wheel:** press **Insert** to choose what the wheel commands: the stock teams
  (as in the plain game) → **GREEN** → **YELLOW** → the stock teams. While GREEN or YELLOW is selected, a label at the top of the
  screen says so (**WHEEL: GREEN**, in the team's colour; `config.overlay`). The **Command wheel** buttons on the
  ATAK screen show and change the selection too.
  - Stock teams selected: RED and BLUE reach the original squad only; **GOLD reaches everyone**.
  - GREEN selected: RED or BLUE on the wheel (either) commands **Echo and Foxtrot only**; GOLD still reaches
    everyone. The same for YELLOW.

How it works: the game itself only knows RED, BLUE and GOLD, and picks who gets a wheel order from each
officer's team. RoNTAK keeps those teams arranged for the current selection: the called-in operators rest on
GOLD (the squad-wide team) unless selected, and while a team is selected everyone else rests on GOLD
(`squads.lua`, `config.squads`). Teams, names, gear and keys are set in `config.lua` (`config.reinforcements`,
`config.squads`, `request_green`, `request_yellow`, `select_team`).

Single player only.

## Order status

Each order in the **Orders** list shows **OK**, **HELD**, **ERROR** (with the reason) or **CANCELLED**. If a
breach doesn't start within 20 seconds (for example a blocked door), the order says so. The UE4SS console log
has the details of every order.
