import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { wireDiagrams } from "../../../lib/samagotchi/web/public/diagram_wiring.js";

// A window whose system theme can be changed by hand.
function themedWindow() {
  const listeners = [];
  const win = Object.create(window);
  win.matchMedia = () => ({ matches: false, addEventListener: (_type, fn) => listeners.push(fn) });
  return { win, change: () => listeners.forEach((fn) => fn()) };
}

test.afterEach(() => { document.body.innerHTML = ""; });

test("a system theme change closes the viewer; the host is made", () => {
  const { win, change } = themedWindow();
  let closed = 0;
  const pictures = { open() {}, close: () => { closed += 1; } };
  const root = document.createElement("div");
  document.body.append(root);
  const { host } = wireDiagrams({ roots: [root], sessionId: () => "s1", renderers: false, pictures, win });
  assert.equal(typeof host.scan, "function");
  change();
  assert.equal(closed, 1);
});
