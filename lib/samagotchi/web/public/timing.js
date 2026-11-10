import { isShellCommandItem } from "./shell_command.js";
import { drawingTurn, drawnKind } from "./turn_drawing.js";

export function formatDuration(milliseconds) {
  const ms = Number(milliseconds);
  if (!Number.isFinite(ms) || ms < 0) return "";

  if (ms < 500) return `${Math.round(ms)}ms`;

  const seconds = ms / 1000;
  if (seconds < 60) return `${seconds < 10 ? seconds.toFixed(1) : Math.round(seconds)}s`;

  const totalSeconds = Math.round(seconds);
  const minutes = Math.floor(totalSeconds / 60);
  return `${minutes}m ${String(totalSeconds % 60).padStart(2, "0")}s`;
}

// A turn's timing line: "turn 3 · 4.1s", or "turn 3 running · 1.0s" while
// it runs. The number is the turn's place in the session's turn records,
// the one a reloaded history shows.
export function turnTimingText(number, durationMs, { running = false, canceled = false } = {}) {
  const turn = Number.isInteger(number) && number > 0 ? `turn ${number}` : "turn";
  return `${turn}${running ? " running" : ""} · ${formatDuration(durationMs)}${canceled ? " · canceled" : ""}`;
}

// The LIVE line's duration: never milliseconds — under a second it shows
// tenths ("0.0s", "0.2s"), then what formatDuration prints from 1 s on
// (its 0.1 s precision holds to 10 s). A finished turn's line keeps
// formatDuration exactly as it is.
export function liveDurationText(durationMs) {
  const ms = Number(durationMs);
  if (!Number.isFinite(ms) || ms < 0) return "";
  if (ms < 1000) return `${(ms / 1000).toFixed(1)}s`;
  return formatDuration(ms);
}

// A cancel's reason as the terminal UIs name it too (Formatting::
// CANCEL_REASONS); anything else as it is. Both sides: spec/shared/labels_matrix.json.
const CANCEL_REASONS = { ctrl_c: "Ctrl-C", user: "stopped", hook: "by a hook", worker_stopped: "worker stopped",
  session_stopped: "session stopped" };

// The line a canceled turn ends with: "■ canceled (stopped)", live from
// turn_canceled's reason and after a re-render from the turn record's
// cancellation_reason (records saved before it existed: no reason). A
// hook's stop that names who (+by+, cancelled_by): "■ stopped by loop-guard".
// Every cancel is a stop someone chose (the user, Ctrl-C, a hook), not a
// failure: the ■ mark and the stopped colours of a call the Stop cut
// (STOPPED_LINE_CLASS), not the ✕ of an error.
export const STOP_MARK = "\u25A0";
export const STOPPED_LINE_CLASS = "bubble cancel stopped";
export function cancelLineText(reason, by) {
  if (reason === "hook" && by) return `${STOP_MARK} stopped by ${by}`;
  return `${STOP_MARK} canceled` + (reason ? ` (${CANCEL_REASONS[reason] || reason})` : "");
}

export function elapsedSince(startedAt, now = Date.now()) {
  const started = Date.parse(startedAt);
  const current = Number(now);
  if (!Number.isFinite(started) || !Number.isFinite(current)) return null;
  return Math.max(0, current - started);
}

// The info bar's session clock: while a turn runs it counts from the
// session's start (+timing.startedAt+), or, on a session's first turn (its
// snapshot came before any turn, so no start), from the running turn's;
// otherwise the server's session_duration_ms (null when unknown).
export function sessionDurationNow(timing, running, now = Date.now()) {
  if (running) {
    const since = elapsedSince(timing?.startedAt ?? timing?.activeTurn?.started_at, now);
    if (since !== null) return since;
  }
  return timing?.sessionDurationMs ?? null;
}

