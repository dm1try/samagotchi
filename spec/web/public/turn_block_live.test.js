import { htmlOf, markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createTurnBlock, stepTemplate } from "../../../lib/samagotchi/web/public/turn_block.js";
import { toolRowTemplate } from "../../../lib/samagotchi/web/public/turn_html.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { answerRefsOf } from "../../../lib/samagotchi/web/public/answer_refs.js";

// A live turn block on the stage's seams (stage_view.js): the block in a
// host (the cloud), the answer in its own slot (a plain turn's block goes),
// newest step first.
function liveBlock(opts = {}) {
  const historyEl = document.createElement("div");
  const host = document.createElement("div");
  const answer = document.createElement("div");
  const turnBlock = createTurnBlock({
    historyEl,
    isNearBottom: () => false,
    follow: () => {},
    sawText: () => {},
    sessionId: () => "s1",
    blockHost: (el) => host.appendChild(el),
    placeAnswer: (pieces, { plain, blockEl }) => {
      if (plain) blockEl.remove();
      answer.append(...pieces);
    },
    ...opts,
  });
  return { turnBlock, host, answer };
}

// A step's markup as stepTemplate draws it with a reload's defaults.
function reloadStepHtml(gen, rows = []) {
  const frag = document.createDocumentFragment();
  const items = rows.length ? [document.createRange().createContextualFragment(rows.map((r) => markupOf(toolRowTemplate(r))).join(""))] : [];
  render(stepTemplate(gen, { items }), frag);
  return htmlOf(frag);
}

function stepOne(turnBlock) {
  turnBlock.turnStarted({ prompt: "p" });
  turnBlock.generationStarted({ iteration: 1 });
  turnBlock.chunk({ thinking: "First a plan. Then a check.", iteration: 1 });
  turnBlock.chunk({ text: "Let me check.", iteration: 1 });
  turnBlock.flush();
  turnBlock.generationCompleted();
  turnBlock.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: 'path="R.md"' });
  turnBlock.toolCompleted({ iteration: 1, call_index: 1, tool: "read", status: "ok", output: "[read]\nok" });
}

test("createTurnBlock: a closed live step is the reload's markup for the same gen", () => {
  const { turnBlock } = liveBlock();
  stepOne(turnBlock);
  turnBlock.generationStarted({ iteration: 2 });
  const { turn } = turnBlock.current();
  const gen = turn.gens[0];
  const live = htmlOf(turnBlock.step(0).el.cloneNode(true));
  assert.equal(live, reloadStepHtml(gen, gen.tools));
  assert.match(live, /^<details class="gen"><summary class="repeats">/);
  assert.match(live, /<details class="thinking"><summary>thinking<\/summary><div class="thinking-body">First a plan\. Then a check\.<\/div><\/details><div class="gen-text">Let me check\.<\/div>/);
});

test("createTurnBlock: a live step is open, 'step N', its narration streaming; no empty narration element without text", () => {
  const { turnBlock } = liveBlock();
  turnBlock.turnStarted({});
  turnBlock.generationStarted({ iteration: 1 });
  const el = turnBlock.step(0).el;
  assert.equal(el.className, "gen live");
  assert.equal(el.open, true);
  assert.equal(el.querySelector(":scope > summary").textContent, "step 1");
  assert.equal(el.querySelector(".gen-text"), null);
  turnBlock.chunk({ text: "One. Two", iteration: 1 });
  turnBlock.flush();
  assert.deepEqual([...el.querySelectorAll(".gen-text.streaming .narration .sentence")].map((s) => s.textContent), ["One."]);
});

test("createTurnBlock: a thinking-only step closes unwrapped (one 'thinking'); with text or tools it keeps its wrap", () => {
  const { turnBlock } = liveBlock();
  turnBlock.turnStarted({});
  turnBlock.generationStarted({ iteration: 1 });
  turnBlock.chunk({ thinking: "Only thinking here.", iteration: 1 });
  turnBlock.flush();
  assert.ok(turnBlock.step(0).thinkingWrap, "wrapped while live");
  turnBlock.generationStarted({ iteration: 2 });
  const closed = turnBlock.step(0).el;
  assert.equal(turnBlock.step(0).thinkingWrap, null);
  assert.ok(closed.querySelector(":scope > .thinking-body"));
  assert.equal(closed.querySelector(":scope > summary").textContent, "thinking");

  const other = liveBlock().turnBlock;
  stepOne(other);
  other.generationStarted({ iteration: 2 });
  assert.ok(other.step(0).thinkingWrap, "a step with text and a call keeps its wrap");
});

