local Device = require("device")
local EventListener = require("ui/widget/eventlistener")
local QRMessage = require("ui/widget/qrmessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local QRHighlight = EventListener:new{
    name = "qrhighlight",
    is_doc_only = true,
}

function QRHighlight:init()
    self.ui.highlight:addToHighlightDialog("qrhighlight_QR", function(o)
        return {
            text = _("QR"),
            enabled = Device:hasClipboard(),
            callback = function()
                UIManager:show(QRMessage:new{
                    text = o.selected_text.text,
                    width = Device.screen:getWidth(),
                    height = Device.screen:getHeight()
                })
                o:onClose()
            end,
        }
    end)
end

return QRHighlight
