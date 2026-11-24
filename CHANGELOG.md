# Changelog

## 1.1.0-rc12 (unreleased)

- Fixed a crash ("attempt to index field 'document' (a nil value)") in
  `pushCurrentlyReading`/`pushFinished`: both re-read
  `self.ui.document.file` *inside* an `ensureLinked` callback that can
  fire a real delay later (after a network search, or after the reader
  picks from a multi-match list) - if the book had been closed by then,
  `self.ui.document` was already nil. `ensureLinked` now resolves the
  path once up front and threads it through the whole async chain as a
  second callback argument (`callback(link, path)`), instead of any
  later code re-reading `self.ui.document`.

## 1.1.0-rc11

- Fixed progress sync staying stuck forever if you sign in to Goodreads
  *after* a book is already open: linking a book to Goodreads and
  shelving it only happened once, in `onReaderReady` (fired once at
  open). If sign-in hadn't happened yet at that point, the book was
  never linked, and every later `onPageUpdate` push silently no-opped
  since it requires an existing link. `onPageUpdate` now also retries
  the link/shelve step (cheaply, since it no-ops once already linked),
  so a late sign-in self-heals within a page-turn interval or two
  instead of needing the book closed and reopened.

## 1.1.0-rc10

- Fixed the extension still being blocked by its own `connect-src`
  policy after the rc9 fix: a CSP source expression that omits a port
  matches only the scheme's *default* port (80 for `http:`), per the
  CSP spec — so `http://*` matched nothing but port 80, silently
  excluding the e-reader's port 8970. Added an explicit wildcard port
  (`http://*:* https://*:*`). Browser-extension-only change.

## 1.1.0-rc9

- Fixed the browser extension failing with a CORS/network error on
  Firefox ("Content-Security-Policy: Upgrading insecure request...").
  Firefox's default extension CSP was upgrading the `http://` request to
  the e-reader to `https://`; since the e-reader's cookie receiver only
  speaks plain HTTP, that handshake failed before any response came
  back, which surfaced as a generic CORS failure. Added an explicit
  `content_security_policy` to `browser-extension/manifest.json` with a
  `connect-src` that allows plain `http://`, replacing whatever default
  policy was causing the upgrade. Browser-extension-only change — no
  koplugin files changed, so nothing new needs reinstalling on the
  e-reader for this one.

## 1.1.0-rc8

- Fixed the cookie-receiver panel leaving e-ink ghosting behind after
  pressing Stop: `onStop` called `UIManager:close(self)` with no refresh
  type, which lets UIManager pick its own (lesser) default. Passing
  `"full"` forces a complete refresh that actually clears the panel's
  afterimage.

## 1.1.0-rc7

- Fixed the browser extension failing to reach the e-reader with "Could
  not reach the e-reader" on Chrome, even with correct address/code and
  both devices on the same network: Chrome's Private Network Access
  check blocks a page/extension from fetching a local-network address
  unless the server's preflight response includes
  `Access-Control-Allow-Private-Network: true`. Added it to
  `gr_cookie_receiver.lua`'s response headers.

## 1.1.0-rc6

- Fixed the cookie-receiver panel still appearing invisible after the
  self.dimen fix: the "Sign in from browser extension…" and "Sign in by
  pasting a cookie…" menu entries had `keep_menu_open = true`, which
  keeps KOReader's touch menu open on top after tapping. The panel was
  likely being drawn underneath the still-open menu; what looked like
  tapping its Stop button was probably the outer menu dismissing itself
  on an outside tap. Removed `keep_menu_open` from both entries, since
  neither is a toggle that needs the menu to stay open.

## 1.1.0-rc5

- Fixed the cookie-receiver panel rendering invisible (though still
  tappable — closing it worked, nothing else did): `ReceiverWidget` never
  set `self.dimen`, which UIManager needs to know what screen region to
  actually paint/refresh. Gesture hit-testing doesn't need it (it walks
  the widget tree directly), which is why taps still worked while nothing
  was visible. Added `self.dimen = self[1]:getSize()`, matching the
  pattern KOReader's own full-screen widgets use.

## 1.1.0-rc4

- Fixed the cookie-receiver freezing KOReader entirely: `Receiver.open`
  called a blocking `os.execute("iptables ...")` to open the Kindle's
  firewall for the listening port, and ran it *before* showing the
  panel. If that call hung on a given device (no `iptables` in PATH,
  slow netfilter module load, etc.), the whole UI thread froze before
  ever drawing anything — matching exactly what on-device testing showed
  (port reachable via the OS's TCP backlog, panel never rendered).
  Removed the firewall toggle entirely (unneeded on the tested device —
  the port was reachable without it) and moved `UIManager:show()` to the
  very first thing `Receiver.open` does, so the panel appears even if
  something later goes wrong.

## 1.1.0-rc3

- Fixed the cookie-receiver panel not appearing until the next screen
  refresh (e.g. after a sleep/wake cycle): `Receiver.open` now calls
  `UIManager:forceRePaint()` right after showing the widget, instead of
  relying on some later redraw to flush it to the e-ink screen.

## 1.1.0-rc2

- Fixed a crash on "Sign in from browser extension…": the cookie
  receiver's status widget passed `face = nil` to `TextBoxWidget`
  instead of a real font face, which made KOReader's text renderer index
  a nil value. Found via `crash.log` after a real on-device test.

## 1.1.0-rc1

Testing build — no functional change from 1.0.0's code; this tag exists
to mark the round of live testing on real hardware.

## 1.0.0

First release.

- Auto-links the open book to Goodreads by title/author.
- Shelves as Currently reading on open, Read on finish.
- Pushes reading percentage every ~10 page turns.
- Mismatch detection: best-effort check before overwriting a shelf
  Goodreads already has the book on.
- Finished-date editing: offers to back-date a book shelved as Read.
- Star rating prompt once a book is shelved as Read.
- Two sign-in paths: paste a cookie, or receive one from the companion
  browser extension over the local network.
