-- Shared test setup: puts the plugin and KOReader's own Lua sources (from
-- tools/fetch-koreader-src.sh) on package.path, so tests drive KOReader's
-- real Blitbuffer rather than a stand-in.

local root = arg[0]:match("(.*)/tools/") or "."
local ko = os.getenv("KOREADER_SRC") or (root .. "/.koreader-src")

local f = io.open(ko .. "/ffi/blitbuffer.lua")
if not f then
    io.stderr:write("KOReader sources not found at " .. ko .. "\n"
        .. "Mount the Kobo and run tools/fetch-koreader-src.sh first.\n")
    os.exit(1)
end
f:close()

package.path = root .. "/coloursketch.koplugin/?.lua;"
    .. ko .. "/?.lua;" .. ko .. "/frontend/?.lua;" .. package.path

-- Blitbuffer's util module wants lfs; it's never exercised by the tests.
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() end, dir = function() end }
end

local env = { root = root, failures = 0 }

function env.check(cond, msg)
    if cond then
        io.write("  ok   ", msg, "\n")
    else
        io.write("  FAIL ", msg, "\n")
        env.failures = env.failures + 1
    end
end

function env.finish()
    if env.failures > 0 then
        io.write(env.failures, " failure(s)\n")
        os.exit(1)
    end
    io.write("all passed\n")
end

return env
