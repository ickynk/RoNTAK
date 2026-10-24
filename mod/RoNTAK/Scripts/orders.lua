-- Turns ATAK orders into game function calls, as described by config.actions.

local config = require("config")
local game = require("game")
local log = require("log")

local orders = {}

local function lookup(table_name, id)
    local value = config[table_name][id]
    if value == nil then error(string.format("unknown %s option '%s'", table_name, tostring(id))) end
    return value
end

local function vector(v)
    return { X = v.x, Y = v.y, Z = v.z or 0 }
end

-- Fills in the "$" placeholders of an action's argument list. Returns the
-- arguments and their count (some, like $breach_item, can be nil).
local function build_args(spec, cmd, door)
    local options = {}
    for k, v in pairs(cmd.options or {}) do options[k] = v end
    for k, v in pairs(spec.options or {}) do options[k] = v end
    local breach = options.breach or "kick"

    local approach, normal
    if door then approach, normal = game.door_approach(door, cmd.team) end

    local args = {}
    for i, arg in ipairs(spec.args or {}) do
        local value = arg
        if arg == "$team" then
            value = config.team_args[cmd.team]
            if value == nil then error("unknown team '" .. tostring(cmd.team) .. "'") end
        elseif arg == "$door" then
            if not door then error("this order needs a door") end
            value = door
        elseif arg == "$location" then
            local player = game.player()
            local loc = approach or (cmd.target and cmd.target.location) or (player and player.pos)
            if not loc then error("this order needs a map location") end
            value = vector(loc)
        elseif arg == "$normal" then
            if not normal then error("this order needs a door") end
            value = vector(normal)
        elseif arg == "$breach" then
            value = lookup("breach_args", breach)
        elseif arg == "$breach_item" then
            local category = config.breach_items[breach]
            value = nil
            if category then
                value = game.team_item_class(cmd.team, category)
                if not value then error("no officer on " .. cmd.team .. " carries the " .. breach .. " item") end
            end
        elseif arg == "$grenade_item" then
            local grenade = options.grenade or "none"
            value = nil
            if grenade ~= "none" then
                local category = lookup("grenade_items", grenade)
                value = game.team_item_class(cmd.team, category)
                if not value then error("no officer on " .. cmd.team .. " carries a " .. grenade) end
            end
        elseif arg == "$side" then
            value = lookup("side_args", options.side or "auto")
        elseif arg == "$with_leader" then
            value = breach == "leader"
        elseif arg == "$fall_in" then
            value = config.fall_in_pattern
        end
        args[i] = value
    end
    return args, #spec.args
end

-- Runs one order. Returns a result table for state.json.
function orders.execute(cmd)
    local result = { id = cmd.id, team = cmd.team, action = cmd.action }
    local spec = config.actions[cmd.action]
    if not spec then
        result.status, result.message = "error", "unknown action " .. tostring(cmd.action)
        return result
    end
    if not spec.fn then
        result.status = "not_configured"
        result.message = "set config.actions." .. cmd.action .. ".fn (see docs/02-discovery.md)"
        return result
    end

    local ok, err = pcall(function()
        local door = nil
        local door_id = cmd.target and cmd.target.door
        if door_id then
            door = game.door_by_id(door_id)
            if not door then error("door " .. door_id .. " no longer exists") end
        end
        local target = game.resolve_target(spec.target, door)
        if not target then error("could not find target '" .. tostring(spec.target) .. "'") end
        local fn = target[spec.fn]
        if not fn then error(string.format("%s has no function %s", game.object_name(target), spec.fn)) end
        local args, count = build_args(spec, cmd, door)
        fn(target, table.unpack(args, 1, count))
    end)

    if ok then
        result.status = "ok"
        log.info(string.format("order %d: %s %s", cmd.id, cmd.team, cmd.action))
    else
        result.status, result.message = "error", tostring(err)
        log.error(string.format("order %d failed: %s", cmd.id, tostring(err)))
    end
    return result
end

return orders
