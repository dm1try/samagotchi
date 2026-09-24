import test from "node:test";
import assert from "node:assert/strict";
import { gripFloor, promptHeight, PROMPT_MIN_PX } from "../../../lib/samagotchi/web/public/composer_size.js";

test("short text keeps the minimum height", () => {
  assert.deepEqual(promptHeight({ contentPx: 30, viewportPx: 800 }), { height: PROMPT_MIN_PX, scrolls: false });
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
  assert.equal(gripFloor(10, 800), PROMPT_MIN_PX);
  assert.equal(gripFloor(300, 800), 300);
  assert.equal(gripFloor(2000, 800), 400);
});
