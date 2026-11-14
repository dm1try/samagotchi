import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createSessionView } from "../../../lib/samagotchi/web/public/session_view.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";
import { emptySessionState } from "../../../lib/samagotchi/web/public/session_state.js";
import { createGapClock } from "../../../lib/samagotchi/web/public/time_gaps.js";
import { drawnHistory } from "./drawn_history.js";

const settle = () => new Promise((resolve) => setImmediate(resolve));

function deferred() {
  let resolve;
  const promise = new Promise((res) => { resolve = res; });
  return { promise, resolve };
}

// The page around the view, every hook recording its name and arguments
// (+calls+); +read(id, opts)+ answers getSession.
function fakePage({ read = async () => ({}) } = {}) {
  const calls = [];
  const rec = (name, ret) => (...args) => {
    calls.push([name, ...args]);
    return typeof ret === "function" ? ret(...args) : ret;
  };
  const proxy = (prefix, returns = {}) => new Proxy({}, {
    get: (_, name) => rec(`${prefix}.${String(name)}`, returns[name]),
  });
  const store = createSessionStore({ initial: emptySessionState() });
  const historyEl = document.createElement("div");
  const page = { calls, read, pending: null, capabilities: {}, names: () => calls.map((c) => c[0]) };
  const liveTurn = {
    running: false,
    serverGen: null,
    timing: {
      ended: 0, turnId: null,
      start: rec("timing.start"), finish: rec("timing.finish"),
      capture: () => ({ turnId: "t1" }), finishLine: rec("timing.finishLine"),
    },
  };
  // A prompt bubble, as bubbles.js makes one: at the history's end.
  const makeUserBubble = (text, opts) => {
    calls.push(["makeUserBubble", text, opts]);
    const el = document.createElement("div");
    el.className = "bubble user";
    el.textContent = text;
    historyEl.appendChild(el);
    return el;
  };
  const deps = {
    store, historyEl,
    getSession: (...args) => {
      calls.push(["getSession", ...args]);
      return page.read(...args);
    },
    liveTurn,
    turnDom: proxy("turnDom", { turnEnded: () => [] }),
    questionCards: {
      ...proxy("questionCards"),
      pendingQuestion: () => page.pending,
      resolveQuestion: rec("questionCards.resolveQuestion"),
      renderQuestion: rec("questionCards.renderQuestion"),
      markRelayed: rec("questionCards.markRelayed"),
      renderContinue: rec("questionCards.renderContinue"),
    },
    shownTexts: { seed: rec("shownTexts.seed") },
    objectives: { reset: rec("objectives.reset"), seed: rec("objectives.seed") },
    featureGates: { prime: rec("featureGates.prime") },
    markdownTip: { show: rec("markdownTip.show") },
    workingSet: null,
    wsPreview: { reset: rec("wsPreview.reset") },
    gapClock: createGapClock(),
    bubbles: {
      makeUserBubble, addEndBubble: rec("addEndBubble"), showGuardrailWarning: rec("showGuardrailWarning"),
      showRecap: rec("showRecap"),
    },
    cards: { placeSnapshotCards: rec("placeSnapshotCards"), upsertCard: rec("upsertCard") },
    markdown: { linkTextRefs: rec("linkTextRefs"), applyFinalMarkdown: rec("applyFinalMarkdown") },
    capabilities: () => page.capabilities,
    page: {
      setReviseAnchor: rec("setReviseAnchor"), renderInitRow: rec("renderInitRow"),
      setMarkdownWarning: rec("setMarkdownWarning"), setCapabilities: rec("setCapabilities"),
      findInTurnRoots: () => [...historyEl.querySelectorAll(".bubble")],
      appendToHistory: (el) => { historyEl.appendChild(el); },
      setTurnRunning: rec("setTurnRunning", (running) => { liveTurn.running = running; }),
      mergeTurnTiming: rec("mergeTurnTiming", async () => true),
      applySessionPayload: rec("applySessionPayload"), turnEndStatus: rec("turnEndStatus"),
      replaceSelectedCard: rec("replaceSelectedCard"),
    },
    later: {
      handlers: () => ({ turn_started: rec("handlers.turn_started") }),
      composer: () => ({ newVisit: rec("composer.newVisit") }),
      ownerVerify: () => ({ clear: rec("ownerVerify.clear"), renderSaved: rec("ownerVerify.renderSaved") }),
      commandList: () => ({ close: rec("commandList.close") }),
      initTasks: () => new Map(),
      resetTurnView: rec("resetTurnView"),
    },
  };
  return { page, store, historyEl, liveTurn, view: createSessionView(deps) };
}

const count = (page, name) => page.names().filter((n) => n === name).length;
const session = { id: "s1", status: "idle", model_name: "qwen", working_directory: "/w" };

test("renderSessionView draws the history, the kept command bubbles after their turn, then a failed turn's prompt", () => {
  const { page, store, historyEl, view } = fakePage();
  store.update({ selected: "s1" });
  const { items, drawings } = drawnHistory([
    { role: "user", content: "first", turn_id: "t1" },
    { role: "assistant", content: "one", turn_id: "t1" },
  ]);
  const kept = document.createElement("div");
  kept.className = "bubble command";
  kept.textContent = "/help";
  view.renderSessionView(
    { session, messages: items, turn_drawings: drawings, failed_turn: { prompt: "again", error: "boom" } },
    { kept: [{ el: kept, anchor: { users: 1, shells: 0 } }] },
  );
  const bubbles = [...historyEl.querySelectorAll(".bubble.user, .bubble.command")];
  assert.deepEqual(bubbles.map((b) => b.textContent.trim().split("\n")[0]), ["first", "/help", "again"]);
  assert.equal(bubbles[2].dataset.failedTurn, "1");
  assert.equal(count(page, "addEndBubble"), 1);
  assert.equal(count(page, "ownerVerify.renderSaved"), 1);
  assert.equal(store.current.model, "qwen");
});

