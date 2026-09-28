import test from "node:test";
import assert from "node:assert/strict";
import { attentionFor, attentionText, initialAttentionState, trackAttention } from "../../../lib/samagotchi/web/public/notify.js";

// What in a session's summary change needs the user: an open question,
// a failed turn, a long turn done. The first snapshot only seeds.
const base = { id: "s1", first_preview: "fix the build", pending_question: null, last_turn: null };
const turn = (outcome, seconds, ended_at = "2026-09-28T10:00:00.000Z") => ({ outcome, seconds, ended_at, origin: "client" });

test("a new question needs an answer, keyed by its id", () => {
  const next = { ...base, pending_question: { id: "q1", kind: "question" } };
  assert.deepEqual(attentionFor(base, next), { reason: "question", sessionId: "s1", key: "s1:q1" });
});

test("the same question twice is one", () => {
  const next = { ...base, pending_question: { id: "q1", kind: "question" } };
  assert.equal(attentionFor(next, { ...next, updated_at: "later" }), null);
});

test("a guardrail approval needs approval; no kind is a question", () => {
  assert.equal(attentionFor(base, { ...base, pending_question: { id: "q1", kind: "approval" } }).reason, "approval");
  assert.equal(attentionFor(base, { ...base, pending_question: { id: "q1" } }).reason, "question");
});

test("a turn done under 10 s was watched; 10 s and over is done", () => {
  assert.equal(attentionFor(base, { ...base, last_turn: turn("completed", 9.9) }), null);
  assert.deepEqual(attentionFor(base, { ...base, last_turn: turn("completed", 10) }),
    { reason: "done", sessionId: "s1", key: "s1:2026-09-28T10:00:00.000Z" });
});

test("a failed turn, however short; a canceled one never", () => {
  assert.equal(attentionFor(base, { ...base, last_turn: turn("failed", 1) }).reason, "failed");
  assert.equal(attentionFor(base, { ...base, last_turn: turn("canceled", 60) }), null);
});

test("the same finished turn seen again is nothing", () => {
  const done = { ...base, last_turn: turn("completed", 30) };
  assert.equal(attentionFor(done, { ...done, status: "idle" }), null);
});

test("a delegated child: questions yes, done and failed no", () => {
  const child = { ...base, parent_id: "p1" };
  assert.equal(attentionFor(child, { ...child, last_turn: turn("completed", 30) }), null);
  assert.equal(attentionFor(child, { ...child, last_turn: turn("failed", 3) }), null);
  assert.equal(attentionFor(child, { ...child, pending_question: { id: "q1" } }).reason, "question");
});

test("the first snapshot seeds and never notifies, even for an open question", () => {
  const open = { ...base, pending_question: { id: "q1" }, last_turn: turn("failed", 3) };
  const { state, attentions } = trackAttention(initialAttentionState(), "snapshot", { sessions: [open] });
  assert.deepEqual(attentions, []);
  assert.equal(state.seeded, true);
  // …and the same state in a session frame after it is nothing new.
  assert.deepEqual(trackAttention(state, "session", { session: open }).attentions, []);
});

test("a session frame before the first snapshot does not notify", () => {
  const open = { ...base, pending_question: { id: "q1" } };
  assert.deepEqual(trackAttention(initialAttentionState(), "session", { session: open }).attentions, []);
});

test("a later snapshot (a reconnect) is diffed like session frames", () => {
  let { state } = trackAttention(initialAttentionState(), "snapshot", { sessions: [base] });
  const open = { ...base, pending_question: { id: "q1" } };
  const r = trackAttention(state, "snapshot", { sessions: [open] });
  assert.deepEqual(r.attentions.map((a) => a.key), ["s1:q1"]);
  state = r.state;
  assert.deepEqual(trackAttention(state, "snapshot", { sessions: [open] }).attentions, []);
});

test("a new session after the seed notifies; a gone one is forgotten", () => {
  let { state } = trackAttention(initialAttentionState(), "snapshot", { sessions: [] });
  const r = trackAttention(state, "session", { session: { id: "s2", last_turn: turn("completed", 12) } });
  assert.equal(r.attentions[0].reason, "done");
  state = trackAttention(r.state, "session_gone", { id: "s2" }).state;
  assert.equal(state.byId.s2, undefined);
});

