import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { html } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { createToasts } from "../../../lib/samagotchi/web/public/toasts.js";

function setup(t) {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const el = document.createElement("div");
  document.body.appendChild(el);
  t.after(() => el.remove());
  const changes = [];
  const toasts = createToasts({ el, onChange: () => changes.push(el.children.length) });
  return { el, toasts, changes };
}

test("each non-sticky toast has its own six-second timer", (t) => {
  const { el, toasts } = setup(t);
  toasts.show("first");
  t.mock.timers.tick(3000);
  toasts.show("second");

  assert.deepEqual([...el.querySelectorAll(".toast-message")].map((item) => item.textContent), ["first", "second"]);
  t.mock.timers.tick(3000);
  assert.deepEqual([...el.querySelectorAll(".toast-message")].map((item) => item.textContent), ["second"]);
  t.mock.timers.tick(3000);
  assert.equal(el.hidden, true);
});

test("a later toast cannot replace or time out a sticky toast", (t) => {
  const { el, toasts } = setup(t);
  toasts.show("error", null, { sticky: true });
  toasts.show("notice");
  t.mock.timers.tick(6000);

  assert.deepEqual([...el.querySelectorAll(".toast-message")].map((item) => item.textContent), ["error"]);
  assert.equal(el.querySelector(".toast-close").getAttribute("aria-label"), "Dismiss");
});

test("a repeated message reuses its toast and restarts only its timer", (t) => {
  const { el, toasts } = setup(t);
  toasts.show("same");
  const item = el.firstElementChild;
  t.mock.timers.tick(4000);
  toasts.show("same");

  assert.equal(el.children.length, 1);
  assert.equal(el.firstElementChild, item);
  t.mock.timers.tick(3000);
  assert.equal(el.children.length, 1);
  t.mock.timers.tick(3000);
  assert.equal(el.children.length, 0);
});

test("the fourth toast evicts the oldest non-sticky item, or the oldest when all are sticky", (t) => {
  const { el, toasts } = setup(t);
  toasts.show("sticky one", null, { sticky: true });
  toasts.show("timed one");
  toasts.show("sticky two", null, { sticky: true });
  toasts.show("newest", null, { sticky: true });
  assert.deepEqual([...el.querySelectorAll(".toast-message")].map((item) => item.textContent),
    ["sticky one", "sticky two", "newest"]);

  toasts.show("fourth", null, { sticky: true });
  assert.deepEqual([...el.querySelectorAll(".toast-message")].map((item) => item.textContent),
    ["sticky two", "newest", "fourth"]);
});

test("an action and a link dismiss only their own toast", (t) => {
  const { el, toasts } = setup(t);
  const actions = [];
  toasts.show("action toast", { label: "Undo", run: () => actions.push("undo") }, { sticky: true });
  toasts.show(html`<a href="/session">open session</a>`, null, { sticky: true });

  el.querySelector(".toast-action").click();
  assert.deepEqual(actions, ["undo"]);
  assert.equal(el.children.length, 1);
  el.querySelector("a[href]").click();
  assert.equal(el.hidden, true);
});

test("a sticky toast can offer multiple actions", (t) => {
  const { el, toasts } = setup(t);
  const actions = [];
  toasts.show("chi 99 is installed", [
    { label: "Restart workers", run: () => actions.push("workers") },
    { label: "Restart chi web", run: () => actions.push("web") },
  ], { sticky: true });

  assert.deepEqual([...el.querySelectorAll(".toast-action")].map((button) => button.textContent),
    ["Restart workers", "Restart chi web"]);
  el.querySelectorAll(".toast-action")[1].click();
  assert.deepEqual(actions, ["web"]);
  assert.equal(el.hidden, true);
});

test("a duplicate sticky message stays untimed when shown again", (t) => {
  const { el, toasts } = setup(t);
  toasts.show("persistent", null, { sticky: true });
  t.mock.timers.tick(6000);
  toasts.show("persistent", null, { sticky: true });
  t.mock.timers.tick(12000);
  assert.equal(el.children.length, 1);
});

test("a non-sticky duplicate does not unstick a sticky message", (t) => {
  const { el, toasts } = setup(t);
  toasts.show("persistent", null, { sticky: true });
  toasts.show("persistent");
  t.mock.timers.tick(12000);
  assert.equal(el.children.length, 1);
  assert.ok(el.querySelector(".toast-close"));
});

test("a duplicate without an action keeps the earlier toast's action", (t) => {
  const { el, toasts } = setup(t);
  toasts.show("archived", { label: "Undo", run: () => {} }, { sticky: true });
  toasts.show("archived");
  assert.equal(el.querySelector(".toast-action")?.textContent, "Undo");
});

test("a repeated words toast is drawn once, into its item: no throw-away item for the key", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const el = document.createElement("div");
  document.body.appendChild(el);
  t.after(() => el.remove());
  let made = 0;
  const doc = { createElement: (tag) => { made += 1; return document.createElement(tag); } };
  const toasts = createToasts({ el, doc });
  toasts.show("same");
  toasts.show("same");
  assert.equal(made, 1);
  assert.equal(el.children.length, 1);
  toasts.show(html`<a href="/s">link</a>`);
  toasts.show(html`<a href="/s">link</a>`);
  assert.equal(el.children.length, 2);
});

test("dismiss takes down the toast show returned, and only that one", (t) => {
  const { el, toasts } = setup(t);
  const installed = toasts.show("chi 2 is installed", null, { sticky: true });
  toasts.show("other", null, { sticky: true });
  toasts.dismiss(installed);
  toasts.dismiss(installed);
  toasts.dismiss(null);

  assert.deepEqual([...el.querySelectorAll(".toast-message")].map((item) => item.textContent), ["other"]);
  assert.equal(toasts.show("other", null, { sticky: true }).key, "other");
});
