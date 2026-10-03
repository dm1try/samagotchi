// When a session needs the user: a pure reducer over the hub's session
// summaries (GET /api/events). The page shows an OS notification and a
// title badge for what it returns, while the tab is not in front.

// The bell's state. OS notifications need a secure context: on chi web
// over http at a LAN address the API is missing or always denied, so the
// bell is hidden there (the title badge still counts).
// @return "on" | "off" | "denied" | "unsupported"
export function notifyState({ hasNotification, secureContext, permission, wanted }) {
  if (!hasNotification || !secureContext) return "unsupported";
  if (permission === "denied") return "denied";
  return wanted && permission === "granted" ? "on" : "off";
}

// A finished turn shorter than this was watched: no "done".
export const DONE_MIN_SECONDS = 10;

// The step-limit question (kind "continue": a turn ran out of iterations
// and asks whether to go on) has its own reason: "out of steps".
const questionReason = (q) => (q.kind === "approval" ? "approval" : q.kind === "continue" ? "continue" : "question");

// What a session waits on the user for right now, from one summary: an open
// question or approval, or a running turn's card with actions (check-in's
// Nudge / Keep going / Stop asks as a question does). The session cards
// mark and lift these; attentionFor notifies when one opens.
// @return null | {reason: "question"|"approval"|"continue"|"card", id}
export function waitingOn(summary) {
  const q = summary?.pending_question;
  if (q && q.id) return { reason: questionReason(q), id: q.id };
  const card = summary?.pending_card;
  if (card && card.id) return { reason: "card", id: card.id };
  return null;
}

// How long a delegated child's new approval waits before it notifies: its
// parent relays it when it waits on its children, and then the parent's
// card notifies instead (one bell, not two). A child the parent isn't
// waiting on directly is seen by its look at the others (DelegateRelay
// OTHERS_EVERY, 2 s), and the relay reaches the page with the hub's next
// scan (SessionHub SCAN_INTERVAL, 1 s): up to ~3 s. Only these approvals
// wait; a child's approval nobody relays rings this late.
export const RELAY_HOLD_MS = 3500;

// What changed between two summaries of one session that needs the user.
// @param prev the summary held before (null for a session not seen yet)
// @param next the new summary
// @return null | {reason: "question"|"approval"|"card"|"failed"|"done", sessionId, key}
//   key names this one event, the same in every tab (the Notification tag);
//   holdMs, when there, delays it (a delegated child's approval)
export function attentionFor(prev, next) {
  if (!next || !next.id) return null;
  const q = next.pending_question;
  if (q && q.id && q.id !== prev?.pending_question?.id) {
    // Relayed to the parent already: the parent's card notifies.
    if (q.relayed_to) return null;
    const attention = { reason: questionReason(q), sessionId: next.id, key: `${next.id}:${q.id}` };
    return next.parent_id && q.kind === "approval" ? { ...attention, holdMs: RELAY_HOLD_MS } : attention;
  }
  const card = next.pending_card;
  if (card && card.id && card.id !== prev?.pending_card?.id) {
    return { reason: "card", sessionId: next.id, key: cardKey(next.id, card.id) };
  }
  const turn = next.last_turn;
  if (!turn || !turn.ended_at || turn.ended_at === prev?.last_turn?.ended_at) return null;
  // A delegated child's turn is reported by its parent's.
  if (next.parent_id) return null;
  const key = `${next.id}:${turn.ended_at}`;
  if (turn.outcome === "failed") return { reason: "failed", sessionId: next.id, key };
  if (turn.outcome === "completed" && Number(turn.seconds) >= DONE_MIN_SECONDS) {
    return { reason: "done", sessionId: next.id, key };
  }
  return null;
}

// The tracker's state: the last summary of each session, and whether the
// first snapshot has been seen (it seeds, so old state never notifies).
export function initialAttentionState() {
  return { seeded: false, byId: {} };
}

const cardKey = (sessionId, cardId) => `${sessionId}:card:${cardId}`;

// The keys of what the session no longer has open: its question (answered
// here or in another client), its card with actions (resolved, or the turn
// ended), or both when the session is gone.
// @param prev the summary held before (null for a session not seen yet)
// @param next the new summary (null when the session is gone)
// @return [String] keys, maybe none
export function closedKeys(prev, next) {
  const keys = [];
  const q = prev?.pending_question;
  const nq = next?.pending_question;
  // Gone, or relayed to the parent (its card notifies and badges instead).
  if (q && q.id && (nq?.id !== q.id || (nq.relayed_to && !q.relayed_to))) keys.push(`${prev.id}:${q.id}`);
  const card = prev?.pending_card;
  if (card && card.id && next?.pending_card?.id !== card.id) keys.push(cardKey(prev.id, card.id));
  return keys;
}

