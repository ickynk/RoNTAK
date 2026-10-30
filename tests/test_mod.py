"""Runs the UE4SS Lua mod against a fake UE4SS API (needs `pip install lupa`)."""

import json
import tempfile
import time
import unittest
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "mod" / "RoNTAK" / "Scripts"

FAKE_UE4SS = r"""
local function name(n) return { ToString = function() return n end } end

function actor(n, x, y, z, yaw, props)
    local a = props or {}
    a.IsValid = function() return true end
    a.GetFName = function() return name(n) end
    a.GetFullName = function() return "BP_C " .. n end
    a.K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end
    a.K2_GetActorRotation = function() return { Yaw = yaw } end
    return a
end

calls = {}
local pawn = actor("PlayerPawn_C_0", 0, 0, 0, 90)
local controller = actor("PlayerController_C_0", 0, 0, 0, 0, {
    Pawn = pawn,
    Player = { IsValid = function() return true end },
    GetWorld = function() return { GetFName = function() return name("RiverwoodHouse") end } end,
})

-- Records every Give...Command call as { fn = name, n = arg count, ... }.
-- RegisterHook stand-in: pre-hooks get params with get()/set(), like UE4SS.
hooks = {}
function RegisterHook(path, fn)
    hooks[path] = hooks[path] or {}
    table.insert(hooks[path], fn)
    return 1, 2
end
function UnregisterHook() end

-- When true, the fake drops class (item) arguments the way UE4SS does in game.
drop_class_args = false

-- Records every Give...Command call as { fn = name, n = arg count, ... }.
local manager = setmetatable({ IsValid = function() return true end }, {
    __index = function(_, fn)
        return function(self, ...)
            local args = table.pack(...)
            if drop_class_args then
                for i = 1, args.n do
                    if type(args[i]) == "table" and args[i].GetFullName then args[i] = "stale" end
                end
            end
            local params = {}
            for i = 1, args.n do
                local index = i
                params[i] = {
                    get = function() return args[index] end,
                    set = function(_, v) args[index] = v end,
                }
            end
            for _, hook in ipairs(hooks["/Script/ReadyOrNot.SWATManager:" .. fn] or {}) do
                hook({ get = function() return self end }, table.unpack(params, 1, args.n))
            end
            args.fn = fn
            calls[#calls + 1] = args
        end
    end,
})

classes = {}
-- TArray stand-in: ForEach(fn) calls fn(index, element) with element:get().
function tarray(values)
    return { ForEach = function(self, fn)
        for i, v in ipairs(values) do fn(i, { get = function() return v end }) end
    end }
end

-- items: list of { class name, EItemCategory, depleted }
local function inventory(items)
    local objs = {}
    for _, entry in ipairs(items) do
        classes[entry[1]] = classes[entry[1]] or {
            name = entry[1],
            GetFullName = function() return "BlueprintGeneratedClass /Game/Items/" .. entry[1] end,
            GetFName = function() return name(entry[1]) end,
            IsValid = function() return true end,
        }
        local class = classes[entry[1]]
        objs[#objs + 1] = {
            IsValid = function() return true end,
            IsDepleted = function() return entry[3] == true end,
            GetClass = function() return class end,
            ItemCategories = tarray({ entry[2] }),
        }
    end
    return { InventoryItems = tarray(objs) }
end

-- Controller whose ThrowGrenadeThroughDoorActivity targets a door with an item class.
function controller_with_throw(door, class)
    return { IsValid = function() return true end, ThrowGrenadeThroughDoorActivity = {
        IsValid = function() return true end,
        Door = door,
        ThrowItemClass = { IsValid = function() return true end, GetFName = function() return name(class) end },
    } }
end

objects = {
    PlayerController = { controller },
    SWATManager = { manager },
    CyberneticsSwat_V2_C = {
        actor("Swat_C_1", 100, 200, 0, 0, { SquadPosition = 2,
            InventoryComp = inventory({ { "C2", 38 }, { "Flashbang", 30 }, { "Flashbang", 30, true }, { "StingerUsed", 33, true } }) }),
        actor("Swat_C_2", 150, 250, 0, 45, { SquadPosition = 0,
            InventoryComp = inventory({ { "Stinger", 33 } }) }),
    },
    Door = {
        actor("Door_C_7", 500, 0, 0, 90, {
            IsLocked = function() return true end,
            GetSWATKnowsLockState = function() return true end,
            GetDoorMidLocation = function() return { X = 500, Y = 20, Z = 0 } end,
            IsOpen = function() return false end,
            IsDoorBroken = function() return false end,
        }),
        actor("Door_C_8", 40, 30, 0, 0, {
            IsLocked = function() return true end,
            GetSWATKnowsLockState = function() return false end,
            IsOpen = function() return true end,
        }),
    },
}

function FindAllOf(class) return objects[class] end
function FindFirstOf(class) return objects[class] and objects[class][1] end
Key = { F5 = "F5", F6 = "F6", F7 = "F7", F8 = "F8", F9 = "F9", F10 = "F10" }
keybinds = {}
function RegisterKeyBind(key, fn) keybinds[key] = fn end
function ExecuteInGameThread(fn) fn() end
loop = nil
function LoopAsync(ms, fn) loop = fn end
"""


