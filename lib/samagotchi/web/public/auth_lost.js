// Signed out: the auth proxy's session (Okta…) or chi's token is gone. An
// /api answer says so in one of these ways: a 401 (chi's unauthorized, or
// the proxy's own 401 {} for Accept: application/json), a fetch that was
// redirected or came back as HTML (a sign-in page), or, from the probe,
// a redirect fetch can't follow (real IdPs send no CORS: a TypeError, so
// the probe asks with redirect: "manual"). The page then says so in a
// banner with Reload, and reloads by itself at most once a minute (the
// proxy's sign-in brings the user back), never when it can't keep the time.

export const AUTH_RELOAD_KEY = "chi.authReloadAt";
export const AUTH_RELOAD_MS = 60_000;

// Whether a fetch Response says the sign-in is gone.
export function lostAnswer(res) {
  if (!res) return false;
  if (res.status === 401 || res.redirected || res.type === "opaqueredirect") return true;
  const type = res.headers?.get?.("content-type") || "";
  return type.includes("text/html");
}

// "lost" | "ok" | "down" (chi web unreachable: no banner, the page's own
// retries go on).
export async function authProbe(fetchImpl = globalThis.fetch) {
  try {
    const res = await fetchImpl("/api/info", {
      credentials: "same-origin", redirect: "manual", headers: { Accept: "application/json" },
    });
    return lostAnswer(res) ? "lost" : "ok";
  } catch (_) {
    return "down";
  }
}

export const AUTH_LOST_TEXT = "Signed out (the proxy's sign-in or chi's token ended).";

// The page's authLost(reason): once, a banner (doc) and, unless one ran in
// the last minute, a reload. storage: sessionStorage (may be missing or throw).
export function createAuthLost({
  doc = globalThis.document, storage = () => globalThis.sessionStorage, reload = () => globalThis.location.reload(),
  now = () => Date.now(), log = (reason) => console.warn("chi: signed out", reason),
} = {}) {
  let shown = false;
  return function authLost(reason) {
    if (shown) return;
    shown = true;
    log(reason);
    // The reload only when its stamp can be kept: without storage (a
    // private window) a page that keeps losing its sign-in would reload
    // forever, so it gets the banner.
    let due = false;
    try {
      due = now() - (Number(storage().getItem(AUTH_RELOAD_KEY)) || 0) >= AUTH_RELOAD_MS;
      if (due) storage().setItem(AUTH_RELOAD_KEY, String(now()));
    } catch (_) {
      due = false;
    }
    if (due) {
      reload();
      return;
    }
    const bar = doc.createElement("div");
    bar.id = "authLost";
    bar.setAttribute("role", "alert");
    bar.style.cssText = "position:fixed;top:0;left:0;right:0;z-index:10000;padding:8px 16px;font-size:14px;"
      + "color:var(--warn-text);background:var(--warn-bg);border-bottom:1px solid var(--warn-border);"
      + "display:flex;gap:12px;align-items:center;justify-content:center";
    const text = doc.createElement("span");
    text.textContent = AUTH_LOST_TEXT;
    const button = doc.createElement("button");
    button.type = "button";
    button.textContent = "Reload";
    button.addEventListener("click", () => reload());
    bar.append(text, button);
    doc.body.append(bar);
  };
}
