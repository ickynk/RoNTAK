-- Team analysis (config.keys.team_probe, the End key). Read-only.
--
-- Step 3 of reinforcements gives GREEN and YELLOW their own orders. To
-- build that, RoNTAK needs to know how the game routes an order to a team:
-- which functions take a team, where the selected team is stored, and which
-- officers an order reaches. This tool finds out and writes it to
-- bridge/team_report.txt:
--
--   1st press: scans the game's classes and functions for team types (the
--              game freezes for a few seconds), then starts watching.
--              Give orders now with the in-game command wheel: RED, BLUE,
--              GOLD, and different kinds of order.
--   2nd press: stops watching and writes the report.
--
-- While watching, every call to a watched function (config.team_probe.watch)
-- is logged with its team and the command wheel's team state,
-- and a moment later which officers' current job changed (who the order
-- actually reached). Hooks only read the team value and nothing else (struct
-- reads inside hooks crashed UE4SS 3.0.1). Hooks stay registered after the
-- first press (unregistering broke hooked functions) but do nothing when
-- not watching.

local bridge = require("bridge")
local config = require("config")
local game = require("game")
local log = require("log")

local teamprobe = {}

local valid, object_name = game.valid, game.object_name

local REPORT = "team_report.txt"
local AFTER_SECONDS = 1.5      -- how long after an order the officers' jobs are compared
local MAX_CALLS = 400

local survey = nil             -- { enum = {...}, functions = {...}, properties = {...} }
local watching = false
local hooked = {}              -- function path -> true
local calls = {}               -- observed calls
local pending = {}             -- calls waiting for the "after" snapshot
local started_at = nil

local function c() return config.team_probe or {} end
local function note(line) log.info("team probe: " .. line) end

local function name_of(obj)
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    return ok and n or "?"
end

local function full_name_of(obj)
    local ok, n = pcall(function() return obj:GetFullName() end)
    return ok and n or "?"
end

