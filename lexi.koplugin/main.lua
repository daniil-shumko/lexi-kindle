--[[--
Lexi: long-press a word → "Ask AI" → its meaning in this context plus translations,
from Claude or OpenAI. Saved words wait on the Kindle and sync to a personal backend.

@module koplugin.lexi
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

-- Plugin modules must be required here: KOReader only puts the plugin folder on
-- package.path while this file is being loaded.
local AnswerViewer = require("lexi_viewer")
local Cache = require("lexi_cache")
local Client = require("lexi_client")
local Config = require("lexi_config")
local Format = require("lexi_format")
local Presets = require("lexi_presets")
local Prompt = require("lexi_prompt")
local Providers = require("lexi_providers")
local Setup = require("lexi_setup")
local SetupView = require("lexi_setupview")
local Store = require("lexi_store")

-- Words of context taken on each side of the selection.
local CONTEXT_WORDS = 40

-- Where a new custom prompt starts: shows the placeholders at work.
local CUSTOM_PROMPT_EXAMPLE = "Explain “{word}” as it is used in this passage, in two short sentences in "
    .. "{explain_language}:\n{context}\n\nThen translate it into {translate_to}."

local Lexi = WidgetContainer:extend{
    name = "lexi",
    is_doc_only = true,
}

function Lexi:init()
    -- Optional config.lua next to main.lua presets values (handy for long API keys);
    -- anything set from the menu overrides it.
    local defaults, err = Config.loadFile(self.path .. "/config.lua")
    if err then logger.warn("lexi: cannot load config.lua:", err) end
    self.config = Config.new(LuaSettings:open(DataStorage:getSettingsDir() .. "/lexi.lua"), defaults)
    self.store = Store.new(LuaSettings:open(DataStorage:getSettingsDir() .. "/lexi_words.lua"))
    self.ui.menu:registerToMainMenu(self)
    self:registerHighlightButton()
    self:registerDictButton()
end

function Lexi:get(key) return self.config:get(key) end
function Lexi:set(key, value) self.config:set(key, value) end
function Lexi:provider() return self.config:provider() end
function Lexi:providerConfig(id) return self.config:providerConfig(id) end
function Lexi:backendConfigured() return self.config:backendConfigured() end

-- Earlier answers (lexi_cache), read on the first Ask AI rather than with every book: the file
-- holds up to 500 answers.
function Lexi:answers()
    if not self.cache then
        self.cache = Cache.new(LuaSettings:open(DataStorage:getSettingsDir() .. "/lexi_answers.lua"))
    end
    return self.cache
end

-- Entry points ----------------------------------------------------------------------------------

-- Shown after selecting text (long-press and drag).
function Lexi:registerHighlightButton()
    local highlight = self.ui.highlight
    if not (highlight and highlight.addToHighlightDialog) then return end
    highlight:addToHighlightDialog("08_lexi_ask", function(reader_highlight)
        return {
            text = _("Ask AI"),
            callback = function()
                -- Read the selection before onClose(), which clears it.
                local query = self:collectQuery(reader_highlight)
                reader_highlight:onClose()
                self:ask(query)
            end,
        }
    end)
end

-- Shown in the dictionary popup (long-press on a single word). KOReader v2026.07+ API.
function Lexi:registerDictButton()
    local dictionary = self.ui.dictionary
    if not (dictionary and type(dictionary.addToDictButtons) == "function") then return end
    dictionary:addToDictButtons{
        id = "lexi_ask",
        text = _("Ask AI"),
        menu_text = _("Ask AI (Lexi)"),
        insert_first = true,
        callback = function(dict_popup) self:askFromDictPopup(dict_popup) end,
    }
end

-- Older KOReader versions build the dictionary popup buttons through this event instead.
function Lexi:onDictButtonsReady(dict_popup, buttons)
    local dictionary = self.ui.dictionary
    if dictionary and type(dictionary.addToDictButtons) == "function" then return end
    table.insert(buttons, 1, {{
        id = "lexi_ask",
        text = _("Ask AI"),
        callback = function() self:askFromDictPopup(dict_popup) end,
    }})
end

function Lexi:askFromDictPopup(dict_popup)
    local word = dict_popup.word or dict_popup.lookupword
    self:ask(self:collectQuery(self.ui.highlight, word))
end

function Lexi:collectQuery(highlight, word)
    local selected = highlight and highlight.selected_text
    local query = {
        word = util.cleanupSelectedText(word or (selected and selected.text) or ""),
        prev = "",
        next = "",
    }
    -- After a nested lookup (a word tapped inside the dictionary popup) the selection belongs to
    -- another word: send no context rather than the wrong passage.
    if selected and selected.text and highlight.getSelectedWordContext
            and util.cleanupSelectedText(selected.text) == query.word then
        local prev, following = highlight:getSelectedWordContext(CONTEXT_WORDS)
        query.prev, query.next = prev or "", following or ""
    end
    local props = self.ui.doc_props
    if not props and self.ui.document and self.ui.document.getProps then
        props = self.ui.document:getProps()
    end
    props = props or {}
    query.title = props.display_title or props.title
    query.authors = props.authors
    query.lang = props.language
    return query
end

-- Asking -----------------------------------------------------------------------------------------

-- preset: the prompt preset to ask with (default: the one chosen in the menu). A word asked about
-- before shows its earlier answer, with no request, unless fresh is set ("Ask AI again").
function Lexi:ask(query, preset, fresh)
    if not query.word or query.word == "" then return end
    preset = preset or self.config:activePreset()
    local prompt = Prompt.build(query, { targets = self.config:languages(), preset = preset })
    local key = Cache.key(query.word, preset, prompt)
    local earlier = not fresh and self:answers():get(key)
    if earlier then
        self:showAnswer(query, earlier.text, earlier.provider, earlier.model, preset, earlier)
        return
    end
    local provider = self:provider()
    local cfg = self:providerConfig(provider)
    local request, err = Providers.build(provider, cfg, query, prompt)
    if not request then
        UIManager:show(InfoMessage:new{
            text = err .. "\n\n" .. _("Set it up in the reader menu → Lexi."),
        })
        return
    end

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            -- Runs in a forked subprocess: Client returns only plain values.
            local asking = preset.id == Presets.DEFAULT
                and T(_("Asking %1 about “%2”…"), Providers.LABELS[provider], query.word)
                or T(_("Asking %1 about “%2” (%3)…"), Providers.LABELS[provider], query.word, preset.name)
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                return Client.ask(provider, request)
            end, asking)
            if not completed then return end -- dismissed with a tap
            if type(result) ~= "table" or not result.text then
                UIManager:show(InfoMessage:new{
                    text = T(_("AI request failed:\n%1"), type(result) == "table" and result.err or _("no response")),
                })
                return
            end
            self:answers():put(key, {
                word = query.word, preset = preset.id, text = result.text, provider = provider, model = cfg.model,
            })
            self:showAnswer(query, result.text, provider, cfg.model, preset)
        end)
    end)
