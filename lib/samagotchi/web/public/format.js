import { waitingOn } from "./notify.js";

export const PREVIEW_CHARS = 40;
const FIRST_PREVIEW_CHARS = 80;

export function escapeHtml(value) {
  return String(value).replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]),
  );
}

// Who a steer names as its sender: a plugin's own label, chi's sender ids
// in words (the TUI's Formatting#steer_sender agrees;
// spec/shared/labels_matrix.json). "": no one named.
const STEER_SENDERS = { parent_agent: "parent agent", chi_send: "chi send", plugin_send: "plugin", delegate_report: "delegate report" };
export function steerSender(source) {
  const id = String(source ?? "");
  return STEER_SENDERS[id] || id;
}

// The label a user-role line gets on reload for who sent it, by its saved
// source: a delegate report (the live bubble's clientLabel of child:<id>);
// null for the user's own (and anything else, as before).
export function sourceLabel(source) {
  return source === "delegate_report" ? steerSender(source) : null;
}

// The piece to append to a streamed body that holds +sofar+: while the body
// is empty its leading whitespace is dropped (a model's thinking starts with
// the "\n" after <think>, which would render as an empty first line).
export function leadTrimmed(sofar, piece) {
  return sofar === "" ? String(piece || "").replace(/^[ \t\r\n]+/, "") : String(piece || "");
}

export function normalize(s) {
  return String(s || "").replace(/\s+/g, " ").trim();
}

// +text+ in at most +n+ characters: whole when it fits, else cut with "…"
// as its last (the kept part's trailing spaces dropped).
export function clip(text, n) {
  const s = String(text ?? "");
  return s.length > n ? `${s.slice(0, n - 1).trimEnd()}\u2026` : s;
}

export function previewOf(lastPrompt) {
  const normalized = normalize(lastPrompt);
  if (!normalized) return "\u2014";
  return clip(normalized, PREVIEW_CHARS + 1);
}

// A session's first message as the info bar's title: whitespace collapsed,
// cut at FIRST_PREVIEW_CHARS with an ellipsis ("" for none).
export function firstPreview(text) {
  const n = normalize(text);
  return clip(n, FIRST_PREVIEW_CHARS + 1);
}

export function previewForCard(session) {
  // Unified card preview: first message (80) else previewOf(last_prompt)
  const raw = session.first_preview || session.last_prompt || "";
  return firstPreview(raw) || "\u2014";
}

const DELETE_PREVIEW_CHARS = 40;

// The confirm before deleting a session (the info bar's and a card's). The
// list's owner can be stale (a worker idle-exits), so a worker is only
// "stopped if it's still running", never promised.
export function deleteConfirmText(session) {
  const n = normalize(session.first_preview || session.last_prompt || "");
  const preview = clip(n, DELETE_PREVIEW_CHARS + 1);
  const shortId = session.short_id || String(session.id).slice(0, 8);
  const lines = [
    `Delete session ${shortId}${preview ? ` \u2014 "${preview}"` : ""}?`,
    "Its history, notes and images are removed; this can't be undone.",
  ];
  if (session.owner === "worker") lines.push("If its worker is still running, it is stopped first.");
  return lines.join("\n");
}

// The badge on a session a process holds right now (the list's `owner`):
// a worker (shared: every UI can send), or a plain terminal chi (not shared).
export function ownerBadge(owner, id) {
  if (owner === "worker") {
    return { kind: "worker", text: "live", title: `A worker runs this session; a terminal joins with: chi --attach ${id}` };
  }
  if (owner === "tui") {
    return { kind: "tui", text: "terminal", title: "A terminal chi owns this session and doesn't share it (chi --shared would)" };
  }
  return null;
}

// The chip on a delegated session (parent_id set): its parent's short id,
// with the parent's preview in the tooltip when the parent is known.
// @param parentId the session's parent_id
// @param parent the parent's summary from the list, if listed
export function delegatedBy(parentId, parent = null) {
  if (!parentId) return null;
  const short = String(parentId).slice(0, 8);
  const what = parent ? previewForCard(parent) : "";
  return { text: `\u21B3 ${short}`, title: `delegated by session ${short}${what ? `: ${what}` : ""}` };
}

