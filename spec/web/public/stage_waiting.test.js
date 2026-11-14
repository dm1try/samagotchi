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
  CONTINUE_KEY, cardIn, createStageWaiting, foldKey, pluginCardKey, questionKey, waitingKey, waitingKind,
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

test("docked: as arrive says; a second arrival keeps its place in the order", () => {
  const w = createStageWaiting();
  w.arrive("c:1", { kind: "asks" });
  w.arrive("q:7", { kind: "question", docked: true });
  assert.deepEqual(w.docked(), ["q:7"]);
  w.arrive("c:1", { kind: "asks" });
  // The stage's order: the blocking card first.
  assert.deepEqual(w.list().map((e) => e.key), ["q:7", "c:1"]);
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

// The fold of the asking card is this tab's own (audit r20 D5): a Map-backed
// storage stands in for sessionStorage, one per test.
function foldStore() {
  const map = new Map();
  return {
    read: (k) => map.get(k) ?? null,
    write: (k, v) => map.set(k, String(v)),
    remove: (k) => map.delete(k),
  };
}

test("the fold kept for the tab: written on fold, gone on unfold and on the drop; a replay takes it back", () => {
  const store = foldStore();
  const at = foldKey("s1");
  const w = createStageWaiting({ sessionId: () => "s1", storage: store });
  w.arrive("q:1", { kind: "question", docked: true });
  assert.ok(store.read(at) === null, "nothing stored before a fold");
  w.fold("q:1");
  assert.deepEqual(JSON.parse(store.read(at)), { key: "q:1", with: 1 }, "the card and how many waited");

  // The replay redrew the same card: memory is empty, the stored fold comes back.
  w.reset();
  assert.equal(w.folded(), null, "reset clears memory only");
  assert.ok(store.read(at), "reset leaves the stored entry alone");
  w.arrive("q:1", { kind: "question", docked: true });
  assert.equal(w.trackFold("q:1"), "q:1", "the fold the tab kept");

  // A different card is not the folded one.
  w.fold(null);
  assert.ok(store.read(at) === null, "unfolded: the entry goes");
  w.fold("q:1");
  w.arrive("q:2", { kind: "approval", docked: true });
  assert.equal(w.trackFold("q:1"), null, "one more waiting drops it");
  assert.ok(store.read(at) === null, "and a reload must not fold it back");
  w.arrive("q:1", { kind: "question", docked: true });
  assert.equal(w.trackFold("q:1"), null, "nothing stored: no fold to take back");

  // A check-in card folds too, by its own key.
  w.arrive("c:ci", { kind: "asks", docked: true });
  w.fold("c:ci");
  assert.deepEqual(JSON.parse(store.read(at)), { key: "c:ci", with: 2 }, "two cards waited at the fold");
  // Answered for good.
  w.clearFold();
  assert.ok(store.read(at) === null);

  // No session: nothing to keep, and nothing thrown.
  const bare = createStageWaiting({ storage: store });
  bare.arrive("q:1", { kind: "question", docked: true });
  bare.fold("q:1");
  assert.ok(store.read(at) === null, "no session, no entry");
});

test("the fold survives the cards the resync takes off and puts back", () => {
  const store = foldStore();
  const w = createStageWaiting({ sessionId: () => "s1", storage: store });
  w.arrive("q:1", { kind: "question", docked: true });
  w.fold("q:1");
  // removeQuestion / replaceQuestionCard only settle the card: the entry stays.
  w.settle("q:1");
  assert.ok(store.read(foldKey("s1")), "settling does not clear it");
  w.arrive("q:1", { kind: "question", docked: true });
  assert.equal(w.trackFold("q:1"), "q:1", "the redrawn card is folded as it was");
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

test("place feeds it: a question docks with its lead-in, an approval with its own, a hook's question with none; a reset empties it", () => {
  const { view, append } = holdingPage();
  try {
    asks(view, "Both matter. Which first?");
    append(questionCard("q1"));
    assert.deepEqual(view.waiting.list().map(({ key, kind, docked }) => ({ key, kind, docked })),
      [{ key: "q:q1", kind: "question", docked: true }]);
    assert.equal(document.querySelector("#history .bubble.said").dataset.questionId, "q1", "its lead-in");
    assert.ok(view.root.classList.contains("asking-form"));
    view.reset();
    assert.deepEqual(view.waiting.list(), []);
    const again = holdingPage();
    asks(again.view, "Running it.");
    again.append(questionCard("a1", "approval"));
    assert.deepEqual(again.view.waiting.list().map(({ kind, docked, approval }) => ({ kind, docked, approval })),
      [{ kind: "approval", docked: true, approval: true }]);
    assert.equal(document.querySelector("#history .bubble.said").dataset.questionId, "a1", "its lead-in");
    assert.equal(again.view.waiting.front(), "q:a1");
    again.view.reset();
    const hook = holdingPage();
    asks(hook.view, "Running it.");
    hook.append(questionCard("h1", "hook"));
    assert.deepEqual(hook.view.waiting.list().map(({ kind, docked }) => ({ kind, docked })), [{ kind: "hook", docked: true }]);
    assert.ok(document.querySelector("#history .bubble.said") === null, "no lead-in");
    hook.view.reset();
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

test("the stage's order: blocking cards before the asking ones, arrival within each; one shown, the pager moves it, a new card resets it", () => {
  const w = createStageWaiting();
  w.arrive("c:check-in", { kind: "asks", docked: true });
  w.arrive("c:warn", { kind: "warn" });
  w.arrive("q:a1", { kind: "approval", docked: true });
  w.arrive("q:h1", { kind: "hook", docked: true });
  assert.deepEqual(w.list().map((e) => e.key), ["q:a1", "q:h1", "c:check-in", "c:warn"]);
  assert.deepEqual(w.docked(), ["q:a1", "q:h1", "c:check-in"]);
  assert.deepEqual(w.blocking(), ["q:a1", "q:h1"]);
  assert.equal(w.shown(), "q:a1");
  assert.equal(w.page(1), "q:h1");
  assert.equal(w.page(5), "c:check-in", "clamped");
  assert.equal(w.shown(), "c:check-in");
  assert.equal(w.page(-1), "q:h1");
  // The shown card answered: the first one shows.
  w.settle("q:h1");
  assert.equal(w.shown(), "q:a1");
  w.page(1);
  assert.equal(w.shown(), "c:check-in");
  // A new card goes in front of what the pager was on.
  w.arrive("q:q2", { kind: "question", docked: true });
  assert.equal(w.shown(), "q:a1");
  // Arriving again keeps the paging.
  w.page(1);
  w.arrive("q:a1", { kind: "approval", docked: true });
  assert.equal(w.shown(), "q:q2");
  w.reset();
  assert.equal(w.shown(), null);
  assert.equal(w.page(1), null);
});

// The fold's storage (stage_waiting.js FOLD_PREFIX): settle with done removes
// the fold this tab kept only when it names that card, also with no entry for
// it (a replay's earlier card, a history question); without done never.
test("settle with done drops its own stored fold only, entry or not; a plain settle keeps it", () => {
  const map = new Map();
  const storage = { read: (k) => map.get(k) ?? null, write: (k, v) => map.set(k, v), remove: (k) => map.delete(k) };
  const w = createStageWaiting({ sessionId: () => "s1", storage });
  const key = foldKey("s1");
  w.arrive("c:ci", { kind: "asks", docked: true });
  w.arrive("q:a1", { kind: "approval", docked: true });
  w.fold("c:ci");
  assert.equal(JSON.parse(map.get(key)).key, "c:ci");
  assert.equal(w.settle("q:a1", { done: true }), true, "the approval answered");
  assert.equal(JSON.parse(map.get(key)).key, "c:ci", "another card's answer keeps the fold");
  assert.equal(w.settle("q:old", { done: true }), false, "a card the stage never held");
  assert.ok(map.get(key), "still kept");
  w.settle("c:ci");
  assert.ok(map.get(key), "a plain settle (a redraw, a resync) keeps it");
  w.reset();
  assert.equal(w.settle("c:ci", { done: true }), false, "no entry after a reset");
  assert.equal(map.get(key), undefined, "its own answer drops it all the same");
});

test("settle with done and no session stores nothing and removes nothing", () => {
  const removed = [];
  const storage = { read: () => JSON.stringify({ key: "q:1", with: 1 }), write() {}, remove: (k) => removed.push(k) };
  const w = createStageWaiting({ sessionId: () => null, storage });
  w.settle("q:1", { done: true });
  assert.deepEqual(removed, []);
});
