// The generations of one turn, as the turn view shows them: a list of gens
// (one per model generation: its thinking, its narration, its tool rows),
// the last one live until the next opens or the turn ends. Pure: fed by the
// same events live and on a join (turn_events.js snapshotEvents), no DOM, so
// `node --test` covers the grouping rules. turn_view.js draws it.
//
// Rules:
// - turn_started opens the first gen (no iteration yet).
// - generation_started(n) opens a new gen unless the current one is still
//   empty (then it takes n).
// - a chunk goes to the gen of its iteration (opening one when none has it);
//   a chunk with no iteration goes to the current gen, unless that one is
//   textDone or already has tool rows (an older server's replay), which
//   opens a new gen.
// - generation_completed marks the current gen textDone; its tool rows
//   follow it (the kernel emits them after).
// - tool events go to the gen of their iteration, else to the current gen,
//   which takes the iteration when it had none.
// - a hook's notice goes to the current gen (hook_notice has no
//   iteration; a before_tool_call hook runs before the call's
//   tool_call_started), none once the turn ended.
// - the turn's end closes the current gen.
import { addCompleted, addStarted, newActivity, toolName } from "./activity.js";
import { tallyText } from "./tally.js";
import { leadTrimmed } from "./format.js";

const LABEL_MAX = 80;
const LABEL_TOOLS = 3;

export function newTurn() {
  return { gens: [], ended: false, plainAnswer: false };
}

// The gen still open, or null.
export function currentGen(turn) {
  const last = turn.gens[turn.gens.length - 1];
  return last && !last.closed ? last : null;
}

function isEmpty(gen) {
  return !gen.thinking && !gen.text && gen.tools.length === 0;
}

function openGen(turn, iteration) {
  const closed = closeCurrent(turn);
  const gen = { iteration: iteration ?? null, thinking: "", text: "", activity: newActivity(), textDone: false, closed: false, notices: [] };
  gen.tools = gen.activity.rows;
  turn.gens.push(gen);
  return { gen, opened: true, closed };
}

function closeCurrent(turn) {
  const gen = currentGen(turn);
  if (!gen) return null;
  gen.thinking = gen.thinking.replace(/[ \t\r\n]+$/, "");
  gen.text = gen.text.replace(/[ \t\r\n]+$/, "");
  gen.closed = true;
  return gen;
}

// The current gen, or the one that +iteration+ names (opening one when
// needed). Returns { gen, opened, closed }.
function genFor(turn, iteration) {
  if (iteration != null) {
    const named = [...turn.gens].reverse().find((g) => g.iteration === iteration);
    if (named) return { gen: named, opened: false, closed: null };
  }
  const current = currentGen(turn);
  if (current && iteration != null && current.iteration == null) {
    current.iteration = iteration;
    return { gen: current, opened: false, closed: null };
  }
  if (current && iteration != null && current.iteration !== iteration) return openGen(turn, iteration);
  if (current) return { gen: current, opened: false, closed: null };
  return openGen(turn, iteration);
}

export function turnStarted(turn) {
  return openGen(turn, null);
}

export function generationStarted(turn, iteration = null) {
  const current = currentGen(turn);
  if (current && isEmpty(current)) {
    current.iteration = iteration ?? current.iteration;
    return { gen: current, opened: false, closed: null };
  }
  return openGen(turn, iteration);
}

export function chunk(turn, { text = "", thinking = "", iteration = null } = {}) {
  let r;
  if (iteration == null) {
    const current = currentGen(turn);
    r = current && (current.textDone || current.tools.length) ? openGen(turn, null) : genFor(turn, null);
  } else {
    r = genFor(turn, iteration);
  }
  const { gen } = r;
  // Leading whitespace (the "\n" after <think>, or after a closed
  // think/tool_call block) would render as an empty first line; trim it at
  // the start of a gen's thinking and text only.
  if (thinking) gen.thinking += leadTrimmed(gen.thinking, thinking);
  if (text) gen.text += leadTrimmed(gen.text, text);
  return r;
}

export function generationCompleted(turn) {
  const gen = currentGen(turn);
  if (gen) gen.textDone = true;
  return gen ? { gen, opened: false, closed: null } : null;
}

