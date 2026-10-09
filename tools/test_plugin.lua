-- Plugin entry point: NickelMenu launch flag, exit behaviour, drawing files.
-- The pad itself is stubbed (tools/test_pad.lua covers it).
local env = require((arg[0]:match("(.*/)") or "./") .. "koenv") -- luacheck: ignore
local check = env.check

local function stub(name, t) package.preload[name] = function() return t end end
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("logger", { err = function() end, dbg = function() end })

local data_dir = os.getenv("TMPDIR") and (os.getenv("TMPDIR") .. "/coloursketch-test") or "/tmp/coloursketch-test"
os.execute("rm -rf '" .. data_dir .. "' && mkdir -p '" .. data_dir .. "'")
stub("datastorage", { getDataDir = function() return data_dir end })
stub("device", { isKobo = function() return false end })
stub("ui/event", { new = function(_, name) return { name = name } end })

local shown, broadcasts, ticks = {}, {}, {}
stub("ui/uimanager", {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
    broadcastEvent = function(_, ev) broadcasts[#broadcasts + 1] = ev.name end,
})
local function runTicks() local t = ticks; ticks = {}; for _, fn in ipairs(t) do fn() end end
stub("ui/widget/infomessage", { new = function(_, o) o.__kind = "InfoMessage"; return o end })
stub("ui/widget/menu", { new = function(_, o) o.__kind = "Menu"; return o end })
stub("ui/renderimage", {})
stub("ui/widget/container/widgetcontainer", {
    extend = function(_, t) return t end,
})
stub("coloursketch.pad", { new = function(_, o) o.__kind = "Pad"; return o end })

-- lfs: a fake filesystem. dir() returns (iterator, handle) like the real one,
-- and the iterator needs the handle.
local mtimes = { ["/tmp/coloursketch.launch"] = nil }
local files_in = {}
stub("libs/libkoreader-lfs", {
    attributes = function(p, what)
        if p == data_dir .. "/drawings" and files_in.exists then return what == "mode" and "directory" or {} end
        local m = mtimes[p]
        if not m then return nil end
        if what == "modification" then return m end
        if what == "mode" then return "file" end
        return { modification = m }
    end,
    mkdir = function(p) if p == data_dir .. "/drawings" then files_in.exists = true; return true end end,
    dir = function()
        local handle = { i = 0, names = files_in.names or {} }
        return function(state)
            assert(state, "directory handle expected")
            state.i = state.i + 1
            return state.names[state.i]
        end, handle
    end,
})

local removed = {}
local real_remove = os.remove
os.remove = function(p) removed[#removed + 1] = p; return true end -- luacheck: ignore

local Plugin = require("main")
local function instance()
    local registered = false
    local p = setmetatable({ ui = { menu = { registerToMainMenu = function() registered = true end } } },
                          { __index = Plugin })
    p:init()
    return p, registered
end

print("launching")
do
    local _, registered = instance()
    runTicks()
    check(registered, "adds itself to the main menu")
    check(#shown == 0, "no flag: nothing opens")

    mtimes["/tmp/coloursketch.launch"] = os.time() - 5
    instance()
    check(removed[#removed] == "/tmp/coloursketch.launch", "fresh flag is consumed")
    check(#shown == 0, "pad waits for the next tick")
    runTicks()
    check(#shown == 1 and shown[1].__kind == "Pad", "fresh flag opens the pad")
    check(shown[1].exit_label == "Exit to Kobo", "opened from NickelMenu, it offers Exit to Kobo")
    shown[1].actions.exit(shown[1])
    runTicks()
    check(broadcasts[1] == "Exit", "leaving the pad exits KOReader")

    mtimes["/tmp/coloursketch.launch"] = os.time() - 600
    shown, removed = {}, {}
    instance()
    runTicks()
    check(removed[1] == "/tmp/coloursketch.launch" and #shown == 0, "stale flag is removed and ignored")
    mtimes["/tmp/coloursketch.launch"] = nil

    local p = instance()
    broadcasts = {}
    p:openPad(false)
    shown[#shown].actions.exit(shown[#shown])
    runTicks()
    check(shown[#shown].exit_label == "Close" and #broadcasts == 0, "opened from KOReader, closing just closes")
end

print("drawing files")
do
    local p = instance()
    local dir = data_dir .. "/drawings"
    files_in.names = { ".", "..", "old.png", "._new.png", "new.PNG", "notes.txt" }
    mtimes[dir .. "/old.png"] = 100
    mtimes[dir .. "/new.PNG"] = 200
    local list = p:listDrawings()
    check(files_in.exists, "drawings folder is created")
    check(#list == 2, "lists PNGs only, skipping AppleDouble files")
    check(list[1] and list[1].name == "new.PNG", "newest first")

    local a = p:newPath()
    mtimes[a] = 1
    local b = p:newPath()
    check(a ~= b and b:match("%-2%.png$"), "new names never overwrite an existing file")
    mtimes[a] = nil

    -- save writes to a temp file then renames into place
    os.execute("mkdir -p '" .. dir .. "'")
    local wrote
    local pad = {
        path = nil,
        canvas = { bb = { writePNG = function(_, f) wrote = f; io.open(f, "w"):close() end } },
        saved = function(self, path) self.path = path end,
    }
    os.remove = real_remove -- luacheck: ignore
    check(p:save(pad, false) == true, "save succeeds")
    check(wrote and wrote:match("%.png%.tmp$"), "PNG is written to a temp file first")
    check(pad.path and io.open(pad.path) ~= nil and io.open(wrote) == nil, "then renamed into place")
    local first = pad.path
    p:save(pad, false)
    check(pad.path == first, "Save overwrites the open drawing")
    mtimes[first] = 1
    p:save(pad, true)
    check(pad.path ~= first, "Save as new makes a new file")
end

os.execute("rm -rf '" .. data_dir .. "'")
env.finish()
