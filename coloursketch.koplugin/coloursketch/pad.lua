--[[--
The full-screen sketch pad.

Drawing is two-phase, because colour refreshes are slow on Kaleido:
  * while the finger is down, the stroke is drawn straight into the screen
    buffer in black (white for the eraser) and refreshed with A2, the fastest
    2-level waveform;
  * on lift, the stroke is painted in colour onto the canvas, copied to the
    screen, and that rectangle is refreshed with a Kaleido colour waveform.

Touches are read raw, below KOReader's gesture detector, which otherwise only
reports a drag after ~35 dp of movement and would lose dots and stroke starts.

@module coloursketch.pad
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Canvas = require("coloursketch.canvas")
local Palette = require("coloursketch.palette")

local Screen = Device.screen
local floor, min, max = math.floor, math.min, math.max

local CREDIT = "Colour Sketch © 2026 Aleks Oniszczak"
local ERASER = #Palette.colours + 1
local HOLD_SECONDS = 0.5   -- press a swatch this long to show its shades

-- Move each channel of 0xRRGGBB a fraction t of the way towards target (0 or 255).
local function mix(rgb, target, t)
    local out = 0
    for shift = 16, 0, -8 do
        local c = floor(rgb / 2 ^ shift) % 256
        out = out * 256 + floor(c + (target - c) * t + 0.5)
    end
    return out
end

local Pad = InputContainer:extend{
    name = "coloursketch_pad",
    covers_fullscreen = true,
    -- Makes UIManager pass the dither hint on our repaints. On Kaleido that
    -- hint is what selects the colour waveforms (see disableHWDither).
    dithered = true,
    stop_events_propagation = true,

    canvas = nil,       -- optional: a Canvas to edit, with path set
    path = nil,         -- file the canvas was opened from / saved to
    actions = nil,      -- { save(pad, as_new), open(pad), exit(pad) } from the plugin
    exit_label = nil,
}

function Pad:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.row_h = floor(min(self.W, self.H) / 10)
    self.toolbar_y = self.H - 2 * self.row_h
    self.canvas = self.canvas or Canvas.new(self.W, self.toolbar_y)

    -- The colour is remembered by name, so editing the palette can't
    -- silently turn the remembered eraser into a colour (or vice versa).
    local s = G_reader_settings and G_reader_settings:readSetting("coloursketch") or {}
    self.colour_idx = 1
    if s.colour == "Eraser" then
        self.colour_idx = ERASER
    else
        for i, c in ipairs(Palette.colours) do
            if c.name == s.colour then self.colour_idx = i end
        end
    end
    self.size_idx = s.size or Palette.default_size
    if not Palette.sizes[self.size_idx] then self.size_idx = Palette.default_size end
    -- The shade each swatch shows, by colour name, when it isn't the base colour.
    self.shade = type(s.shades) == "table" and s.shades or {}
    self.fill_mode = false

    self.face = Font:getFace("cfont", 16)
    self.contacts = {}  -- slot -> "pad" | "other" | "ignored"
    self.overlays = {}  -- dialogs we showed over the pad, to clean up after when they close
    self:layoutToolbar()
end

function Pad:saveSettings()
    if G_reader_settings then
        local colour = self.colour_idx == ERASER and "Eraser" or Palette.colours[self.colour_idx].name
        G_reader_settings:saveSetting("coloursketch", { colour = colour, size = self.size_idx, shades = self.shade })
    end
end

-- session setup / teardown -----------------------------------------------

function Pad:onShow()
    self:disableHWDither()
    self:installTouchHook()
    if not Screen:isColorEnabled() then
        self:showOverlay(InfoMessage:new{
            text = _("Colour rendering is off in KOReader, so drawings will show in grey.\n\nTurn on Settings → Screen → Color rendering, then restart KOReader."),
        })
    end
end

function Pad:onCloseWidget()
    self:cancelHold()
    self:removeTouchHook()
    self:restoreHWDither()
    self:saveSettings()
    if self.canvas then self.canvas:free(); self.canvas = nil end
end

-- KOReader only promotes a refresh to a Kaleido colour waveform (GLRC16 /
-- GCC16) when it carries the dither hint, and on MTK Kobos that same hint also
-- switches on hardware dithering. While the pad is open we report no HW
-- dithering, so we get the colour waveform without the dither pass, and force
-- UIManager to keep passing the hint through. Both are restored on close.
function Pad:disableHWDither()
    local dev = Screen.device or Device
    self._saved_dither = {
        dev = dev,
        can = rawget(dev, "canHWDither"),
        hw = Screen.hw_dithering,
    }
    dev.canHWDither = function() return false end
    Screen.hw_dithering = true
end

function Pad:restoreHWDither()
    local s = self._saved_dither
    if not s then return end
    s.dev.canHWDither = s.can
    Screen.hw_dithering = s.hw
    self._saved_dither = nil
end

function Pad:installTouchHook()
    local gd = Device.input and Device.input.gesture_detector
    if not gd then return end
    self._gd, self._gd_own = gd, rawget(gd, "feedEvent")
    local base = gd.feedEvent
    gd.feedEvent = function(this, tevs)
        -- The pad's own contacts never reach the gesture detector. If they
        -- did, lifting a finger off Menu would also become a tap, delivered
        -- to the dialog that lift just opened, closing it straight away.
        local ok, forward = pcall(self.onTouchFrame, self, tevs)
        if not ok then
            logger.err("coloursketch: touch handling failed:", forward)
            forward = tevs
        end
        return base(this, forward)
    end
end

function Pad:removeTouchHook()
    if self._gd then
        self._gd.feedEvent = self._gd_own
        self._gd = nil
    end
end

-- Topmost widget, ignoring toasts (e.g. the "Saved" notification).
function Pad:isOnTop()
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if not w.toast and not w.invisible then return w == self end
    end
    return false
end

-- Swallow every gesture (e.g. from a second finger): drawing and the toolbar
-- are handled from raw touches.
function Pad:onGesture()
    return true
end

-- layout & painting ------------------------------------------------------

function Pad:layoutToolbar()
    self.cells = {}
    local function row(y, kinds)
        local n = #kinds
        for i, kind in ipairs(kinds) do
            local x0 = floor((i - 1) * self.W / n)
            local x1 = floor(i * self.W / n)
            table.insert(self.cells, { kind = kind[1], arg = kind[2], x = x0, y = y, w = x1 - x0, h = self.row_h })
        end
    end
    local swatches = {}
    for i = 1, #Palette.colours do swatches[i] = { "colour", i } end
    row(self.toolbar_y, swatches)
    row(self.toolbar_y + self.row_h,
        { { "size" }, { "colour", ERASER }, { "fill" }, { "undo" }, { "redo" }, { "menu" } })
end

function Pad:cellAt(x, y)
    for _, c in ipairs(self.cells) do
        if x >= c.x and x < c.x + c.w and y >= c.y and y < c.y + c.h then return c end
    end
end

function Pad:radius()
    return Palette.sizes[self.size_idx] / 2
end

-- The colour a swatch currently stands for: its base colour, or the shade picked for it.
function Pad:swatchRGB(i)
    local c = Palette.colours[i]
    return self.shade[c.name] or c.rgb
end

function Pad:currentRGB()
    if self.colour_idx == ERASER then return 0xFFFFFF end
    return self:swatchRGB(self.colour_idx)
end

--- Six shades of a colour, lightest first: two lighter, the colour itself,
-- three darker. Near-black colours can't get darker, so they get greys instead.
function Pad.shadesOf(rgb)
    local hi = max(floor(rgb / 65536) % 256, floor(rgb / 256) % 256, rgb % 256)
    if hi < 0x40 then
        return { mix(rgb, 255, 0.75), mix(rgb, 255, 0.6), mix(rgb, 255, 0.45),
                 mix(rgb, 255, 0.3), mix(rgb, 255, 0.15), rgb }
    end
    return { mix(rgb, 255, 0.6), mix(rgb, 255, 0.3), rgb,
             mix(rgb, 0, 0.25), mix(rgb, 0, 0.45), mix(rgb, 0, 0.6) }
end

local function drawText(bb, text, face, x, y, w, h, fg)
    local tw = TextWidget:new{ text = text, face = face, fgcolor = fg or Blitbuffer.COLOR_BLACK, bold = true, max_width = w - 8 }
    local size = tw:getSize()
    tw:paintTo(bb, x + floor((w - size.w) / 2), y + floor((h - size.h) / 2))
    tw:free()
end

function Pad:paintCell(bb, c)
    local x, y, w, h = c.x, c.y, c.w, c.h
    local black, grey = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_DARK_GRAY
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    local inset = floor(h * 0.14)
    if c.kind == "colour" then
        local selected = self.colour_idx == c.arg
        if c.arg == ERASER then
            bb:paintBorder(x + inset, y + inset, w - 2 * inset, h - 2 * inset, 2, black)
            drawText(bb, _("Eraser"), self.face, x, y, w, h)
        else
            bb:paintRectRGB32(x + inset, y + inset, w - 2 * inset, h - 2 * inset, Canvas.rgb32(self:swatchRGB(c.arg)))
        end
        if selected then
            bb:paintBorder(x + 3, y + 3, w - 6, h - 6, inset - 6, black)
        end
    elseif c.kind == "size" then
        local r = self:radius()
        local cx, cy = x + floor(w / 2), y + floor(h * 0.4)
        Canvas.capsule(cx, cy, cx, cy, r, function(yy, l, rr) bb:paintRect(l, yy, rr - l + 1, 1, black) end)
        drawText(bb, _("Size"), self.face, x, y + floor(h * 0.55), w, floor(h * 0.45))
    elseif c.kind == "fill" then
        if self.fill_mode then
            bb:paintRect(x + inset, y + inset, w - 2 * inset, h - 2 * inset, black)
            drawText(bb, _("Fill"), self.face, x, y, w, h, Blitbuffer.COLOR_WHITE)
        else
            drawText(bb, _("Fill"), self.face, x, y, w, h)
        end
    elseif c.kind == "undo" then
        drawText(bb, _("Undo"), self.face, x, y, w, h, self.canvas:canUndo() and black or grey)
    elseif c.kind == "redo" then
        drawText(bb, _("Redo"), self.face, x, y, w, h, self.canvas:canRedo() and black or grey)
    elseif c.kind == "menu" then
        drawText(bb, _("Menu"), self.face, x, y, w, h)
    end
end

function Pad:paintToolbar(bb)
    bb:paintRect(0, self.toolbar_y, self.W, self.H - self.toolbar_y, Blitbuffer.COLOR_WHITE)
    for _, c in ipairs(self.cells) do self:paintCell(bb, c) end
    bb:paintRect(0, self.toolbar_y, self.W, 2, Blitbuffer.COLOR_BLACK)
end

-- Show a dialog over the pad. When it closes, paintTo arranges a full-screen
-- flash so it leaves no ghost.
function Pad:showOverlay(widget)
    self.overlays[widget] = true
    UIManager:show(widget)
end

function Pad:paintTo(bb, x, y)
    bb:blitFrom(self.canvas.bb, x, y, 0, 0, self.canvas.w, self.canvas.h)
    self:paintToolbar(bb)
    if self.picker then self:paintShades(bb) end

    local closed = false
    for w in pairs(self.overlays) do
        if not UIManager:isWidgetShown(w) then
            self.overlays[w] = nil
            closed = true
        end
    end
    if closed then
        self:scheduleCleanRefresh()
    else
        -- UIManager would refresh us with a greyscale waveform; queue a gentle
        -- colour refresh of the whole screen, which merges with it.
        UIManager:setDirty(nil, "partial", nil, true)
    end
end

-- One of our dialogs closed: flash the whole screen in colour to clear its
-- ghost. Done on the next tick, once KOReader has drawn the screen without
-- the dialog, and only after refreshes still in progress have finished (e.g.
-- a tapped button's highlight), as a flash that overlaps one can be lost.
function Pad:scheduleCleanRefresh()
    if self._clean then return end
    self._clean = function()
        self._clean = nil
        -- If another dialog took over (e.g. Colour test from the Menu), the
        -- flash happens when that one closes instead.
        if not self:isOnTop() then return end
        Screen:refreshWaitForLast()
        self:colourRefresh(0, 0, self.W, self.H, true)
    end
    UIManager:nextTick(self._clean)
end

-- Refresh with a Kaleido colour waveform: GLRC16, or GCC16 (flashing) if asked.
function Pad:colourRefresh(x, y, w, h, flash)
    if flash then
        Screen:refreshFull(x, y, w, h, true)
    else
        Screen:refreshPartial(x, y, w, h, true)
    end
end

function Pad:refreshToolbar()
    self:paintToolbar(Screen.bb)
    self:colourRefresh(0, self.toolbar_y, self.W, self.H - self.toolbar_y)
end

-- Copy a canvas rectangle to the screen and show it in colour.
function Pad:showCanvasRect(x, y, w, h, flash)
    if not x then return end
    Screen.bb:blitFrom(self.canvas.bb, x, y, x, y, w, h)
    self:colourRefresh(x, y, w, h, flash)
end

-- touch input ------------------------------------------------------------

-- Raw touch slots are in the panel's native orientation; rotate them the
-- same way the gesture detector does for gestures.
function Pad:toScreen(tev)
    local pos = { x = tev.x, y = tev.y }
    self._gd:translateCoordinates({ pos = pos }, Screen:getTouchRotation())
    return pos.x, pos.y
end

-- Called for every input frame while the pad exists, whatever is on top.
-- A contact belongs to the pad only if it *started* while the pad was on top.
-- Returns the touches that aren't the pad's, for the gesture detector.
function Pad:onTouchFrame(tevs)
    local on_top = nil
    local forward = {}
    for _, tev in ipairs(tevs) do
        local slot, owner = tev.slot, self.contacts[tev.slot]
        if tev.id == -1 then
            if owner == "pad" then self:touchUp(self:toScreen(tev)) end
            self.contacts[slot] = nil
        elseif owner == nil then
            if on_top == nil then on_top = self:isOnTop() end
            if on_top and not self.press then
                self.contacts[slot] = "pad"
                self:touchDown(self:toScreen(tev))
            else
                self.contacts[slot] = "other"   -- a second finger, or not ours
            end
        elseif owner == "pad" then
            self:touchMove(self:toScreen(tev))
        end
        if owner ~= "pad" and self.contacts[slot] ~= "pad" then
            forward[#forward + 1] = tev
        end
    end
    self:flushPreview()
    return forward
end

function Pad:touchDown(x, y)
    if self.picker then
        -- While the shades are showing, a touch either picks one or dismisses them.
        local i = self:shadeAt(x, y)
        self.press = { kind = i and "shade" or "dismiss", shade = i }
        return
    end
    if y < self.toolbar_y then
        if self.fill_mode then
            self.press = { kind = "fill", x = x, y = y }
        else
            self.press = { kind = "stroke", points = { x, y }, r = self:radius() }
            self:previewSegment(x, y, x, y)
        end
    else
        local cell = self:cellAt(x, y)
        self.press = { kind = "button", cell = cell }
        if cell and cell.kind == "colour" and cell.arg ~= ERASER then
            self:startHold(cell)
        end
    end
end

function Pad:touchMove(x, y)
    local p = self.press
    if p and p.kind == "button" and not p.held and self:cellAt(x, y) ~= p.cell then
        self:cancelHold()   -- slid off the swatch before the hold completed
    end
    if not p or p.kind ~= "stroke" then return end
    local pts = p.points
    local lx, ly = pts[#pts - 1], pts[#pts]
    if x == lx and y == ly then return end
    pts[#pts + 1], pts[#pts + 2] = x, y
    self:previewSegment(lx, ly, x, y)
end

function Pad:touchUp(x, y)
    local p = self.press
    self.press = nil
    self:cancelHold()
    if not p then return end
    -- Turning pixels white leaves a ghost with the non-flashing colour
    -- waveform, so the eraser's result is shown with a (local) flash.
    local erasing = self.colour_idx == ERASER
    if p.kind == "stroke" then
        self:flushPreview()
        local rx, ry, rw, rh = self.canvas:stroke(p.points, p.r, self:currentRGB())
        self:showCanvasRect(rx, ry, rw, rh, erasing)
        self:afterEdit()
    elseif p.kind == "fill" then
        if y < self.toolbar_y then
            local rx, ry, rw, rh = self.canvas:floodFill(floor(x), floor(y), self:currentRGB())
            if rx then
                self:showCanvasRect(rx, ry, rw, rh, erasing)
                self:afterEdit()
            end
        end
    elseif p.kind == "shade" then
        if self:shadeAt(x, y) == p.shade then self:pickShade(p.shade) end
    elseif p.kind == "dismiss" then
        self:closeShades()
    elseif p.kind == "button" then
        if p.held then
            -- The hold opened the shades; lifting on one (after sliding up) picks it.
            local i = self.picker and self:shadeAt(x, y)
            if i then self:pickShade(i) end
        else
            local cell = self:cellAt(x, y)
            if cell and cell == p.cell then self:pressCell(cell) end
        end
    end
end

-- Draw part of the live stroke into the screen buffer, clipped to the canvas.
function Pad:previewSegment(x0, y0, x1, y1)
    local bb = Screen.bb
    local ink = self.colour_idx == ERASER and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local cw, ch = self.canvas.w, self.canvas.h
    local r = self.press.r
    Canvas.capsule(x0, y0, x1, y1, r, function(y, l, rr)
        if y >= 0 and y < ch then
            l, rr = max(l, 0), min(rr, cw - 1)
            if l <= rr then bb:paintRect(l, y, rr - l + 1, 1, ink) end
        end
    end)
    local bx, by, bw, bh = Canvas.strokeBox({ x0, y0, x1, y1 }, r)
    local d = self.dirty
    if d then
        local x2, y2 = max(d.x + d.w, bx + bw), max(d.y + d.h, by + bh)
        d.x, d.y = min(d.x, bx), min(d.y, by)
        d.w, d.h = x2 - d.x, y2 - d.y
    else
        self.dirty = { x = bx, y = by, w = bw, h = bh }
    end
end

-- One A2 refresh per input frame, covering everything drawn in it.
function Pad:flushPreview()
    local d = self.dirty
    if not d then return end
    self.dirty = nil
    local x, y, w, h = self.canvas:clip(d.x, d.y, d.w, d.h)
    if x then Screen:refreshA2(x, y, w, h) end
end

-- After any canvas change, Undo/Redo availability may have changed.
function Pad:afterEdit()
    local undo, redo = self.canvas:canUndo(), self.canvas:canRedo()
    if undo ~= self._could_undo or redo ~= self._could_redo then
        self._could_undo, self._could_redo = undo, redo
        self:refreshToolbar()
    end
end

-- shades -----------------------------------------------------------------

-- Raw touches have no hold event, so a timer opens the shades if the finger
-- is still on the same swatch when it fires.
function Pad:startHold(cell)
    self:cancelHold()
    local press = self.press
    self._hold = function()
        self._hold = nil
        if self.press ~= press or not self:isOnTop() then return end
        local ok, err = pcall(self.openShades, self, cell)
        if ok then
            press.held = true
        else
            logger.err("coloursketch: opening shades failed:", err)
        end
    end
    UIManager:scheduleIn(HOLD_SECONDS, self._hold)
end

function Pad:cancelHold()
    if self._hold then
        UIManager:unschedule(self._hold)
        self._hold = nil
    end
end

-- A column of shade boxes above the held swatch, over the canvas.
function Pad:openShades(cell)
    local shades = Pad.shadesOf(Palette.colours[cell.arg].rgb)
    local n = #shades
    local w = min(self.W, floor(cell.w * 1.5))
    local x = max(0, min(self.W - w, cell.x + floor((cell.w - w) / 2)))
    local box = min(self.row_h, floor((self.toolbar_y - 8) / n))
    local h = box * n
    self.picker = { base = cell.arg, shades = shades, x = x, y = self.toolbar_y - h - 8, w = w, h = h, box = box }
    self:paintShades(Screen.bb)
    local pk = self.picker
    self:colourRefresh(pk.x, pk.y, pk.w, pk.h)
end

function Pad:paintShades(bb)
    local pk = self.picker
    local black = Blitbuffer.COLOR_BLACK
    bb:paintRect(pk.x, pk.y, pk.w, pk.h, Blitbuffer.COLOR_WHITE)
    local current = self:swatchRGB(pk.base)
    local inset = floor(pk.box * 0.1)
    for i, rgb in ipairs(pk.shades) do
        local by = pk.y + (i - 1) * pk.box
        bb:paintRectRGB32(pk.x + inset, by + inset, pk.w - 2 * inset, pk.box - 2 * inset, Canvas.rgb32(rgb))
        if rgb == current then
            bb:paintBorder(pk.x + 2, by + 2, pk.w - 4, pk.box - 4, inset - 3, black)
        end
    end
    bb:paintBorder(pk.x, pk.y, pk.w, pk.h, 2, black)
end

function Pad:shadeAt(x, y)
    local pk = self.picker
    if not pk or x < pk.x or x >= pk.x + pk.w or y < pk.y or y >= pk.y + pk.h then return nil end
    return floor((y - pk.y) / pk.box) + 1
end

-- Put the canvas back where the shades were. Flash, as the boxes were solid colour.
function Pad:closeShades()
    local pk = self.picker
    if not pk then return end
    self.picker = nil
    self:showCanvasRect(pk.x, pk.y, pk.w, pk.h, true)
end

function Pad:pickShade(i)
    local pk = self.picker
    local base = Palette.colours[pk.base]
    local rgb = pk.shades[i]
    self.shade[base.name] = rgb ~= base.rgb and rgb or nil
    self.colour_idx = pk.base
    self:closeShades()
    self:refreshToolbar()
end

-- Every swatch back to its base colour from palette.lua.
function Pad:resetPalette()
    self.shade = {}
    self:refreshToolbar()
    UIManager:show(Notification:new{ text = _("Palette reset") })
end

-- toolbar ----------------------------------------------------------------

function Pad:pressCell(cell)
    if cell.kind == "colour" then
        self.colour_idx = cell.arg
        self:refreshToolbar()
    elseif cell.kind == "size" then
        self.size_idx = self.size_idx % #Palette.sizes + 1
        self:refreshToolbar()
    elseif cell.kind == "fill" then
        self.fill_mode = not self.fill_mode
        self:refreshToolbar()
    elseif cell.kind == "undo" or cell.kind == "redo" then
        -- Flash: undo/redo often turns colour back to white, which ghosts otherwise.
        local x, y, w, h
        if cell.kind == "undo" then x, y, w, h = self.canvas:undo() else x, y, w, h = self.canvas:redo() end
        self:showCanvasRect(x, y, w, h, true)
        self:afterEdit()
    elseif cell.kind == "menu" then
        self:showMenu()
    end
end

function Pad:showMenu()
    local dialog
    local function item(text, fn)
        return { text = text, callback = function()
            UIManager:close(dialog)
            self.actions.guard(function() fn() end)
        end }
    end
    local title = self.path and self.path:match("([^/]+)$") or _("Unsaved drawing")
    dialog = ButtonDialog:new{
        title = title,
        buttons = {
            { item(_("New"), function() self:confirmDiscard(function() self:newDrawing() end) end),
              item(_("Open…"), function() self:confirmDiscard(function() self.actions.open(self) end) end) },
            { item(_("Save"), function() self.actions.save(self, false) end),
              item(_("Save as…"), function() self.actions.save(self, true) end) },
            -- Closing the Menu flashes the screen, which also shows the result
            -- of Clear and New.
            { item(_("Clear page"), function()
                    self.canvas:clear()
                    self:afterEdit()
                end),
              item(_("Reset palette"), function() self:resetPalette() end) },
            { item(_("Colour test"), function() self:showColourTest() end),
              item(self.exit_label or _("Close"), function() self:requestExit() end) },
            -- A footer, not a button: disabled buttons draw grey and ignore taps.
            { { text = CREDIT, enabled = false, font_bold = false, font_size = 16 } },
        },
    }
    self:showOverlay(dialog)
end

function Pad:confirmDiscard(fn)
    if not self.canvas.modified then return fn() end
    self:showOverlay(ConfirmBox:new{
        text = _("Discard unsaved changes?"),
        ok_text = _("Discard"),
        ok_callback = fn,
    })
end

function Pad:newDrawing()
    self.canvas:free()
    self.canvas = Canvas.new(self.W, self.toolbar_y)
    self.path = nil
    self:afterEdit()
    UIManager:setDirty(self)   -- the closing dialog's flash shows it
end

-- Replace the canvas with a loaded image (a Blitbuffer) from path.
function Pad:loadImage(image, path)
    self.canvas:load(image)
    self.path = path
    self:afterEdit()
    UIManager:setDirty(self)   -- the closing Open list's flash shows it
end

function Pad:saved(path)
    self.path = path
    self.canvas.modified = false
    UIManager:show(Notification:new{ text = _("Saved ") .. path:match("([^/]+)$") })
end

function Pad:requestExit()
    if not self.canvas.modified then return self:exit() end
    self:showOverlay(ConfirmBox:new{
        text = _("Save your drawing before leaving?"),
        ok_text = _("Save"),
        ok_callback = function()
            self.actions.save(self, false, function() self:exit() end)
        end,
        other_buttons = { { { text = _("Don't save"), callback = function() self:exit() end } } },
    })
end

function Pad:exit()
    UIManager:close(self, "full")
    if self.actions.exit then self.actions.exit(self) end
end

-- colour test sheet ------------------------------------------------------

local ColourTest = InputContainer:extend{
    name = "coloursketch_colourtest",
    covers_fullscreen = true,
    dithered = true,
    stop_events_propagation = true,
}

function ColourTest:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
end

function ColourTest:onTap()
    UIManager:close(self)   -- the pad flashes the screen once it's gone
    return true
end

function ColourTest:paintTo(bb)
    local W, H = self.dimen.w, self.dimen.h
    bb:paintRect(0, 0, W, H, Blitbuffer.COLOR_WHITE)
    local face = Font:getFace("cfont", 12)
    local rows = {}
    for _, c in ipairs(Palette.colours) do rows[#rows + 1] = { c, true } end
    for _, c in ipairs(Palette.alternates) do rows[#rows + 1] = { c, false } end
    local header = floor(H * 0.04)
    drawText(bb, _("Palette (✓) and alternates — tap to close"), face, 0, 0, W, header)
    local rh = floor((H - header) / #rows)
    for i, row in ipairs(rows) do
        local c, in_palette = row[1], row[2]
        local y = header + (i - 1) * rh
        local colour = Canvas.rgb32(c.rgb)
        local label = string.format("%s%s #%06X", in_palette and "✓ " or "", c.name:gsub(" #.*", ""), c.rgb)
        drawText(bb, label, face, 0, y, floor(W * 0.3), rh)
        -- block, then each brush size as a line
        bb:paintRectRGB32(floor(W * 0.3), y + 4, floor(W * 0.2), rh - 8, colour)
        local lx = floor(W * 0.53)
        local seg = floor(W * 0.45 / #Palette.sizes)
        for j, d in ipairs(Palette.sizes) do
            local x0 = lx + (j - 1) * seg
            Canvas.capsule(x0 + d, y + floor(rh / 2), x0 + seg - d - 8, y + floor(rh / 2), d / 2, function(yy, l, r)
                bb:paintRectRGB32(l, yy, r - l + 1, 1, colour)
            end)
        end
    end
end

function Pad:showColourTest()
    local sheet = ColourTest:new{}
    self.overlays[sheet] = true
    UIManager:show(sheet, "full", nil, nil, nil, true)
end

return Pad
