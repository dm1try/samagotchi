import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { drawCommandBubble, keptCommandBubbles, restoreCommandBubbles } from "../../../lib/samagotchi/web/public/commands.js";

function bubble(view, keptFor = null) {
  const div = document.createElement("div");
  if (keptFor) div.dataset.keptFor = keptFor;
  drawCommandBubble(div, view);
  return div;
}

function userBubble(text) {
  const div = document.createElement("div");
  div.className = "bubble user";
  div.textContent = text;
  return div;
}

test("drawCommandBubble draws the line (labelled for another client) and its output, and redraws in place", () => {
  const div = bubble({ label: "tui", line: "/model x", text: "", waiting: true, commandId: "c1" });
  assert.equal(div.className, "bubble command queued");
  assert.equal(div.dataset.commandId, "c1");
  assert.equal(div.innerHTML, '<div class="command-line">tui&gt; /model x</div>');

  drawCommandBubble(div, { label: null, line: "/model x", text: "model: x", failed: true });
  assert.equal(div.className, "bubble command failed");
  assert.equal(div.innerHTML, '<div class="command-line">/model x</div><pre class="command-output">model: x</pre>');
});

test("keptCommandBubbles keeps this session's finished page-only bubbles; restoreCommandBubbles puts them back after their turn", () => {
  const history = document.createElement("div");
  const help = bubble({ label: null, line: "/help", text: "commands" }, "s1");
  const busy = bubble({ label: null, line: "/help", text: "", busy: true }, "s1");
  const other = bubble({ label: null, line: "/help", text: "x" }, "s2");
  history.append(userBubble("one"), help, busy, other, userBubble("two"));

  const kept = keptCommandBubbles(history, "s1");
  assert.deepEqual(kept.map(({ el }) => el), [help]);

  // A resync redraws the history without the page's bubbles.
  history.replaceChildren(userBubble("one"), userBubble("two"));
  history.insertAdjacentHTML("afterbegin", '<div class="hint">Loading…</div>');
  restoreCommandBubbles(history, kept);
  assert.deepEqual([...history.children].map((el) => el.className), ["bubble user", "bubble command", "bubble user"]);
});
