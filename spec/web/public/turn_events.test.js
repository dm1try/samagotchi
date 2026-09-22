import test from "node:test";
import assert from "node:assert/strict";
import { turnOutput } from "../../../lib/samagotchi/web/public/turn_events.js";

test("turnOutput reads turn_summary.output (result is a string on the wire)", () => {
  const data = { type: "turn_completed", result: "\nPONG", turn_summary: { output: "\nPONG" } };
  assert.equal(turnOutput(data), "PONG");
});

test("turnOutput falls back to a string result, then content/output", () => {
  assert.equal(turnOutput({ result: " ANSWER " }), "ANSWER");
  assert.equal(turnOutput({ result: { output: "OBJ" } }), "OBJ");
  assert.equal(turnOutput({ content: "C" }), "C");
  assert.equal(turnOutput({ output: "O" }), "O");
});

test("turnOutput is empty for a turn with no text", () => {
  assert.equal(turnOutput({}), "");
  assert.equal(turnOutput(null), "");
  assert.equal(turnOutput({ turn_summary: { output: "  " } }), "");
});
