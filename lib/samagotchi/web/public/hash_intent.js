// What the page's hash asks for, decided without the page: the session it
// names, the all-sessions view, or the start page. app.js does the work the
// intent describes (select / applyView / clearSelection); the "start" case is
// the one a "#/" typed in the address bar hits while a session is open.
//
// A module of its own: the page's static JS is cached at unversioned URLs, and
// a new export of an old module would leave a cached copy without it; it is
// pure, so it is testable where app.js is not.
import { ALL_SESSIONS_HASH, sessionIdFromHash } from "./route.js";

const START_HASHES = ["", "#", "#/"];

// +claim+: claim_link.js' parse of the same hash, which names the session a
// claim link belongs to when the hash has no session path of its own.
// @return {kind: "session", id} | {kind: "all"} | {kind: "start"} | {kind: "keep"}
export function hashIntent(hash = "", { selected = null, claim = null } = {}) {
  const id = sessionIdFromHash(hash) || claim?.sessionId || null;
  if (id) return { kind: "session", id };
  if (hash === ALL_SESSIONS_HASH) return { kind: "all" };
  // The start page's own hash with a session still held: the page goes there
  // too. Any other fragment (an anchor clicked in a rendered answer) isn't
  // about the page's session at all.
  return selected && START_HASHES.includes(hash) ? { kind: "start" } : { kind: "keep" };
}
