import test from "node:test";
import assert from "node:assert/strict";
import {
  handOffDue, handOffOrder, inUseFrom, isPlain, liveSlots, placeFor, toolKind,
} from "../../../lib/samagotchi/web/public/stage_model.js";
import { applyEvent, newTurn, takeAnswer } from "../../../lib/samagotchi/web/public/turn_model.js";

function turnOf(...events) {
  const turn = newTurn();
  applyEvent(turn, { type: "turn_started" });
  for (const e of events) applyEvent(turn, e);
  return turn;
}
const started = (it, ci, tool, title) => ({ type: "tool_call_started", iteration: it, call_index: ci, tool, params: `p${ci}`, ...(title ? { title } : {}) });
const done = (it, ci, tool, status = "ok") => ({ type: "tool_call_completed", iteration: it, call_index: ci, tool, output: "x", activity: { status } });

test("toolKind: read-like, edit, exec, other", () => {
  for (const t of ["read", "memory_read", "web_fetch", "task_get", "task_list", "list_sessions"]) assert.equal(toolKind(t), "read");
  for (const t of ["edit", "write", "memory_write"]) assert.equal(toolKind(t), "edit");
  for (const t of ["execute", "task_create", "task_wait", "task_stop", "delegate", "delegate_result"]) assert.equal(toolKind(t), "exec");
  assert.equal(toolKind("mcp_chrome_screenshot"), "other");
  assert.equal(toolKind(undefined), "other");
});

test("liveSlots: thinking first, headline from the thinking sentence, no tool yet", () => {
  const turn = turnOf({ type: "generation_chunk", iteration: 1, thinking: "Hmm. Let me see", text: "" });
  const slots = liveSlots(turn, { thinking: "Hmm." });
  assert.equal(slots.phase, "thinking");
  assert.equal(slots.step, 1);
  assert.deepEqual(slots.headline, { text: "Hmm.", thinking: true });
  assert.equal(slots.tool, null);
  assert.deepEqual(slots.trail, []);
  assert.deepEqual(slots.ticks, []);
});

test("liveSlots: narration wins the headline; a running tool is the tool row; the phase says so", () => {
  const turn = turnOf(
    { type: "generation_chunk", iteration: 1, thinking: "t.", text: "Let me look." },
    { type: "generation_completed" },
    started(1, 1, "execute", "rspec a"),
  );
  const slots = liveSlots(turn, { narration: "Let me look.", thinking: "t." });
  assert.equal(slots.phase, "running a tool");
  assert.deepEqual(slots.headline, { text: "Let me look.", thinking: false });
  assert.deepEqual(slots.tool, { name: "execute", title: "rspec a", kind: "exec" });
  assert.deepEqual(slots.ticks, [{ kind: "exec", status: "running", step: 0 }]);
});

test("liveSlots: the trail is the last three finished calls, newest last, a file's title without its dir", () => {
  const turn = turnOf(
    started(1, 1, "read", "lib/a.rb"), done(1, 1, "read"),
    started(1, 2, "edit", "lib/web/b.rb"), done(1, 2, "edit", "error"),
    { type: "generation_started", iteration: 2 },
    started(2, 1, "execute", "cd x && rspec spec/c_spec.rb"), done(2, 1, "execute"),
    started(2, 2, "mcp_x"), done(2, 2, "mcp_x"),
    started(2, 3, "read", "lib/d.rb"),
  );
  const slots = liveSlots(turn);
  assert.deepEqual(slots.trail, [
    { name: "edit", title: "b.rb", status: "error" },
    { name: "execute", title: "cd x && rspec spec/c_spec.rb", status: "ok" },
    { name: "mcp_x", title: "p2", status: "ok" },
  ]);
  assert.equal(slots.step, 2);
  assert.deepEqual(slots.ticks.map((t) => [t.kind, t.status, t.step]), [
    ["read", "ok", 0], ["edit", "error", 0], ["exec", "ok", 1], ["other", "ok", 1], ["read", "running", 1],
  ]);
  assert.deepEqual(slots.tool, { name: "read", title: "lib/d.rb", kind: "read" });
});

