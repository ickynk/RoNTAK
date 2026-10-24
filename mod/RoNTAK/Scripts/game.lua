-- Reads game state through UE4SS. All game-specific names come from config.lua.

local config = require("config")
local log = require("log")

local game = {}

local DOOR_REFRESH_SECONDS = 1
local INVENTORY_REFRESH_SECONDS = 1

local door_cache = { level = nil, at = 0, list = {}, by_id = {} }

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

function game.player_controller()
    local controllers = FindAllOf("PlayerController")
    if not controllers then return nil end
    for _, pc in ipairs(controllers) do
        if valid(pc) and valid(pc.Pawn) and valid(pc.Player) then return pc end
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

-- Officer actors with their team, for orders that need the actual objects.
function game.officer_actors()
    local result = {}
    local player_pawn = game.player_pawn()
    -- Compare by name: two UE4SS handles to the same object are not always equal.
    local player_name = valid(player_pawn) and object_name(player_pawn) or nil
    for _, actor in ipairs(find_all(config.officers.classes)) do
        if valid(actor) then
            local name = object_name(actor)
            local pos = location(actor)
            if pos and name ~= player_name and not excluded(name) then
                local raw_team = read_property(actor, config.officers.team_property)
                result[#result + 1] = {
                    actor = actor,
                    name = name,
                    team = config.officers.team_values[raw_team] or "unknown",
                    pos = pos,
                }
            end
        end
    end
    return result
end

local function on_team(officer, team)
    return team == "gold" or officer.team == team
end

local function item_count(actor, category)
    local ok, count = pcall(function() return actor.InventoryComp:CountInventoryItemType(category) end)
    if ok and type(count) == "number" then return count end
    return nil
end

local inventory_cache = { at = -1, by_name = {} }

-- Counts of config.inventory items per officer name, refreshed once a second.
local function inventories()
    if os.time() - inventory_cache.at >= INVENTORY_REFRESH_SECONDS then
        local by_name = {}
        for _, o in ipairs(game.officer_actors()) do
            local items = {}
            for item, category in pairs(config.inventory or {}) do
                items[item] = item_count(o.actor, category)
            end
            by_name[o.name] = items
        end
        inventory_cache = { at = os.time(), by_name = by_name }
    end
    return inventory_cache.by_name
end

-- Class of an item (EItemCategory) carried by an officer on the team, or nil.
-- Only officers that still have at least one are considered, so the game is
-- never told to use an item the team has run out of.
function game.team_item_class(team, category)
    for _, o in ipairs(game.officer_actors()) do
        local count = item_count(o.actor, category)
        if on_team(o, team) and (count == nil or count > 0) then
            local ok, class = pcall(function()
                local item = o.actor.InventoryComp:GetInventoryItemOfType(category)
                if item and item:IsValid() then return item:GetClass() end
                return nil
            end)
            if ok and class then return class end
        end
    end
    return nil
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

local function refresh_doors(level)
    local list, by_id = {}, {}
    for _, actor in ipairs(find_all(config.doors.classes)) do
        if valid(actor) then
            local pos = location(actor)
            if pos then
                local id = object_name(actor)
                by_id[id] = actor
                list[#list + 1] = {
                    id = id,
                    pos = pos,
                    yaw = yaw(actor),
                    locked = door_locked(actor),
                    open = call_bool(actor, config.doors.open_function),
                    broken = call_bool(actor, config.doors.broken_function),
                }
            end
        end
    end
    door_cache = { level = level, at = os.time(), list = list, by_id = by_id }
    log.debug(string.format("found %d doors", #list))
end

function game.doors(level)
    if door_cache.level ~= level or os.time() - door_cache.at > DOOR_REFRESH_SECONDS then
        refresh_doors(level)
    end
    return door_cache.list
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

-- Builds the object a configured order is called on.
function game.resolve_target(target, door)
    if target == "player_controller" then return game.player_controller() end
    if target == "player_pawn" then return game.player_pawn() end
    if target == "door" then return door end
    local obj = FindFirstOf(target)
    if valid(obj) then return obj end
    return nil
end

game.valid = valid
game.object_name = object_name

return game
