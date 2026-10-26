// The composer mounted on a page's markup (composer_mount.js): image chips
// (paste, drop, the image button, ×), the box's height, ↑/↓ history and the
// keys, with the page's hooks as stand-ins.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import { GRIP_KEY } from "../../../lib/samagotchi/web/public/composer_grip.js";
import { COMPOSER_FOLD_KEY } from "../../../lib/samagotchi/web/public/composer_fold.js";
import { MAX_TURN_IMAGES } from "../../../lib/samagotchi/web/public/images.js";
import { mountComposer } from "../../../lib/samagotchi/web/public/composer_mount.js";

if (!("localStorage" in globalThis)) globalThis.localStorage = new Window().localStorage;

const image = (name = "shot.png", type = "image/png") => ({ name, type, size: 10 });
const tick = () => new Promise((r) => setTimeout(r, 0));

// A fresh composer markup and window per test (the grip listens on its
// document): +entries+ the history's, +floor+ a saved grip floor.
function setup({ entries = ["first", "second"], floor = null, hooks = {}, fold = {} } = {}) {
  localStorage.removeItem(GRIP_KEY);
  localStorage.removeItem(COMPOSER_FOLD_KEY);
  if (floor !== null) localStorage.setItem(GRIP_KEY, String(floor));
  const doc = document.implementation.createHTMLDocument("composer");
  const el = (tag, parent = doc.body) => parent.appendChild(doc.createElement(tag));
  const grip = el("div");
  grip.setPointerCapture = () => {};
  const composerEl = el("div");
  const chipsEl = el("div", composerEl);
  chipsEl.hidden = true; // as the markup has it
  const prompt = el("textarea", composerEl);
  const button = el("button", composerEl);
  const attachBtn = el("button", composerEl);
  const attachInput = el("input", composerEl);
  const listeners = {};
  const win = {
    innerHeight: 800,
    addEventListener: (type, fn) => { listeners[type] = fn; },
  };
  const calls = { sent: [], toasts: [], writes: 0, revoked: [], loads: 0 };
  let n = 0;
  const composer = mountComposer({
    els: { composer: composerEl, prompt, button, chips: chipsEl, attachBtn, attachInput, grip },
    minPx: () => 26,
    toast: (text) => calls.toasts.push(text),
    onWrite: () => { calls.writes += 1; },
    loadHistory: () => {
      calls.loads += 1;
      return Promise.resolve(entries);
    },
    send: (opts) => calls.sent.push(opts),
    win,
    createObjectURL: () => `blob:${++n}`,
    revokeObjectURL: (src) => calls.revoked.push(src),
    ...hooks,
    fold: { session: () => null, doc, ...fold },
  });
  const key = (key, opts = {}) => {
    const e = new window.KeyboardEvent("keydown", { key, cancelable: true, ...opts });
    prompt.dispatchEvent(e);
    return e;
  };
  const transfer = (files) => ({ files, items: [], types: ["Files"], getData: () => "" });
  const dispatch = (target, type, props) => {
    const e = new window.Event(type, { cancelable: true });
    for (const [k, v] of Object.entries(props)) Object.defineProperty(e, k, { value: v });
    target.dispatchEvent(e);
    return e;
  };
  const chipNames = () => [...chipsEl.querySelectorAll(".chip-name")].map((c) => c.textContent);
  return { composer, composerEl, chipsEl, prompt, button, attachBtn, attachInput, calls, key, transfer, dispatch, chipNames, listeners, doc };
}

test("a pasted image becomes a chip; the text pasted with it still lands in the box", () => {
  const { composer, prompt, chipsEl, dispatch, chipNames } = setup();
  assert.equal(chipsEl.hidden, true);
  const alone = dispatch(prompt, "paste", { clipboardData: { files: [image("image.png")], items: [], getData: () => "" } });
  assert.equal(alone.defaultPrevented, true);
  const withText = dispatch(prompt, "paste", { clipboardData: { files: [image("b.png")], items: [], getData: () => "hello" } });
  assert.equal(withText.defaultPrevented, false);
  assert.deepEqual(chipNames(), ["pasted-1.png", "b.png"]);
  assert.equal(chipsEl.hidden, false);
  assert.equal(composer.chips().length, 2);
  assert.equal(composer.hasDraft(), true);
});

test("a paste with no image is the browser's", () => {
  const { prompt, dispatch, chipNames } = setup();
  const e = dispatch(prompt, "paste", { clipboardData: { files: [], items: [], getData: () => "text" } });
  assert.equal(e.defaultPrevented, false);
  assert.deepEqual(chipNames(), []);
});

test("files dropped on the composer join the chips; the drop mark comes and goes", () => {
  const { composerEl, transfer, dispatch, chipNames } = setup();
  const over = dispatch(composerEl, "dragover", { dataTransfer: transfer([]) });
  assert.equal(over.defaultPrevented, true);
  assert.ok(composerEl.classList.contains("dropping"));
  dispatch(composerEl, "drop", { dataTransfer: transfer([image("a.png"), image("notes.txt", "text/plain")]) });
  assert.equal(composerEl.classList.contains("dropping"), false);
  assert.deepEqual(chipNames(), ["a.png"]);
});