test("liveSlots: writing while the step's narration streams, waiting for you with a card, the end phases", () => {
  const writing = turnOf({ type: "generation_chunk", iteration: 1, thinking: "t", text: "Let me" });
  assert.equal(liveSlots(writing).phase, "writing");
  const plain = turnOf({ type: "generation_chunk", iteration: 1, text: "Hello" });
  assert.equal(liveSlots(plain).phase, "writing the answer");
  assert.equal(liveSlots(plain, { pending: true }).phase, "waiting for you");
  assert.equal(liveSlots(plain, { ended: "completed" }).phase, "answered");
  assert.equal(liveSlots(plain, { ended: "canceled" }).phase, "canceled");
  assert.equal(liveSlots(plain, { ended: "failed" }).phase, "failed");
  assert.equal(liveSlots(plain, { ended: "gone" }).phase, "failed");
  assert.deepEqual(liveSlots(newTurn()).headline, { text: "…", thinking: false });
});

test("liveSlots: at the end an answer-only step is no step (as the block summary counts)", () => {
  const turn = turnOf(started(1, 1, "read"), done(1, 1, "read"), { type: "generation_started", iteration: 2 }, { type: "generation_chunk", iteration: 2, text: "Done." });
  assert.equal(liveSlots(turn).step, 2);
  applyEvent(turn, { type: "turn_completed" });
  takeAnswer(turn, turn.gens[1]);
  assert.equal(liveSlots(turn, { ended: "completed" }).step, 1);
});

test("isPlain: one step, no thinking, no tool rows, not over", () => {
  assert.equal(isPlain(turnOf({ type: "generation_chunk", iteration: 1, text: "Hi" })), true);
  assert.equal(isPlain(turnOf()), true);
  assert.equal(isPlain(turnOf({ type: "generation_chunk", iteration: 1, thinking: "t", text: "" })), false);
  assert.equal(isPlain(turnOf(started(1, 1, "read"))), false);
  assert.equal(isPlain(turnOf({ type: "generation_chunk", iteration: 1, text: "a" }, { type: "generation_started", iteration: 2 }, { type: "generation_chunk", iteration: 2, text: "b" })), false);
  assert.equal(isPlain(null), false);
});

test("inUseFrom: pointer, focus, selection, or a touch/scroll in the last 4 s", () => {
  const base = { pointerIn: false, lastTouchMs: 0, focusInside: false, selectionInside: false, nowMs: 100000 };
  assert.equal(inUseFrom(base), false);
  assert.equal(inUseFrom({ ...base, pointerIn: true }), true);
  assert.equal(inUseFrom({ ...base, focusInside: true }), true);
  assert.equal(inUseFrom({ ...base, selectionInside: true }), true);
  assert.equal(inUseFrom({ ...base, lastTouchMs: 96001 }), true);
  assert.equal(inUseFrom({ ...base, lastTouchMs: 96000 }), false);
});

test("handOffDue: 1.5 s not in use after the end, nothing pending; in use resets the quiet clock", () => {
  const at = (nowMs, over = {}) => handOffDue({ ended: true, pending: false, inUse: false, quietSinceMs: null, nowMs, ...over });
  assert.deepEqual(at(1000), { due: false, quietSinceMs: 1000 });
  assert.deepEqual(at(2400, { quietSinceMs: 1000 }), { due: false, quietSinceMs: 1000 });
  assert.deepEqual(at(2500, { quietSinceMs: 1000 }), { due: true, quietSinceMs: 1000 });
  assert.deepEqual(at(2500, { quietSinceMs: 1000, inUse: true }), { due: false, quietSinceMs: null });
  assert.deepEqual(at(2500, { quietSinceMs: 1000, pending: true }), { due: false, quietSinceMs: null });
  assert.deepEqual(at(2500, { quietSinceMs: 1000, ended: false }), { due: false, quietSinceMs: null });
});

test("handOffOrder: prompt, block, extras in arrival order, answer, timing, end line, kept cards", () => {
  const order = handOffOrder({ prompt: "P", block: "B", extras: ["x1", "x2"], answer: ["think", "A"], timing: "T", end: "E", kept: ["k1"] });
  assert.deepEqual(order, ["P", "B", "x1", "x2", "think", "A", "T", "E", "k1"]);
  // A reminder turn has no prompt bubble; a plain answer no block.
  assert.deepEqual(handOffOrder({ prompt: null, block: null, extras: [], answer: ["A"], timing: "T" }), ["A", "T"]);
});

test("placeFor: the stage's extras while a turn is live, else the history; the recap always the history", () => {
  assert.equal(placeFor({ live: true, handingOff: false, kind: "card" }), "stage");
  assert.equal(placeFor({ live: true, handingOff: true, kind: "card" }), "history");
  assert.equal(placeFor({ live: false, handingOff: false, kind: "command" }), "history");
  assert.equal(placeFor({ live: true, handingOff: false, kind: "recap" }), "history");
});
