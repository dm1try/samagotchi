// The offscreen placer (cards_offscreen.js): the same snapshot entries placed
// into a detached holder as the live page places them into its history, read
// the same (history_shape.js); nothing of the page is touched.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { placeCardsOffscreen } from "../../../lib/samagotchi/web/public/cards_offscreen.js";
import { splitSnapshotCards } from "../../../lib/samagotchi/web/public/card.js";
import { compareShapes, historyShape } from "../../../lib/samagotchi/web/public/history_shape.js";
import { livePage } from "./live_page.js";

// A drawn turn, its prompt, its step and its answer: what a reload renders
// before the snapshot's cards are placed.
const TURN = '<div class="bubble user" data-turn-id="T1" data-drawn="T1"><div class="user-message">pick one</div></div>'
  + '<details class="turn-work" data-drawn="T1"><summary><span class="turn-steps">2 steps</span></summary>'
  + '<div class="gen"><summary>ask</summary><div class="activity-body">'
  + '<div class="activity-row"><span class="activity-tool">ask_user_question</span><span class="activity-params">question="Which one?"</span></div>'
  + '</div></div></details>'
  + '<div class="bubble output">A it is.</div><div class="turn-timing">turn 1 · 2.4s</div>';

const QUESTION = {
  type: "question", in_turn: true, of_turn: "T1", iteration: 1,
  pending_question: { id: "q1", question: "Which one?", options: [{ label: "A" }, { label: "B" }] },
  answer: { selected: ["A"] },
};
const APPROVAL = {
  type: "question", in_turn: true, of_turn: "T1", iteration: 1,
  pending_question: {
    id: "q2", kind: "approval", approval: { tool: "execute", label: "rm tmp", acts_as: "shell" },
    options: [{ label: "Allow" }, { label: "Deny" }],
  },
  answer: { selected: ["Deny"] },
};
const CANCELLED = {
  type: "question", in_turn: true, of_turn: "T1", iteration: 1,
  pending_question: { id: "q3", question: "Keep going?", options: [{ label: "Yes" }] },
  cancelled: true, reason: "turn ended",
};
const STEP_LIMIT = {
  type: "question", in_turn: true, of_turn: "T1", iteration: 2,
  pending_question: { id: "q4", kind: "continue", header: "Step limit", options: [{ label: "Continue" }, { label: "Stop" }] },
  answer: { selected: ["Stop"] },
};
const DRAWN_CARD = {
  type: "card", id: "c1", in_turn: true, of_turn: "T1", iteration: 1,
  title: "Check-in", body: "still going", actions: [],
};
// The drawing already has the turn's card as a row of its step (turn_block.js
// drawnTurnNodes): the placer only refreshes its body.
const DRAWN_MARKUP = TURN.replace('<div class="activity-row">',
  '<div class="plugin-card" data-card-id="c1"><span class="card-title">Check-in</span><div class="card-body">still going</div></div><div class="activity-row">');

// +markup+ as the history's children (both sides start from the same drawing).
function withMarkup(markup) {
  const el = document.createElement("div");
  el.innerHTML = markup;
  return el;
}

// Live: app.js's wiring (livePage) placing the snapshot as session_view.js does.
// Offscreen: cards_offscreen.js over a holder.
function shapes(entries, { markup = TURN, capabilities = null, answers = true } = {}) {
  const page = livePage({ questions: true });
  page.historyEl.innerHTML = markup;
  page.cards.placeSnapshotCards(splitSnapshotCards(entries, capabilities).placed, { before: null });
  const holder = withMarkup(markup);
  placeCardsOffscreen(holder, entries, { capabilities, answers });
  return { live: historyShape(page.historyEl), offscreen: historyShape(holder), page };
}

