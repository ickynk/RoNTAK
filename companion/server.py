"""RoNTAK companion server.

Serves the ATAK web interface and relays data between it and the game mod
through the mod's bridge folder (state.json / commands.json).

    python server.py                       # finds the installed mod ("Start RoNTAK.bat" does this)
    python server.py --bridge "C:/.../Mods/RoNTAK/bridge"
    python server.py --mock                # simulated game, no Ready or Not needed
    python server.py --lan / --local       # allow / don't allow phones on your Wi-Fi (remembered)

Only the Python standard library is used.
"""

import argparse
import json
import os
import re
import secrets
import socket
import sys
import tempfile
import threading
import time
import webbrowser
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

import gamefinder

HERE = Path(__file__).resolve().parent
WEB_DIR = HERE / "web"
MAPS_DIR = HERE / "maps"


def read_version() -> str:
    try:
        return (HERE.parent / "VERSION").read_text(encoding="utf-8").strip()
    except OSError:
        return "dev"

STALE_SECONDS = 3
MAX_KEPT_COMMANDS = 50
MAX_UPLOAD_BYTES = 30 * 1024 * 1024

TEAMS = {"red", "blue", "gold"}
ACTIONS = {
    "stack_up", "open_clear", "breach_clear", "move_clear", "scan_door", "wedge_door",
    "move_to", "fall_in", "hold", "search_secure",
    "pick_lock", "close_door", "remove_wedge", "check_traps", "disarm_trap", "scan_open",
    "cover_area", "chemlight", "deploy_grenade", "restrain", "report",
    "go", "clear_held",  # start / clear the orders held for GO
}
OPTION_KEYS = ("breach", "grenade", "side", "scan")
IMAGE_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".svg": "image/svg+xml"}
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.\- ]{1,80}$")


def write_atomic(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def read_json(path: Path, retries: int = 3):
    """Reads a JSON file that another process may be rewriting."""
    for attempt in range(retries):
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except (json.JSONDecodeError, PermissionError, OSError):
            if attempt == retries - 1:
                return None
            time.sleep(0.02)
    return None


def safe_name(name: str) -> str:
    if not SAFE_NAME.match(name) or name.startswith(".") or ".." in name:
        raise ValueError(f"invalid name: {name!r}")
    return name


class CommandQueue:
    """Writes orders to commands.json for the mod to pick up."""

    def __init__(self, bridge: Path):
        self.path = bridge / "commands.json"
        self.session = secrets.token_hex(4)
        self.next_id = 1
        self.commands = []
        self.lock = threading.Lock()
        self._flush()

    def _flush(self) -> None:
        write_atomic(self.path, json.dumps({"session": self.session, "commands": self.commands}))

    def add(self, order: dict) -> dict:
        with self.lock:
            cmd = dict(order, id=self.next_id, created=time.time())
            self.next_id += 1
            self.commands = (self.commands + [cmd])[-MAX_KEPT_COMMANDS:]
            self._flush()
            return cmd


def validate_order(body: dict) -> dict:
    team = body.get("team")
    action = body.get("action")
    if team not in TEAMS:
        raise ValueError("team must be red, blue or gold")
    if action not in ACTIONS:
        raise ValueError(f"unknown action {action!r}")
    order = {"team": team, "action": action}

    target = body.get("target") or {}
    clean_target = {}
    if "door" in target:
        clean_target["door"] = str(target["door"])
    if "location" in target:
        loc = target["location"]
        clean_target["location"] = {k: float(loc.get(k, 0)) for k in ("x", "y", "z")}
    if "room" in target:
        clean_target["room"] = str(target["room"])
    if "character" in target:
        clean_target["character"] = str(target["character"])
    order["target"] = clean_target

    options = body.get("options") or {}
    order["options"] = {k: str(v) for k, v in options.items() if k in OPTION_KEYS}
    if body.get("hold") and action not in ("go", "clear_held"):
        order["hold"] = True
    return order


class Handler(SimpleHTTPRequestHandler):
    bridge: Path
    queue: CommandQueue
    info: dict = {}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_DIR), **kwargs)

    def log_message(self, fmt, *args):  # keep the console readable
        if "/api/state" not in (self.path or ""):
            sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    # Helpers -------------------------------------------------------------

    def send_json(self, data, status=HTTPStatus.OK):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self, limit=1024 * 1024) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        if length > limit:
            raise ValueError("request too large")
        return self.rfile.read(length)

    def route(self):
        parts = [unquote(p) for p in urlparse(self.path).path.split("/") if p]
        return parts

    # Routes --------------------------------------------------------------

    def do_GET(self):
        parts = self.route()
        try:
            if parts == ["api", "state"]:
                return self.get_state()
            if parts == ["api", "info"]:
                return self.send_json(self.info)
            if parts == ["api", "rooms"]:
                return self.send_json(read_json(self.bridge / "rooms.json") or {"level": None, "rooms": []})
            if len(parts) == 3 and parts[:2] == ["api", "maps"]:
                return self.get_map(safe_name(parts[2]))
            if len(parts) == 3 and parts[0] == "maps":
                return self.get_map_file(safe_name(parts[1]), safe_name(parts[2]))
        except ValueError as e:
            return self.send_json({"error": str(e)}, HTTPStatus.BAD_REQUEST)
        return super().do_GET()

    def do_POST(self):
        parts = self.route()
        try:
            if parts == ["api", "command"]:
                order = validate_order(json.loads(self.read_body()))
                return self.send_json(self.queue.add(order))
        except (ValueError, json.JSONDecodeError) as e:
            return self.send_json({"error": str(e)}, HTTPStatus.BAD_REQUEST)
        self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def do_PUT(self):
        parts = self.route()
        try:
            if len(parts) == 3 and parts[:2] == ["api", "maps"]:
                return self.put_map(safe_name(parts[2]))
            if len(parts) == 4 and parts[:2] == ["api", "maps"]:
                return self.put_map_image(safe_name(parts[2]), safe_name(parts[3]))
        except (ValueError, json.JSONDecodeError) as e:
            return self.send_json({"error": str(e)}, HTTPStatus.BAD_REQUEST)
        self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def get_state(self):
        path = self.bridge / "state.json"
        state = read_json(path)
        if state is None:
            return self.send_json({"connected": False, "reason": f"no state.json in {self.bridge}"})
        age = time.time() - path.stat().st_mtime
        state["connected"] = age < STALE_SECONDS
        state["age"] = round(age, 1)
        self.send_json(state)

    def get_map(self, level):
        data = read_json(MAPS_DIR / level / "map.json")
        if data is None:
            return self.send_json({"level": level, "floors": [], "rooms": []})
        self.send_json(data)

    def get_map_file(self, level, name):
        path = MAPS_DIR / level / name
        ctype = IMAGE_TYPES.get(path.suffix.lower())
        if not ctype or not path.is_file():
            return self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def put_map(self, level):
        data = json.loads(self.read_body())
        if not isinstance(data, dict) or not isinstance(data.get("floors", []), list):
            raise ValueError("map must be an object with a floors list")
        data["level"] = level
        folder = MAPS_DIR / level
        folder.mkdir(parents=True, exist_ok=True)
        write_atomic(folder / "map.json", json.dumps(data, indent=2))
        self.send_json({"saved": True})

    def put_map_image(self, level, name):
        if Path(name).suffix.lower() not in IMAGE_TYPES:
            raise ValueError("image must be png, jpg, webp or svg")
        folder = MAPS_DIR / level
        folder.mkdir(parents=True, exist_ok=True)
        (folder / name).write_bytes(self.read_body(MAX_UPLOAD_BYTES))
        self.send_json({"saved": True, "image": name})


