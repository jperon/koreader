local Cache = require("cache")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Input = Device.input
local Screen = Device.screen
local T = require("ffi/util").template

local ReaderZooming = InputContainer:new{
    zoom = 1.0,
    available_zoom_modes = {
        content = "content",
        contentwidth = "contentwidth",
        contentheight = "contentheight",
        column = "column",
        pagewidth = "pagewidth",
        pageheight = "pageheight",
        page = "page",
        pan = "pan",
    },
    -- default to nil so we can trigger ZoomModeUpdate events on start up
    zoom_mode = nil,
    DEFAULT_ZOOM_MODE = "pagewidth",
    -- for column or pan modes: fit to width/zoom_factor,
    -- with overlap of zoom_pan_h_overlap % (horizontally)
    -- and zoom_pan_v_overlap % (vertically).
    -- In column mode, zoom_factor is the number of columns.
    zoom_factor = 2,
    zoom_pan_h_overlap = 40,
    zoom_pan_v_overlap = 40,
    zoom_pan_right_to_left = nil,  -- true for right-to-left
    zoom_pan_bottom_to_top = nil,  -- true for bottom-to-top
    zoom_pan_direction_vertical = nil, -- true for column mode
    current_page = 1,
    rotation = 0,
    paged_modes = {
        page = _("Zoom to fit page works best with page view."),
        pageheight = _("Zoom to fit page height works best with page view."),
        contentheight = _("Zoom to fit content height works best with page view."),
        content = _("Zoom to fit content works best with page view."),
    },
    panned_modes = {
        column = _("Page view normally works best with column zoom mode."),
        pan = _("Pan zoom only works in page view."),
    }
}

function ReaderZooming:init()
    if Device:hasKeyboard() then
        self.key_events = {
            ZoomIn = {
                { "Shift", Input.group.PgFwd },
                doc = "zoom in",
                event = "Zoom", args = "in"
            },
            ZoomOut = {
                { "Shift", Input.group.PgBack },
                doc = "zoom out",
                event = "Zoom", args = "out"
            },
            ZoomToFitPage = {
                { "A" },
                doc = "zoom to fit page",
                event = "SetZoomMode", args = "page"
            },
            ZoomToFitContent = {
                { "Shift", "A" },
                doc = "zoom to fit content",
                event = "SetZoomMode", args = "content"
            },
            ZoomToFitPageWidth = {
                { "S" },
                doc = "zoom to fit page width",
                event = "SetZoomMode", args = "pagewidth"
            },
            ZoomToFitContentWidth = {
                { "Shift", "S" },
                doc = "zoom to fit content width",
                event = "SetZoomMode", args = "contentwidth"
            },
            ZoomToFitPageHeight = {
                { "D" },
                doc = "zoom to fit page height",
                event = "SetZoomMode", args = "pageheight"
            },
            ZoomToFitContentHeight = {
                { "Shift", "D" },
                doc = "zoom to fit content height",
                event = "SetZoomMode", args = "contentheight"
            },
            ZoomToFitColumn = {
                { "Shift", "C" },
                doc = "zoom to fit column",
                event = "SetZoomMode", args = "colu"
            },
            ZoomToFitLines = {
                { "Shift", "H" },
                doc = "pan zoom",
                event = "SetZoomMode", args = "pan"
            },
        }
    end
    self.ui.menu:registerToMainMenu(self)
end

function ReaderZooming:onReadSettings(config)
    local zoom_mode = config:readSetting("zoom_mode") or
                    G_reader_settings:readSetting("zoom_mode") or
                    self.DEFAULT_ZOOM_MODE
    self:setZoomMode(zoom_mode, true) -- avoid informative message on load
    for _, setting in ipairs{
            "zoom_factor",
            "zoom_pan_h_overlap",
            "zoom_pan_v_overlap",
            "zoom_pan_right_to_left",
            "zoom_pan_bottom_to_top",
            "zoom_pan_direction_vertical",
    } do
        self[setting] = config:readSetting(setting) or
                        G_reader_settings:readSetting(setting) or
                        self[setting]
    end
