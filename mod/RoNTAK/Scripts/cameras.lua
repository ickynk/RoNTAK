-- Helicopter, drone and CCTV cameras for the map, and the people the
-- helicopter has tracked. Actor lists are cached like the rest of the mod;
-- each tick only reads positions of the few actors found.

local config = require("config")
local game = require("game")
local log = require("log")

local cameras = {}

local valid, location = game.valid, game.location
local read_raw, read_property, call_bool = game.read_raw, game.read_property, game.call_bool

local HELICOPTER_RESCAN_SECONDS = 10
local DRONE_RESCAN_SECONDS = 5     -- drones appear when deployed
local CCTV_RESCAN_SECONDS = 15     -- until a level's cameras are found
local CCTV_WIRED_SECONDS = 1

local helicopters = { at = -math.huge, actors = {} }
local drones = { at = -math.huge, actors = {} }
local cctv = { level = nil, at = -math.huge, list = {}, by_actor = {}, system = nil, wired = false, wired_at = -math.huge }

-- People tracked by the helicopter, by object name. Set from the
-- OnTargetFound / OnTargetLost hooks, which only store the actor: everything
-- else is read in the tick.
local spotted = { level = nil, by_id = {} }
local tracked_actor = nil
local hook_fired = false

local function c() return config.cameras or {} end

local function component_view(component)
    if not valid(component) then return nil end
    local ok, loc = pcall(function() return component:K2_GetComponentLocation() end)
    local ok_rot, rot = pcall(function() return component:K2_GetComponentRotation() end)
    if not ok or not loc or not ok_rot or not rot then return nil end
    return { pos = { x = loc.X, y = loc.Y, z = loc.Z }, yaw = rot.Yaw, pitch = rot.Pitch }
end

