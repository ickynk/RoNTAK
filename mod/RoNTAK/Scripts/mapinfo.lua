-- Reads the current level's floor data from the game (F6): each building's
-- floors and their world-space height bands (ABuildingTrigger.GeneratedFloors).
-- Writes bridge/mapinfo.json. Read only.
--
-- Note: a UE4SS error from calling a method on an empty (nullptr) object is
-- not caught by pcall; it aborts the whole callback. Reading the planning map
-- textures (LevelData.MapFloors) did that, so it is no longer read here.

local bridge = require("bridge")
local game = require("game")
local json = require("json")
local log = require("log")

local mapinfo = {}

local function text(value)
    if value == nil then return nil end
    local ok, s = pcall(function() return value:ToString() end)
    if ok and s ~= nil then return tostring(s) end
    return nil
end

local function vec3(v)
    local ok, r = pcall(function() return { x = v.X, y = v.Y, z = v.Z } end)
    return ok and r or nil
end

local function each(array, fn)
    local ok, err = pcall(function()
        array:ForEach(function(i, element) fn(i, element:get()) end)
    end)
    if not ok then log.error("mapinfo: " .. tostring(err)) end
end

local function read_buildings(info)
    log.info("mapinfo: reading BuildingTrigger floors")
    info.buildings = {}
    for _, building in ipairs(FindAllOf("BuildingTrigger") or {}) do
        if game.valid(building) then
            local entry = {
                name = text(building.BuildingName),
                actor = game.object_name(building),
                number_of_floors = building.NumberOfFloors,
                floors = {},
            }
            pcall(function() entry.location = vec3(building:K2_GetActorLocation()) end)
            each(building.GeneratedFloors, function(_, floor)
                entry.floors[#entry.floors + 1] = {
                    number = floor.Number,
                    height = floor.Height,
                    name = text(floor.Name),
                    location = vec3(floor.Location),
                    extent = vec3(floor.Extent),
                }
            end)
            info.buildings[#info.buildings + 1] = entry
        end
    end
end

-- F6: dump everything to bridge/mapinfo.json.
function mapinfo.dump()
    local info = { level = game.level_name(), errors = {} }
    local steps = { read_buildings }
    for _, step in ipairs(steps) do
        local ok, err = pcall(step, info)
        if not ok then
            info.errors[#info.errors + 1] = tostring(err)
            log.error("mapinfo: " .. tostring(err))
        end
    end
    local ok, encoded = pcall(json.encode, info)
    if not ok then
        log.error("mapinfo: cannot encode: " .. tostring(encoded))
        return info
    end
    bridge.write_file("mapinfo.json", encoded)
    log.info(string.format("mapinfo: %d buildings -> mapinfo.json", #(info.buildings or {})))
    return info
end

return mapinfo
