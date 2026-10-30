// The history's bottom reserve and the toast's place (dock_reserve.js) over
// a page of their own: the reserve math the e2e stage.spec relies on (the
// card, the showing stage with its gap, a leaving one not counted), who
// follows (a reader at the end, at once or eased), and the toast's offset.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import { createDockReserve } from "../../../lib/samagotchi/web/public/dock_reserve.js";
import { FOLLOW_MS } from "../../../lib/samagotchi/web/public/scroll.js";
import { FOLD_MS } from "../../../lib/samagotchi/web/public/stage_view.js";
import { STAGE_GAP } from "../../../lib/samagotchi/web/public/stage_frame.js";

// happy-dom lays nothing out: each size is set by hand.
function sized(el, sizes) {
  for (const [k, v] of Object.entries(sizes)) Object.defineProperty(el, k, { configurable: true, get: () => v });
}
function boxed(el, box) {
  el.getBoundingClientRect = () => ({ top: box.top, height: box.height, bottom: box.top + box.height, left: 0, right: 0, width: 0 });
}

// The stage starts hidden. +atEnd+: the reader is at the
// history's end.
function setup({ dockH = 144, stageH = 250, atEnd = true, inSession = true, viewportH = 860 } = {}) {
  const win = new Window({ innerHeight: viewportH, innerWidth: 1280 });
  const doc = win.document;
  if (inSession) doc.body.classList.add("has-session");
  const centerEl = doc.createElement("div");
  const historyEl = doc.createElement("div");
  const dockEl = doc.createElement("div");
  const stageEl = doc.createElement("section");
  const toastEl = doc.createElement("div");
  const modelPanelEl = doc.createElement("div");
  modelPanelEl.hidden = true;
  centerEl.append(historyEl, dockEl);
  stageEl.hidden = true;
  dockEl.prepend(stageEl);
  doc.body.append(centerEl, toastEl, modelPanelEl);
  sized(dockEl, { offsetHeight: dockH });
  boxed(dockEl, { top: viewportH - dockH, height: dockH });
  if (stageEl) {
    sized(stageEl, { offsetHeight: stageH });
    boxed(stageEl, { top: viewportH - dockH - STAGE_GAP - stageH, height: stageH });
  }
  sized(toastEl, { offsetHeight: 40 });
  sized(historyEl, { scrollHeight: 2000, clientHeight: 600 });
  historyEl.scrollTop = 0;
  const eases = [];
  const reserve = createDockReserve({
    dockEl, centerEl, stageEl, historyEl, toastEl, modelPanelEl,
    atHistoryEnd: () => atEnd,
    reduce: () => false,
    ease: (el, top, opts) => { eases.push({ el, top: typeof top === "function" ? top() : top, ...opts }); },
  });
  const dockVar = () => centerEl.style.getPropertyValue("--dock-h");
  const toastVar = () => doc.documentElement.style.getPropertyValue("--toast-bottom");
  return { win, doc, centerEl, historyEl, dockEl, stageEl, modelPanelEl, reserve, eases, dockVar, toastVar };
}

test("the reserve is the composer card's height; a reader at the end jumps with it", () => {
  const { reserve, dockVar, historyEl, eases } = setup();
  reserve.updateReserve();
  assert.equal(dockVar(), "144px");
  assert.equal(historyEl.scrollTop, 2000);
  assert.deepEqual(eases, []);
});

test("a showing stage counts with its gap, and the follow eases", () => {
  const { reserve, dockVar, stageEl, historyEl, eases } = setup();
  stageEl.hidden = false;
  reserve.updateReserve({ fromStage: true });
  assert.equal(dockVar(), `${144 + 250 + STAGE_GAP}px`);
  assert.equal(historyEl.scrollTop, 0, "no jump: the stage's change eases");
  assert.equal(eases.length, 1);
  assert.equal(eases[0].el, historyEl);
  assert.equal(eases[0].top, 2000 - 600, "to the history's end");
  assert.equal(eases[0].ms, FOLLOW_MS);
  assert.equal(eases[0].reduce, false);
});

