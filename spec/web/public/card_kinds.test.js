// What a card waits as, from its data (card_kinds.js), against the node the
// page draws for it: for each kind the card is drawn with the real
// createQuestionCards / drawCard in happy-dom, and the data's kind, approval
// flag and folded-row text equal the node's read (stage_waiting.js
// waitingKind, isApprovalCard; stage_asking.js foldedText's DOM read).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

for (const k of ["MutationObserver", "CustomEvent", "localStorage", "sessionStorage", "getSelection"]) {
  if (!(k in globalThis)) globalThis[k] = window[k];
}

const { cardWait, continueWait, questionText, questionWait, warnDiffers } = await import("../../../lib/samagotchi/web/public/card_kinds.js");
const { createQuestionCards } = await import("../../../lib/samagotchi/web/public/question_cards.js");
const { drawCard } = await import("../../../lib/samagotchi/web/public/card.js");
const { createStageAsking } = await import("../../../lib/samagotchi/web/public/stage_asking.js");
const { CONTINUE_KEY, isApprovalCard, questionKey, waitingKind } = await import("../../../lib/samagotchi/web/public/stage_waiting.js");

// The node's folded-row text: stage_asking.js foldedText with no data in the
// registry (its DOM read).
const asking = createStageAsking({
  stage: document.createElement("div"), extras: null, tail: null, scroller: null, fold: null, view: null, opener: null,
  frame: () => null, isOpened: () => false, setOpened() {}, isEnded: () => false, promptEl: () => null, setCloud() {},
  scheduleRefresh() {}, pendingCard: () => false, waiting: { get: () => null },
});
const domText = (card) => asking.foldedText(card);

// The cards question_cards.js draws, each with what it told the stage.
function drawn() {
  const placed = [];
  const arrived = [];
  const cards = createQuestionCards({
    sessionId: () => "s1", clientId: "web:me", place: (card) => { placed.push(card); return false; },
    isNearBottom: () => false, scrollToEnd() {}, removeHintIfEmpty() {},
    onArrive: (key, info) => arrived.push({ key, info }),
    api: { sendAnswer: async () => ({}), dismissQuestion: async () => ({}), sendCommand: async () => ({}) },
  });
  return { cards, placed, arrived };
}

const APPROVAL = {
  tool: "execute", command: "echo ok\nand more", cwd: "/work", rule: "e2e-ask", source: "config", reason: "asks", scopes: ["once"],
};
const RELAY = { id: "r1", child_id: "cccc2222-0000", chain: ["cccc2222"], task: "push it" };
const QUESTIONS = {
  question: { id: "q1", kind: "question", question: "Which file?", options: ["a", "b"] },
  "question without a kind": { id: "q2", question: "Which one?", options: ["a"] },
  approval: { id: "a1", kind: "approval", header: "Approve tool call?", question: "execute: echo ok", options: ["Allow once", "Deny"], approval: APPROVAL },
  "approval of paths": {
    id: "a2", kind: "approval", question: "edit", options: ["Allow once", "Deny"],
    approval: { tool: "edit", paths: ["lib/a.rb", "lib/b/"], rule: "r", source: "config" },
  },
  "approval of an MCP tool": {
    id: "a3", kind: "approval", question: "call", options: ["Allow once", "Deny"], approval: { tool: "mcp", label: "chrome: screenshot" },
  },
  "relayed approval": { id: "a4", kind: "approval", question: "execute: echo ok", options: ["Allow once", "Deny"], approval: APPROVAL, relay: RELAY },
  "relayed question": { id: "q3", kind: "question", question: "Spent?", options: ["ok"], relay: { ...RELAY, asked: "Spent $5." } },
  hook: { id: "h1", kind: "hook", question: "Go on?", options: ["yes", "no"] },
  "relayed hook": { id: "h2", kind: "hook", question: "Go?", options: ["yes"], relay: { ...RELAY, asked: "Go?" } },
  "step limit": { id: "s1", kind: "continue", question: "The turn ran out of steps. Continue?", options: ["Continue", "Stop"] },
};

for (const [name, pq] of Object.entries(QUESTIONS)) {
  test(`${name}: the data's wait is the drawn card's`, () => {
    const { cards, placed, arrived } = drawn();
    cards.renderQuestion(pq);
    const card = placed.at(-1);
    const wait = questionWait(pq);
    assert.equal(wait.kind, waitingKind(card));
    assert.equal(wait.approval, isApprovalCard(card));
    assert.equal(wait.summary, domText(card));
    assert.deepEqual(arrived, [{ key: questionKey(pq.id), info: wait }], "told the stage right before the place");
  });
}

test("the continue offer: kind continue, no summary, as its card", () => {
  const { cards, placed, arrived } = drawn();
  cards.renderContinue({ context: { original_prompt: "do it" } });
  const card = placed.at(-1);
  assert.equal(continueWait().kind, waitingKind(card));
  assert.equal(continueWait().summary, domText(card));
  assert.deepEqual(arrived, [{ key: CONTINUE_KEY, info: continueWait() }]);
});

const PLUGIN = {
  "asking card (check-in)": { id: "ci", in_turn: true, title: "check-in", body: "Still on it?", actions: [{ label: "Nudge", command: "/nudge" }] },
  "warn card": { id: "w1", in_turn: true, level: "warn", title: "Careful", body: "A long warning\nover lines." },
  "warn card with actions, between turns": { id: "w2", level: "warn", title: "Heads up", body: "b", actions: [{ label: "Go", command: "/go" }] },
  "asking warn card (asks first)": { id: "w3", in_turn: true, level: "warn", title: "Stop?", body: "b", actions: [{ label: "Stop", command: "/stop" }] },
  "info card": { id: "i1", in_turn: true, title: "Info", body: "A body\nof two lines." },
  "card without a title": { id: "i2", in_turn: true, level: "warn", body: "b\nc" },
};

for (const [name, card] of Object.entries(PLUGIN)) {
  test(`${name}: the data's wait is the drawn card's`, () => {
    const el = drawCard(document.createElement("div"), card);
    const wait = cardWait(card);
    assert.equal(wait.kind, waitingKind(el));
    assert.equal(wait.approval, false);
    if (wait.kind) assert.equal(wait.summary, domText(el));
  });
}

test("questionText: a relayed question's own words, else the question", () => {
  assert.equal(questionText({ question: "Q" }), "Q");
  assert.equal(questionText({ question: "Q", relay: { child_id: "c", asked: "A" } }), "A");
  assert.equal(questionText({ question: "Q", relay: { child_id: "c" } }), "Q");
  assert.equal(questionText({}), "");
});

test("the cross-check warns once per key and field", () => {
  const warned = [];
  const was = console.warn;
  console.warn = (...args) => warned.push(args[0]);
  try {
    warnDiffers("kind", "q:x1", { kind: "question" }, { kind: "approval" });
    warnDiffers("kind", "q:x1", { kind: "question" }, { kind: "approval" });
    warnDiffers("summary", "q:x1", "a", "b");
  } finally {
    console.warn = was;
  }
  assert.deepEqual(warned, ["stage: waiting kind differs", "stage: waiting summary differs"]);
});
