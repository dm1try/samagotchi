// When the working set's peek and reader ask the item route again: the
// server's item for a page row (its signature), and which of two answers
// is the newer. A module of its own (docs/internals/web-frontend.md, "New
// exports go in new modules"); working_set.js matches rows with it too.

// The states the server's items carry (working_set.js STATES).
export const ITEM_STATES = Object.freeze(["live", "stale", "forgotten", "dropped"]);
const ELLIPSIS = "…";

// The server's items by "kind:key", and its URLs (a cut row key matches one
// by prefix).
export function serverIndex(server) {
  const byKey = new Map();
  const urls = [];
  for (const it of server?.items || []) {
    if (!it || !ITEM_STATES.includes(it.state)) continue;
    byKey.set(`${it.kind}:${it.key}`, it);
    if (it.kind === "url") urls.push(it);
  }
  return { byKey, urls };
}

// The server's item for +item+: files by absolute path (a title fallback
// won't match), memories by name, URLs by the row's key (its params
// preview: cut at 80 characters with a "…", whose head must start the
// server's URL). null when the server doesn't know it (a running call).
export function serverItem(index, item) {
  const exact = index.byKey.get(`${item.kind}:${item.key}`);
  if (exact || item.kind !== "url") return exact || null;
  const key = String(item.key);
  if (!key.endsWith(ELLIPSIS)) return null;
  const head = key.slice(0, -1);
  return index.urls.find((it) => String(it.key).startsWith(head)) || null;
}

// The signature of +item+'s server item (count, ops, tokens, state,
// has_drop, pinned: a new run of it raises count), null when the server
// doesn't know it (+server+: a snapshot {items, at}, or null). The peek and
// the reader ask the item route again only when it changed.
export function serverSig(server, item) {
  const found = item && server ? serverItem(serverIndex(server), item) : null;
  return found ? JSON.stringify([found.count, found.ops, found.tokens, found.state, found.has_drop, found.pinned]) : null;
}

// Whether the item route's +answer+ is older than the +kept+ one: both
// from the same running turn (its turn_id) and built from a shorter
// conversation (at). Its at may go down otherwise (a turn's end keeps
// less), so a running → idle answer is always taken.
export function olderAnswer(kept, answer) {
  return !!(kept?.running && answer?.running && kept.turn_id && kept.turn_id === answer.turn_id && Number(answer.at) < Number(kept.at));
}
