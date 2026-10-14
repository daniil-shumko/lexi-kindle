--[[--
Request builders and response parsers for the AI providers, plus the personal-backend contract.

Pure Lua with no KOReader dependencies: requests are plain tables ({ url, headers, body }) and
responses are decoded JSON tables, so everything here is unit-testable with plain LuaJIT.

@module lexi_providers
--]]

local Providers = {}

Providers.DEFAULTS = {
    claude = { model = "claude-opus-5-5", effort = "low", base_url = "https://api.anthropic.com" },
    openai = { model = "gpt-6.1-sol", effort = "low", base_url = "https://api.openai.com" },
    backend = {},
}

Providers.LABELS = { claude = "Claude", openai = "OpenAI", backend = "my backend" }

-- Offered in the menus and on the phone setup page; any other model ID can still be typed in.
Providers.MODELS = {
    claude = {
        { id = "claude-opus-5-5", label = "Claude Opus 5.5", note = "best answers" },
        { id = "claude-sonnet-5-5", label = "Claude Sonnet 5.5", note = "balanced" },
        { id = "claude-haiku-5-5", label = "Claude Haiku 5.5", note = "fastest, cheapest" },
    },
    openai = {
        { id = "gpt-6.1-sol", label = "GPT-6.1 Sol", note = "balanced" },
        { id = "gpt-6-astra", label = "GPT-6 Astra", note = "most capable, pricier" },
        { id = "gpt-6-luna", label = "GPT-6 Luna", note = "fastest, cheapest" },
    },
}

Providers.EFFORTS = { "low", "medium", "high" }

--- "Claude Opus 5.5" for a known model ID, otherwise the ID itself.
function Providers.modelLabel(provider, id)
    for _, m in ipairs(Providers.MODELS[provider] or {}) do
        if m.id == id then return m.label end
    end
    return id
end

-- Enough room for low-effort thinking plus a ~120-word answer.
local MAX_OUTPUT_TOKENS = 8000

-- Claude models that accept server-side refusal fallbacks ("fallbacks": "default").
local CLAUDE_FALLBACK_MODELS = {
    ["claude-fable-5-1"] = true,
    ["claude-opus-5-5"] = true,
    ["claude-opus-5"] = true,
    ["claude-sonnet-5-5"] = true,
}

local function present(s)
    return type(s) == "string" and s ~= ""
end

local function stripSlash(url)
    return (url:gsub("/+$", ""))
end

local builders = {}

function builders.claude(cfg, _, prompt)
    if not present(cfg.api_key) then return nil, "Claude API key is not set." end
    local headers = {
        ["x-api-key"] = cfg.api_key,
        ["anthropic-version"] = "2023-06-01",
    }
    -- Required when the key spans several workspaces ("This API key is not scoped to a workspace").
    if present(cfg.workspace_id) then
        headers["anthropic-workspace-id"] = cfg.workspace_id
    end
    local body = {
        model = cfg.model,
        max_tokens = MAX_OUTPUT_TOKENS,
        system = prompt.system,
        messages = { { role = "user", content = prompt.user } },
        output_config = { effort = cfg.effort },
    }
    if CLAUDE_FALLBACK_MODELS[cfg.model] then
        headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        body.fallbacks = "default"
    end
    -- Haiku 5.x can skip thinking entirely (allowed at effort "high" or below): fastest answers.
    if cfg.model:match("^claude%-haiku%-5") and cfg.effort ~= "xhigh" and cfg.effort ~= "max" then
        body.thinking = { type = "disabled" }
    end
    return { url = stripSlash(cfg.base_url) .. "/v1/messages", headers = headers, body = body }
end

function builders.openai(cfg, _, prompt)
    if not present(cfg.api_key) then return nil, "OpenAI API key is not set." end
    return {
        url = stripSlash(cfg.base_url) .. "/v1/responses",
        headers = { ["Authorization"] = "Bearer " .. cfg.api_key },
        body = {
            model = cfg.model,
            instructions = prompt.system,
            input = prompt.user,
            reasoning = { effort = cfg.effort },
            max_output_tokens = MAX_OUTPUT_TOKENS,
            store = false,
        },
    }
end

