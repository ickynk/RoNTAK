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

local function actor(n, x, y, z, yaw, props)
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
    IssueOrder = function(self, ...) calls[#calls + 1] = { ... } end,
})

objects = {
    PlayerController = { controller },
    SWATCharacter = {
        pawn, -- the player shares the class and must be skipped
        actor("SWATCharacter_C_1", 100, 200, 0, 0, { TeamId = 0 }),
        actor("SWATCharacter_C_2", 150, 250, 0, 45, { TeamId = 1 }),
    },
    Door = {
        actor("Door_C_7", 500, 0, 0, 90, {
            IsLocked = function() return true end,
            GetSWATKnowsLockState = function() return true end,
        }),
        actor("Door_C_8", 40, 30, 0, 0, {
            IsLocked = function() return true end,
            GetSWATKnowsLockState = function() return false end,
        }),
    },
}

function FindAllOf(class) return objects[class] end
function FindFirstOf(class) return objects[class] and objects[class][1] end
Key = { F8 = "F8", F9 = "F9", F10 = "F10" }
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
        config.officers.classes = lua.table("SWATCharacter")
        config.officers.team_property = "TeamId"
        config.actions.stack_up.fn = "IssueOrder"
        lua.execute('require("main")')

    def tick(self):
        self.lua.execute("loop()")
        return json.loads((self.bridge / "state.json").read_text())

    def send(self, session, commands):
        (self.bridge / "commands.json").write_text(json.dumps({"session": session, "commands": commands}))

    def test_state_contents(self):
        state = self.tick()
        self.assertEqual(state["level"], "RiverwoodHouse")
        self.assertEqual(state["player"]["yaw"], 90)
        self.assertEqual([(o["id"], o["team"]) for o in state["officers"]],
                         [("SWATCharacter_C_1", "red"), ("SWATCharacter_C_2", "blue")])
        self.assertEqual({d["id"]: d.get("locked") for d in state["doors"]}, {"Door_C_7": True, "Door_C_8": None})
        self.assertEqual(state["configured_actions"], ["stack_up"])

    def test_orders_flow(self):
        order = {"team": "red", "action": "stack_up", "target": {"door": "Door_C_7"}, "options": {"side": "left"}}
        self.send("A", [dict(order, id=1)])
        self.tick()  # queued before the mod saw any orders: skipped
        self.assertEqual(len(self.lua.globals().calls), 0)

        self.send("A", [dict(order, id=1), dict(order, id=2),
                        {"id": 3, "team": "blue", "action": "hold", "target": {}, "options": {}}])
        state = self.tick()
        calls = self.lua.globals().calls
        self.assertEqual(len(calls), 1)
        args = calls[1]
        self.assertEqual(args[1], 1)  # config.team_args.red
        self.assertEqual(args[2].GetFName().ToString(), "Door_C_7")
        self.assertEqual(args[3], 2)  # config.side_args.left
        results = {r["id"]: r["status"] for r in state["results"]}
        self.assertEqual(results, {2: "ok", 3: "not_configured"})

        self.tick()  # nothing new: nothing re-run
        self.assertEqual(len(calls), 1)

        self.send("B", [dict(order, id=1, target={"door": "missing"})])  # server restarted
        state = self.tick()
        self.assertEqual(state["results"][0]["status"], "error")
        self.assertIn("no longer exists", state["results"][0]["message"])

    def test_test_order_hotkey_uses_nearest_door(self):
        self.tick()
        self.lua.execute('keybinds["F10"]()')
        args = self.lua.globals().calls[1]
        self.assertEqual(args[2].GetFName().ToString(), "Door_C_8")


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
                obj("SWATCharacter", "Class", nil, { ForEachProperty = function(self, fn) fn(prop) end }),
                obj("Lamp", "Class"),
                obj("IssueTeamOrder", "Function", "Function /Script/ReadyOrNot.SWATManager:IssueTeamOrder"),
                obj("Tick", "Function", "Function /Script/Engine.Actor:Tick"),
            }
            function ForEachUObject(fn) for _, o in ipairs(all) do fn(o) end end
        """)
        self.lua.execute('keybinds["F8"]()')
        text = (self.bridge / "discovery.txt").read_text()
        self.assertIn("    3  SWATCharacter", text)
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
