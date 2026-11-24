// The history's background items fold into one closed row per stretch:
// anything nobody says in the conversation (a plugin's or chi's own line
// shown on its own, a context note that starts nothing, an objectives line,
// a plugin's nudge) folds; what someone says stays (the prompt, the answer,
// a peer's answer, a note that opens a wake turn). A stretch is a run of
// those items side by side among #history's children; the turn's timing
// line passes through one, anything else ends it. Its row reads
// "▸ 3 notes · claude-inbox, source-links, skills" (and "⚠ N" for its warn
// lines), closed; a click (Enter/Space: it is a button) opens it and the
// items show under it as they are.
//
// Modelled on answer_fold.js: the row is a sibling just before the
// stretch's first item, never a wrapper (the bubbles keep their place,
// copy text and observers); the items are hidden by a class
// (`.quiet-hidden`, CSS). Each row is tied to its first item (rowOf /
// firstOf), so a row something was placed after (a recap, a snapshot's
// card) goes back before its item, open or not. The open state is the
// row's class only, never stored: a re-render draws the rows closed.
//
// One observer on #history (its own children only) settles every path that
// fills it; a settle that changes nothing writes nothing (the other
// observers on #history see class and subtree writes).
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.
import { html, render, nothing } from "./vendor/lit-html.js";

// What folds: a direct child of #history that is one of these.
export const QUIET = ".bubble.hook-notice:not(.empty-answer), .bubble.note:not(.turn-start):not(.peer-answer), .bubble.steer-row";
// What a stretch passes over (it stays visible).
export const PASS = ".turn-timing";
export const ROW_CLASS = "quiet-notes";
export const HIDDEN_CLASS = "quiet-hidden";

const ARRIVE = "ts-arrive";
const ROW = `.${ROW_CLASS}`;

// The stretches over +children+ (an element list, in order): [{ items }].
// Pure.
export function quietRuns(children) {
  const runs = [];
  let run = null;
  for (const el of children) {
    if (el.nodeType !== 1 || el.matches(ROW) || el.matches(PASS)) continue;
    if (!el.matches(QUIET)) {
      run = null;
      continue;
    }
    if (!run) runs.push((run = { items: [] }));
    run.items.push(el);
  }
  return runs;
}

const squash = (text) => String(text ?? "").replace(/\s+/g, " ").trim();

// One item's name on the row.
function itemName(el) {
  if (el.matches(".objectives-entry")) return "objectives";
  if (el.matches(".steer-row")) {
    const said = squash(el.querySelector("summary")?.textContent);
    return said.endsWith(" nudged the model") ? said.slice(0, -" nudged the model".length) : "nudge";
  }
  if (el.matches(".hook-notice")) {
    // "<bundle or hook>: text"; chi's own lines ("↻ empty answer, asking
    // again") name no one.
    const text = squash(el.textContent);
    const at = text.indexOf(": ");
    const who = at > 0 ? text.slice(0, at) : "";
    return /^[A-Za-z0-9][\w./-]*$/.test(who) ? who : "chi";
  }
  const line = squash(el.querySelector(".note-line")?.textContent) || "note";
  if (line === "note") return "context";
  const from = line.replace(/^note from /, "").replace(/^context /, "");
  // Another session's note (ContextNote.label): "session <id6> (<~cwd>)".
  const session = /^(session \S+) \(.*\)$/.exec(from);
  return session ? session[1] : from;
}

// A row's words: how many items, their names (unique, in order) and how
// many are warnings (the `warn` class, never the text). Pure.
export function rowLabel(items) {
  const names = [];
  let warn = 0;
  for (const el of items) {
    const name = itemName(el);
    if (!names.includes(name)) names.push(name);
    if (el.classList.contains("warn")) warn += 1;
  }
  return { count: items.length, names, warn };
}

export function rowTemplate({ count, names, warn }) {
  return html`<span class="qn-count">${count} ${count === 1 ? "note" : "notes"}</span><span class="qn-names">· ${names.join(", ")}</span>${warn > 0 ? html`<span class="qn-warn">⚠ ${warn}</span>` : nothing}`;
}

