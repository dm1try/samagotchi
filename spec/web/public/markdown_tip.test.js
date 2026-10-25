import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import { TIP_DISMISSED_KEY, createMarkdownTip } from "../../../lib/samagotchi/web/public/markdown_tip.js";

const TIP = "Tip: answers can render as Markdown.";

// index.html's #markdownTip, and a localStorage the module reads at call time.
function setup() {
  if (!("localStorage" in globalThis)) globalThis.localStorage = new Window().localStorage;
  localStorage.removeItem(TIP_DISMISSED_KEY);
  const el = document.createElement("div");
  el.hidden = true;
  el.innerHTML = '<span class="markdown-tip-text"></span><button type="button" class="markdown-tip-close">×</button>';
  const tip = createMarkdownTip(el);
  const text = () => el.querySelector(".markdown-tip-text").textContent;
  const close = () => el.querySelector(".markdown-tip-close").click();
  return { el, tip, text, close };
}

// Storage that throws on every call (a private window, blocked site data).
function withBrokenStorage(fn) {
  const saved = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  const fail = () => { throw new Error("blocked"); };
  Object.defineProperty(globalThis, "localStorage", { configurable: true, value: { getItem: fail, setItem: fail, removeItem: fail } });
  try { fn(); } finally { Object.defineProperty(globalThis, "localStorage", saved); }
}

test("shows the server's text", () => {
  const { el, tip, text } = setup();
  tip.show(TIP);
  assert.equal(el.hidden, false);
  assert.equal(text(), TIP);
});

test("hides with no text (markdown on, an older server, no session)", () => {
  const { el, tip, text } = setup();
  tip.show(TIP);
  tip.show(null);
  assert.equal(el.hidden, true);
  assert.equal(text(), "");
  tip.show(undefined);
  assert.equal(el.hidden, true);
});

test("× stores the dismissal and hides; it stays hidden for later payloads", () => {
  const { el, tip, close } = setup();
  tip.show(TIP);
  close();
  assert.equal(el.hidden, true);
  assert.equal(localStorage.getItem(TIP_DISMISSED_KEY), "1");
  tip.show(TIP);
  assert.equal(el.hidden, true);
});

test("a dismissal stored earlier (a reload) keeps it hidden", () => {
  const { el, tip } = setup();
  localStorage.setItem(TIP_DISMISSED_KEY, "1");
  tip.show(TIP);
  assert.equal(el.hidden, true);
});

test("storage that throws: still shows, and × still hides", () => {
  const { el, tip, text, close } = setup();
  withBrokenStorage(() => {
    tip.show(TIP);
    assert.equal(el.hidden, false);
    assert.equal(text(), TIP);
    close();
    assert.equal(el.hidden, true);
  });
});
