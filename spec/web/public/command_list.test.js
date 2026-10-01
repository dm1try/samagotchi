import test from "node:test";
import assert from "node:assert/strict";
import { createCommandList } from "../../../lib/samagotchi/web/public/command_list.js";

// Light DOM stand-ins: the list and the composer, with listeners to fire.
function stub(extra = {}) {
  const listeners = {};
  return {
    attrs: {},
    setAttribute(k, v) { this.attrs[k] = v; },
    removeAttribute(k) { delete this.attrs[k]; },
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    fire(type, e = {}) { (listeners[type] || []).forEach((fn) => fn(e)); },
    ...extra,
  };
}

const COMMANDS = [
  { name: "/help", description: "Show commands" },
  { name: "/hello", description: "Say hi", source: "greet", anytime: true },
  { name: "/stats", description: "Local", local: true },
];

function setup({ commands = COMMANDS } = {}) {
  const list = stub({ hidden: true, innerHTML: "", querySelector: () => null });
  const prompt = stub({
    value: "",
    focused: false,
    selection: null,
    setSelectionRange(a, b) { this.selection = [a, b]; },
    focus() { this.focused = true; },
  });
  let picks = 0;
  const cl = createCommandList({ list, prompt, commands: () => commands, afterPick: () => { picks += 1; } });
  const type = (text) => { prompt.value = text; prompt.fire("input"); };
  const key = (k, extra = {}) => {
    const e = { key: k, prevented: false, stopped: false, preventDefault() { this.prevented = true; }, stopPropagation() { this.stopped = true; }, ...extra };
    return { took: cl.handleKey(e), e };
  };
  return { cl, list, prompt, type, key, picks: () => picks };
}

const names = (html) => [...html.matchAll(/class="command-name">([^<]*)</g)].map((m) => m[1]);
const active = (html) => html.match(/command-option active"[^>]*data-index="(\d+)"/)?.[1];

test("typing /he lists the matching session commands, by name, the first active", () => {
  const { list, prompt, type } = setup();
  type("/he");
  assert.equal(list.hidden, false);
  assert.deepEqual(names(list.innerHTML), ["/hello", "/help"]);
  assert.equal(active(list.innerHTML), "0");
  assert.match(list.innerHTML, /<span class="command-note">greet · mid-turn too<\/span>/);
  assert.equal(prompt.attrs["aria-expanded"], "true");
  assert.equal(prompt.attrs["aria-activedescendant"], "command-option-0");
});

test("no match (or a space typed) closes it; the local terminal commands never show", () => {
  const { list, prompt, type } = setup();
  type("/st");
  assert.equal(list.hidden, true);
  type("/he");
  type("/help me");
  assert.equal(list.hidden, true);
  assert.equal(list.innerHTML, "");
  assert.equal(prompt.attrs["aria-expanded"], "false");
  assert.equal("aria-activedescendant" in prompt.attrs, false);
});

test("arrows move and wrap; the active row is kept while typing narrows the list", () => {
  const { list, type, key } = setup();
  type("/");
  assert.deepEqual(names(list.innerHTML), ["/hello", "/help"]);
  assert.equal(key("ArrowUp").took, true);
  assert.equal(active(list.innerHTML), "1");
  key("ArrowDown");
  assert.equal(active(list.innerHTML), "0");
  key("ArrowDown");
  type("/hel");
  assert.equal(active(list.innerHTML), "1", "still /help");
});

test("Tab completes the name with a space for its arguments", () => {
  const { list, prompt, type, key, picks } = setup();
  type("/hel");
  const { took, e } = key("Tab");
  assert.equal(took, true);
  assert.equal(e.prevented, true);
  assert.equal(prompt.value, "/hello ");
  assert.deepEqual(prompt.selection, [7, 7]);
  assert.equal(prompt.focused, true);
  assert.equal(picks(), 1);
  assert.equal(list.hidden, true);
});

test("Enter on a name typed in full leaves the key to send it", () => {
  const { list, prompt, type, key } = setup();
  type("/hello");
  const { took, e } = key("Enter");
  assert.equal(took, false);
  assert.equal(e.prevented, false);
  assert.equal(prompt.value, "/hello");
  assert.equal(list.hidden, true);
});

test("Escape closes without a change; a closed list takes no keys", () => {
  const { list, prompt, type, key } = setup();
  type("/he");
  const { took, e } = key("Escape");
  assert.equal(took, true);
  assert.equal(e.stopped, true);
  assert.equal(list.hidden, true);
  assert.equal(prompt.value, "/he");
  assert.equal(key("ArrowDown").took, false);
});

test("a tap on a row picks it; a blur closes", () => {
  const { list, prompt, type } = setup();
  type("/he");
  list.fire("click", { target: { closest: () => ({ dataset: { index: "1" } }) } });
  assert.equal(prompt.value, "/help ");
  type("/he");
  prompt.fire("blur");
  assert.equal(list.hidden, true);
});

test("no commands (no session, or a terminal holds it): nothing to offer", () => {
  const { list, type } = setup({ commands: [] });
  type("/he");
  assert.equal(list.hidden, true);
});
