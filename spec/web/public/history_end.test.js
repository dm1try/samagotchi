// The stage's one move into the history (history_end.js).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { moveToHistoryEnd } from "../../../lib/samagotchi/web/public/history_end.js";

test("moveToHistoryEnd: the pieces go to the history's end in order, the same nodes; the hint goes", () => {
  const history = document.createElement("div");
  history.innerHTML = '<div class="hint">nothing yet</div><div class="old"></div>';
  const stage = document.createElement("div");
  stage.innerHTML = '<div class="a"></div><div class="b"></div>';
  const [a, b] = stage.children;
  moveToHistoryEnd(history, [b, a]);
  assert.deepEqual([...history.children].map((el) => el.className), ["old", "b", "a"]);
  assert.ok(history.lastElementChild === a);
  assert.equal(stage.children.length, 0);
});

test("moveToHistoryEnd: +animate+ marks each arrival until its animation ends", () => {
  const history = document.createElement("div");
  const piece = document.createElement("div");
  moveToHistoryEnd(history, [piece], { animate: true });
  assert.ok(piece.classList.contains("ts-arrive"));
  piece.dispatchEvent(new window.Event("animationend"));
  assert.ok(!piece.classList.contains("ts-arrive"));
  const still = document.createElement("div");
  moveToHistoryEnd(history, [still]);
  assert.ok(!still.classList.contains("ts-arrive"));
});
