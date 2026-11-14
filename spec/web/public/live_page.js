// The live page the turn-drawing harnesses share (turn_drawing_parity.test.js,
// stage_cuts_parity.test.js), in happy-dom (dom_shim.js).
import "./dom_shim.js";

for (const k of ["MutationObserver", "CustomEvent", "localStorage", "sessionStorage", "getSelection", "CSS"]) {
  if (!(k in globalThis)) globalThis[k] = window[k];
}
globalThis.ResizeObserver ??= class { observe() {} disconnect() {} };
globalThis.IntersectionObserver ??= class { observe() {} unobserve() {} disconnect() {} };
globalThis.matchMedia ??= () => ({ matches: false });
if (!window.HTMLElement.prototype.animate) window.HTMLElement.prototype.animate = () => ({ finished: Promise.resolve(), cancel() {}, playState: "finished" });

const { createStageView } = await import("../../../lib/samagotchi/web/public/stage_view.js");
const { createStreamHandlers } = await import("../../../lib/samagotchi/web/public/stream_handlers.js");
const { createBubbles } = await import("../../../lib/samagotchi/web/public/bubbles.js");
const { createCardsPlace } = await import("../../../lib/samagotchi/web/public/cards_place.js");
const { createSessionStore } = await import("../../../lib/samagotchi/web/public/session_store.js");
const { createShownTexts } = await import("../../../lib/samagotchi/web/public/shown_texts.js");
const { createQuestionCards } = await import("../../../lib/samagotchi/web/public/question_cards.js");
const { elementOf, emptyAnswerTemplate } = await import("../../../lib/samagotchi/web/public/turn_html.js");

// What this tab kept in sessionStorage. `npm test` runs every file in one
// process (no isolation), so a test that folds clears it first: one test's
// fold is not another's.
export function clearSession() {
  try { globalThis.sessionStorage?.clear(); } catch (_) {}
}

// The live page, its pieces as app.js wires them (the stage view, the
// bubbles, the cards' placement, the stream handlers), the rest stubbed:
// no timing line (the reload has no records here either). No question
// cards (a question's card is placed from CardStore on both sides), unless
// +questions+: question_cards.js wired as app.js wires it (the stage cuts).
export function livePage({ questions = false } = {}) {
  document.body.innerHTML = '<div id="center"><div id="history"></div><div id="dock"><div id="composer"></div></div></div>';
  const historyEl = document.getElementById("history");
  const shownTexts = createShownTexts();
  const turnDom = createStageView({
    historyEl, isNearBottom: () => false, sawText: (k) => shownTexts.saw(k), sessionId: () => "s1",
    dockEl: document.getElementById("dock"), centerEl: document.getElementById("center"),
  });
  const findInTurnRoots = (selector) => [...historyEl.querySelectorAll(selector), ...turnDom.root.querySelectorAll(selector)];
  const liveTurn = {
    running: false, failedText: null, review: null,
    timing: { el: null, turnId: null, ended: 0, setNote() {}, detach() {}, start(_at, id) { liveTurn.timing.turnId = id; }, finish() {}, capture: () => ({}) },
    releaseDisplay() {},
  };
  const appendToHistory = (el) => {
    if (turnDom.place(el)) return true;
    historyEl.appendChild(el);
    return false;
  };
  const bubbles = createBubbles({
    historyEl, appendToHistory, isNearBottom: () => false, turnDom, findInTurnRoots, shownTexts, liveTurn,
    selected: () => "s1", clientId: "web:me",
  });
  const questionCards = questions
    ? createQuestionCards({
      sessionId: () => "s1", clientId: "web:me", place: (card) => appendToHistory(card), isNearBottom: () => false,
      scrollToEnd() {}, removeHintIfEmpty() {}, askingText: (pq) => turnDom.askingText(pq),
      api: { sendAnswer: async () => ({}), dismissQuestion: async () => ({}), sendCommand: async () => ({}) },
      onArrive: (key, info) => turnDom.expectWaiting?.(key, info),
      onSettled: (key) => turnDom.settleWaiting?.(key),
    })
    : new Proxy({}, { get: () => () => null });
  const cards = createCardsPlace({
    historyEl, turnDom, findInTurnRoots, selected: () => "s1", clientId: "web:me", questionCards, bubbles,
    followWokenWorker() {}, api: { getSession: async () => ({ cards: [] }), sendCommand: async () => {} },
  });
  // session_view.js's endTurnView, without the composer and the timing line.
  function endTurnView(kind, endText = null, { emptyAnswer = null, stopped = false } = {}) {
    liveTurn.running = false;
    const endNote = emptyAnswer ? elementOf(emptyAnswerTemplate(emptyAnswer)) : null;
    const kept = turnDom.turnEnded({ kind, endNote, emptyAnswer: !!emptyAnswer, turnId: liveTurn.timing.turnId }) || [];
    if (endNote && !endNote.isConnected) appendToHistory(endNote);
    if (endText) bubbles.addEndBubble(endText, { stopped });
    kept.forEach((el) => appendToHistory(el));
  }
  const store = createSessionStore({ initial: { model: "m", ctxWindow: 1000, llmContext: null, timing: { tokens: null, turnRecords: [] } } });
  const handlers = createStreamHandlers({
    selected: () => "s1", store, clientId: "web:me", capabilities: () => ({}), historyEl, liveTurn, turnDom, shownTexts,
    questionCards, contextChips: { refresh() {} }, sentIds: new Set(), earlyRestores: new Map(),
    stream: { takeGuess: () => false, restart() {} },
    composer: { empty: () => true, refill() {}, setChips() {} },
    getSession: async () => ({ messages: [] }),
    resync: async () => {}, setTurnRunning: (on) => { liveTurn.running = on; }, setLiveStatus() {}, endTurnView,
    readTurnEnd: async () => {}, refreshTimingFromSession() {}, setUsedMemories() {}, onInitEvent() {}, findInTurnRoots,
    applyFinalMarkdown() {},
    applyPromptOps: bubbles.applyPromptOps, showSteers: bubbles.showSteers, markRecapStale() {}, appendChunk: bubbles.appendChunk,
    makeUserBubble: bubbles.makeUserBubble, addEndBubble: bubbles.addEndBubble, commandBubble: bubbles.commandBubble,
    addCommandBubble: bubbles.addCommandBubble, addNoteBubble: bubbles.addNoteBubble, showRecap() {}, showGuardrailWarning() {},
    showHookNotice: bubbles.showHookNotice, addTimeGap() {},
    upsertCard: cards.upsertCard, refreshCardBodies() {},
  });
  return { historyEl, turnDom, handlers, cards, questionCards };
}
