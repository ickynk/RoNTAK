# 4. Phase 2: Show it on the in-game ATAK device

Phases 1 to 3 give you a working ATAK on a browser, phone, or second screen. Phase 2 puts the same map on
the game's own ATAK device.

This needs the **Unreal Editor** and the game's actual asset names, so start it only after
[02-discovery](02-discovery.md) works: officers show on the map and at least one order goes through.

## The plan

The data and order logic is already done in the Lua mod. Phase 2 is a display layer:

```
RoNTAK Lua mod  ──(calls a function)──►  RoNTAK widget (Blueprint, in a .pak)  ──►  drawn on the ATAK device
                ◄──(order button)─────
```

1. **Find the device.** In a mission, hold the ATAK and press F8. Look in `discovery.txt` for classes with
   `Tablet`, `ATAK`, `Map`, or `Device` that have 1 live instance. Use UE4SS **Live View** to see which
   widget or render target its screen uses.
2. **Install the matching Unreal Editor.** Use the Epic Games Launcher to install the engine version the game
   uses. The UE4SS log prints it at startup.
3. **Build a widget mod.** Use UE4SS's Blueprint mod loader ("LogicMods"). Create a `ModActor` Blueprint and
   a UMG widget with:
   - an image for the floor plan, with officer and door icons on top
   - team buttons (RED / BLUE / GOLD) and order buttons
   - a custom event `RoNTAK_UpdateState(StateJson)`, called by the Lua mod each tick
   - order buttons that call a custom event the Lua mod hooks with `RegisterCustomEvent`, which then calls
     the same `orders.execute` the companion uses
4. **Put it on the device.** Either replace the device's screen widget, or draw your widget into the render
   target the device's screen material uses.
5. **Package it** as a `.pak` in `ReadyOrNot\Content\Paks\LogicMods\`.

When you reach this phase, share what step 1 finds (class names and how the device's screen is built) and
we'll build the widget together, step by step.