test("renderSessionView replays a running turn through the handlers, marked replayed", () => {
  const { page, store, view } = fakePage();
  store.update({ selected: "s1" });
  view.renderSessionView({
    session: { ...session, status: "running" }, messages: [],
    replay: [{ type: "turn_started", turn_id: "t2" }, { type: "no_such_event" }],
    current_turn: { turn_id: "t2" },
  });
  assert.deepEqual(page.calls.find((c) => c[0] === "handlers.turn_started"), ["handlers.turn_started", { type: "turn_started", turn_id: "t2", replayed: true }]);
});

test("renderSessionView of an empty session says so; a pending question and a continue offer come back", () => {
  const { page, store, historyEl, view } = fakePage();
  store.update({ selected: "s1" });
  view.renderSessionView({
    session, messages: [],
    pending_question: { id: "q1", status: "pending", relayed_to: "parent" },
    continue_offer: { id: "c1" },
  });
  assert.ok(historyEl.textContent.includes("No output yet"));
  assert.deepEqual(page.calls.find((c) => c[0] === "questionCards.markRelayed"), ["questionCards.markRelayed", "q1", "parent"]);
  assert.equal(count(page, "questionCards.renderContinue"), 1);
});

test("forgetSession starts the page over; keepVerify (the same session again) keeps Verify and Revise", () => {
  const { page, store, view } = fakePage();
  store.update({ current: { model: "qwen" } });
  view.forgetSession({ keepVerify: true });
  assert.equal(count(page, "ownerVerify.clear"), 0);
  assert.equal(count(page, "setReviseAnchor"), 0);
  assert.equal(store.current.model, emptySessionState().model);
  for (const name of ["commandList.close", "resetTurnView", "objectives.reset", "renderInitRow", "composer.newVisit"]) {
    assert.equal(count(page, name), 1, name);
  }
  assert.deepEqual(page.calls.find((c) => c[0] === "setCapabilities"), ["setCapabilities", null, null]);

  // The same session again keeps the reader; another one (or the start page) resets it.
  assert.equal(count(page, "wsPreview.reset"), 0);
  view.forgetSession();
  assert.equal(count(page, "wsPreview.reset"), 1);
  assert.equal(count(page, "ownerVerify.clear"), 1);
  assert.deepEqual(page.calls.find((c) => c[0] === "setReviseAnchor"), ["setReviseAnchor", null]);
});

test("endTurnView: an ended turn counts, a gone worker's doesn't; a cancel says so; the pending question goes", () => {
  const { page, liveTurn, view } = fakePage();
  liveTurn.running = true;
  view.endTurnView("completed");
  assert.equal(liveTurn.timing.ended, 1);
  assert.equal(liveTurn.running, false);
  view.endTurnView("gone", "the worker left", { stopped: true });
  assert.equal(liveTurn.timing.ended, 1);
  assert.deepEqual(page.calls.find((c) => c[0] === "addEndBubble"), ["addEndBubble", "the worker left", { stopped: true }]);
  page.pending = { id: "q1" };
  view.endTurnView("canceled", "canceled");
  assert.deepEqual(page.calls.filter((c) => c[0] === "timing.finish").map((c) => c[1]),
    [{ canceled: false }, { canceled: false }, { canceled: true }]);
  assert.deepEqual(page.calls.find((c) => c[0] === "questionCards.resolveQuestion"),
    ["questionCards.resolveQuestion", "q1", { cancelled: true, reason: "turn ended" }]);
});

test("endTurnView of an empty answer puts its notice in the history when the turn block didn't", () => {
  const { historyEl, view } = fakePage();
  view.endTurnView("completed", null, { emptyAnswer: { reason: "empty" } });
  assert.equal(historyEl.children.length, 1);
});

test("readTurnEnd reads the turn's end into the page; on another session by then it is a no-op", async () => {
  const { page, store, view } = fakePage({ read: async () => ({ session, timing: {}, messages: [] }) });
  await view.readTurnEnd();
  assert.equal(count(page, "getSession"), 0, "no session open: no read");

  store.update({ selected: "s1" });
  await view.readTurnEnd();
  assert.deepEqual(page.calls.find((c) => c[0] === "getSession"), ["getSession", "s1", { tail: true, recent: true, turnId: "t1" }]);
  assert.equal(count(page, "timing.finishLine"), 1);
  assert.equal(count(page, "applyFinalMarkdown"), 1);

  const pending = deferred();
  page.read = () => pending.promise;
  const reading = view.readTurnEnd();
  store.update({ selected: "s2" });
  pending.resolve({ session, timing: {}, messages: [] });
  await reading;
  await settle();
  assert.equal(count(page, "mergeTurnTiming"), 1);
  assert.equal(count(page, "applyFinalMarkdown"), 1);
});

test("historyOpts reads the page's capabilities at the call", () => {
  const { page, view } = fakePage();
  page.capabilities = { editor: true };
  assert.deepEqual(view.historyOpts({ current_turn: { turn_id: "t9" } }).capabilities, { editor: true });
  assert.equal(view.historyOpts().runningTurnId, null);
  assert.equal(view.historyOpts({ current_turn: { turn_id: "t9" } }).runningTurnId, "t9");
});
