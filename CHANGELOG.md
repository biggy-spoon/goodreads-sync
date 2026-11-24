# Changelog

## 1.1.0-rc4 (unreleased)

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
