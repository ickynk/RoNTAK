-- A small label on the game screen (RoNTAK's own UMG widget).
--
-- Used to show which team the command wheel commands while GREEN or YELLOW
-- is selected (squads.lua). The game doesn't show PlayerController messages,
-- so RoNTAK builds a widget: UserWidget -> WidgetTree -> CanvasPanel ->
-- TextBlock, added to the viewport. Every step is checked; if one fails the
-- label is turned off for the session and the log says which step.

local config = require("config")
local game = require("game")
local log = require("log")

local overlay = {}

local valid = game.valid

local widget, text_block = nil, nil
local broken = false
local shown = nil   -- { text, color } currently on screen

local function c() return config.overlay or {} end
local function note(line) log.info("overlay: " .. line) end

local function find(path)
    local obj = StaticFindObject and StaticFindObject(path)
    return valid(obj) and obj or nil
end

local function construct(class_path, outer)
    local class = find(class_path)
    if not class or not StaticConstructObject then return nil end
    local ok, obj = pcall(StaticConstructObject, class, outer)
    return ok and valid(obj) and obj or nil
end

local function fail(step, err)
    broken = true
    widget, text_block = nil, nil
    note(string.format("could not build the on-screen label (%s%s); it stays off this session",
        step, err and (": " .. tostring(err)) or ""))
    return false
end

local function step(what, fn)
    local ok, err = pcall(fn)
    if not ok then error({ step = what, err = err }, 0) end
end

local waiting_noted = false

local function player_controller()
    local pc = game.player_controller()
    if valid(pc) then return pc end
    local pawn = game.player_pawn()
    local ok, ctrl = pcall(function() return pawn.Controller end)
    if ok and valid(ctrl) then return ctrl end
    return nil
end

local function build()
    local pc = player_controller()
    if not valid(pc) then
        if not waiting_noted then
            waiting_noted = true
            note("no player controller found yet; the label will be built when there is one")
        end
        return false
    end
    note("building the on-screen label")
    local ok, err = pcall(function()
        local w = construct("/Script/UMG.UserWidget", pc)
        if not w then error({ step = "widget" }, 0) end
        local tree = construct("/Script/UMG.WidgetTree", w)
        if not tree then error({ step = "widget tree" }, 0) end
        step("widget tree link", function() w.WidgetTree = tree end)
        local canvas = construct("/Script/UMG.CanvasPanel", tree)
        if not canvas then error({ step = "canvas" }, 0) end
        step("root", function() tree.RootWidget = canvas end)
        local text = construct("/Script/UMG.TextBlock", tree)
        if not text then error({ step = "text" }, 0) end
        local slot
        step("add text", function() slot = canvas:AddChildToCanvas(text) end)
        step("place text", function()
            local x, y = c().x or 0.5, c().y or 0.12   -- fractions of the screen
            slot:SetAnchors({ Minimum = { X = x, Y = y }, Maximum = { X = x, Y = y } })
            slot:SetAlignment({ X = 0.5, Y = 0.5 })
            slot:SetAutoSize(true)
        end)
        pcall(function() text.Font.Size = c().font_size or 22 end)
        pcall(function() text:SetShadowOffset({ X = 2, Y = 2 }) end)
        pcall(function() text:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 }) end)
        step("show", function() w:AddToViewport(c().z_order or 50) end)
        widget, text_block = w, text
    end)
    if not ok then
        if type(err) == "table" then return fail(err.step, err.err) end
        return fail("build", err)
    end
    note("on-screen label ready")
    return true
end

local function apply(text, color)
    local ok, err = pcall(function()
        text_block:SetText(FText(text))
        text_block:SetColorAndOpacity({ SpecifiedColor = { R = color.R, G = color.G, B = color.B, A = 1 }, ColorUseRule = 0 })
        widget:SetVisibility(text ~= "" and 3 or 1)   -- 3 HitTestInvisible (visible), 1 Collapsed
    end)
    if not ok then return fail("set text", err) end
    return true
end

-- Shows text in color ({ R, G, B } 0-1), or hides the label with nil.
-- Called every mod tick by its owner; only touches the widget on a change.
local disabled_noted = false

function overlay.show(text, color)
    if c().enabled == false then
        if text and not disabled_noted then
            disabled_noted = true
            note("the on-screen label is off (config.overlay.enabled = false)")
        end
        return
    end
    if broken then return end
    text = text or ""
    color = color or { R = 1, G = 1, B = 1 }
    if not (valid(widget) and valid(text_block)) then
        widget, text_block, shown = nil, nil, nil
        if text == "" then return end
        if not build() then return end
    end
    if shown and shown.text == text and shown.r == color.R and shown.g == color.G and shown.b == color.B then return end
    if apply(text, color) then
        shown = { text = text, r = color.R, g = color.G, b = color.B }
        if text ~= "" then note("showing \"" .. text .. "\"") end
    end
end

return overlay
