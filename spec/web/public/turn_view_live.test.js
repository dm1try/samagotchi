import { htmlOf, markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createTurnView, stepTemplate } from "../../../lib/samagotchi/web/public/turn_view.js";
import { toolRowTemplate } from "../../../lib/samagotchi/web/public/turn_html.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { answerRefsOf } from "../../../lib/samagotchi/web/public/answer_refs.js";

// A live turn view on a detached history, no hold (no layout under node).
function liveView() {
  const historyEl = document.createElement("div");
  const view = createTurnView({
    historyEl,
    appendToHistory: (el) => historyEl.appendChild(el),
    isNearBottom: () => false,
    sawText: () => {},
    sessionId: () => "s1",
    useHold: false,
  });
  return { view, historyEl };
}

// A step's markup as stepTemplate draws it with a reload's defaults.
function reloadStepHtml(gen, rows = []) {
  const frag = document.createDocumentFragment();
  const items = rows.length ? [document.createRange().createContextualFragment(rows.map((r) => markupOf(toolRowTemplate(r))).join(""))] : [];
  render(stepTemplate(gen, { items }), frag);
  return htmlOf(frag);
}

function stepOne(view) {
  view.turnStarted({ prompt: "p" });
  view.generationStarted({ iteration: 1 });
  view.chunk({ thinking: "First a plan. Then a check.", iteration: 1 });
  view.chunk({ text: "Let me check.", iteration: 1 });
  view.flush();
  view.generationCompleted();
  view.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: 'path="R.md"' });
  view.toolCompleted({ iteration: 1, call_index: 1, tool: "read", status: "ok", output: "[read]\nok" });
}

test("createTurnView: a closed live step is the reload's markup for the same gen", () => {
  const { view } = liveView();
  stepOne(view);
  view.generationStarted({ iteration: 2 });
  const { turn } = view.current();
  const gen = turn.gens[0];
  const live = htmlOf(view.step(0).el.cloneNode(true));
  assert.equal(live, reloadStepHtml(gen, gen.tools));
  assert.match(live, /^<details class="gen"><summary class="repeats">/);
  assert.match(live, /<details class="thinking"><summary>thinking<\/summary><div class="thinking-body">First a plan\. Then a check\.<\/div><\/details><div class="gen-text">Let me check\.<\/div>/);
});

test("createTurnView: a live step is open, 'step N', its narration streaming; no empty narration element without text", () => {
  const { view } = liveView();
  view.turnStarted({});
  view.generationStarted({ iteration: 1 });
  const el = view.step(0).el;
  assert.equal(el.className, "gen live");
  assert.equal(el.open, true);
  assert.equal(el.querySelector(":scope > summary").textContent, "step 1");
  assert.equal(el.querySelector(".gen-text"), null);
  view.chunk({ text: "One. Two", iteration: 1 });
  view.flush();
  assert.deepEqual([...el.querySelectorAll(".gen-text.streaming .narration .sentence")].map((s) => s.textContent), ["One."]);
});

test("createTurnView: a thinking-only step closes unwrapped (one 'thinking'); with text or tools it keeps its wrap", () => {
  const { view } = liveView();
  view.turnStarted({});
  view.generationStarted({ iteration: 1 });
  view.chunk({ thinking: "Only thinking here.", iteration: 1 });
  view.flush();
  assert.ok(view.step(0).thinkingWrap, "wrapped while live");
  view.generationStarted({ iteration: 2 });
  const closed = view.step(0).el;
  assert.equal(view.step(0).thinkingWrap, null);
  assert.ok(closed.querySelector(":scope > .thinking-body"));
  assert.equal(closed.querySelector(":scope > summary").textContent, "thinking");

  const other = liveView().view;
  stepOne(other);
  other.generationStarted({ iteration: 2 });
  assert.ok(other.step(0).thinkingWrap, "a step with text and a call keeps its wrap");
});

