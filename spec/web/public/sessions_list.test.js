import test from "node:test";
import assert from "node:assert/strict";
import { applySessionEvent, batchCounts, batchTargets, batchToastText, heldOrder, inTree, listedSessions, sortedByUpdated, stoppedBadge, waitingBadge, waitingFirst, rangeIds, runBatch, waitingSearchText, withChildrenAfterParents } from "../../../lib/samagotchi/web/public/sessions_list.js";

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

test("withChildrenAfterParents nests at any depth: a grandchild follows its own parent, depth first", () => {
  const p = { id: "p" };
  const c = { id: "c", parent_id: "p" };
  const g = { id: "g", parent_id: "c" };
  const x = { id: "x" };
  assert.deepEqual(withChildrenAfterParents([g, c, p, x]).map((s) => s.id), ["p", "c", "g", "x"]);
  // Siblings in the list's order, each followed by its own subtree.
  const c2 = { id: "c2", parent_id: "p" };
  const g2 = { id: "g2", parent_id: "c2" };
  assert.deepEqual(withChildrenAfterParents([c2, g, x, c, g2, p]).map((s) => s.id), ["x", "p", "c2", "g2", "c", "g"]);
});

test("withChildrenAfterParents: a family's place comes from its newest member at any depth", () => {
  const p = { id: "p", updated_at: "2026-09-25T08:00:00.000Z" };
  const c = { id: "c", parent_id: "p", updated_at: "2026-09-25T08:30:00.000Z" };
  const g = { id: "g", parent_id: "c", updated_at: "2026-09-25T12:00:00.000Z" };
  const o = { id: "o", updated_at: "2026-09-25T10:00:00.000Z" };
  assert.deepEqual(withChildrenAfterParents([o, c, p, g]).map((s) => s.id), ["p", "c", "g", "o"]);
});

test("withChildrenAfterParents shows every session of a parent cycle once", () => {
  const a = { id: "a", parent_id: "b", updated_at: "2026-09-25T09:00:00.000Z" };
  const b = { id: "b", parent_id: "a", updated_at: "2026-09-25T08:00:00.000Z" };
  const k = { id: "k", parent_id: "b", updated_at: "2026-09-25T07:00:00.000Z" };
  const self = { id: "s", parent_id: "s", updated_at: "2026-09-25T10:00:00.000Z" };
  assert.deepEqual(withChildrenAfterParents([self, a, b, k]).map((s) => s.id), ["s", "a", "b", "k"]);
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
  assert.deepEqual(waitingBadge({ id: "s", status: "idle", pending_question: { id: "c", kind: "continue" } }),
    { kind: "continue", text: "out of steps", title: "The turn hit its step limit: continue or stop it" });
  assert.equal(waitingBadge({ id: "s", pending_question: { id: "q", kind: "approval" } }).text, "approval");
  assert.equal(waitingBadge({ id: "s", pending_card: { id: "c" } }).text, "needs you");
  assert.equal(waitingBadge({ id: "s", pending_question: null, pending_card: null }), null);
});

const ids = (list) => list.map((s) => s.id);
const asks = (id, extra = {}) => ({ id, pending_question: { id: `q-${id}` }, ...extra });

