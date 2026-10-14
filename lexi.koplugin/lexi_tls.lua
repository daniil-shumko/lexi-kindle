--[[--
Host-name check for HTTPS certificates. LuaSec verifies the certificate chain but not that the
certificate belongs to the host we connected to, so lexi_http.lua calls this after the handshake.

Pure Lua: works on any object with LuaSec's cert:extensions() / cert:subject() shape.

@module lexi_tls
--]]

local Tls = {}

--- RFC 6125-style match: exact, or "*.example.com" covering exactly one leftmost label.
function Tls.hostMatches(host, pattern)
    if type(host) ~= "string" or type(pattern) ~= "string" then return false end
    host, pattern = host:lower(), pattern:lower()
    if host == pattern then return true end
    local suffix = pattern:match("^%*(%.[^*]+%.[^*]+)$") -- at least two labels after the wildcard
    if not suffix or #host <= #suffix or host:sub(-#suffix) ~= suffix then return false end
    return not host:sub(1, #host - #suffix):find(".", 1, true)
end

--- DNS names the certificate is valid for: its subjectAltName entries, else its common name.
function Tls.certNames(cert)
    local names = {}
    local ok, ext = pcall(cert.extensions, cert)
    local san = ok and type(ext) == "table" and ext["2.5.29.17"]
    if san and type(san.dNSName) == "table" then
        for _, name in ipairs(san.dNSName) do table.insert(names, name) end
    end
    if #names == 0 then
        local ok_subject, subject = pcall(cert.subject, cert)
        for _, entry in ipairs(ok_subject and type(subject) == "table" and subject or {}) do
            if entry.oid == "2.5.4.3" then table.insert(names, entry.value) end
        end
    end
    return names
end

function Tls.certValidFor(cert, host)
    for _, name in ipairs(Tls.certNames(cert)) do
        if Tls.hostMatches(host, name) then return true end
    end
    return false
end

return Tls
