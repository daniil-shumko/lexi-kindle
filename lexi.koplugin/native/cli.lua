--[[--
Lexi outside KOReader, for native/lexi.sh (the library scriptlets). Run from /mnt/us/koreader with
KOReader's LuaJIT: ./luajit plugins/lexi.koplugin/native/cli.lua <command>

  status   print a one-line summary of the settings
  setup    set up from a phone: a QR code in Lexi's window over the Kindle UI (native/ui.lua) and a
           temporary web page (lexi_setup.lua)

Prints one line: the result message.
--]]

require("setupkoenv")
local PLUGIN = "plugins/lexi.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path
-- socketutil reads Device.model; the real device module would take over the screen.
package.loaded["device"] = { model = "lexi-cli" }

local LuaSettings = require("luasettings")
local ffiutil = require("ffi/util")
local qrencode = require("ffi/qrencode")
local rapidjson = require("rapidjson")
local Config = require("lexi_config")
local Setup = require("lexi_setup")

-- The running phone setup (lexi.sh stops an older one), and where its window's events land.
local SETUP_PID_FILE = "/var/run/lexi-setup.pid"
local SETUP_EVENT_FILE = "/var/run/lexi-setup.event"
-- How long an error stays up when nobody taps Close.
local ERROR_TIMEOUT_S = 60

local function loadConfig()
    local defaults = Config.loadFile(PLUGIN .. "/config.lua")
    return Config.new(LuaSettings:open("settings/lexi.lua"), defaults)
end

-- QR modules as strings of "1" (dark) and "0", one per row.
local function qrRows(text)
    local ok, matrix = qrencode.qrcode(text)
    if not ok then return nil end
    local rows = {}
    for y = 1, #matrix do
        local row = {}
        for x = 1, #matrix do row[x] = matrix[x][y] > 0 and "1" or "0" end
        rows[y] = table.concat(row)
    end
    return rows
end

-- Lexi's window with setup.html. Its events (the Close button) go to a file we poll. lexi.sh
-- ignores SIGPIPE for us, so a window that went away only fails the write.
local Window = {}
Window.__index = Window

function Window.open()
    os.remove(SETUP_EVENT_FILE)
    local pipe = io.popen("exec ./luajit " .. PLUGIN .. "/native/ui.lua setup > " .. SETUP_EVENT_FILE, "w")
    return setmetatable({ pipe = pipe }, Window)
end

function Window:show(params)
    if not self.pipe then return end
    if not (self.pipe:write(rapidjson.encode(params), "\n") and self.pipe:flush()) then
        pcall(self.pipe.close, self.pipe)
        self.pipe = nil
    end
end

function Window:closedByUser()
    local f = io.open(SETUP_EVENT_FILE, "r")
    if not f then return false end
    local text = f:read("*a")
    f:close()
    return text ~= nil and text ~= ""
end

-- Leaves an error up until Close is tapped or ERROR_TIMEOUT_S passes.
function Window:waitForClose()
    for _ = 1, ERROR_TIMEOUT_S * 2 do
        if self:closedByUser() then return end
        ffiutil.usleep(500000)
    end
end

-- Closing its input makes the window exit.
function Window:close()
    if self.pipe then pcall(self.pipe.close, self.pipe) end
    self.pipe = nil
    os.remove(SETUP_EVENT_FILE)
end

local function setup(config)
    -- Opened before the server socket exists, so the window can't inherit it.
    local window = Window.open()
    local ip = Setup.localAddress()
    if not ip then
        window:show{ mode = "error", text = "Turn on Wi-Fi first, then choose Set up from phone again." }
        window:waitForClose()
        window:close()
        return "Wi-Fi is off"
    end
    local server, err = Setup.start{ config = config }
    if not server then
        window:show{ mode = "error", text = "Couldn't start setup: " .. tostring(err) }
        window:waitForClose()
        window:close()
        return "Setup failed: " .. tostring(err)
    end
    local url = server:url(ip)
    window:show{ mode = "setup", url = url, code = server.state.code, port = server.port, qr = qrRows(url) }
    -- Whatever happens, the port and the firewall rule are cleaned up afterwards.
    local ok, outcome = pcall(function()
        local result
        repeat
            result = server:poll(1)
            if not result and window:closedByUser() then result = "closed" end
        until result
        return result
    end)
    server:stop()
    if not ok then
        window:show{ ifOpen = true, mode = "error", text = "Setup stopped because of an error." }
        window:waitForClose()
        window:close()
        return "Setup failed: " .. tostring(outcome)
    elseif outcome == "saved" then
        window:show{ ifOpen = true, mode = "saved", text = Setup.summary(config, false) }
        ffiutil.sleep(6)
        window:close()
        return "Saved: " .. Setup.summary(config, false)
    end
    window:close()
    return outcome == "expired" and "Setup timed out" or "Setup closed"
end

local command = arg[1]
local config = loadConfig()
if command == "status" then
    print(Setup.summary(config, false))
elseif command == "setup" then
    local f = io.open(SETUP_PID_FILE, "w")
    if f then
        -- $PPID of a child shell is this process.
        local p = io.popen("echo $PPID")
        f:write((p and p:read("*l") or ""), "\n")
        if p then p:close() end
        f:close()
    end
    print(setup(config))
    os.remove(SETUP_PID_FILE)
else
    io.stderr:write("Usage: cli.lua status | setup\n")
    os.exit(2)
end
