-- Which officers the command wheel commands (the called-in teams included).
--
-- The game sends a squad order to the officers in its squad list whose
-- DefaultTeam is the order's team (RED 1, BLUE 2), or to all of them (GOLD
-- 5). It has no other teams, and the command wheel picks who gets an order
-- inside the game's own code, before anything RoNTAK can hook (tested Nov
-- 2026). So the officers' DefaultTeam is kept arranged all the time for the
-- command group selected with config.keys.select_team (Insert):
--
--   * RED / BLUE (the plain game): the original squad keeps its teams; the
--     called-in operators rest on config.squads.rest_team (GOLD);
--   * GREEN / YELLOW ("called_in"): the called-in operators take the team
--     they joined (GREEN -> BLUE, YELLOW -> RED), the original squad rests
--     on GOLD. The wheel's RED commands YELLOW, its BLUE commands GREEN.
--
-- Either way the wheel's GOLD commands the full element.
--
-- RoNTAK's own orders (the companion) don't depend on the wheel: for the
-- moment one goes out, DefaultTeam is arranged so exactly its team gets it,
-- then put back (config.squads.restore_ms).
--
-- Native squad routing (RoNTAKNative 0.5+, config.squads.native_routing):
-- the called-in operators get their own squad manager (a second
-- USWATManager, with its own officer list) instead of joining the game's.
-- Nobody is parked on another team: GREEN keeps BLUE, YELLOW keeps RED, but
-- in their own manager. RoNTAKNative hooks the game so wheel orders and the
-- officers' AI use the right manager; Insert picks which one the wheel
-- commands:
--
--   group     wheel RED       wheel BLUE      wheel GOLD
--   RED/BLUE  RED             BLUE            RED + BLUE
--   GRN/YEL   YELLOW          GREEN           GREEN + YELLOW
--   FULL      RED + YELLOW    BLUE + GREEN    FULL ELEMENT

local config = require("config")
local game = require("game")
local log = require("log")
local overlay = require("overlay")

local squads = {}

local valid, object_name = game.valid, game.object_name

local NO_TEAM = 0
local RED, BLUE, GOLD = 1, 2, 5

local CALLED_IN = "called_in"
local FULL = "full"         -- native routing only: both squad managers
local selected = nil        -- nil (RED / BLUE), CALLED_IN (GREEN / YELLOW) or FULL
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