test("a hidden stage is not counted", () => {
  const { reserve, dockVar } = setup();
  reserve.updateReserve({ fromStage: true });
  assert.equal(dockVar(), "144px");
});

test("a leaving stage no longer counts: the reserve eases down over the slide", () => {
  const { reserve, dockVar, stageEl, centerEl, eases } = setup();
  stageEl.hidden = false;
  reserve.updateReserve({ fromStage: true });
  stageEl.classList.add("leaving");
  reserve.updateReserve({ fromStage: true });
  assert.equal(dockVar(), "144px");
  assert.ok(centerEl.classList.contains("reserve-easing"));
  assert.equal(eases.at(-1).ms, FOLD_MS);
  stageEl.classList.remove("leaving");
  stageEl.hidden = true;
  reserve.updateReserve({ fromStage: true });
  assert.ok(!centerEl.classList.contains("reserve-easing"));
});

test("a reader scrolled up is left where they are", () => {
  const { reserve, dockVar, historyEl, eases, stageEl } = setup({ atEnd: false });
  historyEl.scrollTop = 120;
  reserve.updateReserve();
  stageEl.hidden = false;
  reserve.updateReserve({ fromStage: true });
  assert.equal(dockVar(), `${144 + 250 + STAGE_GAP}px`);
  assert.equal(historyEl.scrollTop, 120);
  assert.deepEqual(eases, []);
});

test("an eased follow running counts as at the end, and the card's change leaves it to the ease", () => {
  const { reserve, dockVar, historyEl, eases } = setup({ atEnd: false });
  historyEl.scrollTop = 120;
  historyEl.dataset.following = "";
  reserve.updateReserve();
  assert.equal(dockVar(), "144px");
  assert.equal(historyEl.scrollTop, 120, "no jump over a running ease");
  assert.deepEqual(eases, []);
});

test("an unchanged reserve moves nothing", () => {
  const { reserve, historyEl } = setup();
  reserve.updateReserve();
  historyEl.scrollTop = 500;
  reserve.updateReserve();
  assert.equal(historyEl.scrollTop, 500);
});

test("the stage showing or hiding updates the reserve; its other classes don't", async () => {
  const { stageEl, dockVar, eases } = setup();
  stageEl.hidden = false;
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(dockVar(), `${144 + 250 + STAGE_GAP}px`);
  assert.equal(eases.length, 1);
  stageEl.classList.add("waiting");
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(eases.length, 1);
  stageEl.hidden = true;
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(dockVar(), "144px");
  assert.equal(eases.length, 2);
});

test("the toast sits 12 px above the card, or above the showing stage and the open model panel", () => {
  const { reserve, toastVar, stageEl, modelPanelEl } = setup();
  reserve.placeToast();
  assert.equal(toastVar(), `${144 + 12}px`);
  stageEl.hidden = false;
  reserve.placeToast();
  assert.equal(toastVar(), `${144 + STAGE_GAP + 250 + 12}px`);
  stageEl.hidden = true;
  modelPanelEl.hidden = false;
  boxed(modelPanelEl, { top: 860 - 144 - 300, height: 300 });
  reserve.placeToast();
  assert.equal(toastVar(), `${144 + 300 + 12}px`);
});

test("the reserve's update places the toast too", () => {
  const { reserve, toastVar } = setup();
  reserve.updateReserve();
  assert.equal(toastVar(), `${144 + 12}px`);
});

test("off a session the toast keeps the CSS's place", () => {
  const { reserve, toastVar, doc } = setup();
  reserve.placeToast();
  assert.equal(toastVar(), `${144 + 12}px`);
  doc.body.classList.remove("has-session");
  reserve.placeToast();
  assert.equal(toastVar(), "");
});
