// When a session needs the user: a pure reducer over the hub's session
// summaries (GET /api/events). The page shows an OS notification and a
// title badge for what it returns, while the tab is not in front.

// A finished turn shorter than this was watched: no "done".
export const DONE_MIN_SECONDS = 10;

// What changed between two summaries of one session that needs the user.
// @param prev the summary held before (null for a session not seen yet)
// @param next the new summary
// @return null | {reason: "question"|"approval"|"failed"|"done", sessionId, key}
//   key names this one event, the same in every tab (the Notification tag)
export function attentionFor(prev, next) {
  if (!next || !next.id) return null;
  const q = next.pending_question;
  if (q && q.id && q.id !== prev?.pending_question?.id) {
    return { reason: q.kind === "approval" ? "approval" : "question", sessionId: next.id, key: `${next.id}:${q.id}` };
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

// @param state initialAttentionState() or a previous result's state
// @param type "snapshot" | "session" | "session_gone"
// @param data the frame's data
// @return {state, attentions}; state is a new object, attentions a list
export function trackAttention(state, type, data = {}) {
  const byId = { ...state.byId };
  const attentions = [];
  const see = (s) => {
    if (!s || !s.id) return;
    if (state.seeded) {
      const a = attentionFor(byId[s.id] || null, s);
      if (a) attentions.push(a);
    }
    byId[s.id] = s;
  };
  if (type === "snapshot") {
    (Array.isArray(data.sessions) ? data.sessions : []).forEach(see);
    return { state: { seeded: true, byId }, attentions };
  }
  if (type === "session") see(data.session);
  else if (type === "session_gone") delete byId[data.id];
  return { state: { seeded: state.seeded, byId }, attentions };
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
    failed: "turn failed",
    done: `done in ${seconds} s`
  }[attention.reason] || "";
  return { title, body };
}
