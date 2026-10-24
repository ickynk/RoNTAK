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
    activity_dump  = "F7",   -- write every officer's door jobs to bridge/activities.txt
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
    -- Property on the officer holding its team. SquadPosition is an
    -- ESquadPosition: 0 Alpha, 1 Beta, 2 Charlie, 3 Delta (from the header dump).
    team_property = "SquadPosition",
    -- Which squad slot belongs to which team (checked in game: Alpha and Beta
    -- are BLUE, Charlie and Delta are RED).
    team_values = { [0] = "blue", [1] = "blue", [2] = "red", [3] = "red" },
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
    -- Optional functions returning whether the door is open / broken.
    open_function = "IsOpen",
    broken_function = "IsDoorBroken",
}

---------------------------------------------------------------------------
-- Orders
---------------------------------------------------------------------------

-- All values below come from the UE4SS header dump (ReadyOrNot.hpp and
-- ReadyOrNot_enums.hpp) and the sniffer.

-- ETeamType: TT_SERT_RED = 1, TT_SERT_BLUE = 2, TT_SQUAD = 5 (gold).
config.team_args = { red = 1, blue = 2, gold = 5 }

-- EDoorBreachType, passed as "$breach".
-- "move" is Move & Clear, used for doors that are already open.
config.breach_args = { open = 1, move = 2, kick = 3, shotgun = 4, ram = 5, c2 = 6, leader = 7 }

-- EItemCategory of the item each breach type uses. The item's class is taken
-- from the inventory of an officer on the ordered team ("$breach_item").
config.breach_items = { shotgun = 42, ram = 41, c2 = 38 }

-- EItemCategory of each grenade ("$grenade_item"). "none" sends no grenade.
-- "launcher" makes the officer fire the grenade launcher through the door.
config.grenade_items = { flashbang = 30, stinger = 33, cs = 32, ninebang = 31, launcher = 47 }

-- Items counted on every officer and sent to the ATAK screen, which disables
-- options nobody on the selected team carries. EItemCategory values.
config.inventory = {
    c2 = 38, shotgun = 42, ram = 41,
    flashbang = 30, stinger = 33, cs = 32, ninebang = 31, launcher = 47,
    wedge = 40, mirror = 34,
}

-- EStackUpStyle, passed as "$side".
config.side_args = { auto = 0, split = 1, left = 2, right = 3 }

-- EFallInPattern: 0 Snake, 1 HalfSnake, 2 Diamond, 3 Flock.
config.fall_in_pattern = 0

-- How each ATAK action is carried out in the game.
--
--   target  = where to find the object whose function is called:
--             "player_controller", "player_pawn", "door" (the tapped door),
--             or a class name (the first object of that class is used).
--   fn      = name of the function to call on that object.
--   args    = list of arguments. Strings starting with "$" are filled in:
--               $team          ETeamType of the ordered team
--               $door          the tapped door
--               $location      door orders: a point just outside the door on the
--                              team's side; other orders: the tapped map point
--               $normal        door orders: direction from the door to that side
--               $breach        EDoorBreachType      $side  EStackUpStyle
--               $breach_item   class of the breaching item (nil for kick/open/leader)
--               $grenade_item  class of the grenade (nil for none)
--               $with_leader   true when the breach type is "leader"
--               $fall_in       config.fall_in_pattern
--             Anything else (true, false, numbers) is passed as-is.
--   options = fixed options that override the ATAK ones (e.g. breach = "open").
--
-- Signatures (USWATManager, from ReadyOrNot.hpp):
--   GiveStackUpCommand(Target, TeamType, CommandLocation, CommandNormal, bCheckDoor, StackUpStyle)
--   GiveBreachAndClearCommand(Door, DoorBreachType, TeamType, CommandLocation,
--       DoorBreachItemClass, DoorUseItemClass, bWithLeader, bWithLeaderItem,
--       bAutoClear, bLastAutoClear, CustomStackUpStyle, bIsSWATCommand)
--   GiveCheckForContactsCommand(Target, TeamType, CommandLocation, CommandNormal)
--   GiveWedgeDoorCommand(Target, TeamType, CommandLocation, CommandNormal)
--   GiveMoveCommand(TeamType, CommandLocation)
--   GiveFallInCommand(TeamType, FallInPattern)
--   GiveHoldCommand(TeamType)
--   GiveSearchAndSecureCommand(TeamType, CommandLocation, bOnlyCurrentRoom)
local BREACH_ARGS = {
    "$door", "$breach", "$team", "$location", "$breach_item", "$grenade_item",
    "$with_leader", false, false, false, "$side", true,
}
config.actions = {
    stack_up      = { target = "SWATManager", fn = "GiveStackUpCommand",
                      args = { "$door", "$team", "$location", "$normal", true, "$side" } },
    breach_clear  = { target = "SWATManager", fn = "GiveBreachAndClearCommand", args = BREACH_ARGS },
    move_clear    = { target = "SWATManager", fn = "GiveBreachAndClearCommand", args = BREACH_ARGS,
                      options = { breach = "move" } },
    open_clear    = { target = "SWATManager", fn = "GiveBreachAndClearCommand", args = BREACH_ARGS,
                      options = { breach = "open" } },
    scan_door     = { target = "SWATManager", fn = "GiveCheckForContactsCommand",
                      args = { "$door", "$team", "$location", "$normal" } },
    wedge_door    = { target = "SWATManager", fn = "GiveWedgeDoorCommand",
                      args = { "$door", "$team", "$location", "$normal" } },
    move_to       = { target = "SWATManager", fn = "GiveMoveCommand", args = { "$team", "$location" } },
    fall_in       = { target = "SWATManager", fn = "GiveFallInCommand", args = { "$team", "$fall_in" } },
    hold          = { target = "SWATManager", fn = "GiveHoldCommand", args = { "$team" } },
    search_secure = { target = "SWATManager", fn = "GiveSearchAndSecureCommand",
                      args = { "$team", "$location", false } },
}

-- Order sent by the test hotkey. Door orders use the door nearest the player.
config.test_order = { team = "gold", action = "fall_in", options = {} }

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
-- Only OnCommandIssued fires when using the command wheel: the SWATManager
-- Give...Command functions are called from C++ and cannot be hooked (they can
-- still be called by the mod). Do not try to read the SwatCommand struct inside
-- a hook: that crashed the game.
config.sniff = {
    "/Script/ReadyOrNot.SwatCommandWidget:OnCommandIssued",
    "/Script/ReadyOrNot.ReadyOrNotCommandFunctionLibrary:RespondToSWATCommand",
}

-- Values printed with every sniffed call, to see which team the wheel had selected.
config.sniff_context = {
    { class = "SwatCommandWidget", property = "ActiveTeamType" },
    { class = "SWATManager", property = "ActiveCommandTeam" },
}

return config
