-- Traces a floor's walls with the game's collision, for the floor capture
-- (floorplan.lua). Walls are often hollow meshes that a top-down picture cut
-- above the floor can't show, but they still block line traces.
--
-- Rows of horizontal rays sweep the whole capture area (along +X, then
-- along +Y), every STEP_CM. Each ray runs until it hits something, the hit
-- is recorded, and the ray carries on past it. The rays run just below the
-- ceiling, over furniture and people; a hit only counts as wall if a second,
-- short ray at chest height is blocked at the same spot, so doorways and
-- archways (open at chest height, wall above) stay open.
--
-- The work runs a slice at a time on its own loop, so the game doesn't
-- freeze. Hits on neighbouring rows are joined into wall segments, written
-- to <capture>.walls.json in the bridge folder.

local bridge = require("bridge")
local game = require("game")
local json = require("json")
local log = require("log")

local walls = {}

local STEP_CM = 15               -- distance between rays
local CEILING_GAP_CM = 25        -- trace this far below the ceiling...
local MAX_TRACE_ABOVE_FLOOR = 240 -- ...but no higher than this above the floor
local MIN_TRACE_ABOVE_FLOOR = 170
local OPEN_AIR_TRACE_ABOVE_FLOOR = 240 -- no ceiling above the player (outdoors)
local CHECK_ABOVE_FLOOR = 120    -- the chest-height check ray
local CHECK_BEFORE_CM, CHECK_AFTER_CM = 30, 15
local STEP_INTO_WALL_CM = 10     -- how far to move on when a ray starts inside something
local MAX_HITS_PER_ROW = 400
local TRACES_PER_SLICE = 250
local SLICE_MS = 15
local JOIN_CM = 2 * STEP_CM      -- hits this close on neighbouring rows belong to one wall
local STRAIGHT_CM = 5            -- points this close to a line are merged into one segment

local job = nil                  -- the running trace, or nil

local function note(line) log.info("wall trace: " .. line) end

local function vec(x, y, z) return { X = x, Y = y, Z = z } end

