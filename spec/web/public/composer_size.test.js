import test from "node:test";
import assert from "node:assert/strict";
import { GRIP_FOLD_PX, GRIP_OPEN_PX, PROMPT_LINE_PX, gripFolds, gripFloor, promptHeight } from "../../../lib/samagotchi/web/public/composer_size.js";

test("short text keeps the three-line minimum", () => {
  assert.deepEqual(promptHeight({ contentPx: 30, viewportPx: 800 }), { height: 72, scrolls: false });
});

test("text grows the box up to 35% of the window, then scrolls", () => {
  assert.deepEqual(promptHeight({ contentPx: 200, viewportPx: 800 }), { height: 200, scrolls: false });
  assert.deepEqual(promptHeight({ contentPx: 900, viewportPx: 800 }), { height: 280, scrolls: true });
});

test("the grip's floor holds for short text and lifts the cap", () => {
  assert.deepEqual(promptHeight({ contentPx: 30, floorPx: 250, viewportPx: 800 }), { height: 250, scrolls: false });
  assert.deepEqual(promptHeight({ contentPx: 900, floorPx: 500, viewportPx: 800 }), { height: 500, scrolls: true });
});

test("a grip drag stays between the minimum and 50% of the window", () => {
  assert.equal(gripFloor(10, 800), 72);
  assert.equal(gripFloor(300, 800), 300);
  assert.equal(gripFloor(2000, 800), 400);
});

test("in a session the empty box is one line", () => {
  assert.deepEqual(promptHeight({ contentPx: 10, viewportPx: 800, minPx: PROMPT_LINE_PX }), { height: 26, scrolls: false });
  assert.deepEqual(promptHeight({ contentPx: 47, viewportPx: 800, minPx: PROMPT_LINE_PX }), { height: 47, scrolls: false });
});

test("in a session the grip's floor still wins over the one-line minimum", () => {
  assert.deepEqual(promptHeight({ contentPx: 26, floorPx: 120, viewportPx: 800, minPx: PROMPT_LINE_PX }), { height: 120, scrolls: false });
});

test("in a session the cap stays 35% of the window", () => {
  assert.deepEqual(promptHeight({ contentPx: 900, viewportPx: 800, minPx: PROMPT_LINE_PX }), { height: 280, scrolls: true });
});

test("in a session a grip drag can go down to one line", () => {
  assert.equal(gripFloor(10, 800, PROMPT_LINE_PX), 26);
  assert.equal(gripFloor(2000, 800, PROMPT_LINE_PX), 400);
});

test("the grip's thresholds: 32 px past the box folds, 8 px up from the handle opens", () => {
  assert.equal(GRIP_FOLD_PX, 32);
  assert.equal(GRIP_OPEN_PX, 8);
});

test("gripFolds: a drag asking 32 px or more under what the box shows folds", () => {
  assert.equal(gripFolds({ requestedPx: 26, shownPx: 58 }), true);
  assert.equal(gripFolds({ requestedPx: 26, shownPx: 57 }), false);
  assert.equal(gripFolds({ requestedPx: -40, shownPx: 26 }), true);
  assert.equal(gripFolds({ requestedPx: 200, shownPx: 26 }), false);
});

test("gripFolds: measured against the box shown, not the floor: a tall draft folds on a long pull only", () => {
  // A 150 px box (its text): the floor may be at the minimum already.
  assert.equal(gripFolds({ requestedPx: 130, shownPx: 150 }), false);
  assert.equal(gripFolds({ requestedPx: 118, shownPx: 150 }), true);
});
