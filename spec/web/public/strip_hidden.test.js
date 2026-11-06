// The strip hidden or shown (strip_hidden.js) over stand-in storage and a
// stand-in short-window query: the saved choice and zen mode's fallback, the
// short window's own hide (not saved), the grip's toggle through Enter.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { STRIP_HIDDEN_KEY, createStripHidden } from "../../../lib/samagotchi/web/public/strip_hidden.js";

function harness({ stored = {}, short = false } = {}) {
  const storage = { ...stored };
  const listeners = [];
  const media = { matches: short, addEventListener: (_type, fn) => listeners.push(fn) };
  const body = document.createElement("div");
  const gripEl = document.createElement("div");
  const log = [];
  const strip = createStripHidden({
    gripEl, body,
    onApply: () => log.push("apply"),
    closeFamilyPop: () => log.push("closeFamilyPop"),
    win: { matchMedia: () => media },
    storage: { read: (key) => storage[key] ?? null, write: (key, value) => { storage[key] = value; } },
  });
  const hidden = () => body.classList.contains("strip-hidden");
  const resize = (matches) => { media.matches = matches; listeners.forEach((fn) => fn()); };
  return { strip, storage, body, gripEl, log, hidden, resize };
}

test("applied at creation: shown by default, the grip says so", () => {
  const h = harness();
  assert.equal(h.hidden(), false);
  assert.equal(h.gripEl.getAttribute("aria-expanded"), "true");
  assert.deepEqual(h.log, ["apply"]);
});

test("the saved choice wins; without one, zen mode's old key starts hidden", () => {
  assert.equal(harness({ stored: { [STRIP_HIDDEN_KEY]: "1" } }).hidden(), true);
  assert.equal(harness({ stored: { [STRIP_HIDDEN_KEY]: "0", chi_zen: "1" } }).hidden(), false);
  assert.equal(harness({ stored: { chi_zen: "1" } }).hidden(), true);
  assert.equal(harness({ stored: { chi_zen: "0" } }).hidden(), false);
});

test("a hide is saved and closes the family popover; a show is saved too", () => {
  const h = harness();
  h.strip.setHidden(true);
  assert.equal(h.hidden(), true);
  assert.equal(h.storage[STRIP_HIDDEN_KEY], "1");
  assert.deepEqual(h.log, ["apply", "closeFamilyPop", "apply"]);
  h.strip.setHidden(false);
  assert.equal(h.hidden(), false);
  assert.equal(h.storage[STRIP_HIDDEN_KEY], "0");
  assert.equal(h.gripEl.getAttribute("aria-expanded"), "true");
});

test("a short window hides the strip by itself, unsaved; shown by hand it stays until the window is tall again", () => {
  const h = harness({ short: true });
  assert.equal(h.hidden(), true);
  assert.equal(h.storage[STRIP_HIDDEN_KEY], undefined);
  h.strip.setHidden(false);
  assert.equal(h.hidden(), false);
  // Tall, then short again: hidden by itself once more.
  h.resize(false);
  assert.equal(h.hidden(), false);
  h.resize(true);
  assert.equal(h.hidden(), true);
});

test("the grip's Enter toggles through the same path", () => {
  const h = harness();
  h.gripEl.dispatchEvent(new document.defaultView.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  assert.equal(h.hidden(), true);
  assert.equal(h.storage[STRIP_HIDDEN_KEY], "1");
  assert.equal(h.gripEl.getAttribute("aria-expanded"), "false");
});
