import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createObjectivesStrip } from "../../../lib/samagotchi/web/public/objectives_strip.js";

const view = (over = {}) => ({ pending: false, items: [
  { id: "O1", text: "Two coffees", status: "done" }, { id: "O2", text: "Stops before checkout", status: "active" },
  { id: "O3", text: "Dropped one", status: "dropped" },
], ...over });

function strip() {
  const el = document.createElement("div");
  el.hidden = true;
  return { el, control: createObjectivesStrip({ el }) };
}

test("no list: the strip stays hidden and empty", () => {
  const { el, control } = strip();
  control.seed(undefined);
  assert.equal(el.hidden, true);
  assert.equal(el.querySelectorAll(".obj-chip").length, 0);
});

test("a list shows active first, without the dropped one, with its count, and an update redraws", () => {
  const { el, control } = strip();
  control.seed(view());
  assert.equal(el.hidden, false);
  assert.deepEqual([...el.querySelectorAll(".obj-chip .obj-id")].map((n) => n.textContent), ["O2", "O1"]);
  assert.equal(el.querySelector(".obj-count").textContent, "1/2");
  control.update(view({ items: [{ id: "O1", text: "Two coffees", status: "done" }] }));
  assert.equal(el.querySelector(".obj-count").textContent, "1/1");
  control.reset();
  assert.equal(el.hidden, true);
});