export function normalizeTiming(data = {}) {
  return {
    startedAt: typeof data.started_at === "string" ? data.started_at : null,
    sessionDurationMs: finiteOrNull(data.session_duration_ms),
    turnRecords: Array.isArray(data.turn_records) ? data.turn_records.filter(validRecord) : [],
    toolRecords: Array.isArray(data.tool_records) ? data.tool_records.filter(validRecord) : [],
    activeTurn: validRecord(data.active_turn) ? data.active_turn : null,
    // The session's token sums and speeds (SessionMetrics' tokens block).
    tokens: validRecord(data.tokens) ? data.tokens : null,
    // The memory indexes the session's prompt holds (SessionMetrics'
    // memory_index), for the ctx tooltip.
    memoryIndex: validRecord(data.memory_index) ? data.memory_index : null,
    // The session's tokens, cost and speeds per model after a /model
    // (SessionMetrics' model_segments; [] with one model), for the ctx
    // tooltip.
    modelSegments: Array.isArray(data.model_segments) ? data.model_segments.filter(validRecord) : [],
    // The session's side requests (SessionMetrics' side block: recap,
    // /btw, ctx.ask_model, apart from tokens), for the ctx tooltip; null
    // without any.
    side: validRecord(data.side) ? data.side : null,
  };
}

// A turn-end re-read's timing (+data+, the server's ?tail=1&recent=1: the
// newest turn's records and turn_count) merged into the page's (+timing+,
// normalizeTiming's shape). Records by id: a known one is replaced in
// place; an unknown turn goes in started_at order (ties and unparsable
// dates keep arrival order), an unknown tool record at the end (they come
// grouped by turn, in call order). startedAt, sessionDurationMs and
// activeTurn are the reply's, and so are its tokens (a reply without them
// keeps the page's) and its model_segments (present: authoritative). `short`: the reply's turn_count says the page
// misses a turn (it then reads the whole timing). A reply without
// turn_count (an older server: the whole timing) replaces, as before; more
// records than the count (a worker died before saving a turn the page saw)
// are kept.
// @return {{timing: object, short: boolean}}
export function mergeTiming(timing, data = {}) {
  const fresh = normalizeTiming(data || {});
  const count = data?.turn_count;
  if (typeof count !== "number" || !Number.isFinite(count)) return { timing: fresh, short: false };
  const turnRecords = (timing?.turnRecords || []).slice();
  fresh.turnRecords.forEach((record) => {
    if (replaceById(turnRecords, record)) return;
    const started = Date.parse(record.started_at);
    const at = Number.isFinite(started)
      ? turnRecords.findIndex((r) => Date.parse(r?.started_at) > started)
      : -1;
    if (at < 0) turnRecords.push(record);
    else turnRecords.splice(at, 0, record);
  });
  const toolRecords = (timing?.toolRecords || []).slice();
  fresh.toolRecords.forEach((record) => {
    if (!replaceById(toolRecords, record)) toolRecords.push(record);
  });
  const tokens = fresh.tokens || timing?.tokens || null;
  const memoryIndex = fresh.memoryIndex || timing?.memoryIndex || null;
  const side = fresh.side || timing?.side || null;
  // A reply that has the rows is the answer, an empty list too (one model
  // now): a stale list never survives it; one without them (an older
  // server) keeps the page's.
  const modelSegments = data && "model_segments" in data ? fresh.modelSegments : (timing?.modelSegments || []);
  return { timing: { ...fresh, turnRecords, toolRecords, tokens, memoryIndex, modelSegments, side },
           short: turnRecords.length < count };
}

function replaceById(records, record) {
  if (record?.id == null) return false;
  const at = records.findIndex((r) => r?.id === record.id);
  if (at < 0) return false;
  records[at] = record;
  return true;
}

// A history item that starts a turn: a prompt, or the note a context wake
// turn starts with (turn_start). A `!cmd`'s record (shell_command.js) is a
// user message but no prompt: no turn, no record, no timing.
const startsTurn = (item) =>
  (item?.role === "user" && !isShellCommandItem(item)) || (item?.role === "note" && item.turn_start === true);

