import test from "node:test";
import assert from "node:assert/strict";
import { createLiveTurn } from "../../../lib/samagotchi/web/public/live_turn.js";

function setup() {
  const timers = new Map();
  let next = 1;
  const page = { timing: { turnRecords: [], activeTurn: null }, timers };
  const liveTurn = createLiveTurn({
    timing: () => page.timing,
    place: () => false,
    makeLine: () => ({ textContent: "", className: "", classList: { remove() {} } }),
    now: () => Date.parse("2026-10-06T10:00:00.000Z"),
    every: (fn) => { const id = next++; timers.set(id, fn); return id; },
    cancel: (id) => timers.delete(id),
  });
  return { liveTurn, page };
}

test("a new live turn: nothing runs, no flags, no wait, a settled turn-end read", async () => {
  const { liveTurn } = setup();
  assert.equal(liveTurn.running, false);
  assert.equal(liveTurn.unmatchedMerge, false);
  assert.equal(liveTurn.wakeStart, false);
  assert.equal(liveTurn.displayPending, null);
  assert.equal(liveTurn.failedText, null);
  assert.equal(await liveTurn.endRead, undefined);
  assert.equal(liveTurn.timing.el, null);
});

test("releaseDisplay finishes the answer_display wait once", () => {
  const { liveTurn } = setup();
  let finished = 0;
  liveTurn.displayPending = { finish: () => { finished += 1; } };
  liveTurn.releaseDisplay();
  liveTurn.releaseDisplay();
  assert.equal(finished, 1);
  assert.equal(liveTurn.displayPending, null);
});

test("forget: the timing line and its turn id, the merge flags and the display wait go; running and the turn count stay", () => {
  const { liveTurn, page } = setup();
  let finished = false;
  liveTurn.running = true;
  liveTurn.timing.ended = 4;
  liveTurn.timing.start("2026-10-06T10:00:00.000Z", "T5");
  liveTurn.unmatchedMerge = "report";
  liveTurn.wakeStart = true;
  liveTurn.displayPending = { finish: () => { finished = true; } };
  liveTurn.forget();
  assert.equal(liveTurn.timing.el, null);
  assert.equal(liveTurn.timing.turnId, null);
  assert.equal(page.timers.size, 0);
  assert.equal(liveTurn.unmatchedMerge, false);
  assert.equal(liveTurn.wakeStart, false);
  assert.equal(finished, true);
  assert.equal(liveTurn.displayPending, null);
  // setTurnRunning (app.js) owns these.
  assert.equal(liveTurn.running, true);
  assert.equal(liveTurn.timing.ended, 4);
});
