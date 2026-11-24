-- A small client for the handful of goodreads.com endpoints this plugin
-- needs. Goodreads has no public API for any of this any more, so like
-- every other Goodreads-sync tool still around, it drives the same
-- endpoints the website's own pages use: a signed-in session cookie plus
-- a Rails CSRF token (fetched once from the front page and cached).
--
-- This talks to an external site we don't control: a layout change there
-- can break the one scrape this module does (the CSRF token). Everything
-- else is a plain form POST with a JSON or empty reply.

local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local logger = require("logger")

local GRApi = {}
GRApi.settings = nil -- set by the caller before any request

local BASE = "https://www.goodreads.com"
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%.~_]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function formEncode(fields)
    local parts = {}
    for k, v in pairs(fields) do
        parts[#parts + 1] = urlencode(k) .. "=" .. urlencode(v)
    end
    return table.concat(parts, "&")
end

-- A handful of Set-Cookie attribute names we must not fold into the jar
-- as if they were cookies of their own.
local COOKIE_ATTRS = {
    path = true, domain = true, expires = true, ["max-age"] = true,
    samesite = true, secure = true, httponly = true,
}

-- Rebuilds a clean "name=value; name=value" Cookie header from whatever
-- was saved, dropping attribute-looking pairs.
local function cleanCookie(raw)
    local seen, order = {}, {}
    for name, value in tostring(raw or ""):gmatch("([%w_%-]+)=([^;]*)") do
        if not COOKIE_ATTRS[name:lower()] then
            value = value:match("^%s*(.-)%s*$")
            if value ~= "" and not seen[name] then
                seen[name] = value
                order[#order + 1] = name
            end
        end
    end
    local out = {}
    for _, name in ipairs(order) do out[#out + 1] = name .. "=" .. seen[name] end
    return table.concat(out, "; ")
end
GRApi.cleanCookie = cleanCookie

local function request(method, url, body, extra_headers)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then return nil end
    local cookie = cleanCookie(GRApi.settings and GRApi.settings:getCookie())
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

-- Pulls <meta name="csrf-token" content="..."> out of an HTML page.
local function scrapeCsrf(html)
    return html and html:match('name="csrf%-token"%s+content="([^"]+)"')
end

function GRApi:ensureCsrfToken(force)
    if self._csrf and not force then return self._csrf end
    local code, body = request("GET", BASE .. "/")
    if code ~= 200 then return nil end
    local token = scrapeCsrf(body)
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
    local url = BASE .. "/book/auto_complete?format=json&q=" .. urlencode(query)
    local code, body = request("GET", url, nil, { Accept = "application/json" })
    if code ~= 200 or not body or body == "" then return nil end
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" then return nil end
    local out = {}
    for _, item in ipairs(decoded) do
        local id = item.bookId or item.id
        if id then
            local authors = item.author and item.author.name or item.authorName
            out[#out + 1] = {
                book_id = tostring(id),
                edition_id = tostring(id),
                title = item.title or item.bookTitleBare or "?",
                authors = authors or "",
                goodreads_url = BASE .. "/book/show/" .. tostring(id),
            }
        end
    end
    return out
end

-- Adds/moves `book_id` to exclusive shelf `shelf` ("to-read",
-- "currently-reading" or "read"). Returns true/false.
function GRApi:addToShelf(book_id, shelf)
    local token = self:ensureCsrfToken()
    if not token then return false end
    local body = formEncode({
        book_id = book_id,
        name = shelf,
        authenticity_token = token,
    })
    local code = request("POST", BASE .. "/shelf/add_to_shelf", body, {
        ["X-Requested-With"] = "XMLHttpRequest",
    })
    if code == 404 then
        -- A stale cached token is the usual cause; one retry with a fresh one.
        self:resetCsrfToken()
        token = self:ensureCsrfToken(true)
        if not token then return false end
        body = formEncode({ book_id = book_id, name = shelf, authenticity_token = token })
        code = request("POST", BASE .. "/shelf/add_to_shelf", body, { ["X-Requested-With"] = "XMLHttpRequest" })
    end
    return code == 200 or code == 201 or code == 204
end

-- Sends a 1-100 reading percentage. The book must already be on an
-- exclusive shelf (Goodreads otherwise answers 404).
function GRApi:setProgress(book_id, percent)
    local pct = math.max(1, math.min(100, math.floor((tonumber(percent) or 0) + 0.5)))
    local token = self:ensureCsrfToken()
    if not token then return false end
    local body = formEncode({
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
    local stars = math.max(1, math.min(5, math.floor((tonumber(rating) or 0) + 0.5)))
    local token = self:ensureCsrfToken()
    if not token then return false end
    local url = BASE .. "/review/rate/" .. book_id .. "?rating=" .. stars
    local code = request("POST", url, "", { ["X-Requested-With"] = "XMLHttpRequest" })
    return code == 200 or code == 201 or code == 204
end

local EXCLUSIVE_SHELVES = { ["to-read"] = true, ["currently-reading"] = true, ["read"] = true }

-- Best-effort read of which exclusive shelf the signed-in account already
-- has `book_id` on, by scraping the book's review-edit page. Goodreads'
-- markup for this isn't documented and can change without notice, so this
-- returns nil (meaning "couldn't tell") far more readily than it guesses
-- wrong; callers must treat nil as "proceed as usual", never as "none".
function GRApi:currentShelf(book_id)
    local code, body = request("GET", BASE .. "/review/edit/" .. tostring(book_id), nil, {
        Accept = "text/html,application/xhtml+xml",
    })
    if code ~= 200 or not body then return nil end
    -- The exclusive-shelf picker on that page marks the active one; two
    -- independent patterns are tried since either a `selected`/`checked`
    -- attribute or an `is-active`-style class is a reasonable Rails guess,
    -- and we'd rather miss a hit than scrape the wrong element.
    for shelf in body:gmatch('data%-shelf%-name="([%w%-]+)"[^>]-selected') do
        if EXCLUSIVE_SHELVES[shelf] then return shelf end
    end
    for shelf in body:gmatch('name="shelf"[^>]-value="([%w%-]+)"[^>]-checked') do
        if EXCLUSIVE_SHELVES[shelf] then return shelf end
    end
    return nil
end

-- Best-effort: back-dates when a book was finished, instead of leaving
-- Goodreads' default of "today". `when` is a table with year/month/day.
-- Goodreads has no simple form field for this on the plain shelving
-- endpoint; the real UI posts a reading-session row from the book's edit
-- page. This mirrors that in the most generic way we can justify without
-- having the live markup to check against, and gives up cleanly (false)
-- rather than risk corrupting the request if the page doesn't match.
function GRApi:setDateFinished(book_id, when)
    if not (when and when.year and when.month and when.day) then return false end
    local code, body = request("GET", BASE .. "/review/edit/" .. tostring(book_id), nil, {
        Accept = "text/html,application/xhtml+xml",
    })
    if code ~= 200 or not body then return false end
    local token = scrapeCsrf(body) or self:ensureCsrfToken()
    if not token then return false end
    local review_id = body:match('name="review%[id%]"%s+value="(%d+)"')
        or body:match('/review/edit/(%d+)')
    if not review_id then return false end
    local form = {
        authenticity_token = token,
        ["review[id]"] = review_id,
        ["review[read_at][year]"] = tostring(when.year),
        ["review[read_at][month]"] = tostring(when.month),
        ["review[read_at][day]"] = tostring(when.day),
    }
    local rcode = request("POST", BASE .. "/review/update/" .. tostring(book_id), formEncode(form), {
        ["X-Requested-With"] = "XMLHttpRequest",
        Accept = "text/html",
    })
    return rcode == 200 or rcode == 201 or rcode == 204 or rcode == 302 or rcode == 303
end

return GRApi
