-- RoNTAK configuration.
--
-- Everything that depends on Ready or Not's internals lives in this file. The
-- values below were found with the UE4SS header dump and the discovery tools
-- and tested in game (October 2026, Unreal Engine 5 build of Ready or Not).
-- If a game update breaks something, docs/02-discovery.md explains how to find
-- the new names. You never need to touch the other scripts.

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
    execute_held   = "F5",   -- start the orders held on the ATAK screen ("Hold for GO")
    map_info       = "F6",   -- write the level's building floors to bridge/mapinfo.json
    activity_dump  = "F7",   -- write every officer's door jobs to bridge/activities.txt
    discovery_dump = "F8",   -- write candidate classes/functions to bridge/discovery.txt
    sniff_toggle   = "F9",   -- start/stop logging calls to config.sniff functions
    test_order     = "F10",  -- send config.test_order through the normal order path
    floorplan_test = "F11",  -- TEST: save top-down pictures around you to bridge/floorplan_test_*.png
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
    -- Officer names: RosterCharacter.FirstName / LastName. The roster entry
    -- can be empty (it is checked before use); then the squad slot name is used.
    roster_property = "RosterCharacter",
    squad_names = { [0] = "Alpha", [1] = "Beta", [2] = "Charlie", [3] = "Delta" },
    -- Health shown in the roster: GetHealthStatus() returns an
    -- EPlayerHealthStatus, and GetCurrentHealth() / GetMaxHealth() the
    -- health points (AReadyOrNotCharacter, from the header dump).
    health_status_function = "GetHealthStatus",
    health_status_values = { [0] = "healthy", [1] = "injured", [2] = "downed", [3] = "incapacitated",
                             [4] = "dead", [5] = "arrested" },
    health_function = "GetCurrentHealth",
    max_health_function = "GetMaxHealth",
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
    -- Optional functions: is the door wedged? Is there a trap your team knows of?
    jammed_function = "IsJammed",
    trap_known_function = "HasTrapAndSWATKnowsTrap",
    -- Functions returning the name of the game's room on each side of the door.
    front_room_function = "GetFrontThreatOwningRoom",
    back_room_function = "GetBackThreatOwningRoom",
}

-- Rooms: the AI's threat-awareness points carry the name of their room
-- (OwningRoom). The outline of each room on the map is drawn around them.
config.rooms = {
    point_classes = { "ThreatAwarenessActor" },
    room_property = "OwningRoom",
    outside_property = "bIsOutside",
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
    wedge = 40, mirror = 34, multitool = 25, lockpick_gun = 49, chemlight = 28,
}

-- EDoorScanMethod, passed as "$scan" (scanning through an open door).
config.scan_args = { slide = 1, slice = 2, snap = 3, center = 4 }

-- People shown on the map so they can be restrained or reported. Only people
-- who are no threat are listed (surrendered, restrained, or down), so the map
-- never shows suspects your team hasn't dealt with.
config.targets = {
    classes = { "CyberneticCharacter" },
    suspect_function = "IsSuspect",
    civilian_function = "IsCivilian",
    surrendered_function = "IsSurrendered",
    arrested_function = "IsArrested",
    down_function = "IsDeadOrUnconscious",
    reported_function = "HasBeenReported",
}

