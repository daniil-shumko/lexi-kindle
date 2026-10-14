--[[--
JSON-over-HTTPS POST using KOReader's bundled LuaSocket/LuaSec and rapidjson.

Meant to run inside a Trapper subprocess: it blocks until the response arrives or times out.

@module lexi_http
--]]

local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local Tls = require("lexi_tls")

local Http = {}

-- Seconds without any data, and for the whole request (a thinking model may take a while).
local BLOCK_TIMEOUT = 30
local TOTAL_TIMEOUT = 120

-- KOReader's LuaSec defaults to verify = "none". Check the server's certificate chain against the
-- CA bundle KOReader ships (relative to its folder, the working directory), and that the
-- certificate is for the host we asked for, so API keys only go to the real provider.
local CA_BUNDLE = "data/ca-bundle.crt"

local function caBundlePresent()
    local f = io.open(CA_BUNDLE, "r")
    if not f then return false end
    f:close()
    return true
end

-- LuaSec's socket factory with a host-name check after the handshake (LuaSec only checks the chain).
-- socket.http uses a request's own `create` when it has one.
local function verifyingCreate(request)
    local https = require("ssl.https")
    local new_conn = https.tcp(request)
    return function()
        local conn = new_conn()
        local connect = conn.connect
        function conn:connect(host, port)
            connect(self, host, port)
            local cert = self.sock:getpeercertificate()
            if not (cert and Tls.certValidFor(cert, host)) then
                self.sock:close()
                socket.try(nil, "certificate is not valid for " .. host)
            end
            return 1
        end
        return conn
    end
end

--[[--
POSTs `body` as JSON.

@treturn table { ok = bool, status = number|nil, data = decoded JSON table|nil, err = string|nil }
--]]
function Http.postJSON(url, headers, body)
    local ok_enc, payload = pcall(rapidjson.encode, body)
    if not ok_enc or not payload then
        return { ok = false, err = "Cannot encode request: " .. tostring(payload) }
    end

    local request_headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#payload),
        ["Accept"] = "application/json",
    }
    for k, v in pairs(headers or {}) do
        -- A line break in a value (say, a pasted workspace ID) would inject extra headers.
        if tostring(v):find("%c") then return { ok = false, err = "Invalid value for " .. k .. "." } end
        request_headers[k] = v
    end

    local request = {
        url = url,
        method = "POST",
        headers = request_headers,
        source = ltn12.source.string(payload),
    }
    if url:match("^https://") then
        if not caBundlePresent() then
            return { ok = false, err = "Cannot verify HTTPS: " .. CA_BUNDLE .. " is missing from KOReader." }
        end
        -- LuaSec takes its TLS settings from the request table.
        request.verify = "peer"
        request.cafile = CA_BUNDLE
        request.create = verifyingCreate(request)
    end

    local sink = {}
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    request.sink = socketutil.table_sink(sink)
    local ok_request, first, code, _, status = pcall(http.request, request)
    socketutil:reset_timeout()
    if not ok_request then code, status = "error", tostring(first) end

    if type(code) ~= "number" then
        -- DNS, TLS and timeout failures come back as a string code instead of an HTTP status.
        logger.warn("lexi: request failed:", url, code, status)
        return { ok = false, err = "Network error: " .. tostring(status or code) }
    end

    local raw = table.concat(sink)
    local data
    if raw ~= "" then
        local ok_dec, decoded = pcall(rapidjson.decode, raw)
        if ok_dec and type(decoded) == "table" then data = decoded end
    end

    if code < 200 or code >= 300 then
        logger.warn("lexi: HTTP", code, url, raw:sub(1, 500))
        return { ok = false, status = code, data = data, err = string.format("HTTP %d %s", code, raw:sub(1, 200)) }
    end
    if not data then
        return { ok = false, status = code, err = "Response is not valid JSON." }
    end
    return { ok = true, status = code, data = data }
end

return Http
