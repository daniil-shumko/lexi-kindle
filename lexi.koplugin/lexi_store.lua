--[[--
Saved words, kept on the Kindle until they are synced to the personal backend.

Backed by any LuaSettings-like object (readSetting / saveSetting / flush), so it can be tested
without KOReader. Each word: { id, word, prev, next, title, authors, lang, answer, provider,
model, preset (the prompt preset id), source ("koreader" or "kindle": the reader it was saved in),
created_at (unix seconds), synced (bool) }.

@module lexi_store
--]]

local Store = {}
Store.__index = Store

function Store.new(settings)
    return setmetatable({ settings = settings }, Store)
end

function Store:all()
    return self.settings:readSetting("words") or {}
end

function Store:save(words)
    self.settings:saveSetting("words", words)
    self.settings:flush()
end

--- Appends a word and returns it with its id. Saving the same word twice is allowed (new context).
function Store:add(entry)
    local words = self:all()
    entry.created_at = entry.created_at or os.time()
    entry.id = entry.id or string.format("%d-%04x", entry.created_at, math.random(0, 0xffff))
    entry.synced = false
    table.insert(words, entry)
    self:save(words)
    return entry
end

function Store:pending()
    local out = {}
    for _, w in ipairs(self:all()) do
        if not w.synced then table.insert(out, w) end
    end
    return out
end

--- Marks the given ids as synced; returns how many were found.
function Store:markSynced(ids)
    local wanted = {}
    for _, id in ipairs(ids or {}) do wanted[id] = true end
    local words, count = self:all(), 0
    for _, w in ipairs(words) do
        if wanted[w.id] and not w.synced then
            w.synced = true
            count = count + 1
        end
    end
    if count > 0 then self:save(words) end
    return count
end

return Store