class ModTest(unittest.TestCase):
    def setUp(self):
        self.bridge = Path(tempfile.mkdtemp())
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        lua = self.lua
        lua.execute(f'package.path = [[{SCRIPTS}/?.lua;]] .. package.path')
        lua.execute(FAKE_UE4SS)
        lua.execute("print = function(...) if DEBUG_PRINT then io.stderr:write(table.concat({...}, \" \") .. \"\\n\") end end")
        config = lua.eval('(require("config"))')
        config.bridge_dir = str(self.bridge)
        lua.execute('require("main")')

    def tick(self):
        self.lua.execute("loop()")
        return json.loads((self.bridge / "state.json").read_text())

    def send(self, session, commands):
        (self.bridge / "commands.json").write_text(json.dumps({"session": session, "commands": commands}))

    def order(self, cmd_id, team, action, target=None, options=None):
        return {"id": cmd_id, "team": team, "action": action, "target": target or {}, "options": options or {}}

    def run_orders(self, *orders):
        """Sends orders after a first tick, so they are not skipped as stale."""
        self.send("A", [])
        self.tick()
        self.send("A", list(orders))
        return self.tick()

    def call(self, i):
        c = self.lua.globals().calls[i]
        return c.fn, [c[k] for k in range(1, c.n + 1)]

    def test_state_contents(self):
        state = self.tick()
        self.assertEqual(state["level"], "RiverwoodHouse")
        self.assertEqual(state["player"]["yaw"], 90)
        self.assertEqual([(o["id"], o["team"]) for o in state["officers"]],
                         [("Swat_C_1", "red"), ("Swat_C_2", "blue")])
        self.assertEqual({d["id"]: (d.get("locked"), d.get("open"), d.get("broken")) for d in state["doors"]},
                         {"Door_C_7": (True, False, False), "Door_C_8": (None, True, None)})
        self.assertEqual(len(state["configured_actions"]), 21)
        items = {o["id"]: o["items"] for o in state["officers"]}
        self.assertEqual(items["Swat_C_1"]["c2"], 1)
        self.assertEqual(items["Swat_C_1"]["flashbang"], 1)  # one of two is used up
        self.assertEqual(items["Swat_C_1"]["stinger"], 0)
        self.assertEqual(items["Swat_C_2"]["stinger"], 1)
        self.assertEqual(items["Swat_C_2"]["ninebang"], 0)

    def test_officer_names_from_roster_or_squad_slot(self):
        self.lua.execute(r"""
            local function fstr(s) return { ToString = function() return s end } end
            objects.CyberneticsSwat_V2_C[1].RosterCharacter = {
                IsValid = function() return true end, FirstName = fstr("Dennis"), LastName = fstr("Judge"),
            }
            -- An empty roster object: reading from it would be a UE4SS error in game.
            objects.CyberneticsSwat_V2_C[2].RosterCharacter = setmetatable({ IsValid = function() return false end }, {
                __index = function(_, k) error("read " .. k .. " from an empty object") end,
            })
        """)
        state = self.tick()
        names = {o["id"]: o["name"] for o in state["officers"]}
        self.assertEqual(names, {"Swat_C_1": "Dennis Judge", "Swat_C_2": "Alpha"})

    def test_stale_orders_skipped_and_not_rerun(self):
        hold = self.order(1, "blue", "hold")
        self.send("A", [hold])
        self.tick()  # queued before the mod saw any orders: skipped
        self.assertEqual(len(self.lua.globals().calls), 0)
        self.send("A", [hold, self.order(2, "blue", "hold")])
        state = self.tick()
        self.tick()  # nothing new: nothing re-run
        self.assertEqual(len(self.lua.globals().calls), 1)
        self.assertEqual(self.call(1), ("GiveHoldCommand", [2]))
        self.assertEqual(state["results"][0]["status"], "ok")

        self.send("B", [self.order(1, "red", "stack_up", {"door": "missing"})])  # server restarted
        state = self.tick()
        self.assertEqual(state["results"][0]["status"], "error")
        self.assertIn("no longer exists", state["results"][0]["message"])

    def test_stack_up_from_team_side_of_door(self):
        self.run_orders(self.order(1, "red", "stack_up", {"door": "Door_C_7"}, {"side": "left"}))
        fn, args = self.call(1)
        self.assertEqual(fn, "GiveStackUpCommand")
        self.assertEqual(args[0].GetFName().ToString(), "Door_C_7")
        self.assertEqual(args[1], 1)  # TT_SERT_RED
        # Red officer is at (100, 200); door middle at (500, 20): approach from that side.
        nx, ny = args[3]["X"], args[3]["Y"]
        self.assertLess(nx, 0)
        self.assertGreater(ny, 0)
        self.assertAlmostEqual(nx * nx + ny * ny, 1.0)
        self.assertAlmostEqual(args[2]["X"], 500 + nx * 40)
        self.assertEqual(args[4:], [True, 2])  # bCheckDoor, EStackUpStyle Left

    def test_breach_c2_flashbang(self):
        self.run_orders(self.order(1, "gold", "breach_clear", {"door": "Door_C_7"},
                                   {"breach": "c2", "grenade": "flashbang"}))
        fn, args = self.call(1)
        self.assertEqual(fn, "GiveBreachAndClearCommand")
        self.assertEqual(len(args), 12)
        self.assertEqual(args[1:3], [6, 5])  # EDoorBreachType C2, TT_SQUAD
        self.assertEqual(args[4]["name"], "Flashbang")
        self.assertEqual(args[5]["name"], "C2")
        self.assertEqual(args[6:], [False, False, False, False, 0, True])

    def test_open_clear_overrides_breach_and_sends_no_items(self):
        self.run_orders(self.order(1, "blue", "open_clear", {"door": "Door_C_7"}, {"breach": "c2", "grenade": "none"}))
        fn, args = self.call(1)
        self.assertEqual(args[1:3], [1, 2])  # EDoorBreachType Open, TT_SERT_BLUE
        self.assertEqual(args[4:6], [None, None])

    def test_missing_item_is_reported(self):
        state = self.run_orders(self.order(1, "blue", "breach_clear", {"door": "Door_C_7"}, {"breach": "shotgun"}))
        self.assertEqual(len(self.lua.globals().calls), 0)
        self.assertIn("carries the shotgun item", state["results"][0]["message"])

    def test_item_taken_from_officer_who_still_has_one(self):
        # Swat_C_1 carries an empty stinger slot; the class must come from Swat_C_2.
        self.run_orders(self.order(1, "gold", "breach_clear", {"door": "Door_C_7"},
                                   {"breach": "kick", "grenade": "stinger"}))
        fn, args = self.call(1)
        self.assertEqual(args[4]["name"], "Stinger")
        self.assertIsNone(args[5])

    def test_no_item_sends_invalid_object_when_available(self):
        self.lua.execute('function CreateInvalidObject() return { invalid = true } end')
        self.run_orders(self.order(1, "red", "breach_clear", {"door": "Door_C_7"}, {"breach": "kick", "grenade": "none"}))
        fn, args = self.call(1)
        self.assertTrue(args[4]["invalid"])
        self.assertTrue(args[5]["invalid"])

    def test_hook_writes_item_classes_the_call_dropped(self):
        self.lua.execute("drop_class_args = true")
        self.lua.execute("logged = {} print = function(s) logged[#logged + 1] = s end")
        state = self.run_orders(self.order(1, "red", "breach_clear", {"door": "Door_C_7"},
                                           {"breach": "c2", "grenade": "flashbang"}))
        fn, args = self.call(1)
        self.assertEqual(args[4]["name"], "Flashbang")
        self.assertEqual(args[5]["name"], "C2")
        log = "\n".join(self.lua.globals().logged.values())
        self.assertIn("set in call: arg 5 stale -> Flashbang, arg 6 stale -> C2", log)
        self.assertNotIn("message", state["results"][0])  # nothing to show on ATAK when all is well

    def test_breach_order_logs_what_the_game_assigned(self):
        self.lua.execute('objects.CyberneticsSwat_V2_C[1].Controller = controller_with_throw(objects.Door[1], "BP_Flashbang_C")')
        self.lua.execute("logged = {} print = function(s) logged[#logged + 1] = s end")
        state = self.run_orders(self.order(1, "red", "breach_clear", {"door": "Door_C_7"},
                                           {"breach": "kick", "grenade": "flashbang"}))
        log = "\n".join(self.lua.globals().logged.values())
        self.assertIn("order 1: game assigned Swat_C_1 ThrowGrenadeThroughDoor: BP_Flashbang_C", log)
        self.assertNotIn("message", state["results"][0])

    def test_breach_check_when_nobody_assigned(self):
        state = self.run_orders(self.order(1, "blue", "breach_clear", {"door": "Door_C_7"}, {"breach": "kick"}))
        for _ in range(78):
            state = self.tick()
        self.assertNotIn("message", state["results"][0])  # still watching
        for _ in range(2):
            state = self.tick()
        self.assertEqual(state["results"][0]["message"], "the team did not start the breach within 20 s")

    def test_map_info_dump_buildings(self):
        self.lua.execute(r"""
            local function txt(s) return { ToString = function() return s end } end
            objects.BuildingTrigger = { actor("BuildingTrigger_1", 0, 0, 0, 0, {
                BuildingName = txt("House"), NumberOfFloors = 2,
                GeneratedFloors = tarray({
                    { Number = 0, Height = 300, Name = txt("Ground"), Location = { X = 0, Y = 0, Z = 0 }, Extent = { X = 1000, Y = 800, Z = 150 } },
                    { Number = 1, Height = 300, Name = txt("Upstairs"), Location = { X = 0, Y = 0, Z = 300 }, Extent = { X = 1000, Y = 800, Z = 150 } },
                }),
            }) }
        """)
        self.lua.execute('keybinds["F6"]()')
        info = json.loads((self.bridge / "mapinfo.json").read_text())
        self.assertEqual(info["errors"], [])
        building = info["buildings"][0]
        self.assertEqual(building["name"], "House")
        self.assertEqual([f["name"] for f in building["floors"]], ["Ground", "Upstairs"])
        self.assertEqual(building["floors"][1]["location"], {"x": 0, "y": 0, "z": 300})

    def test_rooms_from_threat_points_and_doors(self):
        self.lua.execute(r"""
            local function fname(s) return { ToString = function() return s end } end
            local function point(n, x, y, room, outside)
                return actor(n, x, y, 10, 0, { OwningRoom = fname(room), bIsOutside = outside or false })
            end
            objects.ThreatAwarenessActor = {
                point("T1", 0, 0, "Kitchen"), point("T2", 400, 0, "Kitchen"), point("T3", 400, 300, "Kitchen"),
                point("T4", 0, 300, "Kitchen"), point("T5", 200, 150, "Kitchen"),   -- inside: not on the outline
                point("T6", 900, 900, "Yard", true),                               -- outside: ignored
                point("T7", 500, 500, "None"),                                     -- no room: ignored
            }
            objects.Door[1].GetFrontThreatOwningRoom = function() return fname("Kitchen") end
            objects.Door[1].GetBackThreatOwningRoom = function() return fname("Hallway") end
        """)
        state = self.tick()
        self.assertTrue(state["rooms_version"].startswith("RiverwoodHouse#2#"))
        door = next(d for d in state["doors"] if d["id"] == "Door_C_7")
        self.assertEqual((door["front_room"], door["back_room"]), ("Kitchen", "Hallway"))
        data = json.loads((self.bridge / "rooms.json").read_text())
        rooms = {r["name"]: r for r in data["rooms"]}
        self.assertEqual(set(rooms), {"Kitchen", "Hallway"})
        self.assertEqual(sorted(map(tuple, rooms["Kitchen"]["hull"])), [(0, 0), (0, 300), (400, 0), (400, 300)])
        self.assertEqual(rooms["Kitchen"]["points"], 5)
        self.assertEqual(rooms["Kitchen"]["z"], 10)
        self.assertEqual(rooms["Kitchen"]["doors"], ["Door_C_7"])
        self.assertEqual(rooms["Hallway"]["hull"], [])
        self.assertEqual(rooms["Hallway"]["doors"], ["Door_C_7"])

        version = state["rooms_version"]
        for _ in range(10):
            state = self.tick()
        self.assertEqual(state["rooms_version"], version)  # built once per level

    def test_activity_dump(self):
        self.lua.execute('objects.CyberneticsSwat_V2_C[1].Controller = controller_with_throw(objects.Door[1], "BP_Flashbang_C")')
        self.lua.execute('keybinds["F7"]()')
        text = (self.bridge / "activities.txt").read_text()
        self.assertIn("Swat_C_1 (red)", text)
        self.assertIn("ThrowGrenadeThroughDoor", text)
        self.assertIn("door=Door_C_7", text)
        self.assertIn("item=BP_Flashbang_C", text)
        self.assertIn("Swat_C_2 (blue)  ERROR: no controller", text)

    def test_move_and_clear_on_open_door(self):
        self.run_orders(self.order(1, "red", "move_clear", {"door": "Door_C_8"}, {"grenade": "flashbang"}))
        fn, args = self.call(1)
        self.assertEqual(fn, "GiveBreachAndClearCommand")
        self.assertEqual(args[1:3], [2, 1])  # EDoorBreachType Move, TT_SERT_RED
        self.assertEqual(args[4]["name"], "Flashbang")

    def test_move_and_search_use_map_point_or_player(self):
        self.run_orders(self.order(1, "red", "move_to", {"location": {"x": 7, "y": 8, "z": 9}}),
                        self.order(2, "gold", "search_secure"))
        fn, args = self.call(1)
        self.assertEqual((fn, args[0], dict(args[1])), ("GiveMoveCommand", 1, {"X": 7, "Y": 8, "Z": 9}))
        fn, args = self.call(2)
        self.assertEqual(fn, "GiveSearchAndSecureCommand")
        self.assertEqual(args[0], 5)
        self.assertEqual(dict(args[1]), {"X": 0, "Y": 0, "Z": 0})  # player position
        self.assertEqual(args[2], False)

    def test_object_scans_are_cached_across_ticks(self):
        self.lua.execute(r"""
            scans = {}
            local find_all_of = FindAllOf
            function FindAllOf(class) scans[class] = (scans[class] or 0) + 1 return find_all_of(class) end
        """)
        for _ in range(40):  # 10 s of ticks, all within the same os.time() second here
            state = self.tick()
        # One scan per class (player controller, officers, doors, room points, people, cameras), not one per tick.
        scans = dict(self.lua.globals().scans)
        self.assertEqual(set(scans.values()), {1}, scans)
        self.assertEqual(len(state["officers"]), 2)
        self.assertEqual(len(state["doors"]), 2)

    def test_no_tick_stacks_scans_or_door_reads(self):
        """Over 3 minutes of game time, no tick runs more than one FindAllOf
        rescan or re-reads every door at once (that was a hitch every 2 s)."""
        self.add_people()
        self.add_cameras()
        self.lua.execute(r"""
            clock = 0
            os.time = function() return math.floor(clock) end
            scans, door_reads = 0, 0
            local find_all_of = FindAllOf
            function FindAllOf(class) scans = scans + 1 return find_all_of(class) end
            for _, d in ipairs(objects.Door) do
                local is_open = d.IsOpen
                d.IsOpen = function(...) door_reads = door_reads + 1 return is_open(...) end
            end
        """)
        g = self.lua.globals()
        worst_scans = worst_doors = 0
        for i in range(720):  # 3 minutes at 4 ticks per second
            g.scans, g.door_reads = 0, 0
            self.tick()
            if i > 0:  # the first tick of a level may scan everything
                worst_scans = max(worst_scans, g.scans)
                worst_doors = max(worst_doors, g.door_reads)
            g.clock = g.clock + 0.25
        self.assertLessEqual(worst_scans, 1)
        self.assertLessEqual(worst_doors, 1)  # 2 doors here, one per tick

    def add_people(self):
        self.lua.execute(r"""
            local function person(n, x, flags)
                local p = actor(n, x, 0, 0, 0, {})
                for _, f in ipairs({ "IsSuspect", "IsCivilian", "IsSurrendered", "IsArrested",
                                     "IsDeadOrUnconscious", "HasBeenReported" }) do
                    p[f] = function() return flags[f] == true end
                end
                return p
            end
            objects.CyberneticCharacter = {
                person("Suspect_Surrendered", 100, { IsSuspect = true, IsSurrendered = true }),
                person("Suspect_Active", 200, { IsSuspect = true }),                      -- a threat: never shown
                person("Civilian_Down", 300, { IsCivilian = true, IsDeadOrUnconscious = true, HasBeenReported = true }),
                person("Suspect_Cuffed", 400, { IsSuspect = true, IsSurrendered = true, IsArrested = true }),
                person("Swat_Other", 500, {}),                                            -- neither: never shown
            }
        """)

    def test_people_only_when_no_longer_a_threat(self):
        self.add_people()
        state = self.tick()
        people = {t["id"]: (t["kind"], t["status"], t["reported"]) for t in state["targets"]}
        self.assertEqual(people, {
            "Suspect_Surrendered": ("suspect", "surrendered", False),
            "Civilian_Down": ("civilian", "down", True),
            "Suspect_Cuffed": ("suspect", "arrested", False),
        })

    def add_cameras(self):
        self.lua.execute(r"""
            local function component(x, y, z, yaw, pitch, props)
                local comp = props or {}
                comp.IsValid = function() return true end
                comp.K2_GetComponentLocation = function() return { X = x, Y = y, Z = z } end
                comp.K2_GetComponentRotation = function() return { Yaw = yaw, Pitch = pitch } end
                return comp
            end
            local function fstr(s) return { ToString = function() return s end } end
            tracking = { IsValid = function() return true end, bHasTarget = false }
            objects.Helicopter = { actor("Helicopter_C_1", 0, 0, 3000, 10, {
                RadialTrackingComponent = tracking,
                TrackingCameraComponent = { IsValid = function() return true end,
                    IsCameraActive = function() return true end,
                    CaptureComponent = component(0, 0, 2900, 30, -60, { FOVAngle = 40 }) },
            }) }
            objects.UnmannedVehicle = { actor("Drone_C_1", 50, 60, 100, 180, {
                IsAlive = function() return true end,
                GetTabletNameText = function() return fstr("Drone") end,
                GetTabletViewComponent = function() return component(50, 60, 110, 170, -10) end,
                FirstPersonCamera = { IsValid = function() return true end, FieldOfView = 90 },
            }) }
            objects.CCTVCameraPoint = {
                actor("CCTV_C_1", 0, 0, 0, 0, { CameraName = fstr("Lobby"), FloorNumber = 0, CameraNumber = 1,
                    CaptureComponent = component(10, 20, 250, 45, -20, { FOVAngle = 80 }) }),
                actor("CCTV_C_2", 0, 0, 0, 0, { CameraName = fstr("Office"), FloorNumber = 1, CameraNumber = 1,
                    CaptureComponent = component(30, 40, 550, 90, -20, { FOVAngle = 80 }) }),
            }
            wired = false
            objects.CCTVSystem = { { IsValid = function() return true end, IsWired = function() return wired end } }
        """)

    def hook(self, name, *args):
        self.lua.globals().fire_hook(name, *args)

    def test_cctv_only_once_wired_and_viewed_camera_marked(self):
        self.add_cameras()
        self.lua.execute(r"""
            function fire_hook(name, value)
                for _, fn in ipairs(hooks[name] or {}) do fn({}, { get = function() return value end }) end
            end
        """)
        state = self.tick()
        self.assertEqual(state["cameras"]["cctv"], {"wired": False, "cameras": []})
        self.lua.execute("wired = true")
        time.sleep(1.1)  # wired state is re-read once a second
        state = self.tick()
        cctv = state["cameras"]["cctv"]
        self.assertTrue(cctv["wired"])
        self.assertNotIn("viewing", cctv)
        self.assertEqual([(c["name"], c["floor"], c["view"]["fov"], c["view"]["yaw"]) for c in cctv["cameras"]],
                         [("Lobby", 0, 80, 45), ("Office", 1, 80, 90)])
        self.lua.execute("objects.PlayerController[1].Pawn.CurrentViewCamera = objects.CCTVCameraPoint[2]")
        state = self.tick()
        self.assertEqual(state["cameras"]["cctv"]["viewing"], "CCTV_C_2")

    def test_cameras_can_be_switched_off(self):
        self.add_cameras()
        self.lua.execute('require("config").cameras.enabled = false')
        self.assertNotIn("cameras", self.tick())  # nil is left out of state.json

    def test_watching_a_feed_counts_as_wired(self):
        self.add_cameras()
        self.lua.execute("objects.PlayerController[1].Pawn.CurrentViewCamera = objects.CCTVCameraPoint[1]")
        cctv = self.tick()["cameras"]["cctv"]
        self.assertEqual((cctv["wired"], cctv["viewing"], len(cctv["cameras"])), (True, "CCTV_C_1", 2))

    def test_helicopter_and_drone_views(self):
        self.add_cameras()
        cams = self.tick()["cameras"]
        heli = cams["helicopters"][0]
        self.assertEqual((heli["id"], heli["pos"]["z"], heli["tracking"], heli["camera_active"], heli["viewing"]),
                         ("Helicopter_C_1", 3000, False, True, False))
        self.assertEqual((heli["view"]["yaw"], heli["view"]["pitch"], heli["view"]["fov"]), (30, -60, 40))
        drone = cams["drones"][0]
        self.assertEqual((drone["name"], drone["view"]["yaw"], drone["view"]["fov"]), ("Drone", 170, 90))
        self.lua.execute("objects.PlayerController[1].Pawn.CurrentViewHelicopter = objects.Helicopter[1]")
        self.assertTrue(self.tick()["cameras"]["helicopters"][0]["viewing"])

    def test_helicopter_tracked_people_are_marked(self):
        self.add_people()
        self.add_cameras()
        self.lua.execute(r"""
            function fire_hook(name, value)
                for _, fn in ipairs(hooks[name] or {}) do fn({}, { get = function() return value end }) end
            end
        """)
        found = "/Script/ReadyOrNot.Helicopter:OnTargetFound"
        lost = "/Script/ReadyOrNot.Helicopter:OnTargetLost"
        self.tick()
        self.lua.execute(f'fire_hook("{found}", objects.CyberneticCharacter[2])')  # Suspect_Active
        people = {t["id"]: t for t in self.tick()["targets"]}
        self.assertEqual((people["Suspect_Active"]["kind"], people["Suspect_Active"]["status"],
                          people["Suspect_Active"]["source"]), ("suspect", "tracked", "helicopter"))
        self.assertEqual(people["Suspect_Active"]["pos"]["x"], 200)
        # Lost: stays on the map at its last known position.
        self.lua.execute(f'fire_hook("{lost}", 1)')
        self.lua.execute("objects.CyberneticCharacter[2].K2_GetActorLocation = function() return { X = 999, Y = 0, Z = 0 } end")
        people = {t["id"]: t for t in self.tick()["targets"]}
        self.assertEqual((people["Suspect_Active"]["status"], people["Suspect_Active"]["pos"]["x"]), ("last_seen", 200))
        # Tracking someone already shown (surrendered) does not add a second marker.
        self.lua.execute(f'fire_hook("{found}", objects.CyberneticCharacter[1])')
        ids = [t["id"] for t in self.tick()["targets"]]
        self.assertEqual(ids.count("Suspect_Surrendered"), 1)
        # Officers or other characters are never marked.
        self.lua.execute(f'fire_hook("{found}", objects.CyberneticCharacter[5])')
        self.assertNotIn("Swat_Other", [t["id"] for t in self.tick()["targets"]])

    def cctv_scene(self, los):
        """Wired CCTV, and Suspect_Active standing in front of camera Lobby."""
        self.add_people()
        self.add_cameras()
        self.lua.execute(f"""
            wired = true
            los_points = {{}}
            local p = objects.CyberneticCharacter[2]
            p.K2_GetActorLocation = function() return {{ X = 600, Y = 600, Z = 0 }} end
            p.HasLineOfSightTo = function(self, point) los_points[#los_points + 1] = point return {str(los).lower()} end
            -- Behind the camera: never checked.
            objects.CyberneticCharacter[3].K2_GetActorLocation = function() return {{ X = -500, Y = -500, Z = 0 }} end
        """)
        for _ in range(4):  # level start; scans are spread over the first ticks
            state = self.tick()
        return {t["id"]: t for t in state["targets"]}

    def test_cctv_marks_people_in_view_with_line_of_sight(self):
        people = self.cctv_scene(los=True)
        seen = people["Suspect_Active"]
        self.assertEqual((seen["kind"], seen["status"], seen["source"], seen["camera"]), ("suspect", "tracked", "cctv", "Lobby"))
        self.assertEqual(seen["pos"], {"x": 600, "y": 600, "z": 0})
        point = dict(self.lua.globals().los_points[1])
        self.assertGreater(point["X"], 10)  # checked from just in front of the lens
        self.assertEqual(sorted(people), ["Civilian_Down", "Suspect_Active", "Suspect_Cuffed", "Suspect_Surrendered"])

    def test_cctv_needs_line_of_sight(self):
        people = self.cctv_scene(los=False)
        self.assertNotIn("Suspect_Active", people)
        self.assertGreater(len(self.lua.globals().los_points), 0)

    def test_cctv_does_not_spot_until_wired(self):
        self.add_people()
        self.add_cameras()
        self.lua.execute("objects.CyberneticCharacter[2].K2_GetActorLocation = function() return { X = 600, Y = 600, Z = 0 } end")
        self.lua.execute("objects.CyberneticCharacter[2].HasLineOfSightTo = function() return true end")
        self.tick()
        self.assertNotIn("Suspect_Active", [t["id"] for t in self.tick()["targets"]])

    def test_officer_health_status(self):
        self.lua.execute(r"""
            local o = objects.CyberneticsSwat_V2_C
            o[1].GetHealthStatus = function() return 1 end
            o[1].GetCurrentHealth = function() return 45 end
            o[1].GetMaxHealth = function() return 100 end
            o[2].GetHealthStatus = function() return 4 end
            o[2].GetCurrentHealth = function() return 0 end
            o[2].GetMaxHealth = function() return 150 end
        """)
        officers = {o["id"]: (o["status"], o["health"]) for o in self.tick()["officers"]}
        self.assertEqual(officers, {"Swat_C_1": ("injured", 45), "Swat_C_2": ("dead", 0)})

    def test_restrain_and_report(self):
        self.add_people()
        self.tick()
        self.run_orders(self.order(1, "red", "restrain", {"character": "Suspect_Surrendered", "location": {"x": 100, "y": 0}}),
                        self.order(2, "blue", "report", {"character": "Civilian_Down"}))
        fn, args = self.call(1)
        self.assertEqual((fn, args[0].GetFName().ToString(), args[1]), ("GiveRestrainCommand", "Suspect_Surrendered", 1))
        self.assertEqual(dict(args[2]), {"X": 100, "Y": 0, "Z": 0})
        fn, args = self.call(2)
        self.assertEqual((fn, args[0].GetFName().ToString(), args[1]), ("GiveReportTargetCommand", "Civilian_Down", 2))

    def test_new_door_and_spot_orders(self):
        self.run_orders(self.order(1, "red", "pick_lock", {"door": "Door_C_7"}),
                        self.order(2, "red", "scan_open", {"door": "Door_C_7"}, {"scan": "snap"}),
                        self.order(3, "blue", "remove_wedge", {"door": "Door_C_7"}),
                        self.order(4, "gold", "chemlight", {"location": {"x": 1, "y": 2, "z": 3}}))
        self.assertEqual([self.call(i)[0] for i in range(1, 5)],
                         ["GivePickLockCommand", "GiveScanDoorCommand", "GiveRemoveWedgeCommand", "GiveDropChemlightAtLocation"])
        self.assertEqual(self.call(2)[1][3], 3)  # EDoorScanMethod Snap
        self.assertEqual(len(self.call(3)[1]), 4)  # door, team, location, normal

    def test_deploy_grenade_at_spot_writes_class_from_hook(self):
        self.lua.execute("drop_class_args = true")
        self.run_orders(self.order(1, "red", "deploy_grenade", {"location": {"x": 5, "y": 6}}, {"grenade": "flashbang"}))
        fn, args = self.call(1)
        self.assertEqual((fn, args[0], args[2]["name"]), ("GiveDeployGrenadeAtLocation", 1, "Flashbang"))

    def test_door_wedge_and_trap_state(self):
        self.lua.execute("objects.Door[1].IsJammed = function() return true end "
                         "objects.Door[1].HasTrapAndSWATKnowsTrap = function() return true end")
        state = self.tick()
        door = next(d for d in state["doors"] if d["id"] == "Door_C_7")
        self.assertEqual((door["wedged"], door["trap"]), (True, True))

    def test_held_orders_start_together_on_go(self):
        self.send("A", [])
        self.tick()
        hold_red = dict(self.order(1, "red", "hold"), hold=True)
        hold_blue = dict(self.order(2, "blue", "fall_in"), hold=True)
        self.send("A", [hold_red, hold_blue])
        state = self.tick()
        self.assertEqual(len(self.lua.globals().calls), 0)
        self.assertEqual([h["team"] for h in state["held"]], ["red", "blue"])
        self.assertEqual({r["id"]: r["status"] for r in state["results"]}, {1: "held", 2: "held"})

        self.send("A", [hold_red, hold_blue, self.order(3, "gold", "go")])
        state = self.tick()
        self.assertEqual([self.call(i)[0] for i in (1, 2)], ["GiveHoldCommand", "GiveFallInCommand"])
        self.assertEqual(state["held"], [])
        results = {r["id"]: (r["status"], r.get("message")) for r in state["results"]}
        self.assertEqual(results, {1: ("ok", None), 2: ("ok", None), 3: ("ok", "started 2 held orders")})

    def test_gold_hold_replaces_team_holds_and_f5_starts(self):
        self.send("A", [])
        self.tick()
        self.send("A", [dict(self.order(1, "red", "hold"), hold=True), dict(self.order(2, "gold", "fall_in"), hold=True)])
        state = self.tick()
        self.assertEqual([h["team"] for h in state["held"]], ["gold"])
        self.lua.execute('keybinds["F5"]()')
        self.assertEqual(self.call(1), ("GiveFallInCommand", [5, 0]))

    def test_clear_held(self):
        self.send("A", [])
        self.tick()
        self.send("A", [dict(self.order(1, "red", "hold"), hold=True), self.order(2, "red", "clear_held")])
        state = self.tick()
        self.assertEqual(state["held"], [])
        self.assertEqual(next(r for r in state["results"] if r["id"] == 1)["status"], "cancelled")

    def test_test_order_hotkey(self):
        self.tick()
        self.lua.execute('keybinds["F10"]()')
        self.assertEqual(self.call(1), ("GiveFallInCommand", [5, 0]))


