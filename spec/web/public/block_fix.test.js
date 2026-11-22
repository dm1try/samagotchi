import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { failBlock } from "../../../lib/samagotchi/web/public/block_watch.js";
import { createBlockFix, GIVE_UP_MS, postFix, wireBlockFix } from "../../../lib/samagotchi/web/public/block_fix.js";
import { DRAWN } from "../../../lib/samagotchi/web/public/block_source.js";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const pre = (src, lang = "mermaid", attrs = "") => `<pre data-lang="${lang}"${attrs}><code>${src}\n</code></pre>`;
const bubble = (turn, body) => `<div class="bubble output markdown" data-answer-turn="${turn}" data-copy-source="src ${turn}">${body}</div>`;

function fakeTimers() {
  let next = 1;
  const live = new Map();
  return {
    live,
    setTimeout: (fn, ms) => { const id = next++; live.set(id, { fn, ms }); return id; },
    clearTimeout: (id) => { live.delete(id); },
    fire() { for (const [id, { fn }] of [...live]) { live.delete(id); fn(); } },
  };
}

function setup(html, { answers = [], features = ["block_fix"], reads = [], bridgeUp = true, post = null } = {}) {
  const root = document.createElement("div");
  root.id = "history";
  root.innerHTML = html;
  document.body.append(root);
  const posts = [];
  const filled = [];
  let session = "s1";
  const timers = fakeTimers();
  const fix = createBlockFix({
    roots: [root],
    sessionId: () => session,
    features: () => features,
    bridgeUp: () => bridgeUp,
    post: async (id, body) => { posts.push({ id, ...body }); return post ? post() : answers.shift() || { status: 202, body: { state: "running" } }; },
    getSession: async (id, opts) => { reads.push({ id, ...opts }); return reads.answer || { messages: [] }; },
    composerText: () => "draft",
    fillComposer: (text) => filled.push(text),
    timers,
    win: window,
  });
  return { root, fix, posts, filled, timers, reads, setSession: (id) => { session = id; } };
}

const fail = (el, { fixable = true, reason = "Parse error on line 2\nmore" } = {}) => failBlock(el, el.getAttribute("data-lang"), reason, { fixable });
const noteText = (el) => el.nextElementSibling?.dataset.text;

test.afterEach(() => { document.body.innerHTML = ""; });

test("asks for a fixable block in the newest answer: the line says so and the POST names the turn, block and reason", async () => {
  const { root, posts } = setup(bubble("t1", pre("old")) + bubble("t2", pre("graph X")));
  const [older, newest] = root.querySelectorAll("pre");
  fail(newest);
  await settle();
  assert.deepEqual(posts, [{ id: "s1", turn_id: "t2", lang: "mermaid", source: "graph X", reason: "Parse error on line 2\nmore" }]);
  assert.equal(newest.nextElementSibling.dataset.fix, "asking");
  assert.equal(newest.dataset.blockFixAsked, "1");
  fail(older);
  await settle();
  assert.equal(posts.length, 1, "an older answer is never asked for");
  assert.equal(older.nextElementSibling.dataset.fix, "older");
  assert.ok(older.nextElementSibling.querySelector(".block-fix-ask"));
});

test("at most 2 blocks per answer; a failure that isn't the model's, or over 16 KB, keeps today's line", async () => {
  const { root, posts } = setup(bubble("t1", pre("a") + pre("b") + pre("c") + pre("d") + pre("x".repeat(17 * 1024))));
  const [a, b, c, d, big] = root.querySelectorAll("pre");
  for (const el of [a, b, c]) fail(el);
  fail(d, { fixable: false });
  fail(big);
  await settle();
  assert.deepEqual(posts.map((p) => p.source), ["a", "b"]);
  assert.equal(c.nextElementSibling.dataset.fix, "older");
  for (const el of [d, big]) {
    assert.ok(el.nextElementSibling.dataset.fix === undefined);
    assert.ok(el.nextElementSibling.querySelector("button") === null);
  }
});

test("a block that is a fix failing again, or one whose fix failed, isn't asked for again", async () => {
  const { root, posts } = setup(bubble("t1", pre("a", "mermaid", " data-block-fixed") + pre("b", "mermaid", " data-block-fix-failed")));
  const [fixed, failedFix] = root.querySelectorAll("pre");
  fail(fixed);
  fail(failedFix);
  await settle();
  assert.equal(posts.length, 0);
  assert.equal(fixed.nextElementSibling.dataset.fix, "again");
  assert.equal(failedFix.nextElementSibling.dataset.fix, "nohelp");
});

