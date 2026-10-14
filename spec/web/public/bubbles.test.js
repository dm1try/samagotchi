import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  createBubbles, endBubbleTemplate, guardrailWarningTemplate, hintEl, hookNoticeLine, hookNoticeTemplate, outputBubbleTemplate,
  recapTemplate, setBubbleDelivery, setBubbleState, turnPromptBubbles,
} from "../../../lib/samagotchi/web/public/bubbles.js";
import { createShownTexts } from "../../../lib/samagotchi/web/public/shown_texts.js";
import { normalize } from "../../../lib/samagotchi/web/public/format.js";

function history() {
  const el = document.createElement("div");
  document.body.append(el);
  return el;
}

// The page's wiring over a bare history: no stage, the history at its end.
function harness({ near = true, holds = false, steer = () => false } = {}) {
  const historyEl = history();
  const shownTexts = createShownTexts();
  const liveTurn = { unmatchedMerge: false, wakeStart: false, timing: { el: null } };
  const settled = [];
  const bubbles = createBubbles({
    historyEl,
    appendToHistory: (el) => historyEl.appendChild(el),
    isNearBottom: () => near,
    turnDom: { holds: () => holds, steer, settleFold: () => settled.push(true) },
    findInTurnRoots: (selector) => [...historyEl.querySelectorAll(selector)],
    shownTexts,
    liveTurn,
    selected: () => "s1",
    clientId: "me",
  });
  return { historyEl, shownTexts, liveTurn, bubbles, settled };
}

test("the bubbles' markup", () => {
  assert.equal(markupOf(outputBubbleTemplate("hi <b>")), '<div class="bubble output">hi &lt;b&gt;</div>');
  assert.equal(markupOf(endBubbleTemplate("failed")), '<div class="bubble cancel">failed</div>');
  assert.match(markupOf(endBubbleTemplate("stopped", { stopped: true })), /^<div class="[^"]*">stopped<\/div>$/);
  assert.equal(markupOf(guardrailWarningTemplate("bad.yml", "plugins")), '<div class="bubble guardrail-warning">plugins: bad.yml</div>');
  assert.equal(markupOf(recapTemplate("did things")),
               '<details open="" class="bubble recap"><summary>recap</summary><div class="recap-body">did things</div></details>');
  assert.match(markupOf(recapTemplate("did things", 2)), /class="bubble recap stale".*recap · before the last 2 turns/);
  assert.equal(hintEl("Loading…").outerHTML.replace(/<!--[^]*?-->/g, ""), '<div class="hint">Loading…</div>');
});

test("a hook notice: a bubble, or a step's row; warn, its kind's class and title", () => {
  assert.equal(markupOf(hookNoticeTemplate({ line: "x: y" })), '<div class="bubble hook-notice">x: y</div>');
  assert.equal(markupOf(hookNoticeTemplate({ line: "x", level: "warn", cls: "llm-ctx", title: "t" }, { bubble: false })),
               '<div class="hook-notice warn llm-ctx" title="t">x</div>');
  assert.equal(hookNoticeLine({ line: "own" }), "own");
  assert.match(hookNoticeLine({ hook: "after_turn", text: "hi" }), /: hi$/);
});

test("a prompt bubble's state badge and delivery", () => {
  const { bubbles } = harness();
  const b = bubbles.makeUserBubble("go", { state: "queued", own: true, delivery: "queue" });
  assert.ok(b.classList.contains("queued"));
  assert.equal(b.dataset.delivery, "queue");
  setBubbleDelivery(b, null);
  assert.equal(b.dataset.delivery, undefined);
  assert.equal(b.querySelectorAll(".state-badge").length, 1);
  setBubbleState(b, "steered");
  assert.ok(b.classList.contains("steered") && !b.classList.contains("queued"));
  setBubbleState(b, null);
  assert.equal(b.dataset.userState, undefined);
  assert.equal(b.querySelector(".state-badge"), null);
});

