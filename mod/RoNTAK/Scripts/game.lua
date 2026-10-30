-- Reads game state through UE4SS. All game-specific names come from config.lua.

local config = require("config")
local log = require("log")

local game = {}

-- FindAllOf walks every loaded object on the game thread, and a level keeps
-- gaining objects (decals, debris, dropped items) the longer it runs. So it
-- only rebuilds cached actor lists, rarely, and at most one rescan runs per
-- tick (see game.scan_slot). Officers, doors and people don't appear mid
-- mission; a list is also rebuilt when one of its actors disappears.
local OFFICER_RESCAN_SECONDS = 30
local TARGET_RESCAN_SECONDS = 20
local DOOR_RESCAN_SECONDS = 60
local SEARCH_RETRY_SECONDS = 2    -- after a search found nothing (e.g. in menus)
-- Per-object reads are spread over ticks: each tick refreshes a slice, so
-- every door / person / officer is refreshed once per this many ticks
-- (4 ticks = 1 s at the default tick_ms of 250).
local DOOR_STATE_TICKS = 8
local TARGET_STATE_TICKS = 4

local door_cache = { level = nil, at = -math.huge, list = {}, by_id = {}, cursor = 0 }

local tick_id = 0
local scans_left = 0

-- Called once at the start of every mod tick; per-tick reads are reused
-- within a tick.
function game.begin_tick()
    tick_id = tick_id + 1
    scans_left = 1
end

-- Whether a FindAllOf rescan may run now: at most one per tick, so rescans
-- that fall due together run on consecutive ticks instead of stacking up into
-- one long frame. The first scan of a level passes first = true and always
-- runs (the level is loading anyway, and the map needs its data).
function game.scan_slot(first)
    if first then return true end
    if scans_left > 0 then
        scans_left = scans_left - 1
        return true
    end
    return false
end