end

-- earlier: the stored answer (lexi_cache) when this one was reused rather than asked for.
function Lexi:showAnswer(query, answer, provider, model, preset, earlier)
    local html = Format.answerHtml(answer, { plain = Presets.isCustom(preset) })
    local viewer
    local buttons = {{
        {
            text = _("Save word"),
            callback = function()
                UIManager:close(viewer)
                self:saveWord(query, answer, provider, model, preset.id)
            end,
        },
        {
            text = _("Ask again as…"),
            callback = function()
                self:chooseOtherPrompt(preset, function(other)
                    UIManager:close(viewer)
                    self:ask(query, other)
                end)
            end,
        },
        {
            text = _("Close"),
            callback = function() UIManager:close(viewer) end,
        },
    }}
    if earlier then
        html = Format.earlierNote(earlier.created_at) .. "\n" .. html
        table.insert(buttons, 1, {{
            text = _("Ask AI again"),
            callback = function()
                UIManager:close(viewer)
                self:ask(query, preset, true)
            end,
        }})
    end
    viewer = AnswerViewer:new{
        title = preset.id == Presets.DEFAULT and query.word or T("%1 · %2", query.word, preset.name),
        html = html,
        css = Format.CSS,
        -- Same text size as the dictionary popup the user already tuned.
        font_size = G_reader_settings:readSetting("dict_font_size") or 20,
        buttons_table = buttons,
    }
    UIManager:show(viewer)
end

