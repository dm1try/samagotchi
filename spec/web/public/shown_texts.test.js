import test from "node:test";
import assert from "node:assert/strict";
import { createShownTexts } from "../../../lib/samagotchi/web/public/shown_texts.js";

test("shownTexts: a streamed answer is shown, so turn_completed doesn't draw it again", () => {
  const shown = createShownTexts();
  shown.turnStarted();
  shown.saw("Done.");
  assert.equal(shown.shows("Done."), true);
});

test("shownTexts: an earlier turn's equal answer doesn't hide this turn's (a repeated Done.)", () => {
  const shown = createShownTexts();
  shown.saw("Done.");
  shown.turnStarted();
  assert.equal(shown.shows("Done."), false);
});

test("shownTexts: a render's bubbles count until the next turn starts", () => {
  const shown = createShownTexts();
  shown.saw("old");
  shown.seed(["hi", "", "Half an answer"]);
  assert.equal(shown.shows("Half an answer"), true);
  assert.equal(shown.shows("old"), false);
  assert.equal(shown.shows(""), false);
  shown.turnStarted();
  assert.equal(shown.shows("Half an answer"), false);
});
