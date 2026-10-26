"""Simulated Ready or Not session for testing the ATAK interface without the game.

It speaks the same bridge protocol as the mod: writes state.json, reads
commands.json. Run through `python server.py --mock`.

`python mock.py --write-map` regenerates maps/MockHouse (floor plan + map.json).
"""

import json
import math
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LEVEL = "MockHouse"
TICK = 0.25
SPEED = 260.0  # cm/s

# The floor plan is drawn in image pixels; the world uses Unreal units (cm).
# Image right = world +Y, image up = world +X, 0.5 px per cm.
WORLD_TOP_X = 1500.0


def px_to_world(u, v):
    return (WORLD_TOP_X - 2 * v, 2 * u)


def world_to_px(x, y):
    return (y / 2, (WORLD_TOP_X - x) / 2)


ROOMS_PX = {
    "Kitchen": (0, 0, 400, 300),
    "Living Room": (400, 0, 1000, 300),
    "Hallway": (0, 300, 1000, 450),
    "Bedroom": (0, 450, 350, 750),
    "Bathroom": (350, 450, 600, 750),
    "Office": (600, 450, 1000, 750),
}

# id: (u, v, wall orientation, room, stack direction in px, locked)
OPEN_DOORS = {"BP_Door_C_2"}
WEDGED_DOORS = {"BP_Door_C_3"}
TRAPPED_DOORS = {"BP_Door_C_4"}

DOOR_ACTIONS = ("stack_up", "open_clear", "breach_clear", "move_clear", "scan_door", "wedge_door", "pick_lock",
                "close_door", "remove_wedge", "check_traps", "disarm_trap", "scan_open")
SPOT_ACTIONS = ("move_to", "cover_area", "chemlight", "deploy_grenade")
ALL_ACTIONS = DOOR_ACTIONS + SPOT_ACTIONS + ("fall_in", "hold", "search_secure", "restrain", "report")
DOORS_PX = {
    "BP_Door_C_1": (200, 300, "h", "Kitchen", (0, 1), False),
    "BP_Door_C_2": (700, 300, "h", "Living Room", (0, 1), False),
    "BP_Door_C_3": (175, 450, "h", "Bedroom", (0, -1), False),
    "BP_Door_C_4": (475, 450, "h", "Bathroom", (0, -1), False),
    "BP_Door_C_5": (800, 450, "h", "Office", (0, -1), True),
    "BP_Door_C_6": (1000, 375, "v", "Hallway", (1, 0), False),
}

UNCONFIGURED = set()
BREACH_ITEMS = {"c2", "shotgun", "ram"}


def room_center_world(name):
    u0, v0, u1, v1 = ROOMS_PX[name]
    return px_to_world((u0 + u1) / 2, (v0 + v1) / 2)


def px_dir_to_world(du, dv):
    return (-dv, du)  # derivative of px_to_world, normalised


class Officer:
    def __init__(self, oid, name, team, u, v, items):
        x, y = px_to_world(u, v)
        self.id, self.name, self.team, self.items = oid, name, team, dict(items)
        self.pos = [x, y, 0.0]
        self.yaw = 180.0
        self.path = []
        self.follow = None

    def step(self, dt, player):
        if self.follow is not None:
            px, py = player["pos"]["x"], player["pos"]["y"]
            ang = math.radians(player["yaw"] + 180 + self.follow)
            goal = (px + 150 * math.cos(ang), py + 150 * math.sin(ang))
            if math.dist(goal, self.pos[:2]) > 60:
                self.path = [goal]
        if not self.path:
            return
        gx, gy = self.path[0]
        dx, dy = gx - self.pos[0], gy - self.pos[1]
        d = math.hypot(dx, dy)
        move = SPEED * dt
        if d > 1:
            self.yaw = math.degrees(math.atan2(dy, dx))
        if d <= move:
            self.pos[0], self.pos[1] = gx, gy
            self.path.pop(0)
        else:
            self.pos[0] += dx / d * move
            self.pos[1] += dy / d * move

    def state(self):
        return {"id": self.id, "name": self.name, "team": self.team,
                "pos": {"x": self.pos[0], "y": self.pos[1], "z": self.pos[2]},
                "yaw": self.yaw, "health": 100, "items": self.items}


