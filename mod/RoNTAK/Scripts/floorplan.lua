-- Floor plan capture TEST (config.keys.floorplan_test, F11).
--
-- Renders a true top-down (orthographic: no perspective, the same scale
-- everywhere) picture of the area around the player with a temporary
-- SceneCapture2D, in base colour (no lighting), and saves it as PNG in the
-- bridge folder. To find out how this game lets us cut away roofs and the
-- floors above, it saves three versions:
--   A  camera at the cut height, nothing behind (above) it drawn (ortho near plane)
--   B  camera high up, with a clip plane at the cut height
--   C  camera high up, nothing cut (for comparison)
-- floorplan_test.json records the area covered (pixel <-> world) and which
-- steps worked. Run it once; it freezes the game for a moment.
--
-- The camera is a SceneCaptureComponent2D built with StaticConstructObject
-- (no actor, no hooks). If that is not available, it falls back to spawning
-- a SceneCapture2D actor; that needs a hook to pass the class, and the hook
-- is then left installed: removing a hook from a native engine function
-- leaves UE4SS without the original function ("no function map entry").

local bridge = require("bridge")
local game = require("game")
local json = require("json")
local log = require("log")

local floorplan = {}

local SIZE_PX = 2048            -- picture width and height
local AREA_CM = 6000            -- 60 m x 60 m around the player
local CUT_ABOVE_PLAYER = 80     -- the pawn's position is ~90 cm above its feet: cut ~1.7 m up
local HIGH_ABOVE_CUT = 5000     -- camera height for B and C
local SPAWN_PATH = "/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass"

local valid = game.valid
local report = {}

local function note(line)
    report[#report + 1] = line
    log.info("floorplan: " .. line)
end

-- Tries each argument list in turn (engine versions differ in trailing
-- parameters). Returns ok, result, and which attempt worked.
local function try_call(obj, fn, ...)
    local last_err
    for i, args in ipairs({ ... }) do
        local ok, result = pcall(function() return obj[fn](obj, table.unpack(args)) end)
        if ok then return true, result, i end
        last_err = result
    end
    return false, last_err
end

local function set(obj, prop, value)
    local ok, err = pcall(function() obj[prop] = value end)
    if not ok then note(string.format("set %s FAILED: %s", prop, tostring(err))) end
    return ok
end

local function null_object()
    if CreateInvalidObject then return CreateInvalidObject() end
    local ok, obj = pcall(FindFirstOf, "RoNTAK_NoSuchClass")
    return ok and obj or nil
end

-- Lua calls don't fill in class (TSubclassOf) arguments in this game (the same
-- problem as item classes in orders), so a pre-hook writes the class while
-- our own spawn call is running.
local spawn_class = nil
local hook_ids = nil

local function install_spawn_hook()
    if hook_ids or not RegisterHook then return end
    local ok, pre, post = pcall(RegisterHook, SPAWN_PATH, function(_, _, class_param)
        if spawn_class and class_param then pcall(function() class_param:set(spawn_class) end) end
    end)
    if ok then hook_ids = { pre, post } else note("spawn hook FAILED: " .. tostring(pre)) end
end

-- What a call returned, for the report: "UObject Name", "function", "nil"...
local function describe(value)
    if type(value) ~= "userdata" then return type(value) .. " " .. tostring(value) end
    if not valid(value) then return "invalid object" end
    return "object " .. game.object_name(value)
end

-- Pitch -90 (looking straight down), yaw 0: picture up = world +X, picture right = world +Y.
local DOWN = { X = 0, Y = 0.70710678, Z = 0, W = 0.70710678 }

local function spawn_camera(world, statics, class, pos)
    local transform = { Rotation = DOWN, Translation = { X = pos.x, Y = pos.y, Z = pos.z },
                        Scale3D = { X = 1, Y = 1, Z = 1 } }
    spawn_class = class
    local ok, actor = try_call(statics, "BeginDeferredActorSpawnFromClass",
        { world, class, transform, 1, null_object(), 1 },
        { world, class, transform, 1, null_object() })
    spawn_class = nil
    if not ok or not valid(actor) then
        note(string.format("spawn FAILED (%s): %s", ok and "returned" or "error", describe(actor)))
        return nil
    end
    if not try_call(statics, "FinishSpawningActor", { actor, transform, 1 }, { actor, transform }) then
        note("FinishSpawningActor FAILED")
    end
    pcall(function() actor:K2_SetActorRotation({ Pitch = -90, Yaw = 0, Roll = 0 }, false) end)
    return actor
end

-- Method 1: a bare capture component, owned by the player pawn, placed by
-- setting its world transform. Returns the component, or nil.
local function construct_camera(component_class, outer, pos)
    if not StaticConstructObject then
        note("StaticConstructObject not available")
        return nil
    end
    local ok, comp = pcall(StaticConstructObject, component_class, outer)
    if not ok or not valid(comp) then
        note(string.format("StaticConstructObject FAILED (%s): %s", ok and "returned" or "error", describe(comp)))
        return nil
    end
    local loc, rot = { X = pos.x, Y = pos.y, Z = pos.z }, { Pitch = -90, Yaw = 0, Roll = 0 }
    local placed = try_call(comp, "K2_SetWorldLocationAndRotation",
        { loc, rot, false, {}, false }, { loc, rot, false, false })
    local got_ok, got = pcall(function() return comp:K2_GetComponentLocation() end)
    note(string.format("component placed: %s, now at %s", tostring(placed),
        got_ok and got and string.format("%.0f %.0f %.0f", got.X, got.Y, got.Z) or "?"))
    return comp
