-- Tools for finding Ready or Not's class, property and function names.
--   dump()        F8: writes bridge/discovery.txt
--   toggle_sniff() F9: logs every call to the functions listed in config.sniff

local bridge = require("bridge")
local config = require("config")
local log = require("log")

local discovery = {}

local function name_of(obj)
    local ok, name = pcall(function() return obj:GetFName():ToString() end)
    return ok and name or "?"
end

local function full_name_of(obj)
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and name or "?"
end

local function matches(text)
    local lower = text:lower()
    for _, word in ipairs(config.discovery_keywords) do
        if lower:find(word, 1, true) then return true end
    end
    return false
end

local function class_properties(class)
    local props = {}
    pcall(function()
        class:ForEachProperty(function(prop)
            local prop_type = "?"
            pcall(function() prop_type = prop:GetClass():GetFName():ToString() end)
            props[#props + 1] = string.format("%s (%s)", name_of(prop), prop_type)
        end)
    end)
    return props
end

-- Scans every loaded object. Takes a few seconds; run it during a mission so
-- officers and doors are loaded.
function discovery.dump()
    discovery.signatures()
    log.info("discovery: scanning loaded objects, the game may freeze briefly...")
    local classes, functions = {}, {}

    ForEachUObject(function(obj)
        local kind = "?"
        pcall(function() kind = obj:GetClass():GetFName():ToString() end)
        if kind == "Function" then
            local full = full_name_of(obj)
            if full:find("/Script/ReadyOrNot", 1, true) or full:find("/Game/", 1, true) then
                if matches(name_of(obj)) or matches(full) then functions[#functions + 1] = full end
            end
        elseif kind == "Class" or kind == "BlueprintGeneratedClass" then
            local name = name_of(obj)
            if matches(name) then classes[#classes + 1] = { name = name, class = obj } end
        end
    end)

    table.sort(classes, function(a, b) return a.name < b.name end)
    table.sort(functions)

    local out = {
        "RoNTAK discovery dump",
        "Classes with live instances are the ones to try in config.lua.",
        "",
        "== Classes (live instance count) ==",
    }
    for _, c in ipairs(classes) do
        local instances = FindAllOf(c.name)
        local count = instances and #instances or 0
        out[#out + 1] = string.format("%5d  %s", count, c.name)
        if count > 0 then
            for _, prop in ipairs(class_properties(c.class)) do
                out[#out + 1] = "         . " .. prop
            end
        end
    end
    out[#out + 1] = ""
    out[#out + 1] = "== Functions (copy paths into config.sniff, without the 'Function ' prefix) =="
    for _, f in ipairs(functions) do out[#out + 1] = f end

    bridge.write_file("discovery.txt", table.concat(out, "\n"))
    log.info(string.format("discovery: %d classes, %d functions -> %s", #classes, #functions, bridge.dir))
end

-- Sniffer -----------------------------------------------------------------

local hooks = {}
local sniff_lines = {}

local MAX_DEPTH = 3

-- Turns a game value into text. Structs are expanded field by field so the
-- contents of e.g. a SwatCommand are visible.
local function value_text(value, depth)
    local t = type(value)
    if t ~= "userdata" and t ~= "table" then return tostring(value) end
    depth = depth or 0

    local ok, text = pcall(function() return string.format("(%.0f, %.0f, %.0f)", value.X, value.Y, value.Z) end)
    if ok then return text end

    local full = nil
    pcall(function() full = value:GetFullName() end)
    if full and full:find("^ScriptStruct ") then
        local found, def = pcall(StaticFindObject, (full:gsub("^ScriptStruct ", "")))
        if not found or not def or depth >= MAX_DEPTH then return full end
        local fields = {}
        pcall(function()
            def:ForEachProperty(function(prop)
                local name = name_of(prop)
                local f_ok, field = pcall(function() return value[name] end)
                fields[#fields + 1] = name .. "=" .. (f_ok and value_text(field, depth + 1) or "?")
            end)
        end)
        return "{" .. table.concat(fields, ", ") .. "}"
    end
    if full then return full end

    local n_ok, count = pcall(function() return value:GetArrayNum() end)
    if n_ok then return string.format("<array of %d>", count) end
    ok, text = pcall(function() return value:ToString() end)
    if ok then return text end
    return "<userdata>"
end

local function describe(param)
    local ok, value = pcall(function() return param:get() end)
    if not ok then return "?" end
    return value_text(value)
end

-- Signatures ----------------------------------------------------------------

local function prop_type(prop)
    local kind = "?"
    pcall(function() kind = prop:GetClass():GetFName():ToString() end)
    return kind
end

local function inner(prop, getter)
    local ok, obj = pcall(function() return prop[getter](prop) end)
    if ok and obj and obj:IsValid() then return obj end
    return nil
end

local function enum_values(enum)
    local parts = {}
    pcall(function()
        enum:ForEachName(function(name, value)
            parts[#parts + 1] = string.format("%s=%s", name:ToString(), tostring(value))
        end)
    end)
    return table.concat(parts, ", ")
end

-- Writes each parameter of a struct or function, then the enums and structs it uses.
local function describe_fields(def, out, indent, seen)
    def:ForEachProperty(function(prop)
        local kind = prop_type(prop)
        local enum = inner(prop, "GetEnum")
        local struct = inner(prop, "GetStruct")
        local class = inner(prop, "GetPropertyClass")
        local detail = (enum or struct or class) and ("<" .. name_of(enum or struct or class) .. ">") or ""
        out[#out + 1] = string.format("%s%s: %s%s", indent, name_of(prop), kind, detail)
        if enum and not seen[name_of(enum)] then
            seen[name_of(enum)] = true
            out[#out + 1] = indent .. "    values: " .. enum_values(enum)
        end
        if struct and not seen[name_of(struct)] then
            seen[name_of(struct)] = true
            describe_fields(struct, out, indent .. "    ", seen)
        end
    end)
end

-- F8 also writes signatures.txt: parameters of every function in config.signatures.
function discovery.signatures()
    local out = { "RoNTAK function signatures", "" }
    for _, path in ipairs(config.signatures or {}) do
        out[#out + 1] = path
        local found, fn = pcall(StaticFindObject, path)
        if found and fn and fn:IsValid() then
            local ok, err = pcall(describe_fields, fn, out, "    ", {})
            if not ok then out[#out + 1] = "    (error: " .. tostring(err) .. ")" end
        else
            out[#out + 1] = "    (not found)"
        end
        out[#out + 1] = ""
    end
    bridge.write_file("signatures.txt", table.concat(out, "\n"))
    log.info(string.format("signatures: %d functions -> signatures.txt", #(config.signatures or {})))
end

-- Extra values logged with every sniffed call, from config.sniff_context.
local function context()
    local parts = {}
    for _, c in ipairs(config.sniff_context or {}) do
        local value = "?"
        pcall(function()
            local obj = FindFirstOf(c.class)
            if obj and obj:IsValid() then value = tostring(obj[c.property]) end
        end)
        parts[#parts + 1] = string.format("%s.%s=%s", c.class, c.property, value)
    end
    return table.concat(parts, " ")
end

local function flush_sniff()
    bridge.write_file("sniff.txt", table.concat(sniff_lines, "\n"))
end

function discovery.toggle_sniff()
    if #hooks > 0 then
        for _, h in ipairs(hooks) do pcall(UnregisterHook, h.path, h.pre, h.post) end
        hooks = {}
        flush_sniff()
        log.info("sniffer stopped, calls saved to sniff.txt")
        return
    end
    if #config.sniff == 0 then
        log.info("sniffer: config.sniff is empty, run the F8 dump first (docs/02-discovery.md)")
        return
    end
    sniff_lines = {}
    for _, fn_path in ipairs(config.sniff) do
        local ok, pre, post = pcall(RegisterHook, fn_path, function(self, ...)
            local args = {}
            for i, p in ipairs({ ... }) do args[i] = describe(p) end
            local line = string.format("%s  self=%s  args=[%s]  %s",
                fn_path, describe(self), table.concat(args, ", "), context())
            sniff_lines[#sniff_lines + 1] = line
            log.info("sniff: " .. line)
        end)
        if ok then
            hooks[#hooks + 1] = { path = fn_path, pre = pre, post = post }
        else
            log.error("sniffer could not hook " .. fn_path .. ": " .. tostring(pre))
        end
    end
    log.info(string.format("sniffer started on %d functions; give orders in game, press F9 again to stop", #hooks))
end

return discovery
