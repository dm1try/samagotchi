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
const CANCEL_REASONS = { ctrl_c: "Ctrl-C", user: "stopped", hook: "by a hook" };

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

// A re-rendered turn's cancel line (a .bubble.cancel.stopped), or "" when
// the turn record is not a canceled one.
export function cancelLineHtml(record, escape) {
  if (record?.status !== "canceled") return "";
  return `<div class="${STOPPED_LINE_CLASS}">${escape(cancelLineText(record.cancellation_reason, record.cancelled_by))}</div>`;
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
  };
}

// A turn-end re-read's timing (+data+, the server's ?tail=1&recent=1: the
// newest turn's records and turn_count) merged into the page's (+timing+,
// normalizeTiming's shape). Records by id: a known one is replaced in
// place; an unknown turn goes in started_at order (ties and unparsable
// dates keep arrival order), an unknown tool record at the end (they come
// grouped by turn, in call order). startedAt, sessionDurationMs and
// activeTurn are the reply's, and so are its tokens (a reply without them
// keeps the page's). `short`: the reply's turn_count says the page
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
  return { timing: { ...fresh, turnRecords, toolRecords, tokens, memoryIndex }, short: turnRecords.length < count };
}

function replaceById(records, record) {
  if (record?.id == null) return false;
  const at = records.findIndex((r) => r?.id === record.id);
  if (at < 0) return false;
  records[at] = record;
  return true;
}

export function turnRecordAt(timing, index) {
  const records = timing?.turnRecords;
  return Array.isArray(records) ? records[index] || null : null;
}

// A history item that starts a turn: a prompt, or the note a context wake
// turn starts with (turn_start).
const startsTurn = (item) => item?.role === "user" || (item?.role === "note" && item.turn_start === true);

// For each history item, the turn index its timing shows under, or null. A
// turn with tool calls holds several assistant messages; only the last one
// before the next user message carries the turn's timing. A turn with none
// (canceled before an answer, or still running: no record yet) has it on
// its user message.
export function timedTurnIndexes(items) {
  const result = items.map(() => null);
  let turnIndex = -1;
  let carrier = null;
  items.forEach((item, i) => {
    if (startsTurn(item)) {
      if (carrier !== null) result[carrier] = turnIndex;
      turnIndex += 1;
      carrier = i;
    } else if (item?.role === "assistant") {
      carrier = i;
    }
  });
  if (carrier !== null) result[carrier] = turnIndex;
  return result;
}

// The history as turns, for the turn view's reload: notes on their own, and
// per prompt a turn with its record, its steps (one per iteration: the
// turn's tool records grouped by iteration, and the assistant messages but
// the last, in order; a text-less iteration leaves no message, so a text
// can sit one step early: inspection, not truth) and its answer (the last
// assistant message). Assistant messages before any prompt are answers on
// their own. A turn that ended with no answer (the server's empty_answer
// item) has no answer: its texts are steps, and `emptyAnswer` is that
// item's index. The turn index counts prompts, as timedTurnIndexes does. The
// user's lines merged into the running turn (`merged`, the server's
// Steer::INPUT_KIND) stay in it: the turn's `merged` list.
export function turnGroups(items, timing) {
  const groups = [];
  let turnIndex = -1;
  let turn = null;
  items.forEach((item, i) => {
    if (item?.role === "note" && !startsTurn(item)) {
      groups.push({ kind: "note", i });
    } else if (item?.role === "steer") {
      if (turn) turn.steers.push(i);
      else groups.push({ kind: "steer", i });
    } else if (item?.role === "user" && item.merged && turn) {
      turn.merged.push(i);
    } else if (startsTurn(item)) {
      turnIndex += 1;
      turn = { kind: "turn", turnIndex, turnId: item.turn_id, user: i, texts: [], steers: [], merged: [] };
      groups.push(turn);
    } else if (item?.role === "assistant") {
      if (turn) turn.texts.push(i);
      else groups.push({ kind: "answer", answer: i });
    } else if (item?.role === "empty_answer" && turn) {
      turn.emptyAnswer = i;
    }
  });
  return groups.map((g) => {
    if (g.kind !== "turn") return g;
    const group = withSteers(turnGroup(g, items, timing), g.steers, items);
    // A turn that ended with no answer: its notice (the item's index) in
    // the answer's place.
    const ended = g.emptyAnswer == null ? group : { ...group, emptyAnswer: g.emptyAnswer };
    // A turn with no merged lines keeps its shape.
    return g.merged.length ? { ...ended, merged: g.merged } : ended;
  });
}

// A turn's steers (a plugin's nudges) into its steps: each goes to the step
// that answered it (`step`: the server counts the model messages since the
// prompt, plus one). One whose step isn't there (the answer, which leaves
// the block) stays on the group (`steers`): a bubble before the answer, as
// live. A turn without steers keeps its shape.
function withSteers(group, steerIndexes, items) {
  if (!steerIndexes.length) return group;
  const steps = group.steps.map((step) => ({ ...step, steers: [] }));
  const left = [];
  for (const i of steerIndexes) {
    const n = Number(items[i].step) || 1;
    const step = steps.find((s) => s.iteration === n);
    if (step) step.steers.push(i);
    else left.push(i);
  }
  return { ...group, steps, steers: left };
}

