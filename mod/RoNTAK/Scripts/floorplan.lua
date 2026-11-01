-- Floor plan capture (config.keys.floor_capture, F11).
--
-- Stand on a floor and press the key: the mod renders a true top-down
-- picture of the whole level at that floor and saves it in the bridge
-- folder, for the companion to use as that floor's plan.
--
--   * Orthographic (no perspective): one scale everywhere, walls don't lean.
--   * The camera sits ~1.7 m above the floor with its near plane at 0, so
--     everything above (roofs, upper floors) is left out. (Tested: a clip
--     plane did not cut anything in this game.)
--   * Base colour (no lighting, fog or bloom), so dark rooms read clearly.
--     The PNG comes out with alpha 0; the companion makes it opaque.
--   * The area covers every door of the level plus a margin, so its
--     position is known exactly: captures.json holds the pixel <-> world
--     anchors, and no calibration is needed.
--   * Walls the picture can't show (hollow meshes cut open) are then traced
--     with the game's collision over a few seconds (walls.lua).
--
-- The camera is a SceneCaptureComponent2D built with StaticConstructObject
-- (no actor, no hooks). It freezes the game for a moment.

local bridge = require("bridge")
local game = require("game")
local json = require("json")
local log = require("log")
local walls = require("walls")

local floorplan = {}

local CUT_ABOVE_PLAYER = 80     -- the pawn's position is ~90 cm above its feet: cut ~1.7 m up
local FEET_BELOW_PLAYER = 90
local MARGIN_CM = 1500          -- around the outermost doors
local MIN_AREA_CM = 4000
local CM_PER_PX = 3             -- target detail; the picture is at most MAX_PX wide
local MIN_PX, MAX_PX = 1024, 4096
local SAME_FLOOR_CM = 150       -- a new capture this close in height replaces the old one
local CAPTURES = "captures.json"

local valid = game.valid

local function note(line) log.info("floor capture: " .. line) end

-- Tries each argument list in turn (engine versions differ in trailing parameters).
local function try_call(obj, fn, ...)
    local last_err
    for _, args in ipairs({ ... }) do
        local ok, result = pcall(function() return obj[fn](obj, table.unpack(args)) end)
        if ok then return true, result end
        last_err = result
    end
    return false, last_err
end

local function set(obj, prop, value)
    local ok, err = pcall(function() obj[prop] = value end)
    if not ok then note(string.format("set %s failed: %s", prop, tostring(err))) end
end

-- The square to capture: all doors and the player, plus a margin.
function floorplan.area(doors, player_pos)
    local min_x, max_x, min_y, max_y = player_pos.x, player_pos.x, player_pos.y, player_pos.y
    for _, d in ipairs(doors) do
        min_x, max_x = math.min(min_x, d.pos.x), math.max(max_x, d.pos.x)
        min_y, max_y = math.min(min_y, d.pos.y), math.max(max_y, d.pos.y)
    end
    local side = math.max(max_x - min_x, max_y - min_y, MIN_AREA_CM - 2 * MARGIN_CM) + 2 * MARGIN_CM
    local px = math.max(MIN_PX, math.min(MAX_PX, math.ceil(side / CM_PER_PX)))
    return { x = (min_x + max_x) / 2, y = (min_y + max_y) / 2 }, side, px
end

-- Pixel (u, v) <-> world for a capture centred on centre: picture up = +X,
-- picture right = +Y (camera pitch -90, yaw 0; checked in game).
function floorplan.anchors(centre, side, px)
    local half, k = side / 2, side / px
    local function anchor(u, v) return { world = { centre.x + half - v * k, centre.y - half + u * k }, px = { u, v } } end
    return { anchor(0, 0), anchor(px, 0), anchor(0, px) }
end

local function read_captures()
    local text = bridge.read_file(CAPTURES)
    local ok, list = pcall(json.decode, text or "[]")
    return ok and type(list) == "table" and list or {}