local function cached(cache, classes, seconds)
    if os.time() - cache.at >= seconds then
        cache.actors = {}
        for _, actor in ipairs(game.find_all(classes or {})) do
            if valid(actor) then cache.actors[#cache.actors + 1] = actor end
        end
        cache.at = os.time()
    end
    return cache.actors
end

-- Helicopter -------------------------------------------------------------

function cameras.install_hooks()
    if not RegisterHook then return end
    local function hook(fn_path, fn)
        if not fn_path then return end
        local ok, err = pcall(RegisterHook, fn_path, fn)
        if not ok then log.error("cannot hook " .. fn_path .. ": " .. tostring(err)) end
    end
    hook(c().target_found_hook, function(self, target)
        local ok, actor = pcall(function() return target:get() end)
        if ok then tracked_actor = actor end
        hook_fired = true
    end)
    hook(c().target_lost_hook, function()
        tracked_actor = nil
    end)
end

local function person_kind(actor)
    local t = config.targets
    if call_bool(actor, t.suspect_function) then return "suspect" end
    if call_bool(actor, t.civilian_function) then return "civilian" end
    return nil
end

local function update_spotted(level)
    if spotted.level ~= level then
        spotted = { level = level, by_id = {} }
        tracked_actor = nil
    end
    local tracked_id = nil
    if valid(tracked_actor) then
        local id = game.object_name(tracked_actor)
        local entry = spotted.by_id[id]
        if not entry then
            local kind = person_kind(tracked_actor)
            if kind then
                entry = { id = id, kind = kind, source = "helicopter" }
                spotted.by_id[id] = entry
                log.info("helicopter is tracking " .. kind .. " " .. id)
            end
        end
        local pos = entry and location(tracked_actor)
        if pos then
            entry.pos, entry.seen_at, tracked_id = pos, os.time(), id
        end
    end
    for id, entry in pairs(spotted.by_id) do
        entry.status = (id == tracked_id) and "tracked" or "last_seen"
    end
end

local function helicopter_list(viewing)
    local list = {}
    for _, actor in ipairs(cached(helicopters, c().helicopter_classes, HELICOPTER_RESCAN_SECONDS)) do
        local pos = valid(actor) and location(actor)
        if pos then
            local entry = { id = game.object_name(actor), pos = pos, yaw = game.yaw(actor) }
            local tracking = read_raw(actor, c().tracking_property)
            if valid(tracking) then entry.tracking = read_property(tracking, "bHasTarget") == true end
            local camera = read_raw(actor, c().camera_property)
            if valid(camera) then
                entry.camera_active = call_bool(camera, "IsCameraActive")
                local capture = read_raw(camera, "CaptureComponent")
                local view = component_view(capture)
                if view then
                    view.fov = read_property(capture, "FOVAngle")
                    entry.view = view
                end
            end
            entry.viewing = viewing ~= nil and entry.id == viewing
            list[#list + 1] = entry
        end
    end
    return list
end

-- Drones -----------------------------------------------------------------

local function drone_list()
    local list = {}
    for _, actor in ipairs(cached(drones, c().drone_classes, DRONE_RESCAN_SECONDS)) do
        local pos = valid(actor) and call_bool(actor, c().drone_alive_function) ~= false and location(actor)
        if pos then
            local entry = { id = game.object_name(actor), pos = pos, yaw = game.yaw(actor) }
            entry.name = game.call_name(actor, c().drone_name_function)
            local ok, component = pcall(function() return actor[c().drone_view_function](actor) end)
            entry.view = ok and component_view(component) or nil
            local camera = read_raw(actor, c().drone_camera_property)
            if valid(camera) and entry.view then entry.view.fov = read_property(camera, "FieldOfView") end
            list[#list + 1] = entry
        end
    end
    return list
end

-- CCTV -------------------------------------------------------------------

-- CCTV cameras do not move: their position and view are read once per level.
local function rescan_cctv(level)
    local list, by_actor = {}, {}
    for _, actor in ipairs(game.find_all(c().cctv_point_classes or {})) do
        if valid(actor) then
            local capture = read_raw(actor, "CaptureComponent")
            local view = component_view(capture)
            if view then
                view.fov = read_property(capture, "FOVAngle")
                local id = game.object_name(actor)
                list[#list + 1] = {
                    id = id, pos = view.pos, view = view,
                    name = game.name_text(read_raw(actor, "CameraName")),
                    floor = read_property(actor, "FloorNumber"),
                    number = read_property(actor, "CameraNumber"),
                }
                by_actor[id] = true
            end
        end
    end
    local systems = game.find_all(c().cctv_system_classes or {})
    cctv = { level = level, at = os.time(), list = list, by_actor = by_actor, system = systems[1],
        wired = false, wired_at = -math.huge }
    if #list > 0 then log.debug(string.format("found %d CCTV cameras", #list)) end
end

local function cctv_state(level, viewing)
    if cctv.level ~= level or (#cctv.list == 0 and os.time() - cctv.at >= CCTV_RESCAN_SECONDS) then
        rescan_cctv(level)
    end
    if #cctv.list == 0 then return nil end
    if os.time() - cctv.wired_at >= CCTV_WIRED_SECONDS then
        local wired = false
        if valid(cctv.system) then
            wired = call_bool(cctv.system, c().cctv_wired_function)
            if wired == nil then wired = read_property(cctv.system, c().cctv_wired_property) == true end
        end
        cctv.wired, cctv.wired_at = wired, os.time()
    end
    -- Watching a feed means the cameras are connected, whatever the flag says.
    local watching = viewing ~= nil and cctv.by_actor[viewing] == true
    if not cctv.wired and not watching then return { wired = false, cameras = {} } end
    return { wired = true, viewing = watching and viewing or nil, cameras = cctv.list }
end

-- The object name of a pawn property that holds a camera / helicopter.
local function viewing_id(pawn, property)
    local obj = valid(pawn) and read_raw(pawn, property)
    if valid(obj) then return game.object_name(obj) end
    return nil
end

-- Cameras for state.json, or nil outside a level.
function cameras.state(level)
    if not level then return nil end
    local pawn = game.player_pawn()
    update_spotted(level)
    return {
        helicopters = helicopter_list(viewing_id(pawn, c().view_helicopter_property)),
        drones = drone_list(),
        cctv = cctv_state(level, viewing_id(pawn, c().view_camera_property)),
        hook_fired = hook_fired,
    }
end

-- Suspects and civilians the helicopter has tracked, minus those already
-- in the targets list (surrendered, restrained or down).
function cameras.spotted(targets)
    local known = {}
    for _, t in ipairs(targets or {}) do known[t.id] = true end
    local list = {}
    for id, entry in pairs(spotted.by_id) do
        if not known[id] and entry.pos then
            list[#list + 1] = {
                id = id, kind = entry.kind, status = entry.status, pos = entry.pos,
                source = entry.source, seen_at = entry.seen_at,
            }
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

return cameras
