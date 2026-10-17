import test from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import { COMPOSER_FOLD_KEY } from "../../../lib/samagotchi/web/public/composer_fold.js";
import { GRIP_KEY, createComposerGrip } from "../../../lib/samagotchi/web/public/composer_grip.js";

// A page of its own per test (the grip adds listeners on the document) and
// a localStorage the module reads at call time.
function setup({ session = "s1", saved = null } = {}) {
  if (!("localStorage" in globalThis)) globalThis.localStorage = new Window().localStorage;
  localStorage.removeItem(GRIP_KEY);
  localStorage.removeItem(COMPOSER_FOLD_KEY);
  if (saved !== null) localStorage.setItem(COMPOSER_FOLD_KEY, saved);
  const win = new Window();
  const doc = win.document;
  const el = (tag, id) => {
    const node = doc.createElement(tag);
    node.id = id;
    doc.body.append(node);
    return node;
  };
  const composeGrip = el("div", "composeGrip");
  composeGrip.title = "start title";
  composeGrip.setPointerCapture = () => {};
  const promptEl = el("textarea", "prompt");
  const state = { session, floor: null, fits: 0, added: [] };
  const grip = createComposerGrip({
    composeGrip,
    promptEl,
    infoCancelBtn: el("button", "infoCancelBtn"),
    infoBarEl: el("div", "infoBar"),
    session: () => state.session,
    fitPrompt: () => { state.fits += 1; },
    promptMinPx: () => 26,
    floor: () => state.floor,
    setFloor: (px) => { state.floor = px; },
    draft: () => !!promptEl.value.trim(),
    waiting: () => false,
    turnRunning: () => false,
    allViewOpen: () => false,
    lightboxOpen: () => false,
    imageFiles: () => [],
    addImageFiles: (files) => state.added.push(...files),
    doc,
    win,
  });
  const pointer = (type, clientY) => {
    const e = new win.Event(type, { cancelable: true });
    Object.defineProperty(e, "clientY", { value: clientY });
    Object.defineProperty(e, "pointerId", { value: 1 });
    composeGrip.dispatchEvent(e);
  };
  const folded = () => doc.body.classList.contains("composer-folded");
  return { grip, composeGrip, promptEl, doc, win, state, pointer, folded };
}

test("the start page's grip only resizes: no role, its own title, a drag saves the floor", () => {
  const { grip, composeGrip, pointer, folded, state } = setup({ session: null });
  grip.newVisit();
  assert.equal(composeGrip.getAttribute("role"), null);
  assert.equal(composeGrip.title, "start title");
  pointer("pointerdown", 300);
  pointer("pointermove", 200);
  assert.equal(state.floor, 100);
  assert.equal(composeGrip.classList.contains("will-fold"), false);
  pointer("pointerup", 200);
  assert.equal(folded(), false);
  assert.equal(localStorage.getItem(GRIP_KEY), "100");
});

test("a drag down past the box folds on release: will-fold while it would, the floor forgotten, the fold saved", () => {
  const { grip, composeGrip, pointer, folded, state } = setup();
  grip.newVisit();
  state.floor = 80;
  localStorage.setItem(GRIP_KEY, "80");
  assert.equal(composeGrip.getAttribute("aria-expanded"), "true");
  pointer("pointerdown", 100);
  pointer("pointermove", 140);
  assert.ok(composeGrip.classList.contains("will-fold"));
  assert.equal(composeGrip.title, "Release to hide the message box");
  pointer("pointerup", 140);
  assert.equal(composeGrip.classList.contains("will-fold"), false);
  assert.equal(folded(), true);
  assert.equal(state.floor, null);
  assert.equal(localStorage.getItem(GRIP_KEY), null);
  assert.equal(localStorage.getItem(COMPOSER_FOLD_KEY), "1");
  assert.equal(composeGrip.getAttribute("aria-expanded"), "false");
  assert.ok(composeGrip.classList.contains("folded"));
});

test("folded, a tap on the handle opens and focuses the box; a short wobble is still a tap", () => {
  const { grip, promptEl, pointer, folded, doc } = setup({ saved: "1" });
  grip.newVisit();
  assert.equal(folded(), true);
  pointer("pointerdown", 500);
  pointer("pointermove", 497);
  assert.equal(folded(), true);
  pointer("pointerup", 497);
  assert.equal(folded(), false);
  assert.ok(doc.activeElement === promptEl);
  assert.equal(localStorage.getItem(COMPOSER_FOLD_KEY), "0");
});

test("an archived visit opens folded once; opening it there saves nothing; a new visit forgets it", () => {
  const { grip, composeGrip, folded } = setup();
  grip.newVisit();
  grip.decideVisit(true);
  assert.equal(folded(), true);
  composeGrip.dispatchEvent(new composeGrip.ownerDocument.defaultView.KeyboardEvent("keydown", { key: "Enter", cancelable: true }));
  assert.equal(folded(), false);
  assert.equal(localStorage.getItem(COMPOSER_FOLD_KEY), null);
  grip.decideVisit(true); // decided already this visit
  assert.equal(folded(), false);
  grip.newVisit();
  grip.decideVisit(false);
  assert.equal(folded(), false);
});

test("focusPrompt: open false leaves a folded composer folded; the default opens it for the visit only", () => {
  const { grip, promptEl, folded, doc } = setup({ saved: "1" });
  grip.newVisit();
  grip.focusPrompt({ open: false });
  assert.equal(folded(), true);
  assert.ok(doc.activeElement !== promptEl);
  grip.focusPrompt();
  assert.equal(folded(), false);
  assert.ok(doc.activeElement === promptEl);
  assert.equal(localStorage.getItem(COMPOSER_FOLD_KEY), "1");
});

test("typing on the page opens a folded composer and saves the choice", () => {
  const { grip, folded, doc, win } = setup({ saved: "1" });
  grip.newVisit();
  doc.dispatchEvent(new win.KeyboardEvent("keydown", { key: "a", cancelable: true }));
  assert.equal(folded(), false);
  assert.equal(localStorage.getItem(COMPOSER_FOLD_KEY), "0");
});
