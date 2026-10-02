import test from "node:test";
import assert from "node:assert/strict";
import { applySessionEvent, heldOrder, listedSessions, sortedByUpdated, waitingBadge, waitingFirst, withChildrenAfterParents } from "../../../lib/samagotchi/web/public/sessions_list.js";

// The page's session list is a projection of the hub's events: a snapshot
// replaces it, an upsert keeps a known card in place, a new one goes on
// top, a removal drops it.
const a = { id: "a", updated_at: "2026-09-25T10:00:00.000Z", last_prompt: "one" };
const b = { id: "b", updated_at: "2026-09-25T09:00:00.000Z", last_prompt: "two" };

test("a snapshot replaces the list", () => {
  assert.deepEqual(applySessionEvent([a], "snapshot", { sessions: [b, a] }), [b, a]);
  assert.deepEqual(applySessionEvent([a], "snapshot", {}), []);
});

test("a session event for a new id goes on top", () => {
  const c = { id: "c", updated_at: "2026-09-25T11:00:00.000Z" };
  assert.deepEqual(applySessionEvent([a, b], "session", { session: c }), [c, a, b]);
});

test("a session event for a known id replaces it in place, never mutating the old list", () => {
  const list = [a, b];
  const b2 = { ...b, last_prompt: "two again", updated_at: "2026-09-25T12:00:00.000Z" };
  const next = applySessionEvent(list, "session", { session: b2 });
  assert.deepEqual(next, [a, b2]);
  assert.deepEqual(list, [a, b]);
});

test("session_gone removes the id; an unknown id is a no-op that returns the same list", () => {
  const list = [a, b];
  assert.deepEqual(applySessionEvent(list, "session_gone", { id: "a" }), [b]);
  assert.equal(applySessionEvent(list, "session_gone", { id: "zzz" }), list);
});

test("a frame without a session, or of an unknown type, leaves the list as it is", () => {
  const list = [a];
  assert.equal(applySessionEvent(list, "session", {}), list);
  assert.equal(applySessionEvent(list, "whatever", { session: b }), list);
});

test("the all view re-sorts by updated_at desc, as the server lists", () => {
  const c = { id: "c", updated_at: "2026-09-25T12:00:00.000Z" };
  const odd = { id: "d", updated_at: "not a date" };
  assert.deepEqual(sortedByUpdated([b, odd, c, a]).map((s) => s.id), ["c", "a", "b", "d"]);
});

test("the all view puts a delegated session right after its parent; the family keeps its newest member's place", () => {
  const parent = { id: "p", updated_at: "2026-09-25T08:00:00.000Z" };
  const child1 = { id: "c1", parent_id: "p", updated_at: "2026-09-25T11:00:00.000Z" };
  const child2 = { id: "c2", parent_id: "p", updated_at: "2026-09-25T09:30:00.000Z" };
  const other = { id: "o", updated_at: "2026-09-25T10:00:00.000Z" };
  const orphan = { id: "x", parent_id: "gone", updated_at: "2026-09-25T09:00:00.000Z" };
  const sorted = sortedByUpdated([parent, child1, child2, other, orphan]);
  assert.deepEqual(sorted.map((s) => s.id), ["c1", "o", "c2", "x", "p"]);
  assert.deepEqual(withChildrenAfterParents(sorted).map((s) => s.id), ["p", "c1", "c2", "o", "x"]);
  // Nothing to group: the same array comes back.
  const plain = [other, orphan];
  assert.equal(withChildrenAfterParents(plain), plain);
});

test("listedSessions leaves archived sessions out unless asked, and keeps the list's order", () => {
  const hidden = { id: "h", archived: true };
  const list = [a, hidden, b];
  assert.deepEqual(listedSessions(list), [a, b]);
  assert.deepEqual(listedSessions(list, true), [a, hidden, b]);
  assert.deepEqual(listedSessions([]), []);
});

// A card's "needs you" badge follows notify.js's waitingOn.
test("waitingBadge says what the session waits on the user for", () => {
  assert.deepEqual(waitingBadge({ id: "s", pending_question: { id: "q", kind: "question" } }), { kind: "question", text: "question", title: "Waiting for your answer" });
  assert.equal(waitingBadge({ id: "s", pending_question: { id: "q", kind: "approval" } }).text, "approval");
  assert.equal(waitingBadge({ id: "s", pending_card: { id: "c" } }).text, "needs you");
  assert.equal(waitingBadge({ id: "s", pending_question: null, pending_card: null }), null);
});

const ids = (list) => list.map((s) => s.id);
const asks = (id, extra = {}) => ({ id, pending_question: { id: `q-${id}` }, ...extra });

test("waitingFirst lifts the sessions that wait on the user, each part in the list's order", () => {
  const list = [{ id: "a" }, asks("b"), { id: "c" }, { id: "d", pending_card: { id: "k" } }];
  assert.deepEqual(ids(waitingFirst(list)), ["b", "d", "a", "c"]);
});

test("waitingFirst: nobody waiting returns the same list; answered goes back to its place", () => {
  const list = [{ id: "a" }, { id: "b" }, { id: "c" }];
  assert.equal(waitingFirst(list), list);
  const answered = [{ id: "a" }, { id: "b", pending_question: null }, { id: "c" }];
  assert.deepEqual(ids(waitingFirst(answered)), ["a", "b", "c"]);
});

test("waitingFirst moves a delegated family together, whichever member waits", () => {
  const list = [{ id: "x" }, { id: "p" }, asks("ch", { parent_id: "p" }), { id: "y" }];
  assert.deepEqual(ids(waitingFirst(list)), ["p", "ch", "x", "y"]);
  // A child whose parent is not listed is its own family.
  assert.deepEqual(ids(waitingFirst([{ id: "x" }, asks("ch", { parent_id: "gone" })])), ["ch", "x"]);
});

test("heldOrder keeps an order shown before; new sessions go after, gone ones drop", () => {
  const list = [asks("b"), { id: "a" }, { id: "n" }, { id: "c" }];
  assert.deepEqual(ids(heldOrder(["a", "b", "c", "gone"], list)), ["a", "b", "c", "n"]);
});
