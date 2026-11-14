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
  assert.deepEqual(posts, [["s1", { turn_id: "T1", same: true, kinds: [], excused: [], explained: true, drawn: false, undrawn: 0 }]]);
});

test("a reload that differs posts the kinds that did; a drawing for the turn says drawn", async () => {
  const { check, posts } = setup({ reloaded: `${PROMPT}<div class="bubble output">other</div>`, data: { turn_drawings: { T1: {} } } });
  await check.handedOff({ pieces: pieces() });
  assert.deepEqual(posts, [["s1", { turn_id: "T1", same: false, kinds: ["answer", "timing"], excused: [], explained: false, drawn: true, undrawn: 0 }]]);
});

test("it is strict: a known divergence is a mismatch, posted with the ACCEPTED entry that would excuse it", async () => {
  const command = '<div class="bubble command"><div class="command-line">/help</div></div>';
  const { check, posts } = setup();
  await check.handedOff({ pieces: pieces(PROMPT + command + ANSWER) });
  assert.deepEqual(posts, [["s1", { turn_id: "T1", same: false, kinds: ["command"], excused: ["command-bubble"], explained: true, drawn: false, undrawn: 0 }]]);
});

test("a card is no finding (a reload places it after the render); the queued lines after the turn aren't the turn's", async () => {
  const live = `${PROMPT}<div class="bubble plugin-card" data-card-id="c1"><span class="card-title">x</span></div>${ANSWER}`
    + '<div class="bubble command queued"><div class="command-line">/model x</div></div>';
  const { check, posts } = setup();
  await check.handedOff({ pieces: pieces(live) });
  assert.equal(posts[0][1].same, true);
});

test("an answered question card is no finding either (a reload places it after the render, cards_place.js)", async () => {
  const card = '<details class="bubble question answered"><summary>Which file? → README.md</summary></details>';
  const { check, posts } = setup();
  await check.handedOff({ pieces: pieces(PROMPT + card + ANSWER) });
  assert.equal(posts[0][1].same, true);
  assert.deepEqual(posts[0][1].kinds, []);
});

test("a reload's rows that came without their turn's drawing (the plain fallback) are counted", async () => {
  const plain = PROMPT.replace('data-turn-id="T1"', 'data-turn-id="T1" data-undrawn="1"') + ANSWER.replace('class="bubble output"', 'class="bubble output" data-undrawn="1"');
  const { check, posts } = setup({ reloaded: plain });
  await check.handedOff({ pieces: pieces() });
  assert.equal(posts[0][1].undrawn, 2);
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

test("a shape that can't be read is dropped too, no rejection", async () => {
  const { check, posts } = setup();
  const broken = { matches: () => { throw new Error("detached"); } };
  await check.handedOff({ pieces: [...pieces(PROMPT), broken] });
  assert.deepEqual(posts, []);
});

test("the live pieces are read after the reload's read: a timing line that took its record's figure meanwhile counts as it is then", async () => {
  const live = pieces(PROMPT + '<div class="bubble output">hello</div><div class="turn-timing">turn 1 · 7ms</div>');
  const { check, posts } = setup();
  const done = check.handedOff({ pieces: live });
  live[2].textContent = "turn 1 · 5ms"; // the turn record's, landed before the read did
  await done;
  assert.equal(posts[0][1].same, true);
});

test("a read or a post that fails is dropped", async () => {
  const check = createReloadCheck({
    enabled: () => true, sessionId: () => "s1", running: () => false,
    read: async () => { throw new Error("gone"); }, render: () => document.createDocumentFragment(), post: async () => {},
  });
  await check.handedOff({ pieces: pieces() });
});

// A drawn turn already renders its own cards (turn_block.js drawnTurnNodes),
// so they compare; a card of another turn, or a between-turn one, does not.
const DRAWN = '<div class="bubble user" data-turn-id="T1" data-drawn="T1"><div class="user-message">hi</div></div>'
  + '<details class="turn-work" data-drawn="T1"><summary><span class="turn-steps">1 step</span></summary>'
  + '<div class="gen"><summary>ask</summary><div class="activity-body">'
  + '<div class="plugin-card" data-card-id="c1"><span class="card-title">Check-in</span></div>'
  + '</div></div></details>'
  + '<div class="bubble output">hello</div><div class="turn-timing">turn 1 · 5ms</div>';
const CARD = (id, title) => `<div class="plugin-card" data-card-id="${id}"><span class="card-title">${title}</span></div>`;
const IN_TURN = { id: "c1", type: "card", in_turn: true, of_turn: "T1", title: "Check-in" };

test("a drawn turn's own card is compared: the reload that loses it is a finding of kind card", async () => {
  const { check, posts } = setup({ reloaded: DRAWN.replace(CARD("c1", "Check-in"), ""), data: { turn_drawings: { T1: {} }, cards: [IN_TURN] } });
  await check.handedOff({ pieces: pieces(DRAWN) });
  assert.equal(posts[0][1].same, false);
  assert.deepEqual(posts[0][1].kinds, ["card"]);
  assert.equal(posts[0][1].drawn, true);
});

test("a drawn turn's own card, live and reloaded the same, is no finding", async () => {
  const { check, posts } = setup({ reloaded: DRAWN, data: { turn_drawings: { T1: {} }, cards: [IN_TURN] } });
  await check.handedOff({ pieces: pieces(DRAWN) });
  assert.equal(posts[0][1].same, true);
  assert.deepEqual(posts[0][1].kinds, []);
});

test("another turn's card, or a between-turn one, on one side only is no finding", async () => {
  const foreign = `<div class="bubble plugin-card" data-card-id="c9"><span class="card-title">Elsewhere</span></div>`;
  const { check, posts } = setup({
    reloaded: DRAWN,
    data: { turn_drawings: { T1: {} }, cards: [IN_TURN, { id: "c9", opening_id: "T2", title: "Elsewhere" }] },
  });
  await check.handedOff({ pieces: pieces(DRAWN + foreign) });
  assert.equal(posts[0][1].same, true);
  assert.deepEqual(posts[0][1].kinds, []);
});

test("a live card the snapshot doesn't know at all is a finding: the reload lost it", async () => {
  const { check, posts } = setup({ reloaded: DRAWN, data: { turn_drawings: { T1: {} }, cards: [IN_TURN] } });
  await check.handedOff({ pieces: pieces(DRAWN.replace(CARD("c1", "Check-in"), CARD("c1", "Check-in") + CARD("c7", "Late"))) });
  assert.equal(posts[0][1].same, false);
  assert.deepEqual(posts[0][1].kinds, ["card"]);
});

test("a card's title updated after the turn reads the same on both sides (CardStore's latest)", async () => {
  const both = DRAWN.replace("Check-in", "Check-in, again");
  const { check, posts } = setup({ reloaded: both, data: { turn_drawings: { T1: {} }, cards: [{ ...IN_TURN, title: "Check-in, again" }] } });
  await check.handedOff({ pieces: pieces(both) });
  assert.equal(posts[0][1].same, true);
});

test("an undrawn turn's cards are still left out (the placer comes in the next step)", async () => {
  const live = DRAWN.replace(' data-drawn="T1"', "");
  const { check, posts } = setup({ reloaded: live, data: { cards: [{ id: "c1", type: "card", in_turn: true, title: "Check-in" }] } });
  await check.handedOff({ pieces: pieces(live) });
  assert.equal(posts[0][1].same, true);
});
