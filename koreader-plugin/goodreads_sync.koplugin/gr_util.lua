-- Pure helper functions used by gr_api.lua, pulled out into their own
-- module so they can be unit-tested (see ../../tests) without needing to
-- fake KOReader's or LuaSocket's runtime.

local GRUtil = {}

function GRUtil.urlencode(s)
    return (tostring(s):gsub("[^%w%-%.~_]", function(c) return string.format("%%%02X", c:byte()) end))
end

function GRUtil.formEncode(fields)
    local parts = {}
    for k, v in pairs(fields) do
        parts[#parts + 1] = GRUtil.urlencode(k) .. "=" .. GRUtil.urlencode(v)
    end
    table.sort(parts) -- a stable order makes this testable
    return table.concat(parts, "&")
end

-- A handful of Set-Cookie attribute names we must not fold into the jar
-- as if they were cookies of their own.
local COOKIE_ATTRS = {
    path = true, domain = true, expires = true, ["max-age"] = true,
    samesite = true, secure = true, httponly = true,
}

-- Rebuilds a clean "name=value; name=value" Cookie header from whatever
-- was saved: trims whitespace, drops attribute-looking pairs, and drops
-- a second copy of a name that already appeared (the first wins).
function GRUtil.cleanCookie(raw)
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

-- Pulls <meta name="csrf-token" content="..."> out of an HTML page.
function GRUtil.scrapeCsrf(html)
    return html and html:match('name="csrf%-token"%s+content="([^"]+)"')
end

local EXCLUSIVE_SHELVES = { ["to-read"] = true, ["currently-reading"] = true, ["read"] = true }
GRUtil.EXCLUSIVE_SHELVES = EXCLUSIVE_SHELVES

-- Best-effort read of which exclusive shelf a review-edit page's markup
-- marks as active. Returns nil ("couldn't tell") far more readily than a
-- wrong guess; callers must treat nil as "proceed as usual", never as
-- "no shelf at all".
function GRUtil.scrapeShelf(html)
    if not html then return nil end
    for shelf in html:gmatch('data%-shelf%-name="([%w%-]+)"[^>]-selected') do
        if EXCLUSIVE_SHELVES[shelf] then return shelf end
    end
    for shelf in html:gmatch('name="shelf"[^>]-value="([%w%-]+)"[^>]-checked') do
        if EXCLUSIVE_SHELVES[shelf] then return shelf end
    end
    return nil
end

-- The review id a review-edit page is for, for posting a date-finished
-- update against the right record.
function GRUtil.scrapeReviewId(html)
    if not html then return nil end
    return html:match('name="review%[id%]"%s+value="(%d+)"') or html:match('/review/edit/(%d+)')
end

-- Clamps a reading percentage to Goodreads' 1-100 range, rounding to the
-- nearest whole number.
function GRUtil.clampPercent(n)
    return math.max(1, math.min(100, math.floor((tonumber(n) or 0) + 0.5)))
end

-- Clamps a star rating to Goodreads' 1-5 range, rounding to the nearest
-- whole number.
function GRUtil.clampStars(n)
    return math.max(1, math.min(5, math.floor((tonumber(n) or 0) + 0.5)))
end

-- Maps a decoded /book/auto_complete JSON array into this plugin's own
-- book shape. Returns an empty list (never nil) for anything odd, so
-- callers can always iterate the result.
function GRUtil.parseSearchResults(decoded, base_url)
    local out = {}
    if type(decoded) ~= "table" then return out end
    for _, item in ipairs(decoded) do
        local id = item.bookId or item.id
        if id then
            local authors = item.author and item.author.name or item.authorName
            out[#out + 1] = {
                book_id = tostring(id),
                edition_id = tostring(id),
                title = item.title or item.bookTitleBare or "?",
                authors = authors or "",
                goodreads_url = (base_url or "") .. "/book/show/" .. tostring(id),
            }
        end
    end
    return out
end

-- Merges `fields` into (a copy of) `entry`, used for both the book-link
-- table kept in settings and anywhere else a small table of fields needs
-- updating without losing what wasn't mentioned.
function GRUtil.mergeFields(entry, fields)
    local merged = {}
    for k, v in pairs(entry or {}) do merged[k] = v end
    for k, v in pairs(fields or {}) do merged[k] = v end
    return merged
end

return GRUtil
