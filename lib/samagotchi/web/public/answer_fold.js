// Folding a long answer by hand (per viewer). A completed answer bubble
// longer than FOLD_LINES lines or FOLD_CHARS characters of its message text
// gets a fold row: a sibling just before the bubble, never inside it (the
// bubble's copy text, its claims and a live end's innerHTML stay the
// bubble's own). Folded, the bubble has the class `.folded` (CSS hides it;
// no inline style) and the row is the answer's box closed: "▸ ‹first
// line› · N lines" in the bubble's shape; unfolded, the row is that box's
// top edge, "▾ N lines", the bubble its rest (CSS joins the two). The box
// never changes shape, a click changes its height, animated
// (details_motion.js animateHeight) unless the viewer prefers no motion.
//
// A delegate report (a user line chi brought in, data-source
// "delegate_report") gets the same row, folded by default (it is written
// for the model; the reply under it is the user's summary): the row sits
// where the report sits and reads "delegate report · ‹first line› · N
// lines". Its key: a merged one's data-line-key, a wake turn's opening
// "<turn id>:prompt". A live merged report has no key until a reload.
//
// Which answers are folded is this browser's choice (localStorage through
// storage.js): one key per session holding the folded answers' keys and
// the unfolded reports' keys, the last FOLD_KEEP of each. An answer's key is its turn's id
// (data-answer-turn), a delegate report's reply its own (data-reply-key);
// a bubble with neither (an answer before any prompt, a canceled turn's
// partial) gets no row. The keys of sessions gone from the session list go
// when the list loads (sweepAnswerFolds).
//
// One observer on #history decorates every path that fills it (a reload's
// render, a live turn's end, the stage's hand-off), as copy.js does. A jump
// into a folded answer unfolds it (history_reveal.js); the row follows the
// bubble's class.
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.
import { bubbleCopyText } from "./copy.js";
import { animateHeight, canAnimate } from "./details_motion.js";
import { clip } from "./format.js";
import { readStored, removeStored, storedKeys, writeStored } from "./storage.js";

// The fold threshold: an answer longer than either gets a fold row.
export const FOLD_LINES = 25;
export const FOLD_CHARS = 2000;
// How many folded answers a session's key keeps (the oldest go first).
export const FOLD_KEEP = 200;
export const FOLD_PREFIX = "chi_answer_fold:";
// A folded row's label, at most this long (CSS cuts it to the row's width).
const LABEL_CHARS = 160;

const ROW_CLASS = "answer-fold";
// What gets a row: answers and delegate reports (user lines chi brought in).
const REPORTS = '.bubble.user[data-source="delegate_report"]';
const ANSWERS = `.bubble.output, ${REPORTS}`;
// Not done yet: still streaming.
const UNFINISHED = ".streaming";

// +text+'s lines (a trailing newline ends the last one, it adds none).
export function lineCount(text) {
  const s = String(text ?? "").replace(/\s+$/, "");
  return s ? s.split("\n").length : 0;
}

// Whether an answer of +text+ gets a fold row.
export function foldable(text) {
  const s = String(text ?? "");
  return lineCount(s) > FOLD_LINES || s.length > FOLD_CHARS;
}

// A markdown line as plain words: no heading marks, list or quote lead, no
// emphasis or code ticks.
function plainLine(line) {
  return line
    .replace(/^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)/, "")
    .replace(/(\*\*|__|`)/g, "")
    .trim();
}

// A folded answer's label: the first line of what a hook presented in its
// place (+display+: the text is that), else its first markdown heading,
// else its first text line (a code fence's marks skipped); one line.
export function foldLabel(text, { display = false } = {}) {
  const lines = String(text ?? "").replace(/\r\n?/g, "\n").split("\n");
  const texts = lines.filter((l) => l.trim() && !/^\s*(```|~~~)/.test(l));
  const heading = display ? null : texts.find((l) => /^\s{0,3}#{1,6}\s+\S/.test(l));
  return clip(plainLine(heading ?? texts[0] ?? ""), LABEL_CHARS);
}

