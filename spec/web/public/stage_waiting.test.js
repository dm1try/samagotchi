// The stage's waiting cards as data (stage_waiting.js): the registry, the
// key and kind read off a card, and its feeds (stage_view.js place and its
// reconcile, cards_place.js upsertCard), in happy-dom.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

for (const k of ["MutationObserver", "CustomEvent", "localStorage", "getSelection"]) {
  if (!(k in globalThis)) globalThis[k] = window[k];
}
globalThis.ResizeObserver ??= class { observe() {} disconnect() {} };
globalThis.matchMedia ??= () => ({ matches: false });
if (!window.HTMLElement.prototype.animate) window.HTMLElement.prototype.animate = () => ({ finished: Promise.resolve(), cancel() {}, playState: "finished" });

const {
  CONTINUE_KEY, cardIn, createStageWaiting, pluginCardKey, questionKey, waitingKey, waitingKind,
} = await import("../../../lib/samagotchi/web/public/stage_waiting.js");
const { createStageView } = await import("../../../lib/samagotchi/web/public/stage_view.js");
const { createCardsPlace } = await import("../../../lib/samagotchi/web/public/cards_place.js");
const { drawCard } = await import("../../../lib/samagotchi/web/public/card.js");

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function el(html) {
  const box = document.createElement("div");
  box.innerHTML = html;
  return box.firstElementChild;
}

test("each kind: arrive, count, front, settle; blocking over asks; a warn waits for nobody", () => {
  const w = createStageWaiting();
  w.arrive("c:warn", { kind: "warn" });
  w.arrive("c:ask", { kind: "asks" });
  assert.equal(w.count(), 0);
  assert.equal(w.count({ asks: true }), 1);
  assert.equal(w.front(), "c:ask", "the asking card when nothing blocks");
  for (const kind of ["question", "approval", "relay", "hook", "continue"]) {
    const key = `q:${kind}`;
    w.arrive(key, { kind });
    assert.equal(w.get(key).kind, kind);
  }
  assert.equal(w.count(), 5);
  assert.equal(w.count({ asks: true }), 6);
  assert.equal(w.front(), "q:question", "the first blocking card in arrival order");
  assert.equal(w.settle("q:question"), true);
  assert.equal(w.front(), "q:approval");
  assert.equal(w.settle("q:question"), false, "settled twice: no-op");
  assert.equal(w.settle("c:warn", { only: "asks" }), false, "only that kind");
  assert.ok(w.has("c:warn"));
  w.arrive("x", { kind: "nonsense" });
  w.arrive(null, { kind: "question" });
  assert.equal(w.list().length, 6);
  w.reset();
  assert.deepEqual(w.list(), []);
  assert.equal(w.front(), null);
});

test("docked and the lead-in: as arrive says; a second arrival keeps its place in the order", () => {
  const w = createStageWaiting();
  w.arrive("c:1", { kind: "asks" });
  w.arrive("q:7", { kind: "question", docked: true, leadIn: 7 });
  assert.deepEqual(w.docked(), ["q:7"]);
  assert.equal(w.get("q:7").leadIn, "7");
  assert.equal(w.get("c:1").leadIn, null);
  w.arrive("c:1", { kind: "asks" });
  assert.deepEqual(w.list().map((e) => e.key), ["c:1", "q:7"]);
  w.settle("q:7");
  assert.deepEqual(w.docked(), []);
});

test("the fold: the folded card's key; one more card waiting drops it, an answer lowers the mark, another form drops it", () => {
  const w = createStageWaiting();
  w.arrive("q:1", { kind: "question", docked: true });
  w.fold("q:1");
  assert.equal(w.trackFold("q:1"), "q:1");
  w.arrive("q:2", { kind: "approval" });
  assert.equal(w.trackFold("q:1"), null, "a second card opens the stage on it");
  w.fold("q:1");
  w.settle("q:2");
  assert.equal(w.trackFold("q:1"), "q:1", "an answer lowers the mark");
  w.arrive("q:3", { kind: "hook" });
  assert.equal(w.trackFold("q:1"), null, "so the next one drops it");
  w.fold("q:1");
  assert.equal(w.trackFold("q:9"), null, "another form never matches");
  w.fold("q:1");
  w.reset();
  assert.equal(w.folded(), null);
  w.fold(null);
  assert.equal(w.trackFold("q:1"), null);
});

