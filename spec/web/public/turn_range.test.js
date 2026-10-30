// A turn's elements (turn_range.js): from its opening up to the next one or
// a context note, over the owner's real history markup (turnHistoryNodes).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { turnElements } from "../../../lib/samagotchi/web/public/turn_range.js";
import { turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_view.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";

const thumbs = () => "";
const NOW = Date.parse("2026-10-02T00:00:00Z");

function ownerHistory(items, records) {
  const holder = document.createElement("div");
  holder.append(turnHistoryNodes(items, normalizeTiming({ turn_records: records }), { thumbs, now: NOW }));
  return holder;
}

const opening = (history, turnId) => history.querySelector(`[data-turn-id="${turnId}"]`);
const classes = (elements) => elements.map((el) => el.className);

test("turnElements: a turn's answer and timing, up to the next opening and before its gap divider", () => {
  const history = ownerHistory([
    { role: "user", content: "one", turn_id: "T1", at: "2026-10-01T10:00:00Z" },
    { role: "assistant", content: "first answer", at: "2026-10-01T10:00:05Z" },
    { role: "user", content: "two", turn_id: "T2", at: "2026-10-01T14:00:00Z" },
    { role: "assistant", content: "second answer" },
  ], [{ id: "T1", duration_ms: 5 }, { id: "T2", duration_ms: 5 }]);
  assert.ok(history.querySelector(".time-gap"));

  const first = turnElements(opening(history, "T1"));
  assert.deepEqual(classes(first), ["bubble output", "turn-timing"]);
  assert.equal(first[0].textContent, "first answer");
  assert.equal(turnElements(opening(history, "T2"))[0].textContent, "second answer");
});

test("turnElements: a context note ends the turn before it (a wake turn's note carries no turn id)", () => {
  const history = ownerHistory([
    { role: "user", content: "one", turn_id: "T1", at: "2026-10-01T10:00:00Z" },
    { role: "assistant", content: "first answer", at: "2026-10-01T10:00:05Z" },
    { role: "note", content: "c1 is done", turn_start: true, turn_id: "T2", at: "2026-10-01T14:00:00Z" },
    { role: "assistant", content: "woken answer" },
  ], [{ id: "T1", duration_ms: 5 }, { id: "T2", duration_ms: 5 }]);

  const first = turnElements(opening(history, "T1"));
  assert.deepEqual(classes(first), ["bubble output", "turn-timing"]);
  assert.ok(first.every((el) => !el.textContent.includes("woken")));
  // Without the boundary (the participant page's rule) the walk runs on.
  assert.ok(turnElements(opening(history, "T1"), { boundary: null }).some((el) => el.textContent === "woken answer"));
});

test("turnElements: an answer before any prompt (an answer-only group) is in no turn", () => {
  const history = ownerHistory([
    { role: "assistant", content: "hello" },
    { role: "user", content: "p", turn_id: "T1" },
    { role: "assistant", content: "PONG" },
  ], [{ id: "T1", duration_ms: 5 }]);

  assert.equal(history.firstElementChild.textContent, "hello");
  assert.deepEqual(turnElements(opening(history, "T1")).map((el) => el.textContent), ["PONG", "turn 1 · 5ms"]);
});

test("turnElements: an opening inside a wrapper walks at +container+'s level; one outside it has none", () => {
  const container = document.createElement("section");
  const wrap = document.createElement("div");
  const prompt = document.createElement("div");
  prompt.dataset.turnId = "T1";
  wrap.append(prompt);
  const reply = document.createElement("div");
  reply.textContent = "reply";
  const next = document.createElement("div");
  next.append(Object.assign(document.createElement("div"), { className: "x" }));
  next.firstElementChild.dataset.turnId = "T2";
  container.append(wrap, reply, next);

  assert.deepEqual(turnElements(prompt, { container }), [reply]);
  assert.deepEqual(turnElements(document.createElement("div"), { container }), []);
});
