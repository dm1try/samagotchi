// The generations of one turn, as the turn view shows them: a list of gens
// (one per model generation: its thinking, its narration, its tool rows),
// the last one live until the next opens or the turn ends. Pure: fed by the
// same events live and on a join (turn_events.js snapshotEvents), no DOM, so
// `node --test` covers the grouping rules. turn_block.js draws it.
//
// Rules:
// - turn_started opens the first gen (no iteration yet).
// - generation_started(n) opens a new gen unless the current one is still
//   empty (then it takes n); either way the gen's startedAt is the page's
//   clock at it (null for a replay).
// - a chunk goes to the gen of its iteration (opening one when none has it);
//   a chunk with no iteration goes to the current gen, unless that one is
//   textDone or already has tool rows (an older server's replay), which
//   opens a new gen.
// - generation_retrying with restarted (a dropped stream's step asked
//   again) empties its gen's thinking and text.
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
import { clip, leadTrimmed } from "./format.js";
import { plainLine } from "./plain_line.js";

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
  const gen = { iteration: iteration ?? null, thinking: "", text: "", activity: newActivity(), textDone: false, closed: false, notices: [], startedAt: null, thinkingAt: null };
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

// +now+ (ms): when the page saw the generation start, its startedAt (the
// composer's delivery line clocks the step from it); null for a replayed
// start (a join: the snapshot's generation age stands in).
export function generationStarted(turn, iteration = null, now = null) {
  const current = currentGen(turn);
  const r = current && isEmpty(current) ? { gen: current, opened: false, closed: null } : openGen(turn, iteration);
  if (!r.opened) r.gen.iteration = iteration ?? r.gen.iteration;
  r.gen.startedAt = now;
  return r;
}

// +now+ (ms): when the page got the chunk (null for a replay): a gen's
// first thinking delta stamps its thinkingAt, the clock the worker's cut
// counts from too (GenerationPhase).
export function chunk(turn, { text = "", thinking = "", iteration = null, now = null } = {}) {
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
  if (thinking && !gen.thinking && now != null) gen.thinkingAt = now;
  if (thinking) gen.thinking += leadTrimmed(gen.thinking, thinking);
  if (text) gen.text += leadTrimmed(gen.text, text);
  return r;
}

