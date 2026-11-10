// P2's main pin (turn drawings): for each shared scenario
// (spec/shared/turn_drawings/*.json, written by the Ruby specs), the turn
// the live page draws (its events through the real stream handlers, the
// stage view, the bubbles and the cards' placement, then the hand-off)
// and the same turn after a reload (chi web's show for it, drawn by
// turnHistoryNodes from its drawing) read the same (history_shape.js), with
// no allow list.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";

for (const k of ["MutationObserver", "CustomEvent", "localStorage", "getSelection", "CSS"]) {
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
const { elementOf, emptyAnswerTemplate } = await import("../../../lib/samagotchi/web/public/turn_html.js");
const { turnHistoryNodes } = await import("../../../lib/samagotchi/web/public/turn_block.js");
const { compareShapes, historyShape } = await import("../../../lib/samagotchi/web/public/history_shape.js");

const DIR = new URL("../../shared/turn_drawings/", import.meta.url);
const scenarios = readdirSync(DIR).filter((f) => f.endsWith(".json")).sort()
  .map((f) => ({ name: f.replace(/\.json$/, ""), ...JSON.parse(readFileSync(new URL(f, DIR), "utf8")) }));

// The live page, its pieces as app.js wires them (the stage view, the
// bubbles, the cards' placement, the stream handlers), the rest stubbed:
// no timing line (the reload has no records here either), no question
// cards (a question's card is placed from CardStore on both sides).
function livePage() {
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
  const questionCards = new Proxy({}, { get: () => () => null });
  const cards = createCardsPlace({
    historyEl, turnDom, findInTurnRoots, selected: () => "s1", clientId: "web:me", questionCards, bubbles,
    followWokenWorker() {}, api: { getSession: async () => ({ cards: [] }), sendCommand: async () => {} },
  });
  // app.js's endTurnView, without the composer and the timing line.
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
  return { historyEl, turnDom, handlers };
}

// The live turn's shape after its hand-off (+events+: the scenario's
// stream, the last turn's only when there are several).
async function liveShape(events) {
  const { historyEl, turnDom, handlers } = livePage();
  for (const event of events) await handlers[event.type]?.({ ...event });
  turnDom.handOff({ immediate: true });
  return historyShape(historyEl);
}

// The last turn's events, from the wake note announced just before it (a
// context wake's opening, which live drew as the note came in).
function lastTurnEvents(events) {
  const starts = events.map((e, i) => (e.type === "turn_started" ? i : -1)).filter((i) => i >= 0);
  const start = starts[starts.length - 1];
  return events.slice(events[start - 1]?.type === "context_added" ? start - 1 : start);
}

// The reloaded turn's shape: the show drawn, the drawn turn's pieces only.
function drawnShape(show) {
  document.body.innerHTML = '<div id="history"></div>';
  const historyEl = document.getElementById("history");
  historyEl.append(turnHistoryNodes(show.messages, {}, { thumbs: () => null, drawings: show.turn_drawings }));
  const ids = Object.keys(show.turn_drawings || {});
  const last = ids[ids.length - 1];
  return historyShape([...historyEl.children].filter((el) => el.dataset.drawn === last));
}

for (const scenario of scenarios) {
  test(`${scenario.name}: drawn after a reload as live drew it`, async () => {
    const live = await liveShape(lastTurnEvents(scenario.events));
    const reloaded = drawnShape(scenario.show);
    const verdict = compareShapes(live, reloaded);
    assert.ok(verdict.same, `${scenario.description}\nlive: ${JSON.stringify(live, null, 1)}\nreloaded: ${JSON.stringify(reloaded, null, 1)}`);
    assert.ok(reloaded.length > 0);
  });
}

test("every shared scenario has a show with its drawing", () => {
  assert.ok(scenarios.length >= 16);
  for (const s of scenarios) assert.ok(Object.keys(s.show?.turn_drawings || {}).length, s.name);
});
