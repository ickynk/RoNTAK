# Reverse-engineering notes: command wheel and squad manager

Found with RoNTAKNative's code dump (Delete key, `RoNTAK_DumpCode`) and
analysed offline with Capstone. **Addresses are RVAs in
`ReadyOrNotSteam-Win64-Shipping.exe` of November 2026 (154 511 872 bytes)
and change with every game update**: the native hooks will find them by
byte patterns made from this code, not by these numbers.

## How a command-wheel order travels

| RVA | What | Notes |
| --- | --- | --- |
| `494cec0` | `SwatCommandWidget::execDoCommand` (UFunction thunk) | reads the params, calls the implementation |
| `4ca7e10` | `SwatCommandWidget::DoCommand(FSwatCommand&, bool, bool team?, ...)` | the wheel calls this directly (not via ProcessEvent: a Lua hook on DoCommand never fires). Gets the manager from the resolver, takes the team from its 4th arg or `widget+0x34c`, switches on the command type (`cmd+0x30`, jump table) and calls the manager's `Give*Command(team, ...)` |
| `4dd1090` | resolver: `GetWorld()->GetSubsystem<USWATManager>()` | `ctx->vtable[0x188/8]()` = GetWorld, `world+0x828` subsystem collection, `494eb50` = USWATManager::StaticClass, `3519ce0` = GetSubsystemInternal. **134 call sites in 97 functions**, many of them in the officers' team activities (around `4d5xxxx`-`4d7xxxx`, e.g. TeamBaseActivity::GetSquadLeader `4d63a70`) |
| `4ca7710` | `SwatCommandWidget` team scroll `(widget, bool forward, bool)` | builds `[1 RED, 2 BLUE, 5 GOLD]`, removes teams `IsSWATTeamDead` reports dead, steps from `widget+0x348`, calls set-team `4cc32d0(widget, team)`, then a voice line via `manager+0xc60` |
| `4cc32d0` | `SwatCommandWidget` set active team `(widget, team)` | |
| `4ccd250` | `SwatCommandWidget` refresh (every 0.15 s from the tick) | dead-team checks, rebuilds the entries |
| `4cbd2e3` | part of the widget tick | copies `widget+0x348` into `manager+0xcb9` (ActiveCommandTeam) |
| `4cafa30` | `GetActiveTeam` | `widget+0x34b & 1 ? widget+0x34a : widget+0x348` |
| `4cb8c60` | widget vtable[109], setup | sets `widget+0x348 = 5` (GOLD) |

Widget fields: `0x348` ActiveTeamType, `0x34a` OverrideActiveTeamType,
`0x34b` override flag (bit 0), `0x34c` ExecutionTeamType.

## USWATManager

* `SwatAI` TArray at `+0xd0` (Num at `+0xd8`).
* `+0xcb8` / `+0xcb9`: ActiveCommandTeam (written by the widget tick).
* `+0xc20..0xc38`: item blueprints loaded in setup; `+0xc60` voice/audio object.
* vtable (`74c2630`): [88] `4de7c60` Initialize (Super, game-world check,
  then setup `4df9070`), [89] `4dcb150` Deinitialize, [95] `4dfb010` Tick
  (works on the FTickableGameObject at `manager+0x30`).
* Setup `4df9070` builds per-team state for GOLD / RED / BLUE and registers a
  world callback `4def4d0` (`world+0x780`), which only binds the
  OnActivityStarted / OnLeaderToggledNightvision delegates.
* The squad leader is the player's pawn (PlayerController 0, `2f2e030`).
* `IsSWATTeamDead(team)` `4de8b50`.

`Give*Command` implementations (`this` = manager, then team):

| | | | |
| --- | --- | --- | --- |
| Move `4de3260` | FallIn `4de2b40` | Hold `4de2f90` | StackUp `4de5e10` |
| SearchAndSecure `4de5a90` | CheckForContacts `4de02c0` | CheckForTraps `4de0540` | CloseDoor `4de0870` |
| CoverArea `4de0d70` | OpenDoor `4de46d0` | PickLock `4de4a60` | RemoveWedge `4de4e80` |
| Restrain `4de53b0` | ScanDoor `4de5680` | WedgeDoor `4de6af0` | ReportTarget `4de51b0` |

## Plan: wheel teams

1. A second USWATManager for the called-in teams (its own SwatAI, slots 0-3).
2. Hook the resolver: a wheel order marked for the call-ins, or a call-in
   officer / its activity asking, gets the second manager.
3. Hook `DoCommand`: mark the target manager; FULL ELEMENT runs it on both.
4. Hook the team scroll: RED, BLUE, RED+BLUE, GREEN, YELLOW, GREEN+YELLOW,
   FULL ELEMENT (the wheel shows red / blue / gold; RoNTAK's label shows the
   real name).

### Status (native 0.6.0)

Steps 1-4 are in `RoNTAKNative` (`RoNTAK_Squad*`, the "squad routing"
section of `dllmain.cpp`) and `mod/RoNTAK/Scripts/squads.lua`; Insert picks
or the wheel's scroll picks the group. The scroll hook calls set-team `4cc32d0(widget, team)` with the
chosen squad's manager answering the resolver (set-team checks the team with `IsSWATTeamDead` in it) and
skips the game's voice line. Prologue bytes checked before hooking:

| RVA | First bytes |
| --- | --- |
| `4dd1090` resolver | `48 89 5c 24 08 57 48 83 ec 20 48 8b 01 ff 90 88 01 00 00` |
| `4ca7e10` DoCommand | `48 8b c4 48 89 58 18 44 88 48 20 48 89 50 10 48 89 48 08` |
| `4ca7710` team scroll | `44 88 44 24 18 55 57 41 54 41 55 41 57 48 8b ec 48 83 ec 60` |
| `4cc32d0` set team | `48 89 5c 24 18 56 48 83 ec 20 0f b6 81 48 03 00 00` |
| `4de8b50` IsSWATTeamDead | `48 83 ec 28 83 b9 d8 00 00 00 00 75 07 b0 01` |