// The row's words: folded, the label and the size; unfolded, the size
// alone (the content is right under it). +label+: the row's own (a
// report's, reportLabel), else the answer's.
export function foldRowText(text, { display = false, folded = true, label = foldLabel(text, { display }) } = {}) {
  const n = lineCount(text);
  const size = `${n} line${n === 1 ? "" : "s"}`;
  if (!folded) return { label: "", size };
  return { label, size: label ? `\u00a0\u00b7 ${size}` : size };
}

// ---- The stored choice ----

export function foldStoreKey(sessionId) {
  return sessionId ? `${FOLD_PREFIX}${sessionId}` : null;
}

// A session's entry: {root, turns, open}. `turns` holds the answers folded
// by hand (and Revise stubs opened, revise_stack.js); `open` the delegate
// reports unfolded by hand (a report folds by default). An entry written
// before `open` reads as none unfolded.
const strings = (list) => (Array.isArray(list) ? list.filter((t) => typeof t === "string") : []);

function readEntry(key) {
  try {
    const entry = JSON.parse(readStored(key, "null"));
    if (!entry || (!Array.isArray(entry.turns) && !Array.isArray(entry.open))) return null;
    return { root: typeof entry.root === "string" ? entry.root : null, turns: strings(entry.turns), open: strings(entry.open) };
  } catch (_) {
    return null;
  }
}

// The session's folded answers' keys, oldest first; [] when none or they
// can't be read.
export function readFolded(sessionId) {
  const key = foldStoreKey(sessionId);
  return (key && readEntry(key)?.turns) || [];
}

// The session's delegate reports unfolded by hand, oldest first.
export function readOpened(sessionId) {
  const key = foldStoreKey(sessionId);
  return (key && readEntry(key)?.open) || [];
}

// +list+ with +answerKey+ folded (moved to the end) or not, at most
// FOLD_KEEP long. Pure.
export function withFold(list, answerKey, folded) {
  const rest = list.filter((k) => k !== answerKey);
  return (folded ? [...rest, answerKey] : rest).slice(-FOLD_KEEP);
}

// Saves +answerKey+ folded or not for +sessionId+. +root+: the session's
// project root, kept for the sweep of a project's list.
export function writeFold(sessionId, answerKey, folded, { root = null } = {}) {
  writeList(sessionId, "turns", answerKey, folded, root);
}

// Saves the report +reportKey+ unfolded (+open+) or not for +sessionId+.
export function writeOpened(sessionId, reportKey, open, { root = null } = {}) {
  writeList(sessionId, "open", reportKey, open, root);
}

// +member+ in or out of the entry's +list+ ("turns" or "open"), the other
// list kept; the key goes when both are empty.
function writeList(sessionId, list, member, inList, root) {
  const key = foldStoreKey(sessionId);
  if (!key || !member) return;
  const entry = readEntry(key) || { turns: [], open: [] };
  const next = { turns: entry.turns, open: entry.open, [list]: withFold(entry[list], member, inList) };
  if (!next.turns.length && !next.open.length) removeStored(key);
  else writeStored(key, JSON.stringify({ root, turns: next.turns, ...(next.open.length ? { open: next.open } : {}) }));
}

// The session list loaded (+sessions+, each {id, project_root}): the fold
// keys of sessions not in it go. A project's list (+scoped+) only knows its
// own project's sessions, so there a key goes only when its project root is
// one the list shows; an unreadable key goes.
export function sweepAnswerFolds(sessions, { scoped = false } = {}) {
  const list = Array.isArray(sessions) ? sessions : [];
  const ids = new Set(list.map((s) => s?.id).filter(Boolean));
  const roots = new Set(list.map((s) => s?.project_root).filter(Boolean));
  for (const key of storedKeys(FOLD_PREFIX)) {
    if (ids.has(key.slice(FOLD_PREFIX.length))) continue;
    const entry = readEntry(key);
    if (!entry || !scoped || (entry.root && roots.has(entry.root))) removeStored(key);
  }
}

