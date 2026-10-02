import test from "node:test";
import assert from "node:assert/strict";
import { RELAY_HOLD_MS, attentionFor, attentionText, createNotifyGate, initialAttentionState, notifyState, trackAttention, waitingOn } from "../../../lib/samagotchi/web/public/notify.js";

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

// Several tabs: a BroadcastChannel stand-in (a message reaches the other
// tabs, never the sender) and a scheduler the test runs by hand.
function channels(n) {
  const all = [];
  for (let i = 0; i < n; i++) {
    const ch = { onmessage: null, postMessage(data) { for (const other of all) if (other !== ch) other.onmessage?.({ data }); } };
    all.push(ch);
  }
  return all;
}
function clock() {
  const timers = new Map();
  let next = 1;
  return {
    schedule: (fn) => { timers.set(next, fn); return next++; },
    cancel: (id) => timers.delete(id),
    run() { const fns = [...timers.values()]; timers.clear(); fns.forEach((fn) => fn()); },
    get size() { return timers.size; },
  };
}
const q1 = { reason: "question", sessionId: "s1", key: "s1:q1" };

test("a tab behind holds an attention and drops it when a tab in front has it", () => {
  const [front, behind] = channels(2);
  const c = clock();
  const seen = [];
  const a = createNotifyGate({ channel: front, schedule: c.schedule, cancel: c.cancel });
  const b = createNotifyGate({ channel: behind, schedule: c.schedule, cancel: c.cancel, onSeen: (keys) => seen.push(...keys) });
  const delivered = [];
  b.offer(q1, () => delivered.push(q1.key));
  a.seenInFront([q1.key]);
  c.run();
  assert.deepEqual(delivered, []);
  assert.deepEqual(seen, ["s1:q1"]);
});

test("the front tab's word first: the tab behind never holds it", () => {
  const [front, behind] = channels(2);
  const c = clock();
  const b = createNotifyGate({ channel: behind, schedule: c.schedule, cancel: c.cancel });
  createNotifyGate({ channel: front }).seenInFront([q1.key]);
  assert.equal(b.offer(q1, () => assert.fail("delivered")), false);
  assert.equal(c.size, 0);
});

test("no tab in front: delivered after the hold; a closed one is dropped", () => {
  const [ch] = channels(1);
  const c = clock();
  const b = createNotifyGate({ channel: ch, schedule: c.schedule, cancel: c.cancel });
  const delivered = [];
  b.offer(q1, () => delivered.push(q1.key));
  b.offer({ ...q1, key: "s1:q2" }, () => delivered.push("s1:q2"));
  b.drop(["s1:q2"]);
  c.run();
  assert.deepEqual(delivered, ["s1:q1"]);
});

test("without BroadcastChannel every tab delivers at once", () => {
  const c = clock();
  const b = createNotifyGate({ channel: null, schedule: c.schedule, cancel: c.cancel });
  const delivered = [];
  assert.equal(b.offer(q1, () => delivered.push(q1.key)), true);
  assert.deepEqual(delivered, ["s1:q1"]);
  b.seenInFront([q1.key]); // no channel: nothing to tell, no throw
});

test("a word about other keys or a stray message changes nothing", () => {
  const [front, behind] = channels(2);
  const c = clock();
  const b = createNotifyGate({ channel: behind, schedule: c.schedule, cancel: c.cancel });
  const delivered = [];
  b.offer(q1, () => delivered.push(q1.key));
  createNotifyGate({ channel: front }).seenInFront(["s2:q9"]);
  front.postMessage({ type: "other" });
  c.run();
  assert.deepEqual(delivered, ["s1:q1"]);
});

// The bell: "on" | "off" | "denied" | "unsupported" (hidden). An insecure
// origin (chi web on a LAN address over http) has no working
// notifications: the bell is hidden there, the title badge stays.
test("the bell is unsupported without Notification or on an insecure origin", () => {
  assert.equal(notifyState({ hasNotification: false, secureContext: true, permission: "granted", wanted: true }), "unsupported");
  assert.equal(notifyState({ hasNotification: true, secureContext: false, permission: "granted", wanted: true }), "unsupported");
  assert.equal(notifyState({ hasNotification: true, secureContext: false, permission: "default", wanted: false }), "unsupported");
});

