// Query parameters the page no longer reads, dropped from the address bar
// as it loads (app.js, history.replaceState), so a bookmark or a link kept
// from an older chi stops carrying them: ?view= (the turn view, removed in
// 0.135.0). The rest of the query stays as written (?dir='s readable
// slashes too), in its order.
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.

export const STALE_PARAMS = ["view"];

// A query part's name ("view" of "view=turn"), decoded as URLSearchParams
// reads it.
function nameOf(part) {
  const raw = part.split("=", 1)[0].replace(/\+/g, " ");
  try { return decodeURIComponent(raw); } catch { return raw; }
}

// +search+ (a location.search) without the stale parameters, "?…" or "";
// null when it has none (nothing to replace).
export function withoutStaleParams(search) {
  const parts = String(search || "").replace(/^\?/, "").split("&").filter(Boolean);
  const kept = parts.filter((part) => !STALE_PARAMS.includes(nameOf(part)));
  if (kept.length === parts.length) return null;
  return kept.length ? `?${kept.join("&")}` : "";
}