// +el+ hidden in a closed row: that row opens. Nothing otherwise. A jump
// goes through history_reveal.js revealInHistory, which calls this.
export function revealQuiet(el) {
  const hidden = el?.closest?.(`.${HIDDEN_CLASS}`);
  if (!hidden) return;
  let row = hidden.previousElementSibling;
  while (row && !row.matches(ROW)) row = row.previousElementSibling;
  if (row && !row.classList.contains("open")) row.click();
}

// @param historyEl the history (#history)
// @return {settle()} (the observer runs it; specs call it)
export function installQuietNotes({ historyEl }) {
  // Each stretch's first item's row, and each row's first item.
  const rowOf = new WeakMap();
  const firstOf = new WeakMap();
  // The words a row was last drawn with.
  const drawn = new WeakMap();

  function makeRow(first) {
    const row = historyEl.ownerDocument.createElement("button");
    row.type = "button";
    row.className = ROW_CLASS;
    row.setAttribute("aria-expanded", "false");
    // The stretch's arrival plays on its row (its items are hidden).
    if (first.classList.contains(ARRIVE)) {
      row.classList.add(ARRIVE);
      row.addEventListener("animationend", () => row.classList.remove(ARRIVE), { once: true });
    }
    return row;
  }

  // A row already in the stretch's span (between its items, or just before
  // its first) that no other stretch took: the stretch's first item changed.
  function rowInSpan(items, taken) {
    const last = items[items.length - 1];
    const before = items[0].previousElementSibling;
    if (before?.matches(ROW) && firstOf.has(before) && !taken.has(before)) return before;
    for (let el = items[0]; el && el !== last; el = el.nextElementSibling) {
      if (el.matches(ROW) && firstOf.has(el) && !taken.has(el)) return el;
    }
    return null;
  }

  function drawRow(row, items) {
    const label = rowLabel(items);
    const words = JSON.stringify(label);
    if (drawn.get(row) !== words) {
      render(rowTemplate(label), row);
      drawn.set(row, words);
    }
    const open = row.classList.contains("open");
    const expanded = open ? "true" : "false";
    if (row.getAttribute("aria-expanded") !== expanded) row.setAttribute("aria-expanded", expanded);
    if (row.classList.contains("warn") !== label.warn > 0) row.classList.toggle("warn", label.warn > 0);
    for (const item of items) {
      if (item.classList.contains(HIDDEN_CLASS) === !open) continue;
      item.classList.toggle(HIDDEN_CLASS, !open);
      // A hidden element never fires animationend: its slide-up would play
      // the first time the row opens.
      if (!open && item.classList.contains(ARRIVE)) item.classList.remove(ARRIVE);
    }
  }

  function settle() {
    const taken = new Set();
    const shown = new Set();
    for (const { items } of quietRuns(historyEl.children)) {
      const first = items[0];
      let row = rowOf.get(first);
      if (!row || row.parentElement !== historyEl || taken.has(row)) row = rowInSpan(items, taken);
      if (!row) row = makeRow(first);
      if (firstOf.get(row) !== first) {
        firstOf.set(row, first);
        rowOf.set(first, row);
      }
      if (first.previousElementSibling !== row) historyEl.insertBefore(row, first);
      taken.add(row);
      drawRow(row, items);
      for (const item of items) shown.add(item);
    }
    for (const row of historyEl.querySelectorAll(`:scope > ${ROW}`)) if (!taken.has(row)) row.remove();
    // An item no stretch holds any more (it changed kind): shown again.
    for (const el of historyEl.querySelectorAll(`:scope > .${HIDDEN_CLASS}`)) if (!shown.has(el)) el.classList.remove(HIDDEN_CLASS);
  }

  const ours = (n) => n.nodeType !== 1 || n.classList.contains(ROW_CLASS);
  new MutationObserver((records) => {
    if (records.some((r) => [...r.addedNodes, ...r.removedNodes].some((n) => !ours(n)))) settle();
  }).observe(historyEl, { childList: true });
  settle();

  historyEl.addEventListener("click", (e) => {
    const row = e.target.closest?.(ROW);
    if (!row || row.parentElement !== historyEl || !firstOf.has(row)) return;
    e.preventDefault();
    const open = !row.classList.contains("open");
    row.classList.toggle("open", open);
    settle();
  });

  return { settle };
}
