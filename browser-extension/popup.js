// Reads this browser's goodreads.com cookies and POSTs them to the
// address/code shown on the e-reader's "Sign in from browser extension"
// screen. See ../koreader-plugin/goodreads_sync.koplugin/gr_cookie_receiver.lua
// for what's on the other end.

const addressInput = document.getElementById("address");
const codeInput = document.getElementById("code");
const sendButton = document.getElementById("send");
const statusEl = document.getElementById("status");

chrome.storage.local.get(["lastAddress"], (saved) => {
  if (saved.lastAddress) addressInput.value = saved.lastAddress;
});

function setStatus(text, kind) {
  statusEl.textContent = text;
  statusEl.className = kind || "";
}

async function collectCookieHeader() {
  const cookies = await chrome.cookies.getAll({ domain: "goodreads.com" });
  const pairs = cookies
    .filter((c) => c.name !== "jwt_token") // short-lived; stale copies just confuse the server
    .map((c) => `${c.name}=${c.value}`);
  return pairs.join("; ");
}

sendButton.addEventListener("click", async () => {
  const address = addressInput.value.trim();
  const code = codeInput.value.trim();
  if (!address || !code) {
    setStatus("Enter the address and code shown on the e-reader.", "err");
    return;
  }
  chrome.storage.local.set({ lastAddress: address });

  setStatus("Reading cookies…");
  let cookie;
  try {
    cookie = await collectCookieHeader();
  } catch (e) {
    setStatus("Could not read cookies: " + e.message, "err");
    return;
  }
  if (!cookie) {
    setStatus("No goodreads.com cookies found. Sign in to goodreads.com in this browser first.", "err");
    return;
  }

  setStatus("Sending to the e-reader…");
  try {
    const response = await fetch(`http://${address}/cookie`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, cookie }),
    });
    const data = await response.json().catch(() => ({}));
    if (response.ok && data.ok) {
      setStatus("Sent. The e-reader should now say it's signed in.", "ok");
    } else if (data.error === "code") {
      setStatus(`Wrong code (${data.left ?? "?"} tries left on the e-reader).`, "err");
    } else {
      setStatus("The e-reader rejected it: " + (data.error || response.status), "err");
    }
  } catch (e) {
    setStatus("Could not reach the e-reader. Check the address and that both devices share the same Wi-Fi.", "err");
  }
});
