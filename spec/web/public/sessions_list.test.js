import test from "node:test";
import assert from "node:assert/strict";
import { applySessionEvent, sortedByUpdated } from "../../../lib/samagotchi/web/public/sessions_list.js";

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
