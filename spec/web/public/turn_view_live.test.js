import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createTurnView, stepTemplate } from "../../../lib/samagotchi/web/public/turn_view.js";
import { toolRowHtml } from "../../../lib/samagotchi/web/public/turn_html.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

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
  const items = rows.length ? [document.createRange().createContextualFragment(rows.map((r) => toolRowHtml(r)).join(""))] : [];
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
