import test from "node:test";
import assert from "node:assert/strict";
import { toastBottom } from "../../../lib/samagotchi/web/public/toast_place.js";

test("no session: no offset (the CSS's own bottom)", () => {
  assert.equal(toastBottom({ inSession: false, viewportHeight: 844, dockTop: 674 }), null);
});

test("in a session: above the composer card", () => {
  assert.equal(toastBottom({ inSession: true, viewportHeight: 844, dockTop: 674 }), 844 - 674 + 12);
});

test("above an open model panel (or the stage) over the card", () => {
  assert.equal(toastBottom({ inSession: true, viewportHeight: 844, dockTop: 674, tops: [525] }), 844 - 525 + 12);
  assert.equal(toastBottom({ inSession: true, viewportHeight: 844, dockTop: 674, tops: [600, 300] }), 844 - 300 + 12);
});

test("a closed panel or hidden stage (null) doesn't count", () => {
  assert.equal(toastBottom({ inSession: true, viewportHeight: 844, dockTop: 674, tops: [null, undefined] }), 844 - 674 + 12);
});

test("too little room above: stays on screen, gap from the top", () => {
  assert.equal(toastBottom({ inSession: true, viewportHeight: 500, dockTop: 400, tops: [40], toastHeight: 66 }), 500 - 66 - 12);
});
