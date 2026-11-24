-- A small client for the handful of goodreads.com endpoints this plugin
-- needs. Goodreads has no public API for any of this any more, so like
-- every other Goodreads-sync tool still around, it drives the same
-- endpoints the website's own pages use: a signed-in session cookie plus
-- a Rails CSRF token (fetched once from the front page and cached).
--
-- This talks to an external site we don't control: a layout change there
-- can break the scraping this module does (the CSRF token, and the
-- best-effort shelf/review-id lookups near the bottom). Everything else
-- is a plain form POST with a JSON or empty reply.
--
-- The pure parsing/formatting logic lives in gr_util.lua, where it can be
-- unit-tested without KOReader's or LuaSocket's runtime; this module is
-- just that logic wired up to real HTTP requests.

local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local logger = require("logger")

local GRUtil = require("gr_util")

local GRApi = {}
GRApi.settings = nil -- set by the caller before any request
GRApi.cleanCookie = GRUtil.cleanCookie

local BASE = "https://www.goodreads.com"
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

local function request(method, url, body, extra_headers)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then return nil end
    local cookie = GRUtil.cleanCookie(GRApi.settings and GRApi.settings:getCookie())
    if cookie == "" then return nil end

    local headers = {
        ["User-Agent"] = UA,
        ["Accept"] = "*/*",
        ["Cookie"] = cookie,
        ["Referer"] = BASE .. "/",
        ["Origin"] = BASE,
    }
    if extra_headers then for k, v in pairs(extra_headers) do headers[k] = v end end
    if method == "POST" then
        headers["Content-Type"] = headers["Content-Type"] or "application/x-www-form-urlencoded"
        headers["Content-Length"] = tostring(body and #body or 0)
    end

    local sink = {}
    socketutil:set_timeout(15, 30)
    local ok, code, resp_headers = http.request({
        url = url,
        method = method,
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(sink),
        redirect = false,
    })
    socketutil:reset_timeout()
    if not ok then
        logger.warn("Goodreads sync: request failed:", code)
        return nil
    end
    return tonumber(code), table.concat(sink), resp_headers
end

function GRApi:ensureCsrfToken(force)
    if self._csrf and not force then return self._csrf end
    local code, body = request("GET", BASE .. "/")
    if code ~= 200 then return nil end
    local token = GRUtil.scrapeCsrf(body)
    if token then self._csrf = token end
    return token
end

function GRApi:resetCsrfToken()
    self._csrf = nil
end

-- Looks a book up by free-text query (title, or "title author"). Returns a
-- list of { book_id, edition_id, title, authors, goodreads_url } or nil.
function GRApi:search(query)
    if not query or query == "" then return {} end
    local url = BASE .. "/book/auto_complete?format=json&q=" .. GRUtil.urlencode(query)
    local code, body = request("GET", url, nil, { Accept = "application/json" })
    if code ~= 200 or not body or body == "" then return nil end
    local ok, decoded = pcall(json.decode, body)
    if not ok then return nil end
    return GRUtil.parseSearchResults(decoded, BASE)
end

-- Adds/moves `book_id` to exclusive shelf `shelf` ("to-read",
-- "currently-reading" or "read"). Returns true/false.
function GRApi:addToShelf(book_id, shelf)
    local token = self:ensureCsrfToken()
    if not token then return false end
    local body = GRUtil.formEncode({ book_id = book_id, name = shelf, authenticity_token = token })
    local code = request("POST", BASE .. "/shelf/add_to_shelf", body, {
        ["X-Requested-With"] = "XMLHttpRequest",
    })
    if code == 404 then
        -- A stale cached token is the usual cause; one retry with a fresh one.
        self:resetCsrfToken()
        token = self:ensureCsrfToken(true)
        if not token then return false end
        body = GRUtil.formEncode({ book_id = book_id, name = shelf, authenticity_token = token })
        code = request("POST", BASE .. "/shelf/add_to_shelf", body, { ["X-Requested-With"] = "XMLHttpRequest" })
    end
    return code == 200 or code == 201 or code == 204
end

-- Sends a 1-100 reading percentage. The book must already be on an
-- exclusive shelf (Goodreads otherwise answers 404).
function GRApi:setProgress(book_id, percent)
    local pct = GRUtil.clampPercent(percent)
    local token = self:ensureCsrfToken()
    if not token then return false end
    local body = GRUtil.formEncode({
        authenticity_token = token,
        ["user_status[book_id]"] = book_id,
        ["user_status[percent]"] = tostring(pct),
    })
    local code = request("POST", BASE .. "/user_status.json", body, {
        ["X-Requested-With"] = "XMLHttpRequest",
        Accept = "application/json",
    })
    return code == 200 or code == 201 or code == 204
end

-- 1-5 stars. Goodreads only keeps a rating once the book is on the Read
-- shelf, so call this after addToShelf(id, "read").
function GRApi:setRating(book_id, rating)
    local stars = GRUtil.clampStars(rating)
    local token = self:ensureCsrfToken()
    if not token then return false end
    local url = BASE .. "/review/rate/" .. book_id .. "?rating=" .. stars
    local code = request("POST", url, "", { ["X-Requested-With"] = "XMLHttpRequest" })
    return code == 200 or code == 201 or code == 204
end

-- Best-effort read of which exclusive shelf the signed-in account already
-- has `book_id` on; see GRUtil.scrapeShelf for the caveats. Callers must
-- treat nil as "couldn't tell, proceed as usual", never as "no shelf".
function GRApi:currentShelf(book_id)
    local code, body = request("GET", BASE .. "/review/edit/" .. tostring(book_id), nil, {
        Accept = "text/html,application/xhtml+xml",
    })
    if code ~= 200 then return nil end
    return GRUtil.scrapeShelf(body)
end

-- Best-effort: back-dates when a book was finished, instead of leaving
-- Goodreads' default of "today". `when` is a table with year/month/day.
-- Goodreads has no simple form field for this on the plain shelving
-- endpoint; the real UI posts a reading-session row from the book's edit
-- page. This mirrors that in the most generic way we can justify without
-- live markup to check against, and gives up cleanly (false) rather than
-- risk corrupting the request if the page doesn't match.
function GRApi:setDateFinished(book_id, when)
    if not (when and when.year and when.month and when.day) then return false end
    local code, body = request("GET", BASE .. "/review/edit/" .. tostring(book_id), nil, {
        Accept = "text/html,application/xhtml+xml",
    })
    if code ~= 200 then return false end
    local token = GRUtil.scrapeCsrf(body) or self:ensureCsrfToken()
    local review_id = GRUtil.scrapeReviewId(body)
    if not (token and review_id) then return false end
    local form = {
        authenticity_token = token,
        ["review[id]"] = review_id,
        ["review[read_at][year]"] = tostring(when.year),
        ["review[read_at][month]"] = tostring(when.month),
        ["review[read_at][day]"] = tostring(when.day),
    }
    local rcode = request("POST", BASE .. "/review/update/" .. tostring(book_id), GRUtil.formEncode(form), {
        ["X-Requested-With"] = "XMLHttpRequest",
        Accept = "text/html",
    })
    return rcode == 200 or rcode == 201 or rcode == 204 or rcode == 302 or rcode == 303
end

return GRApi
