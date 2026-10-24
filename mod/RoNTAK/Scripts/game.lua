-- Reads game state through UE4SS. All game-specific names come from config.lua.

local config = require("config")
local log = require("log")

local game = {}

-- FindAllOf walks every loaded object (hundreds of thousands in a level) on
-- the game thread, so it is only used to rebuild cached actor lists:
local RESCAN_SECONDS = 5          -- officers / player controller
local DOOR_RESCAN_SECONDS = 15    -- door list
local SEARCH_RETRY_SECONDS = 2    -- after a search found nothing (e.g. in menus)
-- Cheaper per-object reads, still not needed every tick:
local DOOR_STATE_SECONDS = 2
local INVENTORY_REFRESH_SECONDS = 2

local door_cache = { level = nil, at = -math.huge, state_at = -math.huge, list = {}, by_id = {} }

local tick_id = 0

-- Called once at the start of every mod tick; per-tick reads are reused
-- within a tick.
function game.begin_tick()
    tick_id = tick_id + 1
end

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

local officer_cache = { at = -math.huge, list = {} }

-- The officer actors, rebuilt with FindAllOf every RESCAN_SECONDS or when
-- one of them is gone (at most once per SEARCH_RETRY_SECONDS).
local function officer_list()
    local age = os.time() - officer_cache.at
    local stale = age >= RESCAN_SECONDS
    if not stale and age >= SEARCH_RETRY_SECONDS then
        if #officer_cache.list == 0 then stale = true end
        for _, o in ipairs(officer_cache.list) do
            if not valid(o.actor) then stale = true break end
        end
    end
    if not stale then return officer_cache.list end

    local list = {}
    local player_pawn = game.player_pawn()
    -- Compare by name: two UE4SS handles to the same object are not always equal.
    local player_name = valid(player_pawn) and object_name(player_pawn) or nil
    for _, actor in ipairs(find_all(config.officers.classes)) do
        if valid(actor) then
            local name = object_name(actor)
            if name ~= player_name and not excluded(name) then
                local raw_team = read_property(actor, config.officers.team_property)
                list[#list + 1] = { actor = actor, name = name, team = config.officers.team_values[raw_team] or "unknown" }
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
                result[#result + 1] = { actor = o.actor, name = o.name, team = o.team, pos = pos }
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

local inventory_cache = { at = -1, by_name = {} }

-- Counts of config.inventory items per officer name, refreshed once a second.
local function inventories()
    if os.time() - inventory_cache.at >= INVENTORY_REFRESH_SECONDS then
        local by_name = {}
        for _, o in ipairs(game.officer_actors()) do
            local items = usable_items(o.actor)
            if items then
                local counts = {}
                for name, category in pairs(config.inventory or {}) do
                    counts[name] = 0
                    for _, entry in ipairs(items) do
                        if entry.categories[category] then counts[name] = counts[name] + 1 end
                    end
                end
                by_name[o.name] = counts
            end
        end
        inventory_cache = { at = os.time(), by_name = by_name }
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

function game.officers()
    local result = {}
    local items = inventories()
    for _, o in ipairs(game.officer_actors()) do
        result[#result + 1] = {
            id = o.name,
            name = read_property(o.actor, config.officers.name_property) or o.name,
            team = o.team,
            pos = o.pos,
            yaw = yaw(o.actor),
            health = read_property(o.actor, config.officers.health_property),
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
local function rescan_doors(level)
    local list, by_id = {}, {}
    for _, actor in ipairs(find_all(config.doors.classes)) do
        if valid(actor) then
            local pos = location(actor)
            if pos then
                local id = object_name(actor)
                by_id[id] = actor
                list[#list + 1] = {
                    id = id, pos = pos, yaw = yaw(actor), _actor = actor,
                    -- The game's rooms on each side of the door.
                    front_room = call_name(actor, config.doors.front_room_function),
                    back_room = call_name(actor, config.doors.back_room_function),
                }
            end
        end
    end
    door_cache = { level = level, at = os.time(), state_at = -math.huge, list = list, by_id = by_id }
    log.debug(string.format("found %d doors", #list))
end

-- Re-reads lock / open / broken state of the cached doors.
local function refresh_door_states()
    for _, door in ipairs(door_cache.list) do
        local actor = door._actor
        if valid(actor) then
            door.locked = door_locked(actor)
            door.open = call_bool(actor, config.doors.open_function)
            door.broken = call_bool(actor, config.doors.broken_function)
        end
    end
    door_cache.state_at = os.time()
end

-- Door data for state.json (without the actor objects).
function game.doors(level)
    if door_cache.level ~= level or os.time() - door_cache.at >= DOOR_RESCAN_SECONDS then
        rescan_doors(level)
    end
    if os.time() - door_cache.state_at >= DOOR_STATE_SECONDS then
        refresh_door_states()
    end
    local list = {}
    for i, door in ipairs(door_cache.list) do
        list[i] = {
            id = door.id, pos = door.pos, yaw = door.yaw, locked = door.locked, open = door.open,
            broken = door.broken, front_room = door.front_room, back_room = door.back_room,
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

-- The cached door entries (with front_room / back_room), for rooms.lua.
function game.door_entries()
    return door_cache.list
end

game.valid = valid
game.object_name = object_name
game.name_text = name_text
game.location = location
game.find_all = find_all

return game
