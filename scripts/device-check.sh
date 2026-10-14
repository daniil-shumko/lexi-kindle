#!/usr/bin/env bash
# End-to-end check on the Kindle without touching the UI: runs the deployed plugin's real prompt,
# request and HTTPS code with KOReader's own LuaJIT and prints the AI answer (never the key).
#
# Usage: KINDLE_HOST=192.168.1.50 scripts/device-check.sh [word]      (KINDLE_PORT defaults to 2222)
set -euo pipefail

host="${KINDLE_HOST:?Set KINDLE_HOST to the Kindle IP address}"
port="${KINDLE_PORT:-2222}"
word="${1:-ephemeral}"

ssh -p "$port" "root@$host" "cd /mnt/us/koreader && LEXI_WORD='$word' ./luajit -" <<'LUA'
require("setupkoenv")
package.path = "plugins/lexi.koplugin/?.lua;" .. package.path
-- socketutil only reads Device.model (for its User-Agent); the real device module would initialise
-- the screen and input under the running KOReader, so stub it. Everything network-related stays real.
package.loaded["device"] = { model = "lexi-device-check" }

local Http = require("lexi_http")
local Prompt = require("lexi_prompt")
local Providers = require("lexi_providers")

local cfg = dofile("plugins/lexi.koplugin/config.lua")
local provider = cfg.provider or "claude"
local defaults = Providers.DEFAULTS[provider] or {}
local query = {
    word = os.getenv("LEXI_WORD"),
    prev = "The pleasures of the desert were",
    next = "and gone with the morning wind.",
    title = "Dune", authors = "Frank Herbert", lang = "en",
}
local prompt = Prompt.build(query, { targets = Prompt.parseLangList(cfg.languages or Prompt.DEFAULT_LANGUAGES) })
local request = assert(Providers.build(provider, {
    api_key = cfg[provider .. "_api_key"],
    model = cfg[provider .. "_model"] or defaults.model,
    effort = cfg[provider .. "_effort"] or defaults.effort,
    base_url = defaults.base_url,
    workspace_id = cfg[provider .. "_workspace_id"],
    token = cfg.backend_token,
}, query, prompt))

local started = os.time()
local response = Http.postJSON(request.url, request.headers, request.body)
print(string.format("provider=%s model=%s ok=%s status=%s seconds=%d",
    provider, tostring(request.body.model), tostring(response.ok), tostring(response.status), os.time() - started))
if response.ok then
    print((Providers.parse(provider, response.data)))
else
    print("ERROR: " .. tostring(Providers.errorMessage(response.data) or response.err))
    os.exit(1)
end
LUA
