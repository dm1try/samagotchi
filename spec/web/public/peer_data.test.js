// The open session's peers model (peer_data.js): the 404 of an older chi
// web, the stale-answer guard, no request without a peer, the lookups.
import test from "node:test";
import assert from "node:assert/strict";
import { createPeers, listPeers } from "../../../lib/samagotchi/web/public/peer_data.js";

const answered = { id: "s-1", kind: "validate", title: "A", at: "2026-11-20T10:00:00Z", state: "answered",
                   answer: { summary: "A: VERDICT OK", at: "2026-11-20T10:05:00Z", serial: 7, verdict: "OK" } };
const waiting = { id: "s-2", kind: "question", title: "B", at: "2026-11-20T10:06:00Z", state: "waiting" };
const PEERS = { peers: [{ name: "claude", label: "Claude", inbox: true, outbox: true, exchanges: [waiting, answered] }] };

// A window with recorded intervals and its focus listeners.
function fakeWin() {
  const win = { intervals: new Map(), focus: [], next: 1 };
  win.setInterval = (fn, ms) => { const id = win.next++; win.intervals.set(id, { fn, ms }); return id; };
  win.clearInterval = (id) => win.intervals.delete(id);
  win.addEventListener = (type, fn) => { if (type === "focus") win.focus.push(fn); };
  return win;
}

test("listPeers: an older chi web's 404 is an empty list, another failure throws", async () => {
  const answer = (status, body) => async () => ({ ok: status < 400, status, statusText: "x", json: async () => body });
  assert.deepEqual(await listPeers("s1", { fetchImpl: answer(404, { error: "not_found" }) }), { peers: [] });
  assert.deepEqual(await listPeers("s1", { fetchImpl: answer(200, PEERS) }), PEERS);
  await assert.rejects(listPeers("s1", { fetchImpl: answer(500, { error: "boom" }) }), /boom/);
});

test("no request for a session without a peer, nor with none open", async () => {
  const calls = [];
  let open = "s1";
  const peers = createPeers({ sessionId: () => open, hasPeer: () => false, list: async (id) => { calls.push(id); return PEERS; }, win: fakeWin() });
  assert.equal(await peers.refresh(), false);
  open = null;
  assert.equal(await peers.refresh(), false);
  assert.deepEqual(calls, []);
  assert.equal(peers.loaded(), false);
});

test("a read: the newest exchange of an id, an answer by its serial or its re, onChange, the waiting tick", async () => {
  const win = fakeWin();
  let changes = 0;
  const peers = createPeers({ sessionId: () => "s1", hasPeer: () => true, onChange: () => { changes += 1; }, list: async () => PEERS, win });
  assert.equal(await peers.refresh(), true);
  assert.equal(changes, 1);
  assert.equal(peers.loaded(), true);
  assert.equal(peers.exchange("s-1").state, "answered");
  assert.equal(peers.exchange("s-1").peer, "claude");
  assert.equal(peers.exchange("s-9"), null);
  assert.equal(peers.answer("claude", "7").id, "s-1");
  assert.equal(peers.answer("claude", null, "s-1").id, "s-1");
  assert.equal(peers.answer("claude", "8"), null);
  assert.equal(peers.answer("codex", "7"), null);
  // One interval while s-2 waits, read again on it and on focus.
  assert.equal(win.intervals.size, 1);
  assert.equal([...win.intervals.values()][0].ms, 60_000);
  win.focus.forEach((fn) => fn());
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(changes, 2);
  peers.clear();
  assert.equal(win.intervals.size, 0);
  assert.equal(peers.loaded(), false);
  assert.equal(peers.exchange("s-1"), null);
});

test("a resend keeps one id: the newest exchange of it wins", async () => {
  const older = { ...answered, at: "2026-11-20T09:00:00Z" };
  const newer = { ...waiting, id: "s-1", at: "2026-11-20T11:00:00Z" };
  const peers = createPeers({ sessionId: () => "s1", hasPeer: () => true, win: fakeWin(),
                              list: async () => ({ peers: [{ name: "claude", exchanges: [older, newer] }] }) });
  await peers.refresh();
  assert.equal(peers.exchange("s-1").state, "waiting");
});

test("stale answers: an older read landing last, or one for a session left, is dropped", async () => {
  let open = "s1";
  const pending = [];
  const peers = createPeers({ sessionId: () => open, hasPeer: () => true, win: fakeWin(),
                              list: () => new Promise((resolve) => pending.push(resolve)) });
  const first = peers.refresh();
  const second = peers.refresh();
  pending[1]({ peers: [{ name: "claude", exchanges: [waiting] }] });
  pending[0](PEERS);
  assert.equal(await second, true);
  assert.equal(await first, false);
  assert.equal(peers.exchange("s-1"), null);
  assert.equal(peers.exchange("s-2").state, "waiting");
  const third = peers.refresh();
  open = "s2";
  pending[2](PEERS);
  assert.equal(await third, false);
  // What s1 read isn't s2's.
  assert.equal(peers.exchange("s-2"), null);
  assert.equal(peers.loaded(), false);
});

test("a failed read keeps what was read and still tells the page", async () => {
  let fail = false;
  let changes = 0;
  const peers = createPeers({ sessionId: () => "s1", hasPeer: () => true, onChange: () => { changes += 1; }, win: fakeWin(),
                              list: async () => { if (fail) throw new Error("offline"); return PEERS; } });
  await peers.refresh();
  fail = true;
  assert.equal(await peers.refresh(), true);
  assert.equal(changes, 2);
  assert.equal(peers.exchange("s-1").state, "answered");
});

test("a second answer to one send (an unclaimed row of its own) still names that send by its re; peer() and touch()", async () => {
  const second = { id: null, at: "2026-11-20T10:07:00Z", state: "answered", answer: { summary: "A: one more thing", at: "2026-11-20T10:07:00Z", serial: 8 } };
  let changes = 0;
  const peers = createPeers({ sessionId: () => "s1", hasPeer: () => true, win: fakeWin(), onChange: () => { changes += 1; },
                              list: async () => ({ peers: [{ name: "claude", exchanges: [second, waiting, answered] }] }) });
  peers.touch();
  assert.equal(changes, 0);
  await peers.refresh();
  assert.equal(peers.answer("claude", "8", "s-1").id, "s-1");
  // Without a re it stays unclaimed.
  assert.equal(peers.answer("claude", "8"), null);
  assert.equal(peers.answer("claude", "7").id, "s-1");
  assert.equal(peers.peer("claude").name, "claude");
  assert.equal(peers.peer("codex"), null);
  peers.touch();
  assert.equal(changes, 2);
});
