// The stage's cap and frame (stage_frame.js) in happy-dom: what it
// observes and in what order, the cap it writes, the height it holds while
// the stage holds a turn and lets go of otherwise.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

globalThis.matchMedia ??= () => ({ matches: false });

const { createStageFrame } = await import("../../../lib/samagotchi/web/public/stage_frame.js");

function frameOf({ holding = true, collapsed = false, cloudOpen = false, roomCap = false } = {}) {
  const observedLog = [];
  const saved = globalThis.ResizeObserver;
  globalThis.ResizeObserver = class {
    constructor(fn) { this.fn = fn; }
    observe(el) { observedLog.push(el); }
    disconnect() {}
  };
  const el = (cls) => { const e = document.createElement("div"); e.className = cls; return e; };
  const stage = el("turn-stage");
  const parts = { scroller: el("ts-scroll"), status: el("ts-status"), cloud: el("ts-foot"), queuedSlot: el("ts-queued"), holdEl: el("ts-hold"), asking: el("ts-asking"), extras: el("ts-extras") };
  stage.append(parts.status, parts.scroller, parts.cloud, parts.queuedSlot);
  parts.scroller.append(parts.extras, parts.holdEl);
  const dockEl = el("dock");
  const centerEl = el("center");
  const composerEl = el("composer");
  const state = { holding, collapsed, cloudOpen, roomCap };
  try {
    const frame = createStageFrame({
      stage, ...parts, dockEl, centerEl, composerEl,
      observed: [parts.status, parts.extras, parts.cloud],
      isHolding: () => state.holding,
      isCollapsed: () => state.collapsed,
      isCloudOpen: () => state.cloudOpen,
      isRoomCap: () => state.roomCap,
    });
    return { frame, stage, state, observedLog, centerEl, composerEl, dockEl, ...parts };
  } finally {
    globalThis.ResizeObserver = saved;
  }
}

test("createStageFrame observes the center, the composer, then the slots, in that order", () => {
  const { observedLog, centerEl, composerEl, status, extras, cloud } = frameOf();
  assert.deepEqual(observedLog, [centerEl, composerEl, status, extras, cloud]);
});

test("fitCap writes the cap (at least 96 px) and holds the frame while the stage holds a turn", () => {
  const { frame, stage } = frameOf();
  frame.fitCap();
  assert.equal(stage.style.getPropertyValue("--stage-max"), "96px");
  assert.equal(stage.style.height, "0px");
});

test("fitCap leaves a hidden stage alone; a stage not holding a turn has a free height", () => {
  const hidden = frameOf();
  hidden.stage.hidden = true;
  hidden.frame.fitCap();
  assert.equal(hidden.stage.style.getPropertyValue("--stage-max"), "");
  const { frame, stage } = frameOf({ holding: false });
  stage.style.height = "50px";
  frame.fitCap();
  assert.equal(stage.style.height, "");
});

test("frameFree lets the height go; resetHeld and forgetContent are the stage's writes", () => {
  const { frame, stage } = frameOf();
  frame.fitCap();
  frame.resetHeld();
  frame.forgetContent();
  frame.frameFree();
  assert.equal(stage.style.height, "");
});

test("forgetContent lets a held frame shrink back to what shows (the cloud closed by hand)", (t) => {
  const { frame, stage, status, centerEl } = frameOf();
  Object.defineProperty(centerEl, "clientHeight", { configurable: true, get: () => 2000 });
  const was = Object.getOwnPropertyDescriptor(window, "innerHeight");
  let inner = 1000;
  Object.defineProperty(window, "innerHeight", { configurable: true, get: () => inner });
  t.after(() => { if (was) Object.defineProperty(window, "innerHeight", was); else delete window.innerHeight; });
  let tall = 300;
  Object.defineProperty(status, "offsetHeight", { configurable: true, get: () => tall });
  frame.fitCap();
  assert.equal(stage.style.height, "300px");
  tall = 100;
  inner = 900; // the cap moves (600 → 540 px): the frame refits
  frame.fitCap();
  assert.equal(stage.style.getPropertyValue("--stage-max"), "540px");
  assert.equal(stage.style.height, "300px", "held while the turn runs: grow-only");
  frame.forgetContent();
  assert.equal(stage.style.height, "100px");
});