-- Personal backend (phase 2): it owns the built-in prompts and the provider keys; the Kindle sends raw
-- context, the prompt preset id and, for a custom prompt, its text.
function builders.backend(cfg, query, prompt)
    if not present(cfg.base_url) then return nil, "Backend URL is not set." end
    if not present(cfg.token) then return nil, "Backend device token is not set." end
    return {
        url = stripSlash(cfg.base_url) .. "/v1/explain",
        headers = { ["Authorization"] = "Bearer " .. cfg.token },
        body = {
            word = query.word,
            context = { prev = query.prev, next = query.next },
            book = { title = query.title, authors = query.authors, language = query.lang },
            explain_language = prompt.explain_lang,
            -- Omitted when empty: rapidjson would encode an empty Lua table as {} rather than [].
            translate_to = #prompt.targets > 0 and prompt.targets or nil,
            -- The built-in prompt's id ("explain", "eli5", …); a custom prompt also sends its text.
            preset = prompt.preset,
            prompt = prompt.custom and { system = prompt.system, user = prompt.user } or nil,
        },
    }
end

--- Builds an HTTP request. Returns { url, headers, body } or nil, error message.
function Providers.build(id, cfg, query, prompt)
    local builder = builders[id]
    if not builder then return nil, "Unknown AI provider: " .. tostring(id) end
    return builder(cfg, query, prompt)
end

local parsers = {}

function parsers.claude(data)
    if data.stop_reason == "refusal" then
        return nil, "Claude declined to answer this request."
    end
    local parts = {}
    for _, block in ipairs(data.content or {}) do
        if block.type == "text" and present(block.text) then
            table.insert(parts, block.text)
        end
    end
    if #parts == 0 then
        if data.stop_reason == "max_tokens" then
            return nil, "The answer was cut off before any text (max_tokens)."
        end
        return nil, "Claude returned no text."
    end
    return table.concat(parts, "\n")
end

function parsers.openai(data)
    local parts = {}
    for _, item in ipairs(data.output or {}) do
        if item.type == "message" then
            for _, c in ipairs(item.content or {}) do
                if c.type == "output_text" and present(c.text) then
                    table.insert(parts, c.text)
                elseif c.type == "refusal" then
                    return nil, "OpenAI declined to answer this request."
                end
            end
        end
    end
    if #parts == 0 then
        local reason = type(data.incomplete_details) == "table" and data.incomplete_details.reason
        if present(reason) then return nil, "OpenAI response incomplete: " .. reason end
        return nil, "OpenAI returned no text."
    end
    return table.concat(parts, "\n")
end

function parsers.backend(data)
    if present(data.text) then return data.text end
    return nil, "Backend returned no text."
end

--- Extracts the answer text from a decoded response. Returns text or nil, error message.
function Providers.parse(id, data)
    if type(data) ~= "table" then return nil, "Empty response." end
    local parser = parsers[id]
    if not parser then return nil, "Unknown AI provider: " .. tostring(id) end
    return parser(data)
end

-- Provider error messages can echo part of the API key back (e.g. "Incorrect API key provided: sk-ab***yz").
local function redactKeys(message)
    return (message:gsub("sk%-[%w%-_%*]+", "sk-…"))
end

--- Pulls a human-readable message out of an error response body, if there is one.
function Providers.errorMessage(data)
    if type(data) ~= "table" then return nil end
    local err = data.error
    if type(err) == "table" and present(err.message) then return redactKeys(err.message) end
    if present(err) then return redactKeys(err) end
    if present(data.message) then return redactKeys(data.message) end
    return nil
end

--- Request that uploads one saved word to the personal backend.
function Providers.wordUpload(base_url, token, word)
    return {
        url = stripSlash(base_url) .. "/v1/words",
        headers = { ["Authorization"] = "Bearer " .. token },
        body = {
            id = word.id,
            word = word.word,
            context = { prev = word.prev, next = word.next },
            book = { title = word.title, authors = word.authors, language = word.lang },
            answer = word.answer,
            provider = word.provider,
            model = word.model,
            preset = word.preset,
            created_at = word.created_at,
            -- Words saved before the reader was recorded all came from KOReader.
            source = word.source or "koreader",
        },
    }
end

return Providers