// A child's state for the parent's children chip, decided in
// ChildrenStatus's order: waiting on the user (a question, an approval, a
// card), running, stopped, failed, done (the last turn completed), idle.
// The hub has no reply files, so "done" doesn't say whether the parent was
// given the reply ("not reported" is the TUI's and /children's).
const CHILD_STATES = ["running", "waiting", "done", "failed", "stopped", "idle"];
function childState(s) {
  if (waitingOn(s)) return "waiting";
  if (s.status === "running") return "running";
  if (s.status === "stopped") return "stopped";
  const outcome = s.last_turn?.outcome;
  if (s.status === "error" || outcome === "failed") return "failed";
  if (outcome === "completed") return "done";
  return "idle";
}

// Delegates by state: the one counter behind the parent's `⑂ N` chip (the
// info bar) and its card's family chip. live: how many a worker runs now
// (owner "worker", the cards' green badge), whatever their state.
// @param kids the delegates' summaries
// @return null for none, else {total, counts, live, text, waitingText,
//   title}; waitingText ("2 waiting") is for the attention colour, null when
//   none waits
export function delegatesSummary(kids) {
  const list = (kids || []).filter(Boolean);
  if (!list.length) return null;
  const counts = Object.fromEntries(CHILD_STATES.map((k) => [k, 0]));
  list.forEach((s) => { counts[childState(s)] += 1; });
  const parts = CHILD_STATES.filter((k) => counts[k]).map((k) => `${counts[k]} ${k}`);
  const total = list.length;
  return {
    total,
    counts,
    live: list.filter((s) => s.owner === "worker").length,
    text: `\u2442 ${total}`,
    waitingText: counts.waiting ? `${counts.waiting} waiting` : null,
    title: `${total} ${total === 1 ? "delegate" : "delegates"}: ${parts.join(" \u00b7 ")}`,
  };
}

// The parent's `⑂ N` chip (the info bar): its delegates in the list, by
// state (delegatesSummary). Forks (delegate false) and archived children are
// left out, as in the TUI's segment (ChildrenStatus.counts).
// @param parent the parent's summary
// @param sessions the page's list (allSessions: archived ones too)
export function childrenSummary(parent, sessions) {
  if (!parent?.id) return null;
  return delegatesSummary((sessions || []).filter((s) => s && s.parent_id === parent.id && s.delegate && !s.archived && s.id !== parent.id));
}

// Whether the info bar offers "stop": only while a worker runs the session
// (the list says so, or this page streams from one a send just woke). A
// stopped or idle-exited session has nothing to stop, and a chi REPL's is
// refused by the server.
export function canStopSession({ owner, streaming }) {
  if (owner === "tui") return false;
  return owner === "worker" || !!streaming;
}

// The start page's line after the open session went away under the page
// (an unknown #/s/<id>, a delete in another tab). Plain text.
export function goneSessionNotice(id, why) {
  return `Session ${String(id).slice(0, 8)} was ${why === "deleted" ? "deleted" : "not found"}.`;
}

// A session in the list after its live status changed (a turn started or
// ended): that is activity now, so its card's "N min ago" says so too, and
// the change came from a worker's stream, so the card says "live".
export function withLiveStatus(sess, status, now = Date.now()) {
  const owner = sess.owner === "tui" ? "tui" : "worker";
  return { ...sess, status, owner, updated_at: new Date(now).toISOString() };
}

// A session in the list after the page saw its worker go (the stream
// closed: killed, idle exit, stopped): no longer "live", and no turn runs.
// A terminal chi's session is left as is.
export function withoutWorker(sess) {
  if (sess.owner !== "worker") return sess;
  return { ...sess, owner: null, status: sess.status === "running" ? "idle" : sess.status };
}

// Where a saved recap goes in the history: before the first turn it doesn't
// cover, the +turnsSince+-th user bubble from the end; null (at the end) when
// it covers everything or the page shows fewer turns than that.
export function recapPlace(userBubbles, turnsSince) {
  const n = Number(turnsSince) || 0;
  if (n <= 0 || n > userBubbles.length) return null;
  return userBubbles[userBubbles.length - n];
}

// The line a failed turn's bubble shows: a provider error's one-line
// summary, else the error's message and class. A turn whose work stayed
// (turn_failed's kept_steps; no prompt_restored follows) says so, as the
// terminal's rollback hint does.
export function failedTurnText(data) {
  data = data || {};
  const detail = data.summary || `${data.message || "error"}${data.error_class ? ` (${data.error_class})` : ""}`;
  const kept = Number.isInteger(data.kept_steps) ? "; partial progress kept (!rollback restores the pre-turn state)" : "";
  return `\u2715 turn failed: ${detail}${kept}`;
}

