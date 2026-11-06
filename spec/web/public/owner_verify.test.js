// The owner page's Verify (owner_verify.js) over the owner's real history
// markup (turnHistoryNodes) and its session store: a verdict onto its card
// once, a fresh verdict settles its running check, Verify fresh's state, and
// Verify's claim only in an ended turn's final answer.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createOwnerVerify } from "../../../lib/samagotchi/web/public/owner_verify.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";
import { turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_block.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";
import { VERIFY_UNAVAILABLE } from "../../../lib/samagotchi/web/public/verify_preset.js";

const ITEMS = [
  { role: "user", content: "Is the cache keyed?", turn_id: "T1" },
  { role: "assistant", content: "Looking.", parts: { tools: [{ tool: "read", params: 'path="keys.rb"', output: "[read]\nok" }] } },
  { role: "user", content: "also the TTL", merged: true, step: 2 },
  { role: "assistant", content: "The cache is keyed by path." },
];
const RECORDS = [{ id: "T1", duration_ms: 5 }];
const VERDICT = { check_turn_id: "C1", verdict: "unclear", reason: "Can't tell.", anchor: { turn_id: "T1", quote: "keyed by path" } };

function harness({ running = false, turnId = null, current = {} } = {}) {
  const historyEl = document.createElement("div");
  historyEl.append(turnHistoryNodes(ITEMS, normalizeTiming({ turn_records: RECORDS }), { thumbs: () => "" }));
  document.body.appendChild(historyEl);
  const store = createSessionStore({ initial: { verdicts: [], verifyFresh: [], workerFeatures: ["verify"], bridgeUp: true, dir: "", ...current } });
  store.update({ selected: "s1aaaaaaaa", sessions: [{ id: "s1aaaaaaaa" }] });
  const posts = [];
  const toasts = [];
  const win = { location: { hash: "" } };
  const verify = createOwnerVerify({
    historyEl, store,
    api: async (path, opts) => { posts.push([path, opts]); return { child_id: "child1" }; },
    claim: { opts: () => ({ home: "", cwd: "" }) },
    liveTurn: { running, timing: { turnId } },
    toast: (text) => toasts.push(text),
    win,
  });
  const find = (text) => [...historyEl.querySelectorAll(".bubble.output, .gen-text, .bubble.user .user-message")]
    .find((el) => el.textContent.trim() === text);
  const select = (el, word) => {
    const node = [...el.querySelectorAll("*"), el].flatMap((e) => [...e.childNodes]).find((n) => n.nodeType === 3 && n.data.includes(word));
    const range = document.createRange();
    const at = node.data.indexOf(word);
    range.setStart(node, at);
    range.setEnd(node, at + word.length);
    return range;
  };
  return { verify, store, historyEl, posts, toasts, win, find, select, done: () => historyEl.remove() };
}

test("a verdict goes into the session's list once and onto its check's card once", () => {
  const h = harness();
  h.verify.placeVerdict(VERDICT);
  h.verify.placeVerdict(VERDICT);
  assert.equal(h.store.current.verdicts.length, 1);
  assert.equal(h.historyEl.querySelectorAll(".verify-verdict").length, 1);
  // Saved verdicts drawn again over the same history: still one of each.
  h.verify.renderSaved();
  assert.equal(h.store.current.verdicts.length, 1);
  assert.equal(h.historyEl.querySelectorAll(".verify-verdict").length, 1);
  h.verify.placeVerdict(null);
  h.done();
});

test("a fresh verdict settles its check's running Verify fresh", () => {
  const h = harness({ current: { verifyFresh: [{ of: "C1", child_id: "child1" }, { of: "C9", child_id: "child9" }] } });
  h.verify.placeVerdict(VERDICT);
  h.verify.placeVerdict({ check_turn_id: "F1", fresh: true, of: "C1", verdict: "confirmed", reason: "Yes." });
  assert.deepEqual(h.store.current.verifyFresh, [{ of: "C9", child_id: "child9" }]);
  h.done();
});

test("Verify fresh's state: startable with a session and a worker that has it; the start posts to the fresh route", async () => {
  const h = harness();
  const fresh = h.verify.freshState();
  assert.equal(fresh.canStart, true);
  assert.equal(fresh.unavailableReason, null);
  assert.equal(fresh.childHref("child1"), "#/s/child1");
  assert.deepEqual(await fresh.start("C1"), { ok: true, child_id: "child1" });
  assert.deepEqual(h.posts, [["/api/sessions/s1aaaaaaaa/verdicts/C1/fresh", { method: "POST", body: "{}" }]]);
  const old = harness({ current: { workerFeatures: [] } });
  assert.equal(old.verify.freshState().canStart, false);
  assert.equal(old.verify.freshState().unavailableReason, VERIFY_UNAVAILABLE);
  h.done();
  old.done();
});

test("Verify's claim only in an ended turn's final answer", () => {
  const h = harness();
  const answer = h.find("The cache is keyed by path.");
  assert.deepEqual(h.verify.anchorFor({ source: { kind: "answer", root: answer }, range: h.select(answer, "keyed by path") }),
    { turn_id: "T1", quote: "keyed by path" });
  const step = h.find("Looking.");
  assert.equal(h.verify.anchorFor({ source: { kind: "answer", root: step }, range: h.select(step, "Looking") }), null);
  assert.equal(h.verify.anchorFor({ source: { kind: "step", root: answer }, range: h.select(answer, "keyed") }), null);
  assert.equal(h.verify.anchorFor({ source: { kind: "answer", root: answer }, range: null }), null);
  h.done();
  // The same answer while its turn still runs isn't final yet.
  const live = harness({ running: true, turnId: "T1" });
  const liveAnswer = live.find("The cache is keyed by path.");
  assert.equal(live.verify.anchorFor({ source: { kind: "answer", root: liveAnswer }, range: live.select(liveAnswer, "keyed") }), null);
  live.done();
});