-- Lists every prompt but the current one; on_choose(preset) asks again with it.
function Lexi:chooseOtherPrompt(current, on_choose)
    local dialog
    local buttons = {}
    for _, p in ipairs(Presets.list(self.config:customPrompts())) do
        if p.id ~= current.id then
            table.insert(buttons, {{
                text = p.name,
                callback = function()
                    UIManager:close(dialog)
                    on_choose(p)
                end,
            }})
        end
    end
    dialog = ButtonDialog:new{ title = _("Ask again as…"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

-- Saving and syncing -----------------------------------------------------------------------------

function Lexi:saveWord(query, answer, provider, model, preset_id)
    local entry = self.store:add{
        word = query.word,
        prev = query.prev,
        next = query.next,
        title = query.title,
        authors = query.authors,
        lang = Prompt.normalizeLang(query.lang),
        answer = answer,
        provider = provider,
        model = model,
        preset = preset_id,
        source = "koreader",
    }
    if self:backendConfigured() then
        self:syncWords()
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Saved “%1” on this Kindle."), entry.word),
            timeout = 2,
        })
    end
end

function Lexi:syncWords()
    if not self:backendConfigured() then
        UIManager:show(InfoMessage:new{ text = _("Set the backend URL and device token first.") })
        return
    end
    local pending = self.store:pending()
    if #pending == 0 then
        UIManager:show(InfoMessage:new{ text = _("All saved words are synced."), timeout = 2 })
        return
    end
    local base_url, token = self:get("backend_url"), self:get("backend_token")
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                return Client.pushWords(base_url, token, pending)
            end, T(_("Syncing %1 saved word(s)…"), #pending))
            if not completed or type(result) ~= "table" then return end
            local count = self.store:markSynced(result.synced)
            local text = T(_("Synced %1 of %2 word(s)."), count, #pending)
            if result.err then text = text .. "\n" .. result.err end
            UIManager:show(InfoMessage:new{ text = text, timeout = not result.err and 3 or nil })
        end)
    end)
end

