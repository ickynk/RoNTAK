-- Orders for the called-in teams (GREEN, YELLOW) on their own.
--
-- The game sends a squad order to the officers in its squad list whose
-- DefaultTeam is the order's team (RED 1, BLUE 2), or to all of them (GOLD
-- 5). It has no other teams.
--
-- The command wheel picks who gets an order inside the game's own code,
-- before anything RoNTAK can hook (tested Nov 2026: changing DefaultTeam in
-- the wheel's OnCommandIssued came too late). So the officers' DefaultTeam is
-- kept arranged all the time, for whatever the wheel sends next:
--
--   * stock teams selected (the plain game): the original squad keeps its
--     teams; the called-in operators rest on config.squads.rest_team (GOLD),
--     so RED / BLUE orders reach the original squad only and GOLD reaches
--     everyone;
--   * GREEN (or YELLOW) selected with config.keys.select_team: that team's
--     operators take the wheel's current team (RED or BLUE, followed every
--     mod tick), everyone else rests on GOLD. RED / BLUE orders on the wheel
--     go to GREEN only; GOLD still reaches everyone.
--
-- RoNTAK's own orders (the companion) don't depend on the wheel: for the
-- moment one goes out, DefaultTeam is arranged so exactly its team gets it,
-- then put back (config.squads.restore_ms).

local config = require("config")
local game = require("game")
local log = require("log")

local squads = {}

local valid, object_name = game.valid, game.object_name

local NO_TEAM = 0
local RED, BLUE, GOLD = 1, 2, 5

local selected = nil        -- nil (stock teams) or a called-in team name
local swapped = nil         -- a RoNTAK order's arrangement: { until_clock, list = { { actor, team } } }
local home = {}             -- actor name -> the stock team it had (stock officers only)
local member_team = function() return nil end   -- actor name -> called-in team, set by reinforcements
local wheel_team = RED      -- the command wheel's current team (RED or BLUE)
local last_route = nil

local function c() return config.squads or {} end
local function note(line) log.info("squads: " .. line) end
local function rest_team() return c().rest_team or GOLD end

function squads.set_member_lookup(fn) member_team = fn end

local function team_defs() return (config.reinforcements or {}).teams or {} end

local function called_in_teams()
    local out = {}
    for name in pairs(team_defs()) do out[#out + 1] = name end
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
    return ok and tonumber(t) or nil
end

local function set_team(actor, value)
    return pcall(function() actor.DefaultTeam = value end)
end

-- The team an officer really belongs to: a stock officer's own, a called-in
-- operator's joined team.
local function home_team(actor, name, own)
    if own then
        local def = team_defs()[own]
        return def and (config.team_args or {})[def.joins] or BLUE
    end
    if home[name] == nil then home[name] = team_of(actor) end
    return home[name]
end

-- The DefaultTeam an officer should have right now, for the wheel.
local function arranged_team(actor, name, own)
    if selected then
        return own == selected and wheel_team or rest_team()
    end
    if own then return rest_team() end
    return home_team(actor, name, own)
end

-- Keeps every officer's DefaultTeam arranged; called every mod tick (and
-- right away when the selection changes).
function squads.arrange()
    if swapped or c().enabled == false then return end
    for _, actor in ipairs(squad_list()) do
        local name = object_name(actor)
        local own = member_team(name)
        if not own then home_team(actor, name, own) end   -- remember before changing it
        local want = arranged_team(actor, name, own)
        if want and team_of(actor) ~= want then set_team(actor, want) end
    end
end

-- Puts back the DefaultTeam of every officer changed for a RoNTAK order.
function squads.restore()
    if not swapped then return end
    for _, entry in ipairs(swapped.list) do
        if valid(entry.actor) then set_team(entry.actor, entry.team) end
    end
    swapped = nil
end

-- For a RoNTAK order sent as order_team: arranges DefaultTeam so it reaches
-- exactly the officers of `team` (a called-in team, or nil for the stock
-- team order_team). Returns how many get it and how many were changed.
function squads.route(team, order_team)
    squads.restore()
    squads.arrange()
    order_team = tonumber(order_team)
    if not order_team or order_team == NO_TEAM then return 0, 0 end
    local list, reach, changed = {}, 0, 0
    for _, actor in ipairs(squad_list()) do
        local name = object_name(actor)
        local own = member_team(name)
        local current = team_of(actor)
        local wanted
        if team then
            wanted = own == team
        elseif order_team == GOLD then
            wanted = true
        else
            wanted = not own and home_team(actor, name, own) == order_team
        end
        local would = order_team == GOLD or current == order_team
        local new = nil
        if wanted and not would then new = order_team end
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
    last_route = { team = team or "stock", order_team = order_team, reach = reach, changed = changed }
    if c().log_routes ~= false then
        note(string.format("RoNTAK order for %s (sent as team %d): %d officer(s), %d team setting(s) changed for %d ms",
            team and string.upper(team) or "the stock team", order_team, reach, changed, c().restore_ms or 500))
    end
    return reach, changed
end

function squads.last_route() return last_route end
function squads.selected() return selected end

local function has_members(team)
    for _, actor in ipairs(squad_list()) do
        if member_team(object_name(actor)) == team then
            local ok, down = pcall(function() return actor:IsDeadOrUnconscious() end)
            if not (ok and down) then return true end
        end
    end
    return false
end

-- A short message on screen (the game's player message), if it shows one.
local function announce(text)
    if c().announce == false then return end
    local pc = game.player_controller()
    if not valid(pc) then return end
    pcall(function() pc:ClientMessage(text, FName and FName("None") or "None", c().announce_seconds or 3) end)
end

function squads.select(team)
    if team ~= nil and not team_defs()[team] then return false end
    selected = team
    local text = selected and string.format("Command wheel: %s (RED / BLUE orders go to %s only)", string.upper(selected),
        string.upper(selected)) or "Command wheel: RED / BLUE / GOLD"
    note(text)
    announce(text)
    squads.arrange()
    return true
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

-- The command wheel's current team: the selected team takes it, so RED and
-- BLUE on the wheel both command it.
local function read_wheel_team()
    local widget = FindFirstOf(c().wheel_class or "SwatCommandWidget")
    if not valid(widget) then return end
    local ok, v = pcall(function() return widget[c().wheel_team_property or "ActiveTeamType"] end)
    v = ok and tonumber(v) or nil
    if v == RED or v == BLUE then wheel_team = v end
end

-- Every mod tick: put back a RoNTAK order's arrangement when its time is up,
-- follow the wheel, keep the officers arranged.
function squads.tick()
    if swapped and os.clock() >= swapped.until_clock then squads.restore() end
    if selected and not has_members(selected) then
        note(string.upper(selected) .. " is no longer on scene")
        squads.select(nil)
    end
    if selected then read_wheel_team() end
    squads.arrange()
end

-- When the mission changes, forget the old officers.
function squads.reset()
    home, selected, swapped, wheel_team = {}, nil, nil, RED
end

return squads
