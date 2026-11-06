-- Reinforcements: extra SWAT teams called in during a mission (stage 1).
--
-- Requesting a team (RoNTAK button or config.keys.request_<team>) spawns its
-- operators one per tick:
--   1. a free spot at the mission's entry point (where the squad stood when
--      the mission began), else near the player on the AI navigation mesh,
--      clear of other officers;
--   2. world:SpawnActor(<a stock officer's class>) there; squad slot and
--      team set; an AI controller if it has none;
--   3. a copy of a stock officer's gear (each item spawned and added, the
--      gear slots pointed at the copies, the primary weapon put in hand);
--   4. the game's own OnAIFinishSpawning, then the operator is added to the
--      squad manager's SwatAI list, so squad orders reach it.
-- A step that fails removes what was spawned for that operator.
--
-- The game has squad slots 4-7 (Foxtrot, Golf, Hotel, India) that single
-- player leaves empty; the teams use those, named as in config. In-game
-- orders follow DefaultTeam (RED / BLUE / GOLD only), so until the teams can
-- be commanded on their own (stage 2) each joins the stock team set in config.
--
-- The way to spawn and equip an operator follows what the Extra SWAT Teams
-- mod showed works in this game; this is RoNTAK's own implementation.

local config = require("config")
local game = require("game")
local log = require("log")

local reinforcements = {}

local valid, object_name = game.valid, game.object_name
local ZERO_ROT = { Pitch = 0, Yaw = 0, Roll = 0 }
local STOCK_SLOTS = { [0] = true, [1] = true, [2] = true, [3] = true }

local queue = {}        -- operators still to spawn: { team, slot, kit }
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

-- Stock officers (squad slots 0-3), by slot.
local function stock_by_slot()
    local out = {}
    for _, o in ipairs(game.officer_actors()) do
        local s = slot_of(o.actor)
        if STOCK_SLOTS[s] and ready(o.actor) then out[s] = o.actor end
    end
    return out
end

