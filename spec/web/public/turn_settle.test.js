// turn_settle.js settleOrder: a drawn turn's pieces beside its block in the
// order live left them, case by case (the stage cuts, stage_cuts_parity.test.js,
// check it against a live page).
import test from "node:test";
import assert from "node:assert/strict";

const { settleOrder } = await import("../../../lib/samagotchi/web/public/turn_settle.js");

const gen = (iteration) => ({ type: "generation_started", iteration });
const text = (iteration, words) => ({ type: "generation_chunk", iteration, text: words, thinking: "" });
const asks = (id = "ci") => ({ type: "card", id, title: "t", actions: [{ label: "Nudge", command: "/checkin nudge" }] });
const plain = (id = "ci", level = "info") => ({ type: "card", id, title: "t", level, actions: [] });
const settled = (id = "ci", was = "asks", now = null) => ({ type: "part_settled", of: "card", id, was, now });
const asked = (id) => ({ type: "question_requested", pending_question: { id, kind: "approval" } });
const answered = (id) => ({ type: "question_answered", id, answer: { selected: ["Allow once"] } });
const order = (events) => settleOrder(events).pieces.map((p) => (p.id ? `${p.kind}:${p.id}` : p.kind));

test("a card still asking at the end goes after a question answered under its lead-in", () => {
  assert.deepEqual(order([gen(1), asks(), gen(2), text(2, "Running."), asked("a1"), answered("a1")]), ["question:a1", "card:ci"]);
});

test("a question without a lead-in leaves at its answer, an asking card at the hand-off", () => {
  assert.deepEqual(order([gen(1), asks(), gen(2), asked("q1"), answered("q1")]), ["question:q1", "card:ci"]);
});

test("a card that settled leaves where it settled: before a later question, after an earlier one", () => {
  // The drawing keeps the latest version (no actions): the arrival comes from the settle.
  assert.deepEqual(order([gen(1), plain(), gen(2), settled(), gen(3), text(3, "Run."), asked("a1"), answered("a1")]), ["card:ci", "question:a1"]);
  assert.deepEqual(order([gen(1), plain(), gen(2), text(2, "Run."), asked("a1"), answered("a1"), gen(3), settled()]), ["question:a1", "card:ci"]);
});

test("a card that never waited is a row of its step, not a piece", () => {
  const result = settleOrder([gen(1), plain(), gen(2), plain("x")]);
  assert.deepEqual(result.pieces, []);
  assert.equal(result.cards.size, 0);
});

test("the cards that are pieces, by their event's index", () => {
  assert.deepEqual([...settleOrder([gen(1), plain(), settled()]).cards], [1]);
});

test("a merged line and a reminder leave where they arrived in an opened turn", () => {
  const merged = { type: "merged_input", content: "also b" };
  assert.deepEqual(order([gen(1), asks(), merged, gen(2), settled()]), ["merged", "card:ci"]);
  assert.deepEqual(order([gen(1), asks(), { type: "reminder_injected", reminders: [] }]), ["reminder", "card:ci"]);
});

test("a warning cleared in a turn nothing opened stays at its arrival place", () => {
  const merged = { type: "merged_input", content: "also b" };
  assert.deepEqual(order([gen(1), plain("w", "info"), merged, settled("w", "warn")]), ["card:w", "merged"]);
});

test("a warning cleared in an opened turn leaves at its clearing", () => {
  assert.deepEqual(order([gen(1), plain("w", "info"), gen(2), text(2, "Run."), asked("a1"), answered("a1"), gen(3), settled("w", "warn")]),
    ["question:a1", "card:w"]);
});

test("asks then warns: still waiting (a warning), it goes at the hand-off", () => {
  assert.deepEqual(order([gen(1), plain("c", "warn"), settled("c", "asks", "warn"), gen(2), asked("q1"), answered("q1")]), ["question:q1", "card:c"]);
});

test("a drawing without settle parts orders its cards by their latest version", () => {
  assert.deepEqual(order([gen(1), asks(), gen(2), asked("q1"), answered("q1")]), ["question:q1", "card:ci"]);
  assert.deepEqual(order([gen(1), plain(), gen(2), asked("q1"), answered("q1")]), ["question:q1"]);
});

test("a step's text is the lead-in of its first question only", () => {
  const events = [gen(1), asks(), gen(2), text(2, "Two."), asked("a1"), answered("a1"), asked("a2"), answered("a2")];
  // a1 under its lead-in at its ask, then a2 at its answer; check-in at the end.
  assert.deepEqual(order(events), ["question:a1", "question:a2", "card:ci"]);
  // Whitespace is no lead-in.
  assert.deepEqual(order([gen(1), asks(), gen(2), text(2, "  "), asked("q1"), answered("q1")]), ["question:q1", "card:ci"]);
});

test("a part_settled naming an unknown id, or another kind, is ignored; junk events too", () => {
  assert.deepEqual(order([gen(1), asks(), settled("nope"), { type: "part_settled", of: "widget", id: "ci", was: "asks", now: null }, null, {}]),
    ["card:ci"]);
  assert.deepEqual(settleOrder(undefined).pieces, []);
  assert.deepEqual(settleOrder("x").pieces, []);
});

test("a question still waiting at the end, or cancelled, has its piece", () => {
  assert.deepEqual(order([gen(1), asked("q1")]), ["question:q1"]);
  assert.deepEqual(order([gen(1), asks(), gen(2), asked("q1"), { type: "question_cancelled", id: "q1" }]), ["question:q1", "card:ci"]);
});

test("the turn opens before a lead-in: a line merged or a reminder that came earlier goes first", () => {
  const merged = { type: "merged_input", content: "also b" };
  assert.deepEqual(order([{ type: "turn_started" }, merged, gen(1), text(1, "I'll run it"), asked("q1"), answered("q1")]), ["merged", "question:q1"]);
  assert.deepEqual(order([gen(1), { type: "reminder_injected", reminders: [] }, gen(2), text(2, "Run."), asked("a1"), answered("a1")]),
    ["reminder", "question:a1"]);
});