class MockGame:
    def __init__(self):
        self.officers = [
            Officer("SWATCharacter_C_1", "Judge", "red", 1050, 340, {"c2": 1, "flashbang": 2, "mirror": 1, "multitool": 1}),
            Officer("SWATCharacter_C_2", "Hayes", "red", 1050, 370, {"ram": 1, "stinger": 1, "wedge": 2, "chemlight": 3}),
            Officer("SWATCharacter_C_3", "Kona", "blue", 1050, 400, {"shotgun": 1, "cs": 1, "lockpick_gun": 1}),
            Officer("SWATCharacter_C_4", "Sierra", "blue", 1050, 430, {"launcher": 1, "ninebang": 1, "chemlight": 2}),
        ]
        self.player_route = [px_to_world(u, v) for u, v in ((1060, 375), (1075, 330), (1075, 420))]
        self.player = {"pos": {"x": 0, "y": 0, "z": 0}, "yaw": 180.0}
        self.player_t = 0.0
        self.doors = {}
        for did, (u, v, wall, room, stack, locked) in DOORS_PX.items():
            x, y = px_to_world(u, v)
            self.doors[did] = {
                "id": did, "pos": {"x": x, "y": y, "z": 0.0},
                "yaw": 90.0 if wall == "h" else 0.0, "locked": locked,
                "open": did in OPEN_DOORS, "broken": False,
                "wedged": did in WEDGED_DOORS, "trap": did in TRAPPED_DOORS,
                "_room": room, "_stack": px_dir_to_world(*stack),
            }
        # The game's rooms: on each side of a door, and outlined by threat points.
        for d in self.doors.values():
            d["front_room"] = d["_room"]
            d["back_room"] = "Hallway" if d["_room"] != "Hallway" else None
        self.rooms_written = False
        # People who are no threat any more: shown so they can be restrained or reported.
        self.targets = []
        for tid, kind, status, (u, v) in (("Suspect_C_1", "suspect", "surrendered", (520, 160)),
                                          ("Civilian_C_1", "civilian", "down", (180, 620))):
            x, y = px_to_world(u, v)
            self.targets.append({"id": tid, "kind": kind, "status": status, "reported": False,
                                 "pos": {"x": x, "y": y, "z": 0.0}})
        self.clock = 0.0
        self.spotted = None
        self.held = {}
        self.results = []
        self.session = None
        self.last_id = 0
        self.seq = 0

    def team(self, team):
        return [o for o in self.officers if team == "gold" or o.team == team]

    def update_player(self, dt):
        self.player_t += dt * 0.15
        n = len(self.player_route)
        i = int(self.player_t) % n
        f = self.player_t % 1
        (ax, ay), (bx, by) = self.player_route[i], self.player_route[(i + 1) % n]
        self.player["pos"] = {"x": ax + (bx - ax) * f, "y": ay + (by - ay) * f, "z": 0.0}
        self.player["yaw"] = math.degrees(math.atan2(by - ay, bx - ax))

    def stack_points(self, door, count, side):
        sx, sy = door["_stack"]
        tx, ty = -sy, sx
        pts = []
        for i in range(count):
            depth = 90 + (i // 2) * 70 if side in ("auto", "split") else 90 + i * 60
            if side == "left":
                lateral = 60
            elif side == "right":
                lateral = -60
            else:
                lateral = 60 if i % 2 == 0 else -60
            pts.append((door["pos"]["x"] + sx * depth + tx * lateral,
                        door["pos"]["y"] + sy * depth + ty * lateral))
        return pts

    def execute(self, cmd):
        result = {"id": cmd["id"], "team": cmd["team"], "action": cmd["action"]}
        action = cmd["action"]
        if action in UNCONFIGURED:
            return dict(result, status="not_configured", message=f"set config.actions.{action}.fn")
        members = self.team(cmd["team"])
        target = cmd.get("target") or {}
        options = cmd.get("options") or {}
        door = self.doors.get(target.get("door"))

        for o in members:
            o.follow = None

        if action in DOOR_ACTIONS:
            if not door:
                return dict(result, status="error", message="this order needs a door")
            if action == "open_clear" and door["locked"]:
                return dict(result, status="error", message="door is locked, use breach")
            # Like the mod: refuse items nobody on the team has left.
            needed = [options.get("grenade")] if options.get("grenade", "none") != "none" else []
            if action == "breach_clear" and options.get("breach") in BREACH_ITEMS:
                needed.append(options["breach"])
            needed += {"wedge_door": ["wedge"], "scan_door": ["mirror"]}.get(action, [])
            if action == "pick_lock":
                needed.append("multitool" if any(o.items.get("multitool", 0) for o in members) else "lockpick_gun")
            for item in needed:
                carrier = next((o for o in members if o.items.get(item, 0) > 0), None)
                if not carrier:
                    return dict(result, status="error", message=f"no officer on {cmd['team']} carries {item}")
                carrier.items[item] -= 1
            stack = self.stack_points(door, len(members), options.get("side", "auto"))
            for i, o in enumerate(members):
                o.path = [stack[i]]
                if action in ("open_clear", "breach_clear", "move_clear"):
                    cx, cy = room_center_world(door["_room"])
                    ang = i * math.pi / 2
                    o.path += [(door["pos"]["x"], door["pos"]["y"]),
                               (cx + 80 * math.cos(ang), cy + 80 * math.sin(ang))]
            if action in ("open_clear", "breach_clear", "move_clear"):
                door["locked"] = False
                door["open"] = True
            door.update({"pick_lock": {"locked": False}, "close_door": {"open": False},
                         "remove_wedge": {"wedged": False}, "disarm_trap": {"trap": False}}.get(action, {}))
        elif action in ("restrain", "report"):
            person = next((t for t in self.targets if t["id"] == target.get("character")), None)
            if not person:
                return dict(result, status="error", message="that person is no longer on the map")
            if action == "restrain":
                person["status"] = "arrested"
            else:
                person["reported"] = True
        elif action in ("cover_area", "chemlight", "deploy_grenade"):
            pass
        elif action == "move_to":
            loc = target.get("location")
            if not loc:
                return dict(result, status="error", message="this order needs a map location")
            for i, o in enumerate(members):
                ang = i * math.pi / 2
                o.path = [(loc["x"] + 60 * math.cos(ang), loc["y"] + 60 * math.sin(ang))]
        elif action == "fall_in":
            for i, o in enumerate(members):
                o.follow = (i - (len(members) - 1) / 2) * 35
        elif action == "hold":
            for o in members:
                o.path = []
        return dict(result, status="ok")

    def dispatch(self, cmd):
        """Like the mod: run now, hold for GO, or start / clear the held orders."""
        result = {"id": cmd["id"], "team": cmd["team"], "action": cmd["action"]}
        if cmd["action"] == "go":
            held, self.held = self.held, {}
            for entry in held.values():
                entry["result"].update(self.execute(entry["cmd"]))
            return dict(result, status="ok", message=f"started {len(held)} held orders")
        if cmd["action"] == "clear_held":
            for entry in self.held.values():
                entry["result"].update(status="cancelled", message="cleared before GO")
            self.held = {}
            return dict(result, status="ok")
        if cmd.get("hold"):
            if cmd["team"] == "gold":
                self.held = {}
            else:
                self.held.pop("gold", None)
            result["status"] = "held"
            self.held[cmd["team"]] = {"cmd": cmd, "result": result}
            return result
        return self.execute(cmd)

    def read_commands(self, bridge):
        try:
            doc = json.loads((bridge / "commands.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []
        if doc.get("session") != self.session:
            self.session, self.last_id = doc.get("session"), 0
        fresh = sorted((c for c in doc.get("commands", []) if c.get("id", 0) > self.last_id), key=lambda c: c["id"])
        if fresh:
            self.last_id = fresh[-1]["id"]
        return fresh

    def write_rooms(self, bridge):
        """rooms.json as the mod writes it: threat points inset from the walls."""
        rooms = []
        for name, (u0, v0, u1, v1) in ROOMS_PX.items():
            inset = 30
            hull = [list(px_to_world(u, v)) for u, v in
                    ((u0 + inset, v0 + inset), (u1 - inset, v0 + inset), (u1 - inset, v1 - inset), (u0 + inset, v1 - inset))]
            doors = [did for did, d in self.doors.items() if name in (d["front_room"], d["back_room"])]
            rooms.append({"name": name.replace(" ", "_"), "hull": hull, "points": 6, "z": 0, "doors": doors})
        for d in self.doors.values():
            d["front_room"] = d["front_room"] and d["front_room"].replace(" ", "_")
            d["back_room"] = d["back_room"] and d["back_room"].replace(" ", "_")
        (bridge / "rooms.json").write_text(json.dumps({"level": LEVEL, "rooms": rooms}), encoding="utf-8")
        self.rooms_written = True

    def cameras(self):
        """Helicopter circling the house tracking a suspect in the yard (20 s tracked, then
        10 s lost), a drone turning in the hallway, and CCTV that gets wired after 10 s and
        whose feeds the player flips through."""
        t = self.clock
        hx, hy = px_to_world(500 + 650 * math.cos(t / 12), 375 + 550 * math.sin(t / 12))
        heli = {"id": "Helicopter_C_1", "pos": {"x": hx, "y": hy, "z": 4000.0},
                "yaw": math.degrees(t / 12) + 90, "camera_active": True, "viewing": False}
        sx, sy = px_to_world(1050, 375 + 300 * math.sin(t / 6))
        tracked = t % 30 < 20
        if tracked or self.spotted is None:
            self.spotted = {"id": "Suspect_C_2", "kind": "suspect", "source": "helicopter",
                            "pos": {"x": sx, "y": sy, "z": 0.0}, "seen_at": int(time.time())}
        self.spotted["status"] = "tracked" if tracked else "last_seen"
        aim = self.spotted["pos"]
        dx, dy = aim["x"] - hx, aim["y"] - hy
        heli["tracking"] = tracked
        heli["view"] = {"pos": dict(heli["pos"]), "fov": 15.0,
                        "yaw": math.degrees(math.atan2(dy, dx)),
                        "pitch": -math.degrees(math.atan2(4000.0, math.hypot(dx, dy)))}
        dx_, dy_ = px_to_world(500, 375)
        drone_yaw = (t * 20) % 360
        drone = {"id": "Drone_C_1", "name": "Drone", "pos": {"x": dx_, "y": dy_, "z": 120.0}, "yaw": drone_yaw,
                 "view": {"pos": {"x": dx_, "y": dy_, "z": 120.0}, "yaw": drone_yaw, "pitch": -5.0, "fov": 90.0}}
        cams = []
        # Ceiling corners, looking into the room.
        for cid, name, (u, v), yaw in (("CCTV_C_1", "Living Room", (990, 10), -135.0),
                                       ("CCTV_C_2", "Kitchen", (10, 10), 135.0)):
            x, y = px_to_world(u, v)
            pos = {"x": x, "y": y, "z": 250.0}
            cams.append({"id": cid, "name": name, "floor": 0, "number": len(cams) + 1, "pos": pos,
                         "view": {"pos": pos, "yaw": yaw, "pitch": -25.0, "fov": 80.0}})
        wired = t >= 10
        viewing = [None, "CCTV_C_1", "CCTV_C_2"][int(t / 8) % 3] if wired else None
        cctv = {"wired": wired, "cameras": cams if wired else []}
        if viewing:
            cctv["viewing"] = viewing
        return {"helicopters": [heli], "drones": [drone], "cctv": cctv, "hook_fired": True}

    def tick(self, bridge, dt):
        for cmd in self.read_commands(bridge):
            self.results.insert(0, self.dispatch(cmd))
            del self.results[30:]
        self.clock += dt
        self.update_player(dt)
        cameras = self.cameras()
        for o in self.officers:
            o.step(dt, self.player)
        if not self.rooms_written:
            self.write_rooms(bridge)
        self.seq += 1
        state = {
            "version": 1, "seq": self.seq, "time": int(time.time()), "level": LEVEL,
            "player": self.player,
            "officers": [o.state() for o in self.officers],
            "doors": [{k: v for k, v in d.items() if not k.startswith("_")} for d in self.doors.values()],
            "rooms_version": f"{LEVEL}#{len(ROOMS_PX)}",
            "results": self.results,
            "targets": self.targets + [self.spotted],
            "cameras": cameras,
            "held": [{"id": e["cmd"]["id"], "team": t, "action": e["cmd"]["action"]} for t, e in self.held.items()],
            "configured_actions": sorted(set(ALL_ACTIONS) - UNCONFIGURED),
        }
        tmp = bridge / "state.json.tmp"
        tmp.write_text(json.dumps(state), encoding="utf-8")
        tmp.replace(bridge / "state.json")


def run(bridge: Path):
    game = MockGame()
    last = time.monotonic()
    while True:
        now = time.monotonic()
        game.tick(bridge, now - last)
        last = now
        time.sleep(TICK)


def write_map():
    folder = HERE / "maps" / LEVEL
    folder.mkdir(parents=True, exist_ok=True)
    w, h = 1100, 750
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
             f'<rect width="{w}" height="{h}" fill="#5b6a4e"/>',
             '<rect x="0" y="0" width="1000" height="750" fill="#d9d4c7"/>']
    for name, (u0, v0, u1, v1) in ROOMS_PX.items():
        parts.append(f'<rect x="{u0}" y="{v0}" width="{u1 - u0}" height="{v1 - v0}" '
                     f'fill="none" stroke="#2b2b2b" stroke-width="8"/>')
        parts.append(f'<text x="{(u0 + u1) / 2}" y="{(v0 + v1) / 2}" font-family="sans-serif" font-size="22" '
                     f'fill="#6b665c" text-anchor="middle">{name.upper()}</text>')
    for u, v, wall, *_ in DOORS_PX.values():
        if wall == "h":
            parts.append(f'<rect x="{u - 40}" y="{v - 6}" width="80" height="12" fill="#d9d4c7"/>')
        else:
            parts.append(f'<rect x="{u - 6}" y="{v - 40}" width="12" height="80" fill="#d9d4c7"/>')
    parts.append("</svg>")
    (folder / "floor1.svg").write_text("\n".join(parts), encoding="utf-8")

    data = {
        "level": LEVEL,
        "floors": [{
            "name": "Ground",
            "image": "floor1.svg",
            "zMin": -100000, "zMax": 100000,
            "anchors": [
                {"world": list(px_to_world(0, 0)), "px": [0, 0]},
                {"world": list(px_to_world(1000, 750)), "px": [1000, 750]},
            ],
        }],
        # Rooms come from the game (rooms.json), so the map file has none.
        "rooms": [],
    }
    (folder / "map.json").write_text(json.dumps(data, indent=2), encoding="utf-8")
    print(f"wrote {folder}")


if __name__ == "__main__":
    if "--write-map" in sys.argv:
        write_map()
    else:
        print("run `python server.py --mock` instead")
