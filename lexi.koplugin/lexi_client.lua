--[[--
Network calls shared by the KOReader plugin (run inside a Trapper subprocess) and the native-reader
bridge. Results are plain tables, so they survive the subprocess boundary.

@module lexi_client
--]]

local Http = require("lexi_http")
local Providers = require("lexi_providers")

local Client = {}

--- Sends a request built by Providers.build. @treturn table { text = answer } or { err = message }
function Client.ask(provider, request)
    local response = Http.postJSON(request.url, request.headers, request.body)
    if not response.ok then
        local message = Providers.errorMessage(response.data)
        if message and response.status then
            message = string.format("HTTP %s: %s", response.status, message)
        end
        return { err = message or response.err }
    end
    local text, err = Providers.parse(provider, response.data)
    if not text then return { err = err } end
    return { text = text }
end

--- Uploads saved words in order and stops at the first failure, so words keep their order.
-- @treturn table { synced = { ids… }, err = message or nil }
function Client.pushWords(base_url, token, words)
    local synced = {}
    for _, word in ipairs(words) do
        local request = Providers.wordUpload(base_url, token, word)
        local response = Http.postJSON(request.url, request.headers, request.body)
        if not response.ok then
            return { synced = synced, err = Providers.errorMessage(response.data) or response.err }
        end
        table.insert(synced, word.id)
    end
    return { synced = synced }
end

return Client
