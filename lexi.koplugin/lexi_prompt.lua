--[[--
Builds the prompt for a word lookup: the lookup context (selection, passage, languages) here, the
wording of each prompt preset in lexi_presets.lua.

Pure Lua with no KOReader dependencies, so it can be unit-tested with plain LuaJIT.

@module lexi_prompt
--]]

local Presets = require("lexi_presets")

local Prompt = {}

Prompt.DEFAULT_LANGUAGES = "ru,en,es"

Prompt.LANG_NAMES = {
    ar = "Arabic", de = "German", en = "English", es = "Spanish", fr = "French",
    it = "Italian", ja = "Japanese", ko = "Korean", nl = "Dutch", pl = "Polish",
    pt = "Portuguese", ru = "Russian", tr = "Turkish", uk = "Ukrainian", zh = "Chinese",
}

-- ISO 639-2 codes that EPUB metadata sometimes uses instead of ISO 639-1.
local ISO639_2 = {
    ara = "ar", chi = "zh", deu = "de", dut = "nl", eng = "en", fra = "fr", fre = "fr",
    ger = "de", ita = "it", jpn = "ja", kor = "ko", nld = "nl", pol = "pl", por = "pt",
    rus = "ru", spa = "es", tur = "tr", ukr = "uk", zho = "zh",
}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function squash(s)
    return trim((s or ""):gsub("%s+", " "))
end

--- Normalizes "en-US", "EN_gb", "eng", "English" to "en". Returns nil when unknown.
function Prompt.normalizeLang(lang)
    if type(lang) ~= "string" then return nil end
    local l = trim(lang:lower())
    if l == "" then return nil end
    for code, name in pairs(Prompt.LANG_NAMES) do
        if l == name:lower() then return code end
    end
    if ISO639_2[l] then return ISO639_2[l] end
    return l:match("^(%a%a)$") or l:match("^(%a%a)[%-_]")
end

function Prompt.langName(code)
    return Prompt.LANG_NAMES[code] or code
end

--- Parses "ru, EN,es" into {"ru", "en", "es"}, dropping duplicates and junk.
function Prompt.parseLangList(s)
    local out, seen = {}, {}
    for item in tostring(s or ""):gmatch("[^,;%s]+") do
        local code = Prompt.normalizeLang(item)
        if code and not seen[code] then
            seen[code] = true
            table.insert(out, code)
        end
    end
    return out
end

-- Keeps the passage short: the end of the text before the word, the start of the text after it.
local function tail(s, max_chars)
    s = squash(s)
    if #s <= max_chars then return s end
    return "…" .. s:sub(-max_chars):gsub("^[\128-\191]+", "")
end

local function head(s, max_chars)
    s = squash(s)
    if #s <= max_chars then return s end
    -- If the cut lands inside a multibyte character, back up to that character's first byte.
    local cut = max_chars + 1
    while cut > 1 and s:byte(cut) >= 0x80 and s:byte(cut) < 0xC0 do
        cut = cut - 1
    end
    return s:sub(1, cut - 1) .. "…"
end

--- The default preset's rules (see lexi_presets.lua for every preset's).
Prompt.SYSTEM = Presets.find(Presets.DEFAULT).system

--[[--
What every preset can use from a lookup: the selection, the trimmed passage around it and the
languages.

@tparam table query { word, prev, next, title, authors, lang }
@tparam table opts { targets = {"ru", "en", "es"} }
@treturn table { word, before, after, passage, title, authors, book_lang, book_language, explain_in,
  targets, target_names }
--]]
function Prompt.context(query, opts)
    opts = opts or {}
    local book_lang = Prompt.normalizeLang(query.lang)
    local wanted = opts.targets
    if not wanted or #wanted == 0 then
        wanted = Prompt.parseLangList(Prompt.DEFAULT_LANGUAGES)
    end

    local targets, target_names = {}, {}
    for _, code in ipairs(wanted) do
        if code ~= book_lang then
            table.insert(targets, code)
            table.insert(target_names, Prompt.langName(code))
        end
    end

    local word = squash(query.word)
    local before, after = tail(query.prev, 400), head(query.next, 400)
    local has_title = query.title and query.title ~= ""
    return {
        word = word,
        before = before,
        after = after,
        passage = string.format("%s ⟦%s⟧ %s", before, word, after),
        title = has_title and squash(query.title) or nil,
        authors = has_title and query.authors and query.authors ~= "" and squash(query.authors) or nil,
        book_lang = book_lang,
        book_language = book_lang and Prompt.langName(book_lang) or nil,
        explain_in = book_lang and Prompt.langName(book_lang) or "the language of the passage",
        targets = targets,
        target_names = target_names,
    }
end

--[[--
Builds the prompt.

@tparam table query { word, prev, next, title, authors, lang }
@tparam table opts { targets = {"ru", "en", "es"}, preset = a preset from lexi_presets (default: explain) }
@treturn table { system, user, explain_lang, targets, preset (id), format ("card" for the built-in
  layouts, "plain" for custom prompts), custom (bool) }
--]]
function Prompt.build(query, opts)
    opts = opts or {}
    local preset = opts.preset or Presets.find(Presets.DEFAULT)
    local ctx = Prompt.context(query, opts)
    local system, user = Presets.build(preset, ctx)
    local custom = Presets.isCustom(preset)
    return {
        system = system,
        user = user,
        explain_lang = ctx.book_lang,
        targets = ctx.targets,
        preset = preset.id,
        format = custom and "plain" or "card",
        custom = custom,
    }
end

return Prompt