// The history as turns, for a reload: chi web draws every finished turn
// (turn_drawings, {turn_id: {events, end}}), and the items stamped with a
// drawn turn's id (`drawn`) are that turn's group (`drawn`, its `drawing`),
// whether or not they start with an opening (a reminder turn has none; a
// wake's note, outside the range, opens it by its id); its steps are the
// drawing's (turn_drawing.js), and an unstamped item after it starts no
// part of it. A loose context note is a group of its own (`note`), a
// `!cmd`'s record too (`command`: no steps, no record, no turn index).
// Any other unstamped item is a `plain` group (its index): a row of its
// text, no steps. The running turn's (its opening's turn id
// +runningTurnId+, and what follows it: no line until its end) are
// `running`; any other is a miss (turn_block.js draws and logs it).
// The turn index counts the drawn turns.
export function turnGroups(items, timing, { drawings = null, runningTurnId = null } = {}) {
  const groups = [];
  let turnIndex = -1;
  let turn = null;
  let running = false;
  items.forEach((item, i) => {
    const drawn = drawings && typeof item?.drawn === "string" && drawings[item.drawn] ? item.drawn : null;
    if (item?.role === "note" && !startsTurn(item)) { groups.push({ kind: "note", i }); return; }
    if (!drawn) {
      turn = null;
      if (isShellCommandItem(item)) { groups.push({ kind: "command", i }); return; }
      if (startsTurn(item) && !item.merged) running = runningTurnId != null && item.turn_id === runningTurnId;
      groups.push(running ? { kind: "plain", i, running: true } : { kind: "plain", i });
      return;
    }
    running = false;
    if (turn?.drawn !== drawn) {
      // An opening just before the range with the drawn turn's id (a wake's
      // note, added before the turn began, loose notes after it): the drawn
      // turn's own.
      const back = groups.findLastIndex((g) => g.kind !== "note");
      const wake = back >= 0 && groups[back].kind === "plain" && items[groups[back].i]?.role === "note"
        && items[groups[back].i].turn_id === drawn ? groups[back].i : null;
      turnIndex += 1;
      turn = { kind: "turn", turnIndex, turnId: drawn, drawn, user: wake ?? (startsTurn(item) ? i : null), texts: [], steers: [], merged: [] };
      if (wake != null) groups.splice(back, 1, turn);
      else groups.push(turn);
      if (wake == null && startsTurn(item)) return;
    }
    if (startsTurn(item) && !item.merged && item.role === "user") {
      // A second opening line of the drawn turn (a wake turn's report after
      // its note): one of its lines, as live drew it.
      turn.merged.push(i);
    } else if (item.role === "steer") {
      turn.steers.push(i);
    } else if (item.role === "user" && item.merged) {
      turn.merged.push(i);
    } else if (item.role === "assistant") {
      turn.texts.push(i);
    } else if (item.role === "empty_answer") {
      turn.emptyAnswer = i;
    }
  });
  return groups.map((g) => (g.kind === "turn" ? drawnGroup(g, items, timing, drawings[g.drawn]) : g));
}

// A drawn turn's group: its record by the id its end names (`record_id`: a
// drawing chi web made from the messages pairs one as Bridge::TurnRanges.records
// does, by place for a turn saved before turn ids), else by its own id, its
// steps the drawing's gens (the rows the working set and the footprint
// read, as live), its answer the last text of a completed turn that had
// one, and its items (the opening, merged lines, the empty answer) by index.
function drawnGroup(g, items, timing, drawing) {
  const recordId = drawing?.end?.record_id ?? g.drawn;
  const record = (timing?.turnRecords || []).find((r) => r.id === recordId) || null;
  const steps = drawingTurn(drawing).gens.map((gen, k) => ({ i: null, iteration: k + 1, thinking: gen.thinking, tools: gen.tools }));
  const last = g.texts[g.texts.length - 1];
  const answered = drawnKind(drawing.end) === "completed" && g.emptyAnswer == null && last != null && String(items[last]?.content ?? "") !== "";
  const group = { kind: "turn", turnIndex: g.turnIndex, user: g.user, turnId: g.drawn, drawn: g.drawn, drawing, record, steps,
    texts: g.texts, answer: answered ? last : null, steers: [] };
  if (g.emptyAnswer != null) group.emptyAnswer = g.emptyAnswer;
  if (g.merged.length) group.merged = g.merged;
  return group;
}

// Append +el+ to the history, above +timingEl+ while it is a running turn's
// live timing line, so that line stays under the turn's activity, thinking
// and answer.
export function appendAboveLiveTiming(parent, el, timingEl) {
  if (timingEl && timingEl.parentNode === parent && timingEl.classList.contains("live")) {
    parent.insertBefore(el, timingEl);
  } else {
    parent.appendChild(el);
  }
}

function validRecord(record) {
  return record && typeof record === "object";
}

function finiteOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}
