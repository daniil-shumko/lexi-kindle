--[[--
Lexi for the native Kindle reader.

Started by native/lexi.sh start (the "Lexi: Ask AI on/off" library item), which feeds stdin through
a FIFO with two line streams: the reader's window events from /var/log/messages, and the events
native/dialog.html sends from Lexi's window (native/ui.lua, which this script starts).

Flow: the reader's dictionary popup opens → the newest Vocabulary Builder lookup (word, sentence,
book) → a small "Ask AI" button over the reader (dialog.html in Lexi's window) → tap → the AI answer,
asked with the chosen prompt preset, in the same window (a word asked about before shows its earlier
answer, with "Ask AI again") → "Ask again as…" another prompt, or "Save word" to add it to the list
KOReader's Lexi menu shows.

Run from /mnt/us/koreader with KOReader's LuaJIT: ./luajit plugins/lexi.koplugin/native/lexid.lua
--]]

require("setupkoenv")
local PLUGIN = "plugins/lexi.koplugin"
package.path = PLUGIN .. "/?.lua;" .. package.path
-- socketutil only reads Device.model (for its User-Agent). The real device module would take over
-- the screen and input, which belong to the Kindle framework here.
package.loaded["device"] = { model = "lexi-native" }

local LuaSettings = require("luasettings")
local SQ3 = require("lua-ljsqlite3/init")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
require("ffi/posix_h")
local rapidjson = require("rapidjson")
local Cache = require("lexi_cache")
local Client = require("lexi_client")
local Config = require("lexi_config")
local Format = require("lexi_format")
local Native = require("lexi_native")
local Presets = require("lexi_presets")
local Prompt = require("lexi_prompt")
local Providers = require("lexi_providers")
local Store = require("lexi_store")

local VOCAB_DB = "/mnt/us/system/vocabulary/vocab.db"
-- Our stdin: Lexi's window writes its events into it too.
local EVENTS_FIFO = os.getenv("LEXI_EVENTS") or "/var/run/lexi/events"
local SETTINGS_FILE = "settings/lexi.lua"
local WORDS_FILE = "settings/lexi_words.lua"
local ANSWERS_FILE = "settings/lexi_answers.lua"
-- The lookup row is written around the moment the popup opens: look for it this long, this often.
local LOOKUP_WINDOW, LOOKUP_POLL_MS = 5, 250

local LOOKUP_SQL = [[
SELECT l.timestamp, w.word, w.lang, l.usage, b.title, b.authors, b.lang
FROM LOOKUPS l JOIN WORDS w ON w.id = l.word_key LEFT JOIN BOOK_INFO b ON b.id = l.book_key
WHERE l.timestamp > ? ORDER BY l.timestamp DESC LIMIT 1]]

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    io.stdout:write(os.date("%H:%M:%S "), table.concat(parts, " "), "\n")
    io.stdout:flush()
end

-- Newest lookup after the given LOOKUPS.timestamp (ms), or nil.
local function newestLookup(after_ts)
    local ok, conn = pcall(SQ3.open, VOCAB_DB, "ro")
    if not ok then
        log("cannot open vocab.db:", conn)
        return
    end
    conn:set_busy_timeout(2000)
    local ok_query, row = pcall(function()
        local stmt = conn:prepare(LOOKUP_SQL)
        local r = stmt:reset():bind(after_ts):step()
        stmt:close()
        return r
    end)
    conn:close()
    if not ok_query then
        log("vocab.db query failed:", row)
        return
    end
    if not row then return end
    return {
        ts = tonumber(row[1]), word = row[2], lang = row[3], usage = row[4],
        title = row[5], authors = row[6], book_lang = row[7],
    }
end

local function loadConfig()
    local defaults, err = Config.loadFile(PLUGIN .. "/config.lua")
    if err then log("cannot load config.lua:", err) end
    return Config.new(LuaSettings:open(SETTINGS_FILE), defaults)
end

-- Lexi's window (native/ui.lua) with dialog.html: it stays up, hidden between lookups, and gets
-- one JSON line per update. It exits when this pipe closes, i.e. when we do.
local ui
local function startUi()
    ui = io.popen("exec ./luajit " .. PLUGIN .. "/native/ui.lua dialog >> " .. EVENTS_FIFO, "w")
