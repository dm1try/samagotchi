import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createUnqueue, unqueueFailureText } from "../../../lib/samagotchi/web/public/unqueue.js";
import { elementOf, userBubbleTemplate } from "../../../lib/samagotchi/web/public/turn_html.js";

function failure(status, code = null, message = "boom") {
  return Object.assign(new Error(message), { status, code });
}

// A queued bubble as the page draws it, in the document.
function queuedBubble(enqueuedId = "e1", parent = document.body) {
  const el = elementOf(userBubbleTemplate({ content: "later" }, { state: "queued", own: true, enqueuedId, delivery: "queue" }));
  parent.append(el);
  return el;
}

function harness({ dequeue, draft = "", open = { id: "s1" }, copyWorks = true }) {
  const copied = [];
  const toasts = [];
  const calls = [];
  const composer = { text: draft };
  const unqueue = createUnqueue({
    sessionId: () => open.id,
    clientId: "web:t1",
    dequeue: (...args) => { calls.push(args); return dequeue(...args); },
    toast: (text, action = null, options = {}) => toasts.push(action || options.sticky ? { text, action, options } : text),
    copy: async (text) => { copied.push(text); return copyWorks; },
    putBack: (text) => {
      if (composer.text.trim()) return false;
      composer.text = text;
      return true;
    },
  });
  return { unqueue, toasts, calls, composer, copied };
}

const click = (el) => ({ target: el, stopPropagation() {} });

test("unqueueFailureText: what each refusal means for the message", () => {
  assert.equal(unqueueFailureText(failure(409, "already_started")), "Not removed: it already started");
  assert.equal(unqueueFailureText(failure(409, "not_queued")), "Not removed: it goes in at the running turn's next step");
  assert.equal(unqueueFailureText(failure(404, "unknown_enqueued_id")), "Not removed: it is already gone");
  assert.equal(unqueueFailureText(failure(503, "not_live", "no live worker for session s1")),
               "Not removed: no live worker for session s1");
});

test("a click on × posts the bubble's enqueued_id with the tab's client id; the bubble goes on 200", async () => {
  const { unqueue, calls, toasts } = harness({ dequeue: async () => ({ status: "removed", prompt: "later" }) });
  const slot = document.createElement("div");
  slot.className = "ts-queued";
  document.body.append(slot);
  const bubble = queuedBubble("e1", slot);
  const button = bubble.querySelector("button.unqueue");

  await unqueue.onClick(click(button));

  assert.deepEqual(calls, [["s1", "e1", { clientId: "web:t1" }]]);
  assert.equal(bubble.isConnected, false);
  assert.equal(slot.isConnected, false);
  assert.deepEqual(toasts, []);
});

test("removing one of several queued bubbles keeps their slot until the last goes", async () => {
  const { unqueue } = harness({ dequeue: async () => ({ status: "removed" }) });
  const slot = document.createElement("div");
  slot.className = "ts-queued";
  document.body.append(slot);
  const first = queuedBubble("e1", slot);
  const second = queuedBubble("e2", slot);

  await unqueue.onClick(click(first.querySelector("button.unqueue")));
  assert.ok(slot.isConnected);
  assert.equal(slot.childElementCount, 1);

  await unqueue.onClick(click(second.querySelector("button.unqueue")));
  assert.equal(slot.isConnected, false);
});

test("a refused removal keeps the bubble, enables the button again and says why", async () => {
  const { unqueue, toasts } = harness({ dequeue: async () => { throw failure(409, "already_started"); } });
  const bubble = queuedBubble("e2");
  const button = bubble.querySelector("button.unqueue");

  const pending = unqueue.onClick(click(button));
  assert.equal(button.disabled, true);
  await pending;

  assert.equal(bubble.isConnected, true);
  assert.equal(button.disabled, false);
  assert.deepEqual(toasts, ["Not removed: it already started"]);
  bubble.remove();
});

test("a click anywhere else, or on a bubble with no enqueued_id yet, posts nothing", async () => {
  const { unqueue, calls } = harness({ dequeue: async () => ({}) });
  const bubble = queuedBubble(null);
  await unqueue.onClick(click(bubble.querySelector("button.unqueue")));
  await unqueue.onClick(click(bubble));
  assert.deepEqual(calls, []);
  bubble.remove();
});

test("edit: the removed text goes back into an empty composer, to change and send again", async () => {
  const { unqueue, composer, toasts } = harness({ dequeue: async () => ({ status: "removed", prompt: "fix the tests" }) });
  const bubble = queuedBubble("e3");
  await unqueue.onClick(click(bubble.querySelector("button.unqueue")));
  assert.equal(composer.text, "fix the tests");
  assert.deepEqual(toasts, []);
});

test("edit: a draft in the composer stays; the removed text is in the toast", async () => {
  const { unqueue, composer, toasts } = harness({ dequeue: async () => ({ status: "removed", prompt: "fix the tests" }), draft: "my draft" });
  const bubble = queuedBubble("e4");
  await unqueue.onClick(click(bubble.querySelector("button.unqueue")));
  assert.equal(composer.text, "my draft");
  assert.deepEqual(toasts, ["Removed (your draft stays): fix the tests"]);
});

test("a switch to another session before the 200: the removed text stays out of its composer, in a toast naming the session", async () => {
  const open = { id: "s1aaaaaaaaaa" };
  let answer;
  const { unqueue, composer, toasts } = harness({ dequeue: () => new Promise((resolve) => { answer = resolve; }), open });
  const bubble = queuedBubble("e5");
  const pending = unqueue.onClick(click(bubble.querySelector("button.unqueue")));
  open.id = "s2bbbbbbbbbb";
  answer({ status: "removed", prompt: "fix the tests" });
  await pending;
  assert.equal(composer.text, "");
  assert.equal(toasts.length, 1);
  assert.equal(toasts[0].text, "Removed from s1aaaaaa: fix the tests");
  // Sticky (the text is nowhere else); Copy takes the whole text, unclipped.
  assert.deepEqual(toasts[0].options, { sticky: true });
  assert.equal(toasts[0].action.label, "Copy");
});

test("after a switch: Copy copies the full removed text; a failed copy shows it again", async () => {
  const long = "x".repeat(300);
  for (const copyWorks of [true, false]) {
    const open = { id: "s1aaaaaaaaaa" };
    let answer;
    const { unqueue, toasts, copied } = harness({ dequeue: () => new Promise((resolve) => { answer = resolve; }), open, copyWorks });
    const pending = unqueue.onClick(click(queuedBubble("e6").querySelector("button.unqueue")));
    open.id = "s2bbbbbbbbbb";
    answer({ status: "removed", prompt: long });
    await pending;
    assert.ok(toasts[0].text.endsWith("\u2026"));
    await toasts[0].action.run();
    assert.deepEqual(copied, [long]);
    if (copyWorks) assert.deepEqual(toasts.slice(1), ["Copied"]);
    else assert.deepEqual(toasts[1], toasts[0]);
  }
});
