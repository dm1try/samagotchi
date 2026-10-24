// A link's token in its fragment (https://<public url>/#token=…&s=ID, what
// chi web makes behind an auth proxy): no proxy or IdP sees a fragment, so
// the page posts it to POST /api/token, which sets the cookie, then loads
// itself again without it. The 401 page runs it (chi web serves this file
// without the token), and the owner's and participant's pages do on load
// (a browser that already has a cookie). Plain module, no imports.

// {token, rest}: the fragment's token and what else it says ("s=ID"), or
// null without one.
export function fragmentToken(hash) {
  const params = new URLSearchParams(String(hash || "").replace(/^#/, ""));
  const token = params.get("token");
  if (!token) return null;
  params.delete("token");
  return { token, rest: params.toString() };
}

// Trades the fragment's token, if there is one: the URL loses it at once
// (history.replaceState), the page reloads once the cookie is set. Resolves
// true when it reloads, false when there was nothing to trade or the token
// was refused (onRefused gets the server's words).
export async function tradeFragmentToken({
  loc = globalThis.location, hist = globalThis.history, fetchImpl = globalThis.fetch, onRefused = () => {},
} = {}) {
  const found = fragmentToken(loc?.hash);
  if (!found) return false;
  try {
    hist.replaceState(null, "", `${loc.pathname}${loc.search}${found.rest ? `#${found.rest}` : ""}`);
  } catch (_) {}
  let res;
  try {
    res = await fetchImpl("/api/token", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ token: found.token }),
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
  onRefused(body.detail || `That link's token was refused (HTTP ${res.status}).`);
  return false;
}
