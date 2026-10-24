-- RoNTAK configuration.
--
-- Everything that depends on Ready or Not's internals lives in this file.
-- The game's class/function/property names are NOT publicly documented, so the
-- values marked "UNVERIFIED" below are starting guesses. Use the discovery
-- tools (F8 / F9, see docs/02-discovery.md) to find the real names on your
-- install, then edit this file. You never need to touch the other scripts.

local config = {}

-- How often (milliseconds) the mod publishes state and checks for new orders.
config.tick_ms = 250

-- Folder used to exchange files with the ATAK companion app.
-- nil = the "bridge" folder inside this mod (recommended).
config.bridge_dir = nil

-- Print extra information to the UE4SS console / UE4SS.log.
config.verbose = false

-- Hotkeys (UE4SS Key names). Set any to nil to disable it.
config.keys = {
    discovery_dump = "F8",   -- write candidate classes/functions to bridge/discovery.txt
    sniff_toggle   = "F9",   -- start/stop logging calls to config.sniff functions
    test_order     = "F10",  -- send config.test_order through the normal order path
}

---------------------------------------------------------------------------
-- Actors to track
---------------------------------------------------------------------------

-- AI SWAT officers. The first class name that returns objects is used.
config.officers = {
    -- CyberneticsSwat_V2_C = your AI officers (4 live in the discovery dump).
    -- SWATCharacter also matches 4 TrailerSWATCharacter actors, so it is only a fallback.
    classes = { "CyberneticsSwat_V2_C", "SWATCharacter" },
    -- Property on the officer holding its team (Red/Blue). nil = unknown.
    team_property = nil,                                             -- UNVERIFIED
    -- Map raw property values (numbers for enums, or strings) to team ids.
    team_values = { [0] = "red", [1] = "blue" },                      -- UNVERIFIED
    -- Optional property with the officer's display name.
    name_property = nil,
    -- Optional property with health (number). Shown as a status bar.
    health_property = nil,
    -- Skip actors whose object name contains any of these (e.g. the player
    -- pawn, if the player shares the officer class).
    exclude_name_patterns = {},
}

-- Doors. Positions are sent to the map so you can tap a door to order a team.
config.doors = {
    classes = { "Door" },                                            -- 32 live in the discovery dump
    -- Optional boolean property: is the door locked?
    locked_property = nil,
    -- Optional function returning whether the door is locked.
    locked_function = "IsLocked",
    -- Optional function returning whether your team knows the lock state.
    -- When it returns false the map shows the door as unknown, not locked.
    lock_known_function = "GetSWATKnowsLockState",
}

---------------------------------------------------------------------------
-- Orders
---------------------------------------------------------------------------

-- Team id -> value passed as the "$team" argument.
config.team_args = { gold = 0, red = 1, blue = 2 }                  -- UNVERIFIED

-- Breach option id -> value passed as "$breach".
config.breach_args = {                                              -- UNVERIFIED
    open = 0, kick = 1, shotgun = 2, c2 = 3, ram = 4, leader = 5,
}

-- Grenade option id -> value passed as "$grenade".
config.grenade_args = {                                             -- UNVERIFIED
    none = 0, flashbang = 1, stinger = 2, cs = 3,
}

-- Stack side option id -> value passed as "$side".
config.side_args = { auto = 0, split = 1, left = 2, right = 3 }      -- UNVERIFIED

-- How each ATAK action is carried out in the game.
--
--   target   = where to find the object whose function is called:
--              "player_controller", "player_pawn", "door" (the tapped door),
--              or a class name (the first object of that class is used).
--   fn       = name of the function to call on that object.
--   args     = list of arguments. Strings starting with "$" are filled in:
--              $team $door $location $breach $grenade $side
--              Anything else is passed as-is.
--
-- An action with fn = nil is shown in the ATAK menu but reports
-- "not configured" when used. Find the real functions with the sniffer
-- (docs/02-discovery.md) and fill them in here.
config.actions = {
    stack_up      = { target = "player_controller", fn = nil, args = { "$team", "$door", "$side" } },
    open_clear    = { target = "player_controller", fn = nil, args = { "$team", "$door", "$grenade" } },
    breach_clear  = { target = "player_controller", fn = nil, args = { "$team", "$door", "$breach", "$grenade" } },
    scan_door     = { target = "player_controller", fn = nil, args = { "$team", "$door" } },
    wedge_door    = { target = "player_controller", fn = nil, args = { "$team", "$door" } },
    move_to       = { target = "player_controller", fn = nil, args = { "$team", "$location" } },
    fall_in       = { target = "player_controller", fn = nil, args = { "$team" } },
    hold          = { target = "player_controller", fn = nil, args = { "$team" } },
    search_secure = { target = "player_controller", fn = nil, args = { "$team" } },
}

