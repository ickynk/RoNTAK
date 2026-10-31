-- Floor plan capture TEST (config.keys.floorplan_test, F11).
--
-- Renders true top-down (orthographic: no perspective, the same scale
-- everywhere) pictures of the area around the player and saves them as PNG
-- in the bridge folder, with floorplan_test.json describing the area covered
-- (pixel <-> world) and what happened. It freezes the game for a moment.
--
-- Round 3 showed that a capture component built with StaticConstructObject
-- renders (pixels read back in game), but in base colour every pixel is saved
-- with alpha 0: viewers show that as white. Final colour is saved opaque.
-- This round (all orthographic, camera straight down):
--   A  final colour, near plane at the cut height (camera at the cut)
--   B  final colour, clip plane at the cut height (camera high up)
--   C  final colour, nothing cut
--   G  base colour, added onto a target cleared to alpha 1 (additive
--      composite): does that make the plain base colour picture opaque?
-- A few pixels of each picture are read back in game and logged.

local bridge = require("bridge")
local game = require("game")
local json = require("json")
local log = require("log")

local floorplan = {}

local SIZE_PX = 2048            -- picture width and height
local AREA_CM = 6000            -- 60 m x 60 m around the player
local CUT_ABOVE_PLAYER = 80     -- the pawn's position is ~90 cm above its feet: cut ~1.7 m up
local HIGH_ABOVE_CUT = 5000     -- camera height when nothing is cut

local valid = game.valid
local report = {}