-- Helicopter, drone and CCTV cameras, drawn on the map as view cones
-- (names from the header dump; to be confirmed in game).
config.cameras = {
    -- false = no helicopter / drone / CCTV features at all (nothing about
    -- them is read from the game).
    enabled = true,
    -- Police helicopter. Its tracking camera follows one suspect or civilian;
    -- the game calls OnTargetFound / OnTargetLost when it picks one up or
    -- loses it. Those people are marked on the map.
    helicopter_classes = { "Helicopter" },
    tracking_property = "RadialTrackingComponent",     -- .bHasTarget
    camera_property = "TrackingCameraComponent",       -- .CaptureComponent, IsCameraActive()
    target_found_hook = "/Script/ReadyOrNot.Helicopter:OnTargetFound",
    target_lost_hook = "/Script/ReadyOrNot.Helicopter:OnTargetLost",
    -- Drones (ADrone, ADroneVehicle and other UnmannedVehicle pawns).
    drone_classes = { "UnmannedVehicle" },
    drone_view_function = "GetTabletViewComponent",    -- the component the tablet view uses
    drone_camera_property = "FirstPersonCamera",       -- .FieldOfView
    drone_name_function = "GetTabletNameText",
    drone_alive_function = "IsAlive",
    -- CCTV. Shown only once the cameras are wired to the tablet.
    cctv_point_classes = { "CCTVCameraPoint" },        -- CaptureComponent, CameraName, FloorNumber
    cctv_system_classes = { "CCTVSystem" },
    cctv_wired_function = "IsWired",
    cctv_wired_property = "bWiredToTablet",
    -- Mark suspects and civilians a wired camera can see: inside its view,
    -- within cctv_view_range (cm), and with a clear line of sight
    -- (AReadyOrNotCharacter::HasLineOfSightTo, called with the camera's position).
    cctv_spots_people = true,
    cctv_view_range = 2500,
    cctv_line_of_sight_function = "HasLineOfSightTo",
    -- On the player pawn: the CCTV camera / helicopter whose feed is on screen.
    view_camera_property = "CurrentViewCamera",
    view_helicopter_property = "CurrentViewHelicopter",
}

-- EStackUpStyle, passed as "$side".
config.side_args = { auto = 0, split = 1, left = 2, right = 3 }

-- EFallInPattern: 0 Snake, 1 HalfSnake, 2 Diamond, 3 Flock.
config.fall_in_pattern = 0

-- UE4SS does not write item class (TSubclassOf) arguments when the mod calls
-- these functions: the game saw stale values (C2 as the grenade) and never
-- got the grenade. A pre-hook on each writes $breach_item / $grenade_item into
-- the call's parameters directly before the game runs it.
config.class_arg_hooks = {
    "/Script/ReadyOrNot.SWATManager:GiveBreachAndClearCommand",
    "/Script/ReadyOrNot.SWATManager:GiveDeployGrenadeAtLocation",
}

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
--               $scan          EDoorScanMethod      $character  the tapped person
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
--   GivePickLockCommand / GiveCloseDoorCommand / GiveDisarmTrapOnDoorCommand(Target, TeamType, CommandLocation)
--   GiveRemoveWedgeCommand / GiveCheckForTrapsCommand(Target, TeamType, CommandLocation, CommandNormal)
--   GiveScanDoorCommand(Target, TeamType, CommandLocation, ScanMethod)
--   GiveCoverAreaCommand / GiveDropChemlightAtLocation(TeamType, CommandLocation)
--   GiveDeployGrenadeAtLocation(TeamType, CommandLocation, Grenade)
--   GiveRestrainCommand(Target, TeamType, CommandLocation)
--   GiveReportTargetCommand(Target, TeamType)
--
-- Note: arguments 5 and 6 are used the other way round from their names in the
-- header dump. Tested in game: the class in argument 5 is what an officer
-- throws through the door (C2 put there was "thrown", and a flashbang in
-- argument 6 was ignored), so the grenade goes in 5 and the breaching item in 6.
local BREACH_ARGS = {
    "$door", "$breach", "$team", "$location", "$grenade_item", "$breach_item",
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
    -- Door
    pick_lock     = { target = "SWATManager", fn = "GivePickLockCommand", args = { "$door", "$team", "$location" } },
    close_door    = { target = "SWATManager", fn = "GiveCloseDoorCommand", args = { "$door", "$team", "$location" } },
    remove_wedge  = { target = "SWATManager", fn = "GiveRemoveWedgeCommand",
                      args = { "$door", "$team", "$location", "$normal" } },
    check_traps   = { target = "SWATManager", fn = "GiveCheckForTrapsCommand",
                      args = { "$door", "$team", "$location", "$normal" } },
    disarm_trap   = { target = "SWATManager", fn = "GiveDisarmTrapOnDoorCommand", args = { "$door", "$team", "$location" } },
    scan_open     = { target = "SWATManager", fn = "GiveScanDoorCommand", args = { "$door", "$team", "$location", "$scan" } },
    -- Map point
    cover_area    = { target = "SWATManager", fn = "GiveCoverAreaCommand", args = { "$team", "$location" } },
    chemlight     = { target = "SWATManager", fn = "GiveDropChemlightAtLocation", args = { "$team", "$location" } },
    deploy_grenade = { target = "SWATManager", fn = "GiveDeployGrenadeAtLocation",
                       args = { "$team", "$location", "$grenade_item" } },
    -- People
    restrain      = { target = "SWATManager", fn = "GiveRestrainCommand", args = { "$character", "$team", "$location" } },
    report        = { target = "SWATManager", fn = "GiveReportTargetCommand", args = { "$character", "$team" } },
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
    "helicopter", "drone", "unmanned", "cctv",
}

-- Full function paths to hook with the F9 sniffer, copied from discovery.txt.
-- Example: "/Script/ReadyOrNot.SomeClass:SomeFunction"
-- For troubleshooting only. When you use the command wheel only
-- OnCommandIssued fires (SWATManager is called from C++). The mod's own calls
-- to SWATManager do pass through the hook, so sniffing them shows the
-- arguments as the game received them. Do not read the SwatCommand struct
-- inside a hook: that crashed the game.
config.sniff = {
    "/Script/ReadyOrNot.SWATManager:GiveBreachAndClearCommand",
    "/Script/ReadyOrNot.SwatCommandWidget:OnCommandIssued",
    "/Script/ReadyOrNot.ReadyOrNotCommandFunctionLibrary:RespondToSWATCommand",
}

-- Values printed with every sniffed call, to see which team the wheel had selected.
config.sniff_context = {
    { class = "SwatCommandWidget", property = "ActiveTeamType" },
    { class = "SWATManager", property = "ActiveCommandTeam" },
}

return config