def lan_address() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
    except OSError:
        return "your-pc-ip"


def ask_yes_no(question: str) -> bool:
    answer = input(f"{question} (y/n) > ").strip().lower()
    return answer.startswith("y")


def choose_bridge(parser) -> Path:
    """The mod's bridge folder: from settings or the installed game, else asked."""
    bridge = gamefinder.find_bridge()
    while not bridge:
        print("Couldn't find the RoNTAK mod. Run \"Install RoNTAK.bat\" first, or paste the mod's")
        answer = gamefinder.ask_path("bridge folder (…\\Mods\\RoNTAK\\bridge). Leave empty to cancel:")
        if not answer:
            parser.exit(1, "Cancelled.\n")
        if Path(answer).is_dir():
            bridge = Path(answer)
    gamefinder.save_settings(bridge=str(bridge))
    return bridge


def choose_lan(args) -> bool:
    """Phone / tablet access: from --lan / --local, else asked once and remembered."""
    if args.lan or args.local:
        gamefinder.save_settings(lan=args.lan)
        return args.lan
    saved = gamefinder.load_settings().get("lan")
    if saved is not None:
        return saved
    if not sys.stdin.isatty():
        return False
    lan = ask_yes_no("Allow phones and tablets on your Wi-Fi to open the ATAK screen?\n"
                     "(Anyone on your network could then give orders. Change later with --lan / --local.)")
    gamefinder.save_settings(lan=lan)
    return lan


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bridge", help="path to the mod's bridge folder (Mods/RoNTAK/bridge)")
    parser.add_argument("--mock", action="store_true", help="run a simulated game instead of connecting to Ready or Not")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--lan", action="store_true", help="allow phones / tablets on your network (remembered)")
    parser.add_argument("--local", action="store_true", help="only this PC (remembered)")
    parser.add_argument("--no-browser", action="store_true", help="don't open the ATAK screen in your browser")
    args = parser.parse_args(argv)

    if args.mock:
        import mock
        bridge = Path(tempfile.mkdtemp(prefix="rontak-mock-"))
        threading.Thread(target=mock.run, args=(bridge,), daemon=True).start()
        lan = args.lan
    else:
        if args.bridge:
            bridge = Path(args.bridge).expanduser().resolve()
            if not bridge.is_dir():
                parser.error(f"bridge folder does not exist: {bridge}")
        else:
            bridge = choose_bridge(parser)
        lan = choose_lan(args)

    local_url = f"http://127.0.0.1:{args.port}"
    lan_url = f"http://{lan_address()}:{args.port}" if lan else None
    Handler.bridge = bridge
    Handler.queue = CommandQueue(bridge)
    Handler.info = {"version": read_version(), "lan": lan, "lan_url": lan_url}

    try:
        server = ThreadingHTTPServer(("0.0.0.0" if lan else "127.0.0.1", args.port), Handler)
    except OSError:
        print(f"Port {args.port} is in use. Is RoNTAK already running? Try opening {local_url}")
        print(f"(Or start on another port: python server.py --port {args.port + 1})")
        return 1

    print(f"RoNTAK companion {read_version()} ({'mock game' if args.mock else 'bridge: ' + str(bridge)})")
    print(f"  Open on this PC:   {local_url}")
    if lan_url:
        print(f"  Open on phone/tab: {lan_url}  (or press the Phone button on the ATAK screen)")
    print("  Press Ctrl+C to stop.")
    if not args.no_browser:
        threading.Timer(0.5, webbrowser.open, args=(local_url,)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
