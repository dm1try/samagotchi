// The stage's in-use watch (stage_watch.js) in happy-dom, on mocked timers:
// the in-use class, the quiet clock it keeps for the hand-off rule, and
// its stop.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

if (!("getSelection" in globalThis)) globalThis.getSelection = window.getSelection.bind(window);

const { createInUseWatch } = await import("../../../lib/samagotchi/web/public/stage_watch.js");

function watchOf({ due = () => false } = {}) {
  const stage = document.createElement("section");
  document.body.appendChild(stage);
  const ticks = [];
  let dues = 0;
  let watching = true;
  const watch = createInUseWatch({
    stage,
    watching: () => watching,
    onTick: (args) => {
      ticks.push(args);
      return { due: due(args), quietSinceMs: args.quietSinceMs ?? args.nowMs };
    },
    onDue: () => { dues += 1; },
  });
  return { stage, watch, ticks, dues: () => dues, stopWatching: () => { watching = false; } };
}

const mouse = (type) => Object.assign(new window.Event(type), { pointerType: "mouse" });

test("a tick marks the stage in use while the mouse is over it, and carries the quiet clock", (t) => {
  t.mock.timers.enable({ apis: ["setInterval", "Date"], now: 1000 });
  const { stage, watch, ticks } = watchOf();
  try {
    watch.start();
    stage.dispatchEvent(mouse("pointerenter"));
    t.mock.timers.tick(200);
    assert.ok(stage.classList.contains("in-use"));
    assert.equal(ticks[0].inUse, true);
    stage.dispatchEvent(mouse("pointerleave"));
    t.mock.timers.tick(200);
    assert.ok(!stage.classList.contains("in-use"));
    assert.deepEqual(ticks.map((x) => x.quietSinceMs), [null, 1200]);
  } finally {
    watch.stop();
  }
});

test("a due tick hands off; a stop forgets the quiet clock and the class", (t) => {
  t.mock.timers.enable({ apis: ["setInterval", "Date"], now: 0 });
  const { stage, watch, ticks, dues } = watchOf({ due: ({ nowMs }) => nowMs >= 600 });
  watch.start();
  for (let i = 0; i < 3; i++) t.mock.timers.tick(200);
  assert.equal(dues(), 1);
  stage.classList.add("in-use");
  watch.stop();
  assert.ok(!stage.classList.contains("in-use"));
  t.mock.timers.tick(200);
  t.mock.timers.tick(200);
  assert.equal(ticks.length, 3);
  watch.start();
  t.mock.timers.tick(200);
  assert.equal(ticks[3].quietSinceMs, null);
  watch.stop();
});

test("a tick once the stage no longer holds an ended turn stops the watch", (t) => {
  t.mock.timers.enable({ apis: ["setInterval", "Date"], now: 0 });
  const { stage, watch, ticks, stopWatching } = watchOf();
  watch.start();
  t.mock.timers.tick(200);
  stage.classList.add("in-use");
  stopWatching();
  t.mock.timers.tick(200);
  assert.ok(!stage.classList.contains("in-use"));
  t.mock.timers.tick(1000);
  assert.equal(ticks.length, 1);
});

test("a touch or wheel counts as use", (t) => {
  t.mock.timers.enable({ apis: ["setInterval", "Date"], now: 5000 });
  const { stage, watch, ticks } = watchOf();
  try {
    watch.start();
    stage.dispatchEvent(new window.Event("wheel"));
    t.mock.timers.tick(200);
    assert.equal(ticks[0].inUse, true);
  } finally {
    watch.stop();
  }
});
