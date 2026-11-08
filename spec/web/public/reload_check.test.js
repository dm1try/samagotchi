// The opt-in reload check (reload_check.js): a handed-off turn's pieces
// against the same turn drawn as a reload draws it, the counts posted.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createReloadCheck } from "../../../lib/samagotchi/web/public/reload_check.js";

function nodes(markup) {
  const holder = document.createElement("div");
  holder.innerHTML = markup;
  return holder;
}

const PROMPT = '<div class="bubble user" data-turn-id="T1"><div class="user-message">hi</div></div>';
const ANSWER = '<div class="bubble output">hello</div><div class="turn-timing">turn 1 · 5ms</div>';

function setup({ enabled = true, reloaded = PROMPT + ANSWER, data = {} } = {}) {
  const posts = [];
  const reads = [];
  let session = "s1";
  let running = false;
  const check = createReloadCheck({
    enabled: () => enabled,
    sessionId: () => session,
    running: () => running,
    read: async (id) => { reads.push(id); return { ...data, html: reloaded }; },
    render: (d) => {
      const frag = document.createDocumentFragment();
      frag.append(...nodes(d.html).childNodes);
      return frag;
    },
    post: async (id, body) => { posts.push([id, body]); },
  });
  return {
    check, posts, reads,
    switchTo: (id) => { session = id; },
    startTurn: () => { running = true; },
  };
}

const pieces = (markup = PROMPT + ANSWER) => [...nodes(markup).children];

test("a handed-off turn the reload draws the same posts same, no kinds, not drawn", async () => {
  const { check, posts, reads } = setup();
  await check.handedOff({ pieces: pieces() });
  assert.deepEqual(reads, ["s1"]);
  assert.deepEqual(posts, [["s1", { turn_id: "T1", same: true, kinds: [], excused: [], explained: true, drawn: false }]]);
});

test("a reload that differs posts the kinds that did; a drawing for the turn says drawn", async () => {
  const { check, posts } = setup({ reloaded: `${PROMPT}<div class="bubble output">other</div>`, data: { turn_drawings: { T1: {} } } });
  await check.handedOff({ pieces: pieces() });
  assert.deepEqual(posts, [["s1", { turn_id: "T1", same: false, kinds: ["answer", "timing"], excused: [], explained: false, drawn: true }]]);
});

test("it is strict: a known divergence is a mismatch, posted with the ACCEPTED entry that would excuse it", async () => {
  const command = '<div class="bubble command"><div class="command-line">/help</div></div>';
  const { check, posts } = setup();
  await check.handedOff({ pieces: pieces(PROMPT + command + ANSWER) });
  assert.deepEqual(posts, [["s1", { turn_id: "T1", same: false, kinds: ["command"], excused: ["command-bubble"], explained: true, drawn: false }]]);
});

test("a card is no finding (a reload places it after the render); the queued lines after the turn aren't the turn's", async () => {
  const live = `${PROMPT}<div class="bubble plugin-card" data-card-id="c1"><span class="card-title">x</span></div>${ANSWER}`
    + '<div class="bubble command queued"><div class="command-line">/model x</div></div>';
  const { check, posts } = setup();
  await check.handedOff({ pieces: pieces(live) });
  assert.equal(posts[0][1].same, true);
});

test("off, the check reads nothing", async () => {
  const { check, posts, reads } = setup({ enabled: false });
  await check.handedOff({ pieces: pieces() });
  assert.deepEqual([reads, posts], [[], []]);
});

test("it skips a hand-off another turn forced, a running turn, a turn with no id and a session switch mid-read", async () => {
  const forced = setup();
  await forced.check.handedOff({ pieces: pieces(), immediate: true });
  const busy = setup();
  busy.startTurn();
  await busy.check.handedOff({ pieces: pieces() });
  const anonymous = setup();
  await anonymous.check.handedOff({ pieces: pieces(ANSWER) });
  assert.deepEqual([...forced.reads, ...busy.reads, ...anonymous.reads], []);

  const moved = setup();
  const done = moved.check.handedOff({ pieces: pieces() });
  moved.switchTo("s2");
  await done;
  assert.deepEqual(moved.reads, ["s1"]);
  assert.deepEqual(moved.posts, []);
});

test("a read or a post that fails is dropped", async () => {
  const check = createReloadCheck({
    enabled: () => true, sessionId: () => "s1", running: () => false,
    read: async () => { throw new Error("gone"); }, render: () => document.createDocumentFragment(), post: async () => {},
  });
  await check.handedOff({ pieces: pieces() });
});
