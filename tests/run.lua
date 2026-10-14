-- Unit tests for the pure-Lua parts of lexi.koplugin. Run from the repo root: luajit tests/run.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/run%.lua$") or "."
local plugin_dir = root .. "/lexi.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local Cache = require("lexi_cache")
local Config = require("lexi_config")
local Format = require("lexi_format")
local Native = require("lexi_native")
local Presets = require("lexi_presets")
local Prompt = require("lexi_prompt")
local Setup = require("lexi_setup")
local Tls = require("lexi_tls")
local Providers = require("lexi_providers")
local Store = require("lexi_store")

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n     " .. tostring(err))
    end
end

local function eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
    end
end

local function contains(text, needle, what)
    if not tostring(text):find(needle, 1, true) then
        error(string.format("%s: %q not found in:\n%s", what or "text", needle, tostring(text)), 2)
    end
end

local function lacks(text, needle, what)
    if tostring(text):find(needle, 1, true) then
        error(string.format("%s: unexpected %q in:\n%s", what or "text", needle, tostring(text)), 2)
    end
end

local function validUtf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len = c < 0x80 and 1 or c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 0
        if len == 0 or i + len - 1 > n then return false end
        for j = i + 1, i + len - 1 do
            local b = s:byte(j)
            if b < 0x80 or b > 0xBF then return false end
        end
        i = i + len
    end
    return true
end

local sample = {
    word = "ephemeral",
    prev = "The pleasures of the desert were",
    next = "and gone with the morning wind.",
    title = "Dune",
    authors = "Frank Herbert",
    lang = "en-US",
}

-- Prompt -------------------------------------------------------------------------------------------

test("normalizeLang", function()
    eq(Prompt.normalizeLang("en"), "en")
    eq(Prompt.normalizeLang("en-US"), "en")
    eq(Prompt.normalizeLang("EN_gb"), "en")
    eq(Prompt.normalizeLang("eng"), "en")
    eq(Prompt.normalizeLang("ger"), "de")
    eq(Prompt.normalizeLang("Russian"), "ru")
    eq(Prompt.normalizeLang(" rus "), "ru")
    eq(Prompt.normalizeLang("sv"), "sv")
    eq(Prompt.normalizeLang(""), nil)
    eq(Prompt.normalizeLang("x"), nil)
    eq(Prompt.normalizeLang(nil), nil)
end)

