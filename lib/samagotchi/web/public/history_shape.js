// The history's shape: what a reader sees of the conversation, as a list of
// small records, so a turn drawn live and the same turn after a reload can be
// compared (live is the truth: a reload that reads otherwise is the bug).
// A pure DOM read with no app imports: the e2e reload checks
// (spec/e2e/support/history_shape.js) import it into the page, and chi web's
// opt-in reload check (reload_check.js) uses the same normalizer and
// allowlist.
//
// historyShape(historyEl) → [{kind, cls, text}], in order: each child of
// #history, and inside a turn block each step and each step's rows and
// notices. Kinds come from KINDS only (the server logs them, nothing else).
// `cls` is a kind's own modifier (a row's status, a warn notice, a report
// reply), `text` what it says, whitespace collapsed. Left out: lit's
// comments, the copy button, the quiet-stretch dividers (`.time-gap`), and
// view state (folds, stacks, the motion classes): nothing a reader would
// call a different turn.
//
// compareShapes(a, b, {allow}) → {same, kinds}: the two lists aligned
// (their longest common run), each leftover item, or pair of same-kind
// items at one place, a difference, unless an ACCEPTED entry named in
// +allow+ matches it. `kinds`: the differing items' kinds, sorted, unique.

// The kinds a shape item can have (a closed list: reload_check's log line
// carries only these, and chi web drops any other token).
export const KINDS = Object.freeze([
  "prompt", "steered", "note", "command", "recap", "block", "step", "steer", "row", "notice", "card", "question",
  "thinking", "answer", "empty-answer", "timing", "cancel", "failed", "other",
]);

// The live/reload divergences that stay, each with why: the deliberate ones
// of section 1 of ~/.claude/plans/arch-turn-records.md, and the bugs P2 (turn
// drawings) closes (`closedBy`; `found`: the e2e test whose reload check
// found it). A
// difference one of them matches is not one: +a+ live, +b+ reloaded (either
// may be null: the item is on one side only), +shapes+ the two whole lists
// ({live, reloaded}). A caller names the ones its scenario has (`allow`);
// the opt-in reload check takes them all.
export const ACCEPTED = Object.freeze([
  {
    id: "retry-row",
    reason: "an empty answer's step and its \"asking again\" row: live, the step that retried with the row in it; "
      + "a reload, the step gone (never saved) and the row before the next step or the answer (bug 1)",
    closedBy: "P2 (turn drawings)",
    match: (a, b, shapes) => (a === null || b === null
      ? isRetryRow(a || b) || droppedStep(a, b) || thinkingOnly(a, b, shapes)
      : fewerSteps(a, b)),
  },
  {
    id: "command-bubble",
    reason: "a command's reply bubble (/help, /model, a queued one) is saved nowhere: a reload drops it "
      + "(deliberate until a display journal; a !cmd is saved and stays)",
    match: (a, b) => b === null && a?.kind === "command",
  },
  {
    id: "edit-mark",
    reason: "a reloaded row shows the ✂ mark an LLM context edit later saved on its output: later state, "
      + "an overlay as a card's latest body is",
    match: (a, b) => a?.kind === "row" && b?.kind === "row" && sameBut(a, b, "edit"),
  },
  {
    id: "failed-step",
    found: "web.spec.js: a turn that fails after a tool step",
    reason: "a failed turn's last step (the generation the error ended) is drawn live and not saved: a reload "
      + "has one step fewer",
    closedBy: "P2 (turn drawings)",
    match: (a, b) => (a === null || b === null ? droppedStep(a, b) : fewerSteps(a, b)),
  },
  {
    id: "in-turn-card",
    found: "web.spec.js: check-in, the card mid-turn",
    reason: "a card a turn showed sits in that turn live and after the turn on a reload (CardStore places it by "
      + "its stamp; a drawing draws it in its step, P2 C2/C5)",
    closedBy: "P2 (turn drawings)",
    match: (a, b, { live, reloaded }) => (a === null ? b?.kind === "card" && has(live, b) : a.kind === "card" && b === null && has(reloaded, a)),
  },
]);

// A step the reload doesn't have (+a+ live only): one that said nothing.
function droppedStep(a, b) {
  return b === null && a?.kind === "step" && a.text === "thinking";
}

