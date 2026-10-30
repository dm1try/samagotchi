// The history's one reveal hook (history_reveal.js): what hides an element
// unfolds, the element itself as it was.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { revealInHistory } from "../../../lib/samagotchi/web/public/history_reveal.js";

test("revealInHistory: every closed <details> around the element opens, not the element's own", () => {
  const history = document.createElement("div");
  history.innerHTML = '<details class="turn-work"><summary>2 steps</summary><details class="gen"><summary>step 1</summary>'
    + '<div class="activity-row"><details class="activity-diff"><summary>diff</summary><div class="line">x</div></details></div></details></details>';
  const diff = history.querySelector(".activity-diff");
  assert.ok(revealInHistory(diff) === diff);
  assert.equal(history.querySelector(".turn-work").open, true);
  assert.equal(history.querySelector(".gen").open, true);
  assert.equal(diff.open, false);
  revealInHistory(history.querySelector(".line"));
  assert.equal(diff.open, true);
});

test("revealInHistory: an element nothing hides stays as it is; none is null", () => {
  const bubble = document.createElement("div");
  assert.ok(revealInHistory(bubble) === bubble);
  assert.equal(revealInHistory(null), null);
});