end

-- Shows the dialog, or updates it. lexi.sh ignores SIGPIPE for us, so a window that died shows up
-- as a failed write: start a new one and try once more.
local function dialog(params)
    local line = rapidjson.encode(params) .. "\n"
    for attempt = 1, 2 do
        if not ui then startUi() end
        if ui and ui:write(line) and ui:flush() then return end
        log("window gone (attempt " .. attempt .. "), restarting it")
        if ui then pcall(ui.close, ui) end
        ui = nil
    end
end

-- False only when wifid reports a state other than CONNECTED; if it can't be read, let the
-- request itself fail with its own error.
local function wifiConnected()
    local p = io.popen("lipc-get-prop com.lab126.wifid cmState 2>/dev/null")
    local state = p and p:read("*a") or ""
    if p then p:close() end
    state = state:match("^%s*(%u+)")
    return state == nil or state == "CONNECTED"
end

local state = {
    last_ts = (newestLookup(0) or {}).ts or 0, -- lookups made before we started are not offered
    -- { id, query, answers = { [preset id] = { text, provider, model, created_at, reused } },
    --   shown = preset id }
    current = nil,
    dialog_open = false,
}

-- The prompt name to show, or nil for the default prompt.
local function promptLabel(preset)
    return preset.id ~= Presets.DEFAULT and preset.name or nil
end

local watch = Native.popupWatch(LOOKUP_WINDOW)
local next_check = 0

local function offer(row)
    state.last_ts = row.ts
    local query = Native.queryFromLookup(row)
    state.current = { id = tostring(row.ts), query = query, answers = {} }
    state.dialog_open = true
    log("lookup:", query.word, "lang=" .. tostring(query.lang))
    local config = loadConfig()
    dialog{ mode = "offer", id = state.current.id, word = query.word,
            provider = Providers.LABELS[config:provider()], prompt = promptLabel(config:activePreset()) }
end

-- While the popup is open, looks for its lookup. None within LOOKUP_WINDOW: a selection without a
-- dictionary lookup (several words, or a re-shown popup).
local function checkLookup()
    local now = ffiutil.getTimestamp()
    if now < next_check then return end
    next_check = now + LOOKUP_POLL_MS / 1000
    local row = newestLookup(math.max(state.last_ts, math.floor(watch.since * 1000)))
    if row then
        watch:found()
        offer(row)
    end
end

-- A word asked about before (in either reader) gets its earlier answer, with no request, unless
-- fresh is set ("Ask AI again").
local function ask(current, config, preset, fresh)
    local query = current.query
    local prompt = Prompt.build(query, { targets = config:languages(), preset = preset })
    local cache = Cache.new(LuaSettings:open(ANSWERS_FILE))
    local key = Cache.key(query.word, preset, prompt)
    local earlier = not fresh and cache:get(key)
    if earlier then
        log("earlier answer:", query.word, preset.id)
        current.answers[preset.id] = { text = earlier.text, provider = earlier.provider, model = earlier.model,
                                       created_at = earlier.created_at, reused = true }
        return current.answers[preset.id]
    end
    local provider = config:provider()
    local cfg = config:providerConfig(provider)
    local request, err = Providers.build(provider, cfg, query, prompt)
    if not request then return nil, err .. " Set it up in KOReader → Lexi, or from your phone." end
    if not wifiConnected() then return nil, "Wi-Fi is off. Turn it on, then long-press the word again." end
    local started = os.time()
    local result = Client.ask(provider, request)
    log("asked", provider, tostring(cfg.model), preset.id, result.text and "ok" or "failed", os.time() - started .. "s")
    if not result.text then return nil, result.err or "No answer." end
    current.answers[preset.id] = cache:put(key, {
        word = query.word, preset = preset.id, text = result.text, provider = provider, model = cfg.model,
    })
    return current.answers[preset.id]
end