end

function ReaderZooming:onSaveSettings()
    self.ui.doc_settings:saveSetting("zoom_mode", self.orig_zoom_mode or self.zoom_mode)
    for _, setting in ipairs{
            "zoom_factor",
            "zoom_pan_h_overlap",
            "zoom_pan_v_overlap",
            "zoom_pan_right_to_left",
            "zoom_pan_bottom_to_top",
            "zoom_pan_direction_vertical",
    } do
        self.ui.doc_settings:saveSetting(setting, self[setting])
    end
end

function ReaderZooming:onSpread(arg, ges)
    if ges.direction == "horizontal" then
        self:genSetZoomModeCallBack("contentwidth")()
    elseif ges.direction == "vertical" then
        self:genSetZoomModeCallBack("contentheight")()
    elseif ges.direction == "diagonal" then
        self:genSetZoomModeCallBack("content")()
    end
    return true
end

function ReaderZooming:onPinch(arg, ges)
    if ges.direction == "diagonal" then
        self:genSetZoomModeCallBack("page")()
    elseif ges.direction == "horizontal" then
        self:genSetZoomModeCallBack("pagewidth")()
    elseif ges.direction == "vertical" then
        self:genSetZoomModeCallBack("pageheight")()
    end
    return true
end

function ReaderZooming:onToggleFreeZoom(arg, ges)
    if self.zoom_mode ~= "free" then
        self.orig_zoom = self.zoom
        local xpos, ypos
        self.zoom, xpos, ypos = self:getRegionalZoomCenter(self.current_page, ges.pos)
        logger.info("zoom center", self.zoom, xpos, ypos)
        self.ui:handleEvent(Event:new("SetZoomMode", "free"))
        if xpos == nil or ypos == nil then
            xpos = ges.pos.x * self.zoom / self.orig_zoom
            ypos = ges.pos.y * self.zoom / self.orig_zoom
        end
        self.view:SetZoomCenter(xpos, ypos)
    else
        self.ui:handleEvent(Event:new("SetZoomMode", "page"))
    end
end

function ReaderZooming:onSetDimensions(dimensions)
    -- we were resized
    self.dimen = dimensions
    self:setZoom()
end

function ReaderZooming:onRestoreDimensions(dimensions)
    -- we were resized
    self.dimen = dimensions
    self:setZoom()
end

function ReaderZooming:onRotationUpdate(rotation)
    self.rotation = rotation
    self:setZoom()
end

function ReaderZooming:onZoom(direction)
    logger.info("zoom", direction)
    if direction == "in" then
        self.zoom = self.zoom * 1.333333
    elseif direction == "out" then
        self.zoom = self.zoom * 0.75
    end
    logger.info("zoom is now at", self.zoom)
    self:onSetZoomMode("free")
    self.view:onZoomUpdate(self.zoom)
    return true
end

function ReaderZooming:onSetZoomMode(new_mode)
    self.view.zoom_mode = new_mode
    if self.zoom_mode ~= new_mode then
        logger.info("setting zoom mode to", new_mode)
        self.ui:handleEvent(Event:new("ZoomModeUpdate", new_mode))
        self.zoom_mode = new_mode
        self:setZoom()
        self.ui:handleEvent(Event:new("InitScrollPageStates", new_mode))
    end
end

function ReaderZooming:onPageUpdate(new_page_no)
    self.current_page = new_page_no
    self:setZoom()
end

function ReaderZooming:onReZoom(font_size)
    if self.document.is_reflowable then
        local reflowable_font_size = self.document:convertKoptToReflowableFontSize(font_size)
        self.document:layoutDocument(reflowable_font_size)
    end
    self:setZoom()
    self.ui:handleEvent(Event:new("InitScrollPageStates"))
    return true
end

