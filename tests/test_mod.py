"""Runs the UE4SS Lua mod against a fake UE4SS API (needs `pip install lupa`)."""

import json
import tempfile
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
Key = { F6 = "F6", F7 = "F7", F8 = "F8", F9 = "F9", F10 = "F10" }
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
        lua.execute("print = function() end")
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
        self.assertEqual(len(state["configured_actions"]), 10)
        items = {o["id"]: o["items"] for o in state["officers"]}
        self.assertEqual(items["Swat_C_1"]["c2"], 1)
        self.assertEqual(items["Swat_C_1"]["flashbang"], 1)  # one of two is used up
        self.assertEqual(items["Swat_C_1"]["stinger"], 0)
        self.assertEqual(items["Swat_C_2"]["stinger"], 1)
        self.assertEqual(items["Swat_C_2"]["ninebang"], 0)

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
            scans = 0
            local find_all_of = FindAllOf
            function FindAllOf(class) scans = scans + 1 return find_all_of(class) end
        """)
        for _ in range(40):  # 10 s of ticks, all within the same os.time() second here
            state = self.tick()
        # One scan each for the player controller, officers, doors and room points, not one per tick.
        self.assertLessEqual(self.lua.globals().scans, 4)
        self.assertEqual(len(state["officers"]), 2)
        self.assertEqual(len(state["doors"]), 2)

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
        lua.execute("print = function() end")
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
