// A finished turn's drawing (turn_drawing.js; turn_block.js draws it):
// its fold into steps, and turnHistoryNodes' drawn branch for each kind of
// part, its overlays from the saved items and a card without a stored body.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { drawingTurn, drawnIds, drawnKind } from "../../../lib/samagotchi/web/public/turn_drawing.js";
import { turnGroups } from "../../../lib/samagotchi/web/public/timing.js";
import { turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_block.js";
import { historyShape } from "../../../lib/samagotchi/web/public/history_shape.js";

const started = { type: "turn_started", prompt: "hi", turn_id: "T1" };
const gen = (n) => ({ type: "generation_started", iteration: n });
const say = (n, text, thinking = "") => ({ type: "generation_chunk", iteration: n, text, thinking });
const row = (n) => [
  { type: "tool_call_started", iteration: n, call_index: 1, tool: "read", params: 'path="a"', title: "a", tool_id: "t1" },
  { type: "tool_call_completed", iteration: n, call_index: 1, tool: "read", tool_id: "t1", output: "x", duration_ms: 40, activity: { status: "ok" } },
];
const done = { type: "turn_completed", turn_id: "T1" };

function drawn(events, items, { end = done, cards = null } = {}) {
  const host = document.createElement("div");
  host.append(turnHistoryNodes(items, {}, { thumbs: () => null, drawings: { T1: { events, end } }, cards }));
  return host;
}

test("drawnKind reads the end event's type; drawingTurn folds the steps and rows as live", () => {
  assert.equal(drawnKind({ type: "turn_canceled" }), "canceled");
  assert.equal(drawnKind({}), "completed");
  const turn = drawingTurn({ events: [started, gen(1), say(1, "Look."), ...row(1), gen(2), say(2, "Done.")] });
  assert.equal(turn.gens.length, 2);
  assert.deepEqual(turn.gens[0].tools.map((r) => [r.tool, r.status, r.duration_ms]), [["read", "ok", 40]]);
  assert.deepEqual([...drawnIds([{ drawn: "T1" }, { drawn: "T9" }, {}], { T1: {} })], ["T1"]);
});

test("turnGroups makes a drawn turn's stamped items one group, a reminder turn's too, its steps the drawing's", () => {
  const items = [{ role: "user", content: "hi", turn_id: "T0" }, { role: "assistant", content: "a" },
    { role: "assistant", content: "Tea.", drawn: "T1" }];
  const groups = turnGroups(items, {}, { drawings: { T1: { events: [started, gen(1), say(1, "Tea.")], end: done } } });
  assert.deepEqual(groups.map((g) => [g.kind, g.drawn ?? null, g.user]), [["turn", null, 0], ["turn", "T1", null]]);
  assert.equal(groups[1].answer, 2);
  assert.equal(groups[1].steps.length, 1);
  // No drawing for the stamp (a page without them): today's groups.
  assert.equal(turnGroups(items, {}).length, 1);
});

// The steer's step is the answer's, which leaves the block: the steer
// leaves with it, before the answer (as live's promote).
test("a drawn turn's notice stays in its step, a reminder is its bubble, a steer goes where live put it", () => {
  const events = [started, { type: "reminder_injected", reminders: [{ name: "tea" }] }, gen(1), say(1, "", "hmm"),
    { type: "empty_answer_retry", iteration: 1, attempt: 1, of: 1 }, ...row(1),
    { type: "pending_input_merged", count: 0, content: null, steers: [{ source: "check-in", text: "go on" }] },
    gen(2), say(2, "Done.")];
  const items = [{ role: "user", content: "hi", turn_id: "T1", drawn: "T1" }, { role: "assistant", content: "Done.", drawn: "T1" }];
  const shape = historyShape(drawn(events, items));
  assert.deepEqual(shape.map((it) => it.kind), ["prompt", "block", "step", "notice", "row", "command", "steer", "answer"]);
  assert.equal(shape.find((it) => it.kind === "command").text, "reminder: tea");
});

test("the answer and the steps' texts take their items' markdown; a row its tool's mark only from the drawing", () => {
  const events = [started, gen(1), say(1, "Look **here**."), ...row(1), gen(2), say(2, "**Done**.")];
  const items = [{ role: "user", content: "hi", turn_id: "T1", drawn: "T1" },
    { role: "assistant", content: "Look **here**.", html: "<p>Look <b>here</b>.</p>", drawn: "T1", marks: { t1: { kind: "forgot" } } },
    { role: "assistant", content: "**Done**.", html: "<p><b>Done</b>.</p>", drawn: "T1" }];
  const host = drawn(events, items);
  assert.equal(host.querySelector(".bubble.output").innerHTML, "<p><b>Done</b>.</p>");
  assert.equal(host.querySelector(".bubble.output").dataset.answerTurn, "T1");
  assert.equal(host.querySelector(".gen > .gen-text.markdown").getAttribute("data-copy-source"), "Look **here**.");
  assert.ok([...host.children].every((el) => el.dataset.drawn === "T1"));
});

test("a drawn card that asked sits beside the block, its buttons off; without a stored one its body is the drawing's", () => {
  const card = { type: "card", in_turn: true, id: "check-in", source: "check-in", title: "Check in", body: "still?", level: "info",
    actions: [{ label: "Nudge", command: "/check-in nudge" }] };
  const events = [started, gen(1), say(1, "Work."), ...row(1), card, gen(2), say(2, "Done.")];
  const items = [{ role: "user", content: "hi", turn_id: "T1", drawn: "T1" }, { role: "assistant", content: "Work.", drawn: "T1" },
    { role: "assistant", content: "Done.", drawn: "T1" }];
  const host = drawn(events, items);
  const el = host.querySelector(":scope > .plugin-card");
  assert.ok(el);
  assert.match(el.textContent, /still\?/);
  assert.ok([...el.querySelectorAll(".card-action")].every((b) => b.disabled));
  assert.deepEqual(historyShape(host).map((it) => it.kind), ["prompt", "block", "step", "row", "card", "answer"]);
});

test("a canceled drawn turn ends with its cancel line, a failed one with its failure", () => {
  const events = [started, gen(1), say(1, "Start."), ...row(1), gen(2), say(2, "Half")];
  const items = [{ role: "user", content: "hi", turn_id: "T1", drawn: "T1" }, { role: "assistant", content: "Start.", drawn: "T1" },
    { role: "assistant", content: "Half", drawn: "T1" }];
  const canceled = historyShape(drawn(events, items, { end: { type: "turn_canceled", turn_id: "T1", cancellation_reason: "user" } }));
  assert.deepEqual(canceled.slice(-1), [{ kind: "cancel", cls: "", text: "■ canceled (stopped)" }]);
  const failed = historyShape(drawn(events.slice(0, -2), items.slice(0, 2),
    { end: { type: "turn_failed", turn_id: "T1", summary: "server down", kept_steps: 1 } }));
  assert.equal(failed[failed.length - 1].kind, "failed");
});

test("a wake's note just before the range (its id the drawn turn's) opens the drawn turn: one group, one timing", () => {
  const items = [{ role: "note", turn_start: true, turn_id: "T1", content: "task done" }, { role: "assistant", content: "Ran.", drawn: "T1" }];
  const groups = turnGroups(items, {}, { drawings: { T1: { events: [started, gen(1), say(1, "Ran.")], end: done } } });
  assert.deepEqual(groups.map((g) => [g.drawn, g.user]), [["T1", 0]]);
  const shape = historyShape(drawn([started, gen(1), say(1, "Ran.")], items));
  assert.deepEqual(shape.map((it) => it.kind), ["note", "answer"]);
});
