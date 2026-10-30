// Folding a long answer by hand (answer_fold.js): the threshold, the row's
// label, the stored choice and its sweep, and the row on the page.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

for (const k of ["MutationObserver", "localStorage"]) {
  if (!(k in globalThis)) globalThis[k] = window[k];
}

const {
  FOLD_CHARS, FOLD_KEEP, FOLD_LINES, FOLD_PREFIX, foldLabel, foldRowText, foldable, installAnswerFold, lineCount,
  readFolded, sweepAnswerFolds, withFold, writeFold,
} = await import("../../../lib/samagotchi/web/public/answer_fold.js");
const { revealInHistory } = await import("../../../lib/samagotchi/web/public/history_reveal.js");
const { turnAnswerEl } = await import("../../../lib/samagotchi/web/public/cards_place.js");

const lines = (n, word = "line") => Array.from({ length: n }, (_, i) => `${word} ${i + 1}`).join("\n");
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function clearFolds() {
  for (let i = localStorage.length - 1; i >= 0; i--) {
    const key = localStorage.key(i);
    if (key?.startsWith(FOLD_PREFIX)) localStorage.removeItem(key);
  }
}

test("foldable: over FOLD_LINES lines or FOLD_CHARS characters, not at them", () => {
  assert.equal(foldable(lines(FOLD_LINES)), false);
  assert.equal(foldable(lines(FOLD_LINES + 1)), true);
  assert.equal(foldable(`${lines(FOLD_LINES)}\n\n\n`), false, "trailing blank lines don't count");
  assert.equal(foldable("x".repeat(FOLD_CHARS)), false);
  assert.equal(foldable("x".repeat(FOLD_CHARS + 1)), true);
  assert.equal(foldable(""), false);
  assert.equal(lineCount("a\nb\n"), 2);
  assert.equal(lineCount(""), 0);
});

test("foldLabel: the first heading, else the first text line, as plain words; a display's first line first", () => {
  assert.equal(foldLabel("Intro words\n\n## PROJ-123: **Retry** on `webhook`\n\nbody"), "PROJ-123: Retry on webhook");
  assert.equal(foldLabel("\n\n- **Summary**: done\n- more"), "Summary: done");
  assert.equal(foldLabel("```ruby\ncode here\n```\n"), "code here");
  assert.equal(foldLabel("Ticket ready\n# Heading", { display: true }), "Ticket ready");
  assert.equal(foldLabel(""), "");
  const long = foldLabel(`# ${"word ".repeat(80)}`);
  assert.ok(long.length <= 160 && long.endsWith("…"));
});

test("foldRowText: the label and ' · N lines', folded or not", () => {
  const text = `# Title\n${lines(30)}`;
  assert.deepEqual(foldRowText(text), { label: "Title", size: "\u00a0\u00b7 31 lines" });
  assert.deepEqual(foldRowText(text, { folded: false }), { label: "Title", size: " · 31 lines" });
  assert.deepEqual(foldRowText("only\n"), { label: "only", size: "\u00a0\u00b7 1 line" });
});

test("withFold: a fold moves to the end, an unfold drops it, at most FOLD_KEEP kept (the oldest go)", () => {
  assert.deepEqual(withFold(["a", "b"], "a", true), ["b", "a"]);
  assert.deepEqual(withFold(["a", "b"], "a", false), ["b"]);
  const full = Array.from({ length: FOLD_KEEP }, (_, i) => `t${i}`);
  const next = withFold(full, "new", true);
  assert.equal(next.length, FOLD_KEEP);
  assert.equal(next[0], "t1");
  assert.equal(next.at(-1), "new");
});

test("writeFold / readFolded: per session; the last unfold removes the key", () => {
  clearFolds();
  writeFold("s1", "t1", true, { root: "/p" });
  writeFold("s1", "t2", true, { root: "/p" });
  writeFold("s2", "t9", true);
  assert.deepEqual(readFolded("s1"), ["t1", "t2"]);
  assert.deepEqual(readFolded("s2"), ["t9"]);
  assert.deepEqual(JSON.parse(localStorage.getItem(`${FOLD_PREFIX}s1`)).root, "/p");
  writeFold("s2", "t9", false);
  assert.equal(localStorage.getItem(`${FOLD_PREFIX}s2`), null);
  localStorage.setItem(`${FOLD_PREFIX}s3`, "{not json");
  assert.deepEqual(readFolded("s3"), []);
  assert.deepEqual(readFolded(null), []);
  clearFolds();
});

