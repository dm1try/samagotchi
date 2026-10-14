// The stage's live slots (stage_slots.js) on their own, in happy-dom: the
// markup each draw writes, the nodes a redraw keeps, and reset. The same
// goldens drive the whole stage in stage_view.test.js.
import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

const { createStageSlots, node } = await import("../../../lib/samagotchi/web/public/stage_slots.js");

function slotsOf({ taskStop = null, gens = () => [] } = {}) {
  const els = {
    headline: node("div", "ts-headline"),
    asking: node("div", "ts-asking"),
    now: node("div", "ts-now"),
    trail: node("div", "ts-trail"),
    ticks: node("span", "ts-ticks"),
  };
  let changes = 0;
  const slots = createStageSlots({ ...els, taskStop, gens, onChange: () => { changes += 1; } });
  return { ...els, slots, changes: () => changes };
}

test("node: an element with its class, appended to its parent", () => {
  const parent = node("div", "");
  const el = node("span", "a b", parent);
  assert.equal(htmlOf(parent), '<div><span class="a b"></span></div>');
  assert.ok(el.parentNode === parent);
});

test("drawHeadline: narration, then thinking with its tag; the element kept, fresh only on a new key", () => {
  const { headline, slots } = slotsOf();
  slots.drawHeadline({ text: "Reading it.", thinking: false });
  assert.equal(htmlOf(headline), '<div class="ts-headline fresh">Reading it.</div>');
  headline.classList.remove("fresh");
  slots.drawHeadline({ text: "Reading it.", thinking: false });
  assert.ok(!headline.classList.contains("fresh"));
  slots.drawHeadline({ text: "Reading it.", thinking: true });
  assert.equal(htmlOf(headline), '<div class="ts-headline thinking fresh"><span class="ts-think-tag">thinking</span>Reading it.</div>');
});

test("drawNow: a running tool, a quiet word, a task_wait's stop button with its command read at the click", async () => {
  let asked = null;
  const taskStop = {
    target: (row) => row.view.task_id,
    busy: () => false,
    stop: (id, command) => { asked = [id, command]; return Promise.resolve(true); },
    watch: () => () => {},
  };
  const gens = () => [{ tools: [{ tool: "task_create", output: "task_id: t1", view: { command: "npm test" } }] }];
  const { now, slots, changes } = slotsOf({ taskStop, gens });
  slots.drawNow({ name: "execute", title: "ls", kind: "exec", command: "ls -la" }, "");
  assert.equal(htmlOf(now), '<div class="ts-now running"><span class="ts-spin"></span><span class="ts-tool exec">execute</span><span class="ts-title" title="ls -la">ls</span></div>');
  slots.drawNow(null, "thinking…");
  assert.equal(htmlOf(now), '<div class="ts-now"><span class="ts-idle"></span><span class="ts-title quiet">thinking…</span></div>');
  slots.drawNow({ name: "task_wait", title: "npm test", kind: "exec", taskId: "t1", key: "1:1" }, "");
  const btn = now.querySelector(".task-stop");
  assert.ok(btn);
  btn.click();
  assert.deepEqual(asked, ["t1", "npm test"]);
  assert.equal(changes(), 1);
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(changes(), 2);
});

test("drawNow: the same key keeps the row's nodes; a new key draws them fresh", () => {
  const { now, slots } = slotsOf();
  const tool = { name: "read", title: "a.rb", kind: "read" };
  slots.drawNow(tool, "");
  const spin = now.firstChild;
  slots.drawNow({ ...tool }, "");
  assert.ok(now.firstChild === spin);
  slots.drawNow({ ...tool, title: "b.rb" }, "");
  assert.ok(now.firstChild !== spin);
});

test("drawTrail: a live flash ahead of the toned items; an expired one is gone; none at all says so", () => {
  const { trail, slots } = slotsOf();
  const items = [{ name: "read", title: "a.rb", status: "ok" }, { name: "execute", title: "false", status: "error", command: "false; echo" }];
  slots.drawTrail(items, { kind: "info", text: "h: hi", until: Date.now() + 1000 });
  assert.equal(htmlOf(trail), '<div class="ts-trail"><span class="ts-trail-item info" title="ℹ h: hi">ℹ h: hi</span><span class="ts-trail-item" title="✓ read a.rb">✓ read a.rb</span><span class="ts-trail-item error" title="false; echo">✕ execute false</span></div>');
  slots.drawTrail(items, { kind: "info", text: "h: hi", until: Date.now() - 1 });
  assert.equal(trail.children.length, 2);
  slots.drawTrail([], null);
  assert.equal(htmlOf(trail), '<div class="ts-trail"><span class="ts-trail-item none">no tool calls yet</span></div>');
});

test("drawTicks: one per call, the nodes kept by index as the list grows and shrinks", () => {
  const { ticks, slots } = slotsOf();
  slots.drawTicks([{ kind: "read", status: "running", step: 0 }]);
  const first = ticks.firstChild;
  slots.drawTicks([{ kind: "read", status: "ok", step: 0 }, { kind: "edit", status: "running", step: 1 }]);
  assert.ok(ticks.firstChild === first);
  assert.equal(htmlOf(ticks), '<span class="ts-ticks"><span role="button" class="ts-tick read ok" data-step="0" title="step 1"></span><span role="button" class="ts-tick edit running" data-step="1" title="step 2"></span></span>');
  slots.drawTicks([{ kind: "read", status: "ok", step: 0 }]);
  assert.equal(ticks.children.length, 1);
  assert.ok(ticks.firstChild === first);
});

test("drawAsking: hidden without a text; the scroll goes to the top only at a new text", () => {
  const { asking, slots } = slotsOf();
  slots.drawAsking("");
  assert.equal(asking.hidden, true);
  slots.drawAsking("Go on?");
  assert.equal(asking.hidden, false);
  asking.scrollTop = 20;
  slots.drawAsking("Go on?");
  assert.equal(asking.scrollTop, 20);
  slots.drawAsking("Go on? Yes.");
  assert.equal(asking.scrollTop, 0);
});

test("reset: the slots empty, asking hidden, and the same values draw again", () => {
  const { headline, asking, now, trail, ticks, slots } = slotsOf();
  const draw = () => {
    slots.drawHeadline({ text: "Hi.", thinking: false });
    slots.drawAsking("Go on?");
    slots.drawNow(null, "thinking…");
    slots.drawTrail([], null);
    slots.drawTicks([{ kind: "read", status: "ok", step: 0 }]);
  };
  draw();
  slots.reset();
  for (const el of [headline, asking, now, trail, ticks]) assert.equal(el.childNodes.length, 0);
  assert.equal(asking.hidden, true);
  draw();
  assert.equal(headline.textContent, "Hi.");
  assert.equal(asking.textContent, "Go on?");
  assert.equal(now.textContent, "thinking…");
  assert.equal(trail.textContent, "no tool calls yet");
  assert.equal(ticks.children.length, 1);
});
