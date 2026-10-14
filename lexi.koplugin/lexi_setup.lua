--[[--
Set up Lexi from a phone: a small, temporary web page on the Kindle's Wi-Fi address where you paste
an API key, pick the provider, model, effort, languages and prompt, and write your own prompts
(typing a 100-character key or a long prompt on an e-ink keyboard is the alternative). Used by the KOReader menu and, outside KOReader, by native/cli.lua.

Safety: the page needs a random 6-digit code (part of the QR code), locks after 5 wrong codes, stops
after one save or 10 minutes, and never shows a saved key back. It is plain HTTP on the local
network, so use it on a network you trust.

Everything except Setup.start (LuaSocket) is pure Lua and unit-tested.

@module lexi_setup
--]]

local Presets = require("lexi_presets")
local Prompt = require("lexi_prompt")
local Providers = require("lexi_providers")

local Setup = {}

Setup.PORT = 8642
Setup.TIMEOUT_S = 600
Setup.MAX_BAD_CODES = 5

local PROVIDERS = { "claude", "openai" }
local KEY_LINKS = {
    claude = "https://platform.claude.com/settings/keys",
    openai = "https://platform.openai.com/api-keys",
}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function esc(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

function Setup.urlDecode(s)
    s = tostring(s or ""):gsub("%+", " ")
    return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

--- "a=1&b=x%20y" → { a = "1", b = "x y" }
function Setup.parseForm(body)
    local out = {}
    for pair in tostring(body or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k and k ~= "" then out[Setup.urlDecode(k)] = Setup.urlDecode(v) end
    end
    return out
end

--- "…abcd" for a saved key, so the page can say a key exists without revealing it.
function Setup.mask(key)
    if not key or key == "" then return nil end
    return "…" .. key:sub(-4)
end

--- Six random digits, from /dev/urandom when available.
function Setup.newCode()
    local n
    local f = io.open("/dev/urandom", "rb")
    if f then
        local b = f:read(4)
        f:close()
        if b and #b == 4 then
            n = ((b:byte(1) * 256 + b:byte(2)) * 256 + b:byte(3)) * 256 + b:byte(4)
        end
    end
    if not n then
        math.randomseed(os.time())
        n = math.random(0, 999999)
    end
    return string.format("%06d", n % 1000000)
end

--- The Kindle's address on Wi-Fi, or nil.
function Setup.localAddress()
    for _, cmd in ipairs({ "ip -4 addr show wlan0 2>/dev/null", "ifconfig wlan0 2>/dev/null" }) do
        local p = io.popen(cmd)
        if p then
            local out = p:read("*a") or ""
            p:close()
            local ip = out:match("inet (%d+%.%d+%.%d+%.%d+)") or out:match("inet addr:(%d+%.%d+%.%d+%.%d+)")
            if ip then return ip end
        end
    end
end

--- One line describing the active settings, e.g. "Claude Opus 5.5 · low effort · key …abcd".
-- show_key_hint = false says only "key saved" (for the system log and the e-ink status line).
function Setup.summary(config, show_key_hint)
    local provider = config:provider()
    local cfg = config:providerConfig(provider)
    local parts = { Providers.modelLabel(provider, cfg.model) or Providers.LABELS[provider] }
    if cfg.effort then table.insert(parts, cfg.effort .. " effort") end
    if not cfg.api_key then
        table.insert(parts, "no API key")
    else
        table.insert(parts, show_key_hint == false and "key saved" or ("key " .. Setup.mask(cfg.api_key)))
    end
    local preset = config:activePreset()
    if preset.id ~= Presets.DEFAULT then table.insert(parts, preset.name) end
    return table.concat(parts, " · ")
end

-- Pages ------------------------------------------------------------------------------------------

local CSS = [[
:root { color-scheme: light dark; --bg: #f5f3ee; --card: #fff; --ink: #1d1c1a; --muted: #6f6b64;
  --line: #e2ded6; --accent: #1d1c1a; --on-accent: #fff; --ok: #1f7a4d; --bad: #b3261e; }
@media (prefers-color-scheme: dark) { :root { --bg: #151514; --card: #1f1e1c; --ink: #f1efe9;
  --muted: #a39e94; --line: #34322e; --accent: #f1efe9; --on-accent: #151514; --ok: #6fd3a0; --bad: #ff8a80; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { max-width: 540px; margin: 0 auto; padding: 28px 16px 48px; }
.brand { font: 700 30px/1 Georgia, "Times New Roman", serif; letter-spacing: -0.5px; margin: 0; }
.lead { color: var(--muted); margin: 6px 0 22px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 18px; margin: 0 0 14px; }
.card h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); margin: 0 0 10px; }
label { display: block; font-weight: 600; margin: 14px 0 6px; }
.hint { color: var(--muted); font-size: 14px; font-weight: 400; margin: 6px 0 0; }
.hint a { color: inherit; }
input[type=text], input[type=password], input[type=tel], select, textarea { width: 100%; font: inherit; color: inherit; padding: 12px;
  border: 1px solid var(--line); border-radius: 12px; background: transparent; }
textarea { min-height: 150px; resize: vertical; }
.choice { display: flex; gap: 12px; align-items: flex-start; font-weight: 400; margin: 10px 0 0; }
.choice input { margin-top: 5px; }
.choice b { display: block; } .choice small { display: block; color: var(--muted); font-size: 14px; }
.custom { border-top: 1px solid var(--line); margin-top: 16px; padding-top: 4px; }
.row { display: flex; gap: 8px; margin-top: 10px; }
.row .choice { flex: 1; margin: 0; align-items: center; }
button.small { width: auto; font-size: 15px; padding: 10px 14px; margin: 0; background: transparent; color: var(--ink);
  border: 1px solid var(--line); }
#add { margin-top: 16px; }
code { font-size: 14px; }
ul.ph { padding-left: 18px; margin: 8px 0 0; } ul.ph li { margin: 2px 0; }
.seg { display: flex; gap: 8px; }
.seg label { flex: 1; margin: 0; }
.seg input { position: absolute; opacity: 0; }
.seg span { display: block; text-align: center; padding: 12px; border: 1px solid var(--line); border-radius: 12px; }
.seg input:checked + span { background: var(--accent); color: var(--on-accent); border-color: var(--accent); }
details { margin-top: 14px; } summary { color: var(--muted); cursor: pointer; }
button { width: 100%; font-family: inherit; font-size: 17px; font-weight: 600; padding: 16px; border: 0; border-radius: 14px;
  background: var(--accent); color: var(--on-accent); margin-top: 6px; cursor: pointer; }
.msg { border-radius: 12px; padding: 12px 14px; margin: 0 0 14px; font-weight: 600; }
.msg.bad { background: color-mix(in srgb, var(--bad) 14%, transparent); color: var(--bad); }
.done { text-align: center; padding: 36px 18px; }
.done .tick { font-size: 54px; color: var(--ok); line-height: 1; }
.foot { color: var(--muted); font-size: 13px; text-align: center; margin-top: 18px; }
]]

local function shell(title, body)
    return table.concat({
        '<!doctype html><html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        '<meta name="referrer" content="no-referrer">',
        "<title>", esc(title), "</title><style>", CSS, "</style></head><body><main>",
        '<p class="brand">Lexi</p>', body,
        '<p class="foot">This page stops after one save or 10 minutes. Keys stay on your Kindle and go only to the provider you pick.',
        " It is plain HTTP on your local network: use it on Wi-Fi you trust, not public Wi-Fi.</p>",
        "</main></body></html>",
    })
end

local function message(text)
    return text and ('<p class="msg bad">' .. esc(text) .. "</p>") or ""
end

function Setup.codePage(err)
    return shell("Lexi setup", table.concat({
        '<p class="lead">Enter the 6-digit code shown on your Kindle.</p>', message(err),
        '<form class="card" method="get" action="/"><label for="c">Code</label>',
        '<input id="c" name="c" type="tel" inputmode="numeric" autocomplete="one-time-code" maxlength="6" autofocus>',
        '<button type="submit">Continue</button></form>',
    }))
end

local function options(provider, current)
    local out, known = {}, false
    for _, m in ipairs(Providers.MODELS[provider]) do
        known = known or m.id == current
        table.insert(out, string.format('<option value="%s"%s>%s — %s</option>',
            esc(m.id), m.id == current and " selected" or "", esc(m.label), esc(m.note)))
    end
    if current and not known then
        table.insert(out, string.format('<option value="%s" selected>%s</option>', esc(current), esc(current)))
    end
    return table.concat(out)
end

local function efforts(current)
    local out = {}
    for _, e in ipairs(Providers.EFFORTS) do
        local note = e == "low" and " — fastest (recommended)" or e == "high" and " — slower, more thorough" or ""
        table.insert(out, string.format('<option value="%s"%s>%s%s</option>', e, e == current and " selected" or "", e, note))
    end
    return table.concat(out)
end

local function providerCard(config, id, active)
    local cfg = config:providerConfig(id)
    local saved = Setup.mask(cfg.api_key)
    local link = KEY_LINKS[id]
    local parts = {
        string.format('<section class="card" id="card-%s"%s><h2>%s</h2>', id, active and "" or " hidden", Providers.LABELS[id]),
        string.format('<label for="%s_api_key">API key</label>', id),
        string.format('<input id="%s_api_key" name="%s_api_key" type="password" autocomplete="off" spellcheck="false" placeholder="%s">',
            id, id, esc(saved and ("Saved key " .. saved .. " — paste to replace") or "Paste your key")),
        string.format('<p class="hint">Create one at <a href="%s">%s</a>.</p>', link, (link:gsub("^https://", ""))),
        string.format('<label for="%s_model">Model</label><select id="%s_model" name="%s_model">%s</select>', id, id, id, options(id, cfg.model)),
        string.format('<label for="%s_effort">Reasoning effort</label><select id="%s_effort" name="%s_effort">%s</select>', id, id, id, efforts(cfg.effort)),
        "<details><summary>Advanced</summary>",
        string.format('<label for="%s_model_custom">Other model ID</label>', id),
        string.format('<input id="%s_model_custom" name="%s_model_custom" type="text" autocomplete="off" spellcheck="false" placeholder="Leave empty to use the list above">', id, id),
    }
    if id == "claude" then
        table.insert(parts, '<label for="claude_workspace_id">Workspace ID</label>')
        table.insert(parts, string.format('<input id="claude_workspace_id" name="claude_workspace_id" type="text" autocomplete="off" spellcheck="false" value="%s" placeholder="wrkspc_… (only for keys that span several workspaces)">',
            esc(cfg.workspace_id or "")))
    end
    table.insert(parts, "</details></section>")
    return table.concat(parts)
end

-- One custom prompt's fields. n: the row number in the form; p: { id, name, template } or nil.
local function customRow(n, p, active)
    return table.concat({
        '<div class="custom" data-row="', n, '">',
        string.format('<input type="hidden" name="cp_id_%s" value="%s">', n, esc(p and p.id or "")),
        string.format('<label for="cp_name_%s">Name</label><input id="cp_name_%s" name="cp_name_%s" type="text" maxlength="%d" value="%s" placeholder="e.g. Simple explanation">',
            n, n, n, Presets.MAX_NAME, esc(p and p.name or "")),
        string.format('<label for="cp_text_%s">Prompt</label><textarea id="cp_text_%s" name="cp_text_%s" maxlength="%d" spellcheck="false" placeholder="Explain {word} in {context} in simple words.">%s</textarea>',
            n, n, n, Presets.MAX_TEMPLATE, esc(p and p.template or "")),
        '<div class="row"><label class="choice"><input type="radio" name="prompt" value="row:', n, '"',
        active and " checked" or "", '><span>Use this prompt</span></label>',
        '<button type="button" class="small remove">Remove</button></div></div>',
    })
end

local function promptCard(config)
    local active = config:activePreset().id
    local parts = {
        '<section class="card"><h2>Prompt</h2>',
        '<p class="hint">How Lexi asks the AI about a word. On the Kindle, <b>Ask again as…</b> re-asks a word with another prompt.</p>',
    }
    for _, p in ipairs(Presets.builtins()) do
        table.insert(parts, string.format('<label class="choice"><input type="radio" name="prompt" value="%s"%s><span><b>%s</b><small>%s</small></span></label>',
            p.id, p.id == active and " checked" or "", esc(p.name), esc(p.description)))
    end
    table.insert(parts, '<label style="margin-top:22px">Your prompts</label><div id="customs">')
    for i, p in ipairs(config:customPrompts()) do
        table.insert(parts, customRow(i, p, p.id == active))
    end
    table.insert(parts, "</div>")
    table.insert(parts, string.format('<button type="button" class="small" id="add">Add a prompt</button>'
        .. '<template id="row-template">%s</template>', customRow("N", nil, false)))
    local items = {}
    for _, ph in ipairs(Presets.PLACEHOLDERS) do
        table.insert(items, string.format("<li><code>{%s}</code> %s</li>", ph[1], esc(ph[2])))
    end
    table.insert(parts, string.format('<details><summary>Placeholders you can use</summary><ul class="ph">%s</ul>'
        .. '<p class="hint">Use at least {word} or {context}. Lexi adds the rule "plain text, no Markdown" for the e-ink screen.</p></details>',
        table.concat(items)))
    table.insert(parts, "</section>")
    return table.concat(parts)
end

-- Adds and removes custom prompt rows; the server sorts out the ids.
local PROMPT_SCRIPT = [[
<script>(function () {
var list = document.getElementById('customs'), tpl = document.getElementById('row-template');
var next = list.querySelectorAll('.custom').length + 1;
function wire(row) {
  row.querySelector('.remove').addEventListener('click', function () {
    var r = row.querySelector('input[type=radio]');
    if (r.checked) document.querySelector('input[name=prompt][value=explain]').checked = true;
    row.remove();
  });
}
list.querySelectorAll('.custom').forEach(wire);
document.getElementById('add').addEventListener('click', function () {
  if (list.querySelectorAll('.custom').length >= ]] .. Presets.MAX_CUSTOM .. [[) return;
  var box = document.createElement('div');
  box.innerHTML = tpl.innerHTML.replace(/_N"/g, '_' + next + '"').replace(/"N"/g, '"' + next + '"').replace(/row:N/g, 'row:' + next);
  var row = box.firstChild; list.appendChild(row); wire(row); next++;
  row.querySelector('input[type=text]').focus();
});
})();</script>]]

function Setup.formPage(config, code, err)
    local provider = config:provider()
    if provider ~= "openai" then provider = "claude" end
    local function seg(id)
        return string.format('<label><input type="radio" name="provider" value="%s"%s><span>%s</span></label>',
            id, id == provider and " checked" or "", Providers.LABELS[id])
    end
    return shell("Lexi setup", table.concat({
        '<p class="lead">Choose the AI that explains and translates words on your Kindle.</p>', message(err),
        '<form method="post" action="/save">',
        string.format('<input type="hidden" name="c" value="%s">', esc(code)),
        '<section class="card"><h2>AI provider</h2><div class="seg">', seg("claude"), seg("openai"), "</div></section>",
        providerCard(config, "claude", provider == "claude"),
        providerCard(config, "openai", provider == "openai"),
        '<section class="card"><h2>Translations</h2><label for="languages">Translate into</label>',
        string.format('<input id="languages" name="languages" type="text" autocomplete="off" value="%s">',
            esc(config:get("languages") or Prompt.DEFAULT_LANGUAGES)),
        '<p class="hint">Language codes, comma-separated, e.g. ru,en,es. The book\'s own language is skipped.</p></section>',
        promptCard(config),
        '<button type="submit">Save to Kindle</button></form>',
        PROMPT_SCRIPT,
        "<script>document.querySelectorAll('input[name=provider]').forEach(function (r) {",
        "r.addEventListener('change', function () { ['claude', 'openai'].forEach(function (id) {",
        "document.getElementById('card-' + id).hidden = id !== r.value; }); }); });</script>",
    }))
end

function Setup.donePage(summary)
    return shell("Lexi is ready", table.concat({
        '<section class="card done"><div class="tick">✓</div><h1>Saved to your Kindle</h1>',
        '<p class="lead">', esc(summary), "</p><p>You can close this page. Long-press any word and tap <b>Ask AI</b>.</p></section>",
    }))
end

--- The Prompt card's fields: rows cp_id_<n> / cp_name_<n> / cp_text_<n> (fully empty rows are
-- skipped) and the chosen prompt, a built-in id or "row:<n>".
-- @treturn table|nil custom prompts, string chosen id, string|nil error
function Setup.readPrompts(form)
    local rows = {}
    for k in pairs(form) do
        local n = k:match("^cp_name_(%d+)$")
        if n then table.insert(rows, tonumber(n)) end
    end
    table.sort(rows)
    local customs, by_row, taken = {}, {}, {}
    for _, n in ipairs(rows) do
        local name, text = trim(form["cp_name_" .. n]), trim(form["cp_text_" .. n])
        if name ~= "" or text ~= "" then
            local id = form["cp_id_" .. n]
            if not (id and id:match("^custom%d+$")) or taken[id] then id = nil end
            local valid, err = Presets.validate{ id = id, name = name ~= "" and name or ("Prompt " .. #customs + 1), template = text }
            if not valid then return nil, nil, err end
            if valid.id then taken[valid.id] = true end
            table.insert(customs, valid)
            by_row[n] = valid
        end
    end
    if #customs > Presets.MAX_CUSTOM then
        return nil, nil, string.format("Keep it to %d prompts of your own.", Presets.MAX_CUSTOM)
    end
    for _, p in ipairs(customs) do
        if not p.id then p.id = Presets.newId(customs) end
    end
    local chosen = form.prompt
    local row = tonumber(tostring(chosen):match("^row:(%d+)$"))
    if row then
        chosen = by_row[row] and by_row[row].id or Presets.DEFAULT
    elseif Presets.find(chosen).id ~= chosen then
        chosen = Presets.DEFAULT
    end
    return customs, chosen
end

--- Validates the submitted form, then writes it. @treturn string|nil summary, string|nil error
function Setup.apply(config, form)
    local provider = form.provider
    if provider ~= "claude" and provider ~= "openai" then return nil, "Pick Claude or OpenAI." end
    local changes = {}
    for _, id in ipairs(PROVIDERS) do
        local key = trim(form[id .. "_api_key"])
        if key ~= "" then
            -- Keys go into an HTTP header: letters, digits, "-", "_" and "." only.
            if not key:match("^[%w%-_%.]+$") or #key < 20 then
                return nil, Providers.LABELS[id] .. " API key doesn't look right. Copy it again, without spaces."
            end
            changes[id .. "_api_key"] = key
        end
        local model = trim(form[id .. "_model_custom"])
        if model == "" then model = trim(form[id .. "_model"]) end
        if model ~= "" then
            if not model:match("^[%w%._:/%-]+$") then return nil, "That model ID doesn't look right: " .. model end
            changes[id .. "_model"] = model
        end
        local effort = form[id .. "_effort"]
        for _, e in ipairs(Providers.EFFORTS) do
            if effort == e then changes[id .. "_effort"] = e end
        end
    end
    if not (changes[provider .. "_api_key"] or config:get(provider .. "_api_key")) then
        return nil, "Paste an API key for " .. Providers.LABELS[provider] .. "."
    end
    local workspace = form.claude_workspace_id and trim(form.claude_workspace_id)
    if workspace and workspace ~= "" and not workspace:match("^wrkspc_[%w]+$") then
        return nil, "A workspace ID looks like wrkspc_… (letters and digits)."
    end
    local customs, chosen
    if form.prompt then
        local err
        customs, chosen, err = Setup.readPrompts(form)
        if not customs then return nil, err end
    end
    for k, v in pairs(changes) do config:set(k, v) end
    if customs then
        config:setCustomPrompts(customs)
        config:set("prompt", chosen ~= Presets.DEFAULT and chosen or nil)
    end
    if workspace then config:set("claude_workspace_id", workspace) end
    if form.languages then
        local langs = Prompt.parseLangList(form.languages)
        config:set("languages", #langs > 0 and table.concat(langs, ",") or nil)
    end
    config:set("provider", provider)
    return Setup.summary(config)
end

local function splitPath(path)
    local p, q = tostring(path or "/"):match("^([^?]*)%??(.*)$")
    return p, Setup.parseForm(q)
end

--- Answers one request: { method, path, body, ip }. state: { code, bad = { [ip] = count } }.
-- A device that guesses wrong MAX_BAD_CODES times is shut out; the page keeps working for others.
-- @treturn number status, string body, string|nil outcome ("saved")
function Setup.handle(config, request, state)
    local path, query = splitPath(request.path)
    state.bad = state.bad or {}
    local ip = request.ip or "?"
    if (state.bad[ip] or 0) >= Setup.MAX_BAD_CODES then
        return 403, Setup.codePage("Too many wrong codes from this device. Start setup again on the Kindle.")
    end
    -- Only a code that was actually entered counts as a guess.
    local function check(code)
        if code == state.code then return true end
        if code and code ~= "" then state.bad[ip] = (state.bad[ip] or 0) + 1 end
        return false
    end
    local function wrongCode()
        return 403, Setup.codePage("That code doesn't match the one on your Kindle.")
    end
    if request.method == "GET" and path == "/" then
        if check(query.c) then return 200, Setup.formPage(config, state.code) end
        if query.c then return wrongCode() end
        return 200, Setup.codePage()
    elseif request.method == "POST" and path == "/save" then
        local form = Setup.parseForm(request.body)
        if not check(form.c) then return wrongCode() end
        local summary, err = Setup.apply(config, form)
        if not summary then return 400, Setup.formPage(config, state.code, err) end
        return 200, Setup.donePage(summary), "saved"
    end
    return 404, "Not found"
end

-- Server (LuaSocket) -----------------------------------------------------------------------------

local Server = {}
Server.__index = Server

local STATUS_TEXT = { [200] = "OK", [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found", [500] = "Server Error" }
local MAX_HEADERS = 16384 -- bytes
local MAX_REQUEST = 262144 -- bytes, headers and body together: room for ten long custom prompts
local MAX_CLIENTS = 8
local CLIENT_TIMEOUT_S = 10 -- a client must send its whole request within this

--- Parses what a client has sent so far.
-- @treturn table|false|nil the request { method, path, body }, false to drop the client, nil to wait
function Setup.parseRequest(buf)
    local head_end = buf:find("\r\n\r\n", 1, true)
    if not head_end then
        if #buf > MAX_HEADERS then return false end
        return nil
    end
    local head = buf:sub(1, head_end - 1)
    local method, path = head:match("^(%u+) (%S+) HTTP/%d%.%d")
    if not method then return false end
    local length = tonumber(head:lower():match("\r\ncontent%-length:%s*(%d+)") or "0")
    if not length or head_end + 3 + length > MAX_REQUEST then return false end
    local body = buf:sub(head_end + 4)
    if #body < length then return nil end
    return { method = method, path = path, body = body:sub(1, length) }
end

local SECURITY_HEADERS = table.concat({
    "Cache-Control: no-store",
    "Referrer-Policy: no-referrer",
    "X-Content-Type-Options: nosniff",
    "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'",
    "Connection: close",
}, "\r\n")

local function response(status, body)
    return table.concat({
        "HTTP/1.1 ", status, " ", STATUS_TEXT[status] or "Error", "\r\n",
        "Content-Type: text/html; charset=utf-8\r\n", SECURITY_HEADERS, "\r\n",
        "Content-Length: ", #body, "\r\n\r\n", body,
    })
end

--- Starts listening on all interfaces and opens the Kindle's Wi-Fi firewall for the port. Tries the
-- next ports when one is taken (say, by a setup started from the library that is still waiting).
-- opts: { config, port, code }. @treturn table|nil server, string|nil error
function Setup.start(opts)
    local socket = require("socket")
    local first = opts.port or Setup.PORT
    local server, port, err
    for candidate = first, first + 9 do
        server, err = socket.bind("*", candidate)
        if server then
            port = candidate
            break
        end
    end
    if not server then return nil, err end
    server:settimeout(0)
    -- Close-on-exec: a child started later (say, a long-running lipc-wait-event) must not inherit
    -- the listening socket and keep the port taken after we stop.
    pcall(function()
        local ffi = require("ffi")
        pcall(ffi.cdef, "int fcntl(int fd, int cmd, ...);")
        local F_SETFD, FD_CLOEXEC = 2, 1
        ffi.C.fcntl(server:getfd(), F_SETFD, ffi.new("int", FD_CLOEXEC))
    end)
    local rule = string.format("INPUT -i wlan0 -p tcp --dport %d -j ACCEPT", port)
    os.execute("iptables -D " .. rule .. " 2>/dev/null; iptables -I " .. rule .. " 2>/dev/null")
    return setmetatable({
        socket = socket, server = server, port = port, config = opts.config,
        state = { code = opts.code or Setup.newCode(), bad = {} },
        deadline = socket.gettime() + Setup.TIMEOUT_S,
        clients = {},
    }, Server)
end

function Server:url(ip)
    return string.format("http://%s:%d/?c=%s", ip, self.port, self.state.code)
end

--- Serves what has arrived, waiting up to `wait` seconds for activity. Never blocks on a client:
-- requests are buffered across calls, and slow or oversized ones are dropped, so a device on the
-- network can't stall KOReader's UI (which calls this from a timer).
-- @treturn string|nil "saved" or "expired"
function Server:poll(wait)
    local now = self.socket.gettime()
    if now >= self.deadline then return "expired" end
    if wait and wait > 0 then
        local watch = { self.server }
        for _, c in ipairs(self.clients) do table.insert(watch, c.sock) end
        self.socket.select(watch, nil, wait)
        now = self.socket.gettime()
    end
    while #self.clients < MAX_CLIENTS do
        local sock = self.server:accept()
        if not sock then break end
        sock:settimeout(0)
        table.insert(self.clients, { sock = sock, buf = "", ip = (sock:getpeername()), until_time = now + CLIENT_TIMEOUT_S })
    end
    local outcome
    for i = #self.clients, 1, -1 do
        local c = self.clients[i]
        local data, err, partial = c.sock:receive(4096)
        local chunk = data or partial
        if chunk and chunk ~= "" then c.buf = c.buf .. chunk end
        local request = Setup.parseRequest(c.buf)
        local done = request == false or err == "closed" or now > c.until_time
        if request then
            request.ip = c.ip
            local ok, status, body, result = pcall(Setup.handle, self.config, request, self.state)
            if not ok then status, body, result = 500, "Something went wrong. Try again.", nil end
            c.sock:settimeout(0.5)
            c.sock:send(response(status, body))
            outcome = outcome or result
            done = true
        end
        if done then
            c.sock:close()
            table.remove(self.clients, i)
        end
    end
    return outcome
end

function Server:stop()
    if not self.server then return end
    for _, c in ipairs(self.clients) do c.sock:close() end
    self.clients = {}
    self.server:close()
    self.server = nil
    os.execute(string.format("iptables -D INPUT -i wlan0 -p tcp --dport %d -j ACCEPT 2>/dev/null", self.port))
end

return Setup
