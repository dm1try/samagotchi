// The notes row (quiet_notes.js): what folds, the row's words, and the row on
// the page (one per stretch, tied to its first item, never stored).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

if (!("MutationObserver" in globalThis)) globalThis.MutationObserver = window.MutationObserver;

const {
  HIDDEN_CLASS, QUIET, installQuietNotes, quietRuns, revealQuiet, rowLabel, rowTemplate,
} = await import("../../../lib/samagotchi/web/public/quiet_notes.js");
const { render } = await import("../../../lib/samagotchi/web/public/vendor/lit-html.js");

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

const LINE = (text, warn = false) => `<div class="bubble hook-notice${warn ? " warn" : ""}">${text}</div>`;
const NOTE = (label = "context claude-inbox", text = "n") => `<div class="bubble note"><div class="note-line">note from ${label}</div><div class="note-text">${text}</div></div>`;
const OBJECTIVES = '<div class="bubble note objectives-entry"><span class="obj-entry-label">Objectives</span></div>';
const STEER = '<details class="bubble steer-row"><summary>cost-cap nudged the model</summary><div class="steer-text">x</div></details>';
const ANSWER = '<div class="bubble output">answer</div>';
const TIMING = '<div class="turn-timing">turn 1 · 3 s</div>';

function history(markup = "") {
  const el = document.createElement("div");
  el.id = "history";
  el.innerHTML = markup;
  document.body.append(el);
  return el;
}

function fragment(markup) {
  const el = document.createElement("div");
  el.innerHTML = markup;
  return [...el.children];
}

const rows = (h) => [...h.querySelectorAll(":scope > .quiet-notes")];
const hidden = (h) => [...h.querySelectorAll(`:scope > .${HIDDEN_CLASS}`)];
// The row's spans as read (CSS spaces them).
const words = (row) => [...row.querySelectorAll("span")].map((s) => s.textContent).join(" ");

test("the closed list: background lines, notes, objectives and a nudge fold; what someone says doesn't, and ends a stretch", () => {
  const folds = fragment(LINE("a: x") + LINE("b: x", true) + NOTE() + OBJECTIVES + STEER);
  for (const el of folds) assert.ok(el.matches(QUIET), el.className);
  const stays = [
    '<div class="bubble note turn-start" data-opening-id="T2"><div class="note-line">note from context todo</div></div>',
    '<div class="bubble note peer-answer"><div class="note-text">VERDICT OK</div></div>',
    '<div class="bubble hook-notice empty-answer">no answer: the model returned nothing</div>',
    '<div class="plugin-card">card</div>',
    '<div class="bubble guardrail-warning">guardrails: x</div>',
    '<div class="bubble command">/help</div>',
    '<div class="bubble user">prompt</div>',
  ];
  for (const markup of stays) {
    const [el] = fragment(markup);
    assert.ok(!el.matches(QUIET), markup);
    const runs = quietRuns(fragment(LINE("a: 1") + markup + LINE("b: 2")));
    assert.equal(runs.length, 2, markup);
  }
});

test("the label: a count, the names unique in order, ⚠ only from the warn class", () => {
  const items = fragment(NOTE("context claude-inbox") + LINE("source-links: sources: JIRA-1 → x") + LINE("skills: a step failed", true)
    + LINE("skills: another") + NOTE("session ab12cd (~/projects/x)") + LINE("↻ empty answer, asking again") + NOTE("slack")
    + '<div class="bubble note"><div class="note-line">note</div></div>' + OBJECTIVES + STEER
    + '<details class="bubble steer-row"><summary>nudged the model</summary></details>');
  assert.deepEqual(rowLabel(items), {
    count: 11,
    names: ["claude-inbox", "source-links", "skills", "session ab12cd", "chi", "slack", "context", "objectives", "cost-cap", "nudge"],
    warn: 1,
  });
  assert.equal(rowLabel(fragment(LINE("skills: a step failed"))).warn, 0, "a line that says failed without the class gets no mark");
  const row = document.createElement("button");
  render(rowTemplate({ count: 1, names: ["source-links"], warn: 0 }), row);
  assert.equal(words(row), "1 note · source-links");
  assert.ok(row.querySelector(".qn-warn") === null);
  render(rowTemplate({ count: 3, names: ["a", "b"], warn: 2 }), row);
  assert.equal(words(row), "3 notes · a, b ⚠ 2");
  assert.equal(row.querySelector(".qn-warn").textContent, "⚠ 2");
});

