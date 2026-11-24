# Tests

Unit tests for `gr_util.lua` — the pure parsing/formatting logic behind
the plugin (cookie cleaning, URL/form encoding, CSRF and shelf scraping,
percent/star clamping, search-result mapping, settings merging). It has
no KOReader or LuaSocket dependency, so these run with any plain Lua
interpreter, no mocking required.

```sh
lua tests/run_tests.lua
```

Works with `lua5.1`, `lua5.3`, `lua5.4` or `luajit` — whichever is on
your `PATH` as `lua`. Exits 0 with all passing, 1 with a list of failures
otherwise.

These tests don't cover `gr_api.lua`'s actual HTTP calls, `main.lua`'s UI
flow, or `gr_cookie_receiver.lua`'s local server — those need a running
KOReader (or a much heavier mocking setup) to exercise meaningfully. If
you want to extend coverage there, the logic worth pulling out into
`gr_util.lua` and testing the same way is anything that doesn't need the
network, the filesystem, or KOReader's widgets.