test("the key and kind read off a card; a plugin card keeps its key across a DIV ↔ DETAILS swap", () => {
  const card = (attrs, cls = "bubble question") => el(`<details class="${cls}" ${attrs}><summary>Q</summary></details>`);
  assert.equal(waitingKey(card('data-qid="5" data-kind="question"')), questionKey(5));
  assert.equal(waitingKind(card('data-qid="5" data-kind="question"')), "question");
  assert.equal(waitingKind(card('data-qid="5" data-kind="approval"', "bubble question approval")), "approval");
  assert.equal(waitingKind(card('data-qid="5" data-kind="approval" data-relay="1"', "bubble question approval")), "relay");
  assert.equal(waitingKind(card('data-qid="5" data-kind="hook"')), "hook");
  assert.equal(waitingKind(card('data-qid="5" data-kind="continue"', "bubble question step-limit")), "continue");
  assert.equal(waitingKind(card('data-qid="5" data-kind="question"', "bubble question answered")), null, "answered: waits no more");
  const cont = el('<div class="bubble continue"></div>');
  assert.equal(waitingKey(cont), CONTINUE_KEY);
  assert.equal(waitingKind(cont), "continue");
  assert.equal(waitingKey(el('<div class="bubble note"></div>')), null);
  assert.equal(pluginCardKey(""), null);

  // check-in's card, then its notice row (card.js drawCard swaps the node).
  const root = document.createElement("div");
  const asking = drawCard(document.createElement("div"), { id: "ci", in_turn: true, title: "3 tool calls", body: "b", actions: [{ label: "Nudge", command: "/nudge" }] });
  root.appendChild(asking);
  assert.equal(waitingKey(asking), "c:ci");
  assert.equal(waitingKind(asking), "asks");
  const notice = drawCard(asking, { id: "ci", in_turn: true, title: "check-in", body: "The turn ended.", level: "notice" });
  const now = cardIn(root, "c:ci");
  assert.ok(now === notice);
  assert.equal(waitingKey(now), "c:ci");
  assert.equal(waitingKind(now), null, "no actions: waits no more");
});

// A stage view holding a turn, its step asking (stage_view.test.js's).
function holdingPage() {
  document.body.innerHTML = '<div id="center"><div id="history"></div><div id="dock"><div id="composer"></div></div></div>';
  const historyEl = document.getElementById("history");
  const view = createStageView({
    historyEl, isNearBottom: () => false, sawText: () => false, sessionId: () => "s1",
    dockEl: document.getElementById("dock"), centerEl: document.getElementById("center"),
  });
  const append = (node) => { if (!view.place(node)) historyEl.appendChild(node); };
  const prompt = document.createElement("div");
  prompt.className = "bubble user";
  view.turnStarted({ promptBubble: prompt });
  return { view, historyEl, append };
}
function asks(view, text) {
  view.generationStarted({ iteration: 1 });
  if (text) view.chunk({ iteration: 1, text });
  view.toolStarted({ iteration: 1, call_index: 1, tool: "ask_user_question", params: "q" });
}
function questionCard(qid, kind = "question") {
  return el(`<details class="bubble question" data-qid="${qid}" data-kind="${kind}" open><summary>Q</summary><button></button></details>`);
}

test("place feeds it: a promoted question docks with its lead-in, another kind arrives undocked; a reset empties it", () => {
  const { view, append } = holdingPage();
  try {
    asks(view, "Both matter. Which first?");
    append(questionCard("q1"));
    assert.deepEqual(view.waiting.list().map(({ key, kind, docked, leadIn }) => ({ key, kind, docked, leadIn })),
      [{ key: "q:q1", kind: "question", docked: true, leadIn: "q1" }]);
    assert.ok(view.root.classList.contains("asking-form"));
    view.reset();
    assert.deepEqual(view.waiting.list(), []);
    const again = holdingPage();
    asks(again.view, "Running it.");
    again.append(questionCard("a1", "approval"));
    assert.deepEqual(again.view.waiting.list().map(({ kind, docked }) => ({ kind, docked })), [{ kind: "approval", docked: false }]);
    assert.equal(again.view.waiting.front(), "q:a1");
    again.view.reset();
  } finally {
    view.reset();
  }
});

test("the second feed: a card answered by its classes alone (no hook) settles at the refresh", async () => {
  const { view, append } = holdingPage();
  try {
    asks(view, "Both matter. Which first?");
    const card = questionCard("q1");
    append(card);
    assert.equal(view.waiting.count(), 1);
    card.classList.add("answered");
    await tick();
    assert.deepEqual(view.waiting.list(), []);
    assert.ok(!view.root.classList.contains("asking-form"));
  } finally {
    view.reset();
  }
});

test("the hook feed settles at once, before the refresh; it never docks or adds", () => {
  const { view, append } = holdingPage();
  try {
    asks(view, "Both matter. Which first?");
    append(questionCard("q1"));
    view.settleWaiting("q:q1");
    assert.deepEqual(view.waiting.docked(), []);
    view.settleWaiting("q:nope");
    assert.deepEqual(view.waiting.list(), []);
  } finally {
    view.reset();
  }
});

test("cards_place: a plugin card redrawn without its actions settles its asking entry, only that", () => {
  const historyEl = document.createElement("div");
  document.body.append(historyEl);
  const settled = [];
  const cards = createCardsPlace({
    historyEl, turnDom: { card: () => false, settleWaiting: (key, opts) => settled.push([key, opts]) },
    findInTurnRoots: (sel) => [...historyEl.querySelectorAll(sel)], selected: () => "s1", clientId: "me", questionCards: null,
    bubbles: { removeHintIfEmpty() {}, placeFollowing: (node) => historyEl.appendChild(node) },
    followWokenWorker() {}, api: { getSession: async () => ({}), sendCommand: async () => ({}) },
  });
  cards.upsertCard({ id: "ci", in_turn: true, title: "t", body: "b", actions: [{ label: "Nudge", command: "/nudge" }] });
  cards.upsertCard({ id: "ci", in_turn: true, title: "t", body: "b2", actions: [{ label: "Nudge", command: "/nudge" }] });
  assert.deepEqual(settled, [], "still asking");
  cards.upsertCard({ id: "ci", in_turn: true, title: "check-in", body: "ended", level: "notice" });
  assert.deepEqual(settled, [["c:ci", { only: "asks" }]]);
});
