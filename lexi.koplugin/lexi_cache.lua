--[[--
Earlier AI answers, so asking about a word again shows the answer it already got instead of paying
for a new one. Both readers share them (koreader/settings/lexi_answers.lua).

An answer is reused for the same word in any letter case, with the same prompt, book language and
translation languages. The passage around the word doesn't count: that is what makes the second
lookup of a word free. "Ask AI again" asks anyway and replaces the stored answer. Only the newest
answers are kept.

Backed by any LuaSettings-like object (readSetting / saveSetting / flush), so it can be tested
without KOReader. Each answer: { word, preset (the prompt preset id), text, provider, model,
created_at (unix seconds) }.

@module lexi_cache
--]]

local bit = require("bit")
local Presets = require("lexi_presets")

local Cache = {}
Cache.__index = Cache

Cache.MAX = 500 -- answers kept; the file stays around half a megabyte

--- max: answers to keep (default Cache.MAX).
function Cache.new(settings, max)
    return setmetatable({ settings = settings, max = max or Cache.MAX }, Cache)
end

-- string.lower only changes ASCII. Also lowercase the two-byte UTF-8 letters a capitalized word
-- in a European book is likely to start with: Latin-1 (À–Þ, but not ×) and Cyrillic (Ѐ–Я).
local function lower(s)
    return (s:lower():gsub("[\195\208][\128-\191]", function(c)
        local cp = (c:byte(1) - 0xC0) * 64 + (c:byte(2) - 0x80)
        if cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7 or cp >= 0x410 and cp <= 0x42F then
            cp = cp + 0x20
        elseif cp >= 0x400 and cp <= 0x40F then
            cp = cp + 0x50
        else
            return c
        end
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    end))
end

-- djb2, as 8 hex digits: a custom prompt's wording in the key without the whole text.
local function hash(s)
    local h = 5381
    for i = 1, #s do h = bit.tobit(h * 33 + s:byte(i)) end
    return bit.tohex(h)
end

--- The key an answer is stored under.
-- @tparam string word the selected word
-- @tparam table preset the prompt preset it was asked with (from lexi_presets)
-- @tparam table prompt what Prompt.build returned for it (explain_lang, targets)
function Cache.key(word, preset, prompt)
    local parts = {
        lower((tostring(word or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))),
        preset.id,
        prompt.explain_lang or "",
        table.concat(prompt.targets or {}, ","),
    }
    -- Editing a custom prompt changes its answers, so its wording is part of the key.
    if Presets.isCustom(preset) then table.insert(parts, hash(preset.template or "")) end
    return table.concat(parts, "|")
end

--- The stored answer for key, or nil.
function Cache:get(key)
    local answers = self.settings:readSetting("answers")
    return answers and answers[key]
end

--- Stores an answer under key, replacing any earlier one, and drops the oldest beyond the limit.
-- @treturn table the stored answer, with created_at set
function Cache:put(key, answer)
    local answers = self.settings:readSetting("answers") or {}
    answer.created_at = answer.created_at or os.time()
    answers[key] = answer
    local keys = {}
    for k in pairs(answers) do table.insert(keys, k) end
    if #keys > self.max then
        table.sort(keys, function(a, b) return answers[a].created_at < answers[b].created_at end)
        for i = 1, #keys - self.max do answers[keys[i]] = nil end
    end
    self.settings:saveSetting("answers", answers)
    self.settings:flush()
    return answer
end

return Cache
