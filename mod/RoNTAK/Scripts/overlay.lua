-- A short line of text on the game screen, shown by RoNTAK.
--
-- Used to show which team the command wheel commands while GREEN or YELLOW
-- is selected (squads.lua).
--
-- How: RoNTAKNative (0.3+) creates a CommonUserWidget the game's way
-- (WidgetBlueprintLibrary::Create); Lua gives it a TextBlock, places it with
-- SetPositionInViewport and adds it to the viewport above the game's HUD.
-- What didn't work in game (Nov 2026): PlayerController messages aren't
-- shown, a widget constructed from Lua never appeared, and this game's HUD
-- doesn't run ReceiveDrawHUD. (The Extra SWAT Teams mod showed the
-- Create + CommonUserWidget route works in this game.)
--
-- Every step is checked; a failure turns the text off for the session and the
-- log says which step.

local config = require("config")
local game = require("game")
local log = require("log")

local overlay = {}

local valid = game.valid

local widget, text_block, world_name = nil, nil, nil
local broken = false
local shown = nil
local noted = {}

local function c() return config.overlay or {} end
local function note(line) log.info("overlay: " .. line) end
local function note_once(key, line)
    if noted[key] then return end
    noted[key] = true
    note(line)
end

local function path_of(obj)
    local ok, full = pcall(function() return obj:GetFullName() end)
    if not ok or type(full) ~= "string" then return nil end
    return full:match("^%S+%s+(.+)$") or full
end

local function find(path)
    local obj = StaticFindObject and StaticFindObject(path)
    return valid(obj) and obj or nil
end

local function player_controller()
    local pc = game.player_controller()
    if valid(pc) then return pc end
    local ok, ctrl = pcall(function() return game.player_pawn().Controller end)
    if ok and valid(ctrl) then return ctrl end
    return nil
end

local function fail(step, err)
    broken = true
    widget, text_block = nil, nil
    note(string.format("could not show the on-screen text (%s%s); it stays off this session",
        step, err ~= nil and (": " .. tostring(err)) or ""))
    return false
end

local function to_text(s)
    local lib = find("/Script/Engine.Default__KismetTextLibrary")
    if lib then
        local ok, t = pcall(function() return lib:Conv_StringToText(s) end)
        if ok and t ~= nil then return t end
    end
    return FText and FText(s) or s
end

local function build(pc)
    local create = rawget(_G, "RoNTAK_CreateWidget")
    if type(create) ~= "function" then
        note_once("native", "needs RoNTAKNative 0.3 or newer to show text on screen")
        return false
    end
    note("building the on-screen text")
    local ok, path, err = pcall(create, c().widget_class or "/Script/CommonUI.CommonUserWidget", path_of(pc) or "")
    if not ok then return fail("create widget", path) end
    if not path then return fail("create widget", err) end
    local w = find(path)
    if not w then return fail("find widget", path) end

    local step = "widget tree"
    local built, problem = pcall(function()
        local tree = w.WidgetTree
        if not valid(tree) then
            tree = StaticConstructObject(find("/Script/UMG.WidgetTree"), w)
            w.WidgetTree = tree
        end
        step = "text"
        local text = StaticConstructObject(find("/Script/UMG.TextBlock"), tree)
        assert(valid(text), "no TextBlock")
        tree.RootWidget = text
        step = "font"
        -- The text itself stays white; its colour comes from the widget's tint
        -- (set_color). Written field by field: a whole FSlateColor passed from
        -- Lua came out black in game.
        pcall(function()
            local slate = text.ColorAndOpacity
            slate.SpecifiedColor.R, slate.SpecifiedColor.G, slate.SpecifiedColor.B, slate.SpecifiedColor.A = 1, 1, 1, 1
            slate.ColorUseRule = 0
        end)
        pcall(function()
            local font = text.Font
            font.Size = c().font_size or 30
            local outline = c().outline_color or { R = 0, G = 0, B = 0, A = 1 }
            font.OutlineSettings.OutlineSize = c().outline_size or 3
            font.OutlineSettings.OutlineColor.R = outline.R
            font.OutlineSettings.OutlineColor.G = outline.G
            font.OutlineSettings.OutlineColor.B = outline.B
            font.OutlineSettings.OutlineColor.A = outline.A
            text:SetFont(font)
        end)
        pcall(function()
            text:SetShadowOffset({ X = 3, Y = 3 })
            text:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 })
        end)
        step = "place"
        local size = c().size or { X = 520, Y = 48 }
        w:SetDesiredSizeInViewport(size)
        w:SetPositionInViewport(c().position or { X = 24, Y = 110 }, true)
        step = "show"
        w:SetVisibility(3)   -- HitTestInvisible: visible, never takes the mouse
        w:AddToViewport(c().z_order or 1200)
        widget, text_block = w, text
    end)
    if not built then return fail(step, problem) end
    local ok_world, wname = pcall(function() return pc:GetWorld():GetFName():ToString() end)
    world_name = ok_world and wname or nil
    note("on-screen text ready")
    return true
end

-- Shows text in color ({ R, G, B } 0-1), or hides it with nil. Called every
-- mod tick by its owner; only touches the widget on a change.
function overlay.show(text, color)
    if c().enabled == false then
        if text then note_once("off", "the on-screen text is off (config.overlay.enabled = false)") end
        return
    end
    if broken then return end
    text = text or ""
    color = color or { R = 1, G = 1, B = 1 }
    -- A new mission has a new world: build again.
    if valid(widget) and world_name then
        local pc = player_controller()
        local ok, wname = pcall(function() return pc:GetWorld():GetFName():ToString() end)
        if ok and wname ~= world_name then widget, text_block, shown = nil, nil, nil end
    end
    if not (valid(widget) and valid(text_block)) then
        widget, text_block, shown = nil, nil, nil
        if text == "" then return end
        local pc = player_controller()
        if not pc then
            note_once("pc", "no player controller found yet")
            return
        end
        if not build(pc) then return end
    end
    if shown and shown.text == text and shown.r == color.R and shown.g == color.G and shown.b == color.B then return end
    local ok, err = pcall(function()
        if text ~= "" then
            text_block:SetText(to_text(text))
            -- White text tinted by the widget: the team's colour.
            widget:SetColorAndOpacity({ R = color.R, G = color.G, B = color.B, A = 1 })
            widget:SetVisibility(3)
        else
            widget:SetVisibility(1)   -- Collapsed
        end
    end)
    if not ok then return fail("set text", err) end
    if text ~= "" and not noted.colour then
        -- What the game stored, for troubleshooting (once).
        local parts = {}
        pcall(function()
            local tint = widget.ColorAndOpacity
            parts[#parts + 1] = string.format("tint %.2f %.2f %.2f", tint.R, tint.G, tint.B)
        end)
        pcall(function()
            local own = text_block.ColorAndOpacity.SpecifiedColor
            parts[#parts + 1] = string.format("text %.2f %.2f %.2f", own.R, own.G, own.B)
        end)
        pcall(function() parts[#parts + 1] = "outline " .. tostring(text_block.Font.OutlineSettings.OutlineSize) end)
        note_once("colour", "colours as stored: " .. table.concat(parts, ", "))
    end
    shown = { text = text, r = color.R, g = color.G, b = color.B }
    if text ~= "" then note("showing \"" .. text .. "\"") end
end

return overlay
