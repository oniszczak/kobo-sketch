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
local ConfirmBox      = require("ui/widget/confirmbox")
local Event           = require("ui/event")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local Menu            = require("ui/widget/menu")
local Notification    = require("ui/widget/notification")
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
    -- Drawings live in a dot-folder on the Kobo's drive: Nickel's
    -- ExcludeSyncFolders skips those, so PNGs stay off the home screen.
    kobo_root = "/mnt/onboard",
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
    -- Moves any drawings from the old visible folder straight away, so they
    -- leave the Kobo home screen even before the next save.
    local ok, err = pcall(self.drawingsDir, self)
    if not ok then logger.err("coloursketch:", err) end
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
    if not Device:isKobo() then
        local dir = DataStorage:getDataDir() .. "/drawings"
        if lfs.attributes(dir, "mode") ~= "directory" then
            assert(lfs.mkdir(dir), "could not create " .. dir)
        end
        return dir
    end
    local dir = self.kobo_root .. "/.Drawings"
    if lfs.attributes(dir, "mode") ~= "directory" then
        assert(lfs.mkdir(dir), "could not create " .. dir)
    end
    self:moveOldDrawings(dir)
    return dir
end

-- Drawings used to be saved in Drawings/, where Nickel lists them as books.
-- Move them into the hidden folder, and drop the old folder once it's empty.
function ColourSketch:moveOldDrawings(dir)
    local old = self.kobo_root .. "/Drawings"
    if lfs.attributes(old, "mode") ~= "directory" then return end
    local left = 0
    for name in lfs.dir(old) do
        if name ~= "." and name ~= ".." then
            local target = dir .. "/" .. name
            if name:lower():match("%.png$") and not name:match("^%.")
               and not lfs.attributes(target, "mode")
               and os.rename(old .. "/" .. name, target) then
                logger.info("coloursketch: moved", name, "to", dir)
            else
                left = left + 1
            end
        end
    end
    if left == 0 then os.remove(old) end
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

--- A file name from what was typed: trimmed, without ".png", with the
-- characters the Kobo's FAT drive can't store turned into dashes, and no
-- leading dots. nil if nothing is left.
function ColourSketch.cleanName(text)
    local name = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("%.[pP][nN][gG]$", "")
    name = name:gsub('[\\/:*?"<>|%c]', "-"):gsub("^%.+", "")
    name = name:gsub("%s+$", "")
    if name == "" then return nil end
    return name
end

function ColourSketch:writeTo(pad, path, done)
    local ok = self:guard(function()
        local tmp = path .. ".tmp"
        pad.canvas.bb:writePNG(tmp)
        assert(os.rename(tmp, path))
    end)
    if ok then
        pad:saved(path)
        if done then done() end
    end
    return ok
end

--- Save the drawing. A drawing that already has a file is saved over it;
-- otherwise (or for Save as) ask for a name first. done() runs after a
-- successful save, and not at all if the user cancels.
function ColourSketch:save(pad, as_new, done)
    if pad.path and not as_new then
        return self:writeTo(pad, pad.path, done)
    end
    local suggested = pad.path and (pad.path:match("([^/]+)%.[pP][nN][gG]$") .. " copy")
        or os.date("Sketch %Y-%m-%d %H.%M")
    local dialog
    dialog = InputDialog:new{
        title = as_new and _("Save as") or _("Save drawing"),
        input = suggested,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local name = ColourSketch.cleanName(dialog:getInputText())
                    if not name then
                        UIManager:show(Notification:new{ text = _("Please enter a name") })
                        return
                    end
                    UIManager:close(dialog)
                    local path = self:drawingsDir() .. "/" .. name .. ".png"
                    if path ~= pad.path and lfs.attributes(path, "mode") then
                        pad:showOverlay(ConfirmBox:new{
                            text = _("Replace the existing drawing ") .. name .. "?",
                            ok_text = _("Replace"),
                            ok_callback = function() self:writeTo(pad, path, done) end,
                        })
                    else
                        self:writeTo(pad, path, done)
                    end
                end,
            },
        }},
    }
    -- full: the keyboard covers more than the dialog's own box
    pad:showOverlay(dialog, true)
    dialog:onShowKeyboard()
end

function ColourSketch:chooseDrawing(pad)
    local files = self:listDrawings()
    if #files == 0 then
        pad:showOverlay(InfoMessage:new{ text = _("No drawings saved yet.") })
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
    pad:showOverlay(menu, true)
end

return ColourSketch