function toolEvent(turn, event, add) {
  const r = genFor(turn, event.iteration ?? null);
  const row = add(r.gen.activity, event);
  return { ...r, row };
}

export function toolStarted(turn, event) {
  return toolEvent(turn, event, (model, e) => addStarted(model, e).row);
}

export function toolCompleted(turn, event) {
  return toolEvent(turn, event, addCompleted);
}

// A hook's line to the user, in the current step; null with no running
// turn (the page shows it as a bubble then). Not a tool row: the counts
// and labels leave it out.
export function notice(turn, { hook, text, level } = {}) {
  const gen = turn && !turn.ended ? currentGen(turn) : null;
  if (!gen) return null;
  gen.notices.push({ hook, text, level });
  return { gen };
}

// The turn is over (completed, canceled, failed, the worker gone).
export function turnEnded(turn) {
  const closed = closeCurrent(turn);
  turn.ended = true;
  turn.plainAnswer = turn.gens.length === 1 && !turn.gens[0].thinking && turn.gens[0].tools.length === 0;
  return { gen: null, opened: false, closed };
}

// The turn's answer is +gen+'s text, moved out of the block (turn_view.js
// promote): a gen left with no thinking and no tool rows is no step then,
// as it is no row, and as a reload counts it (turnGroups).
export function takeAnswer(turn, gen) {
  if (gen) gen.answer = true;
  return turn;
}

function isStep(gen) {
  return !gen.answer || !!gen.thinking || gen.tools.length > 0;
}

function cut(line) {
  return line.length > LABEL_MAX ? `${line.slice(0, LABEL_MAX).trimEnd()}…` : line;
}

// "3 tool calls (1 failed)": failed = status error, the tally's predicate
// (tally.js), so a step's label and the block's summary never disagree.
function toolCallsText(rows) {
  const n = rows.length;
  const failed = failedCount(rows);
  return `${n} tool call${n === 1 ? "" : "s"}${failed ? ` (${failed} failed)` : ""}`;
}

// A gen's calls that failed (status error; blocked and stopped don't count).
export function failedCount(rows) {
  return rows.filter((r) => r.status === "error").length;
}

// The collapsed row of a gen: its narration's first line, else its first
// call's title ("edit lib/a.rb"), else the tools it worked with, else
// "thinking"; then its call count and how many failed.
export function genLabel(gen) {
  const { head, calls } = genLabelParts(gen);
  return calls ? `${head} · ${calls}` : head;
}

// genLabel in its parts: +head+, +calls+ ("3 tool calls (1 failed)", or ""
// without calls) and +repeats+: the head is words the open step's body
// starts with (its narration, its first call's title), so an open step's
// summary can say only its calls (turn_view.js labelHtml).
export function genLabelParts(gen) {
  const line = String(gen.text || "").trim().split("\n")[0].trim();
  const calls = gen.tools.length ? toolCallsText(gen.tools) : "";
  const first = gen.tools[0];
  if (line) return { head: cut(line), calls, repeats: true };
  if (first?.title) return { head: cut(`${toolName(first)} ${first.title}`), calls, repeats: true };
  if (gen.tools.length) {
    const names = [...new Set(gen.tools.map(toolName))];
    const head = `working with ${names.slice(0, LABEL_TOOLS).join(", ")}${names.length > LABEL_TOOLS ? ", …" : ""}`;
    return { head, calls, repeats: false };
  }
  return { head: "thinking", calls: "", repeats: false };
}

// The block's summary line: "working · 3 steps · 8 tool calls · execute ×7 · …"
// while it runs, without the prefix after; the tally (tally.js) from 3 calls.
export function blockSummary(turn, { running = false } = {}) {
  const rows = turn.gens.flatMap((g) => g.tools);
  const steps = turn.gens.filter(isStep).length;
  const fields = [`${steps} step${steps === 1 ? "" : "s"}`];
  const tally = tallyText(rows, { last: false });
  if (tally) fields.push(tally);
  else if (rows.length) fields.push(toolCallsText(rows));
  if (running) fields.unshift("working");
  return fields.join(" · ");
}