test("files left out say why in a toast; the cap counts the chips held", () => {
  const { composer, calls } = setup();
  const many = Array.from({ length: MAX_TURN_IMAGES + 1 }, (_, i) => image(`i${i}.png`));
  assert.equal(composer.addImageFiles(many), true);
  assert.equal(composer.chips().length, MAX_TURN_IMAGES);
  assert.match(calls.toasts[0], /1 file not added: at most 20 images a message/);
  assert.equal(composer.addImageFiles([image()]), false);
  assert.equal(calls.toasts.length, 2);
});

test("the image button opens the picker; its pick joins the chips and the picker is cleared", () => {
  const { attachBtn, attachInput, dispatch, chipNames } = setup();
  let opened = 0;
  attachInput.click = () => { opened += 1; };
  attachBtn.dispatchEvent(new window.Event("click"));
  assert.equal(opened, 1);
  Object.defineProperty(attachInput, "files", { value: [image("pick.png")], configurable: true });
  dispatch(attachInput, "change", {});
  assert.deepEqual(chipNames(), ["pick.png"]);
});

test("× takes a chip out and frees its preview; setChips frees only the chips it drops", () => {
  const { composer, chipsEl, calls, chipNames } = setup();
  composer.addImageFiles([image("a.png"), image("b.png"), image("c.png")]);
  chipsEl.querySelectorAll(".chip-remove")[1].dispatchEvent(new window.Event("click", { bubbles: true }));
  assert.deepEqual(chipNames(), ["a.png", "c.png"]);
  assert.deepEqual(calls.revoked, ["blob:2"]);
  const [a] = composer.chips();
  composer.setChips([a, { name: "restored.png", src: "/api/x", ref: "r1" }]);
  assert.deepEqual(chipNames(), ["a.png", "restored.png"]);
  assert.deepEqual(calls.revoked, ["blob:2", "blob:3"]);
  composer.setChips([]);
  assert.equal(chipsEl.hidden, true);
  assert.equal(composer.hasDraft(), false);
});

test("Enter sends, Alt+Enter sends queued; Shift+Enter and an IME's Enter don't; the button sends", () => {
  const { key, button, calls } = setup();
  assert.equal(key("Enter").defaultPrevented, true);
  key("Enter", { altKey: true });
  assert.equal(key("Enter", { shiftKey: true }).defaultPrevented, false);
  key("Enter", { isComposing: true });
  button.dispatchEvent(new window.Event("click"));
  assert.deepEqual(calls.sent, [{ queue: false }, { queue: true }, { queue: false }]);
});

test("the page's keys come first; Esc is the page's when it lets go of something", () => {
  let taken = true;
  let released = false;
  const { key, calls } = setup({ hooks: { keyFirst: () => taken, escape: () => released } });
  key("Enter");
  assert.deepEqual(calls.sent, []);
  taken = false;
  assert.equal(key("Escape").defaultPrevented, false);
  released = true;
  assert.equal(key("Escape").defaultPrevented, true);
});

test("↑/↓ walk the history loaded on focus; a recall is the composer's own write", async () => {
  const { prompt, key, calls } = setup();
  prompt.dispatchEvent(new window.Event("focus"));
  await tick();
  assert.equal(calls.loads, 1);
  assert.equal(key("ArrowUp").defaultPrevented, true);
  assert.equal(prompt.value, "second");
  key("ArrowUp");
  assert.equal(prompt.value, "first");
  key("ArrowDown");
  assert.equal(prompt.value, "second");
  assert.equal(calls.writes, 3);
  // With a modifier the key is the browser's.
  assert.equal(key("ArrowUp", { shiftKey: true }).defaultPrevented, false);
});

test("no history hook: ↑ is the browser's", () => {
  const { prompt, key } = setup({ hooks: { loadHistory: null } });
  prompt.dispatchEvent(new window.Event("focus"));
  assert.equal(key("ArrowUp").defaultPrevented, false);
});

test("the box's height: the page's minimum, a saved floor, and again on input and resize", () => {
  const { prompt, listeners } = setup({ floor: 120 });
  assert.equal(prompt.style.height, "120px");
  localStorage.removeItem(GRIP_KEY);
  assert.equal(typeof listeners.resize, "function");
  prompt.value = "text";
  prompt.dispatchEvent(new window.Event("input"));
  assert.equal(prompt.style.height, "120px");
  const { prompt: fresh } = setup();
  assert.equal(fresh.style.height, "26px");
  assert.equal(fresh.style.overflowY, "hidden");
});

test("typing anywhere opens a folded session composer unless the page turns it off", () => {
  for (const typeAnywhere of [true, false]) {
    localStorage.setItem(COMPOSER_FOLD_KEY, "1");
    const { composer, doc } = setup({ fold: { session: () => "s1", typeAnywhere } });
    localStorage.setItem(COMPOSER_FOLD_KEY, "1");
    composer.newVisit();
    assert.equal(composer.isComposerFolded(), true);
    doc.dispatchEvent(new window.KeyboardEvent("keydown", { key: "x", cancelable: true }));
    assert.equal(composer.isComposerFolded(), !typeAnywhere, `typeAnywhere ${typeAnywhere}`);
  }
});
