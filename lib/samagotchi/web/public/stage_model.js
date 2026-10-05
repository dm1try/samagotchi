// The stage view's pure parts (web.view: stage): what the live slots show
// for a turn (turn_model.js's), when a finished turn hands off into the
// history, and in what order its pieces go there. No DOM, so `node --test`
// covers the rules; stage_view.js draws them.
import { toolName } from "./activity.js";
import { splitSentences } from "./sentences.js";
import { steerSender } from "./format.js";
import { hookNoticeLabel } from "./turn_events.js";

const READ_LIKE = new Set(["read", "memory_read", "web_fetch", "task_get", "task_list", "list_sessions"]);
const EDITS = new Set(["edit", "write", "memory_write"]);
const EXECS = new Set(["execute", "task_create", "task_wait", "task_stop", "delegate", "delegate_result"]);
const FILE_TOOLS = new Set(["read", "edit", "write"]);
const TASK_TOOLS = new Set(["task_wait", "task_get", "task_stop"]);
const TRAIL = 3;
// The hand-off waits this long after the stage was last in use.
export const QUIET_MS = 1500;
// A touch, wheel or scroll counts as use this long (phones have no hover).
export const TOUCH_MS = 4000;

// One headline sentence as plain text: the markdown a streaming answer
// carries (headings, quotes, bullets, table pipes, emphasis, code ticks,
// links) goes, and a line that is only syntax (a code fence, a table's
// separator row, a rule) is empty. A small pass, no renderer: a live line
// only needs to read well, and an unclosed "**" mid-stream goes too.
export function plainHeadline(line) {
  let s = String(line ?? "").trim();
  if (/^(```|~~~)/.test(s)) return "";
  if (/^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$/.test(s)) return "";
  if (/^([-*_])(\s*\1){2,}$/.test(s)) return "";
  s = s.replace(/^(>\s*)+/, "").replace(/^#{1,6}\s+/, "").replace(/^[-*+]\s+(\[[ xX]\]\s+)?/, "");
  // A table row: a pipe at either end (a pipe mid-prose, "a || b", stays).
  if (/^\||\|$/.test(s)) {
    s = s.replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim()).filter(Boolean).join(" · ");
  }
  // Code spans keep their text as is; an unclosed tick just goes.
  const code = [];
  s = s.replace(/`+([^`]+)`+/g, (_, c) => `\u0000${code.push(c) - 1}\u0000`);
  s = s
    .replace(/!\[([^\]]*)\]\([^)]*\)?/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)?/g, "$1")
    .replace(/<(https?:\/\/[^>\s]+)>/g, "$1")
    .replace(/`+/g, "")
    .replace(/(^|[^\w])__(?=\S)(.*?\S)__(?=$|[^\w])/g, "$1$2")
    .replace(/(\*\*|~~)/g, "")
    .replace(/(^|[^\w*])\*(?=\S)([^*]*?\S)\*(?=$|[^\w*])/g, "$1$2")
    .replace(/(^|[^\w])_(?=\S)([^_]*?\S)_(?=$|[^\w])/g, "$1$2")
    .replace(/\u0000(\d+)\u0000/g, (_, i) => code[Number(i)]);
  return s.replace(/\s+/g, " ").trim();
}

// The step's newest narration sentence, as plain text: the end of a
// finished text is a boundary (its last line may have no period), a live
// one's not yet. A sentence that is only markdown syntax is skipped, and so
// is code: the lines between a fence and its close (or the end, while one
// is open).
export function headlineOf(text, done) {
  const { sentences, rest } = splitSentences(text, { atEnd: true });
  let fenced = false;
  const plain = [];
  for (const sentence of sentences) {
    if (/^(```|~~~)/.test(sentence)) fenced = !fenced;
    else if (!fenced && plainHeadline(sentence)) plain.push(plainHeadline(sentence));
  }
  const fragment = fenced ? "" : plainHeadline(rest);
  if (done && fragment) return fragment;
  if (plain.length) return plain[plain.length - 1];
  return fragment.length > 160 ? fragment : "";
}