test("createTurnView: a hand-opened thinking wrap stays open across re-renders and the step's close", () => {
  const { view } = liveView();
  view.turnStarted({});
  view.generationStarted({ iteration: 1 });
  view.chunk({ thinking: "A first thought. ", iteration: 1 });
  view.flush();
  const wrap = view.step(0).thinkingWrap;
  wrap.querySelector(":scope > summary").click();
  assert.equal(wrap.open, true);
  view.chunk({ thinking: "A second thought.", text: "Done here.", iteration: 1 });
  view.flush();
  view.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: "x" });
  view.generationStarted({ iteration: 2 });
  assert.equal(view.step(0).thinkingWrap, wrap, "the same element");
  assert.equal(wrap.open, true);
  assert.equal(wrap.querySelector(".thinking-body").textContent, "A first thought. A second thought.");
  // A later step's wrap starts closed (a peek is per step).
  view.chunk({ thinking: "Next.", iteration: 2 });
  view.flush();
  assert.equal(view.step(1).thinkingWrap.open, false);
});

test("createTurnView: the thinking streams into one text node (a selection in it survives)", () => {
  const { view } = liveView();
  view.turnStarted({});
  view.generationStarted({ iteration: 1 });
  view.chunk({ thinking: "abc", iteration: 1 });
  view.flush();
  const body = view.step(0).thinkingWrap.querySelector(".thinking-body");
  const node = [...body.childNodes].find((n) => n.nodeType === 3);
  view.chunk({ thinking: "def", iteration: 1 });
  view.flush();
  assert.equal(node.data, "abcdef");
  assert.equal([...body.childNodes].filter((n) => n.nodeType === 3).length, 1);
});

// P3 (c2): a finished turn's block is its outline, the same live as on a
// reload (turn_view.js outlineBlock on turn_model.js outlineRuns).
function narratedTurn(view, { newest = false } = {}) {
  stepOne(view);
  view.generationStarted({ iteration: 2 });
  view.toolStarted({ iteration: 2, call_index: 1, tool: "read", params: 'path="A.md"' });
  view.toolCompleted({ iteration: 2, call_index: 1, tool: "read", status: "ok", output: "ok" });
  view.generationStarted({ iteration: 3 });
  view.chunk({ thinking: "Hmm.", iteration: 3 });
  view.generationCompleted();
  view.generationStarted({ iteration: 4 });
  view.chunk({ text: "Middle note: switching to dev.", iteration: 4 });
  view.flush();
  view.generationCompleted();
  view.toolStarted({ iteration: 4, call_index: 1, tool: "edit", params: 'path="B.md"' });
  view.toolCompleted({ iteration: 4, call_index: 1, tool: "edit", status: "ok", output: "ok" });
  view.generationStarted({ iteration: 5 });
  view.chunk({ text: "Done.", iteration: 5 });
  view.flush();
  view.generationCompleted();
  view.turnEnded({ kind: "completed" });
  if (newest) view.chronological();
  return view.current().blockEl;
}

// The block's children as the outline reads: a step's class and head, a fold's text.
const outlineOf = (block) => [...block.children].filter((el) => !el.matches("summary")).map((el) =>
  el.matches(".outline-fold") ? `fold ${el.textContent}` : `${el.className} ${el.querySelector(":scope > summary").textContent.split(" · ")[0]}`);

test("createTurnView: a finished turn with narrated steps stays open as its outline, tool-only steps folded", () => {
  const { view } = liveView();
  const block = narratedTurn(view);
  assert.equal(block.open, true);
  assert.ok(block.classList.contains("outline"));
  assert.deepEqual(outlineOf(block), [
    "gen Let me check.", "fold 2 steps", "gen folded working with read", "gen folded thinking", "gen Middle note: switching to dev.",
  ]);
  // The fold shows its steps and hides them again.
  const fold = block.querySelector(".outline-fold");
  fold.click();
  assert.equal(fold.getAttribute("aria-expanded"), "true");
  assert.equal(block.querySelectorAll(".gen.folded.unfolded").length, 2);
  fold.click();
  assert.equal(block.querySelectorAll(".gen.folded.unfolded").length, 0);
});

