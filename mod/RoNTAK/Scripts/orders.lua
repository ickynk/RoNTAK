-- Turns ATAK orders into game function calls, as described by config.actions.

local config = require("config")
local game = require("game")
local log = require("log")

local orders = {}

-- Breach orders are watched until the game gives an officer the door job
-- (usually once the team is stacked), for at most this many ticks.
local CHECK_MAX_TICKS = 80
local CHECKED_ACTIONS = { breach_clear = true, open_clear = true, move_clear = true }
local pending_checks = {}

local function lookup(table_name, id)
    local value = config[table_name][id]
    if value == nil then error(string.format("unknown %s option '%s'", table_name, tostring(id))) end
    return value
end

-- A definite "no object" for item class arguments: an invalid UObject is
-- written as a null pointer, where a Lua nil may leave the argument unset.
local function no_object()
    if CreateInvalidObject then return CreateInvalidObject() end
    local ok, obj = pcall(FindFirstOf, "RoNTAK_NoSuchClass")
    if ok then return obj end
    return nil
end

local function param_text(param)
    local ok, value = pcall(function() return param:get() end)
    if not ok then return "?" end
    if value == nil then return "null" end
    local v_ok, is_valid = pcall(function() return value:IsValid() end)
    if v_ok and is_valid == false then return "null" end
    local n_ok, name = pcall(function() return value:GetFName():ToString() end)
    if n_ok and name then return name end
    return tostring(value)
end

-- Item class arguments of the call being made right now ({ [arg index] =
-- class }), written by the pre-hooks in config.class_arg_hooks.
local class_args = nil
local class_report = nil

function orders.install_class_hooks()
    if not RegisterHook then return end
    for _, fn_path in ipairs(config.class_arg_hooks or {}) do
        local ok, err = pcall(RegisterHook, fn_path, function(self, ...)
            if not class_args then return end
            local params = { ... }
            local report = {}
            for i, value in pairs(class_args) do
                local param = params[i]
                if param then
                    local before = param_text(param)
                    local set_ok = pcall(function() param:set(value) end)
                    report[#report + 1] = string.format("arg %d %s -> %s%s", i, before, param_text(param),
                        set_ok and "" or " (set failed)")
                end
            end
            table.sort(report)
            class_report = table.concat(report, ", ")
        end)
        if not ok then log.error("cannot hook " .. fn_path .. ": " .. tostring(err)) end
    end
end

local function vector(v)
    return { X = v.x, Y = v.y, Z = v.z or 0 }
end

local function name_of(obj)
    if obj == nil then return "none" end
    local v_ok, is_valid = pcall(function() return obj:IsValid() end)
    if v_ok and is_valid == false then return "none" end
    local ok, name = pcall(function() return obj:GetFName():ToString() end)
    return ok and name or tostring(obj)
end

-- Fills in the "$" placeholders of an action's argument list. Returns the
-- arguments, their count (some, like $breach_item, can be nil) and a note
-- naming the item classes sent.
local function build_args(spec, cmd, door)
    local sent = {}
    local classes = {}
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
            value = no_object()
            if category then
                value = game.team_item_class(cmd.team, category)
                if not value then error("no officer on " .. cmd.team .. " carries the " .. breach .. " item") end
            end
            sent[#sent + 1] = "breach item " .. name_of(value)
            classes[i] = value
        elseif arg == "$grenade_item" then
            local grenade = options.grenade or "none"
            value = no_object()
            if grenade ~= "none" then
                local category = lookup("grenade_items", grenade)
                value = game.team_item_class(cmd.team, category)
                if not value then error("no officer on " .. cmd.team .. " carries a " .. grenade) end
            end
            sent[#sent + 1] = "grenade " .. name_of(value)
            classes[i] = value
        elseif arg == "$side" then
            value = lookup("side_args", options.side or "auto")
        elseif arg == "$with_leader" then
            value = breach == "leader"
        elseif arg == "$fall_in" then
            value = config.fall_in_pattern
        end
        args[i] = value
    end
    return args, #spec.args, table.concat(sent, ", "), classes
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

    local door, sent = nil, ""
    local ok, err = pcall(function()
        local door_id = cmd.target and cmd.target.door
        if door_id then
            door = game.door_by_id(door_id)
            if not door then error("door " .. door_id .. " no longer exists") end
        end
        local target = game.resolve_target(spec.target, door)
        if not target then error("could not find target '" .. tostring(spec.target) .. "'") end
        local fn = target[spec.fn]
        if not fn then error(string.format("%s has no function %s", game.object_name(target), spec.fn)) end
        local args, count, classes
        args, count, sent, classes = build_args(spec, cmd, door)
        class_args, class_report = (next(classes) and classes or nil), nil
        local call_ok, call_err = pcall(fn, target, table.unpack(args, 1, count))
        class_args = nil
        if not call_ok then error(call_err, 0) end
    end)

    if ok then
        result.status = "ok"
        if sent ~= "" then result.sent = "sent " .. sent end
        if class_report then result.sent = (result.sent or "") .. " | set in call: " .. class_report end
        log.info(string.format("order %d: %s %s %s", cmd.id, cmd.team, cmd.action, result.sent or ""))
        if door and CHECKED_ACTIONS[cmd.action] then
            pending_checks[#pending_checks + 1] = { result = result, team = cmd.team, door = door, ticks = CHECK_MAX_TICKS }
        end
    else
        result.status, result.message = "error", tostring(err)
        log.error(string.format("order %d failed: %s", cmd.id, tostring(err)))
    end
    return result
end

-- Called every tick: reports which officer got the door job of recent breach
-- orders and which item the game gave them.
function orders.run_checks()
    for i = #pending_checks, 1, -1 do
        local check = pending_checks[i]
        check.ticks = check.ticks - 1
        local ok, text = pcall(game.describe_door_activities, check.team, check.door)
        if not ok then text = "check failed: " .. tostring(text) end
        if text or check.ticks <= 0 then
            table.remove(pending_checks, i)
            check.result.message = (check.result.sent and (check.result.sent .. " | ") or "") .. "game assigned: "
                .. (text or "no officer got a door job within 20 s (press F7 during the breach)")
            log.info(string.format("order %d check: %s", check.result.id, check.result.message))
        end
    end
end

return orders