-- Order sent by the test hotkey, using the nearest door to the player.
config.test_order = { team = "red", action = "stack_up", options = { side = "auto" } }

---------------------------------------------------------------------------
-- Discovery & sniffing
---------------------------------------------------------------------------

-- Class/function names containing any of these words (case-insensitive) are
-- written to discovery.txt by the F8 dump.
config.discovery_keywords = {
    "swat", "officer", "squad", "team", "order", "command", "breach",
    "stack", "door", "clear", "element", "tablet", "atak", "map",
}

-- Full function paths to hook with the F9 sniffer, copied from discovery.txt.
-- Example: "/Script/ReadyOrNot.SomeClass:SomeFunction"
-- SWATManager has a Give...Command function for every order; the sniffer shows
-- which arguments the command wheel passes to them.
config.sniff = {
    "/Script/ReadyOrNot.SWATManager:GiveBreachAndClearCommand",
    "/Script/ReadyOrNot.SWATManager:GiveCheckForContactsCommand",
    "/Script/ReadyOrNot.SWATManager:GiveCheckForTrapsCommand",
    "/Script/ReadyOrNot.SWATManager:GiveCloseDoorCommand",
    "/Script/ReadyOrNot.SWATManager:GiveCollectEvidenceCommand",
    "/Script/ReadyOrNot.SWATManager:GiveCoverAreaCommand",
    "/Script/ReadyOrNot.SWATManager:GiveDeployGrenadeAtLocation",
    "/Script/ReadyOrNot.SWATManager:GiveDeployNonLethalItemAtTargetCommand",
    "/Script/ReadyOrNot.SWATManager:GiveDeployShield",
    "/Script/ReadyOrNot.SWATManager:GiveDisarmStandaloneTrapCommand",
    "/Script/ReadyOrNot.SWATManager:GiveDisarmTrapOnDoorCommand",
    "/Script/ReadyOrNot.SWATManager:GiveDropChemlightAtLocation",
    "/Script/ReadyOrNot.SWATManager:GiveFallInCommand",
    "/Script/ReadyOrNot.SWATManager:GiveHoldCommand",
    "/Script/ReadyOrNot.SWATManager:GiveMoveCommand",
    "/Script/ReadyOrNot.SWATManager:GiveOpenDoorCommand",
    "/Script/ReadyOrNot.SWATManager:GivePickLockCommand",
    "/Script/ReadyOrNot.SWATManager:GiveRemoveWedgeCommand",
    "/Script/ReadyOrNot.SWATManager:GiveReportTargetCommand",
    "/Script/ReadyOrNot.SWATManager:GiveRestrainCommand",
    "/Script/ReadyOrNot.SWATManager:GiveScanDoorCommand",
    "/Script/ReadyOrNot.SWATManager:GiveSearchAndSecureCommand",
    "/Script/ReadyOrNot.SWATManager:GiveSearchAndSecureCommand_Individual",
    "/Script/ReadyOrNot.SWATManager:GiveStackUpCommand",
    "/Script/ReadyOrNot.SWATManager:GiveWedgeDoorCommand",
    "/Script/ReadyOrNot.SWATManager:RemoveHoldCommand",
    "/Script/ReadyOrNot.SwatCommandWidget:DoCommand",
    "/Script/ReadyOrNot.SwatCommandWidget:OnCommandIssued",
    "/Script/ReadyOrNot.ReadyOrNotCommandFunctionLibrary:RespondToSWATCommand",
}

-- Values printed with every sniffed call, to see which team the wheel had selected.
config.sniff_context = {
    { class = "SwatCommandWidget", property = "ActiveTeamType" },
    { class = "SWATManager", property = "ActiveCommandTeam" },
}

return config