end

-- Records a capture, replacing an older one of the same level and floor.
local function remember(entry)
    local list = {}
    for _, old in ipairs(read_captures()) do
        if not (old.level == entry.level and math.abs((old.floor_z or 0) - entry.floor_z) < SAME_FLOOR_CM) then
            list[#list + 1] = old
        end
    end
    list[#list + 1] = entry
    bridge.write_file(CAPTURES, json.encode(list))
end

local function file_name(level, floor_z)
    return string.format("capture_%s_z%d.png", (level or "level"):gsub("[^%w_%-]", "_"), math.floor(floor_z + 0.5))
end

function floorplan.capture()
    local pc = game.player_controller()
    local player = game.player()
    local pawn = game.player_pawn()
    local level = game.level_name()
    if not pc or not player or not player.pos or not valid(pawn) or not level then
        note("no player yet, start a mission first")
        return
    end
    local find = StaticFindObject or function() return nil end
    local world_ok, world = pcall(function() return pc:GetWorld() end)
    local rendering = find("/Script/Engine.Default__KismetRenderingLibrary")
    local component_class = find("/Script/Engine.SceneCaptureComponent2D")
    if not (world_ok and valid(world) and valid(rendering) and valid(component_class) and StaticConstructObject) then
        note("engine objects not found (world / KismetRenderingLibrary / SceneCaptureComponent2D / StaticConstructObject)")
        return
    end

    local centre, side, px = floorplan.area(game.doors(level), player.pos)
    local ok, rt = try_call(rendering, "CreateRenderTarget2D",
        { world, px, px, 3, { R = 0, G = 0, B = 0, A = 1 }, false, false },
        { world, px, px, 3, { R = 0, G = 0, B = 0, A = 1 }, false },
        { world, px, px, 3 })
    if not ok or not valid(rt) then
        note("could not create the picture: " .. tostring(rt))
        return
    end
    local made, comp = pcall(StaticConstructObject, component_class, pawn)
    if not made or not valid(comp) then
        note("could not create the camera: " .. tostring(comp))
        return
    end

    local cut = player.pos.z + CUT_ABOVE_PLAYER
    local loc = { X = centre.x, Y = centre.y, Z = cut }
    local rot = { Pitch = -90, Yaw = 0, Roll = 0 }
    try_call(comp, "K2_SetWorldLocationAndRotation", { loc, rot, false, {}, false }, { loc, rot, false, false })
    set(comp, "TextureTarget", rt)
    set(comp, "bCaptureEveryFrame", false)
    set(comp, "bCaptureOnMovement", false)
    set(comp, "ProjectionType", 1)                 -- orthographic
    set(comp, "OrthoWidth", side)
    set(comp, "CaptureSource", 7)                  -- SCS_BaseColor
    set(comp, "bAutoCalculateOrthoPlanes", false)  -- near plane at the camera: nothing above it
    set(comp, "OrthoNearClipPlane", 0)
    set(comp, "OrthoFarClipPlane", 100000)
    local captured, err = pcall(function() comp:CaptureScene() end)
    if not captured then
        note("capture failed: " .. tostring(err))
        return
    end

    local floor_z = player.pos.z - FEET_BELOW_PLAYER
    local file = file_name(level, floor_z)
    if not try_call(rendering, "ExportRenderTarget", { world, rt, bridge.dir, file }) then
        note("could not save " .. file)
        return
    end
    remember({
        file = file, level = level, floor_z = floor_z, cut_z = cut, time = os.time(),
        area_cm = side, size_px = px, centre = centre, anchors = floorplan.anchors(centre, side, px),
    })
    note(string.format("saved %s (%.0f m across, %d px). Use it in the companion: Calibrate > In-game captures",
        file, side / 100, px))
    walls.start({ file = file, level = level, centre = centre, side = side, floor_z = floor_z, player_pos = player.pos })
end

return floorplan
