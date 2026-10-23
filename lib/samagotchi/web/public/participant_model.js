// The participant page's logic, pure (participant.js does the DOM): who
// wrote a message, a participant's colour slot, a tool row's line, a turn
// refusal in words, the stream's URL, and the live turn as filtered events
// build it (ParticipantView on the server decides what arrives at all).

// Six author colours (tokens.css --author-1..6), one per participant id,
// the same on every page that shows them (the owner's badges too).
export const AUTHOR_SLOTS = 6;
export function authorSlot(author) {
  const id = String(author || "");
  let hash = 0;
  for (let i = 0; i < id.length; i++) hash = (hash * 31 + id.charCodeAt(i)) >>> 0;
  return (hash % AUTHOR_SLOTS) + 1;
}

// The CSS colour of an author: a participant's slot, else the owner's.
export function authorColor(author) {
  return author ? `var(--author-${authorSlot(author)})` : "var(--author-owner)";
}

// Who wrote a user message or started a turn, as the page names them.
export function authorLabel(item) {
  if (item?.mine) return "You";
  if (item?.author) return item.author_name || "A participant";
  if (item?.automatic) return "Automatic";
  return "Owner";
}

// "read docs/plan.md", or the tool's name alone.
export function toolLine(row) {
  return row?.path ? `${row.tool} ${row.path}` : String(row?.tool || "tool");
}

// A tool rows' summary: "read docs/plan.md", "read docs/plan.md + 2 more".
export function toolsSummary(rows) {
  const list = Array.isArray(rows) ? rows : [];
  if (list.length === 0) return "";
  const first = toolLine(list[0]);
  return list.length === 1 ? first : `${first} + ${list.length - 1} more`;
}

// The conversation with each run of text-less tool steps (a reply that
// only called tools) folded into the next reply's rows, or one row group
// when no reply follows: one "3 tools: …" line instead of three.
export function withToolSteps(messages) {
  const out = [];
  let pending = [];
  for (const message of messages) {
    const toolOnly = message.role === "assistant" && !String(message.content || "").trim() && message.tools?.length;
    if (toolOnly) {
      pending = pending.concat(message.tools);
      continue;
    }
    if (pending.length) {
      if (message.role === "assistant") {
        out.push({ ...message, tools: pending.concat(message.tools || []) });
        pending = [];
        continue;
      }
      out.push({ role: "assistant", content: "", tools: pending });
      pending = [];
    }
    out.push(message);
  }
  if (pending.length) out.push({ role: "assistant", content: "", tools: pending });
  return out;
}

// A turn refused (POST …/turn) or a dequeue, in words: the server's own
// words when it sent them, else these by code.
const REFUSALS = {
  not_permitted: "You can't send that: comments are text, and a line can't start with “!” or “/” (those are the owner's).",
  too_many_turns: "You have too many comments waiting: wait for one to finish.",
  cap_reached: "Your spending cap for this review is reached: ask the session's owner to raise it.",
  review_unavailable: "The session can't take review comments right now: ask its owner to restart it.",
  worker_timeout: "The session didn't answer in time: send again.",
  owned_by_tui: "The session is open in the owner's terminal REPL: comments can't reach it now.",
};
export function refusalText(status, body) {
  const code = body?.error;
  if (code === "not_permitted") return REFUSALS.not_permitted;
  if (typeof body?.detail === "string" && body.detail.trim()) return body.detail;
  if (code && REFUSALS[code]) return REFUSALS[code];
  if (status === 0) return "Not sent: can't reach the session. Send it again.";
  return `Not sent (HTTP ${status}).`;
}

// Whether a review read that failed is read again: chi web unreachable
// (status 0) or a 5xx (a worker starting, a proxy); a 404 (gone) or
// another 4xx is final, a 401 the ended page.
export function retries(status) {
  return status === 0 || status >= 500;
}

// The wait before the next read of the review after +failures+ failed in
// a row: 3 s, doubling, at most 30 s.
export function retryDelay(failures) {
  return Math.min(3000 * 2 ** Math.max(0, failures), 30000);
}

// A 401 from chi web: the link ended (revoked, expired) or was never good.
export function endedText(body) {
  if (body?.error === "token_revoked") return "This review link was revoked by the session's owner.";
  if (body?.error === "token_expired") return "This review link expired: ask the session's owner for a new one.";
  return "This review link has expired or was revoked. Ask the session's owner for a new one.";
}