// A turn's block that the reload draws with fewer steps (the same calls), or
// none at all where only a thinking step is left (the reload's lone
// "thinking" bubble: +b+ only).
function fewerSteps(a, b) {
  if (a?.kind !== "block" || b?.kind !== "block") return false;
  const [, liveSteps, liveRest] = STEPS.exec(a.text) || [];
  const [, reloadSteps, reloadRest] = STEPS.exec(b.text) || [];
  return liveRest === reloadRest && Number(liveSteps) > Number(reloadSteps);
}

const STEPS = /^(\d+) steps?(.*)$/;

// A turn whose only step left on a reload is a thinking one: live, its block
// of steps that called nothing (+a+); reloaded, the plain answer's thinking
// bubble (+b+).
function thinkingOnly(a, b, { reloaded }) {
  if (a === null) return b?.kind === "thinking";
  return a.kind === "block" && b === null && /^\d+ steps?$/.test(a.text) && reloaded.some((it) => it.kind === "thinking");
}

function has(shape, it) {
  return shape.some((other) => JSON.stringify(other) === JSON.stringify(it));
}

const RETRY_ROW = /^↻ empty answer, asking again/;

function isRetryRow(item) {
  return item.kind === "notice" && RETRY_ROW.test(item.text);
}

function sameBut(a, b, key) {
  const strip = ({ [key]: _drop, ...rest }) => rest;
  return JSON.stringify(strip(a)) === JSON.stringify(strip(b));
}

// What a reader reads of +el+: its text, without the copy button and the
// time dividers, whitespace collapsed.
function textOf(el) {
  if (!el) return "";
  const copy = el.cloneNode(true);
  copy.querySelectorAll(".copy-btn, .time-gap").forEach((node) => node.remove());
  return copy.textContent.replace(/\s+/g, " ").trim();
}

function item(kind, text = "", cls = "") {
  return { kind, cls, text };
}

// A tool row: its status mark, then tool, title, the word an exception
// shows, its duration (formatDuration's text); its output, its diff's
// summary and its ✂ mark.
function rowItem(el) {
  const status = [...(el.querySelector(".activity-status")?.classList || [])].filter((c) => c !== "activity-status").join(" ");
  const text = [".activity-tool", ".activity-params", ".activity-state", ".activity-duration"]
    .map((sel) => textOf(el.querySelector(`:scope > ${sel}`))).filter(Boolean).join(" · ");
  const row = item("row", text, status);
  // Its output as the hover has it (the inline text is its start or end),
  // and the summary of an edit's diff.
  const output = el.querySelector(":scope > .activity-output")?.getAttribute("title");
  if (output) row.output = output;
  const diff = textOf(el.querySelector(":scope > .activity-diff > summary"));
  if (diff) row.diff = diff;
  const edit = textOf(el.querySelector(":scope > .activity-edit"));
  if (edit) row.edit = edit;
  return row;
}

function cardItem(el) {
  return item("card", `${el.dataset.cardId || ""} ${textOf(el.querySelector(".card-title"))}`.trim());
}

function questionItem(el) {
  return item("question", textOf(el.querySelector(":scope > summary")));
}

function noticeItem(el) {
  return item("notice", textOf(el), el.classList.contains("warn") ? "warn" : "");
}

// A step's own items, in order: the steers it answered, then its rows,
// notices and cards.
function stepItems(gen) {
  const out = [item("step", textOf(gen.querySelector(":scope > summary")))];
  for (const steer of gen.querySelectorAll(":scope > .steer-row")) out.push(item("steer", textOf(steer.querySelector("summary"))));
  for (const el of gen.querySelectorAll(":scope > .activity-body > *")) {
    if (el.matches(".activity-row")) out.push(rowItem(el));
    else if (el.matches(".hook-notice")) out.push(noticeItem(el));
    else if (el.matches(".plugin-card")) out.push(cardItem(el));
    else if (el.matches(".bubble.question")) out.push(questionItem(el));
    else out.push(otherItem(el));
  }
  return out;
}

// The classes that are view state, not what the element is.
const VIEW_CLASSES = new Set(["open", "folded", "unfolded", "outline", "live", "done", "entering", "card-updated",
  "stack-hidden", "stack-swapped", "stack-view", "streaming"]);