local function type_of(prop)
    local ok, n = pcall(function() return prop:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end

local function enum_of(prop)
    local ok, n = pcall(function() return prop:GetEnum():GetFName():ToString() end)
    return ok and n or nil
end

-- Is this property a team: an ETeamType enum, or a byte/enum named like a team.
local function team_kind(prop)
    local t = type_of(prop)
    local enum = t == "EnumProperty" and enum_of(prop) or nil
    if enum and enum == (c().team_enum or "ETeamType") then return "team" end
    if (t == "ByteProperty" or t == "EnumProperty") and name_of(prop):lower():find("team", 1, true) then
        return "maybe team (" .. t .. (enum and (" " .. enum) or "") .. ")"
    end
    return nil
end

local function owner_of(fn_full_name)
    -- "Function /Script/ReadyOrNot.SWATManager:GiveMoveCommand" -> "SWATManager"
    return fn_full_name:match("%.([%w_]+):") or "?"
end

-- The ETeamType values: { "0 = NONE", ... }.
local function enum_values()
    local out = {}
    local enum = StaticFindObject and StaticFindObject(c().team_enum_path or "/Script/ReadyOrNot.ETeamType")
    if not valid(enum) then return { "(enum not found)" } end
    pcall(function()
        enum:ForEachName(function(n, v)
            local s = n
            pcall(function() s = n:ToString() end)
            out[#out + 1] = string.format("%s = %s", tostring(v), tostring(s))
        end)
    end)
    return out
end

-- Scans every loaded ReadyOrNot class and function for team types.
local function scan()
    local functions, properties = {}, {}
    ForEachUObject(function(obj)
        local kind = "?"
        pcall(function() kind = obj:GetClass():GetFName():ToString() end)
        if kind ~= "Function" and kind ~= "Class" and kind ~= "BlueprintGeneratedClass" then return end
        local full = full_name_of(obj)
        if not (full:find("/Script/ReadyOrNot", 1, true) or full:find("/Game/", 1, true)) then return end
        if kind == "Function" then
            local params, team_index, team_param, index = {}, nil, nil, 0
            pcall(function()
                obj:ForEachProperty(function(prop)
                    local pname = name_of(prop)
                    local is_return = pname == "ReturnValue"
                    if not is_return then index = index + 1 end
                    local tk = team_kind(prop)
                    params[#params + 1] = string.format("%s %s%s", type_of(prop), pname, tk and (" [" .. tk .. "]") or "")
                    if tk and not is_return and not team_index then team_index, team_param = index, pname end
                end)
            end)
            local path = full:match("^%S+%s+(.+)$") or full
            local fn_name = name_of(obj)
            local lower = fn_name:lower()
            local named = lower:find("team", 1, true) or lower:find("command", 1, true) or lower:find("order", 1, true)
            if team_index or (named and full:find("/Script/ReadyOrNot", 1, true)) then
                functions[#functions + 1] = {
                    path = path, owner = owner_of(full), name = fn_name, params = params,
                    team_index = team_index, team_param = team_param, native = full:find("/Script/", 1, true) ~= nil,
                }
            end
        else
            local found = {}
            pcall(function()
                obj:ForEachProperty(function(prop)
                    local tk = team_kind(prop)
                    if tk then found[#found + 1] = { name = name_of(prop), kind = tk, type = type_of(prop) } end
                end)
            end)
            if #found > 0 then properties[#properties + 1] = { class = name_of(obj), props = found } end
        end
    end)
    table.sort(functions, function(a, b) return a.path < b.path end)
    table.sort(properties, function(a, b) return a.class < b.class end)
    return functions, properties
end

-- Every officer: name, team, slot, and its current job.
local function officer_snapshot()
    local out = {}
    for _, o in ipairs(game.officer_actors()) do
        local a = o.actor
        local row = { name = o.name, team = "?", slot = "?", job = "none", controller = "?" }
        pcall(function() row.team = tostring(a.DefaultTeam) end)
        pcall(function() row.slot = tostring(a.SquadPosition) end)
        pcall(function()
            local ctrl = a.Controller
            if valid(ctrl) then
                row.controller = name_of(ctrl:GetClass())
                local job = ctrl.CurrentActivity
                if valid(job) then row.job = name_of(job:GetClass()) .. "#" .. name_of(job) end
            end
        end)
        out[o.name] = row
    end
    return out
end

local function call_sign(name)
    local o = game.officer_override and game.officer_override(name)
    return o and o.name and (o.name .. " ") or ""
end

-- The command wheel's and the squad manager's team state, read when a
-- watched function is called.
local function wheel_state()
    local parts = {}
    for _, w in ipairs(c().state or {}) do
        local obj = FindFirstOf(w.class)
        if valid(obj) then
            for _, prop in ipairs(w.props) do
                local v = "?"
                pcall(function() v = tostring(obj[prop]) end)
                parts[#parts + 1] = w.class .. "." .. prop .. "=" .. v
            end
        end
    end
    return table.concat(parts, " ")
end

-- Hooks the functions in config.team_probe.watch. UE4SS 3.0.1 can't list a
-- function's parameters from Lua, so which one is the team comes from the
-- game's headers (config.lua's list of order signatures).
local function install_hooks()
    for _, w in ipairs(c().watch or {}) do
        if not hooked[w.path] then
            local spec = w
            local short = spec.path:match("%.([%w_]+:[%w_]+)$") or spec.path
            local ok, err = pcall(RegisterHook, spec.path, function(self, ...)
                if not watching or #calls >= MAX_CALLS then return end
                local team = "-"
                if spec.team then
                    team = "?"
                    local param = select(spec.team, ...)
                    if param then pcall(function() team = tostring(param:get()) end) end
                end
                local entry = { time = os.clock() - (started_at or 0), fn = short, param = spec.team and "TeamType" or nil,
                                team = team, state = wheel_state(), before = officer_snapshot() }
                calls[#calls + 1] = entry
                pending[#pending + 1] = { entry = entry, at = os.clock() + AFTER_SECONDS }
            end)
            if ok then
                hooked[spec.path] = true
            else
                note("could not watch " .. spec.path .. ": " .. tostring(err))
            end
        end
    end
    local total = 0
    for _ in pairs(hooked) do total = total + 1 end
    return total
end

-- Live values of the team properties on the few objects that have them.
local function live_values()
    local out = {}
    for _, entry in ipairs(survey.properties) do
        local instances = FindAllOf(entry.class) or {}
        if #instances > 0 and #instances <= (c().max_live_instances or 12) then
            for _, inst in ipairs(instances) do
                local parts = {}
                for _, p in ipairs(entry.props) do
                    local v = "?"
                    pcall(function() v = tostring(inst[p.name]) end)
                    parts[#parts + 1] = p.name .. "=" .. v
                end
                out[#out + 1] = string.format("  %s %s: %s", entry.class, name_of(inst), table.concat(parts, ", "))
            end
        elseif #instances > 0 then
            out[#out + 1] = string.format("  %s: %d instances (not listed)", entry.class, #instances)
        end
    end
    return out
end

local function squad_list()
    local out = {}
    local manager = game.resolve_target((config.reinforcements or {}).manager or "SWATManager")
    if not valid(manager) then return { "  (no squad manager)" } end
    pcall(function()
        manager.SwatAI:ForEach(function(i, element)
            local a = element:get()
            out[#out + 1] = string.format("  %d. %s%s", i, call_sign(name_of(a)), name_of(a))
        end)
    end)
    return out
end

local function write_report()
    local lines = {
        "RoNTAK team report (send this file for step 3: GREEN / YELLOW orders)",
        string.format("level %s, watched %.0f s, %d calls", tostring(game.level_name()), os.clock() - (started_at or os.clock()), #calls),
        "",
        "== Team values (" .. (c().team_enum or "ETeamType") .. ") ==",
    }
    for _, v in ipairs(survey.enum) do lines[#lines + 1] = "  " .. v end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Calls while watching (team, then officers whose job changed within " .. AFTER_SECONDS .. " s) =="
    for _, call in ipairs(calls) do
        lines[#lines + 1] = string.format("%7.1f s  %s%s", call.time, call.fn,
            call.param and ("  " .. call.param .. "=" .. call.team) or "")
        if call.state and call.state ~= "" then lines[#lines + 1] = "            state: " .. call.state end
        local changed = 0
        for name, after in pairs(call.after or {}) do
            local before = call.before[name]
            if not before or before.job ~= after.job then
                changed = changed + 1
                lines[#lines + 1] = string.format("            %s%s (team %s, slot %s): %s -> %s", call_sign(name), name,
                    after.team, after.slot, before and before.job or "?", after.job)
            end
        end
        if not call.after then
            lines[#lines + 1] = "            (stopped before the officers were compared)"
        elseif changed == 0 then
            lines[#lines + 1] = "            (no officer's job changed)"
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Officers now =="
    for name, row in pairs(officer_snapshot()) do
        lines[#lines + 1] = string.format("  %s%s: team %s, slot %s, controller %s, job %s", call_sign(name), name,
            row.team, row.slot, row.controller, row.job)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Squad list (SWATManager.SwatAI) =="
    for _, l in ipairs(squad_list()) do lines[#lines + 1] = l end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Team properties: live values =="
    for _, l in ipairs(live_values()) do lines[#lines + 1] = l end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Functions with a team parameter, or named team / command / order =="
    for _, f in ipairs(survey.functions) do
        lines[#lines + 1] = string.format("%s%s%s", f.path, hooked[f.path] and "   [watched]" or "",
            f.team_index and (string.format("   team = param %d (%s)", f.team_index, f.team_param)) or "")
        if #f.params > 0 then lines[#lines + 1] = "      (" .. table.concat(f.params, ", ") .. ")" end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Classes with team properties =="
    for _, entry in ipairs(survey.properties) do
        local parts = {}
        for _, p in ipairs(entry.props) do parts[#parts + 1] = p.name .. " [" .. p.kind .. "]" end
        lines[#lines + 1] = string.format("  %s: %s", entry.class, table.concat(parts, ", "))
    end

    bridge.write_file(REPORT, table.concat(lines, "\n"))
    return #lines
end

-- Compares officers' jobs for calls whose moment has come; called every mod tick.
function teamprobe.tick()
    if #pending == 0 then return end
    local now = os.clock()
    local remaining = {}
    local snapshot = nil
    for _, p in ipairs(pending) do
        if now >= p.at then
            snapshot = snapshot or officer_snapshot()
            p.entry.after = snapshot
        else
            remaining[#remaining + 1] = p
        end
    end
    pending = remaining
end

function teamprobe.toggle()
    if watching then
        watching = false
        teamprobe.tick()
        local n = write_report()
        note(string.format("stopped; %d calls -> %s (%d lines). Send this file.", #calls, REPORT, n))
        return
    end
    if not game.player_pawn() then
        note("start a mission first")
        return
    end
    if not survey then
        note("scanning the game's classes and functions, the game may freeze for a few seconds...")
        local functions, properties = scan()
        survey = { enum = enum_values(), functions = functions, properties = properties }
        note(string.format("found %d functions and %d classes with team types", #functions, #properties))
    end
    local hooks = install_hooks()
    calls, pending = {}, {}
    started_at = os.clock()
    watching = true
    note(string.format("watching %d functions. Give orders with the command wheel (RED, BLUE, GOLD), then press %s again.",
        hooks, tostring((config.keys or {}).team_probe)))
end

function teamprobe.watching() return watching end

return teamprobe
