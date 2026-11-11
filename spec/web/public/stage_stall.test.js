// The stage's quiet signal (stage_stall.js): the pure rule (stallOf, its
// kinds and edges, what explains a silence), the state a tick reads off
// the turn (stallState), and its drawer in happy-dom: the spans it keeps in
// the now row and the status row, patched only when their text changes.
import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

// The no-op redraw test watches the stage; the shim leaves MutationObserver
// out, so a run of this file alone needs happy-dom's here.
globalThis.MutationObserver ??= window.MutationObserver;

const { createStageStall, stallKind, stallOf, stallState, toolClockText } = await import("../../../lib/samagotchi/web/public/stage_stall.js");
const { node } = await import("../../../lib/samagotchi/web/public/stage_slots.js");

const s = (sec) => sec * 1000;

test("stallOf: kind A (streamed, or between steps) is quiet from 30 s, louder from 90 s", () => {
  assert.equal(stallOf({ kind: "A", silentMs: s(29.9) }).level, 0);
  assert.deepEqual(stallOf({ kind: "A", silentMs: s(30) }), { level: 1, long: "quiet 0:30 · no new events", short: "quiet 0:30" });
  assert.equal(stallOf({ kind: "A", silentMs: s(89.9) }).level, 1);
  assert.deepEqual(stallOf({ kind: "A", silentMs: s(90) }), { level: 2, long: "quiet 1:30 · no new events", short: "quiet 1:30" });
  assert.equal(stallOf({ kind: "A", silentMs: s(40.7) }).short, "quiet 0:40");
});

test("stallOf: kind B (no first token yet) waits longer and reads softer: 45 s, then 3 min", () => {
  assert.equal(stallOf({ kind: "B", silentMs: s(44.9) }).level, 0);
  assert.deepEqual(stallOf({ kind: "B", silentMs: s(45) }), { level: 1, long: "thinking quietly 0:45 · no tokens yet", short: "thinking quietly 0:45" });
  assert.equal(stallOf({ kind: "B", silentMs: s(179.9) }).level, 1);
  assert.deepEqual(stallOf({ kind: "B", silentMs: s(180) }), { level: 2, long: "thinking quietly 3:00 · no tokens yet", short: "thinking quietly 3:00" });
});

test("stallOf: an explained silence says nothing (a tool, a blocking card, a timing note, the end, the grace after a return)", () => {
  const long = { kind: "A", silentMs: s(600), nowMs: s(1000) };
  assert.equal(stallOf({ ...long, toolRunning: true }).level, 0);
  assert.equal(stallOf({ ...long, blocked: true }).level, 0);
  assert.equal(stallOf({ ...long, note: "retrying in 4s" }).level, 0);
  assert.equal(stallOf({ ...long, ended: true }).level, 0);
  assert.equal(stallOf({ ...long, graceUntil: s(1000) + 1 }).level, 0);
  assert.equal(stallOf({ ...long, graceUntil: s(1000) }).level, 2);
  assert.deepEqual(stallOf({ ...long, ended: true }), { level: 0, long: "", short: "" });
});

test("stallOf: a stream that is not live reads reconnecting, no count, over everything but the end", () => {
  const net = { level: "net", long: "reconnecting… · events paused", short: "reconnecting…" };
  assert.deepEqual(stallOf({ kind: "A", silentMs: 0, streamLive: false }), net);
  assert.deepEqual(stallOf({ kind: "B", silentMs: s(400), streamLive: false, toolRunning: true, blocked: true, note: "x" }), net);
  assert.equal(stallOf({ kind: "A", streamLive: false, ended: true }).level, 0);
});

test("stallKind: B until the step's first token (no gen yet, or an open one with nothing in it); else A", () => {
  const gen = (o = {}) => ({ text: "", thinking: "", tools: [], closed: false, ...o });
  assert.equal(stallKind(undefined), "B");
  assert.equal(stallKind(gen()), "B");
  assert.equal(stallKind(gen({ thinking: "Hm" })), "A");
  assert.equal(stallKind(gen({ text: "Hi" })), "A");
  assert.equal(stallKind(gen({ tools: [{ status: "ok" }] })), "A");
  // Between steps: the step closed, the next not started.
  assert.equal(stallKind(gen({ closed: true })), "A");
});

test("toolClockText: the running call's clock from 10 s, none before or without a start", () => {
  assert.equal(toolClockText(null, s(50)), "");
  assert.equal(toolClockText(s(1), s(10.9)), "");
  assert.equal(toolClockText(s(1), s(11)), "0:10");
  assert.equal(toolClockText(s(0), s(125)), "2:05");
});

function turnWith(gens) {
  return { gens: gens.map((g) => ({ text: "", thinking: "", tools: [], closed: false, startedAt: null, thinkingAt: null, ...g })) };
}

