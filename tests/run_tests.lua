#!/usr/bin/env lua
-- Standalone unit tests for gr_util.lua: the pure logic behind the
-- Goodreads sync plugin, with none of KOReader's or LuaSocket's runtime
-- required. Run with any Lua 5.1+ interpreter:
--
--   lua tests/run_tests.lua
--
-- No third-party test framework: a tiny homemade runner keeps this
-- runnable anywhere Lua is installed, without needing luarocks first.

local script_dir = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
package.path = script_dir .. "/../koreader-plugin/goodreads_sync.koplugin/?.lua;" .. package.path

local GRUtil = require("gr_util")

local pass, fail = 0, 0
local failures = {}

local function eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not eq(v, b[k]) then return false end end
    for k, v in pairs(b) do if not eq(v, a[k]) then return false end end
    return true
end

local function check(name, got, want)
    if eq(got, want) then
        pass = pass + 1
    else
        fail = fail + 1
        failures[#failures + 1] = string.format("%s\n    got:  %s\n    want: %s", name, tostring(got), tostring(want))
    end
end

local function section(title) print("\n-- " .. title .. " --") end

-- ---------------------------------------------------------- cleanCookie
section("cleanCookie")
check("drops Path/Domain/Expires attributes",
    GRUtil.cleanCookie("a=1; Path=/; b=2; Domain=.goodreads.com; Expires=Wed, 09 Jun 2027 10:18:14 GMT"),
    "a=1; b=2")
check("trims surrounding whitespace", GRUtil.cleanCookie("  a=1 ;  b=2  "), "a=1; b=2")
check("drops a repeated name, keeping the first", GRUtil.cleanCookie("a=1; a=2"), "a=1")
check("drops empty-value pairs", GRUtil.cleanCookie("a=1; b=; c=3"), "a=1; c=3")
check("empty input gives empty output", GRUtil.cleanCookie(""), "")
check("nil input gives empty output", GRUtil.cleanCookie(nil), "")

-- ------------------------------------------------------------ urlencode
section("urlencode")
check("leaves alphanumerics alone", GRUtil.urlencode("abcXYZ019"), "abcXYZ019")
check("leaves -._~ alone", GRUtil.urlencode("a-b.c_d~e"), "a-b.c_d~e")
check("percent-encodes a space", GRUtil.urlencode("a b"), "a%20b")
check("percent-encodes punctuation", GRUtil.urlencode("a&b=c"), "a%26b%3Dc")

-- ----------------------------------------------------------- formEncode
section("formEncode")
check("encodes and joins with &, sorted for a stable order",
    GRUtil.formEncode({ b = "2", a = "1" }), "a=1&b=2")
check("encodes keys as well as values", GRUtil.formEncode({ ["x y"] = "1" }), "x%20y=1")

-- ------------------------------------------------------------ scrapeCsrf
section("scrapeCsrf")
check("finds the token", GRUtil.scrapeCsrf('<meta name="csrf-token" content="abc123==" />'), "abc123==")
check("nil on a page without one", GRUtil.scrapeCsrf("<html></html>"), nil)
check("nil on nil input", GRUtil.scrapeCsrf(nil), nil)

-- ----------------------------------------------------------- scrapeShelf
section("scrapeShelf")
check("reads a selected data-shelf-name",
    GRUtil.scrapeShelf('<a data-shelf-name="currently-reading" class="selected">Currently reading</a>'),
    "currently-reading")
check("reads a checked shelf radio",
    GRUtil.scrapeShelf('<input name="shelf" value="read" checked>'),
    "read")
check("ignores a non-exclusive shelf even if marked active",
    GRUtil.scrapeShelf('<a data-shelf-name="my-favorites" selected>Favorites</a>'),
    nil)
check("nil when nothing matches", GRUtil.scrapeShelf("<html>nothing here</html>"), nil)
check("nil on nil input", GRUtil.scrapeShelf(nil), nil)

-- -------------------------------------------------------- scrapeReviewId
section("scrapeReviewId")
check("reads review[id] hidden field", GRUtil.scrapeReviewId('<input name="review[id]" value="98765">'), "98765")
check("falls back to a /review/edit/ link", GRUtil.scrapeReviewId('<a href="/review/edit/55512">edit</a>'), "55512")
check("nil when neither is present", GRUtil.scrapeReviewId("<html></html>"), nil)

-- --------------------------------------------------------- clampPercent
section("clampPercent")
check("rounds to the nearest whole number", GRUtil.clampPercent(42.6), 43)
check("floors at 1, not 0", GRUtil.clampPercent(0), 1)
check("floors a negative number at 1", GRUtil.clampPercent(-5), 1)
check("caps at 100", GRUtil.clampPercent(150), 100)
check("nil input treated as 0, clamped to 1", GRUtil.clampPercent(nil), 1)

-- ---------------------------------------------------------- clampStars
section("clampStars")
check("rounds to the nearest whole number", GRUtil.clampStars(3.5), 4)
check("floors at 1", GRUtil.clampStars(0), 1)
check("caps at 5", GRUtil.clampStars(9), 5)

-- ----------------------------------------------------- parseSearchResults
section("parseSearchResults")
check("maps bookId/title/author.name",
    GRUtil.parseSearchResults({ { bookId = 123, title = "Dune", author = { name = "Frank Herbert" } } }, "https://example.test"),
    { { book_id = "123", edition_id = "123", title = "Dune", authors = "Frank Herbert",
        goodreads_url = "https://example.test/book/show/123" } })
check("falls back to id/bookTitleBare/authorName",
    GRUtil.parseSearchResults({ { id = 7, bookTitleBare = "Foo", authorName = "Bar" } }, "https://example.test"),
    { { book_id = "7", edition_id = "7", title = "Foo", authors = "Bar",
        goodreads_url = "https://example.test/book/show/7" } })
check("skips an item with no id", GRUtil.parseSearchResults({ { title = "No id" } }, "https://example.test"), {})
check("empty list on non-table input", GRUtil.parseSearchResults("not a table", "https://example.test"), {})
check("empty list on nil input", GRUtil.parseSearchResults(nil, "https://example.test"), {})

-- -------------------------------------------------------- mergeFields
section("mergeFields")
check("merges new fields over old", GRUtil.mergeFields({ a = 1, b = 2 }, { b = 3, c = 4 }), { a = 1, b = 3, c = 4 })
check("works from a nil base", GRUtil.mergeFields(nil, { a = 1 }), { a = 1 })
check("works with nil fields", GRUtil.mergeFields({ a = 1 }, nil), { a = 1 })
check("does not mutate the original table", (function()
    local original = { a = 1 }
    GRUtil.mergeFields(original, { a = 2 })
    return original.a
end)(), 1)

-- ------------------------------------------------------------- report
print(string.format("\n%d passed, %d failed", pass, fail))
if #failures > 0 then
    print("\nFailures:")
    for _, f in ipairs(failures) do print("  " .. f) end
    os.exit(1)
end
os.exit(0)
