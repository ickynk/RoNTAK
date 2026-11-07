-- A short line of text on the game screen, drawn by RoNTAK.
--
-- Used to show which team the command wheel commands while GREEN or YELLOW
-- is selected (squads.lua).
--
-- How: every frame the game's HUD runs its ReceiveDrawHUD event; a hook on
-- it draws the text with the HUD's own DrawText (the standard Unreal way to
-- put text on screen). Tried before and not used (Nov 2026): the game didn't
-- show PlayerController messages, and a UMG widget built from Lua was
-- created but never appeared.
--
-- The hook is installed the first time there is something to show and stays
-- (UE4SS can't safely remove hooks); with nothing to show it returns at once.

local config = require("config")
local game = require("game")
local log = require("log")

local overlay = {}

local valid = game.valid

local current = nil       -- { text, color } to draw, or nil
local hooked, broken = false, false
local drawn_once, draw_errors = false, 0
local hooked_at = nil
local warned_not_drawn = false
local font = nil

local function c() return config.overlay or {} end
local function note(line) log.info("overlay: " .. line) end

local function no_object()
    if CreateInvalidObject then return CreateInvalidObject() end
    local ok, obj = pcall(FindFirstOf, "RoNTAK_NoSuchClass")
    if ok then return obj end
    return nil
end

-- A font to draw with (nil: the HUD falls back to the engine's medium font).
local function pick_font()
    if valid(font) then return font end
    for _, path in ipairs(c().fonts or { "/Engine/EngineFonts/Roboto.Roboto" }) do
        local f = StaticFindObject and StaticFindObject(path)
        if valid(f) then font = f return f end
    end
    local ok, f = pcall(FindFirstOf, "Font")
    if ok and valid(f) then font = f return f end
    return no_object()
end

local function draw(hud, width, height)
    local text, color = current.text, current.color
    local scale = c().scale or 1.6
    -- Centre the text on (x, y): its width estimated from its length.
    local char_px = (c().char_width_px or 9) * scale
    local x = width * (c().x or 0.5) - #text * char_px / 2
    local y = height * (c().y or 0.12)
    local f = pick_font()
    local shadow = { R = 0, G = 0, B = 0, A = 0.85 }
    hud:DrawText(text, shadow, x + 2, y + 2, f, scale, false)
    hud:DrawText(text, { R = color.R, G = color.G, B = color.B, A = 1 }, x, y, f, scale, false)
end

local function install()
    if hooked or broken then return end
    local path = c().hud_hook or "/Script/Engine.HUD:ReceiveDrawHUD"
    local ok, err = pcall(RegisterHook, path, function(context, size_x, size_y)
        if not current then return end
        local done, problem = pcall(function()
            local hud = context:get()
            local w, h = size_x:get(), size_y:get()
            draw(hud, w, h)
        end)
        if done then
            if not drawn_once then
                drawn_once = true
                note("drawing on the HUD")
            end
        else
            draw_errors = draw_errors + 1
            if draw_errors == 1 then note("drawing failed: " .. tostring(problem)) end
            if draw_errors >= 30 then
                broken, current = true, nil
                note("drawing kept failing; the on-screen text stays off this session")
            end
        end
    end)
    if ok then
        hooked, hooked_at = true, os.clock()
        note("hooked " .. path)
    else
        broken = true
        note("could not hook " .. path .. ": " .. tostring(err) .. "; the on-screen text stays off this session")
    end
end

local disabled_noted = false

-- Shows text in color ({ R, G, B } 0-1) from the next frame, or nothing with nil.
function overlay.show(text, color)
    if c().enabled == false then
        if text and not disabled_noted then
            disabled_noted = true
            note("the on-screen text is off (config.overlay.enabled = false)")
        end
        return
    end
    if broken then return end
    if not text or text == "" then
        current = nil
        return
    end
    if not current or current.text ~= text then note("showing \"" .. text .. "\"") end
    current = { text = text, color = color or { R = 1, G = 1, B = 1 } }
    install()
    -- If the HUD never draws, say so once (the game may not run ReceiveDrawHUD).
    if hooked and not drawn_once and not warned_not_drawn and os.clock() - hooked_at > 3 then
        warned_not_drawn = true
        note("the game's HUD hasn't run ReceiveDrawHUD yet; the text can't be drawn this way")
    end
end

return overlay
