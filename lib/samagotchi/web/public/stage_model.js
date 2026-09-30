// The stage view's pure parts (web.view: stage): what the live slots show
// for a turn (turn_model.js's), when a finished turn hands off into the
// history, and in what order its pieces go there. No DOM, so `node --test`
// covers the rules; stage_view.js draws them.
import { toolName } from "./activity.js";

const READ_LIKE = new Set(["read", "memory_read", "web_fetch", "task_get", "task_list", "list_sessions"]);
const EDITS = new Set(["edit", "write", "memory_write"]);
const EXECS = new Set(["execute", "task_create", "task_wait", "task_stop", "delegate", "delegate_result"]);
const FILE_TOOLS = new Set(["read", "edit", "write"]);
const TRAIL = 3;
// The hand-off waits this long after the stage was last in use.
export const QUIET_MS = 1500;
// A touch, wheel or scroll counts as use this long (phones have no hover).
export const TOUCH_MS = 4000;

// A tool's tick colour: read-like, edit, exec or other.
export function toolKind(name) {
  if (READ_LIKE.has(name)) return "read";
  if (EDITS.has(name)) return "edit";
  if (EXECS.has(name)) return "exec";
  return "other";
}

function rowTitle(row) {
  return row.title || row.params || "";
}

// While the first step has no thinking and no tool rows the turn is plain:
// its text streams in the stage's answer slot, as the turn view's
// chrome-less block streams like a bubble.
export function isPlain(turn) {
  if (!turn || turn.ended || turn.gens.length > 1) return false;
  const [gen] = turn.gens;
  return !gen || (!gen.thinking && gen.tools.length === 0);
}

const END_PHASES = { completed: "answered", canceled: "canceled" };

// What the live slots show for +turn+:
//   phase    the status row's word;
//   step     the step count (at the end as the block summary counts:
//            an answer-only generation is no step);
//   headline the newest narration sentence (+narration+, the view's sentence
//            feed), else the newest thinking one (+thinking+, its ticker),
//            else "…";
//   tool     the running call ({name, title, kind}) or null;
//   trail    the last three finished calls, newest last (a file's title
//            without its dir);
//   ticks    one per call: {kind, status, step (the gen's index)}.
// +pending+: a card waits for the user; +ended+: the turn's end kind.
export function liveSlots(turn, { narration = "", thinking = "", pending = false, ended = null } = {}) {
  const gens = turn?.gens || [];
  const rows = gens.flatMap((gen, step) => gen.tools.map((row) => ({ row, step })));
  const running = [...rows].reverse().find(({ row }) => row.status === "running")?.row || null;
  const current = gens[gens.length - 1];
  let phase;
  if (ended) phase = END_PHASES[ended] || "failed";
  else if (pending) phase = "waiting for you";
  else if (running) phase = "running a tool";
  else if (current?.text && isPlain(turn)) phase = "writing the answer";
  else if (current?.text && !current.textDone) phase = "writing";
  else phase = "thinking";
  let headline = { text: "…", thinking: false };
  if (narration) headline = { text: narration, thinking: false };
  else if (thinking) headline = { text: thinking, thinking: true };
  const trail = rows.filter(({ row }) => row.status !== "running").slice(-TRAIL).map(({ row }) => {
    const title = rowTitle(row);
    return { name: toolName(row), title: FILE_TOOLS.has(row.tool) ? title.split("/").pop() : title, status: row.status };
  });
  return {
    phase,
    step: ended ? gens.filter((g) => !g.answer || g.thinking || g.tools.length).length : gens.length,
    headline,
    tool: running ? { name: toolName(running), title: rowTitle(running), kind: toolKind(running.tool) } : null,
    trail,
    ticks: rows.map(({ row, step }) => ({ kind: toolKind(row.tool), status: row.status, step })),
  };
}

// In use: the pointer over the stage, focus or a selection in it, or a
// touch/wheel/scroll in it within TOUCH_MS.
export function inUseFrom({ pointerIn, lastTouchMs, focusInside, selectionInside, nowMs }) {
  return !!(pointerIn || focusInside || selectionInside || (lastTouchMs && nowMs - lastTouchMs < TOUCH_MS));
}

// One tick of the hand-off watcher: due once the turn has ended, nothing
// is pending (a card, the turn-end read) and the stage has not been in use
// for QUIET_MS. Returns the next quiet clock with it.
export function handOffDue({ ended, pending, inUse, quietSinceMs, nowMs }) {
  if (!ended || pending || inUse) return { due: false, quietSinceMs: null };
  const since = quietSinceMs ?? nowMs;
  return { due: nowMs - since >= QUIET_MS, quietSinceMs: since };
}

// A handed-off turn's nodes in the order the turn view leaves them: the
// prompt bubble (none for a reminder turn), the block, the extras in
// arrival order, the answer's pieces, the timing line, the end line, the
// kept cards.
export function handOffOrder({ prompt = null, block = null, extras = [], answer = [], timing = null, end = null, kept = [] }) {
  return [prompt, block, ...extras, ...answer, timing, end, ...kept].filter(Boolean);
}

// Where a row app.js would append goes: the stage's extras while a turn is
// live (and not handing off), else the history; the recap always the
// history (it is idle-only).
export function placeFor({ live, handingOff, kind }) {
  if (kind === "recap") return "history";
  return live && !handingOff ? "stage" : "history";
}