// @param state initialAttentionState() or a previous result's state
// @param type "snapshot" | "session" | "session_gone"
// @param data the frame's data
// @return {state, attentions, closed}; state is a new object, attentions a
//   list, closed the keys of questions and cards no longer open (the badge
//   drops them)
export function trackAttention(state, type, data = {}) {
  const byId = { ...state.byId };
  const attentions = [];
  const closed = [];
  const close = (prev, next) => closed.push(...closedKeys(prev, next));
  const see = (s) => {
    if (!s || !s.id) return;
    const prev = byId[s.id] || null;
    if (state.seeded) {
      const a = attentionFor(prev, s);
      if (a) attentions.push(a);
    }
    close(prev, s);
    byId[s.id] = s;
  };
  if (type === "snapshot") {
    const sessions = Array.isArray(data.sessions) ? data.sessions : [];
    sessions.forEach(see);
    // The whole list: a session missing from it went while no frame said so
    // (the hub away, or between two fetches), as if session_gone came.
    const present = new Set(sessions.map((s) => s?.id));
    for (const id of Object.keys(byId)) {
      if (present.has(id)) continue;
      close(byId[id], null);
      delete byId[id];
    }
    return { state: { seeded: true, byId }, attentions, closed };
  }
  if (type === "session") see(data.session);
  else if (type === "session_gone") {
    close(byId[data.id] || null, null);
    delete byId[data.id];
  }
  return { state: { seeded: state.seeded, byId }, attentions, closed };
}

// The notification's words: a short title (the session) and the reason.
// No question or answer text (it would show on a lock screen).
export function attentionText(session, attention) {
  const name = String(session?.title || session?.first_preview || session?.last_prompt || "chi session").trim();
  const title = name.length > 60 ? `${name.slice(0, 60)}…` : name;
  const seconds = Math.round(Number(session?.last_turn?.seconds) || 0);
  const body = {
    question: "needs an answer",
    approval: "needs approval",
    continue: "hit its step limit",
    card: "needs you",
    failed: "turn failed",
    done: `done in ${seconds} s`
  }[attention.reason] || "";
  return { title, body };
}

// ── Several tabs ──────────────────────────────────────────────────────────
// Every chi tab gets the same hub frames. A tab in front tells the others
// (BroadcastChannel "chi-notify") which attention keys it has in front, and
// a tab behind neither notifies nor badges those: it holds a new attention
// for +holdMs+ in case the front tab's word is on its way, and drops a key
// from its badge when the word comes later. Every tab behind badges its
// title, but only one shows the OS notification: each tab behind claims
// the key on the channel as it holds it, and at the end of the hold the
// lowest claim (a tab id) shows it (4.11). Without BroadcastChannel every
// tab goes on alone, at once.
export const NOTIFY_CHANNEL = "chi-notify";
export const NOTIFY_HOLD_MS = 300;
// How long a key seen in front is remembered (its frame may come late).
const SEEN_TTL_MS = 10 * 60 * 1000;

// @param channel a BroadcastChannel (postMessage, onmessage), or null
// @param onSeen(keys) another tab has these keys in front (drop them from
//   the badge)
// @param id this tab's claim (random by default)
// @return {seenInFront(keys), offer(attention, deliver), drop(keys)}
export function createNotifyGate({ channel = null, holdMs = NOTIFY_HOLD_MS, onSeen = () => {},
  schedule = setTimeout, cancel = clearTimeout, now = Date.now, id = randomTabId() } = {}) {
  const seen = new Map(); // key → when
  const pending = new Map(); // key → timer
  const claims = new Map(); // key → {ids: the other tabs' claims, at}
  const mark = (keys) => {
    const at = now();
    for (const [key, when] of seen) if (at - when > SEEN_TTL_MS) seen.delete(key);
    for (const key of keys) seen.set(key, at);
  };
  const claimed = (key, tab) => {
    const at = now();
    for (const [k, claim] of claims) if (at - claim.at > SEEN_TTL_MS) claims.delete(k);
    const claim = claims.get(key) || { ids: new Set(), at };
    claim.ids.add(tab);
    claims.set(key, claim);
  };
  // This tab's claim is the lowest: it shows the OS notification.
  const won = (key) => {
    const others = claims.get(key)?.ids || new Set();
    claims.delete(key);
    return [...others].every((other) => id < other);
  };
  const drop = (keys) => {
    for (const key of keys) {
      if (!pending.has(key)) continue;
      cancel(pending.get(key));
      pending.delete(key);
    }
  };
  if (channel) {
    channel.onmessage = (e) => {
      if (e?.data?.type === "claim" && typeof e.data.key === "string" && typeof e.data.id === "string") {
        claimed(e.data.key, e.data.id);
        return;
      }
      const keys = e?.data?.type === "seen" && Array.isArray(e.data.keys) ? e.data.keys.map(String) : [];
      if (keys.length === 0) return;
      mark(keys);
      drop(keys);
      onSeen(keys);
    };
  }
  return {
    // This tab is in front with +keys+.
    seenInFront(keys) {
      if (!channel || keys.length === 0) return;
      try { channel.postMessage({ type: "seen", keys }); } catch (_) {}
    },
    // A new attention in a tab behind: +deliver(notify)+ (badge; the OS
    // notification when +notify+) unless another tab has it in front.
    // @return whether it may still be delivered
    // An attention's own holdMs (a delegated child's approval) holds it
    // longer, alone too.
    offer(attention, deliver) {
      const key = attention.key;
      if (seen.has(key)) return false;
      if (!channel && !attention.holdMs) {
        deliver(true);
        return true;
      }
      drop([key]);
      if (channel) {
        try { channel.postMessage({ type: "claim", key, id }); } catch (_) {}
      }
      pending.set(key, schedule(() => {
        pending.delete(key);
        if (!seen.has(key)) deliver(won(key));
      }, Math.max(holdMs, attention.holdMs || 0)));
      return true;
    },
    // Closed before its hold was up (a question answered at once).
    drop,
  };
}

function randomTabId() {
  try {
    if (typeof globalThis.crypto?.randomUUID === "function") return globalThis.crypto.randomUUID();
  } catch (_) {}
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}
