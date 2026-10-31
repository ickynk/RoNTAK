# 2. After a game update: finding the game's names again

`config.lua` ships with every value already filled in and tested. You only need this guide if a Ready or Not
update breaks something, such as officers missing from the map or an order that stops working.

All game-specific names live in `mod\RoNTAK\Scripts\config.lua`. After every edit, restart the game so the mod
reloads it.

## The tools

| Key | What it does | Output |
| --- | --- | --- |
| **F6** | Each building's floors and their heights | `bridge\mapinfo.json` |
| **F7** | Every officer's current door job: which door, which item | `bridge\activities.txt` and the console |
| **F8** | Lists game classes (with live counts and properties) and functions | `bridge\discovery.txt` |
| **F9** | Start/stop logging calls to the functions in `config.sniff` | `bridge\sniff.txt` and the console |
| **F10** | Sends `config.test_order` (GOLD Fall In) through the normal order path | console |
| **F11** | TEST: top-down floor plan pictures of 60 × 60 m around you, three ways of cutting off what's above | `bridge\floorplan_test_A/B/C.png`, `bridge\floorplan_test.json` |

The UE4SS **header dump** is the most useful tool. In a mission, open the UE4SS console window, go to the
**Dumpers** tab and click **Dump CXX Headers**. A `CXXHeaderDump` folder appears next to the UE4SS files. The two
files that matter are:

- `ReadyOrNot.hpp`: every class, its properties, and every function with its exact parameters
- `ReadyOrNot_enums.hpp`: the number behind every option name

## Officers or doors missing from the map

1. In a mission, press **F8** and open `bridge\discovery.txt`. The number before each class is how many exist
   right now.
2. **Officers:** find the class whose count matches your AI team (it was `CyberneticsSwat_V2_C`, 4 live) and put
   it in `config.officers.classes`.
3. **Team colors:** officers are colored by their `SquadPosition` (0 Alpha, 1 Beta, 2 Charlie, 3 Delta). If
   RED and BLUE show swapped, swap `"red"` and `"blue"` in `config.officers.team_values`.
4. **Doors:** find the class whose count matches the doors in the level (it was `Door`, 32 live) and put it in
   `config.doors.classes`.

## An order stops working

1. Look at the order on the ATAK screen. **ERROR** comes with a reason, such as a missing function or a
   missing door.
2. Search `ReadyOrNot.hpp` for the function named in `config.actions` (for example `GiveStackUpCommand`) and
   compare its parameters with the `args` list. The comment above `config.actions` lists the signatures the
   mod was built against.
3. Check the option numbers (`config.team_args`, `breach_args`, `side_args`, and so on) against
   `ReadyOrNot_enums.hpp`, for example `enum class ETeamType` or `enum class EDoorBreachType`.

## Breaches start but the grenade or breaching tool is wrong

The UE4SS console log shows, for each breach order, the item classes the mod sent, what was written into the
call, and which officer the game gave the job. For example:

```
order 12: red breach_clear sent grenade Grenade_Flashbang_V2_C, breach item none | set in call: arg 5 null -> Grenade_Flashbang_V2_C, arg 6 null -> null
order 12: game assigned CyberneticsSwat_V2_C_2147443415 ThrowGrenadeThroughDoor: Grenade_Flashbang_V2_C
```

What we learned getting this working:

- UE4SS does not pass item class arguments (`TSubclassOf`) when Lua calls a game function. The mod writes them
  from a hook instead (`config.class_arg_hooks`). Leave that in place.
- In `GiveBreachAndClearCommand`, argument 5 is the item thrown through the door and argument 6 is the
  breaching tool. That's the reverse of their names in the header dump. If grenades stop being thrown after an
  update, try swapping `"$grenade_item"` and `"$breach_item"` in `BREACH_ARGS`.
- To compare with the game's own behavior, give the same breach with the command wheel and press **F7** when
  the officer throws. `activities.txt` shows the item the game uses (for example
  `ThrowGrenadeThroughDoor door=BP_Door_New15 item=Grenade_Flashbang_V2_C`).

## Cameras missing from the map

The helicopter, drone and CCTV names are in `config.cameras`.

- **No helicopter, drone or CCTV:** press **F8** and search `discovery.txt` for `Helicopter`, `Drone`,
  `UnmannedVehicle` or `CCTV` to find the new class names.
- **The air unit never marks anyone:** the UE4SS console prints `helicopter is tracking suspect ...` when it
  picks someone up. If that never appears while the helicopter follows someone, check that
  `target_found_hook` / `target_lost_hook` still exist (search the header dump for `OnTargetFound`).
- **Turning the camera features off:** set `enabled = false` at the top of `config.cameras`. The mod then reads
  nothing about the helicopter, drones or CCTV.
- **CCTV never appears:** it only shows once the cameras are wired to your tablet, or while you watch a feed.
- **CCTV never marks anyone:** the console prints `CCTV <camera> sees suspect ...` when it does. If it prints
  `CCTV line of sight check failed`, the line-of-sight function changed: look up `HasLineOfSightTo` in the header
  dump and update `cctv_line_of_sight_function`. Set `cctv_spots_people = false` to turn the feature off.

## Watching functions (F9)

Put full function paths from `discovery.txt` or the header dump into `config.sniff`, without the leading
`Function `. Press **F9**, give orders, and press **F9** again. Each call is logged with its arguments.

- When you use the command wheel, most order functions do **not** show up, because the game calls them
  directly from C++. `SwatCommandWidget:OnCommandIssued` does show up.
- Orders sent by RoNTAK **do** show up, so sniffing a `SWATManager` function shows exactly what the mod passed.
- Don't sniff functions that run every frame; the log floods and the game slows down.