test("createTurnView: newest first while it ran (the stage's cloud), the outline is still chronological", () => {
  const historyEl = document.createElement("div");
  const view = createTurnView({ historyEl, appendToHistory: (el) => historyEl.appendChild(el), isNearBottom: () => false,
    sawText: () => {}, sessionId: () => "s1", useHold: false, newestFirst: true });
  const block = narratedTurn(view, { newest: true });
  assert.deepEqual(outlineOf(block), [
    "gen Let me check.", "fold 2 steps", "gen folded working with read", "gen folded thinking", "gen Middle note: switching to dev.",
  ]);
});

test("createTurnView: a finished turn whose steps said nothing closes as before (no outline)", () => {
  const { view } = liveView();
  view.turnStarted({ prompt: "p" });
  view.generationStarted({ iteration: 1 });
  view.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: 'path="R.md"' });
  view.toolCompleted({ iteration: 1, call_index: 1, tool: "read", status: "ok", output: "ok" });
  view.generationStarted({ iteration: 2 });
  view.chunk({ text: "Done.", iteration: 2 });
  view.flush();
  view.generationCompleted();
  view.turnEnded({ kind: "completed" });
  const { blockEl } = view.current();
  assert.equal(blockEl.open, false);
  assert.equal(blockEl.classList.contains("outline"), false);
  assert.equal(blockEl.querySelectorAll(".outline-fold").length, 0);
});

test("createTurnView: a ref's reveal (show in turn) on a row in a folded step unfolds its run", () => {
  const { view } = liveView();
  const block = narratedTurn(view);
  const row = block.querySelector(".gen.folded .activity-row");
  row.dispatchEvent(new window.CustomEvent("ref:reveal", { bubbles: true }));
  assert.equal(block.querySelectorAll(".gen.folded.unfolded").length, 2);
  assert.equal(block.querySelector(".outline-fold").getAttribute("aria-expanded"), "true");
  // Again: it stays unfolded (a reveal never folds).
  row.dispatchEvent(new window.CustomEvent("ref:reveal", { bubbles: true }));
  assert.equal(block.querySelectorAll(".gen.folded.unfolded").length, 2);
});

// A row whose command the user switched to raw and whose diff they opened.
function editedRow(view) {
  const steps = [{ text: "ruby a.rb" }, { op: "&&", text: "git diff" }];
  view.turnStarted({ prompt: "p" });
  view.generationStarted({ iteration: 1 });
  view.toolStarted({ iteration: 1, call_index: 1, tool: "execute", params: 'command="ruby a.rb && git diff"', title: "ruby a.rb",
    view: { command: "ruby a.rb && git diff", steps } });
  const done = { iteration: 1, call_index: 1, tool: "execute", output: "[execute]\nok", diff: { text: "@@ -1 +1 @@\n-a\n+b", added: 1, removed: 1 },
    activity: { status: "ok", params: 'command="ruby a.rb && git diff"', title: "ruby a.rb" } };
  view.toolCompleted(done);
  return done;
}

test("createTurnView: a live row drawn again keeps its elements, the raw command and the diff the user opened", () => {
  const { view } = liveView();
  const done = editedRow(view);
  const row = view.step(0).el.querySelector(".activity-row");
  const [title, command, diff, mark] = [".activity-params", ".activity-command", ".activity-diff", ".activity-status"].map((s) => row.querySelector(s));
  row.querySelector(".activity-command-raw input").checked = true;
  diff.open = true;
  // The same call's result again (a re-dispatched event), its output changed.
  view.toolCompleted({ ...done, output: "[execute]\nok again", duration_ms: 1500 });
  assert.equal(view.step(0).el.querySelector(".activity-row"), row);
  // Booleans: a failed deepEqual over happy-dom elements takes minutes to print.
  assert.deepEqual([".activity-params", ".activity-command", ".activity-diff", ".activity-status"].map((s, i) => row.querySelector(s) === [title, command, diff, mark][i]), [true, true, true, true]);
  assert.equal(row.querySelector(".activity-command-raw input").checked, true);
  assert.equal(diff.open, true);
  assert.equal(row.querySelector(".activity-output").textContent, "ok again");
  assert.equal(row.querySelector(".activity-duration").textContent, "1.5s");
});

