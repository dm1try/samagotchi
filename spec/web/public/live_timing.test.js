import test from "node:test";
import assert from "node:assert/strict";
import { createLiveTiming, lineRecord, liveLineText, liveTickMs } from "../../../lib/samagotchi/web/public/live_timing.js";

const T0 = "2026-10-06T10:00:00.000Z";
const at = (ms) => Date.parse(T0) + ms;

function fakeLine() {
  const classes = new Set();
  return {
    textContent: "",
    set className(v) { classes.clear(); v.split(" ").forEach((c) => classes.add(c)); },
    get className() { return [...classes].join(" "); },
    classList: { remove: (c) => classes.delete(c), contains: (c) => classes.has(c) },
  };
}

// A live timing on a fake page: a clock, an interval list, the placed lines.
function setup({ inStage = false, records = [] } = {}) {
  const page = { now: at(0), timers: new Map(), nextTimer: 1, placed: [], ticks: 0,
    timing: { turnRecords: records, activeTurn: null } };
  const timing = createLiveTiming({
    timing: () => page.timing,
    place: (el) => { page.placed.push(el); return inStage; },
    makeLine: fakeLine,
    onTick: () => { page.ticks += 1; },
    now: () => page.now,
    every: (fn, ms) => { const id = page.nextTimer++; page.timers.set(id, { fn, ms }); return id; },
    cancel: (id) => page.timers.delete(id),
  });
  page.advance = (ms) => { page.now += ms; [...page.timers.values()].forEach(({ fn }) => fn()); };
  page.intervals = () => [...page.timers.values()].map((t) => t.ms);
  return { timing, page };
}

test("liveLineText: the running line, its stage form without 'running', a note after it; null without a start", () => {
  assert.equal(liveLineText({ number: 3, startedAt: T0 }, at(4100)), "turn 3 running · 4.1s");
  assert.equal(liveLineText({ number: 3, startedAt: T0, inStage: true }, at(4100)), "turn 3 · 4.1s");
  assert.equal(liveLineText({ number: 1, startedAt: T0, note: "↻ retrying (503) in 4 s, 2/5" }, at(1000)),
    "turn 1 running · 1.0s · ↻ retrying (503) in 4 s, 2/5");
  assert.equal(liveLineText({ number: 1, startedAt: null }, at(1000)), null);
});

test("lineRecord: by the turn's id, else the last record", () => {
  const records = [{ id: "a" }, { id: "b" }];
  assert.equal(lineRecord(records, "a"), records[0]);
  assert.equal(lineRecord(records, null), records[1]);
  assert.equal(lineRecord(records, "zzz"), undefined);
});

test("start: a live line numbered after the turns seen to end, ticking fast then every second, the active turn set", () => {
  const { timing, page } = setup();
  timing.ended = 2;
  timing.start(T0, "T3");
  assert.equal(page.placed.length, 1);
  assert.equal(timing.el, page.placed[0]);
  assert.equal(timing.el.className, "turn-timing live");
  assert.equal(timing.el.textContent, "turn 3 running · 0.0s");
  assert.deepEqual(page.timing.activeTurn, { id: "T3", started_at: T0 });
  assert.equal(timing.turnId, "T3");
  // The live line counts up from the first second: tenths while under 10 s.
  page.advance(300);
  assert.equal(timing.el.textContent, "turn 3 running · 0.3s");
  page.now = at(1500);
  page.timers.forEach(({ fn }) => fn());
  assert.equal(timing.el.textContent, "turn 3 running · 1.5s");
  page.advance(2000);
  assert.equal(timing.el.textContent, "turn 3 running · 3.5s");
  // Ticking 200 ms during the first ten seconds.
  assert.deepEqual(page.intervals(), [200]);
  page.now = at(10000);
  page.timers.forEach(({ fn }) => fn());
  assert.equal(timing.el.textContent, "turn 3 running · 10s");
  // From ten seconds on the ticker runs at one a second.
  assert.deepEqual(page.intervals(), [1000]);
  page.advance(1000);
  assert.equal(timing.el.textContent, "turn 3 running · 11s");
  page.advance(1000);
  assert.equal(timing.el.textContent, "turn 3 running · 12s");
  assert.equal(page.timers.size, 1);
});

test("start in the stage: the line drops its own 'running'", () => {
  const { timing } = setup({ inStage: true });
  timing.start(T0);
  assert.equal(timing.el.textContent, "turn 1 · 0.0s");
  assert.equal(timing.turnId, null);
});

test("liveTickMs: 200 ms during the first ten seconds, then one a second", () => {
  assert.equal(liveTickMs(0), 200);
  assert.equal(liveTickMs(9999), 200);
  assert.equal(liveTickMs(10000), 1000);
  assert.equal(liveTickMs(60000), 1000);
});

test("setNote: shown after the line until cleared; the same note again is no redraw", () => {
  const { timing, page } = setup();
  timing.start(T0);
  page.now = at(1000);
  timing.setNote("waiting for plugins");
  assert.equal(timing.el.textContent, "turn 1 running · 1.0s · waiting for plugins");
  const ticks = page.ticks;
  timing.setNote("waiting for plugins");
  assert.equal(page.ticks, ticks);
  timing.setNote("");
  assert.equal(timing.el.textContent, "turn 1 running · 1.0s");
});

test("finish: the line stops with its elapsed time (canceled says so), the ticker and the active turn go", () => {
  const { timing, page } = setup();
  timing.start(T0, "T1");
  timing.setNote("retrying");
  page.now = at(4100);
  timing.finish({ canceled: true });
  assert.equal(timing.el.textContent, "turn 1 · 4.1s · canceled");
  assert.equal(timing.el.classList.contains("live"), false);
  assert.equal(page.timing.activeTurn, null);
  assert.equal(page.timers.size, 0);
  // A later start begins without the old note.
  timing.start(T0);
  assert.equal(timing.el.textContent, "turn 1 running · 4.1s");
});

test("finishLine: the captured line takes its record's number and duration; a newer live line keeps ticking", () => {
  const records = [{ id: "T1", duration_ms: 900 }, { id: "T2", duration_ms: 3000, status: "canceled" }];
  const { timing, page } = setup({ records });
  timing.ended = 1;
  timing.start(T0, "T2");
  timing.finish();
  const line = timing.capture();
  assert.deepEqual(line, { el: timing.el, turnId: "T2" });
  // The next turn started before the read landed.
  timing.start(T0, "T3");
  timing.finishLine(line);
  assert.equal(line.el.textContent, "turn 2 · 3.0s · canceled");
  assert.equal(timing.ticking, true);
  assert.deepEqual(page.timing.activeTurn, { id: "T3", started_at: T0 });
  // The live line's own read stops it.
  timing.finishLine(timing.capture());
  assert.equal(timing.ticking, false);
  assert.equal(page.timing.activeTurn, null);
});

test("finishLine with no record leaves the line as the turn's end left it", () => {
  const { timing } = setup();
  timing.start(T0, "T9");
  timing.finish();
  const text = timing.el.textContent;
  timing.finishLine(timing.capture());
  assert.equal(timing.el.textContent, text);
});

test("detach keeps the turn id, drop forgets it; both stop the ticker and let the line go", () => {
  const { timing, page } = setup();
  timing.start(T0, "T1");
  timing.detach();
  assert.equal(timing.el, null);
  assert.equal(timing.turnId, "T1");
  assert.equal(page.timers.size, 0);
  timing.start(T0, "T2");
  timing.drop();
  assert.equal(timing.el, null);
  assert.equal(timing.turnId, null);
  assert.equal(page.timers.size, 0);
});