test("afterGrowth runs its function two frames on when no growth eases", async () => {
  const { frame } = frameOf();
  let ran = false;
  frame.afterGrowth(() => { ran = true; });
  assert.equal(ran, false);
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 0))));
  assert.equal(ran, true);
});

// happy-dom has no layout: the page's and the panel's sizes are stubbed.
function sized(t, { center, dock = 100, inner = 1000 }) {
  const { frame, stage, state, centerEl, dockEl } = frameOf();
  Object.defineProperty(centerEl, "clientHeight", { configurable: true, get: () => center });
  Object.defineProperty(dockEl, "offsetHeight", { configurable: true, get: () => dock });
  const was = Object.getOwnPropertyDescriptor(window, "innerHeight");
  Object.defineProperty(window, "innerHeight", { configurable: true, get: () => inner });
  t.after(() => { if (was) Object.defineProperty(window, "innerHeight", was); else delete window.innerHeight; });
  const cap = () => stage.style.getPropertyValue("--stage-max");
  return { frame, state, cap };
}

test("fitCap: ~60% of the page, ~80% with the cloud open, 0.85 with the question room's cap; never above the panel", (t) => {
  // room = 2000 - (100 + 10) - 32 = 1858: the page's share is the ceiling.
  const { frame, state, cap } = sized(t, { center: 2000 });
  frame.fitCap();
  assert.equal(cap(), "600px");
  state.cloudOpen = true;
  frame.fitCap();
  assert.equal(cap(), "800px");
  state.roomCap = true;
  frame.fitCap();
  assert.equal(cap(), "850px");
  state.cloudOpen = false;
  frame.fitCap();
  assert.equal(cap(), "850px", "the room's cap wins over the cloud's either way");
});

test("fitCap: the question room's cap stays under the session panel (room = center - dock - gap - 32)", (t) => {
  // room = 900 - (100 + 10) - 32 = 758 < 850.
  const { frame, state, cap } = sized(t, { center: 900 });
  state.roomCap = true;
  frame.fitCap();
  assert.equal(cap(), "758px");
});

// A waiting card under a long asking text (happy-dom has no layout: the
// offsets are stubbed): the asking text at 100, the card from 600 to 800,
// a 400 px tall scroller. They don't fit together.
function tallAsk() {
  const f = frameOf();
  const set = (el, props) => {
    for (const [k, v] of Object.entries(props)) Object.defineProperty(el, k, { configurable: true, get: () => v });
  };
  set(f.asking, { offsetTop: 100, offsetHeight: 450 });
  set(f.extras, { offsetTop: 600, offsetHeight: 200 });
  set(f.scroller, { clientHeight: 400 });
  return f;
}

test("reveal: the card's end in sight; fromStart (the question room's arrival) reads from the asking text's top", () => {
  const { frame, scroller, extras } = tallAsk();
  frame.reveal(extras, { now: true });
  assert.equal(scroller.scrollTop, 400, "the card-end rule: 800 - 400");
  scroller.scrollTop = 0;
  frame.reveal(extras, { now: true, fromStart: true });
  assert.equal(scroller.scrollTop, 100);
});

test("fitCap's keyboard path (a smaller cap while a card waits) keeps the card-end rule", async (t) => {
  const { frame, stage, scroller, centerEl, extras } = tallAsk();
  stage.classList.add("waiting");
  let center = 2000;
  Object.defineProperty(centerEl, "clientHeight", { configurable: true, get: () => center });
  const was = Object.getOwnPropertyDescriptor(window, "innerHeight");
  Object.defineProperty(window, "innerHeight", { configurable: true, get: () => 1000 });
  t.after(() => { if (was) Object.defineProperty(window, "innerHeight", was); else delete window.innerHeight; });
  frame.fitCap();
  center = 600;
  frame.fitCap();
  await new Promise((resolve) => requestAnimationFrame(() => resolve()));
  assert.equal(scroller.scrollTop, extras.offsetTop + extras.offsetHeight - scroller.clientHeight);
});
