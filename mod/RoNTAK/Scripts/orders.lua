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
        elseif arg == "$scan" then
            value = lookup("scan_args", options.scan or "slice")
        elseif arg == "$character" then
            local id = cmd.target and cmd.target.character
            value = id and game.target_by_id(id)
            if not value then error("that person is no longer on the map") end
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
        -- Details for troubleshooting go to the UE4SS log, not the ATAK screen.
        local detail = sent ~= "" and ("sent " .. sent) or ""
        if class_report then detail = detail .. " | set in call: " .. class_report end
        log.info(string.format("order %d: %s %s %s", cmd.id, cmd.team, cmd.action, detail))
        if door and CHECKED_ACTIONS[cmd.action] then
            pending_checks[#pending_checks + 1] = { result = result, team = cmd.team, door = door, ticks = CHECK_MAX_TICKS }
        end
    else
        result.status, result.message = "error", tostring(err)
        log.error(string.format("order %d failed: %s", cmd.id, tostring(err)))
    end
    return result
end

-- Held orders ("Hold for GO") ---------------------------------------------

-- team -> { cmd = order, result = its result table }. GOLD means both teams,
-- so holding GOLD replaces held RED / BLUE orders and the other way round.
local held = {}
local HELD_ORDER = { "gold", "red", "blue" }

function orders.hold(cmd)
    if cmd.team == "gold" then
        held.red, held.blue = nil, nil
    else
        held.gold = nil
    end
    local result = { id = cmd.id, team = cmd.team, action = cmd.action, status = "held" }
    held[cmd.team] = { cmd = cmd, result = result }
    log.info(string.format("order %d: %s %s held for GO", cmd.id, cmd.team, cmd.action))
    return result
end

-- Starts every held order at once. Each held order's result is updated in place.
function orders.execute_held()
    local count = 0
    for _, team in ipairs(HELD_ORDER) do
        local entry = held[team]
        if entry then
            held[team] = nil
            local result = orders.execute(entry.cmd)
            for k, v in pairs(result) do entry.result[k] = v end
            if result.status == "ok" then
                -- Breach checks report on the result table the screen shows.
                for _, check in ipairs(pending_checks) do
                    if check.result == result then check.result = entry.result end
                end
            end
            count = count + 1
        end
    end
    log.info(string.format("GO: started %d held orders", count))
    return count
end

function orders.clear_held()
    for team, entry in pairs(held) do
        entry.result.status, entry.result.message = "cancelled", "cleared before GO"
        held[team] = nil
    end
end

-- Held orders for state.json.
function orders.held_list()
    local list = {}
    for _, team in ipairs(HELD_ORDER) do
        local entry = held[team]
        if entry then
            list[#list + 1] = { id = entry.cmd.id, team = team, action = entry.cmd.action }
        end
    end
    return list
end

-- Handles one command from the companion: an order to run now, an order to
-- hold, or a GO / clear for the held orders. Returns a result table.
function orders.dispatch(cmd)
    if cmd.action == "go" then
        local count = orders.execute_held()
        return { id = cmd.id, team = cmd.team, action = "go", status = "ok",
                 message = string.format("started %d held orders", count) }
    elseif cmd.action == "clear_held" then
        orders.clear_held()
        return { id = cmd.id, team = cmd.team, action = "clear_held", status = "ok" }
    elseif cmd.hold then
        return orders.hold(cmd)
    end
    return orders.execute(cmd)
end

-- Called every tick: reports which officer got the door job of recent breach
-- orders and which item the game gave them.
function orders.run_checks()
    for i = #pending_checks, 1, -1 do
        local check = pending_checks[i]
        check.ticks = check.ticks - 1
        local ok, text = pcall(game.describe_door_activities, check.team, check.door)
        if not ok then
            table.remove(pending_checks, i)
            log.error(string.format("order %d check failed: %s", check.result.id, tostring(text)))
        elseif text then
            table.remove(pending_checks, i)
            log.info(string.format("order %d: game assigned %s", check.result.id, text))
        elseif check.ticks <= 0 then
            table.remove(pending_checks, i)
            check.result.message = "the team did not start the breach within 20 s"
            log.info(string.format("order %d: %s (F7 shows every officer's door job)", check.result.id, check.result.message))
        end
    end
end

return orders
