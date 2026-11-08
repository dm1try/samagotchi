import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { recapStampPlace } from "../../../lib/samagotchi/web/public/recap_stamp.js";
import { createBubbles, turnPromptBubbles } from "../../../lib/samagotchi/web/public/bubbles.js";
import { createShownTexts } from "../../../lib/samagotchi/web/public/shown_texts.js";

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

test("recapStampPlace: before the opening after the stamped one, null after the last; the stamp wins over the count", () => {
  const users = turnPromptBubbles(history(OPENINGS));
  // A count a turn off (a rollback, a check-in) loses to the stamp.
  assert.equal(recapStampPlace(users, "t1", 0).textContent, "too slow");
  assert.equal(recapStampPlace(users, "o1", 0).textContent, "two");
  assert.equal(recapStampPlace(users, "t2", 3).textContent, "woke");
  assert.equal(recapStampPlace(users, "t3", 2), null);
});

test("recapStampPlace: no stamp (an older worker's recap), or a bubble the page doesn't draw, falls back to the count", () => {
  const users = turnPromptBubbles(history(OPENINGS));
  assert.equal(recapStampPlace(users, null, 2).textContent, "two");
  assert.equal(recapStampPlace(users, "gone", 1).textContent, "woke");
  assert.equal(recapStampPlace(users, undefined, 0), null);
});

test("showRecap places a saved recap after the turn its stamp names", () => {
  const historyEl = history();
  const bubbles = createBubbles({
    historyEl,
    appendToHistory: (el) => historyEl.appendChild(el),
    isNearBottom: () => true,
    turnDom: { holds: () => false, steer: () => false, settleFold: () => {} },
    findInTurnRoots: (selector) => [...historyEl.querySelectorAll(selector)],
    shownTexts: createShownTexts(),
    liveTurn: { unmatchedMerge: false, wakeStart: false, timing: { el: null } },
    selected: () => "s1",
    clientId: "me",
  });
  ["one", "two", "three"].forEach((text, i) => { bubbles.makeUserBubble(text).dataset.turnId = `t${i + 1}`; });
  // The count says one turn since (before "three"); the stamp says after "one".
  bubbles.showRecap("covered one", 1, null, "t1");
  const recap = historyEl.querySelector(".bubble.recap");
  assert.equal(recap.nextElementSibling, turnPromptBubbles(historyEl)[1]);
  bubbles.showRecap("no stamp", 1);
  assert.equal(historyEl.querySelector(".bubble.recap").nextElementSibling, turnPromptBubbles(historyEl)[2]);
});
