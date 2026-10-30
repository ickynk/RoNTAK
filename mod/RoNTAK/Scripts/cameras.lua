-- Helicopter, drone and CCTV cameras for the map, and the suspects and
-- civilians they see: the helicopter reports who it tracks; for CCTV the mod
-- checks who is inside a wired camera's view with a clear line of sight.
-- Actor lists are cached like the rest of the mod; each tick only reads
-- positions of the few actors found.

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
local CCTV_SIGHT_SECONDS = 1       -- who the CCTV cameras see
local CCTV_DEFAULT_ASPECT = 9 / 16 -- picture height / width when the camera doesn't say

local helicopters = { at = -math.huge, actors = {} }
local drones = { at = -math.huge, actors = {} }
local cctv = { level = nil, at = -math.huge, list = {}, by_actor = {}, system = nil, wired = false, wired_at = -math.huge }

-- People seen by the helicopter or CCTV, by object name. The helicopter's
-- OnTargetFound / OnTargetLost hooks only store the actor: everything else is
-- read in the tick.
local spotted = { level = nil, by_id = {} }
local tracked_actor = nil
local hook_fired = false
-- People the CCTV cameras currently see: { actor, kind, camera name }.
local cctv_sight = { at = -math.huge, seen = {}, los_failed = false }

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

-- Records that a camera sees actor now. Returns its id, or nil if it is not
-- a suspect or civilian.
local function mark_seen(actor, source, camera, kind)
    if not valid(actor) then return nil end
    local id = game.object_name(actor)
    local entry = spotted.by_id[id]
    if not entry then
        kind = kind or person_kind(actor)
        if not kind then return nil end
        entry = { id = id, kind = kind }
        spotted.by_id[id] = entry
        if source == "helicopter" then
            log.info("helicopter is tracking " .. kind .. " " .. id)
        else
            log.info("CCTV " .. tostring(camera) .. " sees " .. kind .. " " .. id)
        end
    end
    local pos = location(actor)
    if not pos then return nil end
    entry.pos, entry.seen_at, entry.source, entry.camera = pos, os.time(), source, camera
    return id
end

local function update_spotted(level)
    if spotted.level ~= level then
        spotted = { level = level, by_id = {} }
        tracked_actor = nil
        cctv_sight = { at = -math.huge, seen = {}, los_failed = false }
    end
    local seen = {}
    for _, s in ipairs(cctv_sight.seen) do
        local id = mark_seen(s.actor, "cctv", s.camera, s.kind)
        if id then seen[id] = true end
    end
    -- The helicopter last, so it is named as the source when both see someone.
    local id = mark_seen(tracked_actor, "helicopter")
    if id then seen[id] = true end
    for entry_id, entry in pairs(spotted.by_id) do
        entry.status = seen[entry_id] and "tracked" or "last_seen"
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
                local w, h = read_property(actor, "RenderWidth"), read_property(actor, "RenderHeight")
                list[#list + 1] = {
                    id = id, pos = view.pos, view = view,
                    name = game.name_text(read_raw(actor, "CameraName")),
                    floor = read_property(actor, "FloorNumber"),
                    number = read_property(actor, "CameraNumber"),
                    aspect = (type(w) == "number" and type(h) == "number" and w > 0) and h / w or CCTV_DEFAULT_ASPECT,
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

-- Whether a point is inside a CCTV camera's picture and range.
local function in_view(cam, pos)
    local v = cam.view
    local dx, dy, dz = pos.x - v.pos.x, pos.y - v.pos.y, pos.z - v.pos.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist < 1 or dist > (c().cctv_view_range or 2500) then return false end
    local yaw, pitch = math.rad(v.yaw or 0), math.rad(v.pitch or 0)
    local ahead = dx * math.cos(pitch) * math.cos(yaw) + dy * math.cos(pitch) * math.sin(yaw) + dz * math.sin(pitch)
    if ahead <= 0 then return false end
    local side = -dx * math.sin(yaw) + dy * math.cos(yaw)
    local up = -dx * math.sin(pitch) * math.cos(yaw) - dy * math.sin(pitch) * math.sin(yaw) + dz * math.cos(pitch)
    local half = math.tan(math.rad((v.fov or 90) / 2))
    -- A little extra height: positions are the body's centre, the picture shows head to feet.
    return math.abs(side) <= ahead * half and math.abs(up) <= ahead * half * (cam.aspect or CCTV_DEFAULT_ASPECT) * 1.3
end

-- Asks the game whether the person can see the camera (and so the camera
-- them). The point is moved a little in front of the lens, out of the
-- camera's own housing.
local function line_of_sight(actor, cam)
    local v = cam.view
    local yaw, pitch = math.rad(v.yaw or 0), math.rad(v.pitch or 0)
    local point = {
        X = v.pos.x + math.cos(pitch) * math.cos(yaw) * 30,
        Y = v.pos.y + math.cos(pitch) * math.sin(yaw) * 30,
        Z = v.pos.z + math.sin(pitch) * 30,
    }
    local fn = c().cctv_line_of_sight_function
    local ok, result = pcall(function() return actor[fn](actor, point) end)
    if ok and type(result) == "boolean" then return result end
    if not cctv_sight.los_failed then
        cctv_sight.los_failed = true
        log.error("CCTV line of sight check failed (" .. tostring(fn) .. "): " .. tostring(result))
    end
    return false
end

-- Suspects and civilians inside a wired camera's view with a clear line of sight.
local function update_cctv_sight(cctv_info)
    if os.time() - cctv_sight.at < CCTV_SIGHT_SECONDS then return end
    cctv_sight.at = os.time()
    cctv_sight.seen = {}
    if not (cctv_info and cctv_info.wired and c().cctv_spots_people ~= false) then return end
    for _, person in ipairs(game.target_actors()) do
        local pos = valid(person.actor) and location(person.actor)
        if pos then
            for _, cam in ipairs(cctv_info.cameras) do
                if in_view(cam, pos) and line_of_sight(person.actor, cam) then
                    cctv_sight.seen[#cctv_sight.seen + 1] = { actor = person.actor, kind = person.kind, camera = cam.name or cam.id }
                    break
                end
            end
        end
    end
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
    local cctv_info = cctv_state(level, viewing_id(pawn, c().view_camera_property))
    if spotted.level == level then update_cctv_sight(cctv_info) end
    update_spotted(level)
    return {
        helicopters = helicopter_list(viewing_id(pawn, c().view_helicopter_property)),
        drones = drone_list(),
        cctv = cctv_info,
        hook_fired = hook_fired,
    }
end

-- Suspects and civilians the helicopter or CCTV has seen, minus those already
-- in the targets list (surrendered, restrained or down).
function cameras.spotted(targets)
    local known = {}
    for _, t in ipairs(targets or {}) do known[t.id] = true end
    local list = {}
    for id, entry in pairs(spotted.by_id) do
        if not known[id] and entry.pos then
            list[#list + 1] = {
                id = id, kind = entry.kind, status = entry.status, pos = entry.pos,
                source = entry.source, camera = entry.camera, seen_at = entry.seen_at,
            }
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

return cameras
