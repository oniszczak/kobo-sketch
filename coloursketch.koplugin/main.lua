--[[--
Colour Sketch: a finger-drawing pad for colour e-ink Kobos.

Opens from KOReader's Tools menu, or straight from NickelMenu: the NickelMenu
entry touches LAUNCH_FLAG before starting KOReader, and this plugin opens the
pad when it sees a fresh flag. Opened that way, leaving the pad exits
KOReader back to Nickel.

@module koplugin.coloursketch
--]]--

local DataStorage     = require("datastorage")
local Device          = require("device")
local Event           = require("ui/event")
local InfoMessage     = require("ui/widget/infomessage")
local Menu            = require("ui/widget/menu")
local RenderImage     = require("ui/renderimage")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local _               = require("gettext")

local plugin_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
package.path = plugin_dir .. "?.lua;" .. package.path

local Pad = require("coloursketch.pad")

local LAUNCH_FLAG = "/tmp/coloursketch.launch"
local LAUNCH_MAX_AGE = 120   -- seconds; an older flag is stale (KOReader failed to start)

local ColourSketch = WidgetContainer:extend{
    name = "coloursketch",
    is_doc_only = false,
}

function ColourSketch:init()
    self.ui.menu:registerToMainMenu(self)
    self:checkLaunchFlag()
end

-- Run fn, reporting any error as a message rather than crashing KOReader.
function ColourSketch:guard(fn)
    local ok, err = pcall(fn)
    if not ok then
        logger.err("coloursketch:", err)
        UIManager:show(InfoMessage:new{
            text = _("Colour Sketch error:\n") .. tostring(err),
        })
    end
    return ok
end

function ColourSketch:addToMainMenu(menu_items)
    menu_items.coloursketch = {
        text = _("Colour sketch"),
        sorting_hint = "more_tools",
        callback = function() self:guard(function() self:openPad(false) end) end,
    }
end

function ColourSketch:checkLaunchFlag()
    local mtime = lfs.attributes(LAUNCH_FLAG, "modification")
    if not mtime then return end
    os.remove(LAUNCH_FLAG)
    if os.time() - mtime > LAUNCH_MAX_AGE then return end
    -- Next tick: the file manager or reader is shown after plugins init.
    UIManager:nextTick(function()
        self:guard(function() self:openPad(true) end)
    end)
end

function ColourSketch:openPad(from_nickel)
    local pad = Pad:new{
        exit_label = from_nickel and _("Exit to Kobo") or _("Close"),
        actions = {
            guard = function(fn) return self:guard(fn) end,
            save = function(p, as_new) return self:save(p, as_new) end,
            open = function(p) self:chooseDrawing(p) end,
            exit = function()
                if from_nickel then
                    UIManager:nextTick(function() UIManager:broadcastEvent(Event:new("Exit")) end)
                end
            end,
        },
    }
    UIManager:show(pad, "full", nil, nil, nil, true)
end

-- files ------------------------------------------------------------------

function ColourSketch:drawingsDir()
    local dir = Device:isKobo() and "/mnt/onboard/Drawings" or (DataStorage:getDataDir() .. "/drawings")
    if lfs.attributes(dir, "mode") ~= "directory" then
        assert(lfs.mkdir(dir), "could not create " .. dir)
    end
    return dir
end

function ColourSketch:listDrawings()
    local dir = self:drawingsDir()
    local files = {}
    -- lfs.dir returns an iterator *and* a handle; the for-in keeps both.
    for name in lfs.dir(dir) do
        if name:lower():match("%.png$") and not name:match("^%._") then
            local path = dir .. "/" .. name
            files[#files + 1] = { name = name, path = path, mtime = lfs.attributes(path, "modification") or 0 }
        end
    end
    table.sort(files, function(a, b) return a.mtime > b.mtime end)
    return files
end

function ColourSketch:newPath()
    local base = self:drawingsDir() .. os.date("/sketch-%Y%m%d-%H%M%S")
    local path, n = base .. ".png", 1
    while lfs.attributes(path, "mode") do
        n = n + 1
        path = base .. "-" .. n .. ".png"
    end
    return path
end

-- Returns true on success.
function ColourSketch:save(pad, as_new)
    local path
    local ok = self:guard(function()
        path = (not as_new and pad.path) or self:newPath()
        local tmp = path .. ".tmp"
        pad.canvas.bb:writePNG(tmp)
        assert(os.rename(tmp, path))
    end)
    if ok then pad:saved(path) end
    return ok
end

function ColourSketch:chooseDrawing(pad)
    local files = self:listDrawings()
    if #files == 0 then
        UIManager:show(InfoMessage:new{ text = _("No drawings saved yet.") })
        return
    end
    local menu
    local items = {}
    for _, f in ipairs(files) do
        items[#items + 1] = {
            text = f.name,
            mandatory = os.date("%Y-%m-%d %H:%M", f.mtime),
            callback = function()
                self:guard(function()
                    local image = RenderImage:renderImageFile(f.path, false)
                    if not image then error("could not read " .. f.name) end
                    pad:loadImage(image, f.path)
                    image:free()
                end)
            end,
        }
    end
    menu = Menu:new{
        title = _("Open drawing"),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

return ColourSketch