// A step asked again after its stream dropped (generation_retrying with
// restarted): the open gen of +iteration+ (else the current one) loses what
// it streamed; null when there is none.
export function generationRestarted(turn, iteration = null) {
  const current = currentGen(turn);
  const gen = iteration == null ? current
    : [...turn.gens].reverse().find((g) => !g.closed && g.iteration === iteration) ?? null;
  if (!gen) return null;
  gen.thinking = "";
  gen.text = "";
  gen.textDone = false;
  return { gen, opened: false, closed: null };
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

// +now+: when the page got the event, for the call's duration (activity.js).
export function toolStarted(turn, event, now = null) {
  return toolEvent(turn, event, (model, e) => addStarted(model, e, now).row);
}

export function toolCompleted(turn, event, now = null) {
  return toolEvent(turn, event, (model, e) => addCompleted(model, e, now));
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

// The whole text of the reply that asked the user (a question or an
// approval blocks its call): the last gen's text, trimmed, while one of its
// calls runs and the turn goes on; else "". Only that step's text: a hook's
// question (asked before its call's row, or between steps) has no running
// row there, so it gets none rather than another step's (or the answer's)
// text. The stage shows it while the card waits; the card keeps it once
// answered.
export function askingText(turn) {
  if (!turn || turn.ended) return "";
  const gen = turn.gens[turn.gens.length - 1];
  if (!gen?.text || !gen.tools.some((row) => row.status === "running")) return "";
  return gen.text.trim();
}

// A plugin's refs on the reply that asks (a question's refs, from its
// pending question): kept on the asking step's gen, the last one, while
// the turn goes on, for the stage's asking slot (askingRefs) and the
// step's closed text (turn_block.js). A non-array or an empty list keeps
// what the gen has. The gen, or null.
export function questionRefs(turn, refs) {
  if (!turn || turn.ended || !Array.isArray(refs) || !refs.length) return null;
  const gen = turn.gens[turn.gens.length - 1];
  if (!gen) return null;
  gen.refs = refs;
  return gen;
}

// The refs on the asking text (questionRefs), while it shows
// (askingText's rule); else null.
export function askingRefs(turn) {
  if (!askingText(turn)) return null;
  return turn.gens[turn.gens.length - 1].refs || null;
}

// The turn is over (completed, canceled, failed, the worker gone).
export function turnEnded(turn) {
  const closed = closeCurrent(turn);
  turn.ended = true;
  turn.plainAnswer = turn.gens.length === 1 && !turn.gens[0].thinking && turn.gens[0].tools.length === 0;
  return { gen: null, opened: false, closed };
}

// The turn's answer is +gen+'s text, moved out of the block (turn_block.js
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
  return clip(line, LABEL_MAX + 1);
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

// The collapsed row of a gen: its narration's first line as plain text
// (plain_line.js: "## Plan" reads "Plan"; a line that is only syntax, a rule
// or a fence, gives way to the next), else its first call's title ("edit
// lib/a.rb"), else the tools it worked with, else "thinking"; then its call
// count and how many failed.
export function genLabel(gen) {
  const { head, calls } = genLabelParts(gen);
  return calls ? `${head} · ${calls}` : head;
}

// genLabel in its parts: +head+, +calls+ ("3 tool calls (1 failed)", or ""
// without calls) and +repeats+: the head is words the open step's body
// starts with (its narration, its first call's title), so an open step's
// summary can say only its calls (turn_block.js labelHtml).
export function genLabelParts(gen) {
  const line = String(gen.text || "").split("\n").map(plainLine).find(Boolean) || "";
  const calls = gen.tools.length ? toolCallsText(gen.tools) : "";
  const first = gen.tools[0];
  if (line) return { head: cut(line), calls, repeats: true };
  if (first?.title) return { head: cut(`${toolName(first)} ${first.title}`), calls, repeats: true };
  if (gen.tools.length) {
    // A plugin label that is a verb ("echoing", the default "calling
    // tool") is the head itself when every call has one; among other
    // tools it gives way to its tool's name ("working with read, echo").
    const verbs = gen.tools.every(isVerbLabel);
    const names = [...new Set(gen.tools.map((r) => (verbs || !isVerbLabel(r) ? toolName(r) : r.tool || "tool")))];
    const list = `${names.slice(0, LABEL_TOOLS).join(", ")}${names.length > LABEL_TOOLS ? ", …" : ""}`;
    return { head: verbs ? list : `working with ${list}`, calls, repeats: false };
  }
  return { head: "thinking", calls: "", repeats: false };
}

// A plugin tool's label that reads as a verb (its first word ends in
// "ing": "echoing", "calling tool"), not as a name ("chrome: screenshot").
function isVerbLabel(row) {
  return /^[a-z]+ing\b/i.test(String(row?.label || ""));
}

// A step that said something (its text is not the turn's answer): a row of
// its own in a finished block's outline.
export function isNarrated(gen) {
  return !gen.answer && !!String(gen.text || "").trim();
}

// A finished block's outline (+gens+: its steps in order, as the block holds
// them): each narrated step a row, each run of the others between (tool-only,
// thinking-only) one fold ({fold: [indices]}), so every mid-turn text's first
// line reads without a click and the steps that said nothing take one line.
// [] when no step said anything: the block stays closed, as before.
// A last run of one thinking-only step stays a row (no "· 1 step" at the end).
export function outlineRuns(gens) {
  if (!gens.some(isNarrated)) return [];
  const runs = [];
  gens.forEach((gen, i) => {
    if (isNarrated(gen)) return runs.push({ step: i });
    const last = runs[runs.length - 1];
    if (last?.fold) last.fold.push(i);
    else runs.push({ fold: [i] });
  });
  // A turn doesn't end on a "1 step" fold for a lone thinking-only step
  // (the answer's own thinking): it stays a row, its "thinking" label.
  const last = runs[runs.length - 1];
  const lone = last.fold?.length === 1 && gens[last.fold[0]];
  if (lone && lone.tools.length === 0) runs[runs.length - 1] = { step: last.fold[0] };
  return runs;
}

// A finished turn's steps as its block holds them: the answer's step left it
// when the answer was all it had (turn_block.js promote).
export function blockGens(turn) {
  return turn.gens.filter((gen) => !(gen.answer && !gen.thinking && gen.tools.length === 0));
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
