import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createCardsPlace, reloadedTurnEls, turnAnswerEl } from "../../../lib/samagotchi/web/public/cards_place.js";
import { createBubbles } from "../../../lib/samagotchi/web/public/bubbles.js";

// +markup+ as the history's children.
function history(markup = "") {
  const el = document.createElement("div");
  el.innerHTML = markup;
  document.body.append(el);
  return el;
}

// The page's wiring over a bare history (no stage; a running turn's card
// goes into +turnCard+'s step when it returns true).
function harness(historyEl, { turnCard = () => false, questionCards = null, api = {} } = {}) {
  const findInTurnRoots = (selector) => [...historyEl.querySelectorAll(selector)];
  const common = {
    historyEl,
    appendToHistory: (el) => historyEl.appendChild(el),
    isNearBottom: () => true,
    findInTurnRoots,
    selected: () => "s1",
    clientId: "me",
  };
  const bubbles = createBubbles({
    ...common, turnDom: { holds: () => false, steer: () => false }, shownTexts: { shows: () => false },
    liveTurn: { timing: { el: null } },
  });
  const woke = [];
  const cards = createCardsPlace({
    ...common,
    turnDom: { card: turnCard },
    questionCards,
    bubbles,
    followWokenWorker: () => woke.push(true),
    api: { getSession: async () => ({}), sendCommand: async () => ({}), ...api },
  });
  return { cards, woke };
}

const TWO_TURNS = '<div class="bubble user">one</div><div class="turn-work"><div class="gen"><div class="gen-text">asked</div></div></div>'
  + '<div class="bubble output">a1</div><div class="turn-timing">t1</div>'
  + '<div class="bubble user">two</div><div class="bubble user steered" data-step="2">more</div><div class="turn-timing">t2</div>';

test("a reloaded turn's elements, its prompt first; steered lines aren't a turn's start", () => {
  const h = history(TWO_TURNS);
  const second = h.querySelectorAll(".bubble.user")[1];
  assert.deepEqual(reloadedTurnEls(h, second).map((el) => el.textContent), ["one", "asked", "a1", "t1"]);
  assert.deepEqual(reloadedTurnEls(h, null).map((el) => el.textContent), ["two", "more", "t2"]);
});

test("a turn's answer, else its timing line, else none", () => {
  const h = history(TWO_TURNS);
  const [first, second] = [reloadedTurnEls(h, h.querySelectorAll(".bubble.user")[1]), reloadedTurnEls(h, null)];
  assert.equal(turnAnswerEl(first).textContent, "a1");
  assert.equal(turnAnswerEl(second).textContent, "t2");
  assert.equal(turnAnswerEl([]), null);
});

test("a card is added once, then updated in place by its id", () => {
  const h = history('<div class="hint">No output yet.</div>');
  const { cards } = harness(h);
  cards.upsertCard({ id: "c1", title: "Check", body: "first" });
  assert.equal(h.querySelector(".hint"), null);
  const el = cards.cardElement("c1");
  assert.ok(el);
  cards.upsertCard({ id: "c1", title: "Check", body: "second" });
  assert.equal(h.querySelectorAll(".plugin-card").length, 1);
  assert.ok(cards.cardElement("c1").classList.contains("card-updated"));
  cards.upsertCard({ title: "no id" });
  assert.equal(h.querySelectorAll(".plugin-card").length, 1);
  assert.equal(cards.cardElement(null), null);
});

test("a running turn's card goes into its step; one that asks stays under the turn", () => {
  const taken = [];
  const h = history();
  const { cards } = harness(h, { turnCard: (el) => taken.push(el) });
  cards.upsertCard({ id: "row", in_turn: true, title: "t", body: "b" });
  cards.upsertCard({ id: "ask", in_turn: true, title: "t", body: "b", actions: [{ label: "Go", command: "/go" }] });
  assert.equal(taken.length, 1);
  assert.equal(h.querySelectorAll(".plugin-card").length, 1);
  assert.equal(h.querySelector(".plugin-card").dataset.cardId, "ask");
});

test("a snapshot's entries: each above the first turn after it, a turn notice in its step's rows", () => {
  const h = history(TWO_TURNS);
  const { cards } = harness(h);
  cards.placeSnapshotCards([
    { type: "card", id: "c1", title: "Card", body: "x", turns_since: 1 },
    { type: "guardrail_warning", message: "bad", turns_since: 2 },
    { type: "hook_notice", in_turn: true, iteration: 1, hook: "h", text: "in step", turns_since: 1 },
    { type: "hook_notice", in_turn: true, iteration: 5, hook: "h", text: "no such step", turns_since: 1 },
    { type: "hook_notice", line: "between" },
  ]);
  const kids = [...h.children];
  const at = (sel) => kids.findIndex((el) => el.matches(sel));
  assert.equal(at(".bubble.guardrail-warning"), 0);
  assert.equal(h.querySelector(".plugin-card").nextElementSibling.textContent, "two");
  assert.equal(h.querySelector(".turn-work .gen .activity-body .hook-notice").textContent.endsWith("in step"), true);
  // A step the history doesn't have: a bubble before the turn's answer.
  const stray = [...h.querySelectorAll(".bubble.hook-notice")].find((el) => el.textContent.endsWith("no such step"));
  assert.ok(stray.nextElementSibling.matches(".bubble.output"));
  assert.equal(h.lastElementChild.textContent, "between");
});

test("a finished turn's question is drawn resolved, before the lines steered after it asked", () => {
  const h = history(TWO_TURNS);
  const calls = [];
  let card = null;
  const questionCards = {
    renderQuestion: (pq, opts) => {
      calls.push(["render", pq.id, opts.said]);
      card = document.createElement("div");
      card.dataset.qid = String(pq.id);
      h.appendChild(card);
    },
    questionCard: () => card,
    resolveQuestion: (id, opts) => calls.push(["resolve", id, opts.answer]),
  };
  const { cards } = harness(h, { questionCards });
  cards.placeSnapshotCards([{ type: "question", pending_question: { id: "q1" }, answer: "yes", iteration: 1 }]);
  assert.deepEqual(calls, [["render", "q1", ""], ["resolve", "q1", "yes"]]);
  assert.ok(card.nextElementSibling.matches(".bubble.user.steered"));
  // Pending (no answer): the running turn's, not placed here.
  cards.placeSnapshotCards([{ type: "question", pending_question: { id: "q2" } }]);
  assert.equal(calls.length, 2);
});

test("a card's action runs its command and follows the woken worker; a failure shows on the card", async () => {
  const sent = [];
  const h = history();
  const { cards, woke } = harness(h, {
    api: { sendCommand: async (id, line, opts) => { sent.push([id, line, opts]); if (line === "/bad") throw new Error("nope"); } },
  });
  cards.upsertCard({ id: "c1", title: "Check", body: "b", actions: [{ label: "Go", command: "/go" }, { label: "Bad", command: "/bad" }] });
  const [go, bad] = h.querySelectorAll(".card-action");
  cards.onCardAction({ target: go });
  assert.equal(go.disabled, true);
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(sent[0], ["s1", "/go", { clientId: "me", card: true }]);
  assert.equal(woke.length, 1);
  assert.equal(go.disabled, false);
  cards.onCardAction({ target: bad });
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(h.querySelector(".card-error").textContent, "nope");
});
