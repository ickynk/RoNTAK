-- RoNTAK: ATAK-style tactical map and team orders for Ready or Not.
-- Entry point loaded by UE4SS.

local bridge = require("bridge")
local config = require("config")
local discovery = require("discovery")
local game = require("game")
local log = require("log")
local mapinfo = require("mapinfo")
local orders = require("orders")
local rooms = require("rooms")

local MAX_RESULTS = 30

local seq = 0
local results = {}
local busy = false

local function remember(result)
    table.insert(results, 1, result)
    while #results > MAX_RESULTS do table.remove(results) end
end

local function configured_actions()
    local list = {}
    for action, spec in pairs(config.actions) do
        if spec.fn then list[#list + 1] = action end
    end
    table.sort(list)
    return list
end

local function tick()
    game.begin_tick()
    local level = game.level_name()
    for _, cmd in ipairs(bridge.new_commands()) do
        remember(orders.execute(cmd))
    end
    orders.run_checks()

    local doors = level and game.doors(level) or {}
    local rooms_version = rooms.update(level)

    seq = seq + 1
    bridge.write_state({
        version = 1,
        seq = seq,
        time = os.time(),
        level = level,
        player = game.player(),
        officers = level and game.officers() or {},
        doors = doors,
        rooms_version = rooms_version,
        results = results,
        configured_actions = configured_actions(),
    })
end

-- A tick slower than this is reported (at most every SLOW_TICK_REPORT_SECONDS):
-- the mod runs on the game thread, so slow ticks show up as stutter.
local SLOW_TICK_MS = 4
local SLOW_TICK_REPORT_SECONDS = 30
local last_slow_report = -math.huge

local function safe_tick()
    if busy then return end
    busy = true
    local started = os.clock()
    local ok, err = pcall(tick)
    local ms = (os.clock() - started) * 1000
    busy = false
    if not ok then log.error("tick: " .. tostring(err)) end
    if ms > SLOW_TICK_MS and os.time() - last_slow_report >= SLOW_TICK_REPORT_SECONDS then
        last_slow_report = os.time()
        log.info(string.format("slow tick: %.1f ms (game thread)", ms))
    end
end

local function test_order()
    local player = game.player()
    if not player or not player.pos then
        log.info("test order: no player pawn yet")
        return
    end
    local cmd = {
        id = -1,
        team = config.test_order.team,
        action = config.test_order.action,
        options = config.test_order.options,
        target = { door = game.nearest_door_id(player.pos), location = player.pos },
    }
    local result = orders.execute(cmd)
    log.info(string.format("test order: %s %s", result.status, result.message or ""))
    remember(result)
end

local function bind(key_name, fn)
    if not key_name then return end
    local key = Key[key_name]
    if not key then
        log.error("unknown key " .. key_name .. " in config.keys")
        return
    end
    RegisterKeyBind(key, function() ExecuteInGameThread(fn) end)
end

local function activity_dump()
    local lines = game.activity_report()
    bridge.write_file("activities.txt", table.concat(lines, "\n"))
    for _, line in ipairs(lines) do log.info(line) end
end

bind(config.keys.map_info, mapinfo.dump)
bind(config.keys.activity_dump, activity_dump)
bind(config.keys.discovery_dump, discovery.dump)
bind(config.keys.sniff_toggle, discovery.toggle_sniff)
bind(config.keys.test_order, test_order)

orders.install_class_hooks()

LoopAsync(config.tick_ms, function()
    ExecuteInGameThread(safe_tick)
    return false -- keep looping
end)

log.info("loaded, bridge folder: " .. bridge.dir)
log.info("CreateInvalidObject available: " .. tostring(CreateInvalidObject ~= nil))