// Whether the server served another model than asked: names equal in any
// case, or one extending the other (":free" dropped, a date added), are the
// same model (ServedModel.differs? in Ruby).
export function servedModelDiffers(asked, served) {
  const a = String(asked || "").trim().toLowerCase();
  const s = String(served || "").trim().toLowerCase();
  if (!a || !s) return false;
  return !(a.startsWith(s) || s.startsWith(a));
}

// The session's model for the info bar: the served model with a marker when
// the server serves another one than +servedFor+ (the name asked), unless
// +expectedBy+ names the host whose hosts.<name>.models served: lists it.
export function modelLabel(model, served, servedFor, expectedBy = null) {
  if (expectedBy && servedModelDiffers(servedFor, served)) {
    const name = model || "";
    return { text: name.slice(0, 40), title: `${name}; served: ${served} (expected: hosts.${expectedBy}.models)`, mismatch: false };
  }
  if (servedModelDiffers(servedFor, served)) {
    return { text: `${served.slice(0, 40)} ⚠`, title: `served: ${served}; asked for ${model}`, mismatch: true };
  }
  const name = model || "";
  return { text: name.slice(0, 40), title: name, mismatch: false };
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// A card's "2 h ago": coarse on purpose, recomputed on each render (no
// ticking). A week or more back it is a short date; "" for no or bad input.
export function relativeTime(iso, now = Date.now()) {
  const t = iso ? Date.parse(iso) : NaN;
  if (Number.isNaN(t)) return "";
  const secs = Math.max(0, (now - t) / 1000);
  if (secs < 60) return "just now";
  if (secs < 3600) return `${Math.floor(secs / 60)} min ago`;
  if (secs < 86400) return `${Math.floor(secs / 3600)} h ago`;
  if (secs < 2 * 86400) return "yesterday";
  if (secs < 7 * 86400) return `${Math.floor(secs / 86400)} d ago`;
  const d = new Date(t);
  const date = `${d.getDate()} ${MONTHS[d.getMonth()]}`;
  return d.getFullYear() === new Date(now).getFullYear() ? date : `${date} ${d.getFullYear()}`;
}

// The recap bubble's label: how many turns came after it (stale: a turn
// started while the page showed it, count unknown).
export function recapLabel(turnsSince, stale = false) {
  const n = Number(turnsSince) || 0;
  if (n === 1) return "recap · before the last turn";
  if (n > 1) return `recap · before the last ${n} turns`;
  return stale ? "recap · earlier" : "recap";
}

// The info bar's memory chip on a phone (where the "mem: …" line goes),
// for a session that used memories: "mem 2", the names its tooltip.
export function memChipText(names) {
  return `mem ${(names || []).length}`;
}

export function memChipTitle(names) {
  const list = names || [];
  return list.length ? `memories: ${list.join(", ")}` : "no memories in this session";
}

// "model_notes_deepseek (system, 612 chars), model_notes_x (project, 80
// chars)": the model notes the session's prompt carried (its prompt_notes);
// "" without any. As PromptNote.text (spec/shared/labels_matrix.json).
export function promptNotesText(notes) {
  return (Array.isArray(notes) ? notes : [])
    .filter((note) => note && typeof note.name === "string" && note.name.trim())
    .map((note) => {
      const details = [note.scope, Number.isFinite(note.chars) ? `${Math.trunc(note.chars)} chars` : null].filter(Boolean);
      return details.length ? `${note.name.trim()} (${details.join(", ")})` : note.name.trim();
    })
    .join(", ");
}

// The info bar's model notes chip, for a session whose prompt carried
// some: "notes: deepseek" (the names without model_notes_), the full line
// its tooltip; null without notes.
export function promptNotesChip(notes) {
  const text = promptNotesText(notes);
  if (!text) return null;
  const names = notes.filter((note) => note && typeof note.name === "string" && note.name.trim())
    .map((note) => note.name.trim().replace(/^model_notes_/, ""));
  return { text: `notes: ${names.join(", ")}`, title: `model notes in this session's prompt: ${text}` };
}
