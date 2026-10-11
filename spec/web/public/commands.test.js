import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { applyConfirm, drawCommandBubble, keptCommandBubbles, restoreCommandBubbles } from "../../../lib/samagotchi/web/public/commands.js";

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

test("drawCommandBubble draws an Apply button for this tab's own change that asks first, never for another's", () => {
  const view = { label: null, line: "/thinking low", text: "asks", own: true, confirm: "/thinking low --yes" };
  const div = bubble(view);
  const apply = div.querySelector("button[data-confirm-line]");
  assert.equal(apply.dataset.confirmLine, "/thinking low --yes");
  assert.equal(apply.textContent, "Apply (restarts the cache)");
  assert.equal(apply.className, "command-confirm");
  assert.equal(bubble({ ...view, own: false, label: "web" }).querySelector("[data-confirm-line]"), null);
  assert.equal(bubble({ ...view, confirm: null }).querySelector("[data-confirm-line]"), null);
});

test("applyConfirm sends the line once, keeps the button disabled when sent, and enables it again when not", async () => {
  const button = bubble({ label: null, line: "/thinking low", text: "asks", own: true, confirm: "/thinking low --yes" })
    .querySelector("[data-confirm-line]");
  const sent = [];
  let release;
  const pending = applyConfirm(button, (line) => { sent.push(line); return new Promise((r) => { release = r; }); });
  assert.equal(button.disabled, true);
  await applyConfirm(button, (line) => sent.push(line));
  assert.deepEqual(sent, ["/thinking low --yes"]);
  release(true);
  await pending;
  assert.equal(button.disabled, true);

  button.disabled = false;
  await applyConfirm(button, async () => false);
  assert.equal(button.disabled, false);
  await applyConfirm(button, async () => { throw new Error("network"); });
  assert.equal(button.disabled, false);
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
