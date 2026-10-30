-- The level's rooms, as the game's AI knows them: each threat-awareness point
-- carries its room's name, and doors know the rooms on either side. Built
-- once per level and written to bridge/rooms.json (not every tick: it uses
-- FindAllOf, which walks every loaded object).

local bridge = require("bridge")
local config = require("config")
local game = require("game")
local json = require("json")
local log = require("log")

local rooms = {}

-- If a level gives no rooms (still loading), try again after this long.
local RETRY_SECONDS = 60   -- while a level has no rooms (one FindAllOf each time)

local built = { level = nil, at = -math.huge, count = 0, version = nil }

-- Convex hull (monotone chain) of { x, y } points, counter-clockwise.
local function hull(points)
    local pts = {}
    for _, p in ipairs(points) do pts[#pts + 1] = p end
    table.sort(pts, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
    if #pts < 3 then return pts end
    local function cross(o, a, b)
        return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
    end
    local lower, upper = {}, {}
    for _, p in ipairs(pts) do
        while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 0 do table.remove(lower) end
        lower[#lower + 1] = p
    end
    for i = #pts, 1, -1 do
        local p = pts[i]
        while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do table.remove(upper) end
        upper[#upper + 1] = p
    end
    table.remove(lower)
    table.remove(upper)
    for _, p in ipairs(upper) do lower[#lower + 1] = p end
    return lower
end

local function median(values)
    if #values == 0 then return 0 end
    table.sort(values)
    return values[math.floor((#values + 1) / 2)]
end

local function collect()
    local by_name, order = {}, {}
    local function room(name)
        if not by_name[name] then
            by_name[name] = { name = name, points = {}, zs = {}, doors = {} }
            order[#order + 1] = name
        end
        return by_name[name]
    end

    for _, actor in ipairs(game.find_all(config.rooms.point_classes)) do
        if game.valid(actor) then
            local ok, raw = pcall(function() return actor[config.rooms.room_property] end)
            local name = ok and game.name_text(raw) or nil
            local outside_ok, outside = pcall(function() return actor[config.rooms.outside_property] end)
            local pos = name and game.location(actor)
            if pos and not (outside_ok and outside == true) then
                local r = room(name)
                r.points[#r.points + 1] = { pos.x, pos.y }
                r.zs[#r.zs + 1] = pos.z
            end
        end
    end

    for _, door in ipairs(game.door_entries()) do
        for _, name in ipairs({ door.front_room, door.back_room }) do
            if name then
                local r = room(name)
                r.doors[#r.doors + 1] = door.id
                if #r.zs == 0 then r.door_z = door.pos.z end
            end
        end
    end

    local list = {}
    for _, name in ipairs(order) do
        local r = by_name[name]
        list[#list + 1] = {
            name = name,
            hull = hull(r.points),
            points = #r.points,
            z = #r.zs > 0 and median(r.zs) or r.door_z,
            doors = r.doors,
        }
    end
    return list
end

-- Builds rooms.json when the level changes (and retries while it finds none).
-- Returns a version string that changes whenever rooms.json is rewritten.
function rooms.update(level)
    if not level then return nil end
    local new_level = level ~= built.level
    local due = new_level or (built.count == 0 and os.time() - built.at >= RETRY_SECONDS)
    if not due or #game.door_entries() == 0 or not game.scan_slot(new_level) then return built.version end

    local ok, list = pcall(collect)
    if not ok then
        log.error("rooms: " .. tostring(list))
        list = {}
    end
    built = { level = level, at = os.time(), count = #list, version = string.format("%s#%d#%d", level, #list, os.time()) }
    bridge.write_file("rooms.json", json.encode({ level = level, rooms = list }))
    log.info(string.format("rooms: %d rooms in %s -> rooms.json", #list, level))
    return built.version
end

return rooms
