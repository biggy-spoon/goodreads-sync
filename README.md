# Goodreads sync for KOReader

A small, independent KOReader plugin that keeps Goodreads in step with
what you're reading: it shelves the open book as **Currently reading**,
pushes your reading percentage as you turn pages, and shelves it as
**Read** (with an optional star rating and finished date) once you reach
the end.

Goodreads retired its public API years ago, so — like every other
Goodreads-sync tool still around — this drives the same endpoints the
website's own pages use, authenticated with your browser's session
cookie. See [`koreader-plugin/goodreads_sync.koplugin/gr_api.lua`](koreader-plugin/goodreads_sync.koplugin/gr_api.lua)
for exactly what it calls.

## What's in this repo

- [`koreader-plugin/goodreads_sync.koplugin/`](koreader-plugin/goodreads_sync.koplugin) —
  the plugin itself.
- [`browser-extension/`](browser-extension) — a small, unpublished Chrome/Edge
  extension that reads your goodreads.com cookies and sends them to the
  plugin over your local network, so you don't have to type a long cookie
  on an e-ink keyboard.

## Features

- **Auto-linking**: finds the open book on Goodreads by title and author;
  if more than one match comes back, asks you to pick.
- **Shelving**: Currently reading on open, Read when you finish.
- **Progress sync**: pushes your percentage every ~10 page turns.
- **Mismatch detection**: before moving a book to Currently reading, makes
  a best-effort check for whether Goodreads already has it on a different
  shelf (e.g. Read from a previous time through it) and asks before
  touching it, instead of silently overwriting.
- **Finished-date editing**: offers to back-date a book shelved as Read,
  instead of leaving Goodreads' default of "today".
- **Star rating**: prompts for 1-5 stars once a book is shelved as Read.
- **Two sign-in paths**: paste a cookie by hand, or receive it from the
  companion browser extension over your local network.

## Installing the plugin

1. Copy `koreader-plugin/goodreads_sync.koplugin/` into KOReader's
   `plugins` folder (on a Kindle: `koreader/plugins/`).
2. Restart KOReader.
3. `Tools → Goodreads sync`.

## Signing in

### Option A — paste a cookie

1. On a computer, sign in to goodreads.com, open developer tools (F12) →
   Network, reload, click any request to goodreads.com, and copy its
   `Cookie` request header value.
2. `Tools → Goodreads sync → Sign in by pasting a cookie…`, paste it, Save.

### Option B — the browser extension

1. Load `browser-extension/` as an unpacked extension (`chrome://extensions`
   → Developer mode → "Load unpacked") in a browser where you're signed in
   to goodreads.com.
2. On the device: `Tools → Goodreads sync → Sign in from browser
   extension…`. It shows an address and a 4-digit code.
3. Open the extension's popup, type the address and code, Send.

Either way, the cookie eventually expires; repeat the steps above when
pushes silently stop working.

## Limitations

- This drives undocumented, reverse-engineered endpoints on goodreads.com.
  A layout change there can break it without warning — check KOReader's
  logs if sync seems to have stopped.
- Mismatch detection and finished-date editing scrape the book's Goodreads
  page with heuristics that aren't guaranteed to match the site's current
  markup; both fail safe (they skip the feature rather than guess wrong),
  so treat them as a nice-to-have, not a guarantee.
- It only pushes what you do in KOReader — it doesn't pull shelf, rating
  or review changes made on Goodreads itself back down.
- The browser-extension cookie transfer is plain HTTP on your local
  network: fine on Wi-Fi you trust, not on a shared or public one.

## License

MIT — see [LICENSE](LICENSE).