function otherItem(el) {
  const cls = [...el.classList].filter((c) => !VIEW_CLASSES.has(c)).sort().join(" ");
  return item("other", "", cls || el.tagName.toLowerCase());
}

// One child of #history as its items (a turn block's are several; a time
// divider none).
function childItems(el) {
  if (el.matches(".time-gap, .copy-btn")) return [];
  if (el.matches(".turn-work")) {
    return [item("block", textOf(el.querySelector(":scope > summary .turn-steps"))),
      ...[...el.querySelectorAll(":scope > .gen")].flatMap(stepItems)];
  }
  if (el.matches(".bubble.user")) {
    const kind = el.classList.contains("steered") ? "steered" : "prompt";
    return [item(kind, textOf(el.querySelector(":scope > .user-message")))];
  }
  if (el.matches(".bubble.note")) return [item("note", textOf(el))];
  if (el.matches(".bubble.command")) return [item("command", textOf(el.querySelector(".command-line")))];
  if (el.matches(".bubble.recap")) return [item("recap", textOf(el.querySelector(".recap-body")))];
  if (el.matches(".empty-answer")) return [item("empty-answer", textOf(el))];
  if (el.matches(".hook-notice")) return [noticeItem(el)];
  if (el.matches(".bubble.thinking")) return [item("thinking")];
  if (el.matches(".bubble.output")) return [item("answer", textOf(el), el.classList.contains("report-reply") ? "report-reply" : "")];
  if (el.matches(".turn-timing")) return [item("timing", textOf(el))];
  if (el.matches(".bubble.cancel")) return [item(el.classList.contains("stopped") ? "cancel" : "failed", textOf(el))];
  if (el.matches(".bubble.question")) return [questionItem(el)];
  if (el.matches(".plugin-card")) return [cardItem(el)];
  if (el.matches(".steer-row")) return [item("steer", textOf(el.querySelector("summary")))];
  return [otherItem(el)];
}

// +root+'s shape: #history, or a fragment of a turn's elements (the reload
// check's offscreen render), or a list of elements.
export function historyShape(root) {
  const els = Array.isArray(root) ? root : [...(root?.children || [])];
  return els.flatMap(childItems);
}

const key = (it) => JSON.stringify(it);

// The longest common run of +a+ and +b+ by their items' text: the index
// pairs, in order.
function commonRun(a, b) {
  const n = a.length;
  const m = b.length;
  const len = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      len[i][j] = key(a[i]) === key(b[j]) ? len[i + 1][j + 1] + 1 : Math.max(len[i + 1][j], len[i][j + 1]);
    }
  }
  const pairs = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (key(a[i]) === key(b[j])) { pairs.push([i, j]); i++; j++; } else if (len[i + 1][j] >= len[i][j + 1]) i++; else j++;
  }
  return pairs;
}

// The differences of +a+ and +b+: between two common items, a same-kind pair
// at one place is one change ([a, b]), the rest one-sided ([a, null],
// [null, b]).
function differences(a, b) {
  const out = [];
  const gap = (as, bs) => {
    const rest = [...bs];
    for (const x of as) {
      const at = rest.findIndex((y) => y.kind === x.kind);
      if (at >= 0) out.push([x, rest.splice(at, 1)[0]]);
      else out.push([x, null]);
    }
    rest.forEach((y) => out.push([null, y]));
  };
  let i = 0;
  let j = 0;
  for (const [pi, pj] of [...commonRun(a, b), [a.length, b.length]]) {
    gap(a.slice(i, pi), b.slice(j, pj));
    i = pi + 1;
    j = pj + 1;
  }
  return out;
}

// +a+ (live) against +b+ (reloaded), +allow+ the ids of the ACCEPTED entries
// that may explain a difference.
export function compareShapes(a, b, { allow = [] } = {}) {
  const accepted = ACCEPTED.filter((entry) => allow.includes(entry.id));
  const shapes = { live: a, reloaded: b };
  const left = differences(a, b).filter(([x, y]) => !accepted.some((entry) => entry.match(x, y, shapes)));
  const kinds = [...new Set(left.map(([x, y]) => (x || y).kind))].sort();
  return { same: left.length === 0, kinds, differences: left };
}