test("parseLangList dedupes and normalizes", function()
    local list = Prompt.parseLangList("ru, EN,es;ru  de")
    eq(table.concat(list, ","), "ru,en,es,de")
    eq(#Prompt.parseLangList(""), 0)
end)

test("English book: explain in English, translate to RU and ES", function()
    local p = Prompt.build(sample, { targets = Prompt.parseLangList("ru,en,es") })
    eq(p.explain_lang, "en")
    eq(table.concat(p.targets, ","), "ru,es")
    contains(p.user, 'Book: "Dune" by Frank Herbert')
    contains(p.user, "were ⟦ephemeral⟧ and gone")
    contains(p.user, "Meaning: <1-2 sentences in English>")
    contains(p.user, "RU: <Russian translation>")
    contains(p.user, "ES: <Spanish translation>")
    lacks(p.user, "EN: ")
    lacks(p.user, "Skip the translation line")
    contains(p.system, "Plain text only")
end)

test("Russian book: explain in Russian, translate to EN and ES", function()
    local q = { word = "тоска", prev = "Его охватила", next = "по дому.", lang = "ru" }
    local p = Prompt.build(q, { targets = Prompt.parseLangList("ru,en,es") })
    eq(table.concat(p.targets, ","), "en,es")
    contains(p.user, "Meaning: <1-2 sentences in Russian>")
    lacks(p.user, "Book:")
end)

test("unknown language: let the model detect it", function()
    local q = { word = "saudade", prev = "", next = "" }
    local p = Prompt.build(q, {})
    eq(p.explain_lang, nil)
    eq(table.concat(p.targets, ","), "ru,en,es")
    contains(p.user, "in the language of the passage")
    contains(p.user, "Skip the translation line")
end)

test("long Cyrillic context is trimmed on UTF-8 boundaries", function()
    local q = { word = "слово", prev = string.rep("длинное предложение ", 200), next = string.rep("и ещё ", 300), lang = "ru" }
    local p = Prompt.build(q, {})
    assert(#p.user < 1500, "prompt too long: " .. #p.user)
    assert(validUtf8(p.user), "prompt is not valid UTF-8")
    contains(p.user, "…")
end)

test("context cut on a character boundary keeps the whole character", function()
    -- 399 ASCII bytes + "ё" (2 bytes) = 401 bytes: the 400-byte cut must not drop "a" before "ё".
    local q = { word = "x", prev = "", next = string.rep("a", 399) .. "ёzzz", lang = "ru" }
    local p = Prompt.build(q, {})
    assert(validUtf8(p.user), "prompt is not valid UTF-8")
    contains(p.user, string.rep("a", 399) .. "…")
end)

-- Golden copies of the default prompt as it was before presets existed: it must not drift.
local GOLDEN_SYSTEM = [[
You are a vocabulary helper built into an e-ink e-reader. The reader selected a word or short phrase in a book and wants to understand it exactly as it is used in the passage.

Rules:
- Plain text only. No Markdown (no asterisks, #, bullet dashes or tables): the screen cannot render it.
- Be brief: at most about 120 words in total.
- Explain the meaning in this context, not every dictionary sense. If it is an idiom, slang, a proper name or used figuratively, say so.
- If the selection is an inflected form, give the dictionary form.
- Translations must fit this context; give 1 to 3 options per language, most fitting first.
- Follow the answer layout you are given exactly.]]

local GOLDEN_EN = [[
Book: "Dune" by Frank Herbert
Selected: ephemeral
Passage (selection marked with ⟦ ⟧):
The pleasures of the desert were ⟦ephemeral⟧ and gone with the morning wind.

Answer in this layout:
<selection> → <dictionary form> (<part of speech>)
Meaning: <1-2 sentences in English>
Note: <optional nuance, register or idiom; omit this line if there is nothing useful>
Example: <one short new example sentence in English>

RU: <Russian translation>
ES: <Spanish translation>]]

local GOLDEN_UNKNOWN = [[
Selected: saudade
Passage (selection marked with ⟦ ⟧):
 ⟦saudade⟧ 

Answer in this layout:
<selection> → <dictionary form> (<part of speech>)
Meaning: <1-2 sentences in the language of the passage>
Note: <optional nuance, register or idiom; omit this line if there is nothing useful>
Example: <one short new example sentence in the language of the passage>

RU: <Russian translation>
EN: <English translation>
ES: <Spanish translation>
(Skip the translation line for the language the passage is written in.)]]

test("default prompt is unchanged (golden)", function()
    local p = Prompt.build(sample, { targets = Prompt.parseLangList("ru,en,es") })
    eq(p.system, GOLDEN_SYSTEM)
    eq(Prompt.SYSTEM, GOLDEN_SYSTEM)
    eq(p.user, GOLDEN_EN)
    eq(p.preset, "explain")
    eq(p.format, "card")
    eq(p.custom, false)
    eq(Prompt.build({ word = "saudade", prev = "", next = "" }, {}).user, GOLDEN_UNKNOWN)
    local explicit = Prompt.build(sample, { targets = Prompt.parseLangList("ru,en,es"), preset = Presets.find("explain") })
    eq(explicit.user, GOLDEN_EN, "choosing explain explicitly gives the same prompt")
end)

-- Prompt presets -----------------------------------------------------------------------------------

test("presets: every built-in has the passage, its rules and the translations", function()
    local ids = {}
    for _, preset in ipairs(Presets.builtins()) do
        table.insert(ids, preset.id)
        assert(preset.name and preset.description, preset.id .. " needs a name and a description")
        local p = Prompt.build(sample, { targets = { "ru", "en", "es" }, preset = preset })
        eq(p.preset, preset.id)
        eq(p.format, "card")
        contains(p.user, "were ⟦ephemeral⟧ and gone", preset.id)
        contains(p.user, 'Book: "Dune" by Frank Herbert', preset.id)
        contains(p.user, "RU: <Russian translation>", preset.id)
        contains(p.user, "ES: <Spanish translation>", preset.id)
        lacks(p.user, "EN: ", preset.id)
        contains(p.system, "Plain text only", preset.id)
        contains(p.system, "Follow the answer layout", preset.id)
    end
    eq(table.concat(ids, ","), "explain,eli5,translate,deep,grammar")
end)

test("presets: each built-in asks for its own layout", function()
    local function user(id) return Prompt.build(sample, { targets = { "ru" }, preset = Presets.find(id) }).user end
    local function rules(id) return Presets.find(id).system end
    contains(user("eli5"), "Simply: <1-3 very simple sentences in English>")
    contains(user("eli5"), "Like: <one everyday comparison")
    contains(rules("eli5"), "five-year-old")
    contains(user("deep"), "Origin: <short etymology in English>")
    contains(user("deep"), "Synonyms:")
    contains(rules("deep"), "250 words")
    contains(user("grammar"), "Form: <the grammatical form here")
    contains(user("grammar"), "Why here:")
    lacks(user("translate"), "Meaning:")
    contains(rules("translate"), "only the lines of the layout")
end)

test("presets: translation only, when every language is the book's own, asks for the meaning", function()
    local p = Prompt.build(sample, { targets = { "en" }, preset = Presets.find("translate") })
    contains(p.user, "Meaning: <one short sentence in English>")
    lacks(p.user, "translation>")
end)

test("presets: find falls back to the default; list puts custom prompts last", function()
    local customs = { { id = "custom1", name = "Kid", template = "Explain {word}" } }
    eq(Presets.find("eli5", customs).id, "eli5")
    eq(Presets.find("custom1", customs).name, "Kid")
    eq(Presets.find("custom9", customs).id, "explain", "a deleted custom prompt")
    eq(Presets.find(nil).id, "explain")
    local list = Presets.list(customs)
    eq(#list, #Presets.builtins() + 1)
    eq(list[#list].id, "custom1")
    eq(Presets.isCustom(customs[1]), true)
    eq(Presets.isCustom(Presets.find("eli5")), false)
end)

test("custom prompt: placeholders, base rules and plain format", function()
    local preset = { id = "custom1", name = "All", template =
        "W={word} C={context} B=[{before}] A=[{after}] T={book} by {author} L={book_language} "
        .. "E={explain_language} X={translate_to} U={unknown} {word}" }
    local p = Prompt.build(sample, { targets = { "ru", "en", "es" }, preset = preset })
    eq(p.user, "W=ephemeral C=The pleasures of the desert were ⟦ephemeral⟧ and gone with the morning wind. "
        .. "B=[The pleasures of the desert were] A=[and gone with the morning wind.] T=Dune by Frank Herbert "
        .. "L=English E=English X=Russian, Spanish U={unknown} ephemeral")
    eq(p.system, Presets.BASE_SYSTEM)
    contains(p.system, "Plain text only")
    eq(p.format, "plain")
    eq(p.custom, true)
    eq(p.preset, "custom1")
end)

test("custom prompt: values are inserted literally, never expanded again", function()
    local q = { word = "100% {context}", prev = "a%1b", next = "" }
    local p = Prompt.build(q, { targets = {}, preset = { id = "c", name = "c", template = "{word}|{before}|{book}|{book_language}" } })
    eq(p.user, "100% {context}|a%1b||unknown")
    eq(Presets.render("{word} {Word} {word", { word = "тоска" }), "тоска {Word} {word")
end)

test("custom prompt: validation", function()
    local ok, err = Presets.validate{ name = "  Kid  ", template = "  Explain {word} simply.  " }
    eq(ok.name, "Kid")
    eq(ok.template, "Explain {word} simply.")
    ok, err = Presets.validate{ name = "", template = "{word}" }
    eq(ok, nil)
    contains(err, "name")
    ok, err = Presets.validate{ name = string.rep("я", Presets.MAX_NAME), template = "{word}" }
    assert(ok, "a name of exactly MAX_NAME Cyrillic characters is fine")
    ok, err = Presets.validate{ name = string.rep("я", Presets.MAX_NAME + 1), template = "{word}" }
    eq(ok, nil)
    ok, err = Presets.validate{ name = "Long", template = "{word}" .. string.rep("ж", Presets.MAX_TEMPLATE) }
    eq(ok, nil)
    contains(err, "too long")
    ok, err = Presets.validate{ name = "Nothing", template = "Tell me a joke." }
    eq(ok, nil)
    contains(err, "{word} or {context}")
    assert(Presets.validate{ name = "Ctx", template = "Explain the marked word in {context}" }, "{context} alone is enough")
end)

test("custom prompt: sanitize keeps valid ones with unique ids, up to the limit", function()
    local list = Presets.sanitize{
        { id = "custom1", name = "A", template = "{word}" },
        { id = "custom1", name = "B", template = "{word}" },
        { id = "eli5", name = "C", template = "{word}" },
        { name = "D", template = "{word}" },
        { id = "custom7", name = "", template = "{word}" },
        "junk",
    }
    eq(#list, 4)
    eq(list[1].id, "custom1")
    eq(list[2].id, "custom2", "duplicate id replaced")
    eq(list[3].id, "custom3", "a built-in id is not allowed")
    eq(list[4].id, "custom4")
    eq(#Presets.sanitize(nil), 0)
    eq(#Presets.sanitize("nope"), 0)
    local many = {}
    for i = 1, Presets.MAX_CUSTOM + 3 do many[i] = { id = "custom" .. i, name = "P" .. i, template = "{word}" } end
    eq(#Presets.sanitize(many), Presets.MAX_CUSTOM)
    eq(Presets.newId(list), "custom5")
    eq(Presets.newId({}), "custom1")
end)

-- Providers ----------------------------------------------------------------------------------------

local prompt = Prompt.build(sample, {})

local function claudeCfg(model)
    return { api_key = "sk-ant-test", model = model, effort = "low", base_url = "https://api.anthropic.com/" }
end

test("Claude Opus 5.5 request", function()
    local req = Providers.build("claude", claudeCfg("claude-opus-5-5"), sample, prompt)
    eq(req.url, "https://api.anthropic.com/v1/messages")
    eq(req.headers["x-api-key"], "sk-ant-test")
    eq(req.headers["anthropic-version"], "2023-06-01")
    eq(req.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
    eq(req.body.model, "claude-opus-5-5")
    eq(req.body.fallbacks, "default")
    eq(req.body.output_config.effort, "low")
    eq(req.body.system, prompt.system)
    eq(req.body.messages[1].role, "user")
    eq(req.body.messages[1].content, prompt.user)
    eq(req.body.thinking, nil)
    eq(req.headers["anthropic-workspace-id"], nil)
    assert(req.body.max_tokens >= 4000, "max_tokens too small for thinking + answer")
end)

test("Claude workspace header for multi-workspace keys", function()
    local cfg = claudeCfg("claude-opus-5-5")
    cfg.workspace_id = "wrkspc_01TEST"
    local req = Providers.build("claude", cfg, sample, prompt)
    eq(req.headers["anthropic-workspace-id"], "wrkspc_01TEST")
end)

test("Claude Haiku 5.5 request disables thinking and skips fallbacks", function()
    local req = Providers.build("claude", claudeCfg("claude-haiku-5-5"), sample, prompt)
    eq(req.body.thinking.type, "disabled")
    eq(req.body.fallbacks, nil)
    eq(req.headers["anthropic-beta"], nil)
end)

test("missing API keys are reported", function()
    local req, err = Providers.build("claude", { model = "claude-opus-5-5", base_url = "x" }, sample, prompt)
    eq(req, nil)
    contains(err, "Claude API key")
    req, err = Providers.build("openai", { api_key = "", model = "m", base_url = "x" }, sample, prompt)
    eq(req, nil)
    contains(err, "OpenAI API key")
    req, err = Providers.build("nope", {}, sample, prompt)
    eq(req, nil)
    contains(err, "Unknown")
end)

test("OpenAI Responses request", function()
    local cfg = { api_key = "sk-test", model = "gpt-6.1-sol", effort = "low", base_url = "https://api.openai.com" }
    local req = Providers.build("openai", cfg, sample, prompt)
    eq(req.url, "https://api.openai.com/v1/responses")
    eq(req.headers["Authorization"], "Bearer sk-test")
    eq(req.body.model, "gpt-6.1-sol")
    eq(req.body.instructions, prompt.system)
    eq(req.body.input, prompt.user)
    eq(req.body.reasoning.effort, "low")
    eq(req.body.store, false)
end)

test("backend request", function()
    local req, err = Providers.build("backend", { base_url = "https://words.example.com" }, sample, prompt)
    eq(req, nil)
    contains(err, "token")
    req = Providers.build("backend", { base_url = "https://words.example.com/", token = "dev-123" }, sample, prompt)
    eq(req.url, "https://words.example.com/v1/explain")
    eq(req.headers["Authorization"], "Bearer dev-123")
    eq(req.body.word, "ephemeral")
    eq(req.body.book.title, "Dune")
    eq(table.concat(req.body.translate_to, ","), "ru,es")
    -- Every requested language is the book's own: the key is omitted instead of encoding as {}.
    local only_en = Prompt.build(sample, { targets = { "en" } })
    req = Providers.build("backend", { base_url = "https://w.example.com", token = "t" }, sample, only_en)
    eq(req.body.translate_to, nil)
end)

test("backend request names the prompt preset; a custom prompt sends its text", function()
    local cfg = { base_url = "https://w.example.com", token = "t" }
    local req = Providers.build("backend", cfg, sample, Prompt.build(sample, { preset = Presets.find("eli5") }))
    eq(req.body.preset, "eli5")
    eq(req.body.prompt, nil, "a built-in prompt is the backend's own")
    local custom = Prompt.build(sample, { preset = { id = "custom1", name = "Kid", template = "Explain {word}" } })
    req = Providers.build("backend", cfg, sample, custom)
    eq(req.body.preset, "custom1")
    eq(req.body.prompt.user, "Explain ephemeral")
    eq(req.body.prompt.system, Presets.BASE_SYSTEM)
end)

test("parse Claude response skips thinking blocks", function()
    local text = Providers.parse("claude", {
        stop_reason = "end_turn",
        content = {
            { type = "thinking", thinking = "" },
            { type = "text", text = "ephemeral → ephemeral (adjective)" },
            { type = "text", text = "RU: мимолётный" },
        },
    })
    eq(text, "ephemeral → ephemeral (adjective)\nRU: мимолётный")
end)

test("parse Claude refusal and truncation", function()
    local text, err = Providers.parse("claude", { stop_reason = "refusal", content = {} })
    eq(text, nil)
    contains(err, "declined")
    text, err = Providers.parse("claude", { stop_reason = "max_tokens", content = { { type = "thinking", thinking = "" } } })
    eq(text, nil)
    contains(err, "max_tokens")
end)

test("parse OpenAI response", function()
    local text = Providers.parse("openai", {
        output = {
            { type = "reasoning", summary = {} },
            { type = "message", role = "assistant", content = { { type = "output_text", text = "Hi" } } },
        },
    })
    eq(text, "Hi")
    local _, err = Providers.parse("openai", { status = "incomplete", incomplete_details = { reason = "max_output_tokens" }, output = {} })
    contains(err, "max_output_tokens")
    _, err = Providers.parse("openai", { output = { { type = "message", content = { { type = "refusal", refusal = "no" } } } } })
    contains(err, "declined")
end)

test("errorMessage", function()
    eq(Providers.errorMessage({ type = "error", error = { type = "authentication_error", message = "invalid x-api-key" } }), "invalid x-api-key")
    eq(Providers.errorMessage({ error = { message = "Incorrect API key provided" } }), "Incorrect API key provided")
    eq(Providers.errorMessage({ error = "nope" }), "nope")
    eq(Providers.errorMessage({ error = { message = "Incorrect API key provided: sk-proj-ab***yz9." } }),
        "Incorrect API key provided: sk-….")
    eq(Providers.errorMessage(nil), nil)
end)

test("word upload request", function()
    local req = Providers.wordUpload("https://words.example.com", "dev-123", {
        id = "1-abcd", word = "ephemeral", prev = "a", next = "b", title = "Dune", lang = "en",
        answer = "…", provider = "claude", model = "claude-opus-5-5", created_at = 1,
    })
    eq(req.url, "https://words.example.com/v1/words")
    eq(req.body.id, "1-abcd")
    eq(req.body.context.prev, "a")
    eq(req.body.book.language, "en")
    eq(req.body.source, "koreader", "words saved before the reader was recorded")
    eq(req.body.preset, nil, "words saved before presets have none")
    req = Providers.wordUpload("https://w.example.com", "t", { id = "2", word = "x", preset = "grammar", source = "kindle" })
    eq(req.body.preset, "grammar")
    eq(req.body.source, "kindle", "saved in the Kindle's own reader")
end)

-- Format -------------------------------------------------------------------------------------------

-- A real answer returned by claude-opus-5-5 on the Kindle.
local real_answer = [[
ephemeral → ephemeral (adjective)
Meaning: Lasting only a very short time; here, the desert's pleasures fade almost as soon as they appear.
Note: Somewhat literary or formal. From Greek "ephemeros", lasting only a day.
Example: The fame he won from that single song proved ephemeral.

RU: мимолётный, недолговечный, эфемерный
ES: efímero, fugaz, pasajero]]

test("answer HTML: bold headword, labels and separated translations", function()
    local html = Format.answerHtml(real_answer)
    contains(html, '<p class="head"><b>ephemeral → ephemeral (adjective)</b></p>')
    contains(html, "<p><b>Meaning:</b> Lasting only a very short time;")
    contains(html, "<p><b>Note:</b> Somewhat literary")
    contains(html, "<p><b>Example:</b> The fame")
    contains(html, '<hr/>\n<p class="tr"><b>RU:</b> мимолётный, недолговечный, эфемерный</p>')
    contains(html, '<p class="tr"><b>ES:</b> efímero, fugaz, pasajero</p>')
    local _, rules = html:gsub("<hr/>", "")
    eq(rules, 1, "one separator before the translations")
end)

test("answer HTML: escaping, Markdown leftovers, Cyrillic labels, colons in sentences", function()
    local html = Format.answerHtml("**тоска** → тоска (сущ.)\nЗначение: грусть <по дому> & печаль\nHe said this, and then: nothing happened at all\n")
    contains(html, '<p class="head"><b>тоска → тоска (сущ.)</b></p>')
    contains(html, "<p><b>Значение:</b> грусть &lt;по дому&gt; &amp; печаль</p>")
    contains(html, "<p>He said this, and then: nothing happened at all</p>")
    eq(Format.answerHtml(""), "")
end)

test("answer HTML: plain mode (custom prompts) has no bold headword", function()
    local html = Format.answerHtml("Imagine a soap bubble.\nIt is pretty, then it is gone.\nRU: мимолётный", { plain = true })
    contains(html, "<p>Imagine a soap bubble.</p>")
    lacks(html, 'class="head"')
    contains(html, '<p class="tr"><b>RU:</b> мимолётный</p>')
end)

-- Store --------------------------------------------------------------------------------------------

local function fakeSettings(initial)
    local data, flushes = initial or {}, 0
    return {
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        delSetting = function(_, k) data[k] = nil end,
        flush = function() flushes = flushes + 1 end,
        flushes = function() return flushes end,
    }
end

test("store add / pending / markSynced", function()
    local settings = fakeSettings()
    local store = Store.new(settings)
    local a = store:add{ word = "ephemeral", created_at = 100 }
    local b = store:add{ word = "тоска" }
    assert(a.id and b.id and a.id ~= b.id, "ids must be unique")
    eq(a.synced, false)
    eq(#store:pending(), 2)
    eq(store:markSynced({ a.id, "missing" }), 1)
    eq(#store:pending(), 1)
    eq(store:pending()[1].word, "тоска")
    eq(#store:all(), 2)
    eq(store:markSynced({ a.id }), 0, "already synced")
    assert(settings.flushes() >= 3, "store must flush to disk")
end)

-- Earlier answers ----------------------------------------------------------------------------------

local function answerKey(query, preset, targets)
    preset = preset or Presets.find("explain")
    local prompt = Prompt.build(query, { targets = targets or { "ru", "en", "es" }, preset = preset })
    return Cache.key(query.word, preset, prompt)
end

test("cache key: the same word, prompt and languages; not the passage", function()
    local base = answerKey(sample)
    eq(answerKey{ word = "  Ephemeral ", prev = "Fame is", next = ".", title = "Other", lang = "en" }, base,
        "letter case, spaces, passage and book are ignored")
    eq(answerKey{ word = "Однако", lang = "ru" }, answerKey{ word = "однако", lang = "ru" }, "Cyrillic capital")
    eq(answerKey{ word = "Ёлка", lang = "ru" }, answerKey{ word = "ёлка", lang = "ru" }, "Ё")
    eq(answerKey{ word = "Él", lang = "es" }, answerKey{ word = "él", lang = "es" }, "Latin-1 capital")
    contains(answerKey{ word = "ÀÉÎÕÜ×Я", lang = "fr" }, "àéîõü×я", "× has no lowercase")
    assert(answerKey(sample, Presets.find("eli5")) ~= base, "another prompt")
    assert(answerKey{ word = "ephemeral", lang = "fr" } ~= base, "another book language")
    assert(answerKey(sample, nil, { "ru" }) ~= base, "other translation languages")
    local custom = { id = "custom1", name = "Kid", template = "Explain {word}" }
    assert(answerKey(sample, custom) ~= answerKey(sample, { id = "custom1", name = "Kid", template = "Explain {word} simply" }),
        "editing a custom prompt asks again")
    eq(answerKey(sample, { id = "custom1", name = "Renamed", template = "Explain {word}" }), answerKey(sample, custom),
        "renaming it doesn't")
end)

test("cache: put / get, Ask AI again replaces, only the newest are kept", function()
    local settings = fakeSettings()
    local cache = Cache.new(settings, 2)
    eq(cache:get("a"), nil)
    eq(cache:put("a", { word = "a", text = "one", created_at = 100 }).created_at, 100)
    eq(cache:get("a").text, "one")
    cache:put("a", { word = "a", text = "two", created_at = 101 })
    eq(cache:get("a").text, "two", "a new answer replaces the earlier one")
    cache:put("b", { word = "b", text = "b", created_at = 102 })
    cache:put("c", { word = "c", text = "c", created_at = 103 })
    eq(cache:get("a"), nil, "the oldest is dropped")
    eq(cache:get("b").text, "b")
    assert(cache:put("d", { word = "d", text = "d" }).created_at > 103, "created_at defaults to now")
    eq(cache:get("b"), nil)
    assert(settings.flushes() >= 5, "cache must flush to disk")
end)

test("format: the earlier-answer note", function()
    eq(Format.earlierNote(os.time{ year = 2026, month = 10, day = 2, hour = 12 }),
        '<p class="note">Earlier answer · 2 Oct 2026</p>')
end)

-- Config -------------------------------------------------------------------------------------------

test("config: menu settings win over config.lua, empty means unset", function()
    local config = Config.new(fakeSettings{ claude_model = "claude-haiku-5-5", languages = "" }, {
        provider = "openai", claude_model = "claude-opus-5-5", languages = "en,es", claude_api_key = "",
    })
    eq(config:get("claude_model"), "claude-haiku-5-5")
    eq(config:get("languages"), "en,es", "empty menu value falls back to config.lua")
    eq(config:get("claude_api_key"), nil, "empty config.lua value is unset")
    eq(config:provider(), "openai")
    eq(table.concat(config:languages(), ","), "en,es")
    config:set("provider", "nope")
    eq(config:provider(), "claude", "unknown provider falls back to Claude")
    config:set("provider", "")
    eq(config:provider(), "openai", "clearing the menu value restores config.lua")
end)

test("config: provider defaults and backend", function()
    local config = Config.new(fakeSettings(), { claude_workspace_id = "wrkspc_x" })
    local claude = config:providerConfig("claude")
    eq(claude.model, Providers.DEFAULTS.claude.model)
    eq(claude.effort, "low")
    eq(claude.workspace_id, "wrkspc_x")
    eq(config:backendConfigured(), false)
    config:set("backend_url", "https://words.example")
    config:set("backend_token", "t")
    eq(config:backendConfigured(), true)
    eq(config:providerConfig("backend").base_url, "https://words.example")
end)

test("config: active prompt preset and custom prompts", function()
    local config = Config.new(fakeSettings(), {})
    eq(config:activePreset().id, "explain", "default")
    eq(#config:customPrompts(), 0)
    config:set("prompt", "grammar")
    eq(config:activePreset().id, "grammar")
    config:setCustomPrompts{ { id = "custom1", name = "Kid", template = "Explain {word}" }, { name = "bad", template = "no placeholder" } }
    eq(#config:customPrompts(), 1, "invalid custom prompts are dropped")
    config:set("prompt", "custom1")
    eq(config:activePreset().name, "Kid")
    config:setCustomPrompts{}
    eq(config:get("custom_prompts"), nil, "an empty list clears the setting")
    eq(config:activePreset().id, "explain", "the chosen custom prompt was deleted")
    local from_file = Config.new(fakeSettings(), { prompt = "eli5" })
    eq(from_file:activePreset().id, "eli5", "config.lua can preset it")
end)

-- Native reader bridge -----------------------------------------------------------------------------

test("native: dictionary popup open/close from syslog", function()
    local title = "title=L_D_N_non-centered_ID_com.lab126.booklet.reader_M_false_RD_false_FH_S_RC_false"
        .. "_A_SelectionDialogImpl_HC_true_FS_S:"
    eq(Native.parseSyslog("261012:140705 cvm[5127]: I KindleFrameFactory:WindowAdded:" .. title), "opened")
    eq(Native.parseSyslog("261012:140712 cvm[5127]: I KindleFrameFactory:WindowRemoved:" .. title), "closed")
    eq(Native.parseSyslog("261012:140705 cvm[5127]: I SelectionModeController:Information::Selection State SELECTION"), nil)
    eq(Native.parseSyslog("cvm[1]: I KindleFrameFactory:WindowAdded:title=L_D_ID_com.lab126.booklet.reader_A_TocDialog:"), nil)
end)

test("native: the newer reader's popup from syslog", function()
    local kpp = "261014:215008 KPPMainApp: [5392] "
    eq(Native.parseSyslog(kpp .. "[CABSelectionListener:INFO] selectionStabilized, selectionMode=1, willDisplayCAB=1"), "opened")
    eq(Native.parseSyslog(kpp .. "[CABSelectionListener:INFO] selectionStabilized, selectionMode=1, willDisplayCAB=0"), nil,
        "no popup shown")
    eq(Native.parseSyslog(kpp .. "[KUXSelectionListener:INFO] selectionStabilized called"), nil)
    eq(Native.parseSyslog(kpp .. "[KUXSelectionListener:INFO] selectionFinalized called"), "closed")
end)

test("native: popup watch folds the doubled log lines", function()
    local watch = Native.popupWatch(5)
    eq(watch:watching(100), false)
    watch:opened(100)
    eq(watch:watching(102), true)
    eq(watch.since, 98, "lookups from before the popup don't count")
    watch:opened(103) -- the same line again
    eq(watch.since, 98, "a repeated line keeps the popup's start")
    eq(watch:watching(107), true, "and extends the wait")
    eq(watch:watching(108), false)
    watch:found()
    eq(watch:watching(104), false, "found: stop looking")
    eq(watch:closed(), true)
    eq(watch:closed(), false, "the repeated close changes nothing")
    -- Tapping another word: the old popup closes and a new one opens.
    watch:opened(200)
    eq(watch.since, 198)
    eq(watch:watching(201), true)
end)

test("native: input split into lines", function()
    local lines, rest = Native.splitLines("one\ntwo\nthr")
    eq(#lines, 2)
    eq(lines[2], "two")
    eq(rest, "thr")
    lines, rest = Native.splitLines(rest .. "ee\n\n")
    eq(lines[1], "three")
    eq(lines[2], "")
    eq(rest, "")
    eq(#Native.splitLines("no newline"), 0)
end)

test("native: page messages to Lexi's window", function()
    eq(Native.parseUiOp("lexi:ready").op, "ready")
    eq(Native.parseUiOp("lexi:hide").op, "hide")
    local size = Native.parseUiOp("lexi:size 1170 93")
    eq(size.op, "size")
    eq(size.w, 1170)
    eq(size.h, 93)
    local pos = Native.parseUiOp("lexi:pos 51 -3")
    eq(pos.x, 51)
    eq(pos.y, -3)
    local ev = Native.parseUiOp('lexi:event lexiAskAs 1791814025648 eli5')
    eq(ev.name, "lexiAskAs")
    eq(ev.value, "1791814025648 eli5")
    eq(Native.parseUiOp('lexi:event lexiSave a"b\nc').value, "a b c", "quotes and control characters can't break the event line")
    eq(Native.parseUiOp("lexi:event lexiClosed").value, "")
    eq(Native.parseUiOp("lexi:size 12"), nil)
    eq(Native.parseUiOp("lexi:event notOurs x"), nil)
    eq(Native.parseUiOp("lexi:launch rockets"), nil)
    eq(Native.parseUiOp("TypeError: undefined is not a function"), nil)
end)

test("native: JavaScript string literals", function()
    eq(Native.jsString('{"a":"b\\c"}'), '"{\\"a\\":\\"b\\\\c\\"}"')
    eq(Native.jsString("one\ntwo\r"), '"one\\ntwo\\r"')
    eq(Native.jsString("x\226\128\168y\226\128\169z"), '"x\\u2028y\\u2029z"')
    eq(Native.jsString("тоска"), '"тоска"')
    eq(Native.jsString("a\tb\0"), '"a\\u0009b\\u0000"')
end)

test("native: lookup and prompt from an event payload", function()
    local id, preset = Native.splitAskAs("1791814025648 grammar")
    eq(id, "1791814025648")
    eq(preset, "grammar")
    id, preset = Native.splitAskAs("1791814025648")
    eq(id, "1791814025648")
    eq(preset, nil)
    local name, value = Native.parseEvent('lexiAskAgain "1791814025648 explain"')
    eq(name, "lexiAskAgain")
    id, preset = Native.splitAskAs(value)
    eq(id, "1791814025648")
    eq(preset, "explain")
end)

test("native: dialog events from Lexi's window", function()
    local name, value = Native.parseEvent('lexiAsk "1791814025648"')
    eq(name, "lexiAsk")
    eq(value, "1791814025648")
    name, value = Native.parseEvent('lexiClosed ""')
    eq(name, "lexiClosed")
    eq(value, "")
    eq(Native.parseEvent("lexiSave"), "lexiSave")
    eq(Native.parseEvent('261012:140705 lexi: lexiAsk "x"'), nil, "syslog lines are not events")
end)

test("native: lookup sentence split around the word", function()
    local prev, following, word = Native.splitUsage(
        "It is a truth universally acknowledged, that a single man in possession of a good fortune must be in want of a wife.",
        "acknowledged")
    eq(prev, "It is a truth universally ")
    eq(following, ", that a single man in possession of a good fortune must be in want of a wife.")
    eq(word, "acknowledged")
    prev, following, word = Native.splitUsage("School was out, and the school bus left.", "school")
    eq(word, "School", "keeps the book's capitalisation")
    eq(prev, "")
    prev, following, word = Native.splitUsage("Beginning in the end.", "in")
    eq(prev, "Beginning ", "whole word, not inside another word")
    prev, following, word = Native.splitUsage("Он почувствовал тоску и ушёл.", "тоску")
    eq(prev, "Он почувствовал ")
    eq(following, " и ушёл.")
    eq(word, "тоску")
    prev, following, word = Native.splitUsage("A sentence without it.", "missing")
    eq(prev, "A sentence without it.")
    eq(following, "")
    eq(word, nil)
end)

test("native: lookup row becomes a Lexi query", function()
    local q = Native.queryFromLookup{
        word = "civility", lang = "en", title = "Middlemarch", authors = "George Eliot",
        usage = "She answered with cold civility and left the room.",
    }
    eq(q.word, "civility")
    eq(q.prev, "She answered with cold ")
    eq(q.next, " and left the room.")
    eq(q.lang, "en")
    local prompt = Prompt.build(q, { targets = { "ru", "en", "es" } })
    contains(prompt.user, "⟦civility⟧ and left the room.")
    contains(prompt.user, 'Book: "Middlemarch" by George Eliot')
    eq(Native.queryFromLookup{ word = "x", book_lang = "es-ES", usage = "x" }.lang, "es-ES")
end)

test("native: shell quoting", function()
    eq(Native.shellQuote("plain"), "'plain'")
    eq(Native.shellQuote([[{"text":"it's"}]]), [['{"text":"it'\''s"}']])
end)

-- Phone setup --------------------------------------------------------------------------------------

local CLAUDE_KEY = "sk-ant-api03-" .. string.rep("x", 40) .. "WXYZ"

local function setupConfig(values)
    return Config.new(fakeSettings(values or {}), {})
end

test("setup: form decoding", function()
    local form = Setup.parseForm("provider=claude&claude_api_key=sk-ant-a%2Bb%3D&languages=ru%2C+es&empty=")
    eq(form.provider, "claude")
    eq(form.claude_api_key, "sk-ant-a+b=")
    eq(form.languages, "ru, es")
    eq(form.empty, "")
end)

test("setup: code is required; a device that keeps guessing is shut out, others are not", function()
    local config, state = setupConfig(), { code = "123456" }
    local attacker, phone = "192.168.1.66", "192.168.1.20"
    local status, body = Setup.handle(config, { method = "GET", path = "/", ip = attacker }, state)
    eq(status, 200)
    contains(body, "6-digit code")
    status, body = Setup.handle(config, { method = "POST", path = "/save", body = "provider=claude", ip = attacker }, state)
    eq(status, 403, "no code")
    eq(state.bad[attacker], nil, "a missing code is not a guess")
    for _ = 1, Setup.MAX_BAD_CODES do
        status, body = Setup.handle(config, { method = "GET", path = "/?c=999999", ip = attacker }, state)
    end
    eq(status, 403)
    status, body = Setup.handle(config, { method = "GET", path = "/?c=123456", ip = attacker }, state)
    eq(status, 403, "shut out even with the right code")
    contains(body, "Too many wrong codes from this device")
    status = Setup.handle(config, { method = "GET", path = "/?c=123456", ip = phone }, state)
    eq(status, 200, "the phone still gets in")
    eq(config:get("provider"), nil, "nothing saved")
end)

test("setup: requests are parsed from partial buffers with limits", function()
    eq(Setup.parseRequest("GET /?c=1 HTTP/1.1\r\nHost: k"), nil, "headers incomplete: wait")
    local r = Setup.parseRequest("GET /?c=1 HTTP/1.1\r\nHost: k\r\n\r\n")
    eq(r.method, "GET")
    eq(r.path, "/?c=1")
    eq(r.body, "")
    local post = "POST /save HTTP/1.1\r\nHost: k\r\nContent-Length: 9\r\n\r\n"
    eq(Setup.parseRequest(post .. "c=12"), nil, "body incomplete: wait")
    eq(Setup.parseRequest(post .. "c=123456&").body, "c=123456&")
    eq(Setup.parseRequest("garbage\r\n\r\n"), false, "not HTTP: drop")
    eq(Setup.parseRequest(string.rep("x", 20000)), false, "endless headers: drop")
    eq(Setup.parseRequest("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n"), false, "huge body: drop")
end)

test("setup: saves key, model, effort, languages; never shows the key back", function()
    local config, state = setupConfig(), { code = "123456" }
    local status, body = Setup.handle(config, { method = "GET", path = "/?c=123456" }, state)
    eq(status, 200)
    contains(body, 'name="claude_api_key"')
    contains(body, "Claude Opus 5.5 — best answers")
    local form = "c=123456&provider=claude&claude_api_key=" .. CLAUDE_KEY
        .. "&claude_model=claude-haiku-5-5&claude_effort=medium&openai_model=gpt-6-luna&openai_effort=low"
        .. "&claude_workspace_id=&languages=RU%2C+Spanish%2C+en"
    local outcome
    status, body, outcome = Setup.handle(config, { method = "POST", path = "/save", body = form }, state)
    eq(status, 200)
    eq(outcome, "saved")
    eq(config:get("claude_api_key"), CLAUDE_KEY)
    eq(config:get("claude_model"), "claude-haiku-5-5")
    eq(config:get("claude_effort"), "medium")
    eq(config:get("openai_model"), "gpt-6-luna")
    eq(config:get("languages"), "ru,es,en")
    eq(config:provider(), "claude")
    contains(body, "Claude Haiku 5.5 · medium effort · key …WXYZ")
    eq(Setup.summary(config, false), "Claude Haiku 5.5 · medium effort · key saved", "no key hint for logs")
    lacks(Setup.formPage(config, "123456"), CLAUDE_KEY, "form page")
    contains(Setup.formPage(config, "123456"), "Saved key …WXYZ")
end)

test("setup: rejects bad input without saving anything", function()
    local config = setupConfig()
    local summary, err = Setup.apply(config, { provider = "claude", claude_api_key = "sk-ant short" })
    eq(summary, nil)
    contains(err, "doesn't look right")
    summary, err = Setup.apply(config, { provider = "openai", openai_model = "gpt-6-luna" })
    contains(err, "Paste an API key for OpenAI")
    summary, err = Setup.apply(config, { provider = "claude", claude_api_key = CLAUDE_KEY, claude_model_custom = "bad model!" })
    contains(err, "model ID")
    summary, err = Setup.apply(config, { provider = "claude", claude_api_key = CLAUDE_KEY .. '"<x>' })
    contains(err, "doesn't look right")
    summary, err = Setup.apply(config, { provider = "claude", claude_api_key = CLAUDE_KEY,
        claude_workspace_id = "wrkspc_1\r\nX-Evil: 1" })
    contains(err, "workspace ID")
    eq(config:get("claude_api_key"), nil, "nothing saved on error")
    -- A custom model ID wins over the list; an empty key keeps the saved one.
    config:set("openai_api_key", "sk-proj-" .. string.rep("k", 30))
    summary = Setup.apply(config, { provider = "openai", openai_api_key = "  ", openai_model = "gpt-6.1-sol",
        openai_model_custom = "gpt-6.1-sol-2026-09-01", openai_effort = "extreme" })
    eq(config:get("openai_model"), "gpt-6.1-sol-2026-09-01")
    eq(config:get("openai_effort"), nil, "unknown effort ignored")
    contains(summary, "gpt-6.1-sol-2026-09-01 · low effort · key …kkkk")
end)

test("setup: page escapes stored values", function()
    local config = setupConfig{ claude_workspace_id = '"><script>x</script>' }
    local page = Setup.formPage(config, "123456")
    lacks(page, "<script>x", "workspace id")
    contains(page, "&quot;&gt;&lt;script&gt;")
end)

test("setup: the Prompt card lists the prompts and escapes custom ones", function()
    local config = setupConfig{
        prompt = "custom1",
        custom_prompts = { { id = "custom1", name = 'Kid "<b>"', template = "Explain {word} </textarea><script>" } },
    }
    local page = Setup.formPage(config, "123456")
    contains(page, '<input type="radio" name="prompt" value="eli5">')
    contains(page, "Explain like I'm 5")
    contains(page, 'value="Kid &quot;&lt;b&gt;&quot;"')
    contains(page, "Explain {word} &lt;/textarea&gt;&lt;script&gt;</textarea>")
    contains(page, 'value="row:1" checked')
    contains(page, "{translate_to}")
end)

test("setup: saves custom prompts and the chosen one", function()
    local config = setupConfig{ claude_api_key = CLAUDE_KEY,
        custom_prompts = { { id = "custom1", name = "Old", template = "Old {word}" } } }
    local summary, err = Setup.apply(config, {
        provider = "claude", prompt = "row:3",
        cp_id_1 = "custom1", cp_name_1 = "Kid", cp_text_1 = "Explain {word} to a child.",
        cp_id_2 = "", cp_name_2 = "", cp_text_2 = "  ",
        cp_id_3 = "", cp_name_3 = "Grammar nerd", cp_text_3 = "Parse {word} in {context}.",
    })
    assert(summary, err)
    local customs = config:customPrompts()
    eq(#customs, 2, "the empty row is skipped")
    eq(customs[1].id, "custom1")
    eq(customs[1].name, "Kid")
    eq(customs[2].id, "custom2")
    eq(config:activePreset().name, "Grammar nerd")
    contains(summary, "Grammar nerd")
    -- A built-in choice; removing every row clears the custom prompts.
    summary = Setup.apply(config, { provider = "claude", prompt = "grammar" })
    eq(config:activePreset().id, "grammar")
    eq(#config:customPrompts(), 0)
    -- Back to the default: the setting is cleared rather than stored.
    Setup.apply(config, { provider = "claude", prompt = "explain" })
    eq(config:get("prompt"), nil)
    -- A form without the Prompt card leaves prompts alone.
    config:set("prompt", "deep")
    Setup.apply(config, { provider = "claude" })
    eq(config:activePreset().id, "deep")
end)

test("setup: a bad custom prompt saves nothing", function()
    local config = setupConfig{ claude_api_key = CLAUDE_KEY }
    local summary, err = Setup.apply(config, { provider = "claude", claude_effort = "high", prompt = "row:1",
        cp_name_1 = "Joke", cp_text_1 = "Tell me a joke." })
    eq(summary, nil)
    contains(err, "{word} or {context}")
    eq(config:get("claude_effort"), nil, "nothing saved on error")
    -- An unknown choice falls back to the default; a name is made up for a nameless prompt.
    summary = Setup.apply(config, { provider = "claude", prompt = "row:9", cp_name_1 = "", cp_text_1 = "Hi {word}" })
    eq(config:activePreset().id, "explain")
    eq(config:customPrompts()[1].name, "Prompt 1")
end)

test("setup: room for long prompts in a request", function()
    local body = string.rep("x", 200000)
    local r = Setup.parseRequest("POST /save HTTP/1.1\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body)
    eq(#r.body, 200000)
end)

-- TLS host names -----------------------------------------------------------------------------------

test("tls: certificate host names", function()
    eq(Tls.hostMatches("api.anthropic.com", "api.anthropic.com"), true)
    eq(Tls.hostMatches("API.Anthropic.com", "api.anthropic.com"), true, "case-insensitive")
    eq(Tls.hostMatches("api.openai.com", "*.openai.com"), true)
    eq(Tls.hostMatches("openai.com", "*.openai.com"), false, "wildcard needs a label")
    eq(Tls.hostMatches("a.b.openai.com", "*.openai.com"), false, "wildcard covers one label")
    eq(Tls.hostMatches("evil.com", "*.com"), false, "too broad")
    eq(Tls.hostMatches("api.anthropic.com.evil.com", "api.anthropic.com"), false)
    local function cert(san, cn)
        return {
            extensions = function() return san and { ["2.5.29.17"] = { dNSName = san } } or {} end,
            subject = function() return { { oid = "2.5.4.3", name = "commonName", value = cn } } end,
        }
    end
    eq(Tls.certValidFor(cert({ "api.anthropic.com" }), "api.anthropic.com"), true)
    eq(Tls.certValidFor(cert({ "*.badssl.com" }), "wrong.host.badssl.com"), false)
    eq(Tls.certValidFor(cert(nil, "api.openai.com"), "api.openai.com"), true, "common name when no SAN")
    eq(Tls.certValidFor(cert({ "other.example" }, "api.openai.com"), "api.openai.com"), false, "SAN wins over CN")
end)

-- Syntax check of the KOReader-dependent files ------------------------------------------------------

for _, file in ipairs({ "main.lua", "_meta.lua", "lexi_http.lua", "lexi_client.lua", "lexi_viewer.lua",
        "native/lexid.lua", "native/cli.lua", "lexi_setupview.lua", "config.example.lua" }) do
    test("compiles: " .. file, function()
        local chunk, err = loadfile(plugin_dir .. "/" .. file)
        assert(chunk, err)
    end)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