test("a worker without the feature: restart this session to fix, nothing asked", async () => {
  const { root, posts } = setup(bubble("t1", pre("a")), { features: [] });
  const el = root.querySelector("pre");
  fail(el);
  await settle();
  assert.equal(posts.length, 0);
  assert.equal(el.nextElementSibling.dataset.fix, "restart");
});

test("a worker not up, or not reported yet, isn't old: the block is asked for (chi web says whether it is live)", async () => {
  for (const [features, bridgeUp] of [[[], false], [[], null], [null, true]]) {
    const { root, posts } = setup(bubble("t1", pre("a")), { features, bridgeUp, answers: [{ status: 503, body: {} }] });
    const el = root.querySelector("pre");
    fail(el);
    await settle();
    assert.equal(posts.length, 1, JSON.stringify([features, bridgeUp]));
    assert.equal(el.nextElementSibling.dataset.fix, "older");
    document.body.innerHTML = "";
  }
});

test("each answer of the route: 200 failed, 501, any other; 200 fixed reads the answer again", async () => {
  for (const [answer, state] of [[{ status: 200, body: { state: "failed" } }, "nohelp"], [{ status: 501, body: {} }, "restart"],
    [{ status: 409, body: {} }, "older"], [{ status: 0, body: {} }, "older"]]) {
    const { root } = setup(bubble("t1", pre("a")), { answers: [answer] });
    const el = root.querySelector("pre");
    fail(el);
    await settle();
    assert.equal(el.nextElementSibling.dataset.fix, state, JSON.stringify(answer));
    document.body.innerHTML = "";
  }
  const reads = [];
  reads.answer = { messages: [{ role: "assistant", content: "src t1", html: pre("fixed", "mermaid", " data-block-fixed") }] };
  const { root } = setup(bubble("t1", pre("a")), { answers: [{ status: 200, body: { state: "fixed" } }], reads });
  fail(root.querySelector("pre"));
  await settle();
  await settle();
  assert.deepEqual(reads.map((r) => [r.id, r.tail, r.turnId]), [["s1", true, "t1"]]);
  assert.ok(root.querySelector("pre[data-block-fixed]"));
});

test("the worker's event: fixed redraws the answer from a tail read; failed and dropped say a fix didn't help", async () => {
  const reads = [];
  reads.answer = { messages: [{ role: "assistant", content: "src t2", display: null, html: `<p>now</p>${pre("graph LR", "mermaid", " data-block-fixed")}`, display_refs: [] }] };
  const { root, fix, timers } = setup(bubble("t1", pre("a")) + bubble("t2", pre("b")), { reads });
  const [a, b] = root.querySelectorAll("pre");
  fail(b);
  await settle();
  assert.equal(timers.live.size, 1);
  fix.onEvent({ turn_id: "t2", state: "fixed" });
  await settle();
  assert.equal(timers.live.size, 0, "its give-up is dropped");
  const answer = root.querySelector('[data-answer-turn="t2"]');
  assert.equal(answer.querySelector("p").textContent, "now");
  assert.equal(answer.getAttribute("data-copy-source"), "src t2");
  assert.ok(!answer.hasAttribute("data-answer-display"));
  assert.ok(answer.querySelector("pre[data-block-fixed]"));
  assert.ok(a.isConnected);

  document.body.innerHTML = "";
  for (const state of ["failed", "dropped"]) {
    const s = setup(bubble("t1", pre("a")));
    const el = s.root.querySelector("pre");
    fail(el);
    await settle();
    s.fix.onEvent({ turn_id: "t1", state, reason: "the answer changed" });
    assert.equal(el.nextElementSibling.dataset.fix, "nohelp");
    document.body.innerHTML = "";
  }
});