test("createTurnBlock: a hand-opened thinking wrap stays open across re-renders and the step's close", () => {
  const { turnBlock } = liveBlock();
  turnBlock.turnStarted({});
  turnBlock.generationStarted({ iteration: 1 });
  turnBlock.chunk({ thinking: "A first thought. ", iteration: 1 });
  turnBlock.flush();
  const wrap = turnBlock.step(0).thinkingWrap;
  wrap.querySelector(":scope > summary").click();
  assert.equal(wrap.open, true);
  turnBlock.chunk({ thinking: "A second thought.", text: "Done here.", iteration: 1 });
  turnBlock.flush();
  turnBlock.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: "x" });
  turnBlock.generationStarted({ iteration: 2 });
  assert.equal(turnBlock.step(0).thinkingWrap, wrap, "the same element");
  assert.equal(wrap.open, true);
  assert.equal(wrap.querySelector(".thinking-body").textContent, "A first thought. A second thought.");
  // A later step's wrap starts closed (a peek is per step).
  turnBlock.chunk({ thinking: "Next.", iteration: 2 });
  turnBlock.flush();
  assert.equal(turnBlock.step(1).thinkingWrap.open, false);
});

test("createTurnBlock: the thinking streams into one text node (a selection in it survives)", () => {
  const { turnBlock } = liveBlock();
  turnBlock.turnStarted({});
  turnBlock.generationStarted({ iteration: 1 });
  turnBlock.chunk({ thinking: "abc", iteration: 1 });
  turnBlock.flush();
  const body = turnBlock.step(0).thinkingWrap.querySelector(".thinking-body");
  const node = [...body.childNodes].find((n) => n.nodeType === 3);
  turnBlock.chunk({ thinking: "def", iteration: 1 });
  turnBlock.flush();
  assert.equal(node.data, "abcdef");
  assert.equal([...body.childNodes].filter((n) => n.nodeType === 3).length, 1);
});

// P3 (c2): a finished turn's block is its outline, the same live as on a
// reload (turn_block.js outlineBlock on turn_model.js outlineRuns).
function narratedTurn(turnBlock) {
  stepOne(turnBlock);
  turnBlock.generationStarted({ iteration: 2 });
  turnBlock.toolStarted({ iteration: 2, call_index: 1, tool: "read", params: 'path="A.md"' });
  turnBlock.toolCompleted({ iteration: 2, call_index: 1, tool: "read", status: "ok", output: "ok" });
  turnBlock.generationStarted({ iteration: 3 });
  turnBlock.chunk({ thinking: "Hmm.", iteration: 3 });
  turnBlock.generationCompleted();
  turnBlock.generationStarted({ iteration: 4 });
  turnBlock.chunk({ text: "Middle note: switching to dev.", iteration: 4 });
  turnBlock.flush();
  turnBlock.generationCompleted();
  turnBlock.toolStarted({ iteration: 4, call_index: 1, tool: "edit", params: 'path="B.md"' });
  turnBlock.toolCompleted({ iteration: 4, call_index: 1, tool: "edit", status: "ok", output: "ok" });
  turnBlock.generationStarted({ iteration: 5 });
  turnBlock.chunk({ text: "Done.", iteration: 5 });
  turnBlock.flush();
  turnBlock.generationCompleted();
  turnBlock.turnEnded({ kind: "completed" });
  return turnBlock.current().blockEl;
}

test("createTurnBlock: a completed turn's answer bubble carries its turn id (data-answer-turn), as a reload's; a canceled one's partial text doesn't", () => {
  const ended = (kind) => {
    const { turnBlock, answer } = liveBlock();
    turnBlock.turnStarted({ prompt: "p" });
    turnBlock.generationStarted({ iteration: 1 });
    turnBlock.chunk({ text: "Done.", iteration: 1 });
    turnBlock.flush();
    turnBlock.generationCompleted();
    turnBlock.turnEnded({ kind, turnId: "T9" });
    return answer.querySelector(".bubble.output");
  };
  assert.equal(ended("completed").dataset.answerTurn, "T9");
  assert.equal(ended("canceled").dataset.answerTurn, undefined);
});

