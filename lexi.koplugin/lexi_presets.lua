--[[--
Prompt presets: the built-in ways to ask about a selection ("Explain & translate", "Explain like
I'm 5", …) and the reader's own custom prompts with placeholders.

Pure Lua with no KOReader dependencies, so it can be unit-tested with plain LuaJIT.

A built-in preset has its own rules (system prompt) and answer layout, filled in from the lookup
context that lexi_prompt.lua builds. A custom preset is { id, name, template }: the template is sent
as written, with placeholders such as {word} and {context} filled in.

@module lexi_presets
--]]

local Presets = {}

Presets.DEFAULT = "explain"
Presets.MAX_CUSTOM = 10
Presets.MAX_NAME = 40 -- characters
Presets.MAX_TEMPLATE = 2000 -- characters

--- What a custom prompt can use, in the order the help text lists them.
Presets.PLACEHOLDERS = {
    { "word", "the word or phrase you selected" },
    { "context", "the passage around it, with the selection marked ⟦ ⟧" },
    { "before", "the text before the selection" },
    { "after", "the text after the selection" },
    { "book", "the book's title" },
    { "author", "the book's author" },
    { "book_language", "the book's language, e.g. English (or unknown)" },
    { "explain_language", "the book's language, or \"the language of the passage\"" },
    { "translate_to", "your translation languages except the book's, e.g. Russian, Spanish" },
}

local INTRO = "You are a vocabulary helper built into an e-ink e-reader. The reader selected a word or short "
    .. "phrase in a book and wants to understand it exactly as it is used in the passage."
local PLAIN = "Plain text only. No Markdown (no asterisks, #, bullet dashes or tables): the screen cannot render it."
local IN_CONTEXT = "Explain the meaning in this context, not every dictionary sense."
local LAYOUT = "Follow the answer layout you are given exactly."

local function system(rules)
    return INTRO .. "\n\nRules:\n- " .. table.concat(rules, "\n- ")
end

--- The system prompt for custom prompts: only what the e-ink screen needs.
Presets.BASE_SYSTEM = "You are a reading helper built into an e-ink e-reader. The reader selected a word or "
    .. "short phrase in a book and asks about it below.\n\nRules:\n- " .. PLAIN
    .. "\n- Keep the answer short enough to read on a small screen, unless the reader asks for more."

local HEADWORD = "<selection> → <dictionary form> (<part of speech>)"

-- "RU: <Russian translation>" for each target language; nothing when there are none.
local function translations(ctx, add)
    if #ctx.targets == 0 then return end
    add("")
    for i, code in ipairs(ctx.targets) do
        add(string.format("%s: <%s translation>", code:upper(), ctx.target_names[i]))
    end
    if not ctx.book_lang then
        add("(Skip the translation line for the language the passage is written in.)")
    end
end

local BUILTINS = {
    {
        id = "explain",
        name = "Explain & translate",
        description = "Meaning in this context, a note, an example and translations.",
        system = system{
            PLAIN,
            "Be brief: at most about 120 words in total.",
            IN_CONTEXT .. " If it is an idiom, slang, a proper name or used figuratively, say so.",
            "If the selection is an inflected form, give the dictionary form.",
            "Translations must fit this context; give 1 to 3 options per language, most fitting first.",
            LAYOUT,
        },
        layout = function(ctx, add)
            add(HEADWORD)
            add(string.format("Meaning: <1-2 sentences in %s>", ctx.explain_in))
            add("Note: <optional nuance, register or idiom; omit this line if there is nothing useful>")
            add(string.format("Example: <one short new example sentence in %s>", ctx.explain_in))
            translations(ctx, add)
        end,
    },
    {
        id = "eli5",
        name = "Explain like I'm 5",
        description = "Very simple words, an everyday comparison and an easy example.",
        system = system{
            PLAIN,
            "Be brief: at most about 100 words in total.",
            "Explain it the way you would to a five-year-old: short sentences and everyday words, no jargon, "
                .. "never condescending.",
            IN_CONTEXT,
            "Translations must fit this context; give 1 or 2 simple options per language.",
            LAYOUT,
        },
        layout = function(ctx, add)
            add("<selection> → <dictionary form>")
            add(string.format("Simply: <1-3 very simple sentences in %s>", ctx.explain_in))
            add(string.format("Like: <one everyday comparison a child would understand, in %s>", ctx.explain_in))
            add(string.format("Example: <one very simple example sentence in %s>", ctx.explain_in))
            translations(ctx, add)
        end,
    },
    {
        id = "translate",
        name = "Translation only",
        description = "Just the translations that fit this passage.",
        system = system{
            PLAIN,
            "Be very brief: only the lines of the layout, nothing else.",
            "If the selection is an inflected form, give the dictionary form.",
            "Translations must fit this context; give 1 to 3 options per language, most fitting first.",
            LAYOUT,
        },
        layout = function(ctx, add)
            add(HEADWORD)
            if #ctx.targets == 0 then
                -- Every translation language is the book's own: say what it means instead.
                add(string.format("Meaning: <one short sentence in %s>", ctx.explain_in))
            end
            translations(ctx, add)
        end,
    },
    {
        id = "deep",
        name = "Deep dive",
        description = "Meaning, origin, synonyms, register and more examples.",
        system = system{
            PLAIN,
            "At most about 250 words in total.",
            "Start with the meaning in this context, then go wider.",
            "If you are not sure about the origin, say so briefly instead of guessing.",
            "Translations must fit this context; give 1 to 3 options per language, most fitting first.",
            LAYOUT,
        },
        layout = function(ctx, add)
            add(HEADWORD)
            add(string.format("Meaning: <1-2 sentences in %s>", ctx.explain_in))
            add(string.format("Origin: <short etymology in %s>", ctx.explain_in))
            add("Synonyms: <2-4 synonyms that fit this context>")
            add("Antonyms: <1-3 antonyms; omit this line if there are none>")
            add(string.format("Register: <formal, informal, literary, dated, regional…: a short phrase in %s>", ctx.explain_in))
            add(string.format("Example: <a short new example sentence in %s>", ctx.explain_in))
            add(string.format("Example: <another one, using a different sense or construction, in %s>", ctx.explain_in))
            translations(ctx, add)
        end,
    },
    {
        id = "grammar",
        name = "Grammar",
        description = "The form used here, how it is built and why.",
        system = system{
            PLAIN,
            "Be brief: at most about 150 words in total.",
            "Describe the grammar of the selection as it is used in this sentence.",
            "If the selection is an inflected form, give the dictionary form.",
            "Translations must fit this context; give 1 to 3 options per language, most fitting first.",
            LAYOUT,
        },
        layout = function(ctx, add)
            add(HEADWORD)
            add(string.format("Form: <the grammatical form here: tense, mood, case, number, gender, person… in %s>", ctx.explain_in))
            add(string.format("Built: <how it is built from the dictionary form: stem, endings, irregularities, in %s>", ctx.explain_in))
            add(string.format("Why here: <why this form is used in this sentence, in %s>", ctx.explain_in))
            add(string.format("Example: <one short new sentence with the same form, in %s>", ctx.explain_in))
            translations(ctx, add)
        end,
    },
}

local BY_ID = {}
for _, p in ipairs(BUILTINS) do BY_ID[p.id] = p end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Length in characters (UTF-8 continuation bytes don't count).
local function ulen(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

function Presets.builtins()
    return BUILTINS
end

function Presets.isCustom(preset)
    return preset ~= nil and preset.template ~= nil
end

--- Built-ins first, then the custom prompts.
function Presets.list(customs)
    local out = {}
    for _, p in ipairs(BUILTINS) do table.insert(out, p) end
    for _, p in ipairs(customs or {}) do table.insert(out, p) end
    return out
end

--- The preset with this id; the default one when it is unknown (e.g. a deleted custom prompt).
function Presets.find(id, customs)
    if BY_ID[id] then return BY_ID[id] end
    for _, p in ipairs(customs or {}) do
        if p.id == id then return p end
    end
    return BY_ID[Presets.DEFAULT]
end

--- Checks a custom prompt { id, name, template }. Returns a trimmed copy, or nil and a message.
function Presets.validate(p)
    local name, template = trim(p and p.name), trim(p and p.template)
    if name == "" then return nil, "Give the prompt a name." end
    if ulen(name) > Presets.MAX_NAME then
        return nil, string.format("Keep the prompt name under %d characters.", Presets.MAX_NAME)
    end
    if template == "" then return nil, string.format("Write the text of “%s”.", name) end
    if ulen(template) > Presets.MAX_TEMPLATE then
        return nil, string.format("“%s” is too long: keep it under %d characters.", name, Presets.MAX_TEMPLATE)
    end
    if not (template:find("{word}", 1, true) or template:find("{context}", 1, true)) then
        return nil, string.format("“%s” must use {word} or {context}, or the AI won't know what you selected.", name)
    end
    return { id = p.id, name = name, template = template }
end

--- An id for a new custom prompt: "custom" plus the next free number.
function Presets.newId(customs)
    local max = 0
    for _, p in ipairs(customs or {}) do
        local n = tonumber(tostring(p.id):match("^custom(%d+)$"))
        if n and n > max then max = n end
    end
    return "custom" .. (max + 1)
end

--- Keeps the valid custom prompts (settings can be edited by hand), each with a unique id.
function Presets.sanitize(list)
    local out, seen = {}, {}
    for _, p in ipairs(type(list) == "table" and list or {}) do
        local valid = type(p) == "table" and Presets.validate(p)
        if valid and #out < Presets.MAX_CUSTOM then
            if type(valid.id) ~= "string" or valid.id == "" or seen[valid.id] or BY_ID[valid.id] then
                valid.id = Presets.newId(out)
            end
            seen[valid.id] = true
            table.insert(out, valid)
        end
    end
    return out
end

--- Fills {name} placeholders in one pass: values are never expanded again, unknown ones stay.
function Presets.render(template, vars)
    return (template:gsub("{([%a_]+)}", function(name)
        local value = vars[name]
        if value ~= nil then return tostring(value) end
    end))
end

--- Placeholder values from a lookup context (see Prompt.context).
function Presets.vars(ctx)
    return {
        word = ctx.word,
        context = trim(ctx.passage),
        before = ctx.before,
        after = ctx.after,
        book = ctx.title or "",
        author = ctx.authors or "",
        book_language = ctx.book_language or "unknown",
        explain_language = ctx.explain_in,
        translate_to = table.concat(ctx.target_names, ", "),
    }
end

--- System and user prompt for a preset and a lookup context. @treturn string system, string user
function Presets.build(preset, ctx)
    if Presets.isCustom(preset) then
        return Presets.BASE_SYSTEM, Presets.render(preset.template, Presets.vars(ctx))
    end
    local lines = {}
    local function add(s) table.insert(lines, s) end
    if ctx.title then
        local by = ctx.authors and (" by " .. ctx.authors) or ""
        add(string.format('Book: "%s"%s', ctx.title, by))
    end
    add(string.format("Selected: %s", ctx.word))
    add("Passage (selection marked with ⟦ ⟧):")
    add(ctx.passage)
    add("")
    add("Answer in this layout:")
    preset.layout(ctx, add)
    return preset.system, table.concat(lines, "\n")
end

return Presets