test("waitingFirst lifts the sessions that wait on the user, each part in the list's order", () => {
  const list = [{ id: "a" }, asks("b"), { id: "c" }, { id: "d", pending_card: { id: "k" } }];
  assert.deepEqual(ids(waitingFirst(list)), ["b", "d", "a", "c"]);
  // An idle session at its step limit waits too.
  const limited = [{ id: "a" }, { id: "e", status: "idle", pending_question: { id: "c", kind: "continue" } }];
  assert.deepEqual(ids(waitingFirst(limited)), ["e", "a"]);
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

test("waitingFirst moves a nested family together, whichever depth waits; a cycle ends the walk", () => {
  const family = [{ id: "x" }, { id: "p" }, { id: "c", parent_id: "p" }, { id: "g", parent_id: "c" }];
  const waitingG = family.map((s) => (s.id === "g" ? asks("g", { parent_id: "c" }) : s));
  assert.deepEqual(ids(waitingFirst(waitingG)), ["p", "c", "g", "x"]);
  const waitingC = family.map((s) => (s.id === "c" ? asks("c", { parent_id: "p" }) : s));
  assert.deepEqual(ids(waitingFirst(waitingC)), ["p", "c", "g", "x"]);
  const cycle = [{ id: "x" }, { id: "a", parent_id: "b" }, asks("b", { parent_id: "a" })];
  assert.deepEqual(ids(waitingFirst(cycle)), ["a", "b", "x"]);
});

test("heldOrder keeps an order shown before; new sessions go after, gone ones drop", () => {
  const list = [asks("b"), { id: "a" }, { id: "n" }, { id: "c" }];
  assert.deepEqual(ids(heldOrder(["a", "b", "c", "gone"], list)), ["a", "b", "c", "n"]);
});

test("waitingSearchText: what the all view's search matches for a waiting session (its badge, its kind, waiting)", () => {
  assert.equal(waitingSearchText({ pending_question: { id: "q1", kind: "question" } }), "waiting question");
  assert.equal(waitingSearchText({ pending_question: { id: "q1", kind: "approval" } }), "waiting approval");
  assert.equal(waitingSearchText({ pending_card: { id: "c1" } }), "waiting needs you");
  assert.equal(waitingSearchText({ status: "idle" }), "");
});

test("waitingBadge: a delegate's question relayed to its parent says where it waits", () => {
  const badge = waitingBadge({ id: "c", parent_id: "p", pending_question: { id: "q", kind: "approval", relayed_to: "pppp1111" } });
  assert.deepEqual(badge, { kind: "approval", text: "in parent pppp1111",
    title: "Waiting for your approval in parent session pppp1111 (answering here works too)" });
  assert.equal(waitingSearchText({ id: "c", pending_question: { id: "q", kind: "approval", relayed_to: "pppp1111" } }), "waiting in parent pppp1111");
});

// A card's badge for a turn a hook stopped (the same marker as `chi sessions
// list`'s "[looped]" / "[stopped by X]"): "looped" for loop-guard, "stopped by
// <name>" for any other hook; null when the last turn ended otherwise.
test("stoppedBadge: loop-guard says looped, another hook its name, otherwise null", () => {
  assert.deepEqual(stoppedBadge({ id: "s", last_turn: { outcome: "canceled", cancel_reason: "hook", stopped_by: "loop-guard" } }),
    { text: "looped", title: "loop-guard stopped the last turn" });
  assert.deepEqual(stoppedBadge({ id: "s", last_turn: { outcome: "canceled", cancel_reason: "hook", stopped_by: "my-hook" } }),
    { text: "stopped by my-hook", title: "my-hook stopped the last turn" });
  assert.equal(stoppedBadge({ id: "s", last_turn: { outcome: "completed", ended_at: "t" } }), null);
  assert.equal(stoppedBadge({ id: "s", last_turn: null }), null);
  assert.equal(stoppedBadge({ id: "s" }), null);
});

test("waitingSearchText matches the stopped badge's words too (looped, stopped by <name>)", () => {
  assert.equal(waitingSearchText({ last_turn: { stopped_by: "loop-guard" } }), "looped");
  assert.equal(waitingSearchText({ last_turn: { stopped_by: "my-hook" } }), "stopped by my-hook");
  // Both, when the session waits and its last turn a hook stopped: a search
  // for either word finds it.
  assert.equal(waitingSearchText({ pending_question: { id: "q", kind: "question" }, last_turn: { stopped_by: "loop-guard" } }), "waiting question looped");
  assert.equal(waitingSearchText({ status: "idle" }), "");
});

test("inTree: the session itself and its delegates at any depth, not its parent", () => {
  const list = [{ id: "p" }, { id: "c", parent_id: "p" }, { id: "g", parent_id: "c" }, { id: "x" }, { id: "loop", parent_id: "loop" }];
  assert.equal(inTree(list, "p", "p"), true);
  assert.equal(inTree(list, "p", "c"), true);
  assert.equal(inTree(list, "p", "g"), true);
  assert.equal(inTree(list, "c", "p"), false);
  assert.equal(inTree(list, "p", "x"), false);
  assert.equal(inTree(list, "p", null), false);
  assert.equal(inTree(list, "p", "loop"), false);
});

// ── Select mode ──────────────────────────────────────────────────────────

test("rangeIds: the ids between two drawn ids, both included, either way", () => {
  const order = ["a", "b", "c", "d", "e"];
  assert.deepEqual(rangeIds(order, "b", "d"), ["b", "c", "d"]);
  assert.deepEqual(rangeIds(order, "d", "b"), ["b", "c", "d"]);
  assert.deepEqual(rangeIds(order, "c", "c"), ["c"]);
});

test("rangeIds: just the clicked id when the last pick isn't drawn", () => {
  assert.deepEqual(rangeIds(["a", "b"], null, "b"), ["b"]);
  assert.deepEqual(rangeIds(["a", "b"], "gone", "a"), ["a"]);
  assert.deepEqual(rangeIds(["a", "b"], "a", "gone"), []);
});

test("batchTargets: picked and shown, in the drawn order, by archived state", () => {
  const byId = new Map([
    ["a", { id: "a" }], ["b", { id: "b", archived: true }], ["c", { id: "c" }], ["d", { id: "d" }],
  ]);
  const picked = new Set(["d", "a", "b", "hidden"]);
  const shown = ["a", "b", "c", "d"];
  assert.deepEqual(batchTargets(picked, shown, true, byId), ["a", "d"]);
  assert.deepEqual(batchTargets(picked, shown, false, byId), ["b"]);
  // A pick the search hides is not acted on.
  assert.deepEqual(batchTargets(picked, ["b", "c"], true, byId), []);
});

const refusal = (code, message, status = 409) => Object.assign(new Error(message), { code, status });

test("runBatch: one at a time, a delegate a parent's answer covered is not sent again", async () => {
  const sent = [];
  let inFlight = 0;
  const act = async (id) => {
    sent.push(id);
    inFlight++;
    assert.equal(inFlight, 1, "one request at a time");
    await new Promise((r) => setTimeout(r, 1));
    inFlight--;
    if (id === "p") return { ok: true, result: { archived: ["p", "c1", "c2"], discarded: ["c3"] } };
    return { ok: true, result: { archived: [id] } };
  };
  const out = await runBatch(["p", "c1", "c3", "x"], act);
  assert.deepEqual(sent, ["p", "x"]);
  assert.deepEqual(out.done, ["p", "x"]);
  assert.deepEqual(out.covered, ["c1", "c3"]);
  assert.deepEqual(batchCounts(out, true), { done: 4, delegates: 1, skipped: 0, archive: true });
});

test("runBatch: a refusal mid-batch is skipped with its reason and the rest goes on", async () => {
  const act = async (id) => (id === "b"
    ? { ok: false, error: refusal("busy", "session b has a turn running (409)") }
    : { ok: true, result: { archived: [id] } });
  const out = await runBatch(["a", "b", "c"], act);
  assert.deepEqual(out.done, ["a", "c"]);
  assert.deepEqual(out.skipped, [{ id: "b", code: "busy", reason: "session b has a turn running" }]);
  assert.equal(batchToastText(batchCounts(out, true)), "Archived 2 · 1 skipped");
});

test("runBatch: a 404 is gone, not skipped", async () => {
  const act = async (id) => (id === "a" ? { ok: false, error: refusal("not_found", "no session a (404)", 404) } : { ok: true, result: { unarchived: [id] } });
  const out = await runBatch(["a", "b"], act);
  assert.deepEqual(out.gone, ["a"]);
  assert.deepEqual(out.skipped, []);
  assert.deepEqual(out.done, ["b"]);
});

test("runBatch: reports progress after each id, covered ones too", async () => {
  const calls = [];
  const act = async () => ({ ok: true, result: { archived: ["a", "b"] } });
  await runBatch(["a", "b", "c"], act, (n, total) => calls.push([n, total]));
  assert.deepEqual(calls, [[1, 3], [2, 3], [3, 3]]);
});

test("batchToastText: the end toast's words", () => {
  assert.equal(batchToastText({ done: 7, archive: true }), "Archived 7");
  assert.equal(batchToastText({ done: 3, delegates: 2, archive: true }), "Archived 3 (+2 delegates)");
  assert.equal(batchToastText({ done: 1, delegates: 1, archive: true }), "Archived 1 (+1 delegate)");
  assert.equal(batchToastText({ done: 5, skipped: 2, archive: true }), "Archived 5 · 2 skipped");
  assert.equal(batchToastText({ done: 0, skipped: 2, archive: true }), "None archived: 2 skipped");
  assert.equal(batchToastText({ done: 7, archive: false }), "Unarchived 7");
  assert.equal(batchToastText({ done: 6, skipped: 1, archive: false }), "Unarchived 6 · 1 skipped");
});
