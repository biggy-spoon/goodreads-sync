-- Small persistence wrapper around a single LuaSettings file: the Goodreads
-- session cookie, the signed-in user's numeric id, and a per-book table
-- (keyed by the document's path) with the Goodreads edition id, title,
-- author and the shelf/percent we last pushed there.

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local GRUtil = require("gr_util")

local GRSettings = {}
local store

local function open()
    if not store then
        store = LuaSettings:open(DataStorage:getSettingsDir() .. "/goodreads_sync.lua")
    end
    return store
end

function GRSettings:getCookie()
    return open():readSetting("cookie") or ""
end

function GRSettings:setCookie(cookie)
    open():saveSetting("cookie", cookie or ""):flush()
end

function GRSettings:hasCookie()
    return self:getCookie() ~= ""
end

function GRSettings:getUserId()
    return open():readSetting("user_id")
end

function GRSettings:setUserId(id)
    open():saveSetting("user_id", id):flush()
end

function GRSettings:getBooks()
    return open():readSetting("books") or {}
end

-- Returns the stored link for `path`, or nil.
function GRSettings:getBook(path)
    local books = self:getBooks()
    return books[path]
end

-- Merges `fields` into the stored link for `path` (creating it if needed).
function GRSettings:setBook(path, fields)
    local s = open()
    local books = s:readSetting("books") or {}
    local entry = GRUtil.mergeFields(books[path], fields)
    books[path] = entry
    s:saveSetting("books", books):flush()
    return entry
end

function GRSettings:forgetBook(path)
    local s = open()
    local books = s:readSetting("books") or {}
    books[path] = nil
    s:saveSetting("books", books):flush()
end

return GRSettings