test("createTurnView: a live row is the reloaded row's markup", () => {
  const { view } = liveView();
  editedRow(view);
  const { turn } = view.current();
  const row = turn.gens[0].tools[0];
  assert.equal(htmlOf(view.step(0).el.querySelector(".activity-row")), markupOf(toolRowTemplate(row)));
});

test("createTurnView: a running task_wait's row has its stop-task button after its title, the same one across redraws, gone once done", () => {
  const historyEl = document.createElement("div");
  const taskStop = { target: (row) => (row.status === "running" && row.tool === "task_wait" ? "t1" : null), busy: () => false, stop: () => Promise.resolve() };
  const view = createTurnView({ historyEl, appendToHistory: (el) => historyEl.appendChild(el), isNearBottom: () => false, sawText: () => {},
    sessionId: () => "s1", useHold: false, taskStop });
  view.turnStarted({ prompt: "p" });
  view.generationStarted({ iteration: 1 });
  const started = { iteration: 1, call_index: 1, tool: "task_wait", params: 'task_id="t1"', title: "t1" };
  view.toolStarted(started);
  const row = view.step(0).el.querySelector(".activity-row");
  const btn = row.querySelector(".task-stop");
  assert.ok(btn.previousElementSibling === row.querySelector(".activity-params"));
  view.toolStarted(started);
  assert.ok(row.querySelector(".task-stop") === btn);
  view.toolCompleted({ iteration: 1, call_index: 1, tool: "task_wait", output: "[task_wait]\ndone", activity: { status: "ok", title: "t1" } });
  assert.ok(row.querySelector(".task-stop") === null);
});

test("createTurnView: a question's refs on the asking step go on its closed text (once), none on the others", () => {
  const refs = [{ match: "DEMO-123", kind: "issue", target: { id: "DEMO-123" }, actions: [] }];
  const { view } = liveView();
  view.turnStarted({ prompt: "p" });
  view.generationStarted({ iteration: 1 });
  view.chunk({ text: "Proceed with DEMO-123?", iteration: 1 });
  view.flush();
  view.generationCompleted();
  view.toolStarted({ iteration: 1, call_index: 1, tool: "ask_user_question", params: "" });
  view.questionRefs(refs);
  assert.equal(view.current().turn.gens[0].refs, refs);
  // Live: nothing on the step's text yet (the stage's asking slot pairs them).
  assert.equal(answerRefsOf(view.step(0).el.querySelector(":scope > .gen-text")), null);
  view.toolCompleted({ iteration: 1, call_index: 1, tool: "ask_user_question", status: "ok", output: "a" });
  view.generationStarted({ iteration: 2 });
  const text = view.step(0).el.querySelector(":scope > .gen-text");
  assert.equal(text.textContent, "Proceed with DEMO-123?");
  assert.deepEqual(answerRefsOf(text), refs);
  view.chunk({ text: "Reading.", iteration: 2 });
  view.flush();
  view.generationCompleted();
  view.toolStarted({ iteration: 2, call_index: 1, tool: "read", params: 'path="R.md"' });
  view.toolCompleted({ iteration: 2, call_index: 1, tool: "read", status: "ok", output: "ok" });
  view.generationStarted({ iteration: 3 });
  assert.equal(answerRefsOf(view.step(1).el.querySelector(":scope > .gen-text")), null);
});
