-- Reads the current level's map data from the game (F6): the planning map's
-- calibration and floor textures (AReadyOrNotGameState.LevelData) and the
-- floors' world-space height bands (ABuildingTrigger.GeneratedFloors).
-- Writes bridge/mapinfo.json. Read only.

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

local function vec2(v)
    local ok, r = pcall(function() return { x = v.X, y = v.Y } end)
    return ok and r or nil
end

local function vec3(v)
    local ok, r = pcall(function() return { x = v.X, y = v.Y, z = v.Z } end)
    return ok and r or nil
end

-- Asset path of a TSoftObjectPtr. UE4SS exposes these differently between
-- versions, so several ways are tried; the one that worked is reported too.
local function soft_path(value)
    if value == nil then return nil end
    local attempts = {
        { "ToString", function() return value:ToString() end },
        { "AssetPath", function()
            local p = value.SoftObjectPtr.ObjectID.AssetPath
            return p.PackageName:ToString() .. "." .. p.AssetName:ToString()
        end },
        { "AssetPathName", function() return value.SoftObjectPtr.ObjectID.AssetPathName:ToString() end },
        { "Get", function() return value:Get():GetFullName() end },
    }
    for _, attempt in ipairs(attempts) do
        local ok, s = pcall(attempt[2])
        if ok and type(s) == "string" and s ~= "" and s ~= "None" and s ~= "None.None" then
            return s, attempt[1]
        end
    end
    return nil, "none worked"
end

local function each(array, fn)
    local ok, err = pcall(function()
        array:ForEach(function(i, element) fn(i, element:get()) end)
    end)
    if not ok then log.error("mapinfo: " .. tostring(err)) end
end

local function read_level_data(info)
    local state = FindFirstOf("ReadyOrNotGameState")
    if not game.valid(state) then
        info.errors[#info.errors + 1] = "no ReadyOrNotGameState"
        return
    end
    log.info("mapinfo: reading LevelData")
    local level = state.LevelData

    log.info("mapinfo: reading MapLayout")
    local layout = level.MapLayout
    local overview, method = soft_path(layout.MapOverviewTexture)
    info.map_layout = {
        origin = vec2(layout.MapOrigin),
        size = layout.MapSize,
        overview_texture = overview,
    }
    info.soft_path_method = method

    log.info("mapinfo: reading MapFloors")
    info.map_floors = {}
    each(level.MapFloors, function(i, floor)
        info.map_floors[#info.map_floors + 1] = {
            index = i,
            full_name = text(floor.FloorFullName),
            short_name = text(floor.FloorShortName),
            layout_texture = (soft_path(floor.FloorLayout)),
            floorplan_material = (soft_path(floor.FloorplanMaterial)),
        }
    end)

    log.info("mapinfo: reading Floors")
    info.floors = {}
    each(level.Floors, function(i, floor)
        info.floors[#info.floors + 1] = {
            index = i,
            name = text(floor.Name),
            number = floor.Number,
            floor_map = (soft_path(floor.FloorMap)),
        }
    end)
    pcall(function() info.default_floor_index = level.DefaultFloorIndex end)
    pcall(function() info.friendly_name = text(level.FriendlyLevelName) end)
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
    local steps = { read_level_data, read_buildings }
    for _, step in ipairs(steps) do
        local ok, err = pcall(step, info)
        if not ok then
            info.errors[#info.errors + 1] = tostring(err)
            log.error("mapinfo: " .. tostring(err))
        end
    end
    bridge.write_file("mapinfo.json", json.encode(info))
    log.info(string.format("mapinfo: %d map floors, %d buildings -> mapinfo.json (soft paths via %s)",
        #(info.map_floors or {}), #(info.buildings or {}), tostring(info.soft_path_method)))
    return info
end

return mapinfo
