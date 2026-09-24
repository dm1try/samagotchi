// The page's place in its URL hash: #/s/<session id> for an open session,
// #/sessions for the all-sessions view, nothing for the empty start.
export const ALL_SESSIONS_HASH = "#/sessions";

export function sessionHash(id) {
  return id ? `#/s/${encodeURIComponent(id)}` : "";
}

export function sessionIdFromHash(hash) {
  const m = /^#\/s\/([^/?#]+)$/.exec(hash || "");
  if (!m) return null;
  try {
    return decodeURIComponent(m[1]) || null;
  } catch (_) {
    return null;
  }
}