-- preset_id: from "Ask again as…" or "Ask AI again"; nil asks with the chosen prompt. Answers are
-- kept per prompt for the lookup; fresh (from "Ask AI again") asks the AI whatever is kept.
local function onAsk(id, preset_id, fresh)
    local current = state.current
    if not current or current.id ~= id then
        dialog{ ifOpen = true, mode = "error", text = "That lookup has expired. Long-press the word again." }
        return
    end
    local config = loadConfig()
    local customs = config:customPrompts()
    local preset = preset_id and Presets.find(preset_id, customs) or config:activePreset()
    local answer, err = not fresh and current.answers[preset.id]
    if not answer then answer, err = ask(current, config, preset, fresh) end
    if not answer then
        log("error:", err)
        dialog{ ifOpen = true, mode = "error", text = err }
        return
    end
    current.shown = preset.id
    local presets = {}
    for _, p in ipairs(Presets.list(customs)) do
        table.insert(presets, { id = p.id, name = p.name })
    end
    local html = Format.answerHtml(answer.text, { plain = Presets.isCustom(preset) })
    if answer.reused then html = Format.earlierNote(answer.created_at) .. "\n" .. html end
    dialog{ ifOpen = true, mode = "answer", id = id, prompt = preset.name, preset = preset.id, presets = presets,
            html = html, reused = answer.reused or false }
end

local function onSave(id)
    local current = state.current
    local answer = current and current.id == id and current.answers[current.shown or ""]
    if not answer then return end
    local store = Store.new(LuaSettings:open(WORDS_FILE))
    local q = current.query
    store:add{
        word = q.word, prev = q.prev, next = q.next, title = q.title, authors = q.authors,
        lang = Prompt.normalizeLang(q.lang), answer = answer.text,
        provider = answer.provider, model = answer.model, preset = current.shown, source = "kindle",
    }
    log("saved:", q.word)
    local config = loadConfig()
    if config:backendConfigured() and wifiConnected() then
        local result = Client.pushWords(config:get("backend_url"), config:get("backend_token"), store:pending())
        store:markSynced(result.synced)
        if result.err then log("sync failed:", result.err) end
    end
    dialog{ ifOpen = true, saved = true }
end

local function onLine(line)
    local event, value = Native.parseEvent(line)
    if event == "lexiAsk" then
        onAsk(value)
    elseif event == "lexiAskAs" then
        onAsk(Native.splitAskAs(value))
    elseif event == "lexiAskAgain" then
        local id, preset_id = Native.splitAskAs(value)
        onAsk(id, preset_id, true)
    elseif event == "lexiSave" then
        onSave(value)
    elseif event == "lexiClosed" then
        state.dialog_open = false
    elseif not event then
        local popup = Native.parseSyslog(line)
        if popup == "opened" then
            watch:opened(ffiutil.getTimestamp())
            next_check = 0
        elseif popup == "closed" and watch:closed() and state.dialog_open then
            -- The dialog closes itself only while it still shows the "Ask AI" button.
            dialog{ ifOpen = true, nativeClosed = true }
        end
    end
end

-- stdin, read with a timeout so the lookup can be looked for between lines without falling behind
-- them (io.stdin:lines() would block until the next one).
local EINTR = 4
local pfd = ffi.new("struct pollfd[1]")
pfd[0].fd = 0
pfd[0].events = ffi.C.POLLIN
local chunk = ffi.new("char[4096]")
local unfinished = ""

-- Waits up to timeout_ms (-1: no limit). @treturn table the lines read ({} on timeout), or nil
-- once every writer has gone.
local function readLines(timeout_ms)
    local ready = ffi.C.poll(pfd, 1, timeout_ms)
    if ready < 0 then return ffi.errno() == EINTR and {} or nil end
    if ready == 0 then return {} end
    local n = tonumber(ffi.C.read(0, chunk, 4096))
    if n < 0 then return ffi.errno() == EINTR and {} or nil end
    if n == 0 then return nil end
    local lines
    lines, unfinished = Native.splitLines(unfinished .. ffi.string(chunk, n))
    return lines
end

log("started; newest lookup at", state.last_ts)
startUi() -- now, so the first "Ask AI" button doesn't wait for WebKit
while true do
    local lines = readLines(watch:watching(ffiutil.getTimestamp()) and LOOKUP_POLL_MS or -1)
    if not lines then break end
    for _, line in ipairs(lines) do onLine(line) end
    if watch:watching(ffiutil.getTimestamp()) then checkLookup() end
end
log("input closed, exiting")
if ui then pcall(ui.close, ui) end
