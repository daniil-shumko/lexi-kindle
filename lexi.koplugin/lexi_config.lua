--[[--
Settings lookup shared by the KOReader plugin and the native-reader bridge (native/lexid.lua).

A value set from the menu (settings/lexi.lua) wins over config.lua next to main.lua, and ""
counts as unset. Works with any LuaSettings-like object, so it can be tested without KOReader.

@module lexi_config
--]]

local Presets = require("lexi_presets")
local Prompt = require("lexi_prompt")
local Providers = require("lexi_providers")

local Config = {}
Config.__index = Config

--- settings: LuaSettings-like (readSetting / saveSetting / delSetting / flush); defaults: table.
function Config.new(settings, defaults)
    return setmetatable({ settings = settings, defaults = defaults or {} }, Config)
end

--- Loads an optional config.lua. Returns the table, or {} plus the error when it is broken.
function Config.loadFile(path)
    local f = io.open(path, "r")
    if not f then return {} end
    f:close()
    local ok, cfg = pcall(dofile, path)
    if ok and type(cfg) == "table" then return cfg end
    return {}, cfg
end

function Config:get(key)
    local value = self.settings:readSetting(key)
    if value == nil or value == "" then value = self.defaults[key] end
    if value == "" then return nil end
    return value
end

function Config:set(key, value)
    if value == nil or value == "" then
        self.settings:delSetting(key)
    else
        self.settings:saveSetting(key, value)
    end
    self.settings:flush()
end

function Config:provider()
    local id = self:get("provider")
    return Providers.LABELS[id] and id or "claude"
end

function Config:providerConfig(id)
    if id == "backend" then
        return { base_url = self:get("backend_url"), token = self:get("backend_token") }
    end
    local defaults = Providers.DEFAULTS[id] or {}
    return {
        api_key = self:get(id .. "_api_key"),
        model = self:get(id .. "_model") or defaults.model,
        effort = self:get(id .. "_effort") or defaults.effort,
        base_url = self:get(id .. "_base_url") or defaults.base_url,
        workspace_id = self:get(id .. "_workspace_id"),
    }
end

function Config:backendConfigured()
    return self:get("backend_url") ~= nil and self:get("backend_token") ~= nil
end

--- Languages to translate into, e.g. { "ru", "en", "es" }.
function Config:languages()
    return Prompt.parseLangList(self:get("languages") or Prompt.DEFAULT_LANGUAGES)
end

--- The reader's custom prompts, { { id, name, template }, … }; invalid entries are dropped.
function Config:customPrompts()
    return Presets.sanitize(self:get("custom_prompts"))
end

function Config:setCustomPrompts(list)
    self:set("custom_prompts", list and #list > 0 and list or nil)
end

--- The prompt preset to ask with: the chosen one, or the default if it no longer exists.
function Config:activePreset()
    return Presets.find(self:get("prompt"), self:customPrompts())
end

return Config
