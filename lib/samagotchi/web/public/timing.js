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

// A cancel's reason as the terminal UIs name it too (Formatting::
// CANCEL_REASONS); anything else as it is. Both sides: spec/shared/labels_matrix.json.
const CANCEL_REASONS = { ctrl_c: "Ctrl-C", user: "stopped", hook: "by a hook" };

// The line a canceled turn ends with: "✕ canceled (stopped)", live from
// turn_canceled's reason and after a re-render from the turn record's
// cancellation_reason (records saved before it existed: no reason).
export function cancelLineText(reason) {
  return "\u2715 canceled" + (reason ? ` (${CANCEL_REASONS[reason] || reason})` : "");
}

// A re-rendered turn's cancel line (a .bubble.cancel), or "" when the turn
// record is not a canceled one.
export function cancelLineHtml(record, escape) {
  if (record?.status !== "canceled") return "";
  return `<div class="bubble cancel">${escape(cancelLineText(record.cancellation_reason))}</div>`;
}

export function elapsedSince(startedAt, now = Date.now()) {
  const started = Date.parse(startedAt);
  const current = Number(now);
  if (!Number.isFinite(started) || !Number.isFinite(current)) return null;
  return Math.max(0, current - started);
}

export function normalizeTiming(data = {}) {
  return {
    startedAt: typeof data.started_at === "string" ? data.started_at : null,
    sessionDurationMs: finiteOrNull(data.session_duration_ms),
    turnRecords: Array.isArray(data.turn_records) ? data.turn_records.filter(validRecord) : [],
    toolRecords: Array.isArray(data.tool_records) ? data.tool_records.filter(validRecord) : [],
    activeTurn: validRecord(data.active_turn) ? data.active_turn : null,
  };
}

export function turnRecordAt(timing, index) {
  const records = timing?.turnRecords;
  return Array.isArray(records) ? records[index] || null : null;
}

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
    if (item?.role === "user") {
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
    if (item?.role === "note") {
      groups.push({ kind: "note", i });
    } else if (item?.role === "steer") {
      if (turn) turn.steers.push(i);
      else groups.push({ kind: "steer", i });
    } else if (item?.role === "user" && item.merged && turn) {
      turn.merged.push(i);
    } else if (item?.role === "user") {
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
// turnEnded promotes only a completed turn or a lone step with no tools).
function canceledSteps(g, record, tools) {
  return record?.status === "canceled" && (g.texts.length > 1 || tools.length > 0);
}

function recordRows(tools, iteration) {
  return tools.filter((r) => Number(r.iteration) === iteration).map((r) => ({
    key: `${iteration}:${r.call_index ?? 0}`, tool: r.tool, status: r.status, duration_ms: r.duration_ms,
  }));
}

// A turn whose saved messages carry their parts (the server's ?parts=1):
// every assistant message is one generation, so the k-th is iteration k
// and its calls pair with that iteration's records by position. The last
// message is the answer when it has text and made no call (and the turn
// is no canceled multi-step one); its thinking stays behind as a step, as
// it does live.
function partsTurn(g, items, record, tools, stepsOnly = false) {
  const last = g.texts[g.texts.length - 1];
  const lastItem = items[last];
  const answer = !stepsOnly && String(lastItem.content ?? "") !== "" && !lastItem.parts?.tools?.length ? last : null;
  const steps = g.texts.map((i, k) => {
    const iteration = k + 1;
    const parts = items[i].parts || {};
    const records = recordRows(tools, iteration);
    const rows = Array.isArray(parts.tools)
      ? parts.tools.map((call, j) => {
        const r = records.find((row) => row.key === `${iteration}:${j + 1}`);
        return { key: `${iteration}:${j + 1}`, status: r?.status || "ok", duration_ms: r?.duration_ms, ...call };
      })
      : records;
    const thinking = String(parts.thinking || "");
    if (i === answer) return thinking ? { i: null, iteration, thinking, tools: [] } : null;
    return { i, iteration, thinking, tools: rows };
  }).filter(Boolean);
  // Records past the saved messages (a generation that saved nothing).
  const maxIteration = tools.reduce((m, r) => Math.max(m, Number(r.iteration) || 0), 0);
  for (let iteration = g.texts.length + 1; iteration <= maxIteration; iteration += 1) {
    steps.push({ i: null, iteration, thinking: "", tools: recordRows(tools, iteration) });
  }
  return { kind: "turn", turnIndex: g.turnIndex, user: g.user, answer, record, steps };
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