class DiscoveryTest(ModTest):
    def test_dump_lists_classes_with_counts_and_functions(self):
        self.lua.execute(r"""
            local function obj(n, kind, full, extra)
                local o = extra or {}
                o.GetFName = function() return { ToString = function() return n end } end
                o.GetFullName = function() return full or n end
                o.GetClass = function() return { GetFName = function() return { ToString = function() return kind end } end } end
                return o
            end
            local prop = obj("TeamId", "EnumProperty")
            local all = {
                obj("CyberneticsSwat_V2_C", "Class", nil, { ForEachProperty = function(self, fn) fn(prop) end }),
                obj("Lamp", "Class"),
                obj("IssueTeamOrder", "Function", "Function /Script/ReadyOrNot.SWATManager:IssueTeamOrder"),
                obj("Tick", "Function", "Function /Script/Engine.Actor:Tick"),
            }
            function ForEachUObject(fn) for _, o in ipairs(all) do fn(o) end end
        """)
        self.lua.execute('keybinds["F8"]()')
        text = (self.bridge / "discovery.txt").read_text()
        self.assertIn("    2  CyberneticsSwat_V2_C", text)
        self.assertIn(". TeamId (EnumProperty)", text)
        self.assertIn("/Script/ReadyOrNot.SWATManager:IssueTeamOrder", text)
        self.assertNotIn("Lamp", text)
        self.assertNotIn("Actor:Tick", text)