test("stallState: silence since the last event; a running tool shows its clock and no stall", () => {
  const streamed = turnWith([{ text: "Looking.", startedAt: 0 }]);
  assert.equal(stallState({ turn: streamed, lastEventAt: s(10), nowMs: s(41) }).short, "quiet 0:31");
  assert.equal(stallState({ turn: streamed, lastEventAt: s(10), nowMs: s(39) }).level, 0);
  const tool = turnWith([{ text: "Running it.", tools: [{ status: "running", startedAt: s(5) }] }]);
  const during = stallState({ turn: tool, lastEventAt: s(5), nowMs: s(125) });
  assert.equal(during.level, 0);
  assert.equal(during.toolClock, "2:00");
  // The stream down for under a second is a resync's blink: no reconnecting yet.
  assert.equal(stallState({ turn: streamed, lastEventAt: s(40), nowMs: s(41), streamDownMs: 900 }).level, 0);
  assert.equal(stallState({ turn: streamed, lastEventAt: s(40), nowMs: s(41), streamDownMs: 1000 }).level, "net");
});

test("stallState: before the first token a joiner counts from the worker's generation age (serverGen)", () => {
  // Joined 2 s ago (the replay counts as events), the generation 50 s old then.
  const joined = turnWith([{}]);
  const state = stallState({ turn: joined, lastEventAt: s(100), nowMs: s(102), serverGen: { age: 50, at: s(100) } });
  assert.equal(state.short, "thinking quietly 0:52");
  // Streamed already: kind A, the page's own silence only.
  const streamed = turnWith([{ thinking: "Hm" }]);
  assert.equal(stallState({ turn: streamed, lastEventAt: s(100), nowMs: s(102), serverGen: { age: 50, at: s(100) } }).level, 0);
});

function drawer() {
  const stage = node("section", "turn-stage");
  const status = node("div", "ts-status", stage);
  const timing = node("span", "ts-timing", status);
  node("span", "ts-mini", status);
  const now = node("div", "ts-now", stage);
  node("span", "ts-idle", now);
  node("span", "ts-title quiet", now).textContent = "thinking…";
  const stall = createStageStall({ stage, nowEl: now, timingSlot: timing });
  return { stage, status, now, stall };
}

const quiet40 = { level: 1, long: "quiet 0:40 · no new events", short: "quiet 0:40", toolClock: "" };

test("createStageStall: the stall's span right in the now row, its short text in the status row; the hooks on the stage", () => {
  const { stage, status, now, stall } = drawer();
  assert.equal(htmlOf(status), '<div class="ts-status"><span class="ts-timing"></span><span class="ts-stall-head"></span><span class="ts-mini"></span></div>');
  stall.draw(quiet40);
  assert.equal(htmlOf(now), '<div class="ts-now" data-stall="1"><span class="ts-idle"></span><span class="ts-title quiet">thinking…</span><span class="ts-stall"><span class="long">quiet 0:40 · no new events</span><span class="short">quiet 0:40</span></span></div>');
  assert.equal(status.querySelector(".ts-stall-head").textContent, "quiet 0:40");
  assert.ok(stage.classList.contains("stalled"));
  assert.equal(stage.dataset.stall, "1");
  assert.equal(stall.level(), 1);
  stall.draw({ level: 0, long: "", short: "", toolClock: "" });
  assert.equal(htmlOf(now), '<div class="ts-now"><span class="ts-idle"></span><span class="ts-title quiet">thinking…</span></div>');
  assert.equal(status.querySelector(".ts-stall-head").textContent, "");
  assert.ok(!stage.classList.contains("stalled"));
  assert.equal(stage.dataset.stall, undefined);
});

test("createStageStall: the same text draws nothing; a now row rebuilt (drawNow) gets its span back", () => {
  const { stage, now, stall } = drawer();
  stall.draw(quiet40);
  const records = [];
  const observer = new MutationObserver((list) => records.push(...list));
  observer.observe(stage, { subtree: true, childList: true, attributes: true, characterData: true });
  stall.draw({ ...quiet40 });
  assert.equal(observer.takeRecords().length + records.length, 0);
  observer.disconnect();
  now.replaceChildren();
  stall.draw({ ...quiet40 });
  assert.equal(now.querySelector(".ts-stall .short").textContent, "quiet 0:40");
});

test("createStageStall: the tool clock before a task's stop button; gone when the call ends; reset clears all", () => {
  const { stage, now, stall } = drawer();
  now.replaceChildren();
  node("span", "ts-spin", now);
  node("button", "ghost task-stop", now);
  stall.draw({ level: 0, long: "", short: "", toolClock: "0:12" });
  assert.equal(htmlOf(now), '<div class="ts-now"><span class="ts-spin"></span><span class="ts-tool-clock">0:12</span><button class="ghost task-stop"></button></div>');
  stall.draw({ level: 0, long: "", short: "", toolClock: "" });
  assert.ok(now.querySelector(".ts-tool-clock") === null);
  stall.draw({ level: "net", long: "reconnecting… · events paused", short: "reconnecting…", toolClock: "" });
  assert.equal(now.dataset.stall, "net");
  stall.reset();
  assert.ok(now.querySelector(".ts-stall") === null);
  assert.equal(stage.dataset.stall, undefined);
  assert.equal(stall.level(), 0);
});