test("a keyed event settles only its block and leaves another asking block's give-up timer running", async () => {
  const { root, fix, timers } = setup(bubble("t1", pre("a") + pre("b")), {
    answers: [
      { status: 202, body: { state: "running", key: "key-a" } },
      { status: 202, body: { state: "running", key: "key-b" } },
    ],
  });
  const [a, b] = root.querySelectorAll("pre");
  fail(a);
  fail(b);
  await settle();
  assert.equal(a.dataset.blockFixKey, "key-a");
  assert.equal(b.dataset.blockFixKey, "key-b");
  assert.equal(timers.live.size, 1);

  fix.onEvent({ turn_id: "t1", key: "key-a", state: "failed" });
  assert.equal(a.nextElementSibling.dataset.fix, "nohelp");
  assert.equal(b.nextElementSibling.dataset.fix, "asking");
  assert.equal(timers.live.size, 1);
  timers.fire();
  assert.equal(b.nextElementSibling.dataset.fix, "older");
});

test("an event without a key keeps settling every asked block", async () => {
  const { root, fix } = setup(bubble("t1", pre("a") + pre("b")));
  const [a, b] = root.querySelectorAll("pre");
  fail(a);
  fail(b);
  await settle();
  fix.onEvent({ turn_id: "t1", state: "failed" });
  assert.equal(a.nextElementSibling.dataset.fix, "nohelp");
  assert.equal(b.nextElementSibling.dataset.fix, "nohelp");
});

test("an answer is read again at most once per block: a copy still failing after the redraw says a fix didn't help, no loop", async () => {
  const fixed = { status: 200, body: { state: "fixed" } };
  const reads = [];
  // The read still holds both copies, failing (a worker that patched only one).
  reads.answer = { messages: [{ role: "assistant", content: "src t1", html: pre("a") + pre("a") }] };
  const { root, posts } = setup(bubble("t1", pre("a") + pre("a")), { answers: [fixed, fixed, fixed, fixed], reads });
  fail(root.querySelector("pre"));
  await settle();
  await settle();
  assert.equal(reads.length, 1);
  for (const el of root.querySelectorAll("pre")) fail(el);
  await settle();
  await settle();
  assert.equal(reads.length, 1, "no second read");
  assert.equal(posts.length, 3);
  for (const el of root.querySelectorAll("pre")) assert.equal(el.nextElementSibling.dataset.fix, "nohelp");

  document.body.innerHTML = "";
  const again = [];
  again.answer = reads.answer;
  const s = setup(bubble("t2", pre("b")), { answers: [{ status: 202, body: { state: "running" } }, { status: 200, body: { state: "fixed" } }], reads: again });
  again.answer = { messages: [{ role: "assistant", content: "src t2", html: pre("b") }] };
  fail(s.root.querySelector("pre"));
  await settle();
  s.fix.onEvent({ turn_id: "t2", state: "fixed" });
  await settle();
  await settle();
  assert.equal(again.length, 1);
  fail(s.root.querySelector("pre"));
  await settle();
  await settle();
  assert.equal(again.length, 1, "the event's redraw counts too");
  assert.equal(s.root.querySelector("pre").nextElementSibling.dataset.fix, "nohelp");
});

test("the worker's word arriving before the POST's 202 (a quick side answer) still settles the line, and no give-up follows", async () => {
  for (const state of ["failed", "fixed"]) {
    const reads = [];
    reads.answer = { messages: [{ role: "assistant", content: "src t1", html: pre("graph LR", "mermaid", " data-block-fixed") }] };
    let reply;
    const held = new Promise((resolve) => { reply = resolve; });
    const { root, fix, timers, posts } = setup(bubble("t1", pre("a")), { reads, post: () => held });
    const el = root.querySelector("pre");
    fail(el);
    await settle();
    assert.equal(posts.length, 1);
    fix.onEvent({ turn_id: "t1", state });
    await settle();
    await settle();
    reply({ status: 202, body: { state: "running" } });
    await settle();
    if (state === "failed") assert.equal(el.nextElementSibling.dataset.fix, "nohelp", state);
    else assert.ok(root.querySelector("pre[data-block-fixed]"), "the fixed answer was drawn");
    assert.equal(timers.live.size, 0, `no give-up after the word came (${state})`);
    document.body.innerHTML = "";
  }
});

test("a fixed event for an answer the read doesn't hold (a reminder turn's, read as the newest) leaves it for the next full read", async () => {
  const reads = [];
  reads.answer = { messages: [{ role: "assistant", content: "src t2", html: "<p>the newest</p>" }] };
  const { root, fix } = setup(bubble("t1", pre("a")) + bubble("t2", "<p>newest</p>"), { reads });
  fix.onEvent({ turn_id: "t1", state: "fixed" });
  await settle();
  await settle();
  assert.ok(root.querySelector('[data-answer-turn="t1"] pre'));
});