function ReaderZooming:onEnterFlippingMode(zoom_mode)
    if Device:isTouchDevice() then
        self.ges_events = {
            Spread = {
                GestureRange:new{
                    ges = "spread",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(),
                        h = Screen:getHeight(),
                    }
                }
            },
            Pinch = {
                GestureRange:new{
                    ges = "pinch",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(),
                        h = Screen:getHeight(),
                    }
                }
            },
            ToggleFreeZoom = {
                GestureRange:new{
                    ges = "double_tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(),
                        h = Screen:getHeight(),
                    }
                }
            },
        }
    end

    self.orig_zoom_mode = self.zoom_mode
    if zoom_mode == "free" then
        self.ui:handleEvent(Event:new("SetZoomMode", "page"))
    else
        self.ui:handleEvent(Event:new("SetZoomMode", zoom_mode))
    end
end

function ReaderZooming:onExitFlippingMode(zoom_mode)
    if Device:isTouchDevice() then
        self.ges_events = {}
    end
    self.orig_zoom_mode = nil
    self.ui:handleEvent(Event:new("SetZoomMode", zoom_mode))
end

function ReaderZooming:getZoom(pageno)
    -- check if we're in bbox mode and work on bbox if that's the case
    local zoom = nil
    local page_size = self.ui.document:getNativePageDimensions(pageno)
    if self.zoom_mode == "content"
    or self.zoom_mode == "contentwidth"
    or self.zoom_mode == "contentheight"
    or self.zoom_mode == "column"
    or self.zoom_mode == "pan" then
        local ubbox_dimen = self.ui.document:getUsedBBoxDimensions(pageno, 1)
        -- if bbox is larger than the native page dimension render the full page
        -- See discussion in koreader/koreader#970.
        if ubbox_dimen.w <= page_size.w and ubbox_dimen.h <= page_size.h then
            page_size = ubbox_dimen
            self.view:onBBoxUpdate(ubbox_dimen)
        else
            self.view:onBBoxUpdate(nil)
        end
    else
        -- otherwise, operate on full page, but throw debug message
        logger.dbg("ReaderZooming: zoom_mode unknown, which should never occur")
        self.view:onBBoxUpdate(nil)
    end
    -- calculate zoom value:
    local zoom_w = self.dimen.w
    local zoom_h = self.dimen.h
    if self.ui.view.footer_visible and not self.ui.view.footer.settings.reclaim_height then
        zoom_h = zoom_h - self.ui.view.footer:getHeight()
    end
    if self.rotation % 180 == 0 then
        -- No rotation or rotated by 180 degrees
        zoom_w = zoom_w / page_size.w
        zoom_h = zoom_h / page_size.h
    else
        -- rotated by 90 or 270 degrees
        zoom_w = zoom_w / page_size.h
        zoom_h = zoom_h / page_size.w
    end
    if self.zoom_mode == "content" or self.zoom_mode == "page" then
        if zoom_w < zoom_h then
            zoom = zoom_w
        else
            zoom = zoom_h
        end
    elseif self.zoom_mode == "contentwidth" or self.zoom_mode == "pagewidth" then
        zoom = zoom_w
    elseif self.zoom_mode == "pan" or self.zoom_mode == "column" then
        local zoom_factor = self.ui.doc_settings:readSetting("zoom_factor")
                            or G_reader_settings:readSetting("zoom_factor")
                            or self.zoom_factor
        zoom = zoom_w * zoom_factor
    elseif self.zoom_mode == "contentheight" or self.zoom_mode == "pageheight" then
        zoom = zoom_h
    elseif self.zoom_mode == "free" then
        zoom = self.zoom
    end
    if zoom and zoom > 10 and not Cache:willAccept(zoom * (self.dimen.w * self.dimen.h + 64)) then
        logger.dbg("zoom too large, adjusting")
        while not Cache:willAccept(zoom * (self.dimen.w * self.dimen.h + 64)) do
            if zoom > 100 then
                zoom = zoom - 50
            elseif zoom > 10 then
                zoom = zoom - 5
            elseif zoom > 1 then
                zoom = zoom - 0.5
            elseif zoom > 0.1 then
                zoom = zoom - 0.05
            else
                zoom = zoom - 0.005
            end
            logger.dbg("new zoom: "..zoom)

            if zoom < 0 then return 0 end
        end
    end
    return zoom