test("the words: session name and the reason, no question text", () => {
  const s = { ...base, last_turn: turn("completed", 42.4), pending_question: { id: "q1" } };
  assert.deepEqual(attentionText(s, { reason: "done" }), { title: "fix the build", body: "done in 42 s" });
  assert.equal(attentionText(s, { reason: "question" }).body, "needs an answer");
  assert.equal(attentionText(s, { reason: "approval" }).body, "needs approval");
  assert.equal(attentionText(s, { reason: "failed" }).body, "turn failed");
  assert.equal(attentionText({ id: "x" }, { reason: "failed" }).title, "chi session");
});

test("a question answered (here or in another client) is closed; a new one is closed and needs an answer", () => {
  const open = { ...base, pending_question: { id: "q1", kind: "question" } };
  let { state } = trackAttention(initialAttentionState(), "snapshot", { sessions: [open] });
  assert.deepEqual(trackAttention(state, "session", { session: open }).closed, []);
  const answered = trackAttention(state, "session", { session: base });
  assert.deepEqual(answered.closed, ["s1:q1"]);
  assert.deepEqual(answered.attentions, []);
  const next = trackAttention(state, "session", { session: { ...base, pending_question: { id: "q2" } } });
  assert.deepEqual(next.closed, ["s1:q1"]);
  assert.deepEqual(next.attentions.map((a) => a.key), ["s1:q2"]);
});

test("a gone session closes its open question; one without a question closes nothing", () => {
  const open = { ...base, pending_question: { id: "q1", kind: "approval" } };
  const { state } = trackAttention(initialAttentionState(), "snapshot", { sessions: [open, { ...base, id: "s2" }] });
  assert.deepEqual(trackAttention(state, "session_gone", { id: "s1" }).closed, ["s1:q1"]);
  assert.deepEqual(trackAttention(state, "session_gone", { id: "s2" }).closed, []);
  assert.deepEqual(trackAttention(state, "session_gone", { id: "nope" }).closed, []);
});

// A running turn's card with actions (check-in's) asks like a question: the
// hub's summary carries pending_card {id, bundle} while it is open.
test("a new card with actions needs you, once per card id", () => {
  const open = { ...base, status: "running", pending_card: { id: "check-in-1", bundle: "check-in" } };
  assert.deepEqual(attentionFor(base, open), { reason: "card", sessionId: "s1", key: "s1:card:check-in-1" });
  assert.equal(attentionFor(open, { ...open, updated_at: "later" }), null);
  const again = { ...open, pending_card: { id: "check-in-2", bundle: "check-in" } };
  assert.equal(attentionFor(open, again).key, "s1:card:check-in-2");
  assert.equal(attentionText(open, { reason: "card" }).body, "needs you");
});

test("a card resolved, or its turn ended, is closed; a gone session closes it too", () => {
  const open = { ...base, status: "running", pending_card: { id: "c1", bundle: "check-in" } };
  const { state } = trackAttention(initialAttentionState(), "snapshot", { sessions: [base] });
  const shown = trackAttention(state, "session", { session: open });
  assert.deepEqual(shown.attentions.map((a) => a.reason), ["card"]);
  assert.deepEqual(trackAttention(shown.state, "session", { session: open }).closed, []);
  const resolved = trackAttention(shown.state, "session", { session: { ...open, pending_card: null } });
  assert.deepEqual(resolved.closed, ["s1:card:c1"]);
  assert.deepEqual(resolved.attentions, []);
  const ended = trackAttention(shown.state, "session", { session: { ...base, pending_card: null, last_turn: turn("canceled", 30) } });
  assert.deepEqual(ended.closed, ["s1:card:c1"]);
  assert.deepEqual(trackAttention(shown.state, "session_gone", { id: "s1" }).closed, ["s1:card:c1"]);
});

test("an open card in the first snapshot seeds and never notifies", () => {
  const open = { ...base, pending_card: { id: "c1", bundle: "check-in" } };
  const { attentions } = trackAttention(initialAttentionState(), "snapshot", { sessions: [open] });
  assert.deepEqual(attentions, []);
});
