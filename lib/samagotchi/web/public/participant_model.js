// The participant page's logic, pure (participant.js does the DOM): who
// wrote a message, a participant's colour slot, a tool row's line, a turn
// refusal in words, the stream's URL, and the live turn as filtered events
// build it (ParticipantView on the server decides what arrives at all).

import { fullTime, gapText } from "./format.js";

// A participant's author: "p:" and its grant id, as the server writes it
// (Steer.author_for / PARTICIPANT_PREFIX): the one place the web spells it.
export const PARTICIPANT_PREFIX = "p:";
export const participantAuthor = (id) => `${PARTICIPANT_PREFIX}${id}`;

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

// The conversation with each run of text-less tool steps (a reply that
// only called tools) folded into the next reply's rows, or one row group
// when no reply follows: one "3 tools: …" line instead of three.
// A folded run with no reply after it keeps its last step's time (at).
export function withToolSteps(messages) {
  const out = [];
  let pending = [];
  let pendingAt = null;
  const flush = () => out.push({ role: "assistant", content: "", tools: pending, ...(pendingAt ? { at: pendingAt } : {}) });
  for (const message of messages) {
    const toolOnly = message.role === "assistant" && !String(message.content || "").trim() && message.tools?.length;
    if (toolOnly) {
      pending = pending.concat(message.tools);
      pendingAt = message.at || pendingAt;
      continue;
    }
    if (pending.length) {
      if (message.role === "assistant") {
        out.push({ ...message, tools: pending.concat(message.tools || []) });
        pending = [];
        pendingAt = null;
        continue;
      }
      flush();
      pending = [];
      pendingAt = null;
    }
    out.push(message);
  }
  if (pending.length) flush();
  return out;
}

// The thread's gap dividers (format.js gapText, the owner's page's words):
// before each message, and before the turn in progress (+currentAt+, its
// turn_started's at), the divider's text or null. A gap is marked only
// where a person's message or a turn starts, measured from the last
// message's time before it: never inside a turn's work.
export function threadGaps(messages, { currentAt = null, now = Date.now() } = {}) {
  let last = null;
  const before = (messages || []).map((message) => {
    const text = message?.role === "user" && last && message.at ? gapText(last, message.at, now) : null;
    if (message?.at) last = message.at;
    return text;
  });
  return { before, current: last && currentAt ? gapText(last, currentAt, now) : null };
}

// The server's words (ParticipantMessages, a relay's detail) as the page
// shows them: a sentence, never reworded; null with none.
export function sentence(detail) {
  const text = typeof detail === "string" ? detail.trim() : "";
  if (!text) return null;
  return `${text[0].toUpperCase()}${text.slice(1)}${/[.!?…]$/.test(text) ? "" : "."}`;
}

// A comment refused (POST …/turn), in words: the server's detail, else
// the status.
export function refusalText(status, body) {
  const said = sentence(body?.detail);
  if (said) return said;
  if (status === 0) return "Not sent: can't reach the session. Send it again.";
  return `Not sent (HTTP ${status}).`;
}

// A queued comment not taken back (POST …/dequeue): the server's detail,
// else a turn that already started (the Bridge's 409, no detail), else the
// status.
export function dequeueText(status, body) {
  const said = sentence(body?.detail);
  if (said) return said;
  if (body?.error === "already_started") return "Not taken back: it already started.";
  if (status === 0) return "Not taken back: can't reach the session.";
  return `Not taken back (HTTP ${status}).`;
}