test("sweepAnswerFolds: an unscoped list sweeps every missing session; a project's list only its own project's", () => {
  clearFolds();
  writeFold("here", "t", true, { root: "/a" });
  writeFold("gone-a", "t", true, { root: "/a" });
  writeFold("gone-b", "t", true, { root: "/b" });
  writeFold("gone-none", "t", true);
  localStorage.setItem(`${FOLD_PREFIX}broken`, "nope");
  localStorage.setItem("chi_theme", "dark");
  sweepAnswerFolds([{ id: "here", project_root: "/a" }], { scoped: true });
  assert.deepEqual(readFolded("here"), ["t"]);
  assert.deepEqual(readFolded("gone-a"), []);
  assert.deepEqual(readFolded("gone-b"), ["t"], "another project's session isn't in this list");
  assert.deepEqual(readFolded("gone-none"), ["t"]);
  assert.equal(localStorage.getItem(`${FOLD_PREFIX}broken`), null);
  sweepAnswerFolds([{ id: "here", project_root: "/a" }]);
  assert.deepEqual(readFolded("gone-b"), []);
  assert.deepEqual(readFolded("gone-none"), []);
  assert.deepEqual(readFolded("here"), ["t"]);
  assert.equal(localStorage.getItem("chi_theme"), "dark");
  localStorage.removeItem("chi_theme");
  clearFolds();
});

function page({ session = "s1" } = {}) {
  const history = document.createElement("div");
  document.body.append(history);
  const fold = installAnswerFold({ historyEl: history, sessionId: () => session, projectRoot: () => "/p" });
  return { history, fold };
}

function bubble(text, { turn = "turn-1", cls = "" } = {}) {
  const el = document.createElement("div");
  el.className = `bubble output${cls}`;
  if (turn) el.dataset.answerTurn = turn;
  el.setAttribute("data-copy-source", text);
  el.textContent = text;
  return el;
}

test("the page: a long completed answer gets a row just before it; a short, running or keyless one none", async () => {
  clearFolds();
  const { history } = page();
  const long = bubble(`# The ticket\n${lines(40)}`);
  const short = bubble("short", { turn: "turn-2" });
  const streaming = bubble(lines(40), { turn: "turn-3", cls: " streaming" });
  const keyless = bubble(lines(40), { turn: null });
  history.append(long, short, streaming, keyless);
  await tick();
  const rows = history.querySelectorAll(".answer-fold");
  assert.equal(rows.length, 1);
  assert.ok(long.previousElementSibling === rows[0]);
  assert.equal(rows[0].getAttribute("aria-expanded"), "true");
  assert.equal(rows[0].textContent, "The ticket\u00a0\u00b7 41 lines");
  history.remove();
});

test("the page: a click folds (saved, the row reads the label), again unfolds; a reload's bubble comes back folded", async () => {
  clearFolds();
  const first = page();
  const answer = bubble(`intro\n## PROJ-1: Retry\n${lines(40)}`);
  first.history.append(answer);
  await tick();
  const row = answer.previousElementSibling;
  row.click();
  assert.ok(answer.classList.contains("folded"));
  assert.equal(row.getAttribute("aria-expanded"), "false");
  assert.equal(row.textContent, "PROJ-1: Retry\u00a0\u00b7 42 lines");
  assert.deepEqual(readFolded("s1"), ["turn-1"]);
  first.history.remove();

  const again = page();
  const reloaded = bubble(`intro\n## PROJ-1: Retry\n${lines(40)}`);
  again.history.append(reloaded);
  await tick();
  assert.ok(reloaded.classList.contains("folded"));
  reloaded.previousElementSibling.click();
  assert.ok(!reloaded.classList.contains("folded"));
  assert.deepEqual(readFolded("s1"), []);
  again.history.remove();
  clearFolds();
});

test("the page: a report reply folds by its own key; a removed bubble takes its row", async () => {
  clearFolds();
  const { history } = page();
  const reply = bubble(lines(30), { turn: null, cls: " report-reply" });
  reply.dataset.replyKey = "turn-1:report:3";
  history.append(reply);
  await tick();
  reply.previousElementSibling.click();
  assert.deepEqual(readFolded("s1"), ["turn-1:report:3"]);
  reply.remove();
  await tick();
  assert.equal(history.querySelectorAll(".answer-fold").length, 0);
  history.remove();
  clearFolds();
});

test("revealInHistory: a jump into a folded answer unfolds it, the row follows, nothing saved", async () => {
  clearFolds();
  writeFold("s1", "turn-1", true);
  const { history } = page();
  const answer = bubble(lines(40));
  const claim = document.createElement("p");
  answer.append(claim);
  history.append(answer);
  await tick();
  assert.ok(answer.classList.contains("folded"));
  revealInHistory(claim);
  await tick();
  assert.ok(!answer.classList.contains("folded"));
  assert.equal(answer.previousElementSibling.getAttribute("aria-expanded"), "true");
  assert.deepEqual(readFolded("s1"), ["turn-1"]);
  history.remove();
  clearFolds();
});

test("turnAnswerEl: a card placed before a turn's answer goes before its fold row", () => {
  const prompt = document.createElement("div");
  prompt.className = "bubble user";
  const row = document.createElement("button");
  row.className = "answer-fold";
  const answer = bubble("x");
  const history = document.createElement("div");
  history.append(prompt, row, answer);
  assert.ok(turnAnswerEl([prompt, row, answer]) === row);
  row.remove();
  assert.ok(turnAnswerEl([prompt, answer]) === answer);
});
