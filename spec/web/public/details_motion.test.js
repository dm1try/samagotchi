// details_motion.js: a click on a collapsible's summary animates its height
// between open and closed; the answer fold's bubble animates the same way.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { MOTION_MS, animateHeight, canAnimate, installDetailsMotion } from "../../../lib/samagotchi/web/public/details_motion.js";

const tick = () => new Promise((r) => setTimeout(r, 0));

function collapsible(cls = "turn-work", open = true) {
  const details = document.createElement("details");
  details.className = cls;
  if (open) details.open = true;
  const summary = document.createElement("summary");
  summary.textContent = "3 steps";
  const body = document.createElement("div");
  body.textContent = "the steps";
  details.append(summary, body);
  return { details, summary, body };
}

// An element whose animate() records its keyframes and finishes at once.
function recording(el) {
  const calls = [];
  el.animate = (frames, opts) => {
    calls.push({ frames, opts });
    return { finished: Promise.resolve() };
  };
  return calls;
}

test("canAnimate: an element that can animate, unless the viewer prefers reduced motion", () => {
  const el = document.createElement("div");
  const was = window.matchMedia;
  el.animate = () => ({ finished: Promise.resolve() });
  window.matchMedia = () => ({ matches: false });
  assert.equal(canAnimate(el), true);
  window.matchMedia = () => ({ matches: true });
  assert.equal(canAnimate(el), false);
  window.matchMedia = was;
  assert.equal(canAnimate({ animate: 1 }), false);
  assert.equal(canAnimate(null), false);
});

test("animateHeight: height keyframes (a fade too), the overflow clipped meanwhile and restored", async () => {
  const el = document.createElement("div");
  document.body.append(el);
  let resolve;
  const calls = [];
  el.animate = (frames, opts) => {
    calls.push({ frames, opts });
    return { finished: new Promise((r) => { resolve = r; }) };
  };
  const p = animateHeight(el, 120, 0, { fade: true });
  assert.equal(el.style.overflow, "hidden");
  assert.deepEqual(calls[0].frames, [{ height: "120px", opacity: "1" }, { height: "0px", opacity: "0" }]);
  assert.equal(calls[0].opts.duration, MOTION_MS);
  resolve();
  await p;
  assert.equal(el.style.overflow, "");
  const p2 = animateHeight(el, 0, 40);
  assert.deepEqual(calls[1].frames, [{ height: "0px" }, { height: "40px" }]);
  resolve();
  await p2;
  el.remove();
});

test("a summary click animates the block closed, then open; nothing else's summary; a second click mid-motion is dropped", async () => {
  const root = document.createElement("div");
  document.body.append(root);
  const { details, summary } = collapsible();
  const other = collapsible("gen");
  root.append(details, other.details);
  const calls = recording(details);
  installDetailsMotion({ root, selector: ".turn-work, .bubble.recap", motion: (el) => typeof el.animate === "function" && el.animate.length === 2 });
  summary.click();
  assert.equal(calls.length, 1, "closing animates");
  assert.equal(details.open, true, "still open while the motion runs");
  summary.click();
  assert.equal(calls.length, 1, "a click mid-motion does nothing");
  await tick();
  assert.equal(details.open, false, "closed once the motion is over");
  summary.click();
  assert.equal(details.open, true, "opening opens at once, then animates");
  assert.equal(calls.length, 2);
  await tick();
  other.summary.click();
  assert.equal(other.details.open, false, "a summary outside the selector keeps the native toggle");
  assert.equal(calls.length, 2);
  root.remove();
});

test("a viewer without motion gets the native toggle (no animate call, no preventDefault)", () => {
  const root = document.createElement("div");
  document.body.append(root);
  const { details, summary } = collapsible();
  root.append(details);
  const calls = recording(details);
  installDetailsMotion({ root, selector: ".turn-work", motion: () => false });
  let prevented = null;
  root.addEventListener("click", (e) => { prevented = e.defaultPrevented; });
  summary.click();
  assert.equal(calls.length, 0);
  assert.equal(prevented, false);
  root.remove();
});
