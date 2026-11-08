// A finished turn's one order and one answer rule (turn_pieces.js), as the
// live hand-off (stage_model.js handOffOrder) and a reload (turn_block.js
// turnHistoryNodes) both use them.
import test from "node:test";
import assert from "node:assert/strict";
import { answerGen, turnPieces } from "../../../lib/samagotchi/web/public/turn_pieces.js";
import { handOffOrder } from "../../../lib/samagotchi/web/public/stage_model.js";

test("turnPieces: a plain answer is the prompt, the answer, its timing", () => {
  assert.deepEqual(turnPieces({ prompt: "prompt", answer: ["answer"], timing: "timing" }), ["prompt", "answer", "timing"]);
});

test("turnPieces: a canceled turn with steps: the block, the timing, then the cancel line", () => {
  assert.deepEqual(turnPieces({ prompt: "prompt", block: "block", timing: "timing", end: "cancel" }), ["prompt", "block", "timing", "cancel"]);
});

test("turnPieces: a failed turn that kept its steps ends with its failure line after the timing", () => {
  assert.deepEqual(turnPieces({ prompt: "prompt", block: "block", timing: "timing", end: "failed" }), ["prompt", "block", "timing", "failed"]);
});

test("turnPieces: an empty answer's notice goes where the answer would, before the timing", () => {
  assert.deepEqual(turnPieces({ prompt: "prompt", block: "block", emptyNote: "no answer", timing: "timing" }),
    ["prompt", "block", "no answer", "timing"]);
});

test("turnPieces: loose steers, then the merged lines (a report and its reply) after the block, before the answer", () => {
  assert.deepEqual(turnPieces({ prompt: "prompt", block: "block", steers: ["nudge"], merged: ["steered", "report", "reply"],
    answer: ["answer"], timing: "timing" }), ["prompt", "block", "nudge", "steered", "report", "reply", "answer", "timing"]);
});

test("turnPieces: a review turn's Apply comes under the answer and its timing", () => {
  assert.deepEqual(turnPieces({ prompt: "prompt", answer: ["answer"], timing: "timing", apply: "apply" }),
    ["prompt", "answer", "timing", "apply"]);
});

test("turnPieces: the kept cards, then the lines queued for after the turn, come last", () => {
  assert.deepEqual(turnPieces({ prompt: "prompt", block: "block", answer: ["thinking", "answer"], timing: "timing", kept: ["card"],
    queued: ["later"] }), ["prompt", "block", "thinking", "answer", "timing", "card", "later"]);
});

test("handOffOrder is turnPieces with the live extras as the merged lines", () => {
  const live = { prompt: "p", block: "b", extras: ["steered", "card"], answer: ["a"], timing: "t", end: "e", kept: ["k"], queued: ["q"] };
  assert.deepEqual(handOffOrder(live), ["p", "b", "steered", "card", "a", "t", "e", "k", "q"]);
  assert.deepEqual(handOffOrder({ block: "b", answer: [] }), ["b"]);
});

const gen = (tools = 0, closed = false) => ({ tools: Array.from({ length: tools }, () => ({})), closed });

test("answerGen: a completed turn's last open step is its answer, whatever it called", () => {
  const turn = { gens: [gen(2, true), gen(1)] };
  assert.ok(answerGen(turn, "completed") === turn.gens[1]);
});

test("answerGen: a one-step turn without tools gives its text as the answer even canceled or failed", () => {
  const turn = { gens: [gen()] };
  assert.ok(answerGen(turn, "canceled") === turn.gens[0]);
  assert.ok(answerGen(turn, "failed") === turn.gens[0]);
});

test("answerGen: none for a cut turn of several steps, one with tools, a closed last step or no step", () => {
  assert.equal(answerGen({ gens: [gen(1, true), gen()] }, "canceled"), null);
  assert.equal(answerGen({ gens: [gen(1)] }, "canceled"), null);
  assert.equal(answerGen({ gens: [gen(0, true)] }, "completed"), null);
  assert.equal(answerGen({ gens: [] }, "completed"), null);
  assert.equal(answerGen(null, "completed"), null);
});
