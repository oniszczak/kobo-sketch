-- The sketch pad driven the way KOReader drives it: raw touch frames go
-- through the gesture detector hook, the screen is a real Blitbuffer, and
-- refresh calls are recorded. The KOReader UI modules are stubbed.
local env = require((arg[0]:match("(.*/)") or "./") .. "koenv") -- luacheck: ignore
local check = env.check

local Blitbuffer = require("ffi/blitbuffer")
local W, H = 600, 800

local function stub(name, t) package.preload[name] = function() return t end end
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("logger", { dbg = function() end, info = function() end, warn = function() end,
                 err = function(...) print("logger.err", ...) end })
stub("dbg", { is_on = false, guard = function() end })

local saved_settings
_G.G_reader_settings = {
    readSetting = function() return saved_settings end,
    saveSetting = function(_, _, v) saved_settings = v end,
}

-- screen & device ---------------------------------------------------------
local refreshes = {}
local function recorder(kind)
    return function(_, x, y, w, h, dither)
        refreshes[#refreshes + 1] = { kind = kind, x = x, y = y, w = w, h = h, dither = dither }
    end
end
local device = { canHWDither = function() return true end }
local Screen = {
    bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BBRGB32),
    device = device,
    hw_dithering = false,
    rotation = 0,
    DEVICE_ROTATED_UPRIGHT = 0, DEVICE_ROTATED_CLOCKWISE = 1,
    DEVICE_ROTATED_UPSIDE_DOWN = 2, DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
    getWidth = function() return W end,
    getHeight = function() return H end,
    getTouchRotation = function(self) return self.rotation end,
    scaleByDPI = function(_, x) return x end,
    isColorEnabled = function() return true end,
    refreshA2 = recorder("a2"),
    refreshPartial = recorder("partial"),
    refreshFull = recorder("full"),
    refreshWaitForLast = function() refreshes[#refreshes + 1] = { kind = "wait" } end,
}
device.screen = Screen

-- The real gesture detector, for its coordinate rotation. Its feedEvent is
-- replaced by a stand-in that turns every touch it's given into a gesture.
stub("ui/time", { ms = function(x) return x end, s = function(x) return x end })
stub("util", {})
local GestureDetector = require("device/gesturedetector")
local fed = 0
local gd = setmetatable({ screen = Screen }, { __index = {
    feedEvent = function(_, tevs)
        local g = {}
        for _ = 1, #tevs do fed = fed + 1; g[#g + 1] = "gesture" end
        return g
    end,
    translateCoordinates = GestureDetector.translateCoordinates,
} })
stub("device", setmetatable({ input = { gesture_detector = gd } }, { __index = device }))
device.isKobo = function() return false end

-- UI ----------------------------------------------------------------------
local shown, dirty = {}, {}
local UIManager = { _window_stack = {} }
function UIManager:show(w, refresh, region, x, y, dither)
    table.insert(self._window_stack, { widget = w })
    shown[#shown + 1] = w
    if w.handleEvent then w:handleEvent({ name = "Show" }) end
    dirty[#dirty + 1] = { widget = w, refresh = refresh, dither = dither }
end
function UIManager:close(w)
    for i = #self._window_stack, 1, -1 do
        if self._window_stack[i].widget == w then table.remove(self._window_stack, i) end
    end
    if w.handleEvent then w:handleEvent({ name = "CloseWidget" }) end
end
function UIManager:isWidgetShown(w)
    for _, e in ipairs(self._window_stack) do if e.widget == w then return true end end
    return false
end
function UIManager:setDirty(w, refresh, region, dither)
    dirty[#dirty + 1] = { widget = w, refresh = refresh, region = region, dither = dither }
end
function UIManager:nextTick(fn) fn() end
-- Timers only fire when the test says so.
local timers = {}
function UIManager:scheduleIn(secs, fn) timers[#timers + 1] = { secs = secs, fn = fn } end
function UIManager:unschedule(fn)
    for i = #timers, 1, -1 do if timers[i].fn == fn then table.remove(timers, i) end end
end
local function fireTimers() local t = timers; timers = {}; for _, x in ipairs(t) do x.fn() end end
stub("ui/uimanager", UIManager)

local InputContainer = {}
InputContainer.__index = InputContainer
function InputContainer:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
function InputContainer:new(o)
    o = setmetatable(o or {}, self)
    o.ges_events = o.ges_events or {}
    if o.init then o:init() end
    return o
end
function InputContainer:handleEvent(ev)
    local h = self["on" .. ev.name]
    if h then return h(self, ev) end
end
stub("ui/widget/container/inputcontainer", InputContainer)

local function widget(kind)
    return { new = function(_, o) o = o or {}; o.__kind = kind; return o end }
end
stub("ui/widget/buttondialog", { new = function(_, o)
    o.__kind = "ButtonDialog"
    o.added = {}
    o.movable = { dimen = { x = 30, y = 200, w = 540, h = 300 } }
    o.getAddedWidgetAvailableWidth = function() return 500 end
    o.addWidget = function(self, w) self.added[#self.added + 1] = w end
    return o
end })
stub("ui/widget/confirmbox", widget("ConfirmBox"))
stub("ui/widget/infomessage", widget("InfoMessage"))
-- Like the real one, a Notification is a toast: it never blocks input.
stub("ui/widget/notification", { new = function(_, o) o.__kind = "Notification"; o.toast = true; return o end })
stub("ui/gesturerange", widget("GestureRange"))
stub("ui/font", { getFace = function() return {} end })
stub("ui/widget/textwidget", { new = function(_, o)
    o.getSize = function() return { w = 20, h = 10 } end
    o.paintTo = function() end
    o.free = function() end
    return o
end })

-- helpers -----------------------------------------------------------------
local Pad = require("coloursketch.pad")
local Palette = require("coloursketch.palette")

-- One input frame; each contact is { slot, x, y } or { slot, "up" }.
local function frame(...)
    local tevs = {}
    for i, c in ipairs({ ... }) do
        tevs[i] = { slot = c[1], id = c[2] == "up" and -1 or c[1], x = c[2] == "up" and c[3] or c[2], y = c[2] == "up" and c[4] or c[3] }
    end
    return gd:feedEvent(tevs)
end

local function screenRGB(x, y)
    local p = Screen.bb:getPixel(x, y):getColorRGB32()
    return p.r * 65536 + p.g * 256 + p.b
end
local function canvasRGB(pad, x, y)
    local p = pad.canvas.bb:getPixel(x, y):getColorRGB32()
    return p.r * 65536 + p.g * 256 + p.b
end
local function count(kind)
    local n = 0
    for _, r in ipairs(refreshes) do if r.kind == kind then n = n + 1 end end
    return n
end
local function cellCentre(pad, kind, arg)
    for _, c in ipairs(pad.cells) do
        if c.kind == kind and (arg == nil or c.arg == arg) then
            return c.x + math.floor(c.w / 2), c.y + math.floor(c.h / 2)
        end
    end
end
local function tap(pad, kind, arg)
    local x, y = cellCentre(pad, kind, arg)
    frame({ 0, x, y }); frame({ 0, "up", x, y })
end

local exited = 0
local function open()
    local pad = Pad:new{ actions = {
        guard = function(fn) fn(); return true end,
        save = function() return true end,
        open = function() end,
        exit = function() exited = exited + 1 end,
    } }
    UIManager:show(pad, "full", nil, nil, nil, true)
    Screen.bb:fill(Blitbuffer.COLOR_WHITE)
    refreshes = {}
    return pad
end

-- tests -------------------------------------------------------------------
print("opening")
local pad = open()
check(rawget(gd, "feedEvent") ~= nil, "touch hook installed")
check(device.canHWDither() == false, "HW dithering reported off while open")
check(Screen.hw_dithering == true, "UIManager keeps the dither hint while open")
check(pad.toolbar_y == H - 2 * math.floor(W / 10), "toolbar is two rows at the bottom")
local row1, row2, eraser_row = 0, 0, nil
for _, c in ipairs(pad.cells) do
    if c.y == pad.toolbar_y then row1 = row1 + 1 else row2 = row2 + 1 end
    if c.kind == "colour" and c.arg == #Palette.colours + 1 then eraser_row = c.y end
end
check(row1 == #Palette.colours and #Palette.colours == 10, "top row is the 10 colours")
check(row2 == 6 and eraser_row == pad.toolbar_y + pad.row_h, "Eraser sits in the tool row")

print("drawing a stroke")
local red = 2
tap(pad, "colour", red)
check(pad.colour_idx == red, "tapping a swatch selects that colour")
check(count("partial") == 1 and refreshes[#refreshes].y == pad.toolbar_y, "toolbar refreshed in colour")
refreshes = {}

fed = 0
local gestures = frame({ 0, 100, 100 })
check(#gestures == 0 and fed == 0, "the pad's touches are kept from the gesture detector")
check(screenRGB(100, 100) == 0x000000, "finger down draws a black dot on screen")
check(canvasRGB(pad, 100, 100) == 0xFFFFFF, "canvas untouched while drawing")
check(count("a2") == 1, "dot refreshed with A2")
frame({ 0, 150, 100 })
frame({ 0, 200, 140 })
check(screenRGB(150, 100) == 0x000000 and screenRGB(200, 140) == 0x000000, "moves draw black on screen")
check(count("a2") == 3 and count("partial") == 0, "one A2 refresh per frame, no colour refresh yet")
for _, r in ipairs(refreshes) do
    if r.dither then check(false, "A2 preview must not request dithering") end
end
frame({ 0, "up", 200, 140 })
check(canvasRGB(pad, 150, 100) == 0xFF0000, "lift paints the stroke in colour on the canvas")
check(screenRGB(150, 100) == 0xFF0000, "and copies it to the screen")
local last = refreshes[#refreshes]
local colour_refresh
for _, r in ipairs(refreshes) do if r.kind == "partial" and r.y < pad.toolbar_y then colour_refresh = r end end
check(colour_refresh and colour_refresh.dither == true, "lift triggers a colour (dithered-hint) partial refresh")
check(colour_refresh and colour_refresh.x <= 100 - 4 and colour_refresh.x + colour_refresh.w >= 200 + 4
      and colour_refresh.y <= 96 and colour_refresh.y + colour_refresh.h >= 144, "colour refresh covers the stroke")
check(last.y == pad.toolbar_y, "toolbar refreshed when Undo becomes available")

print("toolbar")
refreshes = {}
tap(pad, "undo")
check(canvasRGB(pad, 150, 100) == 0xFFFFFF and screenRGB(150, 100) == 0xFFFFFF, "Undo removes the stroke")
local undo_flash = refreshes[1]
check(undo_flash and undo_flash.kind == "full" and undo_flash.dither and undo_flash.x <= 100
      and undo_flash.x + undo_flash.w >= 200, "Undo flashes the area it changed, in colour")
refreshes = {}
tap(pad, "redo")
check(canvasRGB(pad, 150, 100) == 0xFF0000, "Redo restores it")
check(refreshes[1] and refreshes[1].kind == "full", "Redo flashes too")
local before = pad.size_idx
tap(pad, "size")
check(pad.size_idx == before % #Palette.sizes + 1, "Size cycles the brush")
frame({ 0, 300, 50 }); frame({ 0, "up", 300, 50 })
-- press on one cell, release on another: no action
local ux, uy = cellCentre(pad, "undo")
local rx, ry = cellCentre(pad, "redo")
local undo_len = #pad.canvas.undo_stack
frame({ 0, ux, uy }); frame({ 0, "up", rx, ry })
check(#pad.canvas.undo_stack == undo_len, "sliding off a button cancels it")
-- a stroke that wanders into the toolbar is clipped to the canvas
local tb_x, tb_y = cellCentre(pad, "fill")   -- a white toolbar cell, away from its label
tb_y = tb_y - 30
local tb_before = screenRGB(tb_x, tb_y)
frame({ 0, tb_x, pad.toolbar_y - 10 }); frame({ 0, tb_x, tb_y })
check(tb_before == 0xFFFFFF and screenRGB(tb_x, tb_y) == 0xFFFFFF, "preview never draws over the toolbar")
check(screenRGB(tb_x, pad.toolbar_y - 5) == 0x000000, "but does draw up to the toolbar's edge")
frame({ 0, "up", tb_x, tb_y })

print("menu")
fed = 0
local mx, my = cellCentre(pad, "menu")
frame({ 0, mx, my })
local lift_gestures = frame({ 0, "up", mx, my })
local top = UIManager._window_stack[#UIManager._window_stack].widget
check(top.__kind == "ButtonDialog", "Menu opens the dialog")
local footer = top.buttons[#top.buttons]
check(#footer == 1 and footer[1].text == "Colour Sketch © 2026 Aleks Oniszczak"
      and footer[1].enabled == false and footer[1].font_bold == false,
      "the credit is a footer row of its own: grey, plain, not tappable")
check(top.title == "Unsaved drawing" and #top.added == 0, "the title is just the drawing's name")
check(#lift_gestures == 0 and fed == 0, "the lift that opened it isn't also a tap on the dialog")
fed = 0
check(#frame({ 0, 10, 10 }) == 1, "touches reach the dialog while it's open")
frame({ 0, "up", 10, 10 })
local labels = {}
for _, row in ipairs(top.buttons) do for _, b in ipairs(row) do labels[b.text] = true end end
check(not labels["Refresh screen"] and labels["Clear page"] and labels["Colour test"], "Menu no longer has Refresh screen")

-- After a dialog closes: one full-screen colour flash, once refreshes in
-- flight have finished, and nothing flashing in the repaint itself.
local function checkCleanFlash(what)
    dirty, refreshes = {}, {}
    pad:paintTo(Screen.bb, 0, 0)
    local queued_flash = false
    for _, d in ipairs(dirty) do if d.refresh == "full" then queued_flash = true end end
    local wait, flash = refreshes[1], refreshes[2]
    check(not queued_flash and #refreshes == 2 and wait.kind == "wait" and flash.kind == "full" and flash.dither
          and flash.x == 0 and flash.y == 0 and flash.w == W and flash.h == H,
          what .. ": waits for refreshes in flight, then flashes the whole screen in colour")
end
UIManager:close(top)
checkCleanFlash("closing the Menu")
dirty, refreshes = {}, {}
pad:paintTo(Screen.bb, 0, 0)
check(dirty[1].refresh == "partial" and #refreshes == 0, "later repaints are gentle again")

pad:showColourTest()
local sheet = UIManager._window_stack[#UIManager._window_stack].widget
sheet:onTap()
checkCleanFlash("closing the Colour test")

-- Colour test opened from the Menu: the Menu is gone, but the flash waits
-- until the sheet closes too.
tap(pad, "menu")
local menu2 = UIManager._window_stack[#UIManager._window_stack].widget
UIManager:close(menu2)
pad:showColourTest()
refreshes = {}
pad:paintTo(Screen.bb, 0, 0)
check(#refreshes == 0, "no flash while the Colour test is still showing")
UIManager._window_stack[#UIManager._window_stack].widget:onTap()
checkCleanFlash("closing the Colour test opened from the Menu")

print("fill and eraser")
frame({ 0, 400, 300 }); frame({ 0, 500, 300 }); frame({ 0, 500, 400 }); frame({ 0, 400, 400 }); frame({ 0, 400, 300 })
frame({ 0, "up", 400, 300 })
tap(pad, "colour", 5)   -- green
tap(pad, "fill")
check(pad.fill_mode, "Fill toggles fill mode")
frame({ 0, 450, 350 })
check(screenRGB(450, 350) == 0xFFFFFF, "fill does not preview on touch down")
frame({ 0, "up", 450, 350 })
check(canvasRGB(pad, 450, 350) == Palette.colours[5].rgb, "tap in fill mode fills the enclosed area")
check(canvasRGB(pad, 380, 350) == 0xFFFFFF, "fill stays inside the outline")
tap(pad, "fill")
tap(pad, "colour", #Palette.colours + 1)
refreshes = {}
frame({ 0, 450, 350 })
check(screenRGB(450, 350) == 0xFFFFFF, "eraser previews in white")
frame({ 0, "up", 450, 350 })
check(canvasRGB(pad, 450, 350) == 0xFFFFFF, "eraser paints white on the canvas")
local flashed = false
for _, r in ipairs(refreshes) do
    if r.kind == "full" and r.dither and r.x <= 450 and r.x + r.w > 450 and r.y <= 350 and r.y + r.h > 350 then flashed = true end
end
check(flashed, "eraser's result is shown with a local colour flash, to clear ghosting")
check(count("full") == 1, "only the erased area flashes")

print("shades")
do
    local purple = Pad.shadesOf(0x8000FF)
    check(#purple == 6 and purple[3] == 0x8000FF, "six shades, with the colour itself third")
    local function lum(c) return math.floor(c / 65536) % 256 + math.floor(c / 256) % 256 + c % 256 end
    local ordered = true
    for i = 2, 6 do if lum(purple[i]) >= lum(purple[i - 1]) then ordered = false end end
    check(ordered, "shades run lightest to darkest")
    local black = Pad.shadesOf(0x000000)
    check(#black == 6 and black[6] == 0 and black[1] == 0xBFBFBF, "black gets greys, ending in black")

    local PURPLE = 7
    check(Palette.colours[PURPLE].name == "Purple", "(test assumes Purple is swatch 7)")
    tap(pad, "colour", 1)
    check(#timers == 0, "a quick tap on a swatch leaves no hold timer behind")

    local px_, py_ = cellCentre(pad, "colour", PURPLE)
    frame({ 0, px_, py_ })
    check(#timers == 1 and timers[1].secs == 0.5, "pressing a swatch starts a half-second hold")
    refreshes = {}
    fireTimers()
    local pk = pad.picker
    check(pk and pk.base == PURPLE, "holding opens the shades for that colour")
    check(pk.y + pk.h <= pad.toolbar_y and pk.x <= px_ and pk.x + pk.w >= px_, "shades sit above the swatch")
    check(screenRGB(pk.x + math.floor(pk.w / 2), pk.y + math.floor(pk.box / 2)) == purple[1], "lightest shade at the top")
    check(count("partial") == 1, "shades shown with a colour refresh")
    frame({ 0, "up", px_, py_ })
    check(pad.picker and pad.colour_idx == 1, "lifting on the swatch keeps the shades open, nothing chosen yet")

    -- tap the 5th shade
    local sx, sy = pk.x + math.floor(pk.w / 2), pk.y + 4 * pk.box + math.floor(pk.box / 2)
    refreshes = {}
    frame({ 0, sx, sy }); frame({ 0, "up", sx, sy })
    check(pad.picker == nil, "tapping a shade closes the column")
    check(pad.colour_idx == PURPLE and pad:currentRGB() == purple[5], "and paints with that shade")
    check(screenRGB(sx, sy) == canvasRGB(pad, sx, sy), "the drawing under the column is restored")
    local cleared = false
    for _, r in ipairs(refreshes) do if r.kind == "full" and r.y == pk.y and r.h == pk.h then cleared = true end end
    check(cleared, "and refreshed with a flash, so no ghost of the boxes remains")
    local swx, swy = cellCentre(pad, "colour", PURPLE)
    check(screenRGB(swx, swy) == purple[5], "the swatch now shows the chosen shade")

    frame({ 0, 60, 60 }); frame({ 0, "up", 60, 60 })
    check(canvasRGB(pad, 60, 60) == purple[5], "strokes use the chosen shade")

    -- slide up from the swatch onto a shade and lift
    frame({ 0, swx, swy }); fireTimers()
    local top = pad.picker
    frame({ 0, swx, top.y + math.floor(top.box / 2) })
    frame({ 0, "up", swx, top.y + math.floor(top.box / 2) })
    check(pad.picker == nil and pad:currentRGB() == purple[1], "hold, slide onto a shade, lift: picks it")

    -- dismiss without choosing
    local strokes_before = #pad.canvas.undo_stack
    frame({ 0, swx, swy }); fireTimers(); frame({ 0, "up", swx, swy })
    frame({ 0, 300, 100 }); frame({ 0, 320, 120 }); frame({ 0, "up", 320, 120 })
    check(pad.picker == nil and pad:currentRGB() == purple[1], "tapping elsewhere dismisses, keeping the colour")
    check(#pad.canvas.undo_stack == strokes_before, "and the dismissing touch doesn't draw")

    -- slide off before the hold completes
    frame({ 0, swx, swy }); frame({ 0, swx, 200 })
    check(#timers == 0, "sliding off the swatch cancels the hold")
    frame({ 0, "up", swx, 200 })

    local ex, ey = cellCentre(pad, "colour", #Palette.colours + 1)
    frame({ 0, ex, ey })
    check(#timers == 0, "the eraser has no shades")
    frame({ 0, "up", ex, ey })

    -- picking the base colour again removes the override
    tap(pad, "colour", 2)
    local rx_, ry_ = cellCentre(pad, "colour", 2)
    frame({ 0, rx_, ry_ }); fireTimers(); frame({ 0, "up", rx_, ry_ })
    local rp = pad.picker
    frame({ 0, rx_, rp.y + 2 * rp.box + 5 }); frame({ 0, "up", rx_, rp.y + 2 * rp.box + 5 })
    check(pad.shade.Red == nil and pad:currentRGB() == 0xFF0000, "choosing the colour itself goes back to the base")
    -- Menu -> Reset palette puts every swatch back
    tap(pad, "colour", PURPLE)
    check(pad:currentRGB() == purple[1], "(purple still has a shade chosen)")
    tap(pad, "menu")
    local menu_dialog = UIManager._window_stack[#UIManager._window_stack].widget
    local reset
    for _, row in ipairs(menu_dialog.buttons) do
        for _, b in ipairs(row) do if b.text == "Reset palette" then reset = b end end
    end
    check(reset ~= nil, "Menu has Reset palette")
    UIManager:close(menu_dialog)
    pad:paintTo(Screen.bb, 0, 0)
    refreshes = {}
    reset.callback()
    check(next(pad.shade) == nil, "Reset palette clears every chosen shade")
    check(pad.colour_idx == PURPLE and pad:currentRGB() == 0x8000FF, "the selected swatch goes back to its base colour")
    check(screenRGB(swx, swy) == 0x8000FF and count("partial") == 1, "and the toolbar is redrawn in colour")

    tap(pad, "colour", #Palette.colours + 1)   -- back to the eraser for the tests below
end

print("contacts and dialogs")
local strokes = #pad.canvas.undo_stack
frame({ 0, 100, 500 }, { 1, 300, 500 })
frame({ 0, 120, 500 }, { 1, 320, 500 })
frame({ 0, "up", 120, 500 }, { 1, "up", 320, 500 })
check(#pad.canvas.undo_stack == strokes + 1, "a second finger is ignored")
check(canvasRGB(pad, 320, 500) == 0xFFFFFF, "second finger leaves no mark")

local dialog = { name = "dialog" }
table.insert(UIManager._window_stack, { widget = dialog })
check(#frame({ 0, 100, 600 }) == 1, "gestures pass through when a dialog is on top")
UIManager:close(dialog)
frame({ 0, 120, 600 })
frame({ 0, "up", 120, 600 })
check(#pad.canvas.undo_stack == strokes + 1, "a touch that began under a dialog does not draw")
local toast = { toast = true }
table.insert(UIManager._window_stack, { widget = toast })
frame({ 0, 100, 650 }); frame({ 0, "up", 100, 650 })
check(#pad.canvas.undo_stack == strokes + 2, "drawing still works under a toast")
UIManager:close(toast)

print("rotation")
Screen.rotation = Screen.DEVICE_ROTATED_CLOCKWISE
local raw_x, raw_y = 200, 100            -- panel coordinates
frame({ 0, raw_x, raw_y })
check(pad.press and pad.press.points[1] == W - raw_y and pad.press.points[2] == raw_x, "stroke starts at the rotated point")
frame({ 0, "up", raw_x, raw_y })
Screen.rotation = 0

print("painting by UIManager")
dirty = {}
pad:paintTo(Screen.bb, 0, 0)
check(screenRGB(450, 330) == canvasRGB(pad, 450, 330), "paintTo shows the canvas")
check(#dirty == 1 and dirty[1].refresh == "partial" and dirty[1].dither == true and dirty[1].widget == nil,
      "paintTo queues a full-screen colour refresh")

print("closing")
pad:exit()
check(exited == 1, "exit action called")
check(rawget(gd, "feedEvent") == nil, "touch hook removed")
check(device.canHWDither() == true and Screen.hw_dithering == false, "dithering settings restored")
check(saved_settings and saved_settings.colour == "Eraser", "last colour remembered by name")
local again = Pad:new{ actions = {} }
check(again.colour_idx == #Palette.colours + 1, "reopening restores the eraser")
saved_settings = { colour = "Magenta", size = 1 }
check(Pad:new{ actions = {} }.colour_idx == 10, "a named colour is restored")
saved_settings = { colour = "Purple", shades = { Purple = 0x4D0099 } }
local reopened = Pad:new{ actions = {} }
check(reopened:currentRGB() == 0x4D0099, "a chosen shade is remembered")
saved_settings = { colour = 9 }   -- the old index-based setting
check(Pad:new{ actions = {} }.colour_idx == 1, "an old numeric setting falls back to black")
check(pad.canvas == nil, "canvas freed")
check(#frame({ 0, 10, 10 }) == 1, "gestures flow normally after closing")

env.finish()
