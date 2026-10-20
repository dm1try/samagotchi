import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createRename, titleLine } from "../../../lib/samagotchi/web/public/session_rename.js";

function harness({ titles = { s1: "Coordinator" } } = {}) {
  document.body.innerHTML = "";
  const bar = document.createElement("div");
  const button = document.createElement("button");
  bar.append(button);
  document.body.append(bar);
  const open = { id: "s1" };
  const sent = [];
  const rename = createRename({
    button, session: () => open.id, titleOf: (id) => titles[id] || null,
    run: (line) => { sent.push(line); return Promise.resolve(true); },
  });
  const input = () => bar.querySelector("input.rename-input");
  const key = (k) => input().dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));
  return { rename, button, input, key, sent, open };
}

test("titleLine: the text as /title, whitespace collapsed; blank clears", () => {
  assert.equal(titleLine("  Release \n day "), "/title Release day");
  assert.equal(titleLine("   "), "/title --clear");
});

test("✎ opens an input prefilled with the title in the button's place; Enter sends /title through run", () => {
  const h = harness();
  h.button.click();
  assert.equal(h.input().value, "Coordinator");
  assert.equal(h.button.hidden, true);
  h.input().value = "Release day";
  h.key("Enter");
  assert.deepEqual(h.sent, ["/title Release day"]);
  assert.equal(h.input(), null);
  assert.equal(h.button.hidden, false);
});

test("empty clears; the same title, Esc, or another session opened meanwhile sends nothing", () => {
  const h = harness();
  h.button.click();
  h.input().value = "";
  h.key("Enter");
  assert.deepEqual(h.sent, ["/title --clear"]);

  h.button.click();
  h.input().value = " Coordinator ";
  h.key("Enter");
  h.button.click();
  h.input().value = "Other";
  h.key("Escape");
  assert.equal(h.input(), null);
  assert.deepEqual(h.sent, ["/title --clear"]);

  h.button.click();
  h.open.id = "s2";
  h.rename.follow("s2");
  assert.equal(h.input(), null);
  assert.equal(h.button.hidden, false);
});

test("leaving the field saves what was typed, once; Esc then blur, or a switch, sends nothing", () => {
  const h = harness();
  h.button.click();
  h.input().value = "Typed on a phone";
  h.input().dispatchEvent(new window.Event("blur"));
  assert.deepEqual(h.sent, ["/title Typed on a phone"]);
  assert.equal(h.input(), null);

  h.button.click();
  const el = h.input();
  el.value = "Thrown away";
  h.key("Escape");
  el.dispatchEvent(new window.Event("blur"));
  assert.deepEqual(h.sent, ["/title Typed on a phone"]);

  // The page opened another session before the blur: nothing goes to it.
  h.button.click();
  h.input().value = "Meant for s1";
  h.open.id = "s2";
  h.input().dispatchEvent(new window.Event("blur"));
  assert.deepEqual(h.sent, ["/title Typed on a phone"]);
  assert.equal(h.input(), null);
});

test("an untitled session's input starts empty", () => {
  const h = harness({ titles: {} });
  h.button.click();
  assert.equal(h.input().value, "");
  h.key("Enter");
  assert.deepEqual(h.sent, []);
});
