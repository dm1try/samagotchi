import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { chipConcerns, createObjectivesMoves, moveOfRow, movesInBlock } from "../../../lib/samagotchi/web/public/objectives_moves.js";

globalThis.MutationObserver ??= window.MutationObserver;

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

function history(answerText, { canShorten = true, shorten = () => {} } = {}) {
  const historyEl = document.createElement("div");
  document.body.appendChild(historyEl);
  historyEl.innerHTML = '<div class="bubble output"></div><div class="revise-row"></div><div class="turn-timing"></div>';
  historyEl.querySelector(".bubble.output").textContent = answerText;
  return { historyEl, control: createObjectivesMoves({ historyEl, canShorten: () => canShorten, shorten }) };
}

test("the newest long answer offers its short version after its own rows, where it can", () => {
  let asked = 0;
  const { historyEl } = history("x".repeat(3000), { shorten: () => { asked += 1; } });
  const row = historyEl.querySelector(".obj-short");
  assert.equal(row.previousElementSibling.className, "turn-timing");
  row.querySelector("button").click();
  assert.equal(asked, 1);
  assert.equal(row.querySelector("button").disabled, true);
  assert.equal(history("short answer").historyEl.querySelector(".obj-short"), null);
  assert.equal(history("x".repeat(3000), { canShorten: false }).historyEl.querySelector(".obj-short"), null);
});

test("a failed Short version can be tapped again", async () => {
  const { historyEl } = history("x".repeat(3000), { shorten: async () => false });
  const button = historyEl.querySelector(".obj-short button");
  button.click();
  assert.equal(button.disabled, true);
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(button.disabled, false);
});

test("a failed Not yet on a move can be tapped again; a sent one stays off", async () => {
  const historyEl = document.createElement("div");
  document.body.appendChild(historyEl);
  historyEl.innerHTML = '<div class="turn-work"><span data-move-id="O1" data-move-note="a"></span></div>';
  let answer = false;
  createObjectivesMoves({ historyEl, notYet: async () => answer });
  const button = historyEl.querySelector(".obj-notyet");
  button.click();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(button.disabled, false);
  answer = true;
  button.click();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(button.disabled, true);
});
