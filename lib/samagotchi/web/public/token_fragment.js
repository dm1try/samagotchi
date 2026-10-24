// A link's one-time code in its fragment (https://<public url>/#code=…&s=ID,
// what chi web makes behind an auth proxy: never a token, since a fragment
// outlives the sign-in redirects and stays in the browser's history). The
// page posts it to POST /api/token, which uses it up and sets the cookie,
// then loads itself again without it. The 401 page runs it (chi web serves
// this file without the token); the owner's and participant's pages do on
// load, asking first, since the trade replaces the browser's session. Plain
// module, no imports.

// {code, rest}: the fragment's code and what else it says ("s=ID"), or
// null without one.
export function fragmentCode(hash) {
  const params = new URLSearchParams(String(hash || "").replace(/^#/, ""));
  const code = params.get("code");
  if (!code) return null;
  params.delete("code");
  return { code, rest: params.toString() };
}

export const REPLACE_SESSION_TEXT = "This link signs this browser in as its holder, in place of the session it has now. Open it?";

// Trades the fragment's code, if there is one: the URL loses it at once
// (history.replaceState), the page reloads once the cookie is set. ask():
// whether to go ahead (a page that already has a session); declined, the
// code is dropped unused. Resolves true when it reloads, false when there
// was nothing to trade, it was declined, or the code was refused
// (onRefused gets the server's words).
export async function tradeFragmentCode({
  loc = globalThis.location, hist = globalThis.history, fetchImpl = globalThis.fetch, onRefused = () => {},
  ask = () => true,
} = {}) {
  const found = fragmentCode(loc?.hash);
  if (!found) return false;
  try {
    hist.replaceState(null, "", `${loc.pathname}${loc.search}${found.rest ? `#${found.rest}` : ""}`);
  } catch (_) {}
  if (!ask()) return false;
  let res;
  try {
    res = await fetchImpl("/api/token", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ code: found.code }),
    });
  } catch (_) {
    onRefused("chi web can't be reached: reload to try again.");
    return false;
  }
  if (res.ok) {
    loc.reload();
    return true;
  }
  const body = await res.json().catch(() => ({}));
  onRefused(body.detail || `That link was refused (HTTP ${res.status}): it works once, and an owner's link for 10 minutes.`);
  return false;
}
