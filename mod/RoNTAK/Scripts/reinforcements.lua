-- Reinforcements: extra SWAT teams called in during a mission (stage 2).
--
-- Requesting a team (RoNTAK button or config.keys.request_<team>) sets up its
-- operators one per tick, each completely in that tick (see STEPS), so the
-- game never runs a half-built operator:
--   1. a free spot at the mission's entry point (where the squad stood when
--      the mission began), else near the player on the AI navigation mesh;
--   2. a deferred spawn of a stock officer's class there (RoNTAKNative): the
--      squad slot, team and look are set before the game finishes building
--      it, then an AI controller;
--   3. a copy of that officer's gear (each item spawned and added, the gear
--      record pointed at the copies, the primary weapon put in hand);
--   4. the game's own OnAIFinishSpawning, the look refreshed, and the
--      operator added to the squad manager's SwatAI list, so squad orders
--      reach it.
-- A step that fails removes what was spawned for that operator.
--
-- Needs RoNTAKNative 0.2 or newer: on UE4SS 3.0.1, Lua's World:SpawnActor
-- returns a broken object on this game, and a Lua write one past the end of
-- an array doesn't grow it but writes past it into game memory (the cause of
-- the crashes in stage 1). The native mod spawns through the game's own
-- GameplayStatics functions and grows arrays with the engine's allocator.
--
-- Called-in operators are known by name (members below, and the officer
-- override in game.lua gives RoNTAK their team and call sign). In-game
-- orders follow DefaultTeam (RED / BLUE / GOLD only), so until the teams can
-- be commanded on their own each joins the stock team set in config.
--
-- The way to spawn and equip an operator follows what the Extra SWAT Teams
-- mod showed works in this game; this is RoNTAK's own implementation.

local config = require("config")
local game = require("game")
local log = require("log")
local squads = require("squads")

local reinforcements = {}

local valid, object_name = game.valid, game.object_name
local STOCK_SLOTS = { [0] = true, [1] = true, [2] = true, [3] = true }

local queue = {}        -- operators still to set up: { team, index, call_sign, kit, ... }
local members = {}      -- called-in operators: actor name -> { team, call_sign }
local results = {}      -- per request: result table shown in RoNTAK's order list

local function c() return config.reinforcements or {} end
local function note(line) log.info("reinforcements: " .. line) end

local function ready(o)
    return valid(o) and valid(o.InventoryComp) and game.call_bool(o, "IsDeadOrUnconscious") ~= true
end

local function slot_of(o)
    local ok, v = pcall(function() return o.SquadPosition end)
    return ok and v or nil
end

-- Stock officers (not called in), by squad slot.
local function stock_by_slot()
    local out = {}
    for _, o in ipairs(game.officer_actors()) do
        local s = slot_of(o.actor)
        if STOCK_SLOTS[s] and not members[o.name] and ready(o.actor) then out[s] = o.actor end
    end
    return out
end

-- Is a team's operator with this call sign alive?
local function on_scene(team, call_sign)
    for _, o in ipairs(game.officer_actors()) do
        local m = members[o.name]
        if m and m.team == team and m.call_sign == call_sign and ready(o.actor) then return true end
    end
    return false
end

-- Where the squad stood when the mission began (the entry point), per level.
local entry = { level = nil, spots = nil }

