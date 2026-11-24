# Changelog

## 1.1.0-rc9 (unreleased)

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
