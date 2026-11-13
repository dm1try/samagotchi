// The page's viewer (viewer.js): what <body> says at boot, a show's viewer
// narrowing it, the reset, and the null-control helper.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

const { createViewer } = await import("../../../lib/samagotchi/web/public/viewer.js");

function body(attrs = {}) {
  const el = document.createElement("body");
  for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value);
  return el;
}

const owner = () => body({ "data-viewer-kind": "owner", "data-viewer-can": "sessions models  push" });

test("the stamp's names are what the viewer can do", () => {
  const viewer = createViewer(owner());
  assert.equal(viewer.kind(), "owner");
  assert.equal(viewer.can("sessions"), true);
  assert.equal(viewer.can("push"), true);
  assert.equal(viewer.can("render"), false);
  assert.equal(viewer.can(""), false);
});

test("a page with no stamp, or an empty list, can do nothing", () => {
  for (const el of [body(), body({ "data-viewer-kind": "participant", "data-viewer-can": "" })]) {
    const viewer = createViewer(el);
    assert.equal(viewer.can("sessions"), false);
  }
  assert.equal(createViewer(null).can("sessions"), false);
});

test("a show's viewer narrows the stamp, never widens it; reset goes back to the stamp", () => {
  const viewer = createViewer(owner());
  viewer.update({ kind: "owner", can: ["sessions", "render"] });
  assert.equal(viewer.can("sessions"), true);
  assert.equal(viewer.can("models"), false);
  assert.equal(viewer.can("render"), false, "not in the stamp: the boot made no control for it");
  viewer.update(null);
  viewer.update({ kind: "owner" });
  assert.equal(viewer.can("sessions"), true, "a show without a list keeps what is there");
  viewer.reset();
  assert.equal(viewer.can("models"), true);
});

test("control(): the element when allowed, else hidden and null", () => {
  const viewer = createViewer(owner());
  const allowed = document.createElement("button");
  const refused = document.createElement("button");
  assert.equal(viewer.control(allowed, "sessions"), allowed);
  assert.equal(allowed.hidden, false);
  assert.equal(viewer.control(refused, "rename"), null);
  assert.equal(refused.hidden, true);
  assert.equal(viewer.control(null, "rename"), null);
  const [a, b] = viewer.controls([document.createElement("i"), document.createElement("i")], "models");
  assert.ok(a && b);
  assert.deepEqual(viewer.controls([document.createElement("i")], "answer_cards"), [null]);
});