// A 401 from chi web: the link ended, revoked or expired, in the server's
// words; with none (no session in the link), where to get a new one.
export function endedText(body) {
  return sentence(body?.detail) || "Ask the session's owner for a new link.";
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

// The seq of a stream cursor `<seq>-<epoch>` (or a plain seq); null for none.
export function cursorSeq(eventId) {
  const m = /^(\d+)/.exec(String(eventId || ""));
  return m ? Number(m[1]) : null;
}

// The filtered stream's URL: from the review data's cursor, `<seq>-<epoch>`
// as the owner's page sends it (another worker answers it with a reset,
// which the page re-reads at), or (read with no worker) joining with a
// snapshot, which arrives as a bare marker the page re-reads at, never as
// a replay of old turns. The owner's participant view asks for the
// participant filter (?as=participant).
export function streamURL(sessionId, eventId, { owner = false } = {}) {
  const params = new URLSearchParams();
  if (cursorSeq(eventId) !== null) params.set("from_seq", String(eventId));
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

// The events after which the live turn drawn is no longer the running one
// (it ended, another started, the stream started over): the page draws no
// live event until its re-read, whose stream replays the ones after it.
const TURN_BOUNDARY = new Set(["turn_started", "turn_completed", "turn_canceled", "turn_failed", "snapshot", "reset"]);
export function endsLiveTurn(type) {
  return TURN_BOUNDARY.has(type);
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

// A participant's usage row (the review data's viewer.usage: the fields
// their grant's exposure shows, ParticipantExposure): one short item per
// field it has, each {key, text, title, level}; level "" / "warn" (most of
// the cap spent, the queue full) / "over" (the cap reached). Only the
// participant's own figures ever arrive; a field the level doesn't show is
// absent and draws nothing. [] with no usage (the owner's view).
export const USAGE_WARN = 0.8;
const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;
const dollars = (n) => `$${(Number(n) || 0).toFixed(2)}`;
const isNum = (n) => typeof n === "number" && Number.isFinite(n);

// "6 d left", "5 h left", "12 min left", "ended"; "" for no or bad input.
export function leftText(iso, now = Date.now()) {
  const at = Date.parse(iso || "");
  if (!Number.isFinite(at)) return "";
  const left = at - now;
  if (left <= 0) return "ended";
  if (left >= 2 * DAY_MS) return `${Math.round(left / DAY_MS)} d left`;
  if (left >= 2 * HOUR_MS) return `${Math.floor(left / HOUR_MS)} h left`;
  return `${Math.max(1, Math.floor(left / MINUTE_MS))} min left`;
}

// What the page says a participant's turn does, by the session's mode
// (viewer.mode: ParticipantMode.live on the server): a review turn only
// reads; a pair turn (a working session's) acts with the session's tools
// under the owner's guardrails. +tag+ is a message's: its own stamp
// (participant_mode), a message without one a review's.
export const MODE_COPY = {
  review: {
    note: "You can comment and ask; the model answers in a turn that can only read. The owner sees everything.",
    hint: "The model answers in a read-only turn; the owner sees everything.",
    tag: "review",
  },
  pair: {
    note: "You can ask the model to work in this session: your turns use its tools, writes included, under the owner's "
      + "guardrails, and what needs approval goes to the owner. The owner sees everything.",
    hint: "The model works in this session; the owner approves what needs it and sees everything.",
    tag: "pair",
  },
};
export const modeCopy = (mode) => MODE_COPY[mode] || MODE_COPY.review;

export function usageItems(usage, now = Date.now()) {
  if (!usage || typeof usage !== "object") return [];
  const items = [];
  if (isNum(usage.spent)) {
    const cap = isNum(usage.cap) ? usage.cap : null;
    const share = cap ? usage.spent / cap : 0;
    const level = cap === null ? "" : usage.spent >= cap ? "over" : share >= USAGE_WARN ? "warn" : "";
    items.push({ key: "spent", text: cap === null ? `${dollars(usage.spent)} spent` : `${dollars(usage.spent)} of ${dollars(cap)} cap`,
      title: cap === null ? "What your comments have cost the owner so far"
        : `What your comments have cost the owner so far, of the ${dollars(cap)} cap they set`, level });
  }
  if (isNum(usage.queued) && isNum(usage.queue_limit)) {
    items.push({ key: "queued", text: `${usage.queued}/${usage.queue_limit} queued`,
      title: `Your comments waiting for their turn: up to ${usage.queue_limit} can wait behind a running one`,
      level: usage.queued >= usage.queue_limit ? "warn" : "" });
  }
  const left = leftText(usage.expires_at, now);
  if (left) {
    const day = Date.parse(usage.expires_at) - now < DAY_MS;
    items.push({ key: "expires_at", text: left === "ended" ? "link ended" : `link: ${left}`,
      title: `Your link ends ${fullTime(usage.expires_at)}`, level: day ? "warn" : "" });
  }
  if (typeof usage.model === "string" && usage.model) {
    items.push({ key: "model", text: usage.model, title: "The model answering in this session", level: "" });
  }
  return items;
}