test("installed: two lines and a note after an answer are one closed row before the first; a click opens it, another closes it", async () => {
  const h = history(ANSWER + TIMING);
  installQuietNotes({ historyEl: h });
  h.insertAdjacentHTML("beforeend", LINE("source-links: x") + LINE("skills: y", true) + NOTE());
  await tick();
  const [row] = rows(h);
  assert.equal(rows(h).length, 1);
  assert.equal(row.tagName, "BUTTON");
  assert.equal(row.type, "button");
  assert.equal(row.previousElementSibling.className, "turn-timing");
  assert.ok(row.nextElementSibling.matches(".hook-notice"));
  assert.equal(row.getAttribute("aria-expanded"), "false");
  assert.ok(row.classList.contains("warn"));
  assert.equal(words(row), "3 notes · source-links, skills, claude-inbox ⚠ 1");
  assert.equal(hidden(h).length, 3);
  row.click();
  assert.equal(row.getAttribute("aria-expanded"), "true");
  assert.ok(row.classList.contains("open"));
  assert.equal(hidden(h).length, 0);
  row.click();
  assert.equal(row.getAttribute("aria-expanded"), "false");
  assert.equal(hidden(h).length, 3);
});

test("growing while open: a new item shows, the count follows, the row stays open; closed, it joins hidden", async () => {
  const h = history(ANSWER + LINE("a: 1") + LINE("b: 2") + NOTE());
  installQuietNotes({ historyEl: h });
  const [row] = rows(h);
  row.click();
  h.insertAdjacentHTML("beforeend", LINE("c: 4"));
  await tick();
  assert.equal(rows(h).length, 1);
  assert.ok(row.classList.contains("open"));
  assert.equal(hidden(h).length, 0);
  assert.match(words(row), /^4 notes · a, b, claude-inbox, c$/);
  row.click();
  h.insertAdjacentHTML("beforeend", LINE("d: 5"));
  await tick();
  assert.equal(hidden(h).length, 5);
});

test("a timing line passes through a stretch; a divider or a peer's answer splits it", () => {
  const passed = history(ANSWER + LINE("a: 1") + TIMING + LINE("b: 2"));
  installQuietNotes({ historyEl: passed });
  assert.equal(rows(passed).length, 1);
  assert.equal(words(rows(passed)[0]), "2 notes · a, b");
  assert.ok(!passed.querySelector(".turn-timing").classList.contains(HIDDEN_CLASS), "the timing line stays in sight");
  for (const split of ['<div class="time-gap">── 14:32 ──</div>', '<div class="bubble note peer-answer"><div class="note-text">OK</div></div>']) {
    const h = history(LINE("a: 1") + split + LINE("b: 2"));
    installQuietNotes({ historyEl: h });
    assert.deepEqual(rows(h).map(words), ["1 note · a", "1 note · b"], split);
  }
});

test("one note gets a row too", () => {
  const h = history(ANSWER + LINE("source-links: x"));
  installQuietNotes({ historyEl: h });
  assert.equal(words(rows(h)[0]), "1 note · source-links");
});

