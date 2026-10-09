-- Canvas: brush geometry, flood fill and undo/redo, on KOReader's real Blitbuffer.
local env = require((arg[0]:match("(.*/)") or "./") .. "koenv") -- luacheck: ignore
local check = env.check

local Canvas = require("coloursketch.canvas")

local function px(c, x, y)
    local p = c.bb:getPixel(x, y):getColorRGB32()
    return p.r * 65536 + p.g * 256 + p.b
end

local function checksum(c)
    local sum = 0
    for y = 0, c.h - 1 do
        for x = 0, c.w - 1 do sum = (sum * 31 + px(c, x, y) + x) % 2147483647 end
    end
    return sum
end

print("brush geometry")
do
    local rows = {}
    Canvas.capsule(50, 50, 50, 50, 4, function(y, l, r) rows[#rows + 1] = { y, l, r } end)
    check(#rows == 9, "dot of radius 4 spans 9 rows")
    check(rows[5][2] == 46 and rows[5][3] == 54, "dot's middle row is 9 px wide")

    -- A steep diagonal: every row must be one span, and consecutive rows must
    -- overlap, or flood fill would leak through the line.
    local prev, ok = nil, true
    Canvas.capsule(10, 10, 30, 90, 2, function(y, l, r)
        if prev and (l > prev[2] + 1 or r < prev[1] - 1) then ok = false end
        prev = { l, r }
    end)
    check(ok, "diagonal line rows are connected")

    local x, y, w, h = Canvas.strokeBox({ 10, 20, 40, 5 }, 3)
    check(x <= 7 and y <= 2 and x + w >= 43 and y + h >= 23, "stroke box covers the brush")
end

print("strokes")
do
    local c = Canvas.new(100, 80)
    check(px(c, 0, 0) == 0xFFFFFF, "new canvas is white")
    check(not c.modified, "new canvas is unmodified")
    local x, y, w, h = c:stroke({ 10, 10, 60, 10, 60, 50 }, 3, 0xFF0000)
    check(x ~= nil, "stroke reports a changed rectangle")
    check(px(c, 35, 10) == 0xFF0000 and px(c, 60, 30) == 0xFF0000, "stroke is painted along its path")
    check(px(c, 35, 30) == 0xFFFFFF, "stroke leaves the rest alone")
    -- Everything painted lies inside the reported rectangle.
    local outside = false
    for yy = 0, c.h - 1 do
        for xx = 0, c.w - 1 do
            if px(c, xx, yy) ~= 0xFFFFFF and (xx < x or yy < y or xx >= x + w or yy >= y + h) then outside = true end
        end
    end
    check(not outside, "changed rectangle contains the whole stroke")
    check(c.modified, "stroke marks the canvas modified")

    local cx = c:stroke({ -50, -50, -40, -40 }, 2, 0)
    check(cx == nil and #c.undo_stack == 1, "off-canvas stroke is ignored")
    c:stroke({ 98, 40 }, 6, 0x0000FF)
    check(px(c, 99, 40) == 0x0000FF, "stroke at the edge is clipped, not rejected")
    c:free()
end

print("flood fill")
do
    local c = Canvas.new(120, 100)
    -- Closed box drawn as four strokes, and a separate dot outside it.
    c:stroke({ 20, 20, 90, 20, 90, 80, 20, 80, 20, 20 }, 2, 0x000000)
    c:stroke({ 110, 90 }, 2, 0x000000)
    local x, y, w, h = c:floodFill(50, 50, 0x00A000)
    check(px(c, 50, 50) == 0x00A000 and px(c, 25, 75) == 0x00A000, "inside the box is filled")
    check(px(c, 5, 5) == 0xFFFFFF and px(c, 100, 50) == 0xFFFFFF, "outside the box is untouched")
    check(px(c, 20, 50) == 0x000000, "outline is untouched")
    check(x >= 18 and x + w <= 93 and y >= 18 and y + h <= 83, "fill rectangle is the box's interior")
    check(c:floodFill(50, 50, 0x00A000) == nil, "filling with the same colour is a no-op")
    c:floodFill(5, 5, 0xFF8000)
    check(px(c, 5, 5) == 0xFF8000 and px(c, 50, 50) == 0x00A000, "filling outside stops at the outline")
    check(px(c, 110, 90) == 0x000000, "fill goes around other marks")
    c:free()
end

print("undo / redo")
do
    local c = Canvas.new(80, 60)
    local blank = checksum(c)
    c:stroke({ 5, 5, 70, 50 }, 4, 0xFF0000)
    local one = checksum(c)
    c:floodFill(70, 5, 0x0000FF)
    local two = checksum(c)
    check(c:canUndo() and not c:canRedo(), "history after two edits")
    c:undo()
    check(checksum(c) == one, "undo restores the previous state exactly")
    c:undo()
    check(checksum(c) == blank, "second undo restores the blank canvas")
    check(c:undo() == nil, "undo with empty history does nothing")
    c:redo(); c:redo()
    check(checksum(c) == two, "redo replays both edits")
    c:undo()
    c:stroke({ 40, 30 }, 3, 0x000000)
    check(not c:canRedo(), "a new edit discards the redo history")
    c:clear()
    check(px(c, 40, 30) == 0xFFFFFF, "clear wipes to white")
    c:undo()
    check(px(c, 40, 30) == 0x000000, "clear is undoable")
    c:free()
end

print("history budget")
do
    local saved = Canvas.HISTORY_BUDGET
    Canvas.HISTORY_BUDGET = 8 * 50 * 50 * 3   -- room for three full-canvas steps
    local c = Canvas.new(50, 50)
    for _ = 1, 6 do c:clear() end
    check(#c.undo_stack == 3, "oldest steps are dropped beyond the budget")
    check(c.history_bytes == 8 * 50 * 50 * 3, "history byte count stays accurate")
    Canvas.HISTORY_BUDGET = saved
    c:free()
end

print("loading an image")
do
    local Blitbuffer = require("ffi/blitbuffer")
    local img = Blitbuffer.new(30, 200, Blitbuffer.TYPE_BBRGB24)
    img:fill(Blitbuffer.COLOR_WHITE)
    img:paintRectRGB32(0, 0, 30, 10, Canvas.rgb32(0x8000FF))
    local c = Canvas.new(60, 40)
    c:stroke({ 50, 30 }, 3, 0)
    c:load(img)
    check(px(c, 5, 5) == 0x8000FF, "image pixels are copied in")
    check(px(c, 50, 30) == 0xFFFFFF, "area outside a smaller image is white")
    check(not c:canUndo() and not c.modified, "loading starts a fresh history")
    img:free(); c:free()
end

env.finish()
