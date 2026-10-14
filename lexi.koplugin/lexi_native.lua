--[[--
Pure helpers for the native Kindle reader bridge (native/lexid.lua) and Lexi's window
(native/ui.lua): parsing what the Kindle framework logs and what our pages send, and turning a
Vocabulary Builder lookup into a Lexi query.

@module lexi_native
--]]

local Native = {}

--- The reader's dictionary/selection popup opening or closing, from a /var/log/messages line. Two
-- readers log it differently:
-- - the Java reader: "… cvm[5127]: I KindleFrameFactory:WindowAdded:title=…_A_SelectionDialogImpl_…:"
--   (and WindowRemoved);
-- - the newer one, which opens Amazon's own books on firmware 5.18 (KPPMainApp): "[CABSelectionListener:
--   INFO] selectionStabilized, selectionMode=1, willDisplayCAB=1" when its popup shows, and
--   "[KUXSelectionListener:INFO] selectionFinalized called" when the selection ends.
-- @treturn string|nil "opened" or "closed"
function Native.parseSyslog(line)
    local what = line:match("KindleFrameFactory:Window(%a+):title=[^:]*SelectionDialogImpl")
    if what == "Added" then return "opened" end
    if what == "Removed" then return "closed" end
    if line:find("CABSelectionListener:INFO] selectionStabilized, selectionMode=%d+, willDisplayCAB=1") then
        return "opened"
    end
    if line:find("KUXSelectionListener:INFO] selectionFinalized called", 1, true) then return "closed" end
end

local Watch = {}
Watch.__index = Watch

--[[--
Follows the reader's popup through its log lines, for native/lexid.lua. The Java reader logs every
popup line twice, so repeats are folded: another "opened" while the popup is open only extends the
wait for its lookup, and another "closed" changes nothing.

@tparam number window seconds to keep looking for the popup's Vocabulary Builder lookup
--]]
function Native.popupWatch(window)
    return setmetatable({ window = window, open = false, deadline = nil, since = nil }, Watch)
end

--- The popup opened. now: the time in seconds since the epoch, like Vocabulary Builder timestamps.
function Watch:opened(now)
    if not self.open then
        -- Lookups from before this popup belong to an earlier one.
        self.since = now - 2
    end
    self.open = true
    self.deadline = now + self.window
end

--- The popup closed. @treturn bool false for a repeated line
function Watch:closed()
    if not self.open then return false end
    self.open, self.deadline, self.since = false, nil, nil
    return true
end

--- Whether the popup's lookup is still being looked for.
function Watch:watching(now)
    return self.deadline ~= nil and now < self.deadline
end

--- Its lookup was found: stop looking.
function Watch:found()
    self.deadline = nil
end

--- Splits what was read so far into complete lines. @treturn table lines, string the unfinished rest
function Native.splitLines(buffer)
    local lines, last = {}, 1
    for line, after in buffer:gmatch("([^\n]*)\n()") do
        table.insert(lines, line)
        last = after
    end
    return lines, buffer:sub(last)
end

--- An event line that native/ui.lua prints for its page: `lexiAsk "payload"` (payload unescaped).
-- @treturn string|nil event name, string|nil payload
function Native.parseEvent(line)
    local name, value = line:match('^(lexi%a+) "(.*)"%s*$')
    if name then return name, value end
    return line:match("^(lexi%a+)%s*$")
end

--- An event that names a lookup and a prompt preset: "<id> <preset>" (the preset is optional).
-- @treturn string id, string|nil preset id
function Native.splitAskAs(value)
    local id, preset = tostring(value or ""):match("^(%S+)%s+(%S+)")
    if id then return id, preset end
    return tostring(value or ""):match("^%s*(.-)%s*$"), nil
end

--- What a page asks Lexi's window to do, from a console message: "lexi:<op> <args>" (see
-- native/bridge.js). @treturn table|nil { op = "ready" | "show" | "hide" | "redraw" } or
-- { op = "size", w, h } or { op = "pos", x, y } or { op = "event", name, value }
function Native.parseUiOp(message)
    local op, rest = tostring(message or ""):match("^lexi:(%a+)%s*(.-)%s*$")
    if not op then return nil end
    if op == "size" or op == "pos" then
        local a, b = rest:match("^(%-?%d+)%s+(%-?%d+)$")
        if not a then return nil end
        a, b = tonumber(a), tonumber(b)
        if op == "size" then return { op = op, w = a, h = b } end
        return { op = op, x = a, y = b }
    elseif op == "event" then
        local name, value = rest:match("^(lexi%a+)%s*(.*)$")
        if not name then return nil end
        return { op = op, name = name, value = (value:gsub("[%c\"]", " ")) }
    elseif op == "ready" or op == "show" or op == "hide" or op == "redraw" then
        return { op = op }
    end
end

--- A Lua string as a JavaScript string literal (for WebKit's execute_script). Also valid JSON.
function Native.jsString(s)
    local escaped = tostring(s):gsub('[\\"%c]', function(c)
        if c == "\\" then return "\\\\" end
        if c == '"' then return '\\"' end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        return string.format("\\u%04x", c:byte())
    end)
    -- Line and paragraph separators end a line in older JavaScript string literals.
    escaped = escaped:gsub("\226\128\168", "\\u2028"):gsub("\226\128\169", "\\u2029")
    return '"' .. escaped .. '"'
end

local function escapePattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- Splits the lookup's sentence around the word: a whole-word match (ASCII case-insensitive)
-- first, then any occurrence. string.lower only changes ASCII bytes, so positions line up.
-- @treturn string prev, string next, string|nil the word as written in the book
function Native.splitUsage(usage, word)
    usage = usage or ""
    if not word or word == "" then return usage, "" end
    local lower_usage, lower_word = usage:lower(), word:lower()
    local s, e = lower_usage:find("%f[%w]" .. escapePattern(lower_word) .. "%f[%W]")
    if not s then s, e = lower_usage:find(lower_word, 1, true) end
    if not s then return usage, "" end
    return usage:sub(1, s - 1), usage:sub(e + 1), usage:sub(s, e)
end

--- Vocabulary Builder row → Lexi query { word, prev, next, title, authors, lang }.
-- row: { word, lang, usage, title, authors, book_lang } (WORDS.lang is the dictionary language).
function Native.queryFromLookup(row)
    local prev, following, as_written = Native.splitUsage(row.usage, row.word)
    return {
        word = as_written or row.word,
        prev = prev,
        next = following,
        title = row.title,
        authors = row.authors,
        lang = row.lang or row.book_lang,
    }
end

--- Single-quotes a string for /bin/sh.
function Native.shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

return Native
