local _ = require("gettext")

return {
    name = "goodreadssync",
    fullname = _("Goodreads sync"),
    description = _([[Shelves the open book as Currently reading on Goodreads, pushes your reading
progress as you turn pages, and shelves it as Read (with an optional star rating) when you finish.
Sign in by pasting a session cookie copied from a browser where you are signed in to goodreads.com.]]),
}
