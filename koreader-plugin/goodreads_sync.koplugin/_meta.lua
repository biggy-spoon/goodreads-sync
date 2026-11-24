local _ = require("gettext")

return {
    name = "goodreadssync",
    fullname = _("Goodreads sync"),
    version = "1.1.0-rc8",
    description = _([[Shelves the open book as Currently reading on Goodreads, pushes your reading
progress as you turn pages, and shelves it as Read (with an optional star rating and finished date)
when you finish. Warns before overwriting a shelf Goodreads already has the book on.
Sign in by pasting a session cookie, or by receiving one from the companion browser extension.]]),
}
