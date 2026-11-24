-- Receives a Goodreads session cookie over the local Wi-Fi network from
-- the companion browser extension (browser-extension/ in this project),
-- instead of making you type a long cookie on an e-ink keyboard.
--
-- Opens a small widget showing this device's address and a fresh 4-digit
-- code. On your computer, open the extension while signed in to
-- goodreads.com, type the address and code, and send. The extension POSTs
-- JSON { code, cookie } to this device; a matching code saves the cookie
-- and closes the listener.
--
-- The cookie crosses the network as plain HTTP: fine on a home Wi-Fi you
-- trust, not on a shared or public one.

local socket = require("socket")
local json = require("json")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Button = require("ui/widget/button")
local Font = require("ui/font")
local Size = require("ui/size")
local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")
local T = require("ffi/util").template

local Receiver = {}

Receiver.PORT_FIRST = 8970
Receiver.PORT_TRIES = 5
Receiver.MAX_WRONG_CODES = 5
Receiver.LISTEN_SECONDS = 600 -- 10 minutes

local function fourDigitCode()
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    return string.format("%04d", math.random(0, 9999))
end

-- The device's own LAN address: the local end of a (never-sent) UDP
-- socket aimed at a public, unroutable-for-us address.
local function localAddress()
    local ok, ip = pcall(function()
        local probe = socket.udp()
        probe:setpeername("192.0.2.1", 9)
        local addr = probe:getsockname()
        probe:close()
        return addr
    end)
    if ok and ip and ip ~= "0.0.0.0" then return ip end
    return nil
end

local function respond(client, status, reason, obj)
    local text = json.encode(obj)
    client:send(table.concat({
        "HTTP/1.1 " .. status .. " " .. reason,
        "Content-Type: application/json",
        "Content-Length: " .. #text,
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type",
        -- Chrome's Private Network Access check blocks a request to a
        -- local-network address (like 192.168.x.x) unless the preflight
        -- response says this is expected.
        "Access-Control-Allow-Private-Network: true",
        "Connection: close",
        "", text,
    }, "\r\n"))
end

local function readRequest(client)
    client:settimeout(2)
    local request_line = client:receive("*l")
    if not request_line then return nil end
    local method, path = request_line:match("^(%u+)%s+(%S+)")
    local length = 0
    while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        local len = line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if len then length = tonumber(len) end
    end
    local body = length > 0 and client:receive(length) or ""
    return method, path, body
end

-- One accepted connection. `state` carries the expected code, a running
-- count of wrong tries, and `done` once a cookie has been accepted.
local function handleOne(server, state, on_saved)
    local client = server:accept()
    if not client then return end
    client:settimeout(2)
    local ok, err = pcall(function()
        local method, path, body = readRequest(client)
        if method == "OPTIONS" then
            respond(client, 204, "No Content", {})
        elseif method == "GET" then
            respond(client, 200, "OK", { goodreads_sync = "cookie-receiver" })
        elseif method == "POST" and path == "/cookie" and not state.done then
            local parsed = select(2, pcall(json.decode, body or ""))
            if type(parsed) ~= "table" then
                respond(client, 400, "Bad Request", { ok = false, error = "bad-request" })
            elseif tostring(parsed.code or "") ~= state.code then
                state.tries = (state.tries or 0) + 1
                respond(client, 403, "Forbidden", { ok = false, error = "code",
                    left = math.max(0, Receiver.MAX_WRONG_CODES - state.tries) })
                if state.tries >= Receiver.MAX_WRONG_CODES then state.gave_up = true end
            elseif type(parsed.cookie) ~= "string" or parsed.cookie == "" then
                respond(client, 400, "Bad Request", { ok = false, error = "cookie" })
            else
                state.done = true
                on_saved(parsed.cookie)
                respond(client, 200, "OK", { ok = true })
            end
        else
            respond(client, 404, "Not Found", { ok = false, error = "not-found" })
        end
    end)
    if not ok then logger.warn("Goodreads sync: cookie receiver request failed:", err) end
    pcall(function() client:close() end)
end

-- A plain, self-contained widget: address, code, status line and a Stop
-- button. No custom framework beyond KOReader's own widget library.
local ReceiverWidget = InputContainer:extend{}

