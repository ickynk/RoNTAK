# 2. Find the game's names and fill in config.lua

The mod needs four things that only exist inside your copy of the game:

| What | Where it goes in `config.lua` |
| --- | --- |
| The class of AI officers, and the property that holds their team | `config.officers` |
| The class of doors | `config.doors` |
| The function the game calls when you give an order | `config.actions` |
| The number values the game uses for teams, breach types, and so on | `config.team_args`, `config.breach_args`, … |

Two in-game hotkeys find them for you:

- **F8**: dump. Lists matching classes, their properties, and functions into `bridge\discovery.txt`.
- **F9**: sniffer. Records which functions fire while you use the normal command wheel, into `bridge\sniff.txt`.

After every edit to `config.lua`, restart the game so the mod reloads it.

---

## Part A: Officers and doors

1. Start a mission with your AI team, and wait until you're in control.
2. Press **F8**. The game may freeze for a few seconds while it scans.
3. Open `Mods\RoNTAK\bridge\discovery.txt` in Notepad. The top section looks like this (example):
   ```
       5  SWATCharacter
            . TeamId (EnumProperty)
            . Health (FloatProperty)
       0  SWATCommandWidget
      41  Door
   ```
   The number is **how many exist right now**.
4. **Officer class:** pick the class whose count equals your number of AI officers. It may be one higher if your
   own character uses the same class; the mod skips you automatically. Put its name in
   `config.officers.classes = { "ThatName" }`.
5. **Team property:** under that class, look for a property with *team*, *squad*, or *element* in its name.
   Put it in `config.officers.team_property = "ThatName"`.
6. **Team values:** restart the game and open the ATAK screen. The roster shows each officer's team. If red
   and blue are swapped, or show as UNKNOWN, adjust the numbers in `config.officers.team_values`.
7. **Door class:** pick the class whose count roughly matches the number of doors in the level. Put it in
   `config.doors.classes`.
8. Restart the game. Officers and yellow door markers should now appear on the ATAK map.

> If a class has properties for the officer's name or health, put them in `name_property` and
> `health_property` to show them in the roster.

---

## Part B: Orders

This is the most important part. You'll record what the game does when *you* give an order with the normal
command wheel, then tell RoNTAK to do the same thing.

### B1: Choose functions to watch

1. In `discovery.txt`, scroll to the **Functions** section.
2. Copy every line that looks like it issues orders. Look for words like `Order`, `Command`, `Issue`, `Stack`,
   `Breach`, `Clear`, `Team`, or `Swat`. When unsure, include it; 20 to 50 is fine.
3. Paste them into `config.sniff` **without** the leading `Function `, each in quotes and followed by a comma:
   ```lua
   config.sniff = {
       "/Script/ReadyOrNot.SomeClass:SomeOrderFunction",
       "/Script/ReadyOrNot.OtherClass:AnotherFunction",
   }
   ```
4. Restart the game.

### B2: Record orders

1. In a mission, press **F9**. The console says `sniffer started on N functions`.
2. Use the in-game command wheel to give **one** order, for example RED → Stack Up on a door.
3. Watch the console. Lines like this appear:
   ```
   sniff: /Script/ReadyOrNot.X:IssueOrder  self=… PlayerController_C …  args=[1, …Door_C_12, 0]
   ```
4. Give a few more orders, changing **one thing at a time**: same order but BLUE, then GOLD; different breach
   types; different grenades. This reveals which number means which team or option.
5. Press **F9** again to stop. Everything is saved to `bridge\sniff.txt`.

> If too many lines appear (functions firing every frame), remove those functions from `config.sniff` and
> try again.

### B3: Fill in config.actions

For each order, write down from the sniff lines:

- the **function name**: the part after `:` in the path
- **what `self` was**: your PlayerController, your character, the door, or some manager object
- **the arguments in order**

Then edit that action. Example: the sniffer showed
`/Script/ReadyOrNot.SWATManager:IssueTeamOrder self=SWATManager args=[1, Door_C_12, 3, 1]`
for RED → Breach & Clear → C2 → Flashbang. The action becomes:

```lua
breach_clear = { target = "SWATManager", fn = "IssueTeamOrder", args = { "$team", "$door", "$breach", "$grenade" } },
```

These names are an **illustration only**. Use what your sniffer shows.

- `target`: `"player_controller"`, `"player_pawn"`, `"door"`, or the class name of whatever `self` was.
- Placeholders: `$team $door $location $breach $grenade $side`. Any other value is passed as-is.
- Then set the numbers you observed in `config.team_args`, `config.breach_args`, `config.grenade_args`,
  and `config.side_args`. Example: if RED sent `1` and BLUE sent `2`, set `red = 1, blue = 2`.

### B4: Test without the ATAK screen

1. Set `config.test_order` to the order you configured.
2. Restart the game, stand near a door, and press **F10**.
3. The console prints `test order: ok` and your team should move. If you get an error instead, it names the
   missing piece.

Then try the same order from the ATAK screen. The order list shows **OK**, **ERROR** (with the reason), or
**NOT CONFIGURED**.

---

## If the sniffer never shows an order

Some games process orders in C++ code that isn't exposed as a function UE4SS can hook. Try these, in order:

1. Hook the **command menu widget's** functions. Search `discovery.txt` for classes with `Widget`, `Menu`,
   or `Wheel`, and sniff their functions. Menu buttons usually end in exposed functions.
2. Use UE4SS's **Live View** tab in the console window to browse the objects and functions of your
   officers and controller while in a mission.
3. Use **Dump CXX Headers** in the UE4SS console to generate full header files for the game, and search
   them for `Order`.

If you get stuck, share the relevant `sniff.txt` / `discovery.txt` lines and I can help map them.

Next: [03-maps.md](03-maps.md)
