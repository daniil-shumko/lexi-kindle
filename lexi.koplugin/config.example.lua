-- Optional. The easy way to set Lexi up is "Set up from phone (QR code)" in KOReader's Lexi menu
-- or the "Lexi: Set up from phone" item in your library. If you prefer a file: copy this to config.lua
-- (same folder) and fill it in.
-- Anything changed later from the menus overrides this file. Never share or commit config.lua.
return {
    provider = "claude",               -- "claude" | "openai" | "backend" (your own server, see below)

    claude_api_key = "",               -- sk-ant-…  (platform.claude.com → API keys)
    claude_model = "claude-opus-5-5",  -- or "claude-sonnet-5-5", "claude-haiku-5-5" (fastest, cheapest)
    claude_effort = "low",             -- "low" | "medium" | "high"
    claude_workspace_id = "",          -- wrkspc_…  only if your key spans several workspaces

    openai_api_key = "",               -- sk-…  (platform.openai.com → API keys)
    openai_model = "gpt-6.1-sol",      -- or "gpt-6-astra" (most capable), "gpt-6-luna" (fastest, cheapest)
    openai_effort = "low",

    languages = "ru,en,es",            -- translate into these; the book's own language is skipped

    prompt = "explain",                -- "explain" | "eli5" | "translate" | "deep" | "grammar" | a custom prompt's id
    -- Your own prompts (up to 10), each with {word} or {context} in it (see README → Prompts):
    -- custom_prompts = {
    --     { id = "custom1", name = "Simple", template = "Explain “{word}” simply, as used here: {context}" },
    -- },

    -- Optional: your own server. Saved words sync to it; with provider = "backend" it also answers
    -- lookups. The contract: docs/how-it-works.md → "Your own backend".
    backend_url = "",
    backend_token = "",
}