local function note(line)
    report[#report + 1] = line
    log.info("floorplan: " .. line)
end

-- Tries each argument list in turn (engine versions differ in trailing
-- parameters). Returns ok, result.
local function try_call(obj, fn, ...)
    local last_err
    for _, args in ipairs({ ... }) do
        local ok, result = pcall(function() return obj[fn](obj, table.unpack(args)) end)
        if ok then return true, result end
        last_err = result
    end
    return false, last_err
end

local function get(obj, prop)
    local ok, value = pcall(function() return obj[prop] end)
    if ok then return value end
    return nil
end

local function set(obj, prop, value)
    local ok, err = pcall(function() obj[prop] = value end)
    if not ok then note(string.format("set %s FAILED: %s", prop, tostring(err))) end
    return ok
end

local function describe(value)
    if type(value) ~= "userdata" then return type(value) .. " " .. tostring(value) end
    if not valid(value) then return "invalid object" end
    return "object " .. game.object_name(value)
end

local function transform_of(comp)
    local ok_l, loc = pcall(function() return comp:K2_GetComponentLocation() end)
    local ok_r, rot = pcall(function() return comp:K2_GetComponentRotation() end)
    if not (ok_l and loc and ok_r and rot) then return nil end
    return { loc = { X = loc.X, Y = loc.Y, Z = loc.Z }, rot = { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll } }
end

local function place(comp, loc, rot)
    try_call(comp, "K2_SetWorldLocationAndRotation", { loc, rot, false, {}, false }, { loc, rot, false, false })
    local t = transform_of(comp)
    return t and string.format("at %.0f %.0f %.0f, pitch %.0f yaw %.0f roll %.0f",
        t.loc.X, t.loc.Y, t.loc.Z, t.rot.Pitch, t.rot.Yaw, t.rot.Roll or 0) or "position unknown"
end

-- Reads pixels back from the render target: "N/9 drawn, e.g. R G B A".
local function sample(rendering, world, rt)
    local drawn, example = 0, nil
    for _, fx in ipairs({ 0.25, 0.5, 0.75 }) do
        for _, fy in ipairs({ 0.25, 0.5, 0.75 }) do
            local ok, c = pcall(function()
                return rendering:ReadRenderTargetPixel(world, rt, math.floor(SIZE_PX * fx), math.floor(SIZE_PX * fy))
            end)
            if not ok or type(c) == "nil" then return "pixels unreadable: " .. tostring(c) end
            local r, g, b, a = get(c, "R") or 0, get(c, "G") or 0, get(c, "B") or 0, get(c, "A") or 0
            if r + g + b > 0 then
                drawn = drawn + 1
                example = example or string.format("%d %d %d %d", r, g, b, a)
            end
        end
    end
    return string.format("%d/9 sample pixels drawn%s", drawn, example and (", e.g. RGBA " .. example) or "")
end

local function capture(name, comp, ctx, opts)
    local where = place(comp, opts.loc, { Pitch = -90, Yaw = 0, Roll = 0 })
    set(comp, "TextureTarget", ctx.rt)
    set(comp, "bCaptureEveryFrame", false)
    set(comp, "bCaptureOnMovement", false)
    set(comp, "ProjectionType", 1)              -- ECameraProjectionMode::Orthographic
    set(comp, "OrthoWidth", AREA_CM)
    set(comp, "CaptureSource", opts.base_colour and 7 or 2)  -- SCS_BaseColor / SCS_FinalColorLDR
    set(comp, "CompositeMode", opts.additive and 1 or 0)     -- ESceneCaptureCompositeMode: Additive / Overwrite
    set(comp, "bEnableClipPlane", opts.clip ~= nil)
    if opts.clip then
        set(comp, "ClipPlaneBase", { X = opts.loc.X, Y = opts.loc.Y, Z = opts.clip })
        set(comp, "ClipPlaneNormal", { X = 0, Y = 0, Z = -1 })
    end
    if opts.near_plane then
        set(comp, "bAutoCalculateOrthoPlanes", false)
        set(comp, "OrthoNearClipPlane", 0)
        set(comp, "OrthoFarClipPlane", 100000)
    end
    local clear_alpha = opts.additive and 1 or 0
    pcall(function() ctx.rendering:ClearRenderTarget2D(ctx.world, ctx.rt, { R = 0, G = 0, B = 0, A = clear_alpha }) end)
    local ok, err = pcall(function() comp:CaptureScene() end)
    if not ok then
        note(name .. ": CaptureScene FAILED: " .. tostring(err))
        return
    end
    local pixels = sample(ctx.rendering, ctx.world, ctx.rt)
    local file = "floorplan_test_" .. name .. ".png"
    local exported = try_call(ctx.rendering, "ExportRenderTarget", { ctx.world, ctx.rt, bridge.dir, file })
    note(string.format("%s: camera %s; %s; %s", name, where, pixels, exported and ("saved " .. file) or "export FAILED"))
end

function floorplan.test()
    report = {}
    local pc = game.player_controller()
    local player = game.player()
    local pawn = game.player_pawn()
    if not pc or not player or not player.pos or not valid(pawn) then
        log.info("floorplan: no player yet, start a mission first")
        return
    end
    local world_ok, world = pcall(function() return pc:GetWorld() end)
    local find = StaticFindObject or function() return nil end
    local rendering = find("/Script/Engine.Default__KismetRenderingLibrary")
    if not (world_ok and valid(world) and valid(rendering)) then
        note("engine objects not found (world / KismetRenderingLibrary)")
        return
    end
    local ok, rt = try_call(rendering, "CreateRenderTarget2D",
        { world, SIZE_PX, SIZE_PX, 3, { R = 0, G = 0, B = 0, A = 1 }, false, false },
        { world, SIZE_PX, SIZE_PX, 3, { R = 0, G = 0, B = 0, A = 1 }, false },
        { world, SIZE_PX, SIZE_PX, 3 })
    if not ok or not valid(rt) then
        note("CreateRenderTarget2D FAILED: " .. describe(rt))
        return
    end
    local ctx = { world = world, rendering = rendering, rt = rt }

    local center = player.pos
    local cut = center.z + CUT_ABOVE_PLAYER
    local low = { X = center.x, Y = center.y, Z = cut }
    local high = { X = center.x, Y = center.y, Z = cut + HIGH_ABOVE_CUT }

    local component_class = find("/Script/Engine.SceneCaptureComponent2D")
    if StaticConstructObject and valid(component_class) then
        local made_ok, comp = pcall(StaticConstructObject, component_class, pawn)
        if made_ok and valid(comp) then
            for _, run in ipairs({
                { name = "A", opts = { loc = low, near_plane = true } },
                { name = "B", opts = { loc = high, clip = cut } },
                { name = "C", opts = { loc = high } },
                { name = "G", opts = { loc = high, base_colour = true, additive = true } },
            }) do
                local run_ok, err = pcall(capture, run.name, comp, ctx, run.opts)
                if not run_ok then note(run.name .. ": " .. tostring(err)) end
            end
        else
            note("StaticConstructObject FAILED: " .. describe(comp))
        end
    else
        note("StaticConstructObject / SceneCaptureComponent2D not available")
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
