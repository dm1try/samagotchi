// The page's session list as a projection of the hub's events
// (GET /api/events): a pure reducer over the list the page holds.
import { waitingOn } from "./notify.js";

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

// The sessions a list shows: archived ones only when asked (the all view's
// "include archived"). The page keeps them in its list either way: a parent
// chip and the open session still need them.
export function listedSessions(list, includeArchived = false) {
  return includeArchived ? list : list.filter((s) => !s.archived);
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

const WAITING_BADGES = {
  question: { text: "question", title: "Waiting for your answer" },
  approval: { text: "approval", title: "Waiting for your approval" },
  continue: { text: "out of steps", title: "The turn hit its step limit: continue or stop it" },
  card: { text: "needs you", title: "A card in the running turn waits for you" },
};

// A card's "needs you" badge: what the session waits on the user for
// (notify.js waitingOn), or null.
// @return null | {kind, text, title}
export function waitingBadge(summary) {
  const waiting = waitingOn(summary);
  if (!waiting) return null;
  // A delegate's approval waiting in its parent's card (the approval relay).
  const parent = summary.pending_question?.relayed_to;
  if (parent && waiting.reason !== "card") {
    return { kind: waiting.reason, text: `in parent ${parent}`,
      title: `Waiting for your ${waiting.reason} in parent session ${parent} (answering here works too)` };
  }
  return { kind: waiting.reason, ...WAITING_BADGES[waiting.reason] };
}

// A card's badge for a last turn a hook stopped (the same marker as
// `chi sessions list`'s "[looped]" / "[stopped by X]"): "looped" for
// loop-guard, "stopped by <name>" for any other hook; null when the last
// turn ended otherwise.
// @return null | {text, title}
export function stoppedBadge(summary) {
  const by = summary?.last_turn?.stopped_by;
  if (!by) return null;
  return by === "loop-guard"
    ? { text: "looped", title: "loop-guard stopped the last turn" }
    : { text: `stopped by ${by}`, title: `${by} stopped the last turn` };
}

// What the all view's search matches for a session: its waiting badge's words
// ("waiting", "question", "approval", …) and/or its stopped badge's words
// ("looped", "stopped by <name>"); "" for one with neither.
export function waitingSearchText(summary) {
  const parts = [];
  const badge = waitingBadge(summary);
  if (badge) parts.push(`waiting ${badge.text}`);
  const stopped = stoppedBadge(summary);
  if (stopped) parts.push(stopped.text);
  return parts.join(" ");
}

// The sessions that wait on the user (waitingOn) first, the rest after,
// each part in the list's order: an answered one goes back to its place.
// A delegated session moves with its parent when both are listed (a
// family waits when any of it does), so withChildrenAfterParents' groups
// stay together.
export function waitingFirst(list) {
  const ids = new Set(list.map((s) => s.id));
  const family = (s) => (s.parent_id && ids.has(s.parent_id) ? s.parent_id : s.id);
  const waiting = new Set(list.filter((s) => waitingOn(s)).map(family));
  if (!waiting.size) return list;
  return [...list.filter((s) => waiting.has(family(s))), ...list.filter((s) => !waiting.has(family(s)))];
}

// The list in an order shown before (+ids+): what the pointer is over
// doesn't move. Sessions new since then go after, in the list's order;
// gone ones drop out.
export function heldOrder(ids, list) {
  const at = new Map(ids.map((id, i) => [id, i]));
  const known = list.filter((s) => at.has(s.id)).sort((a, b) => at.get(a.id) - at.get(b.id));
  return [...known, ...list.filter((s) => !at.has(s.id))];
}

// Whether +other+ is +id+ or one of its delegates, at any depth, by the
// list's parent_ids: an archive of +id+ stops +other+'s worker too.
export function inTree(list, id, other) {
  const byId = new Map(list.map((s) => [s.id, s]));
  const seen = new Set();
  for (let at = other; at && !seen.has(at); at = byId.get(at)?.parent_id) {
    if (at === id) return true;
    seen.add(at);
  }
  return false;
}

// ── Select mode (the all view's bulk archive) ─────────────────────────────

// The ids from +fromId+ to +toId+ in a drawn order, both included, in
// either direction: a Shift-click range. Just [toId] when +fromId+ isn't
// drawn (no earlier pick, or it went away).
export function rangeIds(order, fromId, toId) {
  const to = order.indexOf(toId);
  if (to < 0) return [];
  const from = fromId == null ? -1 : order.indexOf(fromId);
  if (from < 0) return [toId];
  return from <= to ? order.slice(from, to + 1) : order.slice(to, from + 1);
}

// What a batch acts on: the picked ids that are shown, in the drawn order,
// the not-archived ones for an archive, the archived ones for an unarchive.
// A pick that isn't shown (the search hides it) stays picked, untouched.
// @param picked Set of ids
// @param shownIds the drawn order
// @param sessionsById Map id → session summary
export function batchTargets(picked, shownIds, archive, sessionsById) {
  return shownIds.filter((id) => {
    const s = sessionsById.get(id);
    return picked.has(id) && s && !!s.archived === !archive;
  });
}

// A refusal's reason as the card shows it: the server's words, without
// the api() status suffix.
function refusalText(error) {
  return String(error?.message || "refused").replace(/\s*\(\d{3}\)$/, "");
}

// Runs +act+ over +ids+ one at a time (a live session's stop waits on the
// server, and a parent's and its delegate's stops would race). An id an
// earlier answer already covered (a delegate of a parent before it, in its
// archived / unarchived / discarded list) is not sent again.
// @param act async (id) → {ok: true, result} | {ok: false, error}
// @param onProgress (doneCount, total) after each id
// @return {done, covered, skipped: [{id, code, reason}], gone, affected, flipped}
//   done: the ids a request succeeded on (what an Undo targets);
//   covered: picked ids an earlier answer covered; gone: 404s;
//   affected: every id the answers listed (discarded ones too);
//   flipped: the ids archived / unarchived (not the discarded)
export async function runBatch(ids, act, onProgress = () => {}) {
  const out = { done: [], covered: [], skipped: [], gone: [], affected: new Set(), flipped: new Set() };
  const targets = ids.slice();
  for (let i = 0; i < targets.length; i++) {
    const id = targets[i];
    if (out.affected.has(id)) {
      out.covered.push(id);
    } else {
      const answer = await act(id);
      if (answer.ok) {
        out.done.push(id);
        const r = answer.result || {};
        for (const list of [r.archived, r.unarchived]) (list || []).forEach((x) => { out.affected.add(x); out.flipped.add(x); });
        (r.discarded || []).forEach((x) => out.affected.add(x));
        out.affected.add(id);
      } else if (answer.error?.status === 404) {
        out.gone.push(id);
      } else {
        out.skipped.push({ id, code: answer.error?.code || null, reason: refusalText(answer.error) });
      }
    }
    onProgress(i + 1, targets.length);
  }
  return out;
}

// The end toast of a batch: "Archived 3 (+2 delegates) · 1 skipped", or
// "None archived: 2 skipped" when nothing went.
// @param done the picked ids it archived (requested or covered)
// @param delegates the others the cascade took along
export function batchToastText({ done, delegates = 0, skipped = 0, archive }) {
  const verb = archive ? "Archived" : "Unarchived";
  const skippedText = `${skipped} skipped`;
  if (!done) return `None ${verb.toLowerCase()}${skipped ? `: ${skippedText}` : ""}`;
  const more = delegates ? ` (+${delegates} ${delegates === 1 ? "delegate" : "delegates"})` : "";
  return `${verb} ${done}${more}${skipped ? ` · ${skippedText}` : ""}`;
}

// The numbers batchToastText takes, from runBatch's outcome.
export function batchCounts(outcome, archive) {
  const picked = new Set([...outcome.done, ...outcome.covered]);
  const delegates = [...outcome.flipped].filter((id) => !picked.has(id)).length;
  return { done: picked.size, delegates, skipped: outcome.skipped.length, archive };
}