end

local function capture_one(name, world, statics, rendering, classes, rt, center, cut, slice, method)
    local z = slice == "A" and cut or cut + HIGH_ABOVE_CUT
    local pos = { x = center.x, y = center.y, z = z }
    local actor, comp
    if method == "construct" then
        comp = construct_camera(classes.component, classes.outer, pos)
        if not comp then return false, "no camera" end
    else
        actor = spawn_camera(world, statics, classes.actor, pos)
        if not actor then return false, "no camera" end
        comp = game.read_raw(actor, "CaptureComponent2D")
        if not valid(comp) then
            note(name .. ": no CaptureComponent2D")
            pcall(function() actor:K2_DestroyActor() end)
            return false
        end
    end
    set(comp, "ProjectionType", 1)          -- ECameraProjectionMode::Orthographic
    set(comp, "OrthoWidth", AREA_CM)
    set(comp, "CaptureSource", 7)           -- ESceneCaptureSource::SCS_BaseColor
    set(comp, "bCaptureEveryFrame", false)
    set(comp, "bCaptureOnMovement", false)
    set(comp, "TextureTarget", rt)
    if slice == "A" then
        set(comp, "bAutoCalculateOrthoPlanes", false)
        set(comp, "OrthoNearClipPlane", 0)
        set(comp, "OrthoFarClipPlane", 100000)
    elseif slice == "B" then
        set(comp, "bEnableClipPlane", true)
        set(comp, "ClipPlaneBase", { X = center.x, Y = center.y, Z = cut })
        set(comp, "ClipPlaneNormal", { X = 0, Y = 0, Z = -1 })
    end
    local ok, err = pcall(function() comp:CaptureScene() end)
    if not ok then note(name .. ": CaptureScene FAILED: " .. tostring(err)) end
    local file = "floorplan_test_" .. name .. ".png"
    local exported = ok and try_call(rendering, "ExportRenderTarget", { world, rt, bridge.dir, file })
    note(string.format("%s (%s): %s", name, method, exported and ("saved " .. file) or "export FAILED"))
    if actor then pcall(function() actor:K2_DestroyActor() end) end
    return exported
end

function floorplan.test()
    report = {}
    local pc = game.player_controller()
    local player = game.player()
    if not pc or not player or not player.pos then
        log.info("floorplan: no player yet, start a mission first")
        return
    end
    local world_ok, world = pcall(function() return pc:GetWorld() end)
    local find = StaticFindObject or function() return nil end
    local classes = {
        component = find("/Script/Engine.SceneCaptureComponent2D"),
        actor = find("/Script/Engine.SceneCapture2D"),
        outer = game.player_pawn(),
    }
    local statics = find("/Script/Engine.Default__GameplayStatics")
    local rendering = find("/Script/Engine.Default__KismetRenderingLibrary")
    if not (world_ok and valid(world) and valid(rendering)) then
        note("engine objects not found (world / KismetRenderingLibrary)")
        return
    end
    local method
    if StaticConstructObject and valid(classes.component) and valid(classes.outer) then
        method = "construct"
    elseif valid(classes.actor) and valid(statics) then
        method = "spawn"
    else
        note("no way to make a capture camera (StaticConstructObject / SceneCapture2D not found)")
        return
    end

    local ok, rt = try_call(rendering, "CreateRenderTarget2D",
        { world, SIZE_PX, SIZE_PX, 3, { R = 0, G = 0, B = 0, A = 1 }, false, false },
        { world, SIZE_PX, SIZE_PX, 3, { R = 0, G = 0, B = 0, A = 1 }, false },
        { world, SIZE_PX, SIZE_PX, 3 })
    if not ok or not valid(rt) then
        note("CreateRenderTarget2D FAILED: " .. tostring(rt))
        return
    end

    local center = player.pos
    local cut = center.z + CUT_ABOVE_PLAYER
    if method == "spawn" then install_spawn_hook() end -- left installed, see the top of this file
    for _, name in ipairs({ "A", "B", "C" }) do
        local done, result, why = pcall(capture_one, name, world, statics, rendering, classes, rt, center, cut, name, method)
        if not done then note(name .. ": " .. tostring(result)) end
        -- The camera could not be made this way: try the other one.
        if done and why == "no camera" and method == "construct" and valid(classes.actor) and valid(statics) then
            note("falling back to spawning a SceneCapture2D actor")
            method = "spawn"
            install_spawn_hook()
            done, result = pcall(capture_one, name, world, statics, rendering, classes, rt, center, cut, name, method)
            if not done then note(name .. ": " .. tostring(result)) end
        end
    end

    -- Pixel (u, v) <-> world: u runs along +Y, v along -X, AREA_CM across SIZE_PX.
    local half, k = AREA_CM / 2, AREA_CM / SIZE_PX
    local function anchor(u, v) return { world = { center.x + half - v * k, center.y - half + u * k }, px = { u, v } } end
    bridge.write_file("floorplan_test.json", json.encode({
        level = game.level_name(), center = center, cut_z = cut, area_cm = AREA_CM, size_px = SIZE_PX,
        anchors = { anchor(0, 0), anchor(SIZE_PX, 0), anchor(0, SIZE_PX) },
        report = report,
    }))
    log.info("floorplan: done, see floorplan_test.json in " .. bridge.dir)
end

floorplan.SIZE_PX, floorplan.AREA_CM = SIZE_PX, AREA_CM

return floorplan
