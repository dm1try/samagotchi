import test from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import { createStripGrip } from "../../../lib/samagotchi/web/public/strip_grip.js";

// A page of its own per test (happy-dom; the grip adds listeners on its own
// element only) and a hidden state the module reads at call time.
function setup({ hidden = false } = {}) {
  const win = new Window();
  const doc = win.document;
  const gripEl = doc.createElement("div");
  gripEl.id = "stripGrip";
  doc.body.append(gripEl);
  gripEl.setPointerCapture = () => {}; // happy-dom has no pointer capture
  const state = { hidden, sets: [] };
  createStripGrip({
    gripEl,
    isHidden: () => state.hidden,
    setHidden: (h) => { state.hidden = h; state.sets.push(h); },
  });
  const pointer = (type, clientY) => {
    const e = new win.Event(type, { cancelable: true });
    Object.defineProperty(e, "clientY", { value: clientY });
    Object.defineProperty(e, "pointerId", { value: 1 });
    gripEl.dispatchEvent(e);
  };
  const key = (k) => {
    const e = new win.KeyboardEvent("keydown", { key: k, cancelable: true });
    gripEl.dispatchEvent(e);
    return e;
  };
  return { gripEl, state, pointer, key };
}

test("a tap on the grip toggles either way, without a will-toggle flicker", () => {
  const { gripEl, state, pointer } = setup();
  assert.equal(gripEl.getAttribute("aria-expanded"), "true");
  pointer("pointerdown", 300);
  assert.ok(gripEl.classList.contains("dragging"));
  pointer("pointermove", 297); // a wobble is still a tap
  assert.equal(gripEl.classList.contains("will-toggle"), false);
  pointer("pointerup", 297);
  assert.deepEqual(state.sets, [true]);
  assert.equal(gripEl.classList.contains("dragging"), false);
  assert.equal(gripEl.getAttribute("aria-expanded"), "false");
  pointer("pointerdown", 300);
  pointer("pointerup", 300);
  assert.deepEqual(state.sets, [true, false]);
  assert.equal(gripEl.getAttribute("aria-expanded"), "true");
});

test("a drag up past 32 px hides the strip; .will-toggle and the title promise while it would act", () => {
  const { gripEl, state, pointer } = setup();
  assert.equal(gripEl.title, "Drag up or click to hide the latest sessions");
  pointer("pointerdown", 400);
  pointer("pointermove", 385); // 15 px: a drag, but short of the threshold
  assert.equal(gripEl.classList.contains("will-toggle"), false);
  pointer("pointermove", 340); // 60 px up
  assert.ok(gripEl.classList.contains("will-toggle"));
  assert.equal(gripEl.title, "Release to hide the latest sessions");
  pointer("pointerup", 340);
  assert.deepEqual(state.sets, [true]);
  assert.equal(gripEl.classList.contains("will-toggle"), false);
  assert.equal(gripEl.title, "Drag down or click to show the latest sessions");
});

test("hidden, a drag down past 8 px shows the strip; a drag up does nothing at all", () => {
  const { gripEl, state, pointer } = setup({ hidden: true });
  assert.equal(gripEl.getAttribute("aria-expanded"), "false");
  pointer("pointerdown", 300);
  pointer("pointermove", 260); // 40 px up, the wrong way
  assert.equal(gripEl.classList.contains("will-toggle"), false);
  pointer("pointerup", 260);
  assert.deepEqual(state.sets, []);
  assert.equal(state.hidden, true);
  pointer("pointerdown", 300);
  pointer("pointermove", 340);
  assert.ok(gripEl.classList.contains("will-toggle"));
  assert.equal(gripEl.title, "Release to show the latest sessions");
  pointer("pointerup", 340);
  assert.deepEqual(state.sets, [false]);
  assert.equal(gripEl.getAttribute("aria-expanded"), "true");
});

test("a cancelled drag changes nothing: not the state, not the marks", () => {
  const { gripEl, state, pointer } = setup();
  pointer("pointerdown", 400);
  pointer("pointermove", 320); // it would hide on release
  assert.ok(gripEl.classList.contains("will-toggle"));
  pointer("pointercancel", 320);
  assert.deepEqual(state.sets, []);
  assert.equal(state.hidden, false);
  assert.equal(gripEl.classList.contains("will-toggle"), false);
  assert.equal(gripEl.classList.contains("dragging"), false);
  assert.equal(gripEl.title, "Drag up or click to hide the latest sessions");
});

test("Enter and Space toggle on the focused handle; another key is left alone", () => {
  const { state, key } = setup();
  assert.equal(key("a").defaultPrevented, false);
  assert.deepEqual(state.sets, []);
  assert.equal(key("Enter").defaultPrevented, true);
  assert.deepEqual(state.sets, [true]);
  assert.equal(key(" ").defaultPrevented, true);
  assert.deepEqual(state.sets, [true, false]);
  assert.equal(key("Escape").defaultPrevented, false);
  assert.deepEqual(state.sets, [true, false]);
});