test("the bell is denied, on or off on a secure origin", () => {
  const secure = { hasNotification: true, secureContext: true };
  assert.equal(notifyState({ ...secure, permission: "denied", wanted: true }), "denied");
  assert.equal(notifyState({ ...secure, permission: "granted", wanted: true }), "on");
  assert.equal(notifyState({ ...secure, permission: "granted", wanted: false }), "off");
  assert.equal(notifyState({ ...secure, permission: "default", wanted: true }), "off");
});

// The session cards' "needs you" (app.js cardHtml): what the session waits on now.
test("waitingOn names an open question, an approval or a card with actions; else null", () => {
  assert.deepEqual(waitingOn({ ...base, pending_question: { id: "q1", kind: "question" } }), { reason: "question", id: "q1" });
  assert.deepEqual(waitingOn({ ...base, pending_question: { id: "q1", kind: "approval" } }), { reason: "approval", id: "q1" });
  assert.deepEqual(waitingOn({ ...base, pending_card: { id: "c1" } }), { reason: "card", id: "c1" });
  assert.equal(waitingOn(base), null);
  assert.equal(waitingOn({ ...base, pending_question: {} }), null);
  assert.equal(waitingOn(null), null);
});

test("waitingOn: a question wins over a card (the question blocks the turn)", () => {
  assert.equal(waitingOn({ ...base, pending_question: { id: "q1" }, pending_card: { id: "c1" } }).reason, "question");
});

test("attentionFor still sees a new card while an old question stays open", () => {
  const prev = { ...base, pending_question: { id: "q1" } };
  assert.equal(attentionFor(prev, { ...prev, pending_card: { id: "c1" } }).reason, "card");
});

// The approval relay: one bell, the parent's.
test("a delegated child's approval is held; one already relayed to the parent never notifies", () => {
  const child = { ...base, parent_id: "p1" };
  assert.deepEqual(attentionFor(child, { ...child, pending_question: { id: "q1", kind: "approval" } }),
    { reason: "approval", sessionId: "s1", key: "s1:q1", holdMs: RELAY_HOLD_MS });
  assert.equal(attentionFor(child, { ...child, pending_question: { id: "q1", kind: "approval", relayed_to: "p1aaaaaa" } }), null);
  // A question (the model's) isn't relayed: at once, as before.
  assert.equal(attentionFor(child, { ...child, pending_question: { id: "q1", kind: "question" } }).holdMs, undefined);
});

test("an approval relayed to the parent closes the child's key (its hold and its badge drop)", () => {
  const child = { ...base, parent_id: "p1", pending_question: { id: "q1", kind: "approval" } };
  const seeded = trackAttention(initialAttentionState(), "snapshot", { sessions: [{ ...base, parent_id: "p1" }] }).state;
  const opened = trackAttention(seeded, "session", { session: child });
  assert.equal(opened.attentions[0].holdMs, RELAY_HOLD_MS);
  const relayed = trackAttention(opened.state, "session", { session: { ...child, pending_question: { id: "q1", kind: "approval", relayed_to: "p1aaaaaa" } } });
  assert.deepEqual(relayed.attentions, []);
  assert.deepEqual(relayed.closed, ["s1:q1"]);
});

test("an attention with its own hold waits for it, also without BroadcastChannel, and drops when closed", () => {
  const timers = [];
  const gate = createNotifyGate({ schedule: (fn, ms) => { timers.push({ fn, ms }); return timers.length; }, cancel: (id) => { timers[id - 1].fn = null; } });
  const delivered = [];
  gate.offer({ key: "s1:q1", holdMs: 1500 }, () => delivered.push("q1"));
  gate.offer({ key: "s1:q2" }, () => delivered.push("q2"));
  assert.deepEqual(delivered, ["q2"]);
  assert.equal(timers[0].ms, 1500);
  gate.drop(["s1:q1"]);
  assert.equal(timers[0].fn, null);
});
