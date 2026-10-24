-- RoNTAK: ATAK-style tactical map and team orders for Ready or Not.
-- Entry point loaded by UE4SS.

local bridge = require("bridge")
local config = require("config")
local discovery = require("discovery")
local game = require("game")
local log = require("log")
local orders = require("orders")

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
    local level = game.level_name()
    for _, cmd in ipairs(bridge.new_commands()) do
        remember(orders.execute(cmd))
    end
    orders.run_checks()

    seq = seq + 1
    bridge.write_state({
        version = 1,
        seq = seq,
        time = os.time(),
        level = level,
        player = game.player(),
        officers = level and game.officers() or {},
        doors = level and game.doors(level) or {},
        results = results,
        configured_actions = configured_actions(),
    })
end

local function safe_tick()
    if busy then return end
    busy = true
    local ok, err = pcall(tick)
    busy = false
    if not ok then log.error("tick: " .. tostring(err)) end
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

bind(config.keys.activity_dump, activity_dump)
bind(config.keys.discovery_dump, discovery.dump)
bind(config.keys.sniff_toggle, discovery.toggle_sniff)
bind(config.keys.test_order, test_order)

LoopAsync(config.tick_ms, function()
    ExecuteInGameThread(safe_tick)
    return false -- keep looping
end)

log.info("loaded, bridge folder: " .. bridge.dir)
log.info("CreateInvalidObject available: " .. tostring(CreateInvalidObject ~= nil))