-- One line trace (visibility channel, simple collision, ignoring the player).
-- Returns hit point {x, y, z} and distance, or nil.
local function trace(ctx, from, to)
    ctx.traces = ctx.traces + 1
    local hit = {}
    local ok, blocked = pcall(function()
        return ctx.system:LineTraceSingle(ctx.pawn, from, to, 0, false, {}, 0, hit, true,
            { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0.0)
    end)
    if not ok then
        ctx.errors = ctx.errors + 1
        if ctx.errors == 1 then note("LineTraceSingle failed: " .. tostring(blocked)) end
        return nil
    end
    if not blocked then return nil end
    local got, x, y, z, dist = pcall(function()
        return hit.Location.X, hit.Location.Y, hit.Location.Z, hit.Distance
    end)
    if not got or type(x) ~= "number" then return nil end
    return { x = x, y = y, z = z }, (type(dist) == "number" and dist or 0)
end

-- How high to trace: just below the ceiling above the player.
function walls.trace_height(ctx, player_pos, floor_z)
    local hit = trace(ctx, vec(player_pos.x, player_pos.y, player_pos.z), vec(player_pos.x, player_pos.y, floor_z + 1000))
    local above = hit and (hit.z - CEILING_GAP_CM - floor_z) or OPEN_AIR_TRACE_ABOVE_FLOOR
    return floor_z + math.max(MIN_TRACE_ABOVE_FLOOR, math.min(MAX_TRACE_ABOVE_FLOOR, above))
end

-- Sweeps one row: along +X at y (axis "x") or along +Y at x (axis "y").
-- Returns the positions along the row where a wall was found.
local function sweep_row(ctx, axis, across, from, to)
    local found = {}
    local at = from
    local function point(along, z)
        if axis == "x" then return vec(along, across, z) end
        return vec(across, along, z)
    end
    for _ = 1, MAX_HITS_PER_ROW do
        if at >= to then break end
        local hit, dist = trace(ctx, point(at, ctx.trace_z), point(to, ctx.trace_z))
        if not hit then break end
        local along = axis == "x" and hit.x or hit.y
        if dist < 1 then
            at = at + STEP_INTO_WALL_CM          -- started inside something
        else
            if trace(ctx, point(along - CHECK_BEFORE_CM, ctx.check_z), point(along + CHECK_AFTER_CM, ctx.check_z)) then
                found[#found + 1] = along
            end
            at = along + STEP_INTO_WALL_CM
        end
        coroutine.yield()
    end
    return found
end

-- Joins hits on neighbouring rows into polylines, then into straight segments.
function walls.segments(rows, axis)
    local open, done = {}, {}
    for i, row in ipairs(rows) do
        local next_open = {}
        for _, along in ipairs(row.hits) do
            local best, best_d = nil, JOIN_CM
            for k, line in ipairs(open) do
                local d = math.abs(line.last - along)
                if not line.used and d <= best_d then best, best_d = k, d end
            end
            local line
            if best then
                line = open[best]
                line.used = true
            else
                line = { points = {} }
            end
            line.last = along
            line.points[#line.points + 1] = axis == "x" and { along, row.across } or { row.across, along }
            next_open[#next_open + 1] = line
        end
        for _, line in ipairs(open) do
            if not line.used then done[#done + 1] = line.points end
        end
        for _, line in ipairs(next_open) do line.used = false end
        open = next_open
        if i == #rows then
            for _, line in ipairs(open) do done[#done + 1] = line.points end
        end
    end
    -- Straight runs become one segment; a single hit becomes a short one.
    local out = {}
    for _, pts in ipairs(done) do
        if #pts == 1 then
            local p = pts[1]
            if axis == "x" then
                out[#out + 1] = { p[1], p[2] - STEP_CM / 2, p[1], p[2] + STEP_CM / 2 }
            else
                out[#out + 1] = { p[1] - STEP_CM / 2, p[2], p[1] + STEP_CM / 2, p[2] }
            end
        else
            local start = 1
            for k = 3, #pts + 1 do
                local a, b = pts[start], pts[k - 1]
                local straight = k <= #pts
                if straight then
                    local c = pts[k]
                    local dx, dy = c[1] - a[1], c[2] - a[2]
                    local len = math.sqrt(dx * dx + dy * dy)
                    local off = len > 0 and math.abs(dx * (b[2] - a[2]) - dy * (b[1] - a[1])) / len or 0
                    straight = off <= STRAIGHT_CM
                end
                if not straight then
                    out[#out + 1] = { a[1], a[2], b[1], b[2] }
                    start = k - 1
                end
            end
        end
    end
    return out
end

local function round(v) return math.floor(v + 0.5) end

local function run(ctx)
    local half = ctx.side / 2
    local min_x, min_y = ctx.centre.x - half, ctx.centre.y - half
    local rows_total = 2 * math.floor(ctx.side / STEP_CM)
    local segments = {}
    for _, axis in ipairs({ "x", "y" }) do
        local rows = {}
        for i = 0, math.floor(ctx.side / STEP_CM) - 1 do
            local across = (axis == "x" and min_y or min_x) + (i + 0.5) * STEP_CM
            local from = axis == "x" and min_x or min_y
            rows[#rows + 1] = { across = across, hits = sweep_row(ctx, axis, across, from, from + ctx.side) }
            ctx.rows_done = ctx.rows_done + 1
            ctx.percent = math.floor(100 * ctx.rows_done / rows_total)
            coroutine.yield()
        end
        for _, s in ipairs(walls.segments(rows, axis)) do
            segments[#segments + 1] = { round(s[1]), round(s[2]), round(s[3]), round(s[4]) }
        end
    end
    return segments
end

local function finish(ctx, segments)
    local seconds = os.time() - ctx.started
    bridge.write_file(ctx.out_file, json.encode({
        file = ctx.file, level = ctx.level, floor_z = ctx.floor_z, trace_z = ctx.trace_z, check_z = ctx.check_z,
        step_cm = STEP_CM, traces = ctx.traces, seconds = seconds, walls = segments,
    }))
    note(string.format("%d wall segments from %d traces in %d s, saved %s%s", #segments, ctx.traces, seconds,
        ctx.out_file, ctx.errors > 0 and string.format(" (%d traces failed)", ctx.errors) or ""))
end

-- Starts tracing the floor of a capture. opts: file, level, centre, side,
-- floor_z, player_pos. Returns false if a trace is already running.
function walls.start(opts)
    if job then
        note("still tracing the previous floor")
        return false
    end
    local system = StaticFindObject and StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pawn = game.player_pawn()
    if not game.valid(system) or not game.valid(pawn) then
        note("KismetSystemLibrary or player not found")
        return false
    end
    local ctx = {
        system = system, pawn = pawn, traces = 0, errors = 0, rows_done = 0, percent = 0, started = os.time(),
        file = opts.file, level = opts.level, centre = opts.centre, side = opts.side, floor_z = opts.floor_z,
        out_file = opts.file:gsub("%.png$", "") .. ".walls.json",
    }
    ctx.trace_z = walls.trace_height(ctx, opts.player_pos, opts.floor_z)
    ctx.check_z = opts.floor_z + CHECK_ABOVE_FLOOR
    note(string.format("tracing walls %.0f cm above the floor (check at %d cm)...", ctx.trace_z - opts.floor_z,
        CHECK_ABOVE_FLOOR))
    local co = coroutine.create(function() return run(ctx) end)
    job = { ctx = ctx, co = co, last_note = 0 }

    local function slice()
        if not job then return end
        local budget = ctx.traces + TRACES_PER_SLICE
        while ctx.traces < budget do
            local ok, segments = coroutine.resume(co)
            if not ok then
                note("stopped: " .. tostring(segments))
                job = nil
                return
            end
            if coroutine.status(co) == "dead" then
                finish(ctx, segments)
                job = nil
                return
            end
        end
        if ctx.percent >= job.last_note + 25 then
            job.last_note = ctx.percent - ctx.percent % 25
            note(ctx.percent .. "%")
        end
    end
    LoopAsync(SLICE_MS, function()
        ExecuteInGameThread(slice)
        return job == nil -- stop looping once done
    end)
    return true
end

-- { file, percent } while a trace runs, else nil (for state.json).
function walls.progress()
    if not job then return nil end
    return { file = job.ctx.file, percent = job.ctx.percent }
end

return walls
