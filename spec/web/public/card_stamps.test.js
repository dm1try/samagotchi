import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { snapshotPlace, stampedOpening } from "../../../lib/samagotchi/web/public/card_stamps.js";
import { createCardsPlace } from "../../../lib/samagotchi/web/public/cards_place.js";
import { createBubbles } from "../../../lib/samagotchi/web/public/bubbles.js";
import { turnPromptBubbles } from "../../../lib/samagotchi/web/public/bubbles.js";

function history(markup = "") {
  const el = document.createElement("div");
  el.innerHTML = markup;
  document.body.append(el);
  return el;
}

// Two prompts, a reason line (/continue no's, no turn id) and a wake's note.
const OPENINGS = '<div class="bubble user" data-turn-id="t1">one</div><div class="bubble output">a1</div>'
  + '<div class="bubble user" data-opening-id="o1">too slow</div>'
  + '<div class="bubble user" data-turn-id="t2">two</div><div class="bubble output">a2</div>'
  + '<div class="bubble note turn-start" data-opening-id="t3">woke</div><div class="bubble output">a3</div>';

test("stampedOpening: a prompt by its turn id, a reason line or a wake note by its opening id; else -1", () => {
  const users = turnPromptBubbles(history(OPENINGS));
  assert.equal(stampedOpening(users, "t1"), 0);
  assert.equal(stampedOpening(users, "o1"), 1);
  assert.equal(stampedOpening(users, "t3"), 3);
  assert.equal(stampedOpening(users, "gone"), -1);
  assert.equal(stampedOpening(users, null), -1);
});

test("snapshotPlace: before the opening after the stamped one, null after the last; no count read", () => {
  const users = turnPromptBubbles(history(OPENINGS));
  // A count that disagrees (an older page's drift) loses to the stamp.
  assert.equal(snapshotPlace(users, { opening_id: "t1", turns_since: 0 }).textContent, "too slow");
  assert.equal(snapshotPlace(users, { opening_id: "o1", turns_since: 3 }).textContent, "two");
  assert.equal(snapshotPlace(users, { opening_id: "t3", turns_since: 2 }), null);
});

test("snapshotPlace: no stamp (an older worker), or one the page doesn't draw, counts turns_since", () => {
  const users = turnPromptBubbles(history(OPENINGS));
  assert.equal(snapshotPlace(users, { turns_since: 1 }).textContent, "woke");
  assert.equal(snapshotPlace(users, { opening_id: "gone", turns_since: 3 }).textContent, "too slow");
  assert.equal(snapshotPlace(users, { turns_since: 0 }), null);
});

test("snapshotPlace: a steered line or a failed prompt is no opening, even with an id", () => {
  const users = turnPromptBubbles(history('<div class="bubble user" data-turn-id="t1">one</div>'
    + '<div class="bubble user steered" data-turn-id="t1">more</div><div class="bubble user" data-turn-id="t2">two</div>'
    + '<div class="bubble user failed" data-turn-id="t3">failed</div>'));
  assert.equal(snapshotPlace(users, { opening_id: "t1" }).textContent, "two");
  assert.equal(snapshotPlace(users, { opening_id: "t3", turns_since: 0 }), null);
});

test("placeSnapshotCards places a stamped card by its opening: after the reason line, above the next prompt", () => {
  const h = history(OPENINGS);
  const common = { historyEl: h, appendToHistory: (el) => h.appendChild(el), isNearBottom: () => true,
    findInTurnRoots: (s) => [...h.querySelectorAll(s)], selected: () => "s1", clientId: "me" };
  const bubbles = createBubbles({ ...common, turnDom: { holds: () => false, steer: () => false }, shownTexts: { shows: () => false },
    liveTurn: { timing: { el: null } } });
  const cards = createCardsPlace({ ...common, turnDom: { card: () => false }, questionCards: null, bubbles, followWokenWorker: () => {},
    api: { getSession: async () => ({}), sendCommand: async () => ({}) } });
  cards.placeSnapshotCards([{ type: "card", id: "c1", title: "t", body: "b", opening_id: "o1", turns_since: 0 }]);
  assert.deepEqual([...h.children].map((el) => el.dataset.cardId || el.textContent),
    ["one", "a1", "too slow", "c1", "two", "a2", "woke", "a3"]);
});
