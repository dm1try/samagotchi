import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { chipConcerns, moveOfRow, movesInBlock } from "../../../lib/samagotchi/web/public/objectives_moves.js";

const row = (over = {}) => ({ tool: "objectives", title: "O2 Filters carry size · merged f00ee32", output: "[objectives]\nRecorded a move on O2. The list is unchanged.", ...over });

test("a row is a move only when the call recorded one", () => {
  assert.deepEqual(moveOfRow(row()), { id: "O2", note: "Filters carry size · merged f00ee32" });
  assert.equal(moveOfRow(row({ output: "[objectives]\nError: no objective O2" })), null);
  assert.equal(moveOfRow(row({ output: "" })), null);
  assert.equal(moveOfRow(row({ tool: "read" })), null);
});

test("a block's moves are its marked rows, in order", () => {
  const block = document.createElement("div");
  block.innerHTML = '<span data-move-id="O1" data-move-note="a"></span><span class="x"></span><span data-move-id="O2" data-move-note="b"></span>';
  assert.deepEqual(movesInBlock(block), [{ id: "O1", note: "a" }, { id: "O2", note: "b" }]);
});

test("a decision card's Concerns gets a chip, once", () => {
  const body = document.createElement("div");
  body.innerHTML = "<p>The summary.</p><p><strong>Which?</strong></p><p>Concerns O2 Stops before checkout</p>";
  chipConcerns(body);
  chipConcerns(body);
  const chips = body.querySelectorAll(".obj-pill");
  assert.equal(chips.length, 1);
  assert.equal(chips[0].textContent, "O2");
  assert.equal(chips[0].parentElement.textContent, "O2 Stops before checkout");
});
