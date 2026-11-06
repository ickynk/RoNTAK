-- Reinforcements: extra SWAT teams called in during a mission (stage 1).
--
-- Requesting a team (RoNTAK button or config.keys.request_<team>) spawns its
-- operators next to the player, one per tick:
--   1. a free spot near the player, on the AI navigation mesh and clear of
--      other officers;
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

-- A free spot on the navigation mesh near the player, or nil.
local function spawn_spot(pawn, world_ctx)
    local nav = StaticFindObject and StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    local here = game.location(pawn)
    if not here then return nil end
    local taken = {}
    for _, o in ipairs(game.officer_actors()) do taken[#taken + 1] = o.pos end
    for _, off in ipairs(c().spawn_offsets or {}) do
        local want = { X = here.x + off[1], Y = here.y + off[2], Z = here.z }
        local spot = nil
        if valid(nav) then
            local projected = {}
            local ok, hit = pcall(function()
                return nav:K2_ProjectPointToNavigation(world_ctx, want, projected, nil, nil, { X = 100, Y = 100, Z = 200 })
            end)
            if ok and hit and type(projected.X) == "number" and math.abs(projected.Z - here.z) < 150 then
                spot = { x = projected.X, y = projected.Y, z = projected.Z }
            end
        else
            spot = { x = want.X, y = want.Y, z = here.z }
        end
        if spot then
            local clear = true
            for _, p in ipairs(taken) do
                if p and (p.x - spot.x) ^ 2 + (p.y - spot.y) ^ 2 < 140 ^ 2 then clear = false break end
            end
            if clear then return spot end
        end
    end
    return nil
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
            local copy = world:SpawnActor(item:GetClass(), at, ZERO_ROT)
            check(valid(copy), "item spawn failed")
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
    local spot = spawn_spot(pawn, donor)
    check(spot, "no free spot near you")
    local made = {}
    local ok, err = pcall(function()
        local half = 90
        pcall(function() half = donor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
        local op = world:SpawnActor(donor:GetClass(), { X = spot.x, Y = spot.y, Z = spot.z + half + 10 }, ZERO_ROT)
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