// ---- The rows ----

const isReport = (bubble) => !!bubble?.matches?.(REPORTS);

// The key an answer bubble is folded by, or null. A delegate report's: a
// merged one's line key (data-line-key, "<turn id>:input:<place>"), one
// that opened a wake turn its turn's id and ":prompt" (never the answer's
// key, the bare id).
export function answerKey(bubble) {
  if (isReport(bubble)) {
    const turn = bubble.getAttribute("data-turn-id");
    return bubble.getAttribute("data-line-key") || (turn ? `${turn}:prompt` : null);
  }
  return bubble?.getAttribute?.("data-answer-turn") || bubble?.getAttribute?.("data-reply-key") || null;
}

function answerText(bubble) {
  return bubbleCopyText(bubble);
}

// A delegate report's lines before its body: "session: <id>",
// "status: <s>", "---".
const REPORT_HEADER = /^(?:(?:session|status):\s|---\s*$)/;

// A report row's label: its origin label (the bubble's) and its first
// heading or first line after the header.
export function reportLabel(text, origin = "") {
  const body = String(text ?? "").replace(/\r\n?/g, "\n").split("\n").filter((l) => !REPORT_HEADER.test(l.trim())).join("\n");
  const first = foldLabel(body);
  return clip([origin.trim(), first].filter(Boolean).join(" · "), LABEL_CHARS);
}

function drawRow(row, bubble) {
  const folded = bubble.classList.contains("folded");
  const text = answerText(bubble);
  const report = isReport(bubble);
  const own = report ? { label: reportLabel(text, bubble.querySelector(":scope > .origin-label")?.textContent || "") } : {};
  const { label, size } = foldRowText(text, { display: bubble.hasAttribute("data-answer-display"), folded, ...own });
  const what = report ? "report" : "answer";
  row.setAttribute("aria-expanded", folded ? "false" : "true");
  row.title = folded ? `Show the ${what}` : `Fold the ${what}`;
  row.classList.toggle("folded", folded);
  row.classList.toggle("report", report);
  row.classList.toggle("steered", report && bubble.classList.contains("steered"));
  const [labelEl, sizeEl] = row.children;
  if (labelEl.textContent !== label) labelEl.textContent = label;
  if (sizeEl.textContent !== size) sizeEl.textContent = size;
}

function makeRow(doc) {
  const row = doc.createElement("button");
  row.type = "button";
  row.className = ROW_CLASS;
  const label = doc.createElement("span");
  label.className = "answer-fold-label";
  const size = doc.createElement("span");
  size.className = "answer-fold-size";
  row.append(label, size);
  return row;
}

// Runs +mutate+ and scrolls +scroller+ so +row+ stays where it was on
// screen (folding a long answer above the view would pull the page up), in
// sight at least.
export function keepRowInView(scroller, row, mutate) {
  const before = row.getBoundingClientRect().top;
  mutate();
  const after = row.getBoundingClientRect().top;
  if (scroller && after !== before) scroller.scrollTop += after - before;
  const box = row.getBoundingClientRect();
  const view = scroller?.getBoundingClientRect?.();
  if (view && (box.top < view.top || box.bottom > view.bottom)) row.scrollIntoView?.({ block: "nearest" });
}

