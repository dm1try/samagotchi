// The page's session list as a projection of the hub's events
// (GET /api/events): a pure reducer over the list the page holds.

// @param list the current list (never mutated)
// @param type "snapshot" | "session" | "session_gone"
// @param data the frame's data
// @return the next list; the same array when nothing changed, so a caller
//   can skip a redraw
export function applySessionEvent(list, type, data = {}) {
  if (type === "snapshot") return Array.isArray(data.sessions) ? data.sessions.slice() : [];
  if (type === "session") {
    const s = data.session;
    if (!s || !s.id) return list;
    const i = list.findIndex((x) => x.id === s.id);
    // A known session is replaced in place: a worker saves several times
    // per turn, and a card that jumped under the pointer each time would
    // be worse than an order that lags until the next snapshot or the
    // all view (sortedByUpdated). A new one goes on top.
    if (i < 0) return [s, ...list];
    const next = list.slice();
    next[i] = s;
    return next;
  }
  if (type === "session_gone") {
    if (!list.some((x) => x.id === data.id)) return list;
    return list.filter((x) => x.id !== data.id);
  }
  return list;
}

const updatedMs = (s) => {
  const ms = Date.parse(s.updated_at || "");
  return Number.isNaN(ms) ? 0 : ms;
};

// The list in the server's order: updated_at desc (a snapshot's order).
export function sortedByUpdated(list) {
  return list.slice().sort((a, b) => updatedMs(b) - updatedMs(a));
}

// A delegated session (parent_id) right after its parent when both are in
// the list: families keep the place of their newest member, the parent
// leads, its children follow in the list's order. A child whose parent
// is not listed stays where it is.
export function withChildrenAfterParents(list) {
  const ids = new Set(list.map((s) => s.id));
  const children = new Map();
  for (const s of list) {
    if (s.parent_id && ids.has(s.parent_id) && s.parent_id !== s.id) {
      if (!children.has(s.parent_id)) children.set(s.parent_id, []);
      children.get(s.parent_id).push(s);
    }
  }
  if (!children.size) return list;
  const grouped = (s) => s.parent_id && ids.has(s.parent_id) && s.parent_id !== s.id;
  const familyMs = (s) => Math.max(updatedMs(s), ...(children.get(s.id) || []).map(updatedMs));
  const heads = list.filter((s) => !grouped(s));
  const ordered = heads.slice().sort((a, b) => familyMs(b) - familyMs(a));
  return ordered.flatMap((s) => [s, ...(children.get(s.id) || [])]);
}