class SnifferTest(unittest.TestCase):
    def test_logs_args_vectors_and_context(self):
        bridge = Path(tempfile.mkdtemp())
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(f'package.path = [[{SCRIPTS}/?.lua;]] .. package.path')
        lua.execute(FAKE_UE4SS)
        lua.execute("print = function(...) if DEBUG_PRINT then io.stderr:write(table.concat({...}, \" \") .. \"\\n\") end end")
        lua.execute(r"""
            hooks = {}
            function RegisterHook(path, fn) hooks[path] = fn return 1, 2 end
            function UnregisterHook() end
            objects.SwatCommandWidget = { { IsValid = function() return true end, ActiveTeamType = 2 } }
        """)
        config = lua.eval('(require("config"))')
        config.bridge_dir = str(bridge)
        lua.execute('require("main")')
        lua.execute(r"""
            keybinds["F9"]()
            local function param(v) return { get = function() return v end } end
            hooks["/Script/ReadyOrNot.SwatCommandWidget:OnCommandIssued"](param(objects.Door[1]), param(1), param({ X = 10, Y = 20, Z = 30 }))
            keybinds["F9"]()
        """)
        text = (bridge / "sniff.txt").read_text()
        self.assertIn("SwatCommandWidget:OnCommandIssued", text)
        self.assertIn("args=[1, (10, 20, 30)]", text)
        self.assertIn("SwatCommandWidget.ActiveTeamType=2", text)


class JsonTest(unittest.TestCase):
    def test_round_trip(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(f'package.path = [[{SCRIPTS}/?.lua;]] .. package.path')
        text = '{"a":[1,2.5,-3e2,true,false,null],"b":{"c":"q\\"uote\\n\\u00e9"},"e":{},"f":[]}'
        out = lua.eval(f'require("json").encode(require("json").decode([==[{text}]==]))')
        self.assertEqual(json.loads(out), json.loads(text))


if __name__ == "__main__":
    unittest.main()