end

function ReaderZooming:getRegionalZoomCenter(pageno, pos)
    local p_pos = self.view:getSinglePagePosition(pos)
    local page_size = self.ui.document:getNativePageDimensions(pageno)
    local pos_x = p_pos.x / page_size.w
    local pos_y = p_pos.y / page_size.h
    local block = self.ui.document:getPageBlock(pageno, pos_x, pos_y)
    local margin = self.ui.document.configurable.page_margin * Screen:getDPI()
    if block then
        local zoom = self.dimen.w / page_size.w / (block.x1 - block.x0)
        zoom = zoom/(1 + 3*margin/zoom/page_size.w)
        local xpos = (block.x0 + block.x1)/2 * zoom * page_size.w
        local ypos = p_pos.y / p_pos.zoom * zoom
        return zoom, xpos, ypos
    end
    local zoom = 2*self.dimen.w / page_size.w
    return zoom/(1 + 3*margin/zoom/page_size.w)
end

function ReaderZooming:setZoom()
    if not self.dimen then
        self.dimen = self.ui.dimen
    end
    self.zoom = self:getZoom(self.current_page)
    self.ui:handleEvent(Event:new("ZoomUpdate", self.zoom))
end

function ReaderZooming:genSetZoomModeCallBack(mode)
    return function()
        self:setZoomMode(mode)
    end
end

function ReaderZooming:setZoomMode(mode, no_warning)
    mode = self.available_zoom_modes[mode] or self.DEFAULT_ZOOM_MODE
    if not no_warning and self.ui.view.page_scroll then
        local message
        if self.paged_modes[mode] then
            message = T(_([[
%1

In combination with continuous view (scroll mode), this can cause unexpected vertical shifts when turning pages.]]),
                self.paged_modes[mode])
        elseif self.panned_modes[mode] then
            message = T(_([[
%1

You should enable it instead of continuous view (scroll mode).]]),
                self.panned_modes[mode])
        end
        if message then
            UIManager:show(InfoMessage:new{text = message, timeout = 5})
        end
    end

    self.ui:handleEvent(Event:new("SetZoomMode", mode))
    self.ui:handleEvent(Event:new("InitScrollPageStates"))
end