-- The next items of list in turn, count at a time; cursor is the position
-- reached so far. Returns the slice and the new cursor.
local function next_slice(list, cursor, count)
    local n = #list
    if n == 0 then return {}, 0 end
    local slice = {}
    for i = 1, math.min(count, n) do
        slice[i] = list[(cursor + i - 1) % n + 1]
    end
    return slice, (cursor + #slice) % n
end
game.next_slice = next_slice

local function valid(obj)
    if obj == nil then return false end
    local ok, result = pcall(function() return obj:IsValid() end)
    return ok and result
end

local function object_name(obj)
    local ok, name = pcall(function() return obj:GetFName():ToString() end)
    return ok and name or "?"
end

-- Turns a UE4SS property value (number, bool, FString, FName, FText...) into a plain Lua value.
local function plain(value)
    if type(value) == "userdata" then
        local ok, s = pcall(function() return value:ToString() end)
        if ok then return s end
        return nil
    end
    return value
end

-- A property value as UE4SS returns it (object wrappers, FStrings...).
local function read_raw(obj, name)
    if not name then return nil end
    local ok, value = pcall(function() return obj[name] end)
    if ok then return value end
    return nil
end

local function read_property(obj, name)
    if not name then return nil end
    local ok, value = pcall(function() return obj[name] end)
    if not ok then return nil end
    return plain(value)
end

-- Calls a no-argument function that returns a bool; nil if it is missing or fails.
local function call_bool(obj, fn_name)
    if not fn_name then return nil end
    local ok, value = pcall(function() return obj[fn_name](obj) end)
    if ok and type(value) == "boolean" then return value end
    return nil
end

local function door_locked(door)
    if call_bool(door, config.doors.lock_known_function) == false then return nil end
    local locked = read_property(door, config.doors.locked_property)
    if locked == nil then locked = call_bool(door, config.doors.locked_function) end
    return locked
end

-- Text of an FName / FString / FText value; nil for empty or "None".
-- (FName is not a UObject, so ToString on it is safe.)
local function name_text(value)
    if value == nil then return nil end
    local ok, s = pcall(function() return value:ToString() end)
    if ok and type(s) == "string" and s ~= "" and s ~= "None" then return s end
    return nil
end

-- Calls a no-argument function returning an FName on a valid object.
local function call_name(obj, fn_name)
    local ok, value = pcall(function() return obj[fn_name](obj) end)
    if ok then return name_text(value) end
    return nil
end

local function find_all(classes)
    for _, class_name in ipairs(classes) do
        local found = FindAllOf(class_name)
        if found and #found > 0 then return found end
    end
    return {}
end

local function location(actor)
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if not ok or not loc then return nil end
    return { x = loc.X, y = loc.Y, z = loc.Z }
end

local function yaw(actor)
    local ok, rot = pcall(function() return actor:K2_GetActorRotation() end)
    if not ok or not rot then return 0 end
    return rot.Yaw
end

local controller_cache = { pc = nil, searched_at = -math.huge }

function game.player_controller()
    local pc = controller_cache.pc
    if valid(pc) and valid(pc.Pawn) then return pc end
    if os.time() - controller_cache.searched_at < SEARCH_RETRY_SECONDS then return nil end
    game.scan_slot(true) -- needed to find the level at all, so it always runs, but takes this tick's slot
    controller_cache = { pc = nil, searched_at = os.time() }
    for _, candidate in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(candidate) and valid(candidate.Pawn) and valid(candidate.Player) then
            controller_cache.pc = candidate
            return candidate
        end
    end
    return nil
end

function game.player_pawn()
    local pc = game.player_controller()
    return pc and pc.Pawn or nil
end

function game.level_name()
    local pc = game.player_controller()
    if not pc then return nil end
    local ok, name = pcall(function() return pc:GetWorld():GetFName():ToString() end)
    return ok and name or nil
end

function game.player()
    local pawn = game.player_pawn()
    if not valid(pawn) then return nil end
    return { pos = location(pawn), yaw = yaw(pawn) }
end

local function excluded(name)
    for _, pattern in ipairs(config.officers.exclude_name_patterns or {}) do
        if name:find(pattern, 1, true) then return true end
    end
    return false
end

-- "First Last" from the officer's roster entry, else its squad slot name.
-- The roster object can be empty: check it before reading from it (UE4SS
-- errors on empty objects are not caught by pcall).
local function officer_display_name(actor, raw_squad)
    local roster = read_raw(actor, config.officers.roster_property)
    if valid(roster) then
        local first = name_text(read_raw(roster, "FirstName"))
        local last = name_text(read_raw(roster, "LastName"))
        local full = table.concat({ first or "", last or "" }, " "):gsub("^%s+", ""):gsub("%s+$", "")
        if full ~= "" then return full end
    end
    return (config.officers.squad_names or {})[raw_squad]
end

local officer_cache = { at = -math.huge, list = {} }

-- The officer actors, rebuilt with FindAllOf every OFFICER_RESCAN_SECONDS or
-- when one of them is gone (at most once per SEARCH_RETRY_SECONDS).
local function officer_list()
    local age = os.time() - officer_cache.at
    local stale = age >= OFFICER_RESCAN_SECONDS
    if not stale and age >= SEARCH_RETRY_SECONDS then
        if #officer_cache.list == 0 then stale = true end
        for _, o in ipairs(officer_cache.list) do
            if not valid(o.actor) then stale = true break end
        end
    end
    if not stale or not game.scan_slot(officer_cache.at == -math.huge) then return officer_cache.list end

    local list = {}
    local player_pawn = game.player_pawn()
    -- Compare by name: two UE4SS handles to the same object are not always equal.
    local player_name = valid(player_pawn) and object_name(player_pawn) or nil
    for _, actor in ipairs(find_all(config.officers.classes)) do
        if valid(actor) then
            local name = object_name(actor)
            if name ~= player_name and not excluded(name) then
                local raw_team = read_property(actor, config.officers.team_property)
                list[#list + 1] = {
                    actor = actor, name = name, team = config.officers.team_values[raw_team] or "unknown",
                    display_name = officer_display_name(actor, raw_team),
                }
            end
        end
    end
    officer_cache = { at = os.time(), list = list }
    return list
end

local officers_this_tick = { tick = nil, list = {} }

-- Officer actors with their team and position, for orders that need the
-- actual objects. Positions are read once per tick.
function game.officer_actors()
    if officers_this_tick.tick == tick_id then return officers_this_tick.list end
    local result = {}
    for _, o in ipairs(officer_list()) do
        if valid(o.actor) then
            local pos = location(o.actor)
            if pos then
                result[#result + 1] = { actor = o.actor, name = o.name, team = o.team, pos = pos, display_name = o.display_name }
            end
        end
    end
    officers_this_tick = { tick = tick_id, list = result }
    return result
end

local function on_team(officer, team)
    return team == "gold" or officer.team == team
end

-- Items the officer can still use: InventoryComp.InventoryItems minus the
-- ones marked IsDepleted (thrown grenades stay in the list, used up).
-- Each entry is { item = object, categories = { [EItemCategory] = true } }.
-- Returns nil if the inventory cannot be read.
local function usable_items(actor)
    local list = {}
    local ok = pcall(function()
        actor.InventoryComp.InventoryItems:ForEach(function(_, element)
            local item = element:get()
            if valid(item) and call_bool(item, "IsDepleted") ~= true then
                local categories = {}
                pcall(function()
                    item.ItemCategories:ForEach(function(_, c) categories[c:get()] = true end)
                end)
                list[#list + 1] = { item = item, categories = categories }
            end
        end)
    end)
    if ok then return list end
    return nil
end

local inventory_cache = { by_name = {}, cursor = 0 }

local function item_counts(actor)
    local items = usable_items(actor)
    if not items then return nil end
    local counts = {}
    for name, category in pairs(config.inventory or {}) do
        counts[name] = 0
        for _, entry in ipairs(items) do
            if entry.categories[category] then counts[name] = counts[name] + 1 end
        end
    end
    return counts
end

-- Counts of config.inventory items per officer name. One officer is
-- re-counted per tick (each once a second with four officers); an officer not
-- counted yet is counted straight away.
local function inventories()
    local officers = game.officer_actors()
    local slice
    slice, inventory_cache.cursor = next_slice(officers, inventory_cache.cursor, 1)
    for _, o in ipairs(officers) do
        if inventory_cache.by_name[o.name] == nil then slice[#slice + 1] = o end
    end
    for _, o in ipairs(slice) do
        inventory_cache.by_name[o.name] = item_counts(o.actor) or inventory_cache.by_name[o.name]
    end
    return inventory_cache.by_name
end

-- Class of a usable item (EItemCategory) carried by an officer on the team,
-- or nil, so the game is never told to use an item the team has run out of.
function game.team_item_class(team, category)
    for _, o in ipairs(game.officer_actors()) do
        if on_team(o, team) then
            for _, entry in ipairs(usable_items(o.actor) or {}) do
                if entry.categories[category] then
                    local ok, class = pcall(function() return entry.item:GetClass() end)
                    if ok and class then return class end
                end
            end
        end
    end
    return nil
end

local function class_name(obj)
    if not valid(obj) then return nil end
    return object_name(obj)
end

local DOOR_ACTIVITIES = {
    "ThrowGrenadeThroughDoorActivity", "LaunchGrenadeThroughDoorActivity",
    "C2DoorActivity", "ShotgunDoorActivity", "RamDoorActivity", "KickDoorActivity",
}

-- Reads one officer's door activities from its controller. Returns a list of
-- { name, door, item } (door and item are names or nil) and an error string.
local function door_activities(officer)
    local list = {}
    local ok, err = pcall(function()
        local controller = officer.actor.Controller
        if not valid(controller) then error("no controller", 0) end
        for _, activity_name in ipairs(DOOR_ACTIVITIES) do
            local activity = controller[activity_name]
            if valid(activity) then
                local door, item
                pcall(function() door = valid(activity.Door) and object_name(activity.Door) or nil end)
                pcall(function() item = class_name(activity.ThrowItemClass) end)
                if not item then pcall(function() item = class_name(activity.BreachItem) end) end
                list[#list + 1] = { name = activity_name:gsub("Activity$", ""), door = door, item = item }
            end
        end
    end)
    return list, (not ok) and tostring(err) or nil
end

-- What the game handed out for a door order: officers on the team whose door
-- activity targets this door, with the item each was given. Returns nil while
-- nobody has been assigned yet.
function game.describe_door_activities(team, door)
    local door_name = object_name(door)
    local parts = {}
    for _, o in ipairs(game.officer_actors()) do
        if on_team(o, team) then
            for _, a in ipairs((door_activities(o))) do
                if a.door == door_name then
                    parts[#parts + 1] = string.format("%s %s: %s", o.name, a.name, a.item or "no item")
                end
            end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "; ")
end

-- Every officer's door activities, for the F7 dump.
function game.activity_report()
    local lines = { "RoNTAK door activity dump (time " .. os.time() .. ")",
                    "CreateInvalidObject available: " .. tostring(CreateInvalidObject ~= nil), "" }
    for _, o in ipairs(game.officer_actors()) do
        local list, err = door_activities(o)
        lines[#lines + 1] = string.format("%s (%s)%s", o.name, o.team, err and ("  ERROR: " .. err) or "")
        for _, a in ipairs(list) do
            lines[#lines + 1] = string.format("    %-28s door=%-22s item=%s", a.name, a.door or "-", a.item or "-")
        end
    end
    return lines
end

-- Calls a no-argument function that returns a number; nil if it is missing or fails.
local function call_number(obj, fn_name)
    if not fn_name then return nil end
    local ok, value = pcall(function() return obj[fn_name](obj) end)
    if ok and type(value) == "number" then return value end
    return nil
end

-- "healthy", "injured", "downed", "incapacitated", "dead" or "arrested"; nil if unknown.
local function health_status(actor)
    local value = call_number(actor, config.officers.health_status_function)
    return value and (config.officers.health_status_values or {})[value] or nil
end

-- Health in percent (0-100), or nil.
local function health_percent(actor)
    local current = call_number(actor, config.officers.health_function)
    local max = call_number(actor, config.officers.max_health_function)
    if not current then return nil end
    if max and max > 0 then return math.floor(current / max * 100 + 0.5) end
    return current
end

function game.officers()
    local result = {}
    local items = inventories()
    for _, o in ipairs(game.officer_actors()) do
        result[#result + 1] = {
            id = o.name,
            name = o.display_name or o.name,
            team = o.team,
            pos = o.pos,
            yaw = yaw(o.actor),
            status = health_status(o.actor),
            health = health_percent(o.actor),
            items = items[o.name],
        }
    end
    return result
end

-- A point just outside the door on the team's side, and the direction from
-- the door to that side: what the game gets when you aim at a door yourself.
function game.door_approach(door, team)
    local ok, mid = pcall(function() return door:GetDoorMidLocation() end)
    local center = ok and mid and { x = mid.X, y = mid.Y, z = mid.Z } or location(door)
    if not center then return nil, nil end

    local sx, sy, n = 0, 0, 0
    for _, o in ipairs(game.officer_actors()) do
        if on_team(o, team) then sx, sy, n = sx + o.pos.x, sy + o.pos.y, n + 1 end
    end
    if n == 0 then
        local player = game.player()
        if player and player.pos then sx, sy, n = player.pos.x, player.pos.y, 1 end
    end

    local dx, dy = 1, 0
    if n > 0 then
        dx, dy = sx / n - center.x, sy / n - center.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 1 then dx, dy = dx / len, dy / len else dx, dy = 1, 0 end
    end
    local APPROACH_DISTANCE = 40
    return { x = center.x + dx * APPROACH_DISTANCE, y = center.y + dy * APPROACH_DISTANCE, z = center.z },
        { x = dx, y = dy, z = 0 }
end

-- Rebuilds the door list with FindAllOf. Doors do not move, so their
-- position is read here only.
-- Doors already known in the same level keep what was read about them, so a
-- periodic rescan only reads new doors. Returns true if every door is new.
local function rescan_doors(level)
    local old = door_cache.level == level and door_cache.list or {}
    local known = {}
    for _, door in ipairs(old) do known[door.id] = door end
    local list, by_id = {}, {}
    for _, actor in ipairs(find_all(config.doors.classes)) do
        if valid(actor) then
            local id = object_name(actor)
            local door = known[id]
            if door then
                door._actor = actor
            else
                local pos = location(actor)
                door = pos and {
                    id = id, pos = pos, yaw = yaw(actor), _actor = actor,
                    -- The game's rooms on each side of the door.
                    front_room = call_name(actor, config.doors.front_room_function),
                    back_room = call_name(actor, config.doors.back_room_function),
                    fresh = true,
                }
            end
            if door then
                by_id[id] = actor
                list[#list + 1] = door
            end
        end
    end
    door_cache = { level = level, at = os.time(), list = list, by_id = by_id, cursor = 0 }
    log.debug(string.format("found %d doors", #list))
end

-- Re-reads lock / open / broken state of the next slice of doors, and of
-- doors not read yet.
local function refresh_door_states()
    local doors
    doors, door_cache.cursor = next_slice(door_cache.list, door_cache.cursor,
        math.ceil(#door_cache.list / DOOR_STATE_TICKS))
    for _, door in ipairs(door_cache.list) do
        if door.fresh then doors[#doors + 1] = door end
    end
    for _, door in ipairs(doors) do
        door.fresh = nil
        local actor = door._actor
        if valid(actor) then
            door.locked = door_locked(actor)
            door.open = call_bool(actor, config.doors.open_function)
            door.broken = call_bool(actor, config.doors.broken_function)
            door.wedged = call_bool(actor, config.doors.jammed_function)
            door.trap = call_bool(actor, config.doors.trap_known_function)
        end
    end
end

-- Door data for state.json (without the actor objects).
function game.doors(level)
    local new_level = door_cache.level ~= level
    local due = new_level or os.time() - door_cache.at >= DOOR_RESCAN_SECONDS
        or (#door_cache.list == 0 and os.time() - door_cache.at >= SEARCH_RETRY_SECONDS)
    if due and game.scan_slot(new_level) then rescan_doors(level) end
    refresh_door_states()
    local list = {}
    for i, door in ipairs(door_cache.list) do
        list[i] = {
            id = door.id, pos = door.pos, yaw = door.yaw, locked = door.locked, open = door.open,
            broken = door.broken, wedged = door.wedged, trap = door.trap,
            front_room = door.front_room, back_room = door.back_room,
        }
    end
    return list
end

function game.door_by_id(id)
    local door = door_cache.by_id[id]
    if valid(door) then return door end
    return nil
end

function game.nearest_door_id(pos)
    local best, best_d = nil, math.huge
    for _, door in ipairs(door_cache.list) do
        local dx, dy, dz = door.pos.x - pos.x, door.pos.y - pos.y, door.pos.z - pos.z
        local d = dx * dx + dy * dy + dz * dz
        if d < best_d then best, best_d = door.id, d end
    end
    return best
end

local target_cache = {}

-- Builds the object a configured order is called on.
function game.resolve_target(target, door)
    if target == "player_controller" then return game.player_controller() end
    if target == "player_pawn" then return game.player_pawn() end
    if target == "door" then return door end
    local obj = target_cache[target]
    if valid(obj) then return obj end
    obj = FindFirstOf(target)
    if valid(obj) then
        target_cache[target] = obj
        return obj
    end
    return nil
end

-- People who can be restrained or reported ------------------------------

-- All suspects and civilians: { actor, id, kind } plus status / pos /
-- reported once read. Rebuilt every TARGET_RESCAN_SECONDS; what was already
-- read about each person is kept across rebuilds.
local target_cache = { at = -math.huge, actors = {}, cursor = 0 }
local target_state = { tick = nil, list = {}, by_id = {} }

local function target_actors()
    local first = target_cache.at == -math.huge
    local age = os.time() - target_cache.at
    local actors = target_cache.actors
    -- Also rescan soon when the list is empty or gone (menus, a new level).
    local due = age >= TARGET_RESCAN_SECONDS
        or (age >= SEARCH_RETRY_SECONDS and (#actors == 0 or not valid(actors[1].actor)))
    if not due or not game.scan_slot(first) then return actors end
    local old = {}
    for _, entry in ipairs(target_cache.actors) do old[entry.id] = entry end
    actors = {}
    for _, actor in ipairs(find_all(config.targets.classes)) do
        if valid(actor) then
            local id = object_name(actor)
            local entry = old[id]
            if entry then
                entry.actor = actor
            else
                local t = config.targets
                local suspect = call_bool(actor, t.suspect_function) == true
                if suspect or call_bool(actor, t.civilian_function) == true then
                    entry = { actor = actor, id = id, kind = suspect and "suspect" or "civilian", fresh = true }
                end
            end
            if entry then actors[#actors + 1] = entry end
        end
    end
    target_cache = { at = os.time(), actors = actors, cursor = 0 }
    return actors
end

local function read_target(entry)
    local actor, t = entry.actor, config.targets
    entry.fresh = nil
    if not valid(actor) then
        entry.status = nil
        return
    end
    local status = nil
    if call_bool(actor, t.arrested_function) then
        status = "arrested"
    elseif call_bool(actor, t.down_function) then
        status = "down"
    elseif call_bool(actor, t.surrendered_function) then
        status = "surrendered"
    end
    entry.status = status
    entry.pos = status and location(actor) or nil
    entry.reported = status and call_bool(actor, t.reported_function) == true or nil
end

-- Suspects and civilians that are surrendered, restrained or down, with
-- position and whether they have been reported. Anyone else is left out, so
-- the map never shows an active suspect. A quarter of the people are re-read
-- per tick (everyone once a second); people not read yet are read at once.
function game.targets()
    if target_state.tick == tick_id then return target_state.list end
    local actors = target_actors()
    local slice
    slice, target_cache.cursor = next_slice(actors, target_cache.cursor, math.ceil(#actors / TARGET_STATE_TICKS))
    for _, entry in ipairs(actors) do
        if entry.fresh then slice[#slice + 1] = entry end
    end
    for _, entry in ipairs(slice) do read_target(entry) end
    local list, by_id = {}, {}
    for _, entry in ipairs(actors) do
        if entry.status and entry.pos then
            by_id[entry.id] = entry.actor
            list[#list + 1] = {
                id = entry.id, kind = entry.kind, status = entry.status, pos = entry.pos,
                reported = entry.reported == true,
            }
        end
    end
    target_state = { tick = tick_id, list = list, by_id = by_id }
    return list
end

function game.target_by_id(id)
    local actor = target_state.by_id[id]
    if valid(actor) then return actor end
    return nil
end

-- The cached door entries (with front_room / back_room), for rooms.lua.
function game.door_entries()
    return door_cache.list
end

game.valid = valid
game.object_name = object_name
game.name_text = name_text
game.location = location
game.find_all = find_all
game.read_raw = read_raw
game.read_property = read_property
game.call_bool = call_bool
game.call_name = call_name
game.yaw = yaw
game.target_actors = target_actors

return game