function ReceiverWidget:init()
    local pad = Size.padding.large
    local text_width = math.floor(Screen:getWidth() * 0.8)
    local title_face = Font:getFace("tfont", 20)
    local text_face = Font:getFace("cfont", 18)
    self.status_box = TextBoxWidget:new{ text = self.status_text or "", width = text_width, face = text_face }
    local group = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{ text = _("Receive Goodreads cookie"), width = text_width, bold = true, face = title_face },
        VerticalSpan:new{ width = Size.span.vertical_large },
        TextBoxWidget:new{ text = _("Open the Goodreads sync browser extension on your computer and enter:"), width = text_width, face = text_face },
        VerticalSpan:new{ width = Size.span.vertical_default },
        TextBoxWidget:new{ text = T(_("Address: %1"), self.address), width = text_width, bold = true, face = text_face },
        TextBoxWidget:new{ text = T(_("Code: %1"), self.code), width = text_width, bold = true, face = text_face },
        VerticalSpan:new{ width = Size.span.vertical_default },
        self.status_box,
        VerticalSpan:new{ width = Size.span.vertical_large },
        Button:new{
            text = _("Stop"),
            width = math.floor(text_width * 0.4),
            callback = function() self:onStop() end,
        },
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            padding = pad,
            margin = 0,
            radius = Size.radius.window,
            group,
        },
    }
    -- UIManager uses this (not just self[1]'s own size) to know what
    -- screen region to actually paint/refresh; without it, taps still
    -- land correctly (gesture hit-testing walks the widget tree
    -- directly) but nothing visible gets drawn.
    self.dimen = self[1]:getSize()
end

function ReceiverWidget:setStatus(text)
    self.status_text = text
    if self.status_box then
        self.status_box:setText(text)
        UIManager:setDirty(self, "ui")
    end
end

function ReceiverWidget:onStop()
    if self.on_close then self.on_close() end
    -- "full" clears any e-ink ghosting the panel left behind, instead of
    -- whatever lesser refresh UIManager would otherwise pick by default.
    UIManager:close(self, "full")
    return true
end

-- Opens the panel, listens, and calls `on_saved(cookie)` once one
-- arrives. Always call Receiver.stop() when you're done with what this
-- returns (the widget's Stop button already does).
function Receiver.open(on_saved)
    local address = localAddress()
    local server, port
    for p = Receiver.PORT_FIRST, Receiver.PORT_FIRST + Receiver.PORT_TRIES - 1 do
        local s, err = socket.bind("*", p)
        if s then server, port = s, p; break end
    end
    local state = { code = fourDigitCode(), tries = 0 }
    local widget = ReceiverWidget:new{
        address = (address or "?") .. ":" .. (port or "?"),
        code = state.code,
        status_text = server and _("Waiting for the cookie…") or _("Could not open a listening port."),
    }
    -- Shown before anything else below, so the panel (and the code the
    -- reader needs to type) is on screen even if something after this
    -- point goes wrong.
    UIManager:show(widget)
    UIManager:forceRePaint()
    if not server then return widget end
    server:settimeout(0)

    local stopped = false
    local function stop()
        if stopped then return end
        stopped = true
        UIManager:unschedule(widget._poll)
        pcall(function() server:close() end)
    end
    widget.on_close = stop

    local function poll()
        if stopped then return end
        handleOne(server, state, function(cookie)
            on_saved(cookie)
            widget:setStatus(_("Cookie received and saved."))
            UIManager:scheduleIn(2, function() widget:onStop() end)
        end)
        if state.gave_up then
            widget:setStatus(_("Too many wrong codes. Open this again for a new one."))
            stop()
            return
        end
        if stopped then return end
        UIManager:scheduleIn(1, poll)
    end
    widget._poll = poll
    UIManager:scheduleIn(0.5, poll)
    UIManager:scheduleIn(Receiver.LISTEN_SECONDS, function()
        if stopped then return end
        widget:setStatus(_("Stopped listening after 10 minutes. Open this again to try once more."))
        stop()
    end)

    return widget
end

return Receiver