test("tied to its first item: something placed between the row and it puts the row back, still open", async () => {
  const h = history(ANSWER + LINE("a: 1") + NOTE());
  installQuietNotes({ historyEl: h });
  const [row] = rows(h);
  row.click();
  const first = row.nextElementSibling;
  const recap = document.createElement("details");
  recap.className = "bubble recap";
  h.insertBefore(recap, first);
  await tick();
  assert.equal(rows(h).length, 1);
  assert.equal(rows(h)[0], row);
  assert.equal(row.nextElementSibling, first);
  assert.equal(recap.nextElementSibling, row);
  assert.ok(row.classList.contains("open"));
  // A new first item before it: the same row, still open.
  h.insertBefore(document.createRange().createContextualFragment(LINE("z: 0")), row);
  await tick();
  assert.equal(rows(h).length, 1);
  assert.equal(rows(h)[0], row);
  assert.ok(row.nextElementSibling.textContent === "z: 0");
  assert.ok(row.classList.contains("open"));
});

test("cleanup: a stretch's items gone take its row; a re-render draws the rows closed", async () => {
  const h = history(ANSWER + LINE("a: 1") + NOTE());
  installQuietNotes({ historyEl: h });
  for (const el of [...h.querySelectorAll(".hook-notice, .note")]) el.remove();
  await tick();
  assert.equal(rows(h).length, 0);
  h.insertAdjacentHTML("beforeend", LINE("a: 1"));
  await tick();
  rows(h)[0].click();
  h.replaceChildren(...fragment(ANSWER + LINE("a: 1") + LINE("b: 2")));
  await tick();
  assert.equal(rows(h).length, 1);
  assert.ok(!rows(h)[0].classList.contains("open"));
  assert.equal(hidden(h).length, 2);
});

test("no self-feeding: a settle that changes nothing writes nothing", async () => {
  const h = history(ANSWER + LINE("a: 1", true) + NOTE() + TIMING + LINE("b: 2"));
  const quiet = installQuietNotes({ historyEl: h });
  rows(h)[0].click();
  await tick();
  const seen = [];
  const watch = new MutationObserver((records) => seen.push(...records));
  watch.observe(h, { childList: true, subtree: true, attributes: true, characterData: true });
  quiet.settle();
  await tick();
  assert.deepEqual(seen.map((r) => r.type), [], "open");
  watch.disconnect();
  rows(h)[0].click();
  await tick();
  watch.observe(h, { childList: true, subtree: true, attributes: true, characterData: true });
  quiet.settle();
  await tick();
  assert.deepEqual(seen.map((r) => r.type), [], "closed");
  watch.disconnect();
});

test("an item that arrives with ts-arrive and is hidden loses it; its new row takes it", async () => {
  const h = history(ANSWER);
  installQuietNotes({ historyEl: h });
  const [line] = fragment(LINE("a: 1"));
  h.appendChild(line);
  line.classList.add("ts-arrive");
  await tick();
  assert.ok(line.classList.contains(HIDDEN_CLASS));
  assert.ok(!line.classList.contains("ts-arrive"));
  assert.ok(rows(h)[0].classList.contains("ts-arrive"));
});

test("an item that stops folding (it opens a turn now) is shown again and its row goes", async () => {
  const h = history(ANSWER + NOTE());
  installQuietNotes({ historyEl: h });
  const note = h.querySelector(".note");
  note.classList.add("turn-start");
  h.appendChild(document.createElement("div"));
  await tick();
  assert.equal(rows(h).length, 0);
  assert.ok(!note.classList.contains(HIDDEN_CLASS));
});

test("revealQuiet opens the row over a hidden item; a shown item is left as it is", () => {
  const h = history(ANSWER + LINE("a: 1") + NOTE());
  installQuietNotes({ historyEl: h });
  const note = h.querySelector(".note .note-text");
  revealQuiet(note);
  assert.ok(rows(h)[0].classList.contains("open"));
  revealQuiet(note);
  assert.ok(rows(h)[0].classList.contains("open"), "a second reveal doesn't close it");
  revealQuiet(h.querySelector(".output"));
});
