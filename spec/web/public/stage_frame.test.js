// The stage's cap and frame (stage_frame.js) in happy-dom: what it
// observes and in what order, the cap it writes, the height it holds while
// the stage holds a turn and lets go of otherwise.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

globalThis.matchMedia ??= () => ({ matches: false });

const { createStageFrame } = await import("../../../lib/samagotchi/web/public/stage_frame.js");

function frameOf({ holding = true, collapsed = false, cloudOpen = false } = {}) {
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
  const state = { holding, collapsed, cloudOpen };
  try {
    const frame = createStageFrame({
      stage, ...parts, dockEl, centerEl, composerEl,
      observed: [parts.status, parts.extras, parts.cloud],
      isHolding: () => state.holding,
      isCollapsed: () => state.collapsed,
      isCloudOpen: () => state.cloudOpen,
    });
    return { frame, stage, state, observedLog, centerEl, composerEl, ...parts };
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

test("afterGrowth runs its function two frames on when no growth eases", async () => {
  const { frame } = frameOf();
  let ran = false;
  frame.afterGrowth(() => { ran = true; });
  assert.equal(ran, false);
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 0))));
  assert.equal(ran, true);
});