test("an own echo is tagged by its turn_enqueued, started by its turn_started; another client's is added", () => {
  const { historyEl, bubbles } = harness();
  historyEl.append(hintEl("No output yet. Send a message."));
  const echo = bubbles.makeUserBubble("do it", { state: "queued", own: true });
  assert.equal(historyEl.querySelector(".hint"), null);
  bubbles.applyPromptOps({ type: "turn_enqueued", enqueued_id: "e1", prompt: "do it", client_id: "me" });
  assert.equal(echo.dataset.enqueuedId, "e1");
  assert.ok(bubbles.bubbleById("e1") === echo);
  const started = bubbles.applyPromptOps({ type: "turn_started", prompt: "do it", origin: { enqueued_id: "e1", client_id: "me" } });
  assert.ok(started === echo);
  assert.ok(!echo.classList.contains("queued"));
  const other = bubbles.applyPromptOps({ type: "turn_started", prompt: "theirs", origin: { enqueued_id: "e2", client_id: "tui" } });
  assert.equal(other.dataset.enqueuedId, "e2");
  assert.equal(turnPromptBubbles(historyEl).length, 2);
});

test("a merge steers its bubble; one with no bubble draws the merged text", () => {
  const { bubbles, liveTurn, historyEl } = harness();
  bubbles.applyPromptOps({ type: "turn_enqueued", enqueued_id: "e3", prompt: "more", client_id: "tui" });
  bubbles.applyPromptOps({ type: "input_merged", origins: [{ enqueued_id: "e3" }] });
  assert.ok(bubbles.bubbleById("e3").classList.contains("steered"));
  bubbles.applyPromptOps({ type: "input_merged", origins: [{ enqueued_id: "gone" }] });
  assert.equal(liveTurn.unmatchedMerge, true);
  bubbles.applyPromptOps({ type: "pending_input_merged", content: "merged" });
  assert.equal(liveTurn.unmatchedMerge, false);
  const last = historyEl.lastElementChild;
  assert.ok(last.classList.contains("steered"));
  // A steered line isn't a turn's prompt.
  assert.equal(turnPromptBubbles(historyEl).length, 0);
});

test("an output chunk shows once, follows only a reader at the end", () => {
  const { historyEl, bubbles, shownTexts } = harness({ near: false });
  historyEl.append(hintEl("No output yet."));
  bubbles.appendChunk("hello");
  shownTexts.saw(normalize("seen"));
  bubbles.appendChunk("seen");
  bubbles.appendChunk("");
  assert.deepEqual([...historyEl.children].map((el) => el.textContent), ["hello"]);
});

test("a recap replaces the last; a stale one goes above the turns it doesn't cover; a turn marks it earlier", () => {
  const { historyEl, bubbles, settled } = harness();
  bubbles.makeUserBubble("one");
  bubbles.makeUserBubble("two");
  bubbles.showRecap("first");
  bubbles.showRecap("second", 1);
  const recaps = historyEl.querySelectorAll(".bubble.recap");
  assert.equal(recaps.length, 1);
  assert.ok(recaps[0].nextElementSibling === turnPromptBubbles(historyEl)[1]);
  assert.equal(settled.length, 2);
  bubbles.showRecap("third");
  bubbles.markRecapStale();
  assert.equal(historyEl.querySelector(".bubble.recap summary").textContent, "recap · earlier");
});

test("warnings and notices go above +before+; steers into the running turn first", () => {
  const steered = [];
  const { historyEl, bubbles } = harness({ steer: (s) => (s.text === "in turn" ? steered.push(s) : false) });
  const first = bubbles.makeUserBubble("one");
  bubbles.showGuardrailWarning("broken", "guardrails", { before: first });
  bubbles.showHookNotice({ line: "note", level: "warn" }, { before: first });
  bubbles.showGuardrailWarning(null);
  bubbles.showSteers([{ text: "in turn" }, { source: "x", text: "between" }]);
  assert.deepEqual([...historyEl.children].map((el) => el.className), [
    "bubble guardrail-warning", "bubble hook-notice warn", "bubble user", "bubble steer-row",
  ]);
  assert.equal(steered.length, 1);
});

test("command and note bubbles; a command's is kept for its session and found by id", () => {
  const { historyEl, bubbles } = harness();
  bubbles.addCommandBubble({ label: null, line: "/stats", text: "ok", commandId: "c1" });
  bubbles.addNoteBubble({ label: "parent", content: "hi" });
  const cmd = bubbles.commandBubble("c1");
  assert.equal(cmd.dataset.keptFor, "s1");
  assert.equal(bubbles.commandBubble(null), null);
  assert.ok(historyEl.lastElementChild.classList.contains("note"));
});

test("an end line scrolls to the end unless the stage holds the turn", () => {
  const { historyEl, bubbles } = harness({ holds: true });
  bubbles.addEndBubble("Canceled", { stopped: true });
  assert.equal(historyEl.children.length, 1);
});