// The block's children as the outline reads: a step's class and head, a fold's text.
const outlineOf = (block) => [...block.children].filter((el) => !el.matches("summary")).map((el) =>
  el.matches(".outline-fold") ? `fold ${el.textContent}` : `${el.className} ${el.querySelector(":scope > summary").textContent.split(" · ")[0]}`);

test("createTurnBlock: a finished turn with narrated steps stays open as its outline, tool-only steps folded", () => {
  const { turnBlock } = liveBlock();
  const block = narratedTurn(turnBlock);
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

test("createTurnBlock: the newest step is on top while the turn runs, the finished outline is chronological", () => {
  const { turnBlock } = liveBlock();
  stepOne(turnBlock);
  turnBlock.generationStarted({ iteration: 2 });
  const steps = () => [...turnBlock.current().blockEl.querySelectorAll(":scope > details.gen")];
  assert.ok(steps()[0] === turnBlock.step(1).el, "the live step first");
  assert.ok(steps()[1] === turnBlock.step(0).el);
  const block = narratedTurn(liveBlock().turnBlock);
  assert.deepEqual(outlineOf(block), [
    "gen Let me check.", "fold 2 steps", "gen folded working with read", "gen folded thinking", "gen Middle note: switching to dev.",
  ]);
});

test("createTurnBlock: a finished turn whose steps said nothing closes as before (no outline)", () => {
  const { turnBlock } = liveBlock();
  turnBlock.turnStarted({ prompt: "p" });
  turnBlock.generationStarted({ iteration: 1 });
  turnBlock.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: 'path="R.md"' });
  turnBlock.toolCompleted({ iteration: 1, call_index: 1, tool: "read", status: "ok", output: "ok" });
  turnBlock.generationStarted({ iteration: 2 });
  turnBlock.chunk({ text: "Done.", iteration: 2 });
  turnBlock.flush();
  turnBlock.generationCompleted();
  turnBlock.turnEnded({ kind: "completed" });
  const { blockEl } = turnBlock.current();
  assert.equal(blockEl.open, false);
  assert.equal(blockEl.classList.contains("outline"), false);
  assert.equal(blockEl.querySelectorAll(".outline-fold").length, 0);
});

test("createTurnBlock: a ref's reveal (show in turn) on a row in a folded step unfolds its run", () => {
  const { turnBlock } = liveBlock();
  const block = narratedTurn(turnBlock);
  const row = block.querySelector(".gen.folded .activity-row");
  row.dispatchEvent(new window.CustomEvent("ref:reveal", { bubbles: true }));
  assert.equal(block.querySelectorAll(".gen.folded.unfolded").length, 2);
  assert.equal(block.querySelector(".outline-fold").getAttribute("aria-expanded"), "true");
  // Again: it stays unfolded (a reveal never folds).
  row.dispatchEvent(new window.CustomEvent("ref:reveal", { bubbles: true }));
  assert.equal(block.querySelectorAll(".gen.folded.unfolded").length, 2);
});

// A row whose command the user switched to raw and whose diff they opened.
function editedRow(turnBlock) {
  const steps = [{ text: "ruby a.rb" }, { op: "&&", text: "git diff" }];
  turnBlock.turnStarted({ prompt: "p" });
  turnBlock.generationStarted({ iteration: 1 });
  turnBlock.toolStarted({ iteration: 1, call_index: 1, tool: "execute", params: 'command="ruby a.rb && git diff"', title: "ruby a.rb",
    view: { command: "ruby a.rb && git diff", steps } });
  const done = { iteration: 1, call_index: 1, tool: "execute", output: "[execute]\nok", diff: { text: "@@ -1 +1 @@\n-a\n+b", added: 1, removed: 1 },
    activity: { status: "ok", params: 'command="ruby a.rb && git diff"', title: "ruby a.rb" } };
  turnBlock.toolCompleted(done);
  return done;
}

