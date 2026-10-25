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

## Order status

Each order in the **Orders** list shows **OK**, **HELD**, **ERROR** (with the reason) or **CANCELLED**. If a
breach doesn't start within 20 seconds (for example a blocked door), the order says so. The UE4SS console log
has the details of every order.
