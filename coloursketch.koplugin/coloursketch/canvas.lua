--[[--
The drawing surface: an RGB32 Blitbuffer plus undo/redo history.

Knows nothing about the screen or input. Brush geometry is exposed as plain
functions so the live (monochrome) preview on screen and the final (colour)
stroke on the canvas cover exactly the same pixels.

@module coloursketch.canvas
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ffi = require("ffi")

local floor, ceil, sqrt, min, max, huge = math.floor, math.ceil, math.sqrt, math.min, math.max, math.huge

local u32p = ffi.typeof("uint32_t*")

local Canvas = {}
Canvas.__index = Canvas

-- Bytes of undo/redo patches to keep before dropping the oldest steps.
Canvas.HISTORY_BUDGET = 64 * 1024 * 1024

local function rgb32(rgb)
    return Blitbuffer.ColorRGB32(floor(rgb / 65536) % 256, floor(rgb / 256) % 256, rgb % 256, 0xFF)
end
Canvas.rgb32 = rgb32

-- The pixel as the canvas stores it in memory, for direct comparison.
local function packed(rgb)
    local cell = ffi.new("ColorRGB32[1]")
    cell[0] = rgb32(rgb)
    return ffi.cast(u32p, cell)[0]
end

-- brush geometry ---------------------------------------------------------

--- Calls emit(y, x_left, x_right) once per pixel row covered by a line of
-- radius r with round ends from (x0, y0) to (x1, y1). A dot is x0 == x1, y0 == y1.
-- The shape is convex, so each row is a single span.
function Canvas.capsule(x0, y0, x1, y1, r, emit)
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    -- The band between the two end discs is a parallelogram (qx, qy).
    local qx, qy
    if len > 0 then
        local nx, ny = -dy / len * r, dx / len * r
        qx = { x0 + nx, x1 + nx, x1 - nx, x0 - nx }
        qy = { y0 + ny, y1 + ny, y1 - ny, y0 - ny }
    end
    local r2 = r * r
    for y = floor(min(y0, y1) - r), ceil(max(y0, y1) + r) do
        local lo, hi = huge, -huge
        local d = y - y0
        if d * d <= r2 then
            local hw = sqrt(r2 - d * d)
            lo, hi = min(lo, x0 - hw), max(hi, x0 + hw)
        end
        d = y - y1
        if d * d <= r2 then
            local hw = sqrt(r2 - d * d)
            lo, hi = min(lo, x1 - hw), max(hi, x1 + hw)
        end
        if qx then
            for i = 1, 4 do
                local j = i % 4 + 1
                local ya, yb = qy[i], qy[j]
                if (ya <= y and y <= yb) or (yb <= y and y <= ya) then
                    if ya == yb then
                        lo, hi = min(lo, qx[i], qx[j]), max(hi, qx[i], qx[j])
                    else
                        local x = qx[i] + (y - ya) * (qx[j] - qx[i]) / (yb - ya)
                        lo, hi = min(lo, x), max(hi, x)
                    end
                end
            end
        end
        if lo <= hi then
            emit(y, floor(lo + 0.5), floor(hi + 0.5))
        end
    end
end

--- Bounding box of a stroke given as a flat point list {x1, y1, x2, y2, ...}.
function Canvas.strokeBox(points, r)
    local x0, y0, x1, y1 = huge, huge, -huge, -huge
    for i = 1, #points, 2 do
        x0, x1 = min(x0, points[i]), max(x1, points[i])
        y0, y1 = min(y0, points[i + 1]), max(y1, points[i + 1])
    end
    local pad = ceil(r) + 1
    return x0 - pad, y0 - pad, x1 - x0 + 2 * pad + 1, y1 - y0 + 2 * pad + 1
end

--- Calls Canvas.capsule for every segment of a stroke.
function Canvas.eachSegment(points, r, emit)
    local n = #points
    if n == 2 then
        Canvas.capsule(points[1], points[2], points[1], points[2], r, emit)
        return
    end
    for i = 1, n - 3, 2 do
        Canvas.capsule(points[i], points[i + 1], points[i + 2], points[i + 3], r, emit)
    end
end

-- the surface ------------------------------------------------------------

function Canvas.new(w, h)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    bb:fill(Blitbuffer.COLOR_WHITE)
    return setmetatable({
        bb = bb, w = w, h = h,
        undo_stack = {}, redo_stack = {}, history_bytes = 0,
        modified = false,
    }, Canvas)
end

local function freeStep(step)
    step.before:free()
    step.after:free()
end

function Canvas:free()
    for _, s in ipairs(self.undo_stack) do freeStep(s) end
    for _, s in ipairs(self.redo_stack) do freeStep(s) end
    self.undo_stack, self.redo_stack, self.history_bytes = {}, {}, 0
    if self.bb then self.bb:free(); self.bb = nil end
end

--- Clamp a rectangle to the canvas; nil if nothing is left.
function Canvas:clip(x, y, w, h)
    local x1, y1 = min(x + w, self.w), min(y + h, self.h)
    x, y = max(x, 0), max(y, 0)
    if x1 <= x or y1 <= y then return nil end
    return x, y, x1 - x, y1 - y
end

function Canvas:copyRect(x, y, w, h)
    local patch = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    patch:blitFrom(self.bb, 0, 0, x, y, w, h)
    return patch
end

--- Start an undoable change to a rectangle. Returns nil if it's off-canvas.
function Canvas:beginEdit(x, y, w, h)
    x, y, w, h = self:clip(x, y, w, h)
    if not x then return nil end
    return { x = x, y = y, w = w, h = h, before = self:copyRect(x, y, w, h) }
end

function Canvas:commitEdit(edit)
    if not edit then return end
    edit.after = self:copyRect(edit.x, edit.y, edit.w, edit.h)
    for _, s in ipairs(self.redo_stack) do
        self.history_bytes = self.history_bytes - s.bytes
        freeStep(s)
    end
    self.redo_stack = {}
    edit.bytes = 8 * edit.w * edit.h
    table.insert(self.undo_stack, edit)
    self.history_bytes = self.history_bytes + edit.bytes
    while self.history_bytes > Canvas.HISTORY_BUDGET and #self.undo_stack > 1 do
        local oldest = table.remove(self.undo_stack, 1)
        self.history_bytes = self.history_bytes - oldest.bytes
        freeStep(oldest)
    end
    self.modified = true
end

function Canvas:canUndo() return #self.undo_stack > 0 end
function Canvas:canRedo() return #self.redo_stack > 0 end

local function step(self, from, to, field)
    local s = table.remove(from)
    if not s then return nil end
    self.bb:blitFrom(s[field], s.x, s.y, 0, 0, s.w, s.h)
    table.insert(to, s)
    self.modified = true
    return s.x, s.y, s.w, s.h
end

--- Returns the changed rectangle, or nil if there was nothing to undo.
function Canvas:undo() return step(self, self.undo_stack, self.redo_stack, "before") end
function Canvas:redo() return step(self, self.redo_stack, self.undo_stack, "after") end

-- drawing ----------------------------------------------------------------

--- Paint a stroke in a colour (0xRRGGBB). Not undoable on its own: wrap it in
-- beginEdit/commitEdit using Canvas.strokeBox.
function Canvas:paintStroke(points, r, rgb)
    local bb, colour = self.bb, rgb32(rgb)
    Canvas.eachSegment(points, r, function(y, xl, xr)
        bb:paintRectRGB32(xl, y, xr - xl + 1, 1, colour)
    end)
end

--- Undoable stroke. Returns the changed rectangle, or nil.
function Canvas:stroke(points, r, rgb)
    local edit = self:beginEdit(Canvas.strokeBox(points, r))
    if not edit then return nil end
    self:paintStroke(points, r, rgb)
    self:commitEdit(edit)
    return edit.x, edit.y, edit.w, edit.h
end

--- Undoable flood fill of the 4-connected region of identical pixels at (sx, sy).
-- Returns the changed rectangle, or nil if nothing changed.
function Canvas:floodFill(sx, sy, rgb)
    local w, h = self.w, self.h
    if sx < 0 or sy < 0 or sx >= w or sy >= h then return nil end
    local stride = tonumber(self.bb.stride) / 4
    local px = ffi.cast(u32p, self.bb.data)
    local new = packed(rgb)
    local old = px[sy * stride + sx]
    if old == new then return nil end

    -- Pass 1: mark the region, so its bounding box is known before anything
    -- changes (the undo patch has to be taken first).
    local mask = ffi.new("uint8_t[?]", w * h)
    local bx0, by0, bx1, by1 = sx, sy, sx, sy
    local stack, n = { sx, sy }, 2
    while n > 0 do
        local x, y = stack[n - 1], stack[n]
        n = n - 2
        local row, mrow = y * stride, y * w
        if mask[mrow + x] == 0 and px[row + x] == old then
            local l, r = x, x
            while l > 0 and mask[mrow + l - 1] == 0 and px[row + l - 1] == old do l = l - 1 end
            while r < w - 1 and mask[mrow + r + 1] == 0 and px[row + r + 1] == old do r = r + 1 end
            for i = l, r do mask[mrow + i] = 1 end
            if l < bx0 then bx0 = l end
            if r > bx1 then bx1 = r end
            if y < by0 then by0 = y end
            if y > by1 then by1 = y end
            for ny = y - 1, y + 1, 2 do
                if ny >= 0 and ny < h then
                    local nrow, nmrow = ny * stride, ny * w
                    local in_run = false
                    for i = l, r do
                        if mask[nmrow + i] == 0 and px[nrow + i] == old then
                            if not in_run then
                                stack[n + 1], stack[n + 2] = i, ny
                                n = n + 2
                                in_run = true
                            end
                        else
                            in_run = false
                        end
                    end
                end
            end
        end
    end

    -- Pass 2: paint it.
    local edit = self:beginEdit(bx0, by0, bx1 - bx0 + 1, by1 - by0 + 1)
    for y = by0, by1 do
        local row, mrow = y * stride, y * w
        for x = bx0, bx1 do
            if mask[mrow + x] == 1 then px[row + x] = new end
        end
    end
    self:commitEdit(edit)
    return edit.x, edit.y, edit.w, edit.h
end

--- Undoable wipe to white.
function Canvas:clear()
    local edit = self:beginEdit(0, 0, self.w, self.h)
    self.bb:fill(Blitbuffer.COLOR_WHITE)
    self:commitEdit(edit)
end

--- Replace the contents with an image (top-left aligned, cropped to fit),
-- forgetting history. The image Blitbuffer is not freed.
function Canvas:load(image)
    self:free()
    self.bb = Blitbuffer.new(self.w, self.h, Blitbuffer.TYPE_BBRGB32)
    self.bb:fill(Blitbuffer.COLOR_WHITE)
    self.bb:blitFrom(image, 0, 0, 0, 0, min(image:getWidth(), self.w), min(image:getHeight(), self.h))
    self.modified = false
end

return Canvas
