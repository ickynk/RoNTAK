-- File exchange with the ATAK companion app.
--
--   state.json     written by the mod: level, player, officers, doors, order results
--   commands.json  written by the companion: {"session": "...", "commands": [...]}

local config = require("config")
local json = require("json")
local log = require("log")

local bridge = {}

local function mod_dir()
    local source = debug.getinfo(1, "S").source:gsub("^@", "")
    -- source is ...\Mods\RoNTAK\Scripts\bridge.lua
    return (source:gsub("[/\\]Scripts[/\\][^/\\]+$", ""))
end

local sep = package.config:sub(1, 1)
local dir = config.bridge_dir or (mod_dir() .. sep .. "bridge")
bridge.dir = dir

local function path(name) return dir .. sep .. name end

local function read_file(name)
    local f = io.open(path(name), "rb")
    if not f then return nil end
    local data = f:read("a")
    f:close()
    return data
end

function bridge.write_file(name, text)
    local tmp = path(name .. ".tmp")
    local f, err = io.open(tmp, "wb")
    if not f then
        log.error("cannot write " .. tmp .. ": " .. tostring(err))
        return false
    end
    f:write(text)
    f:close()
    -- Windows cannot rename over an existing file, and cannot remove it while
    -- the companion is reading it; then write it in place (the companion
    -- retries a half-written file).
    os.remove(path(name))
    if os.rename(tmp, path(name)) then return true end
    os.remove(tmp)
    local direct = io.open(path(name), "wb")
    if not direct then
        log.debug("cannot replace " .. name .. " (in use), skipped this update")
        return false
    end
    direct:write(text)
    direct:close()
    return true
end

function bridge.write_state(state)
    return bridge.write_file("state.json", json.encode(state))
end

local seen_session = nil
local last_id = nil

-- Returns orders added since the last call. Orders already present when the mod
-- starts are skipped so a stale queue is never replayed into a new mission.
function bridge.new_commands()
    local text = read_file("commands.json")
    if not text or text == "" then return {} end
    local ok, doc = pcall(json.decode, text)
    if not ok or type(doc) ~= "table" or type(doc.commands) ~= "table" then
        return {} -- partially written file; try again next tick
    end

    local first_read = seen_session == nil
    if doc.session ~= seen_session then
        seen_session = doc.session
        last_id = 0
    end

    local fresh, max_id = {}, last_id
    for _, cmd in ipairs(doc.commands) do
        if type(cmd.id) == "number" and cmd.id > last_id then
            fresh[#fresh + 1] = cmd
            if cmd.id > max_id then max_id = cmd.id end
        end
    end
    last_id = max_id

    if first_read and #fresh > 0 then
        log.info(string.format("skipping %d orders queued before the mod started", #fresh))
        return {}
    end
    table.sort(fresh, function(a, b) return a.id < b.id end)
    return fresh
end

return bridge