function Lexi:showSavedWords()
    local words = self.store:all()
    local lines = {}
    for i = #words, 1, -1 do
        local w = words[i]
        table.insert(lines, T("%1 %2 — %3", w.synced and "✓" or "•", w.word, w.title or "?"))
    end
    local viewer
    viewer = TextViewer:new{
        title = T(_("Saved words (%1)"), #words),
        text = #lines > 0 and table.concat(lines, "\n") or _("No saved words yet."),
        buttons_table = {{
            {
                text = _("Sync now"),
                callback = function()
                    UIManager:close(viewer)
                    self:syncWords()
                end,
            },
            {
                text = _("Close"),
                callback = function() UIManager:close(viewer) end,
            },
        }},
    }
    UIManager:show(viewer)
end

-- Menu -------------------------------------------------------------------------------------------

function Lexi:addToMainMenu(menu_items)
    menu_items.lexi = {
        text = _("Lexi"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:getMenuItems() end,
    }
end

function Lexi:editSetting(key, title, opts, on_done)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self:get(key) or "",
        input_hint = opts.hint or opts.default,
        description = opts.description,
        text_type = opts.password and "password" or nil,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    self:set(key, util.trim(dialog:getInputText()))
                    UIManager:close(dialog)
                    if on_done then on_done() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Lexi:settingItem(key, title, opts)
    opts = opts or {}
    return {
        text_func = function()
            local value = self:get(key)
            local shown
            if not value then
                shown = opts.default and T(_("%1 (default)"), opts.default) or _("not set")
            elseif opts.password then
                shown = "…" .. value:sub(-4)
            else
                shown = value
            end
            return T("%1: %2", title, shown)
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:editSetting(key, title, opts, function()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end)
        end,
    }
end

function Lexi:effortItem(id)
    local notes = { low = _("fastest, recommended"), high = _("slower, more thorough") }
    local function choice(level)
        return {
            text = notes[level] and T("%1 (%2)", level, notes[level]) or level,
            radio = true,
            checked_func = function() return self:providerConfig(id).effort == level end,
            callback = function() self:set(id .. "_effort", level) end,
        }
    end
    local choices = {}
    for _, level in ipairs(Providers.EFFORTS) do table.insert(choices, choice(level)) end
    return {
        text_func = function() return T(_("Reasoning effort: %1"), self:providerConfig(id).effort) end,
        sub_item_table = choices,
    }
end

function Lexi:modelItem(id)
    local items = {}
    for _, m in ipairs(Providers.MODELS[id]) do
        table.insert(items, {
            text = T("%1 (%2)", m.label, m.note),
            radio = true,
            checked_func = function() return self:providerConfig(id).model == m.id end,
            callback = function() self:set(id .. "_model", m.id) end,
        })
    end
    items[#items].separator = true
    table.insert(items, self:settingItem(id .. "_model", _("Other model ID"), { default = Providers.DEFAULTS[id].model }))
    return {
        text_func = function()
            return T(_("Model: %1"), Providers.modelLabel(id, self:providerConfig(id).model))
        end,
        sub_item_table = items,
    }
end

-- Serves lexi_setup.lua's page while the QR screen is open; polling keeps KOReader responsive.
function Lexi:setupFromPhone(touchmenu_instance)
    NetworkMgr:runWhenOnline(function()
        local ip = Setup.localAddress()
        if not ip then
            UIManager:show(InfoMessage:new{ text = _("Couldn't find this Kindle's Wi-Fi address.") })
            return
        end
        local server, err = Setup.start{ config = self.config }
        if not server then
            UIManager:show(InfoMessage:new{ text = T(_("Couldn't start phone setup:\n%1"), tostring(err)) })
            return
        end
        local view, poll
        local function stop()
            UIManager:unschedule(poll)
            server:stop()
        end
        poll = function()
            local ok, outcome = pcall(server.poll, server, 0)
            if ok and not outcome then
                UIManager:scheduleIn(0.5, poll)
                return
            end
            view.on_close = nil
            UIManager:close(view)
            stop()
            if not ok then
                logger.warn("lexi: phone setup failed:", outcome)
                UIManager:show(InfoMessage:new{ text = _("Phone setup stopped because of an error.") })
            elseif outcome == "saved" then
                UIManager:show(InfoMessage:new{ text = T(_("Saved: %1"), Setup.summary(self.config)), timeout = 5 })
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end
        end
        view = SetupView:new{ url = server:url(ip), code = server.state.code, on_close = stop }
        UIManager:show(view)
        UIManager:scheduleIn(0.5, poll)
    end)
end

-- Prompts --------------------------------------------------------------------------------------------

function Lexi:promptItems()
    local customs = self.config:customPrompts()
    local items = {}
    local function choice(p)
        return {
            text = p.name,
            help_text = p.description,
            radio = true,
            checked_func = function() return self.config:activePreset().id == p.id end,
            callback = function() self:set("prompt", p.id) end,
            hold_callback = Presets.isCustom(p) and function(touchmenu_instance)
                self:customPromptActions(p, touchmenu_instance)
            end or nil,
        }
    end
    for _, p in ipairs(Presets.builtins()) do table.insert(items, choice(p)) end
    items[#items].separator = true
    for _, p in ipairs(customs) do table.insert(items, choice(p)) end
    table.insert(items, {
        text = _("Add custom prompt…"),
        enabled_func = function() return #self.config:customPrompts() < Presets.MAX_CUSTOM end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:editCustomPrompt(nil, function() self:refreshPromptMenu(touchmenu_instance) end)
        end,
    })
    if #customs > 0 then
        table.insert(items, {
            text = _("Long-press a custom prompt to edit or delete it."),
            enabled_func = function() return false end,
        })
    end
    return items
end

-- The prompt list changed: redraw the open submenu with the new items.
function Lexi:refreshPromptMenu(touchmenu_instance)
    if not touchmenu_instance then return end
    touchmenu_instance.item_table = self:promptItems()
    touchmenu_instance:updateItems()
end

function Lexi:placeholderHelp()
    local lines = { _("Placeholders:") }
    for _, ph in ipairs(Presets.PLACEHOLDERS) do
        table.insert(lines, T("{%1}: %2", ph[1], ph[2]))
    end
    return table.concat(lines, "\n")
end

function Lexi:customPromptActions(preset, touchmenu_instance)
    local dialog
    dialog = ButtonDialog:new{
        title = preset.name,
        title_align = "center",
        buttons = {
            {{
                text = _("Edit"),
                callback = function()
                    UIManager:close(dialog)
                    self:editCustomPrompt(preset, function() self:refreshPromptMenu(touchmenu_instance) end)
                end,
            }},
            {{
                text = _("Delete"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete the prompt “%1”?"), preset.name),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            local kept = {}
                            for _, p in ipairs(self.config:customPrompts()) do
                                if p.id ~= preset.id then table.insert(kept, p) end
                            end
                            self.config:setCustomPrompts(kept)
                            if self:get("prompt") == preset.id then self:set("prompt", nil) end
                            self:refreshPromptMenu(touchmenu_instance)
                        end,
                    })
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- Name first, then the prompt text. existing: the custom prompt to edit, or nil for a new one.
function Lexi:editCustomPrompt(existing, on_done)
    local name_dialog
    name_dialog = InputDialog:new{
        title = existing and _("Prompt name") or _("New prompt: name"),
        input = existing and existing.name or "",
        input_hint = _("e.g. Simple explanation"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(name_dialog) end,
            },
            {
                text = _("Next"),
                is_enter_default = true,
                callback = function()
                    local name = util.trim(name_dialog:getInputText())
                    if name == "" then return end
                    UIManager:close(name_dialog)
                    self:editCustomPromptText(existing, name, on_done)
                end,
            },
        }},
    }
    UIManager:show(name_dialog)
    name_dialog:onShowKeyboard()
end

function Lexi:editCustomPromptText(existing, name, on_done)
    local dialog
    dialog = InputDialog:new{
        title = name,
        input = existing and existing.template or CUSTOM_PROMPT_EXAMPLE,
        description = self:placeholderHelp(),
        allow_newline = true,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                callback = function()
                    local list = self.config:customPrompts()
                    local valid, err = Presets.validate{
                        id = existing and existing.id or Presets.newId(list),
                        name = name,
                        template = dialog:getInputText(),
                    }
                    if not valid then
                        UIManager:show(InfoMessage:new{ text = err })
                        return
                    end
                    local replaced = false
                    for i, p in ipairs(list) do
                        if p.id == valid.id then
                            list[i] = valid
                            replaced = true
                        end
                    end
                    if not replaced then table.insert(list, valid) end
                    self.config:setCustomPrompts(list)
                    -- A new prompt is made to be used: choose it.
                    if not existing then self:set("prompt", valid.id) end
                    UIManager:close(dialog)
                    if on_done then on_done() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Lexi:getMenuItems()
    local function providerChoice(id)
        return {
            text = Providers.LABELS[id],
            radio = true,
            checked_func = function() return self:provider() == id end,
            callback = function() self:set("provider", id) end,
        }
    end
    return {
        {
            text = _("Set up from phone (QR code)"),
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:setupFromPhone(touchmenu_instance) end,
            separator = true,
        },
        {
            text_func = function() return T(_("AI provider: %1"), Providers.LABELS[self:provider()]) end,
            sub_item_table = { providerChoice("claude"), providerChoice("openai"), providerChoice("backend") },
        },
        {
            text = _("Claude settings"),
            sub_item_table = {
                self:settingItem("claude_api_key", _("API key"), { password = true, hint = "sk-ant-…" }),
                self:modelItem("claude"),
                self:effortItem("claude"),
                self:settingItem("claude_workspace_id", _("Workspace ID"), {
                    hint = "wrkspc_…",
                    description = _("Only needed when the API key works across several workspaces."),
                }),
            },
        },
        {
            text = _("OpenAI settings"),
            sub_item_table = {
                self:settingItem("openai_api_key", _("API key"), { password = true, hint = "sk-…" }),
                self:modelItem("openai"),
                self:effortItem("openai"),
            },
        },
        {
            text = _("My backend"),
            sub_item_table = {
                self:settingItem("backend_url", _("URL"), { hint = "https://…" }),
                self:settingItem("backend_token", _("Device token"), { password = true }),
            },
        },
        self:settingItem("languages", _("Translate into"), {
            default = Prompt.DEFAULT_LANGUAGES,
            description = _("Comma-separated language codes. The book's own language is skipped."),
        }),
        {
            text_func = function() return T(_("Prompt: %1"), self.config:activePreset().name) end,
            sub_item_table_func = function() return self:promptItems() end,
        },
        {
            text_func = function()
                return T(_("Saved words (%1 not synced)"), #self.store:pending())
            end,
            keep_menu_open = true,
            callback = function() self:showSavedWords() end,
            separator = true,
        },
    }
end

return Lexi
