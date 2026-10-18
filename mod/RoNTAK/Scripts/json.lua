-- Minimal JSON encoder/decoder for the RoNTAK bridge.
-- Supports objects, arrays, strings, numbers, booleans and null (decoded as json.null).

local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end })

local escapes = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k <= 0 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true, n
end

local encode

local function encode_table(t, stack)
    if stack[t] then error("json: circular reference") end
    stack[t] = true
    local out = {}
    local arr, n = is_array(t)
    if arr and n > 0 then
        for i = 1, n do out[i] = encode(t[i], stack) end
        stack[t] = nil
        return "[" .. table.concat(out, ",") .. "]"
    end
    if arr then
        stack[t] = nil
        -- Empty tables encode as arrays unless tagged with json.object().
        return getmetatable(t) == json.object_mt and "{}" or "[]"
    end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = t[k]
        if v == nil then v = t[tonumber(k)] end
        out[#out + 1] = encode_string(k) .. ":" .. encode(v, stack)
    end
    stack[t] = nil
    return "{" .. table.concat(out, ",") .. "}"
end

encode = function(v, stack)
    local tv = type(v)
    if v == nil or v == json.null then return "null" end
    if tv == "boolean" then return tostring(v) end
    if tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v % 1 == 0 and math.abs(v) < 1e15 then return string.format("%d", v) end
        local s = string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")
        return s
    end
    if tv == "string" then return encode_string(v) end
    if tv == "table" then return encode_table(v, stack or {}) end
    error("json: cannot encode type " .. tv)
end

json.object_mt = {}
function json.object(t) return setmetatable(t or {}, json.object_mt) end

function json.encode(v) return encode(v, {}) end

-- Decoder ---------------------------------------------------------------

local function decode_error(str, pos, msg)
    error(string.format("json: %s at position %d", msg, pos))
end

local function skip_ws(str, pos)
    return str:find("[^ \t\r\n]", pos) or #str + 1
end

local decode_value

local function decode_string(str, pos)
    local buf, i = {}, pos + 1
    while true do
        local c = str:sub(i, i)
        if c == "" then decode_error(str, i, "unterminated string") end
        if c == '"' then return table.concat(buf), i + 1 end
        if c == "\\" then
            local e = str:sub(i + 1, i + 1)
            local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
            if map[e] then
                buf[#buf + 1] = map[e]
                i = i + 2
            elseif e == "u" then
                local hex = str:sub(i + 2, i + 5)
                local code = tonumber(hex, 16)
                if not code then decode_error(str, i, "bad unicode escape") end
                buf[#buf + 1] = utf8 and utf8.char(code) or string.char(code % 256)
                i = i + 6
            else
                decode_error(str, i, "bad escape")
            end
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
end

local function decode_number(str, pos)
    local s, e = str:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s then decode_error(str, pos, "bad number") end
    return tonumber(str:sub(s, e)), e + 1
end

decode_value = function(str, pos)
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == "{" then
        local obj = json.object()
        pos = skip_ws(str, pos + 1)
        if str:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            pos = skip_ws(str, pos)
            if str:sub(pos, pos) ~= '"' then decode_error(str, pos, "expected key") end
            local key
            key, pos = decode_string(str, pos)
            pos = skip_ws(str, pos)
            if str:sub(pos, pos) ~= ":" then decode_error(str, pos, "expected ':'") end
            obj[key], pos = decode_value(str, pos + 1)
            pos = skip_ws(str, pos)
            local d = str:sub(pos, pos)
            if d == "}" then return obj, pos + 1 end
            if d ~= "," then decode_error(str, pos, "expected ',' or '}'") end
            pos = pos + 1
        end
    elseif c == "[" then
        local arr, n = {}, 0
        pos = skip_ws(str, pos + 1)
        if str:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            n = n + 1
            arr[n], pos = decode_value(str, pos)
            pos = skip_ws(str, pos)
            local d = str:sub(pos, pos)
            if d == "]" then return arr, pos + 1 end
            if d ~= "," then decode_error(str, pos, "expected ',' or ']'") end
            pos = pos + 1
        end
    elseif c == '"' then
        return decode_string(str, pos)
    elseif str:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif str:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif str:sub(pos, pos + 3) == "null" then
        return json.null, pos + 4
    end
    return decode_number(str, pos)
end

function json.decode(str)
    local value, pos = decode_value(str, 1)
    pos = skip_ws(str, pos)
    if pos <= #str then decode_error(str, pos, "trailing characters") end
    return value
end

return json