// A tool's tick colour: read-like, edit, exec or other.
export function toolKind(name) {
  if (READ_LIKE.has(name)) return "read";
  if (EDITS.has(name)) return "edit";
  if (EXECS.has(name)) return "exec";
  return "other";
}

// A finished call's mark in the trail, as its row's (index.html
// .activity-status): error and blocked ✕, stopped (a Stop cut it) ■, else ✓.
export function trailMark(status) {
  if (status === "error" || status === "blocked") return "\u2715";
  if (status === "stopped") return "\u25A0";
  return "\u2713";
}

function rowTitle(row) {
  return row.title || row.params || "";
}

// A slot's full command (the row's view), for its hover; none for a tool
// without one. A task tool titled by its task's command (the server's
// title) hovers its params instead: the id line it replaced.
function withCommand(slot, row) {
  if (row.view?.command) return { ...slot, command: row.view.command };
  return TASK_TOOLS.has(row.tool) && row.title && row.params ? { ...slot, command: row.params } : slot;
}

// A running task_wait's slot: the task it waits on and the row's key, for
// the stop-task button (task_stop.js).
function withTask(slot, row) {
  return row.tool === "task_wait" && row.view?.task_id ? { ...slot, taskId: row.view.task_id, key: row.key } : slot;
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
// A completed turn whose model returned nothing (the turn view's notice).
const NO_ANSWER = "no answer";

// What the live slots show for +turn+:
//   phase    the status row's word;
//   step     the step count (at the end as the block summary counts:
//            an answer-only generation is no step);
//   headline the newest narration sentence (+narration+, the view's sentence
//            feed), else the newest thinking one (+thinking+, its ticker),
//            else "…";
//   tool     the running call ({name, title, kind}, and command: its full
//            command when it has one; taskId and key: a task_wait's) or null;
//   quiet    the now row's word while no call runs: "writing…" while the
//            step's text streams, else "thinking…"; "" once the turn has
//            ended (nothing happens now);
//   trail    the last three finished calls, newest last (a file's title
//            without its dir; command as for tool);
//   ticks    one per call: {kind, status, step (the gen's index)}.
// +pending+: a card waits for the user; +ended+: the turn's end kind;
// +emptyAnswer+: a completed turn ended with no answer
// (turn_summary.empty_answer), so it reads "no answer", not "answered".
export function liveSlots(turn, { narration = "", thinking = "", pending = false, ended = null, emptyAnswer = false } = {}) {
  const gens = turn?.gens || [];
  const rows = gens.flatMap((gen, step) => gen.tools.map((row) => ({ row, step })));
  const running = [...rows].reverse().find(({ row }) => row.status === "running")?.row || null;
  const current = gens[gens.length - 1];
  let phase;
  if (ended === "completed" && emptyAnswer) phase = NO_ANSWER;
  else if (ended) phase = END_PHASES[ended] || "failed";
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
    return withCommand({ name: toolName(row), title: FILE_TOOLS.has(row.tool) ? title.split("/").pop() : title, status: row.status }, row);
  });
  return {
    phase,
    step: ended ? gens.filter((g) => !g.answer || g.thinking || g.tools.length).length : gens.length,
    headline,
    quiet: ended ? "" : current?.text && !current.textDone ? "writing…" : "thinking…",
    tool: running ? withTask(withCommand({ name: toolName(running), title: rowTitle(running), kind: toolKind(running.tool) }, running), running) : null,
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
// What flashes in the trail for a few seconds while the turn runs (the
// rows themselves go into their step inside the closed cloud): a hook's
// notice, warn or info, as its row reads, and a plugin's nudge (steer).
// chi's own asking-again row (a notice with a line and no hook) does not:
// the status line tells that already. null: nothing flashes.
export function flashOf(what, data = {}) {
  if (what === "steer") {
    const sender = steerSender(data.source);
    return { kind: "steer", text: sender ? `${sender} nudged the model` : "nudged the model" };
  }
  if (what !== "notice" || !data.hook) return null;
  return { kind: data.level === "warn" ? "warn" : "info", text: data.line || `${hookNoticeLabel(data.hook)}: ${data.text || ""}` };
}

export function placeFor({ live, handingOff, kind }) {
  if (kind === "recap") return "history";
  return live && !handingOff ? "stage" : "history";
}