// The seq of a stream cursor `<seq>-<epoch>` (or a plain seq); null for none.
export function cursorSeq(eventId) {
  const m = /^(\d+)/.exec(String(eventId || ""));
  return m ? Number(m[1]) : null;
}

// The filtered stream's URL: from the review data's cursor, or (read with
// no worker) joining with a snapshot, which arrives as a bare marker the
// page re-reads at, never as a replay of old turns. The owner's
// participant view asks for the participant filter (?as=participant).
export function streamURL(sessionId, eventId, { owner = false } = {}) {
  const params = new URLSearchParams();
  const seq = cursorSeq(eventId);
  if (seq !== null) params.set("from_seq", String(seq));
  else params.set("snapshot", "1");
  if (owner) params.set("as", "participant");
  const query = params.toString();
  return `/api/sessions/${encodeURIComponent(sessionId)}/stream${query ? `?${query}` : ""}`;
}

// The events after which the page reads its review data again: a turn's
// start or end, the queue, the owner's question, a snapshot or reset.
const RELOAD = new Set(["turn_started", "turn_completed", "turn_canceled", "turn_failed", "turn_enqueued", "turn_dequeued",
  "input_merged", "question_requested", "question_answered", "question_cancelled", "continue_offered",
  "continue_resolved", "snapshot", "reset"]);
export function reloads(type) {
  return RELOAD.has(type);
}

// The live turn between reloads: its text by step (a restarted step's
// text is void) and its tool rows. Returns the new live state.
export function liveFrom(current) {
  return {
    texts: current?.text ? { 0: current.text } : {},
    tools: Array.isArray(current?.tools) ? current.tools.map((row) => ({ ...row })) : [],
  };
}

export function applyLive(live, event) {
  const next = { texts: { ...live.texts }, tools: live.tools.slice() };
  const step = Number.isInteger(event?.iteration) ? event.iteration : 0;
  switch (event?.type) {
    case "generation_chunk":
      next.texts[step] = (next.texts[step] || "") + String(event.text || "");
      break;
    case "generation_retrying":
      if (event.restarted) delete next.texts[step];
      break;
    case "tool_call_started":
      next.tools.push({ tool: event.tool, ...(event.path ? { path: event.path } : {}), status: "running",
        iteration: event.iteration, call_index: event.call_index });
      break;
    case "tool_call_completed": {
      const at = next.tools.findLastIndex((row) => row.iteration === event.iteration && row.call_index === event.call_index);
      if (at >= 0) next.tools[at] = { ...next.tools[at], status: event.status || "ok" };
      break;
    }
    default:
      return live;
  }
  return next;
}

// The live turn's reply text so far, its steps in order.
export function liveText(live) {
  return Object.keys(live.texts).map(Number).sort((a, b) => a - b).map((k) => live.texts[k]).join("");
}

// The Plan view's subject: the one picked by path when it is still there,
// else the first; null with no subjects (not a review session).
export function pickSubject(subjects, path) {
  const list = Array.isArray(subjects) ? subjects : [];
  return list.find((s) => s.path === path) || list[0] || null;
}

// What the Plan view shows for a subject: rendered markdown, plain text,
// or why it can't (gone, or no longer a project file a participant may
// read); +note+ when the text is cut.
export function subjectBody(subject) {
  if (!subject) return { kind: "none" };
  if (subject.missing) return { kind: "missing", text: `${subject.path} can't be shown: it is gone, or no longer a project file you may read.` };
  const note = subject.truncated ? "Only the start of this file is shown: it is long." : null;
  return subject.html ? { kind: "html", html: subject.html, note } : { kind: "text", text: subject.text || "", note };
}

// Whether the subjects differ from what the Plan view drew (a re-read at
// a turn boundary redraws it only then, keeping its scroll).
export function subjectsKey(subjects) {
  return JSON.stringify((subjects || []).map((s) => [s.path, s.missing ? null : s.text, !!s.truncated]));
}

// Which view a narrow screen shows: "thread" by default, "plan" only when
// there is a subject to show.
export function narrowView(wanted, subjects) {
  return wanted === "plan" && (subjects || []).length ? "plan" : "thread";
}
