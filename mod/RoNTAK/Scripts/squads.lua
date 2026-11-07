-- Orders for the called-in teams (GREEN, YELLOW) on their own.
--
-- The game sends a squad order to the officers in its squad list whose
-- DefaultTeam is the order's team (RED 1, BLUE 2), or to all of them (GOLD
-- 5). It has no other teams, and the command wheel's orders go straight into
-- the game's own code. What the team analysis showed (Nov 2026): the wheel's
-- OnCommandIssued runs before any officer gets the new job.
--
-- So for the moment an order goes out, the officers' DefaultTeam is
-- arranged so that exactly the wanted officers receive it, and put back
-- shortly after (config.squads.restore_ms):
--   * the officers who should get it, but wouldn't, take the order's team;
--   * the others who would get it step out (DefaultTeam 0, no team).
-- Which officers should get it:
--   * a team selected with config.keys.select_team (GREEN / YELLOW): only
--     that team's operators, whatever team the wheel shows;
--   * no team selected: the stock officers of the wheel's team, as in the
--     plain game; GOLD also reaches the called-in teams
--     (config.squads.gold_reaches_called_in).
-- RoNTAK's own orders (the companion) are routed the same way.
--
-- At rest every operator keeps the DefaultTeam it joined with (BLUE / RED),
-- so the rest of the game (friend or foe, team lights) treats it as SWAT.

local config = require("config")
local game = require("game")
local log = require("log")

local squads = {}

local valid, object_name = game.valid, game.object_name

local NO_TEAM = 0
local GOLD = 5

local selected = nil        -- nil (stock teams) or a called-in team name
local swapped = nil         -- { until_clock, list = { { actor, team } } }
local member_team = function() return nil end   -- actor name -> called-in team, set by reinforcements
local last_route = nil      -- for the log / tests

local function c() return config.squads or {} end
local function note(line) log.info("squads: " .. line) end

-- reinforcements tells which actor belongs to which called-in team.
function squads.set_member_lookup(fn) member_team = fn end

local function called_in_teams()
    local out = {}
    for name in pairs((config.reinforcements or {}).teams or {}) do out[#out + 1] = name end
    table.sort(out)
    return out
end

local function squad_list()
    local manager = game.resolve_target((config.reinforcements or {}).manager or "SWATManager")
    local out = {}
    if not valid(manager) then return out end
    pcall(function()
        manager.SwatAI:ForEach(function(_, element)
            local a = element:get()
            if valid(a) then out[#out + 1] = a end
        end)
    end)
    return out
end

local function team_of(actor)
    local ok, t = pcall(function() return actor.DefaultTeam end)
    return ok and t or nil
end

local function set_team(actor, value)
    return pcall(function() actor.DefaultTeam = value end)
end

-- Puts back the DefaultTeam of every officer changed for the last order.
function squads.restore()
    if not swapped then return end
    for _, entry in ipairs(swapped.list) do
        if valid(entry.actor) then set_team(entry.actor, entry.team) end
    end
    swapped = nil
end

-- Arranges DefaultTeam so an order for wheel_team reaches exactly the
-- officers of `team` (a called-in team, or nil for the stock teams).
-- Returns how many officers will get it and how many were changed.
function squads.route(team, wheel_team)
    squads.restore()
    wheel_team = tonumber(wheel_team)
    if not wheel_team or wheel_team == NO_TEAM then return 0, 0 end
    local list, reach, changed = {}, 0, 0
    for _, actor in ipairs(squad_list()) do
        local current = team_of(actor)
        local own = member_team(object_name(actor))
        local wanted
        if team then
            wanted = own == team
        elseif own then
            wanted = wheel_team == GOLD and c().gold_reaches_called_in ~= false
        else
            wanted = wheel_team == GOLD or current == wheel_team
        end
        local would = wheel_team == GOLD or current == wheel_team
        local new = nil
        if wanted and not would then new = wheel_team end
        if not wanted and would then new = NO_TEAM end
        if new ~= nil and current ~= nil and set_team(actor, new) then
            list[#list + 1] = { actor = actor, team = current }
            changed = changed + 1
        end
        if wanted then reach = reach + 1 end
    end
    if #list > 0 then
        swapped = { until_clock = os.clock() + (c().restore_ms or 500) / 1000, list = list }
    end
    last_route = { team = team or "stock", wheel_team = wheel_team, reach = reach, changed = changed }
    if c().log_routes ~= false then
        note(string.format("order for %s (wheel team %d): %d officer(s), %d team setting(s) changed for %d ms",
            team and string.upper(team) or "the stock team", wheel_team, reach, changed, c().restore_ms or 500))
    end
    return reach, changed
end

function squads.last_route() return last_route end

-- The selected team, for RoNTAK's state.
function squads.selected() return selected end

-- Has a called-in team operators alive?
local function has_members(team)
    for _, actor in ipairs(squad_list()) do
        if member_team(object_name(actor)) == team then
            local ok, down = pcall(function() return actor:IsDeadOrUnconscious() end)
            if not (ok and down) then return true end
        end
    end
    return false
end

-- Selects which team the command wheel commands: stock -> GREEN -> YELLOW ->
-- stock, skipping teams that aren't on scene.
function squads.cycle()
    local order = { false }
    for _, t in ipairs(called_in_teams()) do order[#order + 1] = t end
    local index = 1
    for i, t in ipairs(order) do if t == (selected or false) then index = i end end
    for step = 1, #order do
        local candidate = order[(index - 1 + step) % #order + 1]
        if candidate == false or has_members(candidate) then
            squads.select(candidate or nil)
            return selected
        end
    end
    return selected
end

function squads.select(team)
    if team ~= nil and not ((config.reinforcements or {}).teams or {})[team] then return false end
    selected = team
    note(selected and ("command wheel orders now go to " .. string.upper(selected) .. " only (whatever team the wheel shows)")
        or "command wheel orders go to the stock teams again")
    return true
end

-- The command wheel's team for the order being issued.
local function wheel_team_of(widget)
    for _, prop in ipairs(c().wheel_team_properties or { "ExecutionTeamType", "ActiveTeamType" }) do
        local ok, v = pcall(function() return widget[prop] end)
        if ok and tonumber(v) and tonumber(v) ~= NO_TEAM then return tonumber(v) end
    end
    return nil
end

local hooked = false
function squads.install_hooks()
    if hooked or c().enabled == false then return end
    local path = c().wheel_hook or "/Script/ReadyOrNot.SwatCommandWidget:OnCommandIssued"
    local ok, err = pcall(RegisterHook, path, function(context)
        local widget = nil
        pcall(function() widget = context:get() end)
        if not valid(widget) then widget = FindFirstOf("SwatCommandWidget") end
        if not valid(widget) then return end
        local wheel_team = wheel_team_of(widget)
        if wheel_team then squads.route(selected, wheel_team) end
    end)
    if ok then
        hooked = true
    else
        log.error("squads: could not hook " .. path .. ": " .. tostring(err))
    end
end

-- Puts the team settings back once the order has gone out; every mod tick.
function squads.tick()
    if swapped and os.clock() >= swapped.until_clock then squads.restore() end
end

return squads
