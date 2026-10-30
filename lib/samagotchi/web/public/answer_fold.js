// Folding a long answer by hand (per viewer). A completed answer bubble
// longer than FOLD_LINES lines or FOLD_CHARS characters of its message text
// gets a fold row: a sibling just before the bubble, never inside it (the
// bubble's copy text, its claims and a live end's innerHTML stay the
// bubble's own). Folded, the bubble has the class `.folded` (CSS hides it;
// no inline style); the row reads its first line and its size, "▸
// ‹first line› · N lines", folded or not: unfolded it is the bubble's header,
// flush on top of it, its bar the bubble's.
//
// Which answers are folded is this browser's choice (localStorage through
// storage.js): one key per session holding the folded answers' keys, the
// last FOLD_KEEP of them. An answer's key is its turn's id
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
const ANSWERS = ".bubble.output";
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

// The row's words, folded or not: the label and the size (an open row is
// the answer's header, as an open steps block keeps its summary).
export function foldRowText(text, { display = false } = {}) {
  const n = lineCount(text);
  const size = `${n} line${n === 1 ? "" : "s"}`;
  const label = foldLabel(text, { display });
  return { label, size: label ? `\u00a0\u00b7 ${size}` : size };
}

// ---- The stored choice ----

export function foldStoreKey(sessionId) {
  return sessionId ? `${FOLD_PREFIX}${sessionId}` : null;
}

function readEntry(key) {
  try {
    const entry = JSON.parse(readStored(key, "null"));
    if (!entry || !Array.isArray(entry.turns)) return null;
    return { root: typeof entry.root === "string" ? entry.root : null, turns: entry.turns.filter((t) => typeof t === "string") };
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

// +list+ with +answerKey+ folded (moved to the end) or not, at most
// FOLD_KEEP long. Pure.
export function withFold(list, answerKey, folded) {
  const rest = list.filter((k) => k !== answerKey);
  return (folded ? [...rest, answerKey] : rest).slice(-FOLD_KEEP);
}

// Saves +answerKey+ folded or not for +sessionId+. +root+: the session's
// project root, kept for the sweep of a project's list.
export function writeFold(sessionId, answerKey, folded, { root = null } = {}) {
  const key = foldStoreKey(sessionId);
  if (!key || !answerKey) return;
  const turns = withFold(readFolded(sessionId), answerKey, folded);
  if (!turns.length) removeStored(key);
  else writeStored(key, JSON.stringify({ root, turns }));
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

// The key an answer bubble is folded by, or null.
export function answerKey(bubble) {
  return bubble?.getAttribute?.("data-answer-turn") || bubble?.getAttribute?.("data-reply-key") || null;
}

function answerText(bubble) {
  return bubbleCopyText(bubble);
}

function drawRow(row, bubble) {
  const folded = bubble.classList.contains("folded");
  const text = answerText(bubble);
  const { label, size } = foldRowText(text, { display: bubble.hasAttribute("data-answer-display") });
  row.setAttribute("aria-expanded", folded ? "false" : "true");
  row.title = folded ? "Show the answer" : "Fold the answer";
  row.classList.toggle("folded", folded);
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
// @return {decorate(root)} (the observer runs it; specs call it)
export function installAnswerFold({ historyEl, sessionId, projectRoot = () => null }) {
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
      // (a jump that unfolds it, history_reveal.js, isn't saved).
      if (stored().includes(key)) bubble.classList.add("folded");
    }
    if (bubble.previousElementSibling !== row) historyEl.insertBefore(row, bubble);
    drawRow(row, bubble);
  }

  // Rows whose bubble left (a re-render, a replaced bubble) go with it.
  function dropOrphans() {
    for (const row of historyEl.querySelectorAll(`:scope > .${ROW_CLASS}`)) {
      const bubble = bubbleOf.get(row);
      if (!bubble || bubble.parentElement !== historyEl) row.remove();
      else if (row.nextElementSibling !== bubble) historyEl.insertBefore(row, bubble);
    }
  }

  function decorate(root) {
    let folded = null;
    const stored = () => (folded ??= readFolded(sessionId()));
    if (root.matches?.(ANSWERS)) decorateBubble(root, stored);
    for (const bubble of root.querySelectorAll?.(ANSWERS) || []) decorateBubble(bubble, stored);
  }

  // Synchronous (not a frame later, as copy buttons are): the row lands in
  // the same frame as its bubble, so nothing below it shifts after a paint.
  new MutationObserver((records) => {
    const roots = new Set();
    let removed = false;
    for (const r of records) {
      if (r.type === "attributes") {
        if (r.target.matches?.(ANSWERS)) roots.add(r.target);
        continue;
      }
      if (r.removedNodes.length) removed = true;
      const answer = r.target.closest?.(ANSWERS);
      if (answer) roots.add(answer);
      for (const n of r.addedNodes) if (n.nodeType === 1 && !n.classList.contains(ROW_CLASS)) roots.add(n);
    }
    if (removed) dropOrphans();
    for (const el of roots) if (el.isConnected) decorate(el);
  }).observe(historyEl, { childList: true, subtree: true, attributes: true, attributeFilter: ["class"] });
  decorate(historyEl);

  historyEl.addEventListener("click", (e) => {
    const row = e.target.closest?.(`.${ROW_CLASS}`);
    const bubble = row && bubbleOf.get(row);
    if (!bubble) return;
    e.preventDefault();
    const folded = !bubble.classList.contains("folded");
    keepRowInView(historyEl, row, () => {
      bubble.classList.toggle("folded", folded);
      drawRow(row, bubble);
    });
    writeFold(sessionId(), answerKey(bubble), folded, { root: projectRoot() });
  });

  return { decorate };
}