-- The called-in teams in their configured order (then any others, sorted).
local function called_in_teams()
    local out, seen = {}, {}
    for _, name in ipairs((config.reinforcements or {}).order or {}) do
        if team_defs()[name] and not seen[name] then out[#out + 1] = name seen[name] = true end
    end
    local rest = {}
    for name in pairs(team_defs()) do if not seen[name] then rest[#rest + 1] = name end end
    table.sort(rest)
    for _, name in ipairs(rest) do out[#out + 1] = name end
    return out
end

local function manager_class() return (config.reinforcements or {}).manager or "SWATManager" end

local function list_of(manager, out)
    out = out or {}
    if not valid(manager) then return out end
    pcall(function()
        manager.SwatAI:ForEach(function(_, element)
            local a = element:get()
            if valid(a) then out[#out + 1] = a end
        end)
    end)
    return out
end

-- Native squad routing ----------------------------------------------------

local native = { checked = false, installed = false, element = nil, dirty = true, group = nil }

local function native_fn(name)
    local fn = rawget(_G, name)
    return type(fn) == "function" and fn or nil
end

local function path_of(obj)
    local ok, full = pcall(function() return obj:GetFullName() end)
    if not ok or type(full) ~= "string" then return nil end
    return full:match("^%S+%s+(.+)$") or full
end

local function find(path)
    if not path or not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, path)
    if ok and valid(obj) then return obj end
    return nil
end

-- Installs RoNTAKNative's hooks (once). True when native routing can be used.
function squads.native_ready()
    if c().native_routing == false then return false end
    if native.installed then return true end
    if native.checked then return false end
    local install = native_fn("RoNTAK_SquadInstall")
    if not install or not native_fn("RoNTAK_SquadCreate") or not native_fn("RoNTAK_SquadSet")
        or not native_fn("RoNTAK_AppendObject") then
        return false
    end
    native.checked = true
    local ok, done, err = pcall(install)
    if ok and done then
        native.installed = true
        note("native squad routing installed: the called-in teams get their own squad manager")
    else
        note("native squad routing unavailable (" .. tostring(ok and err or done) .. "); using team parking")
    end
    return native.installed
end

-- Are the called-in teams in their own squad manager right now?
local function routed() return native.installed and valid(native.element) end
squads.routed = routed

-- The called-in teams' own squad manager (made on first use in a mission
-- when create is set). Returns it, or nil and why.
function squads.element_manager(create)
    if valid(native.element) then return native.element end
    native.element = nil
    if not create then return nil, "none yet" end
    if not squads.native_ready() then return nil, "native squad routing not available" end
    local main = game.resolve_target(manager_class())
    if not valid(main) then return nil, "no squad manager" end
    local ok, path, err = pcall(native_fn("RoNTAK_SquadCreate"), path_of(main) or "")
    if not ok or not path then return nil, "could not create a squad manager: " .. tostring(ok and err or path) end
    local manager = find(path)
    if not manager then return nil, "created " .. tostring(path) .. " but could not find it" end
    -- The world keeps it (exactly until the mission ends); unreferenced, the
    -- garbage collector would delete it while the game still uses it.
    local world_ok, world = pcall(function() return main:GetOuter() end)
    local kept, count, kerr = false, nil, nil
    if world_ok and valid(world) then
        kept, count, kerr = pcall(native_fn("RoNTAK_AppendObject"), path_of(world) or "", "ExtraReferencedObjects", path)
    end
    if not kept or not count then
        return nil, "could not keep the new squad manager alive: " .. tostring(kept and kerr or count or "no world")
    end
    pcall(function() manager.SquadLeader = main.SquadLeader end)
    game.exclude_target(manager)
    native.element, native.dirty = manager, true
    note("called-in teams' squad manager created: " .. tostring(path))
    return manager
end

-- Adds a called-in operator to the called-in teams' manager. Returns the
-- new officer count (0: already in it), or nil and why.
function squads.native_register(op)
    local manager, err = squads.element_manager(true)
    if not manager then return nil, err end
    local ok, count, aerr = pcall(native_fn("RoNTAK_AppendObject"), path_of(manager) or "", "SwatAI", path_of(op) or "")
    if not ok or not count then return nil, tostring(ok and aerr or count) end
    native.dirty = true
    return count
end

local function native_group()
    if selected == CALLED_IN then return 1 end
    if selected == FULL then return 2 end
    return 0
end

-- Tells RoNTAKNative the manager, its officers and the wheel's group (when changed).
local function push_routing()
    if not native.installed then return end
    local group = native_group()
    if not native.dirty and native.group == group then return end
    local manager = valid(native.element) and native.element or nil
    local paths = {}
    for _, a in ipairs(list_of(manager)) do paths[#paths + 1] = path_of(a) end
    local ok, done, err = pcall(native_fn("RoNTAK_SquadSet"), manager and path_of(manager) or "", table.concat(paths, ","), group)
    if not ok or not done then
        note("could not update native squad routing: " .. tostring(ok and err or done))
    end
    native.dirty, native.group = false, group
end

-- Who a RoNTAK order goes to with native routing: the managers to call it
-- on (main: the game's own). nil without native routing (squads.route then).
function squads.order_targets(team, main)
    if not routed() then return nil end
    if team == "gold" then return { main, native.element } end
    if team_defs()[team] then return { native.element } end
    return { main }
end

-- How many officers are in the list the called-in operators join.
function squads.callin_list_count()
    if squads.native_ready() then return #list_of(native.element) end
    return #list_of(game.resolve_target(manager_class()))
end

-- For the log: each squad list's officers as name=DefaultTeam/SquadPosition.
function squads.describe()
    local function one(manager)
        local out = {}
        for _, a in ipairs(list_of(manager)) do
            local ok, t = pcall(function() return a.DefaultTeam end)
            local ok2, p = pcall(function() return a.SquadPosition end)
            out[#out + 1] = string.format("%s=%s/%s", object_name(a), ok and tostring(t) or "?", ok2 and tostring(p) or "?")
        end
        return table.concat(out, " ")
    end
    return "game list: " .. one(game.resolve_target(manager_class()))
        .. (valid(native.element) and ("; call-in list: " .. one(native.element)) or "")
end

-- Every officer: the game's squad list, then the called-in teams' manager.
local function squad_list()
    local out = list_of(game.resolve_target(manager_class()))
    if valid(native.element) then list_of(native.element, out) end
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
    if routed() then return home_team(actor, name, own) end
    if selected then
        if own then return home_team(actor, name, own) end
        home_team(actor, name, own)   -- remembered before it is parked
        return rest_team()
    end
    if own then return rest_team() end
    return home_team(actor, name, own)
end

-- While operators are being called in, everyone is on their real team
-- (config.squads.pause_after_spawn_s after the last one): the game's own
-- spawning code may expect every officer on RED or BLUE.
local paused_until = nil

local function homes()
    for _, actor in ipairs(squad_list()) do
        local name = object_name(actor)
        local want = home_team(actor, name, member_team(name))
        if want and team_of(actor) ~= want then set_team(actor, want) end
    end
end

-- Called by reinforcements before it sets up an operator.
function squads.pause()
    squads.restore()
    homes()
    paused_until = os.clock() + (c().pause_after_spawn_s or 3)
end

function squads.paused() return paused_until ~= nil and os.clock() < paused_until end

-- Keeps every officer's DefaultTeam arranged; called every mod tick (and
-- right away when the selection changes).
function squads.arrange()
    if swapped or c().enabled == false then return end
    if squads.paused() then return end
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
    if routed() then return 0, 0 end
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

-- Is any called-in operator (of `team`, or of any team) up?
local function has_members(team)
    for _, actor in ipairs(squad_list()) do
        local own = member_team(object_name(actor))
        if own and (team == nil or own == team) then
            local ok, down = pcall(function() return actor:IsDeadOrUnconscious() end)
            if not (ok and down) then return true end
        end
    end
    return false
end

local function group_label(group)
    if group == FULL then return "FULL ELEMENT" end
    if group == CALLED_IN then
        local names = {}
        for _, t in ipairs(called_in_teams()) do names[#names + 1] = string.upper(t) end
        return table.concat(names, " / ")
    end
    return "RED / BLUE"
end

-- Selects the command group: nil (RED / BLUE) or "called_in" (GREEN /
-- YELLOW). Called-in team names select the called-in group too.
function squads.select(group)
    if group == "stock" then group = nil end
    if group == FULL then
        if not squads.native_ready() then return false end
    elseif group ~= nil and group ~= CALLED_IN then
        if not team_defs()[group] then return false end
        group = CALLED_IN
    end
    selected = group
    local text = "Command wheel: " .. group_label(selected)
    if not squads.native_ready() then text = text .. " (GOLD: full element)" end
    note(text)
    squads.arrange()
    push_routing()
    local status = native.installed and native_fn("RoNTAK_SquadStatus")
    if status then
        local ok, line = pcall(status)
        if ok then note("native routing: " .. tostring(line)) end
    end
    return true
end

-- Insert: RED / BLUE -> GREEN / YELLOW (-> FULL ELEMENT with native routing)
-- -> RED / BLUE; the called-in groups only while a called-in team is up.
function squads.cycle()
    if not has_members(nil) then
        if selected then squads.select(nil) end
        return selected
    end
    if selected == nil then
        squads.select(CALLED_IN)
    elseif selected == CALLED_IN and routed() then
        squads.select(FULL)
    else
        squads.select(nil)
    end
    return selected
end

-- The command wheel's current team: the selected team takes it, so RED and
-- BLUE on the wheel both command it.
local wheel_widget = nil
local wheel_shows = nil     -- the team the wheel shows: RED, BLUE or GOLD

local function read_wheel_team()
    if not valid(wheel_widget) then
        local ok, w = pcall(FindFirstOf, c().wheel_class or "SwatCommandWidget")
        wheel_widget = ok and valid(w) and w or nil
    end
    if not wheel_widget then return end
    local ok, v = pcall(function() return wheel_widget[c().wheel_team_property or "ActiveTeamType"] end)
    v = ok and tonumber(v) or nil
    if v == RED or v == BLUE or v == GOLD then wheel_shows = v end
    if v == RED or v == BLUE then wheel_team = v end
end

local STOCK_NAMES = { [RED] = "red", [BLUE] = "blue", [GOLD] = "gold" }

-- The called-in team that joined a stock team (the wheel's RED -> YELLOW).
local function called_in_on(stock_team)
    for _, t in ipairs(called_in_teams()) do
        local def = team_defs()[t]
        if (config.team_args or {})[def.joins] == stock_team then return t end
    end
    return nil
end

-- Who the command wheel commands right now: "gold" (the full element), a
-- stock team, or the called-in team on the wheel's colour (nil until the
-- wheel has been seen).
function squads.commanding()
    if not wheel_shows then return nil end
    if routed() then
        local on_red, on_blue = called_in_on(RED) or "red", called_in_on(BLUE) or "blue"
        if selected == CALLED_IN then
            return ({ [RED] = on_red, [BLUE] = on_blue, [GOLD] = "called_in" })[wheel_shows]
        elseif selected == FULL then
            return ({ [RED] = "red+" .. on_red, [BLUE] = "blue+" .. on_blue, [GOLD] = "full" })[wheel_shows]
        end
        return ({ [RED] = "red", [BLUE] = "blue", [GOLD] = "stock" })[wheel_shows]
    end
    if wheel_shows == GOLD then return "gold" end
    if selected then return called_in_on(wheel_shows) or STOCK_NAMES[wheel_shows] end
    return STOCK_NAMES[wheel_shows]
end

-- Every mod tick: put back a RoNTAK order's arrangement when its time is up,
-- follow the wheel, keep the officers arranged.
function squads.tick()
    if swapped and os.clock() >= swapped.until_clock then squads.restore() end
    if selected and not has_members(nil) then
        note("no called-in operator is up any more")
        squads.select(nil)
    end
    -- A new mission (another world's squad manager), or the called-in
    -- teams' manager gone with its world: start over.
    if native.installed then
        local main = game.resolve_target(manager_class())
        local ok, address = pcall(function() return main:GetAddress() end)
        address = valid(main) and ok and address or nil
        local moved = native.main_address ~= nil and address ~= native.main_address
        if moved or (native.element ~= nil and not valid(native.element)) then squads.reset() end
        native.main_address = address
    end
    read_wheel_team()
    squads.native_ready()
    squads.arrange()
    push_routing()
    -- On screen during a mission: who the wheel commands, in that team's colour.
    local team = squads.commanding()
    if team and (selected or c().show_stock_team ~= false) and game.player_pawn() then
        overlay.show(string.format(c().label or "COMMANDING: %s", squads.label_of(team)), squads.color_of(team))
    else
        overlay.show(nil)
    end
end

-- On-screen name and colour of what squads.commanding() returns.
function squads.label_of(team)
    local labels = c().group_labels or {}
    if labels[team] then return labels[team] end
    if team == "gold" then return c().gold_label or "GOLD (FULL ELEMENT)" end
    if team == "called_in" then return group_label(CALLED_IN):gsub(" / ", " + ") end
    return (string.upper(team):gsub("%+", " + "))
end

function squads.color_of(team)
    local colors = c().colors or {}
    return colors[team] or colors[team:match("^[^+]+") or team]
end

-- When the mission changes, forget the old officers (and the old world's
-- squad manager: RoNTAKNative stops routing to it).
function squads.reset()
    home, selected, swapped, wheel_team, wheel_widget, wheel_shows = {}, nil, nil, RED, nil, nil
    native.element, native.dirty = nil, true
    push_routing()
end

return squads