-- Remembers the stock officers' first positions in a level.
local function record_entry()
    local level = game.level_name()
    if entry.level ~= level then entry = { level = level, spots = nil } end
    if entry.spots or not level then return end
    local spots = {}
    for _, o in ipairs(game.officer_actors()) do
        if STOCK_SLOTS[slot_of(o.actor)] and not members[o.name] and o.pos then spots[#spots + 1] = o.pos end
    end
    if #spots > 0 then
        entry.spots = spots
        note(string.format("entry point recorded (%d positions)", #spots))
    end
end

-- Projects a point onto the AI navigation mesh: the point on the floor, or nil.
local function on_nav(nav, world_ctx, x, y, z)
    if not valid(nav) then return nil end
    local projected = {}
    local ok, hit = pcall(function()
        return nav:K2_ProjectPointToNavigation(world_ctx, { X = x, Y = y, Z = z }, projected, nil, nil, { X = 100, Y = 100, Z = 200 })
    end)
    if ok and hit and type(projected.X) == "number" then return { x = projected.X, y = projected.Y, z = projected.Z } end
    return nil
end

-- Without the navigation check: a spot is fine if nothing blocks the way
-- from the centre (a standing officer's centre) and there is floor under it.
-- Returns the floor point, or nil and why ("blocked", "no_floor").
local function traced_spot(system, pawn, centre, x, y)
    if not valid(system) then return nil, "no_floor" end
    local function trace(from, to)
        local hit = {}
        local ok, blocked = pcall(function()
            return system:LineTraceSingle(pawn, from, to, 0, false, {}, 0, hit, true,
                { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0.0)
        end)
        if not ok or not blocked then return nil end
        local got, z = pcall(function() return hit.Location.Z end)
        return got and type(z) == "number" and z or false
    end
    local at = { X = x, Y = y, Z = centre.z }
    if trace({ X = centre.x, Y = centre.y, Z = centre.z }, at) ~= nil then return nil, "blocked" end
    local floor = trace(at, { X = x, Y = y, Z = centre.z - 250 })
    if not floor then return nil, "no_floor" end
    return { x = x, y = y, z = floor }
end

-- A free spot to spawn at: { x, y, z, centre } where centre means z is a
-- standing officer's centre (an entry position), else the floor. Tries the
-- entry positions themselves, then around them, then around the player.
-- Returns nil and the reasons spots were turned down.
local function spawn_spot(pawn, world_ctx, half)
    local nav = StaticFindObject and StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    local system = StaticFindObject and StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local here = game.location(pawn)
    local taken = {}
    for _, o in ipairs(game.officer_actors()) do taken[#taken + 1] = o.pos end
    local rejected = { occupied = 0, off_nav = 0, other_floor = 0, blocked = 0, no_floor = 0 }
    local function free(p)
        -- Officers stood at the entry positions side by side, so those need less room.
        local clearance = p.centre and (c().entry_clearance_cm or 50) or (c().clearance_cm or 90)
        for _, q in ipairs(taken) do
            if q and (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2 < clearance ^ 2 then
                rejected.occupied = rejected.occupied + 1
                return false
            end
        end
        return true
    end
    -- Around a point: the point itself (if it's a known standing spot), then offsets on the nav mesh.
    local function around(centre, offsets, centre_ok)
        for _, off in ipairs(offsets) do
            local spot
            if off[1] == 0 and off[2] == 0 and centre_ok then
                spot = { x = centre.x, y = centre.y, z = centre.z, centre = true }
            else
                spot = on_nav(nav, world_ctx, centre.x + off[1], centre.y + off[2], centre.z)
                if not spot then
                    rejected.off_nav = rejected.off_nav + 1
                    local why
                    spot, why = traced_spot(system, pawn, centre, centre.x + off[1], centre.y + off[2])
                    if not spot then rejected[why] = rejected[why] + 1 end
                end
                if spot and math.abs(spot.z + half - centre.z) > 150 then
                    rejected.other_floor = rejected.other_floor + 1
                    spot = nil
                end
            end
            if spot and free(spot) then return spot end
        end
        return nil
    end
    if c().spawn_at ~= "player" then
        -- Every entry position itself first, then around each of them.
        for _, p in ipairs(entry.spots or {}) do
            local spot = around(p, { { 0, 0 } }, true)
            if spot then return spot end
        end
        for _, p in ipairs(entry.spots or {}) do
            local spot = around(p, c().entry_offsets or {}, false)
            if spot then return spot end
        end
    end
    if here then
        local spot = around(here, c().spawn_offsets or {}, false)
        if spot then return spot end
    end
    return nil, rejected
end

-- The native functions this needs (RoNTAKNative 0.2+), or nil.
local NATIVE_FUNCTIONS = { "RoNTAK_BeginSpawn", "RoNTAK_FinishSpawn", "RoNTAK_AppendObject" }
local function native()
    local out = {}
    for _, name in ipairs(NATIVE_FUNCTIONS) do
        local fn = rawget(_G, name)
        if type(fn) ~= "function" then return nil end
        out[name] = fn
    end
    return out
end
reinforcements.native = native

-- An object's path, which the native functions take ("<Class> <path>" -> path).
local function path_of(obj)
    local ok, full = pcall(function() return obj:GetFullName() end)
    if not ok or type(full) ~= "string" then return nil end
    return full:match("^%S+%s+(.+)$") or full
end

local function find(path)
    if not path or not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, path)
    if ok and valid(obj) then return obj end
    return nil
end

local COLLISION_ALWAYS, COLLISION_ADJUST = 1, 2

-- Starts spawning an actor of class at a spot (deferred: not built yet).
-- Returns the actor, or nil and why.
local function begin_spawn(fns, context, class, at, yaw, collision, owner)
    local ok, path, err = pcall(fns.RoNTAK_BeginSpawn, path_of(context) or "", path_of(class) or "",
        at.X, at.Y, at.Z, yaw or 0, collision, owner and path_of(owner) or "")
    if not ok then return nil, tostring(path) end
    if not path then return nil, tostring(err) end
    local actor = find(path)
    if not actor then return nil, "spawned " .. tostring(path) .. " but could not find it" end
    return actor
end

local function finish_spawn(fns, actor, at, yaw)
    local ok, done, err = pcall(fns.RoNTAK_FinishSpawn, path_of(actor) or "", at.X, at.Y, at.Z, yaw or 0)
    if not ok then return false, tostring(done) end
    if not done then return false, tostring(err) end
    return true
end

-- Appends element to an object array (property may go through structs:
-- "SpawnedGear.Grenades"). Returns the new count (0: was already in it).
local function append(fns, owner, property, element)
    local ok, count, err = pcall(fns.RoNTAK_AppendObject, path_of(owner) or "", property, path_of(element) or "")
    if not ok then return nil, tostring(count) end
    if not count then return nil, tostring(err) end
    return count
end

-- Spawned objects of one operator, removed again if a step fails.
local function discard(made)
    for i = #made, 1, -1 do
        local obj = made[i]
        if valid(obj) then pcall(function() obj:K2_DestroyActor() end) end
    end
end

local function check(ok, what)
    if not ok then error(what, 0) end
end

-- Copies the donor's gear onto the new operator.
local function step_note(job, line)
    if c().log_steps ~= false then note(job.name .. ": " .. line) end
end

-- Setting up one operator. All steps run in the same tick (see
-- reinforcements.tick), and a log line names each one:
--   spawn -> items -> gear -> finish -> register.
local STEPS = {}

-- Copies the donor's appearance onto the operator: the customization
-- choices and the body / face meshes. Done before the spawn is finished, so
-- the game builds the operator with them (a spawned officer has no head
-- otherwise). Returns how many fields were copied and which failed.
local function copy_look(op, donor)
    local copied, failed = 0, {}
    for _, field in ipairs(c().customization_fields or {}) do
        if pcall(function() op.Customization[field] = donor.Customization[field] end) then
            copied = copied + 1
        else
            failed[#failed + 1] = field
        end
    end
    for _, field in ipairs(c().look_fields or {}) do
        if pcall(function() op[field] = donor[field] end) then
            copied = copied + 1
        else
            failed[#failed + 1] = field
        end
    end
    return copied, failed
end

function STEPS.spawn(job)
    local pc = game.player_controller()
    local pawn = game.player_pawn()
    check(pc and valid(pawn), "no player")
    local stock = stock_by_slot()
    local donor = stock[job.kit] or stock[0] or stock[1] or stock[2] or stock[3]
    check(donor, "no ready stock officer to copy")
    local half = 90
    pcall(function() half = donor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    local spot, rejected = spawn_spot(pawn, donor, half)
    if not spot then
        error(string.format("no free spot at the entry point or near you (%s; entry point %s; spots taken %d, off the nav mesh %d, other floor %d, wall in the way %d, no floor %d)",
            entry.spots and "entry known" or "entry not recorded", entry.spots and #entry.spots .. " positions" or "-",
            rejected.occupied, rejected.off_nav, rejected.other_floor, rejected.blocked, rejected.no_floor), 0)
    end
    -- An entry position is a standing officer's centre; a nav-mesh point is the floor.
    local z = spot.centre and spot.z + 10 or spot.z + half + 10
    local at = { X = spot.x, Y = spot.y, Z = z }
    local yaw = 0
    pcall(function() yaw = donor:K2_GetActorRotation().Yaw or 0 end)
    local op, err = begin_spawn(job.fns, donor, donor:GetClass(), at, yaw, COLLISION_ADJUST, nil)
    check(op, "operator spawn failed: " .. tostring(err))
    job.made[#job.made + 1] = op
    -- Before the game builds it: the donor's slot (the game's tables only
    -- have slots 0-3), the team it joins, and the donor's look.
    op.SquadPosition = slot_of(donor) or 0
    op.DefaultTeam = (config.team_args or {})[job.team_def.joins] or donor.DefaultTeam
    local copied, failed = copy_look(op, donor)
    local done, finish_err = finish_spawn(job.fns, op, at, yaw)
    check(done, "operator not finished: " .. tostring(finish_err))
    job.op_name = object_name(op)
    members[job.op_name] = { team = job.team, call_sign = job.name }
    game.set_officer_override(job.op_name, { team = job.team, name = job.name })
    if not valid(op.Controller) then op:SpawnDefaultController() end
    check(valid(op.Controller), "no AI controller")
    job.made[#job.made + 1] = op.Controller
    check(valid(op.InventoryComp) and valid(donor.InventoryComp), "no inventory")
    job.op, job.donor = op, donor
    job.at = { X = spot.x, Y = spot.y, Z = spot.z + 50 }
    job.items, job.copies = {}, {}
    donor.InventoryComp.InventoryItems:ForEach(function(_, element)
        local item = element:get()
        if valid(item) then job.items[#job.items + 1] = item end
    end)
    pcall(function()
        local primary = donor:GetEquippedWeapon()
        job.primary = valid(primary) and object_name(primary) or nil
    end)
    step_note(job, string.format("spawned (%s, look and gear of %s: %d look fields%s, %d items)", object_name(op),
        object_name(donor), copied, #failed > 0 and (" (failed: " .. table.concat(failed, ", ") .. ")") or "", #job.items))
    return "items"
end

-- Copies the donor's items: each spawned, owned by the operator and added
-- to its inventory.
function STEPS.items(job)
    check(valid(job.op) and valid(job.donor), "operator or gear source gone")
    for _, item in ipairs(job.items) do
        if valid(item) then
            local class_name = object_name(item:GetClass())
            local copy, err = begin_spawn(job.fns, job.op, item:GetClass(), job.at, 0, COLLISION_ALWAYS, job.op)
            check(copy, "item spawn failed (" .. class_name .. "): " .. tostring(err))
            job.made[#job.made + 1] = copy
            local done, finish_err = finish_spawn(job.fns, copy, job.at, 0)
            check(done, "item not finished (" .. class_name .. "): " .. tostring(finish_err))
            copy:SetOwner(job.op)
            check(job.op.InventoryComp:AddInventoryItem(copy), "item not accepted (" .. class_name .. ")")
            job.copies[object_name(item)] = copy
            if object_name(item) == job.primary then job.in_hand = copy end
        end
    end
    step_note(job, string.format("%d items copied", #job.items))
    return "gear"
end

-- Points the gear record at the copies and puts the primary weapon in hand.
function STEPS.gear(job)
    check(valid(job.op) and valid(job.donor), "operator or gear source gone")
    local inv, copies = job.op.InventoryComp, job.copies
    local from, to = job.donor.InventoryComp.SpawnedGear, inv.SpawnedGear
    for _, slot in ipairs(c().gear_slots or {}) do
        local item = from[slot]
        if valid(item) and copies[object_name(item)] then to[slot] = copies[object_name(item)] end
    end
    pcall(function() to.Character = from.Character end)
    -- The lists (grenades, devices...) are grown natively: a fresh operator's are empty.
    local listed, problems = 0, {}
    for _, list in ipairs(c().gear_lists or {}) do
        local wanted = {}
        pcall(function()
            from[list]:ForEach(function(_, element)
                local copy = copies[object_name(element:get())]
                if copy then wanted[#wanted + 1] = copy end
            end)
        end)
        for _, copy in ipairs(wanted) do
            local count, err = append(job.fns, inv, "SpawnedGear." .. list, copy)
            if count then listed = listed + 1 else problems[#problems + 1] = list .. ": " .. tostring(err) end
        end
    end
    pcall(function() inv:RefreshItemCategories() end)
    pcall(function() inv:OnRep_SpawnedGear() end)
    check(valid(job.in_hand), "no primary weapon to copy")
    check(inv:PutItemInHands(job.in_hand, true, true, true), "primary weapon not equipped")
    step_note(job, string.format("geared up (%d listed%s)", listed,
        #problems > 0 and ("; not listed: " .. table.concat(problems, ", ")) or ""))
    return "finish"
end

-- The game's own end of spawning an AI officer, then the look refreshed
-- (config.look_updates).
function STEPS.finish(job)
    check(valid(job.op) and valid(job.op.Controller), "operator gone")
    job.op.Controller:OnAIFinishSpawning()
    local failed = {}
    for _, fn in ipairs(c().look_updates or {}) do
        local ok, err = pcall(function() job.op[fn](job.op) end)
        if not ok then failed[#failed + 1] = fn .. " (" .. tostring(err) .. ")" end
    end
    step_note(job, "AI started" .. (#failed > 0 and ("; look refresh failed: " .. table.concat(failed, ", ")) or ""))
    return "register"
end

-- The squad manager's officer list (SwatAI), which squad orders go to.
function STEPS.register(job)
    check(valid(job.op), "operator gone")
    local manager = game.resolve_target(c().manager or "SWATManager")
    check(valid(manager), "no squad manager")
    if c().add_to_squad_list == false then
        step_note(job, "not added to the squad list (config.reinforcements.add_to_squad_list = false)")
    else
        local count, err = append(job.fns, manager, "SwatAI", job.op)
        check(count, "not added to the squad list: " .. tostring(err))
        step_note(job, count == 0 and "already in the squad list" or string.format("added to the squad list (%d officers)", count))
    end
    game.forget_officers()
    return "done"
end

-- The called-in team an actor (by name) belongs to, or nil.
function reinforcements.team_of(actor_name)
    local m = members[actor_name]
    return m and m.team or nil
end

-- Starts calling in a team. Returns a result for RoNTAK's order list.
function reinforcements.request(cmd)
    local team = cmd.team
    local def = (c().teams or {})[team]
    local result = { id = cmd.id, team = team, action = "request_team", status = "error" }
    if not def then
        result.message = "unknown team " .. tostring(team)
        return result
    end
    if not game.player_pawn() then
        result.message = "no mission running"
        return result
    end
    -- The game's squad has 8 places (squad slots Alpha..India): a 9th
    -- officer in its list crashed the game (Nov 2026). Room for the whole team?
    local manager = game.resolve_target(c().manager or "SWATManager")
    local listed = 0
    if valid(manager) then
        pcall(function() manager.SwatAI:ForEach(function() listed = listed + 1 end) end)
    end
    local queued_total = #queue
    local wanted_now = 0
    for _, call_sign in ipairs(def.names or {}) do
        if not on_scene(team, call_sign) then wanted_now = wanted_now + 1 end
    end
    local room = (c().max_squad or 8) - listed - queued_total
    if wanted_now > 0 and room < wanted_now then
        result.message = string.format("the squad is full (%d of %d places taken): the game allows %d officers",
            listed + queued_total, c().max_squad or 8, c().max_squad or 8)
        note(string.format("%s not called in: %s", string.upper(team), result.message))
        return result
    end
    if not native() then
        result.message = "needs RoNTAKNative 0.2 or newer (see native/README.md)"
        note(string.format("%s not called in: %s", string.upper(team), result.message))
        return result
    end
    local wanted = 0
    for i, call_sign in ipairs(def.names or {}) do
        local queued = false
        for _, job in ipairs(queue) do if job.team == team and job.name == call_sign then queued = true end end
        if not on_scene(team, call_sign) and not queued then
            queue[#queue + 1] = { team = team, team_def = def, name = call_sign, kit = (def.kits or {})[i] or 0, id = cmd.id }
            wanted = wanted + 1
        end
    end
    if wanted == 0 then
        result.status, result.message = "ok", string.upper(team) .. " is already on scene"
        return result
    end
    result.status = "pending"
    result.message = string.format("calling in %d operator(s)", wanted)
    result.wanted, result.done = wanted, 0
    results[cmd.id] = result
    note(string.format("%s requested: %d operator(s)", string.upper(team), wanted))
    return result
end

-- Sets up the next operator, completely; called once per mod tick.
function reinforcements.tick()
    record_entry()
    local job = queue[1]
    if not job then return end
    job.step = job.step or "spawn"
    job.made = job.made or {}
    job.fns = job.fns or native()
    -- Everyone on their real team while the game takes the new operator in.
    squads.pause()
    local result = results[job.id]
    local ok, next_step = true, nil
    if not job.fns then
        ok, next_step = false, "RoNTAKNative is no longer loaded"
    end
    while ok do
        ok, next_step = pcall(STEPS[job.step], job)
        if not ok or next_step == "done" then break end
        job.step = next_step
    end
    table.remove(queue, 1)
    if ok then
        note(string.format("%s (%s) is on scene", job.name, string.upper(job.team)))
        if result then
            result.done = result.done + 1
            if result.done >= result.wanted then
                result.status, result.message = "ok", string.upper(job.team) .. " on scene"
            end
        end
    else
        discard(job.made)
        if job.op_name then
            members[job.op_name] = nil
            game.set_officer_override(job.op_name, nil)
        end
        note(string.format("%s (%s) could not be called in (step %s): %s", job.name, string.upper(job.team),
            job.step, tostring(next_step)))
        if result then result.status, result.message = "error", job.name .. ": " .. tostring(next_step) end
        -- The rest of this request would most likely fail the same way.
        for i = #queue, 1, -1 do if queue[i].id == job.id then table.remove(queue, i) end end
    end
end

-- Hotkey: a request with a negative id, like the test order.
local next_key_id = -100
function reinforcements.request_from_key(team)
    next_key_id = next_key_id - 1
    return reinforcements.request({ id = next_key_id, team = team })
end

return reinforcements
