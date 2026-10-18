-- Logging to the UE4SS console and UE4SS.log.

local config = require("config")

local log = {}

local last_error = {}
local ERROR_REPEAT_SECONDS = 10

local function write(level, msg)
    print(string.format("[RoNTAK] %s %s\n", level, tostring(msg)))
end

function log.info(msg) write("INFO ", msg) end

function log.debug(msg)
    if config.verbose then write("DEBUG", msg) end
end

-- Errors are printed at most once every ERROR_REPEAT_SECONDS per message so a
-- broken tick does not flood the log.
function log.error(msg)
    msg = tostring(msg)
    local now = os.time()
    if last_error[msg] and now - last_error[msg] < ERROR_REPEAT_SECONDS then return end
    last_error[msg] = now
    write("ERROR", msg)
end

return log