// A prompt's turn record: the one with its turn id (the engine saves it
// on the prompt), so a turn whose prompt left the conversation (a failed
// one's went back to the user, !rollback) shifts no other; a prompt saved
// before turn ids pairs by its place among the prompts.
function promptRecord(timing, g) {
  if (typeof g.turnId !== "string" || !g.turnId) return turnRecordAt(timing, g.turnIndex);
  return (timing?.turnRecords || []).find((r) => r.id === g.turnId) || null;
}

function turnGroup(g, items, timing) {
  const record = promptRecord(timing, g);
  const tools = record ? (timing?.toolRecords || []).filter((r) => r.turn_id === record.id) : [];
  // A turn with no answer has none of its texts as one: they are steps.
  const stepsOnly = canceledSteps(g, record, tools) || g.emptyAnswer != null;
  if (g.texts.some((i) => items[i].parts)) return partsTurn(g, items, record, tools, stepsOnly);
  const maxIteration = tools.reduce((m, r) => Math.max(m, Number(r.iteration) || 0), 0);
  const stepTexts = stepsOnly ? g.texts : g.texts.slice(0, -1);
  const steps = [];
  for (let k = 0; k < Math.max(stepTexts.length, maxIteration); k += 1) {
    const iteration = k + 1;
    steps.push({ i: stepTexts[k] ?? null, iteration, tools: recordRows(tools, iteration) });
  }
  const answer = g.texts.length && !stepsOnly ? g.texts[g.texts.length - 1] : null;
  return { kind: "turn", turnIndex: g.turnIndex, user: g.user, answer, record, steps };
}

// A canceled turn that ran more than one step or any call has no answer:
// its partial text stays in the block, as it does live (turn_view.js
// turnEnded promotes only a completed turn or a lone step with no tools). A
// failed turn never answered: its texts are steps.
function canceledSteps(g, record, tools) {
  if (record?.status === "failed") return true;
  return record?.status === "canceled" && (g.texts.length > 1 || tools.length > 0);
}

function recordRows(tools, iteration) {
  return tools.filter((r) => Number(r.iteration) === iteration).map((r) => ({
    key: `${iteration}:${r.call_index ?? 0}`, tool: r.tool, status: r.status, duration_ms: r.duration_ms,
  }));
}

// A turn whose saved messages carry their parts (the server's ?parts=1):
// every assistant message is one step. Its calls take the turn's records by
// tool, in call order (each the next record of its tool, consumed with the
// ones it skipped), not by iteration: an empty retry spends an iteration
// that left no message (as the TUI's join, attached_loop.rb join_duration).
// The last message is the answer when it has text and made no call (and the
// turn is no canceled multi-step one); its thinking stays behind as a step,
// as it does live.
function partsTurn(g, items, record, tools, stepsOnly = false) {
  const last = g.texts[g.texts.length - 1];
  const lastItem = items[last];
  const answer = !stepsOnly && String(lastItem.content ?? "") !== "" && !lastItem.parts?.tools?.length ? last : null;
  const pool = [...tools].sort((a, b) =>
    (Number(a.iteration) || 0) - (Number(b.iteration) || 0) || (Number(a.call_index) || 0) - (Number(b.call_index) || 0));
  const steps = g.texts.map((i, k) => {
    const iteration = k + 1;
    const parts = items[i].parts || {};
    const rows = Array.isArray(parts.tools)
      ? parts.tools.map((call, j) => {
        const r = takeRecord(pool, call.tool);
        return { key: `${iteration}:${j + 1}`, status: r?.status || "ok", duration_ms: r?.duration_ms, ...call };
      })
      : [];
    const thinking = String(parts.thinking || "");
    if (i === answer) return thinking ? { i: null, iteration, thinking, tools: [] } : null;
    return { i, iteration, thinking, tools: rows };
  }).filter(Boolean);
  // Records no saved message took (a generation that saved nothing): a
  // step per iteration of theirs, after the messages'.
  let iteration = g.texts.length;
  for (const n of [...new Set(pool.map((r) => Number(r.iteration) || 0))]) {
    iteration += 1;
    const rows = recordRows(pool, n).map((row) => ({ ...row, key: `${iteration}:${row.key.split(":")[1]}` }));
    steps.push({ i: null, iteration, thinking: "", tools: rows });
  }
  return { kind: "turn", turnIndex: g.turnIndex, user: g.user, answer, record, steps };
}

// The next record of +tool+ in +pool+ (call order), removed with the ones
// before it; undefined when there is none (the pool stays as it was).
function takeRecord(pool, tool) {
  const at = pool.findIndex((r) => String(r.tool) === String(tool));
  if (at < 0) return undefined;
  return pool.splice(0, at + 1)[at];
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
