-- Goodreads sync: shelves the open book as Currently reading, pushes
-- progress as you read, and shelves it as Read (with a star rating) when
-- you finish. See gr_api.lua for the endpoints and gr_settings.lua for
-- where the cookie and per-book links are kept.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local GRSettings = require("gr_settings")
local GRApi = require("gr_api")
local GRCookieReceiver = require("gr_cookie_receiver")

local PUSH_EVERY_N_PAGES = 10 -- how often a page turn may trigger a progress push

local GoodreadsSync = WidgetContainer:extend{
    name = "goodreadssync",
    is_doc_only = false,
}

local function api()
    GRApi.settings = GRSettings
    return GRApi
end

local function notify(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

-- --------------------------------------------------------------- sign-in

function GoodreadsSync:signIn()
    local dialog
    dialog = InputDialog:new{
        title = _("Sign in to Goodreads"),
        description = _("On a computer, sign in to goodreads.com, open the page's developer tools, "
            .. "and copy the value of the Cookie request header from any request to goodreads.com. "
            .. "Paste it below."),
        input = GRSettings:getCookie(),
        input_type = "string",
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
                    local cookie = GRApi.cleanCookie(dialog:getInputText())
                    GRSettings:setCookie(cookie)
                    api():resetCsrfToken()
                    UIManager:close(dialog)
                    notify(cookie == "" and _("Signed out of Goodreads.") or _("Goodreads cookie saved."))
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GoodreadsSync:signOut()
    GRSettings:setCookie("")
    api():resetCsrfToken()
    notify(_("Signed out of Goodreads."))
end

-- Listens on the local network for the companion browser extension
-- (browser-extension/ in this project) to send the cookie, instead of
-- typing it in on an e-ink keyboard.
function GoodreadsSync:receiveFromBrowser()
    GRCookieReceiver.open(function(cookie)
        GRSettings:setCookie(GRApi.cleanCookie(cookie))
        api():resetCsrfToken()
    end)
end

-- ------------------------------------------------------------- book link

-- Finds (or asks the user to pick) the Goodreads book for the currently
-- open document, and remembers the choice. `callback(link, path)` may run
-- much later (after a search, or after the reader picks from a list), by
-- which point the book may have been closed - so `path` is the one
-- resolved here at the start, not something to re-read from
-- self.ui.document inside callback (it may be nil by then).
function GoodreadsSync:ensureLinked(callback)
    local doc = self.ui and self.ui.document
    if not doc then return end
    local path = doc.file
    local link = GRSettings:getBook(path)
    if link and link.book_id then return callback(link, path) end

    local props = self.ui.doc_props or {}
    local title = props.title or ""
    local author = props.authors
    if type(author) == "table" then author = author[1] end
    author = type(author) == "string" and (author:match("^[^\n]+") or author) or ""
    local query = (title .. " " .. author):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return end

    NetworkMgr:runWhenOnline(function()
        local results = api():search(query)
        if not results or #results == 0 then
            notify(_("Could not find this book on Goodreads."))
            return
        end
        if #results == 1 then
            local saved = GRSettings:setBook(path, {
                book_id = results[1].book_id, title = results[1].title, authors = results[1].authors,
            })
            return callback(saved, path)
        end
        self:chooseBook(path, results, callback)
    end)
end

function GoodreadsSync:chooseBook(path, results, callback)
    local buttons = {}
    for i = 1, math.min(#results, 8) do
        local r = results[i]
        buttons[#buttons + 1] = {{
            text = r.title .. (r.authors ~= "" and (" — " .. r.authors) or ""),
            callback = function()
                UIManager:close(self._choose_dialog)
                local saved = GRSettings:setBook(path, { book_id = r.book_id, title = r.title, authors = r.authors })
                callback(saved, path)
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(self._choose_dialog) end,
    }}
    self._choose_dialog = ButtonDialog:new{
        title = _("Which book is this on Goodreads?"),
        buttons = buttons,
    }
    UIManager:show(self._choose_dialog)
end

-- ----------------------------------------------------------------- sync

-- Shelves `link` as Currently reading, unless our best-effort check finds
-- it already on some other exclusive shelf on the site, in which case the
-- reader is asked before anything is touched.
function GoodreadsSync:pushCurrentlyReading()
    if not GRSettings:hasCookie() then return end
    self:ensureLinked(function(link, path)
        if link.shelf == "currently-reading" or link.shelf == "read" then return end
        NetworkMgr:runWhenOnline(function()
            local remote_shelf = api():currentShelf(link.book_id)
            if remote_shelf and remote_shelf ~= "to-read" and remote_shelf ~= "currently-reading" then
                return self:askTakeOver(path, link, remote_shelf)
            end
            if api():addToShelf(link.book_id, "currently-reading") then
                GRSettings:setBook(path, { shelf = "currently-reading" })
                logger.info("Goodreads sync: shelved as Currently reading:", link.title)
            end
        end)
    end)
end

-- Asked once per book per KOReader run: Goodreads already has it as
-- `remote_shelf` (e.g. "read" from a previous time through it, or a shelf
-- of the reader's own). Moving it to Currently reading is the reader's
-- call, not something this plugin does on a guess.
function GoodreadsSync:askTakeOver(path, link, remote_shelf)
    if self._asked_take_over and self._asked_take_over[path] then return end
    self._asked_take_over = self._asked_take_over or {}
    self._asked_take_over[path] = true
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Goodreads already has \"%1\" on another shelf (%2), so its progress will not be sent.\n\nMove it to Currently reading anyway?"),
            link.title, remote_shelf),
        ok_text = _("Currently reading"),
        cancel_text = _("Leave it"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function()
                if api():addToShelf(link.book_id, "currently-reading") then
                    GRSettings:setBook(path, { shelf = "currently-reading" })
                end
            end)
        end,
    })
