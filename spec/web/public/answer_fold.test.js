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

test("foldRowText: folded the label and ' · N lines', unfolded the size only (a report's own label too)", () => {
  const text = `# Title\n${lines(30)}`;
  assert.deepEqual(foldRowText(text), { label: "Title", size: "\u00a0\u00b7 31 lines" });
  assert.deepEqual(foldRowText(text, { folded: false }), { label: "", size: "31 lines" });
  assert.deepEqual(foldRowText(text, { folded: false, label: "delegate report · Title" }), { label: "", size: "31 lines" });
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

// +motion+: whether a click animates (off: the fold lands at once, as a
// viewer who prefers no motion sees it).
function page({ session = "s1", motion = () => false } = {}) {
  const history = document.createElement("div");
  document.body.append(history);
  const fold = installAnswerFold({ historyEl: history, sessionId: () => session, projectRoot: () => "/p", motion });
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
  assert.equal(rows[0].textContent, "41 lines");
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

// ---- Delegate reports (folded by default) ----

const { answerKey, readOpened, reportLabel, writeOpened } = await import("../../../lib/samagotchi/web/public/answer_fold.js");
const { elementOf, userBubbleTemplate } = await import("../../../lib/samagotchi/web/public/turn_html.js");

const REPORT = `session: 6f2ec1d6-41b0-4c50-8fd8-83a43e56d0d9\nstatus: answered\n---\n## Rebase result\n${lines(40)}`;

// A report's bubble as the reload draws it: merged (its line key, steered)
// or opening its wake turn (its turn id).
function report(text = REPORT, { lineKey = null, turnId = null } = {}) {
  return elementOf(userBubbleTemplate({ content: text, source: "delegate_report", turn_id: turnId }, {
    label: "delegate report", state: lineKey ? "steered" : null, lineKey,
  }));
}

test("reportLabel: the origin label and the first heading or line after the session/status/--- header", () => {
  assert.equal(reportLabel(REPORT, "delegate report"), "delegate report · Rebase result");
  assert.equal(reportLabel("session: x\nstatus: question\nThe child asks: which branch?", "delegate report"),
               "delegate report · The child asks: which branch?");
  assert.equal(reportLabel("session: x\nstatus: answered\n---\n", ""), "");
});

test("answerKey: a merged report's line key, a wake turn's report its turn id and :prompt; an answer's stays its own", () => {
  assert.equal(answerKey(report(REPORT, { lineKey: "T1:input:4" })), "T1:input:4");
  assert.equal(answerKey(report(REPORT, { turnId: "T2" })), "T2:prompt");
  assert.equal(answerKey(report(REPORT)), null);
  assert.equal(answerKey(bubble("x", { turn: "T2" })), "T2");
});

test("writeOpened / readOpened: kept beside the folded answers; an entry before `open` reads as none; one with only `open` is kept", () => {
  clearFolds();
  localStorage.setItem(`${FOLD_PREFIX}s1`, JSON.stringify({ root: "/p", turns: ["t1"] }));
  assert.deepEqual(readOpened("s1"), []);
  writeOpened("s1", "T1:prompt", true, { root: "/p" });
  assert.deepEqual(readFolded("s1"), ["t1"]);
  assert.deepEqual(readOpened("s1"), ["T1:prompt"]);
  writeFold("s1", "t1", false, { root: "/p" });
  assert.deepEqual(JSON.parse(localStorage.getItem(`${FOLD_PREFIX}s1`)), { root: "/p", turns: [], open: ["T1:prompt"] });
  writeOpened("s1", "T1:prompt", false);
  assert.equal(localStorage.getItem(`${FOLD_PREFIX}s1`), null);
  clearFolds();
});

test("the page: a long report folds by default (a report row, the label); a click unfolds it, kept in `open`, a reload keeps it open", async () => {
  clearFolds();
  const first = page();
  const merged = report(REPORT, { lineKey: "T1:input:4" });
  const short = report("session: x\nstatus: answered\n---\nDone.", { lineKey: "T1:input:9" });
  first.history.append(merged, short);
  await tick();
  const row = merged.previousElementSibling;
  assert.equal(first.history.querySelectorAll(".answer-fold").length, 1);
  assert.ok(merged.classList.contains("folded"));
  assert.ok(row.matches(".answer-fold.report.steered.folded"));
  assert.equal(row.title, "Show the report");
  assert.equal(row.textContent, "delegate report · Rebase result · 44 lines");
  row.click();
  assert.ok(!merged.classList.contains("folded"));
  assert.equal(row.title, "Fold the report");
  assert.equal(row.textContent, "44 lines");
  assert.deepEqual(readOpened("s1"), ["T1:input:4"]);
  assert.deepEqual(readFolded("s1"), []);
  first.history.remove();

  const again = page();
  const reloaded = report(REPORT, { lineKey: "T1:input:4" });
  const wake = report(REPORT, { turnId: "T2" });
  again.history.append(reloaded, wake);
  await tick();
  assert.ok(!reloaded.classList.contains("folded"));
  assert.ok(wake.classList.contains("folded"));
  assert.ok(!wake.previousElementSibling.classList.contains("steered"));
  again.history.remove();
  clearFolds();
});

function prompt(text, { turn = "T5", source = null } = {}) {
  const el = document.createElement("div");
  el.className = "bubble user";
  if (turn) el.dataset.turnId = turn;
  if (source) el.dataset.source = source;
  el.setAttribute("data-copy-source", text);
  const msg = document.createElement("div");
  msg.className = "user-message";
  msg.textContent = text;
  el.append(msg);
  return el;
}

test("answerKey: a prompt's is its turn's :prompt; a queued one (no turn id) has none", () => {
  assert.equal(answerKey(prompt("x", { turn: "T5" })), "T5:prompt");
  assert.equal(answerKey(prompt("x", { turn: null })), null);
});

test("the page: a long prompt gets an open row (the answers' threshold); a click folds it (saved with the answers), a reload keeps it", async () => {
  clearFolds();
  const first = page();
  const long = prompt(`Please review this:\n## Not the label\n${lines(40)}`);
  const short = prompt("short", { turn: "T6" });
  const atLimit = prompt(lines(FOLD_LINES), { turn: "T7" });
  first.history.append(long, short, atLimit);
  await tick();
  assert.equal(first.history.querySelectorAll(".answer-fold").length, 1);
  const row = long.previousElementSibling;
  assert.ok(row.matches(".answer-fold.prompt:not(.folded):not(.report)"));
  assert.ok(!long.classList.contains("folded"), "open by default");
  assert.equal(row.title, "Fold the message");
  assert.equal(row.textContent, "42 lines");
  row.click();
  assert.ok(long.classList.contains("folded"));
  assert.equal(row.title, "Show the message");
  assert.equal(row.textContent, "Please review this: · 42 lines", "its first line, not a heading under it");
  assert.deepEqual(readFolded("s1"), ["T5:prompt"]);
  assert.deepEqual(readOpened("s1"), []);
  first.history.remove();

  const again = page();
  const reloaded = prompt(`Please review this:\n## Not the label\n${lines(40)}`);
  again.history.append(reloaded);
  await tick();
  assert.ok(reloaded.classList.contains("folded"));
  reloaded.previousElementSibling.click();
  assert.deepEqual(readFolded("s1"), []);
  again.history.remove();
  clearFolds();
});

test("the page: a live prompt gets its row when its turn starts (its key); a sourced user line other than a report gets none", async () => {
  clearFolds();
  const { history } = page();
  const live = prompt(lines(40), { turn: null });
  const other = prompt(lines(40), { turn: "T8", source: "broadcast" });
  history.append(live, other);
  await tick();
  assert.equal(history.querySelectorAll(".answer-fold").length, 0);
  live.dataset.turnId = "T9";
  await tick();
  assert.ok(live.previousElementSibling.matches(".answer-fold.prompt"));
  assert.equal(history.querySelectorAll(".answer-fold").length, 1);
  history.remove();
});

test("the page: something placed before a report that opens its turn goes above its row; a jump into a folded report unfolds it", async () => {
  clearFolds();
  const { history } = page();
  const wake = report(REPORT, { turnId: "T2" });
  history.append(wake);
  await tick();
  const row = wake.previousElementSibling;
  const card = document.createElement("div");
  card.className = "bubble plugin-card";
  history.insertBefore(card, wake);
  await tick();
  assert.ok(card.nextElementSibling === row && row.nextElementSibling === wake);
  const line = wake.querySelector(".user-message");
  revealInHistory(line);
  await tick();
  assert.ok(!wake.classList.contains("folded"));
  assert.equal(row.getAttribute("aria-expanded"), "true");
  assert.deepEqual(readOpened("s1"), [], "a jump's unfold isn't saved");
  history.remove();
  clearFolds();
});
