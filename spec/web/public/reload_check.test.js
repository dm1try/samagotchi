// The opt-in reload check (reload_check.js): a handed-off turn's pieces
// against the same turn drawn as a reload draws it, and the turn's cards as
// data (card_registry.js) against a registry seeded from the read, the
// counts posted.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createReloadCheck } from "../../../lib/samagotchi/web/public/reload_check.js";
import { readdirSync, readFileSync } from "node:fs";
import { createCardRegistry } from "../../../lib/samagotchi/web/public/card_registry.js";
import { turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_block.js";
import { livePage } from "./live_page.js";

function nodes(markup) {
  const holder = document.createElement("div");
  holder.innerHTML = markup;
  return holder;
}

const PROMPT = '<div class="bubble user" data-turn-id="T1"><div class="user-message">hi</div></div>';
const ANSWER = '<div class="bubble output">hello</div><div class="turn-timing">turn 1 · 5ms</div>';

// +cards+: the page's registry (a getter's value; an empty one by default),
// null: none (an older app.js); +place+: what an older app.js passes
// (cards_offscreen.js), unused.
function setup({ enabled = true, reloaded = PROMPT + ANSWER, data = {}, cards = createCardRegistry(), place = undefined } = {}) {
  const posts = [];
  const reads = [];
  let session = "s1";
  let running = false;
  const check = createReloadCheck({
    enabled: () => enabled,
    sessionId: () => session,
    running: () => running,
    read: async (id) => { reads.push(id); return { ...data, html: reloaded }; },
    ...(cards ? { cards: () => cards } : {}),
    ...(place !== undefined ? { place, capabilities: () => null } : {}),
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

test("the lines queued after the turn are not the turn's", async () => {
  const queued = '<div class="bubble command queued"><div class="command-line">/model x</div></div>';
  const { check, posts } = setup();
  await check.handedOff({ pieces: pieces(PROMPT + queued + ANSWER) });
  assert.equal(posts[0][1].same, true);
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

// The turn's cards and questions compare as data: the page's registry (what
// the stream said) against one seeded from the read (what CardStore lists).
const CHECK_IN = { type: "card", id: "c1", title: "Check-in", level: "info", in_turn: true, of_turn: "T1", actions: [{ label: "Nudge", command: "/check-in nudge" }] };
const ASKED = { type: "question", in_turn: true, of_turn: "T1", iteration: 1, calls: 1, current: false,
  pending_question: { id: "q1", kind: "question", question: "Which one?", options: [{ label: "A" }, { label: "B" }] }, answer: { selected: ["A"] } };
// The page's registry after a turn T1 that showed +card+ and asked and
// answered +question+ (each optional).
function livedTurn({ card = null, question = null, answered = true, extra = [] } = {}) {
  const r = createCardRegistry();
  r.apply("turn_started", { turn_id: "T1" });
  r.apply("generation_started", { iteration: 1 });
  r.apply("tool_call_started", { iteration: 1, call_index: 1 });
  if (card) r.apply("card", card);
  if (question) {
    r.apply("question_requested", { pending_question: question });
    if (answered) r.apply("question_answered", { id: question.id, answer: { selected: ["A"] } });
  }
  for (const [type, data] of extra) r.apply(type, data);
  r.apply("turn_completed", { turn_id: "T1" });
  return r;
}
const QCARD = '<details class="bubble question answered" data-qid="q1"><summary>Which one? → A</summary></details>';
const CARD_EL = '<div class="plugin-card" data-card-id="c1"><span class="card-title">Check-in</span></div>';

test("the turn's card and question, live and in the read the same, are no finding", async () => {
  const cards = livedTurn({ card: CHECK_IN, question: ASKED.pending_question });
  const { check, posts } = setup({ cards, data: { cards: [CHECK_IN, ASKED] } });
  await check.handedOff({ pieces: pieces() });
  assert.deepEqual(posts[0][1], { turn_id: "T1", same: true, kinds: [], excused: [], explained: true, drawn: false, undrawn: 0 });
});

test("a card the read has and live never heard of is a finding of kind card; a question of kind question", async () => {
  const card = setup({ cards: livedTurn({ question: ASKED.pending_question }), data: { cards: [CHECK_IN, ASKED] } });
  await card.check.handedOff({ pieces: pieces() });
  assert.deepEqual([card.posts[0][1].same, card.posts[0][1].kinds, card.posts[0][1].explained], [false, ["card"], false]);
  const question = setup({ cards: livedTurn({ card: CHECK_IN }), data: { cards: [CHECK_IN, ASKED] } });
  await question.check.handedOff({ pieces: pieces() });
  assert.deepEqual(question.posts[0][1].kinds, ["question"]);
});

test("a card live had that the read lost is a finding, unless the read is at CardStore's cap", async () => {
  const lost = setup({ cards: livedTurn({ card: CHECK_IN, question: ASKED.pending_question }), data: { cards: [ASKED] } });
  await lost.check.handedOff({ pieces: pieces() });
  assert.deepEqual(lost.posts[0][1].kinds, ["card"]);
  // 20 cards and questions listed: the oldest may have gone; a key live has
  // and the read hasn't is skipped, the rest still compare.
  const others = Array.from({ length: 19 }, (_, i) => ({ type: "card", id: `o${i}`, title: `old ${i}`, of_turn: "T0", in_turn: true }));
  const full = setup({ cards: livedTurn({ card: CHECK_IN, question: ASKED.pending_question }), data: { cards: [...others, ASKED] } });
  await full.check.handedOff({ pieces: pieces() });
  assert.deepEqual([full.posts[0][1].same, full.posts[0][1].kinds], [true, []]);
  const differs = setup({ cards: livedTurn({ card: CHECK_IN, question: ASKED.pending_question }), data: { cards: [...others, { ...ASKED, answer: undefined, cancelled: true }] } });
  await differs.check.handedOff({ pieces: pieces() });
  assert.deepEqual(differs.posts[0][1].kinds, ["question"], "a capped read still compares what it lists");
});

test("a status that differs is a finding: answered live, cancelled in the read", async () => {
  const { check, posts } = setup({ cards: livedTurn({ question: ASKED.pending_question }), data: { cards: [{ ...ASKED, answer: undefined, cancelled: true, reason: "x" }] } });
  await check.handedOff({ pieces: pieces() });
  assert.deepEqual(posts[0][1].kinds, ["question"]);
});

test("a question pending at the turn's end reads cancelled on both sides (the page cancels it, CardStore lists it open)", async () => {
  const { check, posts } = setup({ cards: livedTurn({ question: ASKED.pending_question, answered: false }), data: { cards: [{ ...ASKED, answer: undefined }] } });
  await check.handedOff({ pieces: pieces() });
  assert.equal(posts[0][1].same, true, JSON.stringify(posts[0][1]));
});

test("a summary that differs is a finding (a card's title); its body, buttons and tag are not compared", async () => {
  const retitled = setup({ cards: livedTurn({ card: CHECK_IN }), data: { cards: [{ ...CHECK_IN, title: "Check-in, again" }] } });
  await retitled.check.handedOff({ pieces: pieces() });
  assert.deepEqual(retitled.posts[0][1].kinds, ["card"]);
  const body = setup({ cards: livedTurn({ card: CHECK_IN }), data: { cards: [{ ...CHECK_IN, body: "other", body_html: "<p>other</p>" }] } });
  await body.check.handedOff({ pieces: pieces() });
  assert.equal(body.posts[0][1].same, true);
});

test("another turn's card or question, and a between-turn card, are not this turn's: no finding on one side only", async () => {
  const cards = livedTurn({ extra: [["card", { id: "btw", title: "btw", in_turn: false }]] });
  const { check, posts } = setup({
    cards,
    data: { cards: [{ ...CHECK_IN, of_turn: "T2" }, { ...ASKED, of_turn: "T0" }, { type: "card", id: "late", title: "late", in_turn: false }] },
  });
  await check.handedOff({ pieces: pieces() });
  assert.deepEqual([posts[0][1].same, posts[0][1].kinds], [true, []]);
});

test("an older worker's question (no of_turn, no opening or this turn's) leaves the questions out; one stamped elsewhere doesn't", async () => {
  const loose = { ...ASKED, of_turn: undefined };
  const older = setup({ cards: livedTurn({ question: ASKED.pending_question }), data: { cards: [loose] } });
  await older.check.handedOff({ pieces: pieces() });
  assert.equal(older.posts[0][1].same, true, JSON.stringify(older.posts[0][1]));
  const stamped = setup({ cards: livedTurn({ question: ASKED.pending_question }), data: { cards: [{ ...loose, opening_id: "T1" }] } });
  await stamped.check.handedOff({ pieces: pieces() });
  assert.equal(stamped.posts[0][1].same, true);
  const elsewhere = { type: "question", opening_id: "T2", pending_question: { id: "q9", question: "Elsewhere?" }, answer: { selected: ["yes"] } };
  const counted = setup({ cards: livedTurn({ question: ASKED.pending_question }), data: { cards: [elsewhere] } });
  await counted.check.handedOff({ pieces: pieces() });
  assert.deepEqual(counted.posts[0][1].kinds, ["question"], "q1 is still compared: the read lost it");
});

test("the history's compare drops cards and questions on both sides, and keeps a notice", async () => {
  const cards = livedTurn({ card: CHECK_IN, question: ASKED.pending_question });
  const data = { cards: [CHECK_IN, ASKED] };
  // Placed differently, or missing on one side: the history doesn't say (the
  // data does, and the stage cuts' turn-end cut checks the place).
  const moved = setup({ cards, data, reloaded: PROMPT + ANSWER });
  await moved.check.handedOff({ pieces: pieces(PROMPT + CARD_EL + ANSWER.replace("<div class=\"turn-timing\">", `${QCARD}<div class="turn-timing">`)) });
  assert.equal(moved.posts[0][1].same, true, JSON.stringify(moved.posts[0][1]));
  const notice = '<div class="bubble hook-notice">a hook said so</div>';
  const lostNotice = setup({ cards, data, reloaded: PROMPT + ANSWER });
  await lostNotice.check.handedOff({ pieces: pieces(PROMPT + notice + ANSWER) });
  assert.equal(lostNotice.posts[0][1].same, false);
  assert.deepEqual(lostNotice.posts[0][1].kinds, ["notice"]);
});

test("without the page's registry (an older app.js passes cards_offscreen.js's placer), cards and questions are left out", async () => {
  let placed = 0;
  const { check, posts } = setup({ cards: null, place: () => { placed += 1; }, data: { cards: [CHECK_IN, ASKED] }, reloaded: PROMPT + ANSWER });
  await check.handedOff({ pieces: pieces(PROMPT + CARD_EL + QCARD + ANSWER) });
  assert.equal(placed, 0, "the placer is not called");
  assert.deepEqual([posts[0][1].same, posts[0][1].kinds], [true, []]);
  assert.equal(posts[0][1].cards_compared, false, "a same that checked no cards says so");
  const full = setup({ cards: livedTurn({ card: CHECK_IN, question: ASKED.pending_question }), data: { cards: [CHECK_IN, ASKED] } });
  await full.check.handedOff({ pieces: pieces() });
  assert.equal("cards_compared" in full.posts[0][1], false, "with the registry: no flag");
});

test("a registry that throws drops the check: no post, no error out", async () => {
  const { check, posts } = setup({ cards: { forTurn: () => { throw new Error("gone"); } } });
  await check.handedOff({ pieces: pieces() });
  assert.deepEqual(posts, []);
});

// The stage cuts' turn ends (spec/shared/stage_cuts/*.json): the page that
// lived through the turn (live_page.js: the real handlers, the registry
// around them) handed off and checked against the cut's show, as app.js
// wires it. Every scenario: the same.
const CUTS = new URL("../../shared/stage_cuts/", import.meta.url);
for (const f of readdirSync(CUTS).filter((name) => name.endsWith(".json")).sort()) {
  const scenario = JSON.parse(readFileSync(new URL(f, CUTS), "utf8"));
  const end = scenario.cuts.find((c) => c.label === "turn end");
  if (!end) continue;
  test(`${f.replace(/\.json$/, "")}: the turn's end, live against its read, posts same`, async () => {
    const page = livePage({ questions: true });
    for (const event of scenario.events.slice(0, end.at)) {
      await page.handlers[event.type]?.({ ...event });
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    page.turnDom.flush();
    const posts = [];
    const check = createReloadCheck({
      enabled: () => true, sessionId: () => "s1", running: () => false, read: async () => end.show, cards: () => page.cardRegistry,
      render: (data) => turnHistoryNodes(data.messages || [], {}, { thumbs: () => null, drawings: data.turn_drawings || null, cards: data.cards || null }),
      post: async (_id, body) => { posts.push(body); },
    });
    page.turnDom.handOff({ immediate: true });
    page.turnDom.settleFold();
    // The pieces as the stage hands them off: the turn's opening and what follows it.
    const opening = page.historyEl.querySelector('.bubble.user[data-turn-id]');
    const handed = [...page.historyEl.children].slice([...page.historyEl.children].indexOf(opening));
    await check.handedOff({ pieces: handed });
    assert.equal(posts.length, 1);
    assert.equal(posts[0].same, true, JSON.stringify(posts[0]));
    page.turnDom.reset();
  });
}