function ReaderZooming:addToMainMenu(menu_items)
    if self.ui.document.info.has_pages then
        local function getZoomModeMenuItem(text, mode, separator)
            return {
                text_func = function()
                    local default_zoom_mode = G_reader_settings:readSetting("zoom_mode") or self.DEFAULT_ZOOM_MODE
                    return text .. (mode == default_zoom_mode and "   ★" or "")
                end,
                checked_func = function()
                    return self.zoom_mode == mode
                end,
                callback = self:genSetZoomModeCallBack(mode),
                hold_callback = function(touchmenu_instance)
                    self:makeDefault(mode, touchmenu_instance)
                end,
                separator = separator,
            }
        end
        local function zoomFactorMenuItem(text, title_text)
            return {
                text = text,
                callback = function(touchmenu_instance)
                    local items = SpinWidget:new{
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self.zoom_factor,
                        value_min = self.zoom_mode == "column" and 2 or 1.5,
                        value_max = 10,
                        value_step = self.zoom_mode == "column" and 1 or 0.1,
                        value_hold_step = 1,
                        precision = "%.1f",
                        ok_text = title_text,
                        title_text = title_text,
                        callback = function(spin)
                            self.zoom_factor = spin.value
                            local update_args = {zoom_factor = spin.value}
                            if self.zoom_mode == "column" then
                                self.zoom_pan_direction_vertical = true
                                self.zoom_pan_h_overlap = 0
                                update_args.zoom_pan_direction_vertical = true
                                update_args.zoom_pan_h_overlap = 0
                            end
                            self.ui:handleEvent(Event:new("ZoomPanUpdate", update_args))
                            self.ui:handleEvent(Event:new("RedrawCurrentPage"))
                        end
                    }
                    UIManager:show(items)
                end
            }
        end
        local function getZoomPanMenuItem(text, setting, separator)
            return {
                text = text,
                separator = separator,
                callback = function(touchmenu_instance)
                    local items = SpinWidget:new{
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self[setting],
                        value_min = 0,
                        value_max = 90,
                        value_step = 1,
                        value_hold_step = 10,
                        ok_text = _("Set"),
                        title_text = text,
                        callback = function(spin)
                            self[setting] = spin.value
                            self.ui:handleEvent(Event:new("ZoomPanUpdate", {[setting] = spin.value}))
                            self.ui:handleEvent(Event:new("RedrawCurrentPage"))
                        end
                    }
                    UIManager:show(items)
                end
            }
        end
        local function getZoomPanCheckboxItem(text, setting, separator)
            return {
                text = text,
                checked_func = function()
                    return self[setting] == true
                end,
                callback = function()
                    self[setting] = not self[setting]
                    self.ui:handleEvent(Event:new("ZoomPanUpdate", {[setting] = self[setting]}))
                end,
                hold_callback = function(touchmenu_instance)
                    G_reader_settings:saveSetting(setting, self[setting])
                end,
                separator = separator,
            }
        end
        menu_items.switch_zoom_mode = {
            text = _("Switch zoom mode"),
            enabled_func = function()
                return self.ui.document.configurable.text_wrap ~= 1
            end,
            sub_item_table = {
                getZoomModeMenuItem(_("Zoom to fit content width"), "contentwidth"),
                getZoomModeMenuItem(_("Zoom to fit content height"), "contentheight", true),
                getZoomModeMenuItem(_("Zoom to fit page width"), "pagewidth"),
                getZoomModeMenuItem(_("Zoom to fit page height"), "pageheight", true),
                getZoomModeMenuItem(_("Zoom to fit content"), "content"),
                getZoomModeMenuItem(_("Zoom to fit page"), "page", true),
                getZoomModeMenuItem(_("Zoom to fit column"), "column"),
                getZoomModeMenuItem(_("Pan zoom"), "pan"),
                {
                    text_func = function()
                        return self.zoom_mode == "column" and _("Column settings") or _("Pan zoom settings")
                    end,
                    enabled_func = function()
                        return self.zoom_mode == "column" or self.zoom_mode == "pan"
                    end,
                    sub_item_table_func = function()
                        if self.zoom_mode == "pan" then
                            return {
                                zoomFactorMenuItem(_("Zoom factor"), _("Set zoom factor")),
                                getZoomPanMenuItem(_("Horizontal overlap"), "zoom_pan_h_overlap"),
                                getZoomPanMenuItem(_("Vertical overlap"), "zoom_pan_v_overlap"),
                                getZoomPanCheckboxItem(_("Column mode"), "zoom_pan_direction_vertical"),
                                getZoomPanCheckboxItem(_("Right to left"), "zoom_pan_right_to_left"),
                                getZoomPanCheckboxItem(_("Bottom to top"), "zoom_pan_bottom_to_top"),
                            }
                        else
                            return {
                                zoomFactorMenuItem(_("Column number"), _("Set column number")),
                                getZoomPanMenuItem(_("Vertical overlap"), "zoom_pan_v_overlap"),
                                getZoomPanCheckboxItem(_("Right to left"), "zoom_pan_right_to_left"),
                                getZoomPanCheckboxItem(_("Bottom to top"), "zoom_pan_bottom_to_top"),
                            }
                        end
                    end
                }
            }
        }
    end
end

function ReaderZooming:makeDefault(zoom_mode, touchmenu_instance)
    UIManager:show(ConfirmBox:new{
        text = T(
            _("Set default zoom mode to %1?"),
            zoom_mode
        ),
        ok_callback = function()
            G_reader_settings:saveSetting("zoom_mode", zoom_mode)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

return ReaderZooming