test("no word within 60 s of a 202: today's line and Ask in chat; a session switch drops the timers", async () => {
  const s = setup(bubble("t1", pre("a")));
  const el = s.root.querySelector("pre");
  fail(el);
  await settle();
  assert.equal([...s.timers.live.values()][0].ms, GIVE_UP_MS);
  s.timers.fire();
  assert.equal(el.nextElementSibling.dataset.fix, "older");
  document.body.innerHTML = "";

  const t = setup(bubble("t1", pre("a")));
  fail(t.root.querySelector("pre"));
  await settle();
  assert.equal(t.timers.live.size, 1);
  t.setSession("s2");
  t.fix.onEvent({ turn_id: "other", state: "failed" });
  assert.equal(t.timers.live.size, 0);
});

test("a Revise clone (no answer turn) never asks; a re-rendered bubble posts again; a clone arriving failed is seen", async () => {
  const { root, posts } = setup(bubble("t1", pre("a")));
  const el = root.querySelector("pre");
  fail(el);
  await settle();
  assert.equal(posts.length, 1);
  const answer = root.querySelector(".bubble");
  answer.innerHTML = pre("a");
  fail(answer.querySelector("pre"));
  await settle();
  assert.equal(posts.length, 2, "the worker answers it is running");

  const clone = document.createElement("div");
  clone.className = "bubble output markdown";
  clone.innerHTML = pre("a", "mermaid", ' data-block-failed="1" data-block-fixable="1"') + '<div class="block-note" data-text="x"></div>';
  root.append(clone);
  await settle();
  assert.equal(posts.length, 2);
  assert.equal(clone.querySelector(".block-note").dataset.fix, "older");
});

test("Ask in chat fills the composer after the draft, never sends; a click on the words doesn't", async () => {
  const { root, filled } = setup(bubble("t1", pre("a")) + bubble("t2", pre("b")));
  const older = root.querySelector("pre");
  fail(older);
  await settle();
  older.nextElementSibling.click();
  assert.deepEqual(filled, []);
  older.nextElementSibling.querySelector(".block-fix-ask").click();
  assert.deepEqual(filled, ["draft\nThe mermaid block in your answer didn't draw: Parse error on line 2. Please send it again, corrected."]);
});

test("Drawn after a fix shows once the fixed block drew", async () => {
  const { root } = setup(bubble("t1", pre("graph LR", "mermaid", " data-block-fixed")));
  const el = root.querySelector("pre");
  const figure = document.createElement("figure");
  figure.className = DRAWN;
  el.before(figure);
  el.hidden = true;
  await settle();
  assert.equal(noteText(el), "Drawn after a fix");
});

test("postFix: 202 is running, a refusal its status; wireBlockFix only on the owner's page with data-block-fix auto", async () => {
  const fetchImpl = async (_url, opts) => {
    const body = JSON.parse(opts.body);
    if (body.source === "bad") return new Response(JSON.stringify({ error: "fix_busy", detail: "busy" }), { status: 429 });
    return new Response(JSON.stringify({ state: body.source === "known" ? "failed" : "running" }), { status: body.source === "known" ? 200 : 202 });
  };
  assert.deepEqual(await postFix("s1", { source: "x" }, { fetchImpl }), { status: 202, body: { state: "running" } });
  assert.deepEqual(await postFix("s1", { source: "known" }, { fetchImpl }), { status: 200, body: { state: "failed" } });
  assert.equal((await postFix("s1", { source: "bad" }, { fetchImpl })).status, 429);
  const viewer = (yes) => ({ can: (what) => what === "block_renderers" && yes });
  const args = { roots: [], store: { selected: "s1", current: { workerFeatures: [], bridgeUp: true } }, getSession: async () => ({}), composerText: () => "", fillComposer() {} };
  document.body.dataset.blockFix = "auto";
  assert.ok(wireBlockFix({ viewer: viewer(true), ...args }));
  assert.equal(wireBlockFix({ viewer: viewer(false), ...args }), null);
  document.body.dataset.blockFix = "off";
  assert.equal(wireBlockFix({ viewer: viewer(true), ...args }), null);
  delete document.body.dataset.blockFix;
  assert.equal(wireBlockFix({ viewer: viewer(true), ...args }), null);
});
