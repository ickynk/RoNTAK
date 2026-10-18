-- Turns ATAK orders into game function calls, as described by config.actions.

local config = require("config")
local game = require("game")
local log = require("log")

local orders = {}

local function option_value(table_name, options, key, default)
    local id = (options and options[key]) or default
    local value = config[table_name][id]
    if value == nil then error(string.format("unknown %s '%s'", key, tostring(id))) end
    return value
end

local function build_args(spec, cmd, door)
    local args = {}
    local options = cmd.options or {}
    for i, arg in ipairs(spec.args or {}) do
        local value = arg
        if arg == "$team" then
            value = config.team_args[cmd.team]
            if value == nil then error("unknown team '" .. tostring(cmd.team) .. "'") end
        elseif arg == "$door" then
            if not door then error("this order needs a door") end
            value = door
        elseif arg == "$location" then
            local loc = cmd.target and cmd.target.location
            if not loc then error("this order needs a map location") end
            value = { X = loc.x, Y = loc.y, Z = loc.z or 0 }
        elseif arg == "$breach" then
            value = option_value("breach_args", options, "breach", "kick")
        elseif arg == "$grenade" then
            value = option_value("grenade_args", options, "grenade", "none")
        elseif arg == "$side" then
            value = option_value("side_args", options, "side", "auto")
        end
        args[i] = value
    end
    return args
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
        fn(target, table.unpack(build_args(spec, cmd, door)))
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