// @param historyEl the history (#history), also its scroller
// @param sessionId () => the open session's id
// @param projectRoot () => the open session's project root, or null
// @param motion (bubble) => whether a fold or unfold animates (canAnimate)
// @return {decorate(root)} (the observer runs it; specs call it)
export function installAnswerFold({ historyEl, sessionId, projectRoot = () => null, motion = canAnimate }) {
  // Each bubble's row, and each row's bubble.
  const rows = new WeakMap();
  const bubbleOf = new WeakMap();

  function decorateBubble(bubble, stored) {
    if (bubble.parentElement !== historyEl) return;
    const key = answerKey(bubble);
    let row = rows.get(bubble);
    if (!key || bubble.matches(UNFINISHED) || (!row && !foldable(answerText(bubble)))) return;
    if (!row) {
      row = makeRow(historyEl.ownerDocument);
      rows.set(bubble, row);
      bubbleOf.set(row, bubble);
      // The stored choice, once: after that the bubble's class is the state
      // (a jump that unfolds it, history_reveal.js, isn't saved). An answer
      // is open unless folded by hand, a report folded unless opened.
      const folded = isReport(bubble) ? !stored().open.includes(key) : stored().turns.includes(key);
      if (folded) bubble.classList.add("folded");
    }
    if (bubble.previousElementSibling !== row) historyEl.insertBefore(row, bubble);
    drawRow(row, bubble);
  }

  // Rows whose bubble left (a re-render, a replaced bubble) go with it; a
  // row something was placed after (a card or a recap placed before a
  // report that opens its turn) goes back just before its bubble.
  function dropOrphans() {
    for (const row of historyEl.querySelectorAll(`:scope > .${ROW_CLASS}`)) {
      const bubble = bubbleOf.get(row);
      if (!bubble || bubble.parentElement !== historyEl) row.remove();
      else if (row.nextElementSibling !== bubble) historyEl.insertBefore(row, bubble);
    }
  }

  function decorate(root) {
    let entry = null;
    const stored = () => (entry ??= { turns: readFolded(sessionId()), open: readOpened(sessionId()) });
    if (root.matches?.(ANSWERS)) decorateBubble(root, stored);
    for (const bubble of root.querySelectorAll?.(ANSWERS) || []) decorateBubble(bubble, stored);
  }

  // Synchronous (not a frame later, as copy buttons are): the row lands in
  // the same frame as its bubble, so nothing below it shifts after a paint.
  new MutationObserver((records) => {
    const roots = new Set();
    let settle = false;
    for (const r of records) {
      if (r.type === "attributes") {
        if (r.target.matches?.(ANSWERS)) roots.add(r.target);
        continue;
      }
      if (r.removedNodes.length) settle = true;
      const answer = r.target.closest?.(ANSWERS);
      if (answer) roots.add(answer);
      for (const n of r.addedNodes) {
        if (n.nodeType !== 1 || n.classList.contains(ROW_CLASS)) continue;
        roots.add(n);
        if (r.target === historyEl) settle = true;
      }
    }
    if (settle) dropOrphans();
    for (const el of roots) if (el.isConnected) decorate(el);
  }).observe(historyEl, { childList: true, subtree: true, attributes: true, attributeFilter: ["class"] });
  decorate(historyEl);

  historyEl.addEventListener("click", (e) => {
    const row = e.target.closest?.(`.${ROW_CLASS}`);
    const bubble = row && bubbleOf.get(row);
    if (!bubble) return;
    e.preventDefault();
    const folded = !bubble.classList.contains("folded");
    const settle = () => keepRowInView(historyEl, row, () => {
      bubble.classList.toggle("folded", folded);
      drawRow(row, bubble);
    });
    if (!motion(bubble)) settle();
    else if (folded) animateHeight(bubble, bubble.offsetHeight, 0, { fade: true }).then(settle);
    else {
      settle();
      animateHeight(bubble, 0, bubble.offsetHeight, { fade: true });
    }
    // An answer's choice is its fold, a report's its unfold (D2: the default differs).
    if (isReport(bubble)) writeOpened(sessionId(), answerKey(bubble), !folded, { root: projectRoot() });
    else writeFold(sessionId(), answerKey(bubble), folded, { root: projectRoot() });
  });

  return { decorate };
}