end

function GoodreadsSync:pushProgress(percent)
    if not GRSettings:hasCookie() then return end
    local path = self.ui and self.ui.document and self.ui.document.file
    if not path then return end
    local link = GRSettings:getBook(path)
    if not (link and link.book_id) then return end
    local whole = math.floor(percent + 0.5)
    if link.last_percent == whole then return end
    NetworkMgr:runWhenOnline(function()
        if api():setProgress(link.book_id, whole) then
            GRSettings:setBook(path, { last_percent = whole })
        end
    end)
end

function GoodreadsSync:pushFinished()
    if not GRSettings:hasCookie() then return end
    self:ensureLinked(function(link, path)
        if link.shelf == "read" then return end
        NetworkMgr:runWhenOnline(function()
            if not api():addToShelf(link.book_id, "read") then return end
            GRSettings:setBook(path, { shelf = "read" })
            notify(T(_("Shelved as Read on Goodreads: %1"), link.title))
            self:askFinishedDate(link)
            self:askForRating(link)
        end)
    end)
end

-- Goodreads defaults a freshly-shelved Read book to today. Offers to
-- back-date it instead, for a book actually finished earlier (e.g. one
-- imported with reading history already behind it).
function GoodreadsSync:askFinishedDate(link)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("\"%1\" was shelved as Read with today's date. Was it actually finished on a different day?"), link.title),
        ok_text = _("Pick a date…"),
        cancel_text = _("Today is fine"),
        ok_callback = function() self:pickFinishedDate(link) end,
    })
end

function GoodreadsSync:pickFinishedDate(link)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local today = os.date("*t")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Date finished"),
        fields = {
            { description = _("Year"), input_type = "number", text = tostring(today.year) },
            { description = _("Month"), input_type = "number", text = tostring(today.month) },
            { description = _("Day"), input_type = "number", text = tostring(today.day) },
        },
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local when = {
                        year = tonumber(fields[1]), month = tonumber(fields[2]), day = tonumber(fields[3]),
                    }
                    UIManager:close(dialog)
                    if not (when.year and when.month and when.day) then return end
                    NetworkMgr:runWhenOnline(function()
                        if api():setDateFinished(link.book_id, when) then
                            notify(_("Finished date updated on Goodreads."))
                        else
                            notify(_("Could not set a custom finished date (Goodreads' page may have changed); it stays as today."))
                        end
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GoodreadsSync:askForRating(link)
    local buttons = {}
    for stars = 5, 1, -1 do
        buttons[#buttons + 1] = {{
            text = string.rep("★", stars) .. string.rep("☆", 5 - stars),
            callback = function()
                UIManager:close(self._rate_dialog)
                NetworkMgr:runWhenOnline(function()
                    if api():setRating(link.book_id, stars) then
                        notify(T(_("Rated %1 stars on Goodreads."), stars))
                    end
                end)
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Skip"), callback = function() UIManager:close(self._rate_dialog) end }}
    self._rate_dialog = ButtonDialog:new{ title = _("Rate this book on Goodreads?"), buttons = buttons }
    UIManager:show(self._rate_dialog)
end

-- -------------------------------------------------------------- hooks

function GoodreadsSync:init()
    self.ui.menu:registerToMainMenu(self)
    self._pages_since_push = 0
end

function GoodreadsSync:onReaderReady()
    if GRSettings:hasCookie() then self:pushCurrentlyReading() end
end

function GoodreadsSync:onPageUpdate(pageno)
    if not GRSettings:hasCookie() then return end
    self._pages_since_push = (self._pages_since_push or 0) + 1
    if self._pages_since_push < PUSH_EVERY_N_PAGES then return end
    self._pages_since_push = 0
    local doc = self.ui and self.ui.document
    if not (doc and pageno) then return end
    -- Signing in can happen after onReaderReady already ran (e.g. mid-session
    -- via the browser extension), which is the only other place a book gets
    -- linked and shelved; retry that here too so a late sign-in isn't stuck
    -- until the book is closed and reopened.
    local path = doc.file
    local link = GRSettings:getBook(path)
    if not (link and link.book_id) then self:pushCurrentlyReading() end
    local ok, page_count = pcall(function() return doc:getPageCount() end)
    if not (ok and page_count and page_count > 0) then return end
    local percent = pageno / page_count * 100
    self:pushProgress(percent)
    if percent >= 99.5 then self:pushFinished() end
end

function GoodreadsSync:onCloseDocument()
    self._pages_since_push = 0
end

function GoodreadsSync:addToMainMenu(menu_items)
    menu_items.goodreads_sync = {
        text = _("Goodreads sync"),
        sub_item_table = {
            {
                text_func = function() return GRSettings:hasCookie() and _("Signed in (paste cookie again)") or _("Sign in by pasting a cookie…") end,
                callback = function() self:signIn() end,
            },
            {
                text = _("Sign in from browser extension…"),
                callback = function() self:receiveFromBrowser() end,
            },
            {
                text = _("Sign out"),
                enabled_func = function() return GRSettings:hasCookie() end,
                callback = function() self:signOut() end,
            },
            {
                text = _("Shelve as Currently reading now"),
                enabled_func = function() return GRSettings:hasCookie() and self.ui.document ~= nil end,
                callback = function() self:pushCurrentlyReading() end,
            },
            {
                text = _("Shelve as Read now"),
                enabled_func = function() return GRSettings:hasCookie() and self.ui.document ~= nil end,
                callback = function() self:pushFinished() end,
            },
        },
    }
end

return GoodreadsSync