for (const [name, entry, markup] of [["a resolved question", QUESTION, TURN], ["an approval answered Deny", APPROVAL, TURN], ["a cancelled question", CANCELLED, TURN], ["a step-limit question", STEP_LIMIT, TURN], ["a drawn turn's card", DRAWN_CARD, DRAWN_MARKUP]]) {
  test(`${name}: placed offscreen as the page places it`, () => {
    const { live, offscreen } = shapes([entry], { markup });
    const verdict = compareShapes(live, offscreen);
    assert.ok(verdict.same, `${name}\nlive: ${JSON.stringify(live)}\noffscreen: ${JSON.stringify(offscreen)}`);
    assert.ok(live.some((item) => item.kind === (entry.type === "card" ? "card" : "question")), `${name} shows up in the shape`);
  });
}

test("two questions of one turn are placed in their order", () => {
  const first = { ...QUESTION, pending_question: { id: "q1", question: "Which one?" }, answer: { selected: ["A"] } };
  const second = { ...QUESTION, iteration: 2, pending_question: { id: "q2", question: "And then?" }, answer: { selected: ["B"] } };
  const { live, offscreen } = shapes([first, second]);
  assert.ok(compareShapes(live, offscreen).same);
  const asked = offscreen.filter((item) => item.kind === "question").map((item) => item.text);
  assert.equal(asked.length, 2);
  assert.ok(asked[0].includes("Which one?"), asked.join(" | "));
  assert.ok(asked[1].includes("And then?"), asked.join(" | "));
});

test("answers: false: a viewer who cannot answer gets no question card", () => {
  const { offscreen } = shapes([QUESTION], { answers: false });
  assert.ok(offscreen.every((item) => item.kind !== "question"));
});

test("the placer touches nothing but the holder: no fold storage, no api call", () => {
  const map = new Map([["chi_asking_fold:s1", JSON.stringify({ key: "q:q1", with: 1 })], ["null", "leftover"]]);
  const before = Object.getOwnPropertyDescriptor(globalThis, "sessionStorage");
  Object.defineProperty(globalThis, "sessionStorage", {
    value: { getItem: (k) => map.get(String(k)) ?? null, setItem: (k, v) => map.set(String(k), v), removeItem: (k) => map.delete(String(k)) },
    configurable: true, writable: true,
  });
  const fetches = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (url, opts) => { fetches.push(url); return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}), text: () => Promise.resolve("") }); };
  try {
    const holder = withMarkup(TURN);
    placeCardsOffscreen(holder, [QUESTION, DRAWN_CARD], { capabilities: null, answers: true });
    // Its buttons are inert: an answer or a card action reaches neither chi web nor the page.
    holder.querySelector(".bubble.question .question-answer, .bubble.question button")?.click();
    holder.querySelector(".plugin-card .card-action")?.click();
    assert.equal(fetches.length, 0, `the offscreen placer called the api: ${fetches.join(", ")}`);
    assert.ok(map.get("chi_asking_fold:s1"), "the live tab's fold is untouched");
    assert.ok(map.get("null"), "no key \"null\" is written or deleted");
  } finally {
    globalThis.fetch = realFetch;
    if (before) Object.defineProperty(globalThis, "sessionStorage", before);
    else delete globalThis.sessionStorage;
  }
});

test("the placer draws its own question cards: a page-level instance is never called", () => {
  // The page's question cards (question_cards.js) live in app.js; if the
  // placer reached for one, the live page's card and fold state would change.
  const calls = [];
  const stub = {
    renderQuestion: (pq) => { calls.push("renderQuestion"); },
    questionCard: () => { calls.push("questionCard"); return null; },
    resolveQuestion: (id) => { calls.push("resolveQuestion"); },
  };
  globalThis.pageQuestionCards = stub;
  try {
    const holder = withMarkup(TURN);
    placeCardsOffscreen(holder, [QUESTION], { capabilities: null, answers: true });
    assert.equal(calls.length, 0, `the page's questionCards was called: ${calls.join(", ")}`);
    assert.ok(holder.querySelector(".bubble.question"), "the holder drew its own card");
  } finally {
    delete globalThis.pageQuestionCards;
  }
});
