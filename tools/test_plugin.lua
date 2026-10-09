-- Plugin entry point: NickelMenu launch flag, exit behaviour, drawing files.
-- The pad itself is stubbed (tools/test_pad.lua covers it).
local env = require((arg[0]:match("(.*/)") or "./") .. "koenv") -- luacheck: ignore
local check = env.check

local function stub(name, t) package.preload[name] = function() return t end end
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("logger", { err = function() end, dbg = function() end, info = function() end })

local data_dir = os.getenv("TMPDIR") and (os.getenv("TMPDIR") .. "/coloursketch-test") or "/tmp/coloursketch-test"
os.execute("rm -rf '" .. data_dir .. "' && mkdir -p '" .. data_dir .. "'")
stub("datastorage", { getDataDir = function() return data_dir end })
local is_kobo = false
stub("device", { isKobo = function() return is_kobo end })
stub("ui/event", { new = function(_, name) return { name = name } end })

local shown, broadcasts, ticks = {}, {}, {}
stub("ui/uimanager", {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function() end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
    broadcastEvent = function(_, ev) broadcasts[#broadcasts + 1] = ev.name end,
})
local function runTicks() local t = ticks; ticks = {}; for _, fn in ipairs(t) do fn() end end
local function widget(kind) return { new = function(_, o) o.__kind = kind; return o end } end
stub("ui/widget/infomessage", widget("InfoMessage"))
stub("ui/widget/menu", widget("Menu"))
stub("ui/widget/confirmbox", widget("ConfirmBox"))
stub("ui/widget/notification", widget("Notification"))
stub("ui/widget/inputdialog", { new = function(_, o)
    o.__kind = "InputDialog"
    o.text = o.input
    o.getInputText = function(self) return self.text end
    o.onShowKeyboard = function() end
    return o
end })
stub("ui/renderimage", {})
stub("ui/widget/container/widgetcontainer", {
    extend = function(_, t) return t end,
})
stub("coloursketch.pad", { new = function(_, o) o.__kind = "Pad"; return o end })

-- lfs over the real filesystem (the drawing tests use a temp folder), except
-- the NickelMenu launch flag, whose age is faked. dir() returns (iterator,
-- handle) like the real one, and the iterator needs the handle.
local mtimes = {}
local function sh(cmd) local r = os.execute(cmd); return r == 0 or r == true end
local function q(p) return "'" .. p:gsub("'", "'\\''") .. "'" end
stub("libs/libkoreader-lfs", {
    attributes = function(p, what)
        local m = mtimes[p]
        if m then
            if what == "modification" then return m end
            return what == "mode" and "file" or { modification = m }
        end
        if p:match("coloursketch%.launch$") then return nil end
        local mode = sh("test -d " .. q(p)) and "directory" or (sh("test -e " .. q(p)) and "file") or nil
        if not mode then return nil end
        if what == "mode" then return mode end
        local f = io.popen("stat -f %m " .. q(p)); local t = tonumber(f:read("*l")); f:close()
        if what == "modification" then return t end
        return { mode = mode, modification = t }
    end,
    mkdir = function(p) return sh("mkdir " .. q(p)) end,
    dir = function(p)
        local f = io.popen("ls -a " .. q(p))
        local names = {}
        for line in f:lines() do names[#names + 1] = line end
        f:close()
        local handle = { i = 0, names = names }
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

print("file names")
do
    check(Plugin.cleanName("  My cat  ") == "My cat", "names are trimmed")
    check(Plugin.cleanName("garden.PNG") == "garden", "a typed .png is dropped")
    check(Plugin.cleanName('a/b:c*d?"e<f>g|h') == "a-b-c-d--e-f-g-h", "characters FAT can't store become dashes")
    check(Plugin.cleanName("...hidden") == "hidden", "no leading dots")
    check(Plugin.cleanName("   ") == nil and Plugin.cleanName(".png") == nil, "nothing left means no name")
end

print("saving")
do
    os.remove = real_remove -- luacheck: ignore
    local p = instance()
    local dir = data_dir .. "/drawings"
    local overlays = {}
    local pad = {
        canvas = { bb = { writePNG = function(_, f) io.open(f, "w"):close() end } },
        saved = function(self, path) self.path = path end,
        showOverlay = function(_, w, full) overlays[#overlays + 1] = { w = w, full = full } end,
    }
    local done = 0
    local function finish() done = done + 1 end
    local function button(dialog, text)
        for _, b in ipairs(dialog.buttons[1]) do if b.text == text then return b end end
    end

    p:save(pad, false, finish)
    local dlg = overlays[#overlays].w
    check(dlg.__kind == "InputDialog" and overlays[#overlays].full, "Save on a new drawing asks for a name")
    check(dlg.input:match("^Sketch %d%d%d%d%-%d%d%-%d%d %d%d%.%d%d$"), "suggesting a dated name")
    dlg.text = "   "
    button(dlg, "Save").callback()
    check(shown[#shown].__kind == "Notification" and pad.path == nil, "an empty name is refused")
    dlg.text = "My cat/dog: 1.png"
    button(dlg, "Save").callback()
    check(pad.path == dir .. "/My cat-dog- 1.png", "saved under the typed (cleaned) name")
    check(io.open(pad.path) ~= nil and io.open(pad.path .. ".tmp") == nil, "written via a temp file")
    check(done == 1, "done runs after saving")

    local n = #overlays
    p:save(pad, false, finish)
    check(#overlays == n and done == 2, "Save on a named drawing saves straight over it")

    p:save(pad, true)
    dlg = overlays[#overlays].w
    check(dlg.title == "Save as" and dlg.input == "My cat-dog- 1 copy", "Save as suggests a copy name")
    button(dlg, "Save").callback()
    check(pad.path == dir .. "/My cat-dog- 1 copy.png", "Save as makes a new file")

    p:save(pad, true)
    dlg = overlays[#overlays].w
    dlg.text = "My cat-dog- 1"
    button(dlg, "Save").callback()
    local confirm = overlays[#overlays].w
    check(confirm.__kind == "ConfirmBox" and pad.path:match("copy%.png$"), "asks before replacing another drawing")
    confirm.ok_callback()
    check(pad.path == dir .. "/My cat-dog- 1.png", "and replaces it when confirmed")

    local before = #overlays
    p:save(pad, true)
    button(overlays[#overlays].w, "Cancel").callback()
    check(#overlays == before + 1 and pad.path == dir .. "/My cat-dog- 1.png", "Cancel saves nothing")

    local list = p:listDrawings()
    check(#list == 2, "both drawings are listed")
end

print("Kobo drawings folder")
do
    local root = data_dir .. "/onboard"
    os.execute("mkdir -p " .. q(root .. "/Drawings"))
    for _, f in ipairs({ "one.png", "two.PNG", "._one.png", "notes.txt" }) do
        io.open(root .. "/Drawings/" .. f, "w"):close()
    end
    is_kobo = true
    local p = instance()
    p.kobo_root = root
    local dir = p:drawingsDir()
    check(dir == root .. "/.Drawings", "on a Kobo, drawings go in the hidden .Drawings folder")
    check(io.open(dir .. "/one.png") ~= nil and io.open(dir .. "/two.PNG") ~= nil, "old drawings are moved in")
    check(io.open(root .. "/Drawings/notes.txt") ~= nil and io.open(dir .. "/notes.txt") == nil,
          "other files are left where they were")
    check(sh("test -d " .. q(root .. "/Drawings")), "so the old folder stays")
    os.remove(root .. "/Drawings/notes.txt"); os.remove(root .. "/Drawings/._one.png")
    p:drawingsDir()
    check(not sh("test -d " .. q(root .. "/Drawings")), "an emptied old folder is removed")
    is_kobo = false
end

os.execute("rm -rf '" .. data_dir .. "'")
env.finish()
