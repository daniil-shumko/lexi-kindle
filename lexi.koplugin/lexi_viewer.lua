--[[--
Popup that shows the AI answer as HTML (bold labels), rendered like KOReader's dictionary popup.

Same frame / title bar / buttons layout as TextViewer, with a ScrollHtmlWidget in place of the
plain-text area (TextViewer only renders Markdown/HTML from KOReader v2026.07).

@module lexi_viewer
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local AnswerViewer = InputContainer:extend{
    title = nil,
    html = nil,
    css = nil,
    font_size = 20, -- KOReader's default dictionary font size
    buttons_table = nil,
    width = nil,
    height = nil,
}

function AnswerViewer:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.width = self.width or screen_w - Screen:scaleBySize(30)
    -- Tall enough for the usual answer, translations included, without scrolling.
    self.height = self.height or math.floor(screen_h * 0.75)
    self.region = Geom:new{ w = screen_w, h = screen_h }

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapClose = { GestureRange:new{ ges = "tap", range = self.region } },
        }
    end

    self.titlebar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = self.title,
        title_shrink_font_to_fit = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    self.button_table = ButtonTable:new{
        width = self.width - 2 * Size.padding.default,
        buttons = self.buttons_table or {},
        zero_sep = true,
        show_parent = self,
    }

    local padding = Size.padding.large
    self.html_widget = ScrollHtmlWidget:new{
        html_body = self.html,
        css = self.css,
        default_font_size = Screen:scaleBySize(self.font_size),
        width = self.width - 2 * padding,
        height = self.height - self.titlebar:getHeight() - self.button_table:getSize().h - 2 * padding,
        dialog = self,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.titlebar,
            FrameContainer:new{
                padding = padding,
                margin = 0,
                bordersize = 0,
                self.html_widget,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = self.button_table:getSize().h },
                self.button_table,
            },
        },
    }
    -- Let swipes and holds reach the HTML widget (scrolling) instead of moving the window.
    self.movable = MovableContainer:new{
        ignore_events = { "swipe", "hold", "hold_release", "hold_pan", "touch", "pan", "pan_release" },
        self.frame,
    }
    self[1] = WidgetContainer:new{
        align = "center",
        dimen = self.region,
        self.movable,
    }
end

function AnswerViewer:onShow()
    UIManager:setDirty(self, function() return "partial", self.frame.dimen end)
    return true
end

function AnswerViewer:onCloseWidget()
    UIManager:setDirty(nil, function() return "partial", self.frame.dimen end)
end

function AnswerViewer:onTapClose(_, ges_ev)
    if ges_ev.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end

function AnswerViewer:onClose()
    UIManager:close(self)
    return true
end

return AnswerViewer