test("createTurnBlock: a live row drawn again keeps its elements, the raw command and the diff the user opened", () => {
  const { turnBlock } = liveBlock();
  const done = editedRow(turnBlock);
  const row = turnBlock.step(0).el.querySelector(".activity-row");
  const [title, command, diff, mark] = [".activity-params", ".activity-command", ".activity-diff", ".activity-status"].map((s) => row.querySelector(s));
  row.querySelector(".activity-command-raw input").checked = true;
  diff.open = true;
  // The same call's result again (a re-dispatched event), its output changed.
  turnBlock.toolCompleted({ ...done, output: "[execute]\nok again", duration_ms: 1500 });
  assert.equal(turnBlock.step(0).el.querySelector(".activity-row"), row);
  // Booleans: a failed deepEqual over happy-dom elements takes minutes to print.
  assert.deepEqual([".activity-params", ".activity-command", ".activity-diff", ".activity-status"].map((s, i) => row.querySelector(s) === [title, command, diff, mark][i]), [true, true, true, true]);
  assert.equal(row.querySelector(".activity-command-raw input").checked, true);
  assert.equal(diff.open, true);
  assert.equal(row.querySelector(".activity-output").textContent, "ok again");
  assert.equal(row.querySelector(".activity-duration").textContent, "1.5s");
});

test("createTurnBlock: a live row is the reloaded row's markup", () => {
  const { turnBlock } = liveBlock();
  editedRow(turnBlock);
  const { turn } = turnBlock.current();
  const row = turn.gens[0].tools[0];
  assert.equal(htmlOf(turnBlock.step(0).el.querySelector(".activity-row")), markupOf(toolRowTemplate(row)));
});

test("createTurnBlock: a running task_wait's row has its stop-task button after its title, the same one across redraws, gone once done", () => {
  const taskStop = { target: (row) => (row.status === "running" && row.tool === "task_wait" ? "t1" : null), busy: () => false, stop: () => Promise.resolve() };
  const { turnBlock } = liveBlock({ taskStop });
  turnBlock.turnStarted({ prompt: "p" });
  turnBlock.generationStarted({ iteration: 1 });
  const started = { iteration: 1, call_index: 1, tool: "task_wait", params: 'task_id="t1"', title: "t1" };
  turnBlock.toolStarted(started);
  const row = turnBlock.step(0).el.querySelector(".activity-row");
  const btn = row.querySelector(".task-stop");
  assert.ok(btn.previousElementSibling === row.querySelector(".activity-params"));
  turnBlock.toolStarted(started);
  assert.ok(row.querySelector(".task-stop") === btn);
  turnBlock.toolCompleted({ iteration: 1, call_index: 1, tool: "task_wait", output: "[task_wait]\ndone", activity: { status: "ok", title: "t1" } });
  assert.ok(row.querySelector(".task-stop") === null);
});

test("createTurnBlock: a question's refs on the asking step go on its closed text (once), none on the others", () => {
  const refs = [{ match: "DEMO-123", kind: "issue", target: { id: "DEMO-123" }, actions: [] }];
  const { turnBlock } = liveBlock();
  turnBlock.turnStarted({ prompt: "p" });
  turnBlock.generationStarted({ iteration: 1 });
  turnBlock.chunk({ text: "Proceed with DEMO-123?", iteration: 1 });
  turnBlock.flush();
  turnBlock.generationCompleted();
  turnBlock.toolStarted({ iteration: 1, call_index: 1, tool: "ask_user_question", params: "" });
  turnBlock.questionRefs(refs);
  assert.equal(turnBlock.current().turn.gens[0].refs, refs);
  // Live: nothing on the step's text yet (the stage's asking slot pairs them).
  assert.equal(answerRefsOf(turnBlock.step(0).el.querySelector(":scope > .gen-text")), null);
  turnBlock.toolCompleted({ iteration: 1, call_index: 1, tool: "ask_user_question", status: "ok", output: "a" });
  turnBlock.generationStarted({ iteration: 2 });
  const text = turnBlock.step(0).el.querySelector(":scope > .gen-text");
  assert.equal(text.textContent, "Proceed with DEMO-123?");
  assert.deepEqual(answerRefsOf(text), refs);
  turnBlock.chunk({ text: "Reading.", iteration: 2 });
  turnBlock.flush();
  turnBlock.generationCompleted();
  turnBlock.toolStarted({ iteration: 2, call_index: 1, tool: "read", params: 'path="R.md"' });
  turnBlock.toolCompleted({ iteration: 2, call_index: 1, tool: "read", status: "ok", output: "ok" });
  turnBlock.generationStarted({ iteration: 3 });
  assert.equal(answerRefsOf(turnBlock.step(1).el.querySelector(":scope > .gen-text")), null);
});
