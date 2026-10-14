--[[--
Turns the AI's plain-text answer into HTML for the answer popup: bold headword, bold labels
("Meaning:", "Note:", "Example:") and a separated block of translations ("RU:", "ES:").

Pure Lua with no KOReader dependencies, so it can be unit-tested with plain LuaJIT.

@module lexi_format
--]]

local Format = {}

-- Same base as KOReader's dictionary popup (Noto Sans has the IPA glyphs).
Format.CSS = [[
@page { margin: 0; font-family: 'Noto Sans'; }
body { margin: 0; line-height: 1.3; }
p { margin: 0 0 0.5em 0; }
p.head { font-size: 1.15em; margin-bottom: 0.7em; }
p.tr { margin: 0 0 0.2em 0; }
p.note { font-size: 0.8em; font-style: italic; }
hr { margin: 0.6em 0; }
]]

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- "Meaning: …", "RU: …", "Значение: …" → label, rest. Ordinary sentences that merely contain a
-- colon are left alone: labels are short (at most three words) and have no sentence punctuation.
local function splitLabel(line)
    local label, rest = line:match("^([^:]+):%s*(.*)$")
    if not label or #label > 24 or label:find("[%.%?!,;\"«]") then return nil end
    local _, spaces = label:gsub(" ", "")
    if spaces > 2 then return nil end
    return label, rest
end

-- Translation lines use a 2-3 letter uppercase language code: "RU", "ES", "EN".
local function isTranslation(label)
    return label:match("^%u%u%u?$") ~= nil
end

--- opts.plain: the answer to a custom prompt, which has no headword line to make bold.
function Format.answerHtml(text, opts)
    local out = {}
    local seen_first, in_translations = opts and opts.plain or false, false
    for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
        -- The prompt asks for plain text; drop Markdown emphasis in case the model adds it anyway.
        local line = raw:gsub("%*%*", ""):gsub("__", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local label, rest = splitLabel(line)
            if not seen_first and not label then
                table.insert(out, '<p class="head"><b>' .. escape(line) .. "</b></p>")
            elseif label and isTranslation(label) then
                if not in_translations then
                    table.insert(out, "<hr/>")
                    in_translations = true
                end
                table.insert(out, string.format('<p class="tr"><b>%s:</b> %s</p>', escape(label), escape(rest)))
            elseif label then
                table.insert(out, string.format("<p><b>%s:</b> %s</p>", escape(label), escape(rest)))
            else
                table.insert(out, "<p>" .. escape(line) .. "</p>")
            end
            seen_first = true
        end
    end
    return table.concat(out, "\n")
end

--- The line above a reused answer (see lexi_cache.lua): "Earlier answer · 12 Oct 2026".
function Format.earlierNote(created_at)
    local t = os.date("*t", created_at or 0)
    return string.format('<p class="note">Earlier answer · %d %s %d</p>', t.day, MONTHS[t.month], t.year)
end

return Format
