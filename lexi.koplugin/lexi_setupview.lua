--[[--
"Set up from phone" screen in KOReader: QR code, address and code for the page lexi_setup.lua
serves, with a Stop button. Closing it stops the page (on_close).

@module lexi_setupview
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local T = require("ffi/util").template
local _ = require("gettext")
local Screen = Device.screen

local SetupView = InputContainer:extend{
    url = nil,
    code = nil,
    on_close = nil,
}

function SetupView:init()
    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.86)
    local inner = width - 2 * Size.padding.large
    local function text(str, face, bold)
        return TextBoxWidget:new{ text = str, face = face, bold = bold, width = inner, alignment = "center" }
    end
    local qr_size = math.floor(inner * 0.62)
    local close = Button:new{
        text = _("Stop"),
        width = math.floor(inner * 0.5),
        callback = function() self:onClose() end,
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.large,
        VerticalGroup:new{
            align = "center",
            text(_("Set up Lexi from your phone"), Font:getFace("tfont", 22), true),
            VerticalSpan:new{ width = Size.span.vertical_large },
            text(_("Scan with your phone's camera, then paste your API key and pick a model."), Font:getFace("cfont", 18)),
            VerticalSpan:new{ width = Size.span.vertical_large },
            QRWidget:new{ text = self.url, width = qr_size, height = qr_size },
            VerticalSpan:new{ width = Size.span.vertical_large },
            text(_("Or open this address on a device on the same Wi-Fi:"), Font:getFace("cfont", 16)),
            text(self.url, Font:getFace("cfont", 18), true),
            text(T(_("Code: %1"), self.code), Font:getFace("cfont", 18)),
            VerticalSpan:new{ width = Size.span.vertical_default },
            text(_("Use Wi-Fi you trust, not public Wi-Fi."), Font:getFace("cfont", 14)),
            VerticalSpan:new{ width = Size.span.vertical_large },
            close,
        },
    }
    self[1] = CenterContainer:new{ dimen = Screen:getSize(), self.frame }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    -- Swallow taps outside the frame instead of passing them to the book underneath.
    self.ges_events.TapOutside = { GestureRange:new{ ges = "tap", range = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() } } }
end

function SetupView:onTapOutside() return true end

function SetupView:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function SetupView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

function SetupView:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

return SetupView
