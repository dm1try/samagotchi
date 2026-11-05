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
function harness(historyEl, { turnCard = () => false, questionCards = null, api = {}, selected = () => "s1" } = {}) {
  const findInTurnRoots = (selector) => [...historyEl.querySelectorAll(selector)];
  const common = {
    historyEl,
    appendToHistory: (el) => historyEl.appendChild(el),
    isNearBottom: () => true,
    findInTurnRoots,
    selected,
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

test("a reloaded turn's elements stop at a wake's note: a wake turn's rows look in that turn's block", () => {
  const h = history('<div class="bubble user">one</div><div class="turn-work"><div class="gen"><div class="gen-text">first</div></div></div>'
    + '<div class="bubble output">a1</div><div class="bubble note turn-start">woke</div>'
    + '<div class="turn-work"><div class="gen"><div class="gen-text">wake step</div></div></div><div class="bubble output">a2</div>');
  assert.deepEqual(reloadedTurnEls(h, null).map((el) => el.textContent), ["woke", "wake step", "a2"]);
  const { cards } = harness(h);
  cards.placeSnapshotCards([{ type: "hook_notice", in_turn: true, iteration: 1, hook: "h", text: "in wake", turns_since: 0 }]);
  const [first, wake] = h.querySelectorAll(".turn-work");
  assert.equal(first.querySelector(".hook-notice"), null);
  assert.ok(wake.querySelector(".gen .activity-body .hook-notice").textContent.endsWith("in wake"));
});

test("a card goes above a wake's note when that wake came after it", () => {
  const h = history('<div class="bubble user">one</div><div class="bubble output">a1</div><div class="bubble note turn-start">woke</div>'
    + '<div class="bubble output">a2</div>');
  harness(h).cards.placeSnapshotCards([{ type: "card", id: "c1", title: "Card", body: "x", turns_since: 1 }]);
  assert.equal(h.querySelector(".plugin-card").nextElementSibling.textContent, "woke");
});

test("a turn's answer, else its timing line, else none", () => {
  const h = history(TWO_TURNS);
  const [first, second] = [reloadedTurnEls(h, h.querySelectorAll(".bubble.user")[1]), reloadedTurnEls(h, null)];
  assert.equal(turnAnswerEl(first).textContent, "a1");
  assert.equal(turnAnswerEl(second).textContent, "t2");
  assert.equal(turnAnswerEl([]), null);
});

test("a card is added once, then updated in place by its id", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const h = history('<div class="hint">No output yet.</div>');
  const { cards } = harness(h);
  cards.upsertCard({ id: "c1", title: "Check", body: "first" });
  assert.equal(h.querySelector(".hint"), null);
  const el = cards.cardElement("c1");
  assert.ok(el);
  cards.upsertCard({ id: "c1", title: "Check", body: "second" });
  assert.equal(h.querySelectorAll(".plugin-card").length, 1);
  assert.ok(cards.cardElement("c1").classList.contains("card-updated"));
  t.mock.timers.tick(900);
  assert.ok(!cards.cardElement("c1").classList.contains("card-updated"));
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

test("a snapshot's turn notice with a URL: the row in its step links it", () => {
  const h = history(TWO_TURNS);
  const { cards } = harness(h);
  cards.placeSnapshotCards([
    { type: "hook_notice", in_turn: true, iteration: 1, hook: "h", text: "sources: https://x.com/JIRA-1", turns_since: 1 },
  ]);
  const a = h.querySelector(".turn-work .gen .activity-body .hook-notice a");
  assert.equal(a.getAttribute("href"), "https://x.com/JIRA-1");
  assert.equal(a.getAttribute("target"), "_blank");
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

test("a card's action follows no worker when another session opened meanwhile", async () => {
  const h = history();
  let open = "s1";
  const { cards, woke } = harness(h, {
    selected: () => open,
    api: { sendCommand: async () => { open = "s2"; } },
  });
  cards.upsertCard({ id: "c1", title: "Check", body: "b", actions: [{ label: "Go", command: "/go" }] });
  cards.onCardAction({ target: h.querySelector(".card-action") });
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(woke.length, 0);
});

test("a proposal card's buttons stay disabled until its card comes or the action fails; another card's come back", async () => {
  const h = history();
  let fail = false;
  const { cards } = harness(h, { api: { sendCommand: async () => { if (fail) throw new Error("nope"); return {}; } } });
  const actions = [{ label: "Apply", command: "/objectives --card c1 done O1" }, { label: "Dismiss", command: "/objectives --card c1 dismiss" }];
  cards.upsertCard({ id: "c1", title: "Mark O1 done?", body: "b", actions });
  cards.upsertCard({ id: "c2", title: "Other", body: "b", actions: [{ label: "Go", command: "/go" }] });
  const buttons = () => [...h.querySelectorAll('[data-card-id="c1"] .card-action')];
  cards.onCardAction({ target: buttons()[0] });
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(buttons().map((b) => b.disabled), [true, true]);
  // The worker refused it (its command_ran): back.
  cards.actionFailed(actions[0].command);
  assert.deepEqual(buttons().map((b) => b.disabled), [false, false]);
  // A failed post: back.
  fail = true;
  cards.onCardAction({ target: buttons()[0] });
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(buttons().map((b) => b.disabled), [false, false]);
  fail = false;
  const other = h.querySelector('[data-card-id="c2"] .card-action');
  cards.onCardAction({ target: other });
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(other.disabled, false);
});

// The page draws a failed turn's prompt (its prompt went back to the user,
// the store never counted it) at the end of the history, then places the
// snapshot's cards around it.
const FAILED_PROMPT = '<div class="bubble user failed" data-failed-turn="1">failed</div><div class="bubble cancel">✕ failed</div>';

function order(h) {
  return [...h.children].map((el) => el.dataset.cardId || el.textContent);
}

test("a failed prompt is no turn: a card goes above it, as it showed live", () => {
  const h = history(`<div class="bubble user">one</div><div class="bubble output">a1</div>${FAILED_PROMPT}`);
  const { cards } = harness(h);
  cards.placeSnapshotCards([{ type: "card", id: "c1", title: "t", body: "b", turns_since: 0 }], { before: h.querySelector(".failed") });
  assert.deepEqual(order(h), ["one", "a1", "c1", "failed", "✕ failed"]);
});

test("a failed prompt doesn't count: an older card stays above the turn after it", () => {
  const h = history(`<div class="bubble user">one</div><div class="bubble output">a1</div><div class="bubble user">two</div><div class="bubble output">a2</div>${FAILED_PROMPT}`);
  const { cards } = harness(h);
  cards.placeSnapshotCards([{ type: "card", id: "c1", title: "t", body: "b", turns_since: 1 }], { before: h.querySelector(".failed") });
  assert.deepEqual(order(h), ["one", "a1", "c1", "two", "a2", "failed", "✕ failed"]);
});

test("a last turn's notice goes in that turn, not after a failed prompt", () => {
  const h = history(`<div class="bubble user">one</div><div class="bubble output">a1</div>${FAILED_PROMPT}`);
  const { cards } = harness(h);
  cards.placeSnapshotCards([{ type: "hook_notice", hook: "h", text: "note", in_turn: true, turns_since: 0 }], { before: h.querySelector(".failed") });
  assert.equal(h.querySelector(".hook-notice").nextElementSibling.textContent, "a1");
});

test("a reloaded turn's elements stop at its prompt, not at a failed one", () => {
  const h = history(`<div class="bubble user">one</div><div class="bubble output">a1</div>${FAILED_PROMPT}<div class="bubble note">n</div>`);
  assert.deepEqual(reloadedTurnEls(h, null).map((el) => el.textContent), ["one", "a1", "failed", "✕ failed", "n"]);
});