-- Live operators in a slot (any officer, stock or called in).
local function slot_taken(slot)
    for _, o in ipairs(game.officer_actors()) do
        if slot_of(o.actor) == slot and ready(o.actor) then return true end
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
        if STOCK_SLOTS[slot_of(o.actor)] and o.pos then spots[#spots + 1] = o.pos end
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

-- A free spot to spawn at: { x, y, z, centre } where centre means z is a
-- standing officer's centre (an entry position), else the floor. Tries the
-- entry positions themselves, then around them, then around the player.
-- Returns nil and the reasons spots were turned down.
local function spawn_spot(pawn, world_ctx, half)
    local nav = StaticFindObject and StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    local here = game.location(pawn)
    local taken = {}
    for _, o in ipairs(game.officer_actors()) do taken[#taken + 1] = o.pos end
    local rejected = { occupied = 0, off_nav = 0, other_floor = 0 }
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
                elseif math.abs(spot.z + half - centre.z) > 150 then
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

-- How a call's return value looks, for the log.
local function describe(v)
    if type(v) ~= "userdata" then return type(v) .. " " .. tostring(v) end
    if not valid(v) then return "an invalid object" end
    return "object " .. object_name(v)
end

local reported_returns = {}

-- Spawns an actor of class at a spot. Some UE4SS builds spawn it but return
-- nothing usable from SpawnActor; then the new actor is looked up: an actor
-- of that class at the spot that is_new() accepts.
local function spawn_actor(world, class, at, is_new)
    local ok, made = pcall(function() return world:SpawnActor(class, at, ZERO_ROT) end)
    if ok and valid(made) then return made end
    local class_name = object_name(class)
    if not reported_returns[class_name] then
        reported_returns[class_name] = true
        note(string.format("SpawnActor(%s) returned %s; looking the new actor up instead", class_name,
            ok and describe(made) or ("an error: " .. tostring(made))))
    end
    local best, best_d = nil, (c().find_spawned_cm or 300) ^ 2
    for _, a in ipairs(FindAllOf(class_name) or {}) do
        if valid(a) and is_new(a) then
            local p = game.location(a)
            local d = p and (p.x - at.X) ^ 2 + (p.y - at.Y) ^ 2
            if d and d < best_d then best, best_d = a, d end
        end
    end
    return best
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
local function copy_gear(op, donor, world, at, made)
    local inv, donor_inv = op.InventoryComp, donor.InventoryComp
    check(valid(inv) and valid(donor_inv), "no inventory")
    local primary = nil
    pcall(function() primary = donor:GetEquippedWeapon() end)
    local primary_name = valid(primary) and object_name(primary) or nil
    local copies, in_hand = {}, nil
    donor_inv.InventoryItems:ForEach(function(_, element)
        local item = element:get()
        if valid(item) then
            -- A new item has no owner yet and isn't one of this operator's copies.
            local copy = spawn_actor(world, item:GetClass(), at, function(a)
                for _, m in ipairs(made) do if object_name(m) == object_name(a) then return false end end
                local owned = false
                pcall(function() owned = valid(a:GetOwner()) end)
                return not owned
            end)
            check(valid(copy), "item spawn failed (" .. object_name(item) .. ")")
            made[#made + 1] = copy
            copy:SetOwner(op)
            check(inv:AddInventoryItem(copy), "item not accepted")
            copies[object_name(item)] = copy
            if object_name(item) == primary_name then in_hand = copy end
        end
    end)
    -- The gear record points at items; point the copy's at the copies.
    local from, to = donor_inv.SpawnedGear, inv.SpawnedGear
    for _, slot in ipairs(c().gear_slots or {}) do
        local item = from[slot]
        if valid(item) and copies[object_name(item)] then to[slot] = copies[object_name(item)] end
    end
    pcall(function() to.Character = from.Character end)
    for _, list in ipairs(c().gear_lists or {}) do
        pcall(function()
            local out = to[list]
            out:Empty()
            local n = 0
            from[list]:ForEach(function(_, element)
                local copy = copies[object_name(element:get())]
                if copy then n = n + 1; out[n] = copy end
            end)
        end)
    end
    pcall(function() inv:RefreshItemCategories() end)
    pcall(function() inv:OnRep_SpawnedGear() end)
    check(valid(in_hand), "no primary weapon to copy")
    check(inv:PutItemInHands(in_hand, true, true, true), "primary weapon not equipped")
end

local function spawn_operator(job)
    local pc = game.player_controller()
    local pawn = game.player_pawn()
    check(pc and valid(pawn), "no player")
    local world = pc:GetWorld()
    check(valid(world), "no world")
    local stock = stock_by_slot()
    local donor = stock[job.kit] or stock[0] or stock[1] or stock[2] or stock[3]
    check(donor, "no ready stock officer to copy")
    local half = 90
    pcall(function() half = donor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    local spot, rejected = spawn_spot(pawn, donor, half)
    if not spot then
        error(string.format("no free spot at the entry point or near you (%s; entry point %s; spots taken %d, off the nav mesh %d, other floor %d)",
            entry.spots and "entry known" or "entry not recorded", entry.spots and #entry.spots .. " positions" or "-",
            rejected.occupied, rejected.off_nav, rejected.other_floor), 0)
    end
    local made = {}
    local ok, err = pcall(function()
        -- An entry position is a standing officer's centre; a nav-mesh point is the floor.
        local z = spot.centre and spot.z + 10 or spot.z + half + 10
        -- A new officer isn't one the mod already knows (nor the player).
        local known = {}
        for _, o in ipairs(game.officer_actors()) do known[o.name] = true end
        local op = spawn_actor(world, donor:GetClass(), { X = spot.x, Y = spot.y, Z = z }, function(a)
            return not known[object_name(a)] and object_name(a) ~= object_name(pawn)
        end)
        check(valid(op), "operator spawn failed")
        made[#made + 1] = op
        op.SquadPosition = job.slot
        op.DefaultTeam = (config.team_args or {})[job.team_def.joins] or donor.DefaultTeam
        if not valid(op.Controller) then op:SpawnDefaultController() end
        check(valid(op.Controller), "no AI controller")
        made[#made + 1] = op.Controller
        copy_gear(op, donor, world, { X = spot.x, Y = spot.y, Z = spot.z + 50 }, made)
        op.Controller:OnAIFinishSpawning()
        local manager = game.resolve_target(c().manager or "SWATManager")
        check(valid(manager), "no squad manager")
        local n = 0
        manager.SwatAI:ForEach(function() n = n + 1 end)
        manager.SwatAI[n + 1] = op
    end)
    if not ok then
        discard(made)
        error(err, 0)
    end
    game.forget_officers()
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
    local wanted = 0
    for i, slot in ipairs(def.slots) do
        local queued = false
        for _, job in ipairs(queue) do if job.slot == slot then queued = true end end
        if not slot_taken(slot) and not queued then
            queue[#queue + 1] = { team = team, team_def = def, slot = slot, kit = (def.kits or {})[i] or 0, id = cmd.id }
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

-- Spawns the next queued operator; called once per mod tick.
function reinforcements.tick()
    record_entry()
    local job = table.remove(queue, 1)
    if not job then return end
    local result = results[job.id]
    local ok, err = pcall(spawn_operator, job)
    local name = ((config.officers or {}).squad_names or {})[job.slot] or ("slot " .. job.slot)
    if ok then
        note(string.format("%s (%s) is on scene", name, string.upper(job.team)))
        if result then
            result.done = result.done + 1
            if result.done >= result.wanted then
                result.status, result.message = "ok", string.upper(job.team) .. " on scene"
            end
        end
    else
        note(string.format("%s (%s) could not be called in: %s", name, string.upper(job.team), tostring(err)))
        if result then result.status, result.message = "error", name .. ": " .. tostring(err) end
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
