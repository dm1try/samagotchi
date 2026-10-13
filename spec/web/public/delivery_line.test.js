import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { charsText, clockText, createDeliveryControl, CUT_LABEL, deliveryLine, deliveryLineTemplate, genAge, IDLE_HINT, QUEUE_LABEL, QUEUE_NEEDS_WORKER } from "../../../lib/samagotchi/web/public/delivery_line.js";

const NOW = 1_000_000;
const thinkingGen = (seconds, extra = {}) => ({ thinking: "x".repeat(31_200), text: "", tools: [], startedAt: NOW - seconds * 1000, ...extra });

test("clockText and charsText: m:ss, h:mm:ss, k chars; blank when unknown", () => {
  assert.equal(clockText(8.9), "0:08");
  assert.equal(clockText(151), "2:31");
  assert.equal(clockText(3725), "1:02:05");
  assert.equal(clockText(null), "");
  assert.equal(charsText(812), "812 chars");
  assert.equal(charsText(31_200), "31k chars");
  assert.equal(charsText(0), "");
});

test("thinking past cut_after: its clock and size, cut in now enabled, queue offered", () => {
  const line = deliveryLine({ phase: "thinking", gen: thinkingGen(151), cutAfter: 25, now: NOW });
  assert.equal(line.text, "↳ goes in after this thinking step · 2:31 · 31k chars");
  assert.deepEqual(line.cut, { enabled: true, shown: true, reason: "", label: CUT_LABEL, short: "cut in" });
  assert.deepEqual(line.queue, { enabled: true, shown: true, label: QUEUE_LABEL, short: "queue" });
  assert.equal(line.armed, null);
});

test("thinking younger than cut_after: cut enabled (it waits), and the line says when it would land", () => {
  const line = deliveryLine({ phase: "thinking", gen: thinkingGen(8), cutAfter: 20, now: NOW });
  assert.equal(line.text, "↳ goes in after this thinking step · 0:08 · 31k chars · cuts at about 0:20 if you choose cut in now");
  assert.equal(line.cut.enabled, true);
});

test("an unknown cut_after (an older worker) still offers the cut, with no countdown", () => {
  const line = deliveryLine({ phase: "thinking", gen: thinkingGen(3), cutAfter: null, now: NOW });
  assert.equal(line.cut.enabled, true);
  assert.doesNotMatch(line.text, /cuts at/);
});

test("cut_after 0: cutting is off for the model, the cut link goes, the text says why", () => {
  const line = deliveryLine({ phase: "thinking", gen: thinkingGen(30), cutAfter: 0, now: NOW, model: "splash:qwen3.8-27b" });
  assert.equal(line.text, "↳ cutting is off for splash:qwen3.8-27b · goes in after this thinking step · 0:30 · 31k chars");
  assert.equal(line.cut.enabled, false);
  assert.equal(line.cut.shown, false);
  assert.equal(line.cut.reason, "cutting is off for splash:qwen3.8-27b");
});

test("a running tool: goes in after the call (its name and clock), cut disabled with the reason", () => {
  const line = deliveryLine({ phase: "running a tool", gen: thinkingGen(5), tool: { name: "execute", startedAt: NOW - 12_000 }, cutAfter: 25, now: NOW });
  assert.equal(line.text, "↳ goes in after this tool call (execute · 0:12)");
  assert.equal(line.cut.enabled, false);
  assert.match(line.cut.reason, /tool is running/);
  const joined = deliveryLine({ phase: "running a tool", tool: { name: "read" }, cutAfter: 25, now: NOW });
  assert.equal(joined.text, "↳ goes in after this tool call (read)");
});

test("writing (text streamed) and a waiting card: no cut", () => {
  for (const phase of ["writing", "writing the answer"]) {
    const line = deliveryLine({ phase, gen: thinkingGen(5, { text: "Here" }), cutAfter: 25, now: NOW });
    assert.equal(line.text, "↳ goes in after this answer; the turn may go on");
    assert.equal(line.cut.enabled, false);
  }
  const waiting = deliveryLine({ phase: "waiting for you", gen: thinkingGen(5), cutAfter: 25, now: NOW });
  assert.equal(waiting.text, "↳ goes in once the card above is answered");
  assert.equal(waiting.cut.enabled, false);
});

test("thinking phase before any thinking streamed (the first token's wait): goes in after this step, nothing to cut", () => {
  const line = deliveryLine({ phase: "thinking", gen: { thinking: "", text: "", tools: [], startedAt: NOW }, cutAfter: 25, now: NOW });
  assert.equal(line.text, "↳ goes in after this step");
  assert.equal(line.cut.enabled, false);
});

test("a join mid-generation: the clock from the snapshot's age as of when it came; its thinking_only false wins", () => {
  const gen = { thinking: "hm", text: "", tools: [] };
  const serverGen = { thinking_only: true, age: 40, at: NOW - 5000 };
  assert.equal(genAge(gen, serverGen, NOW), 45);
  const line = deliveryLine({ phase: "thinking", gen, serverGen, cutAfter: 25, now: NOW });
  assert.equal(line.text, "↳ goes in after this thinking step · 0:45 · 2 chars");
  assert.equal(line.cut.enabled, true);
  // A tool-call chunk the page never sees: the worker says it isn't thinking-only.
  assert.equal(deliveryLine({ phase: "thinking", gen, serverGen: { ...serverGen, thinking_only: false }, cutAfter: 25, now: NOW }).cut.enabled, false);
  // Neither clock: none shown.
  assert.equal(deliveryLine({ phase: "thinking", gen, cutAfter: 25, now: NOW }).text, "↳ goes in after this thinking step · 2 chars");
});

test("arming: the armed link is ticked and Enter sends it; a cut no longer possible disarms", () => {
  const cut = deliveryLine({ phase: "thinking", gen: thinkingGen(60), cutAfter: 25, now: NOW, armed: "cut" });
  assert.equal(cut.armed, "cut");
  assert.equal(cut.cut.label, `${CUT_LABEL} ✓`);
  assert.match(cut.text, / · Enter sends$/);
  const queue = deliveryLine({ phase: "running a tool", tool: { name: "read" }, cutAfter: 25, now: NOW, armed: "queue" });
  assert.equal(queue.armed, "queue");
  assert.equal(queue.queue.label, `${QUEUE_LABEL} ✓`);
  const gone = deliveryLine({ phase: "running a tool", tool: { name: "read" }, cutAfter: 25, now: NOW, armed: "cut" });
  assert.equal(gone.armed, null);
  assert.equal(gone.cut.label, CUT_LABEL);
  assert.doesNotMatch(gone.text, /Enter sends/);
});

test("a worker without the delivery feature: no queue link, and queue can't be armed", () => {
  const line = deliveryLine({ phase: "thinking", gen: thinkingGen(60), cutAfter: 25, now: NOW, canQueue: false, armed: "queue" });
  assert.deepEqual(line.queue, { enabled: false, shown: false, label: QUEUE_LABEL, short: "queue" });
  assert.equal(line.armed, null);
  assert.equal(line.cut.enabled, true);
});

test("the view: the where text, then the links; a disabled cut keeps its reason on hover; clicks reach the handlers", () => {
  const clicks = [];
  const div = document.createElement("div");
  const draw = (line) => render(deliveryLineTemplate(line, { onCut: () => clicks.push("cut"), onQueue: () => clicks.push("queue") }), div);
  draw(deliveryLine({ phase: "running a tool", tool: { name: "read" }, cutAfter: 25, now: NOW }));
  assert.equal(div.querySelector(".delivery-where .long").textContent, "\u21B3 goes in after this tool call (read)");
  assert.equal(div.querySelector(".delivery-where .short").textContent, "\u21B3 after this tool call");
  const cut = div.querySelector(".delivery-link.cut");
  assert.equal(cut.disabled, true);
  assert.match(cut.getAttribute("title"), /tool is running/);
  div.querySelector(".delivery-link.queue").click();
  assert.deepEqual(clicks, ["queue"]);

  draw(deliveryLine({ phase: "thinking", gen: thinkingGen(60), cutAfter: 25, now: NOW, armed: "cut" }));
  assert.equal(div.querySelector(".delivery-link.cut").disabled, false);
  assert.equal(div.querySelector(".delivery-link.cut").getAttribute("aria-pressed"), "true");
  assert.ok(div.querySelector(".delivery-link.cut").classList.contains("armed"));

  draw(deliveryLine({ phase: "thinking", gen: thinkingGen(60), cutAfter: 0, now: NOW, canQueue: false }));
  assert.equal(div.querySelectorAll(".delivery-link").length, 0);
});

function control({ empty = true, inputs = {} } = {}) {
  const el = document.createElement("div");
  el.hidden = true;
  const sent = [];
  let tick = null;
  const state = { phase: "thinking", gen: thinkingGen(60), cutAfter: 25, canQueue: true, ...inputs };
  const ctl = createDeliveryControl({
    el, read: () => state, composerEmpty: () => empty, send: (d) => sent.push(d), now: () => NOW,
    setTimer: (fn) => { tick = fn; return 1; }, clearTimer: () => { tick = null; },
  });
  return { ctl, el, sent, state, tick: () => tick?.() , ticking: () => !!tick };
}

test("the control: shown while the turn runs (ticking), hidden after; a link with text sends that delivery", () => {
  const { ctl, el, sent, ticking } = control({ empty: false });
  ctl.show("running");
  assert.equal(el.hidden, false);
  assert.ok(ticking());
  assert.match(el.querySelector(".delivery-where .long").textContent, /thinking step/);
  el.querySelector(".delivery-link.queue").click();
  el.querySelector(".delivery-link.cut").click();
  assert.deepEqual(sent, ["queue", "cut"]);
  assert.equal(ctl.armed(), null);
  ctl.show("off");
  assert.equal(el.hidden, true);
  assert.equal(ticking(), false);
});

test("the control: a link with an empty composer arms (a second click disarms), take() hands it over once, disarm() is Esc", () => {
  const { ctl, el, sent } = control();
  ctl.show("running");
  el.querySelector(".delivery-link.cut").click();
  assert.equal(ctl.armed(), "cut");
  assert.match(el.querySelector(".delivery-where .long").textContent, /Enter sends$/);
  el.querySelector(".delivery-link.cut").click();
  assert.equal(ctl.armed(), null);
  el.querySelector(".delivery-link.queue").click();
  assert.equal(ctl.take(), "queue");
  assert.equal(ctl.take(), null);
  ctl.click("queue");
  assert.equal(ctl.disarm(), true);
  assert.equal(ctl.disarm(), false);
  assert.deepEqual(sent, []);
});

test("the control: an armed cut the turn can no longer take disarms at the next tick", () => {
  const { ctl, state, tick } = control();
  ctl.show("running");
  ctl.click("cut");
  assert.equal(ctl.armed(), "cut");
  Object.assign(state, { phase: "running a tool", tool: { name: "read" } });
  tick();
  assert.equal(ctl.armed(), null);
  // A disabled link doesn't arm.
  ctl.click("cut");
  assert.equal(ctl.armed(), null);
});

test("the control: a session's row is always there: the key hint while idle (no ticking), off outside a session", () => {
  const { ctl, el, ticking } = control();
  ctl.show("idle");
  assert.equal(el.hidden, false);
  assert.equal(el.querySelector(".delivery-where.idle .long").textContent, IDLE_HINT);
  assert.equal(ticking(), false);
  ctl.show("running");
  ctl.click("queue");
  assert.equal(ctl.armed(), "queue");
  // The turn ends: the hint again, nothing armed; a link no longer there.
  ctl.show("idle");
  assert.equal(ctl.armed(), null);
  assert.equal(ticking(), false);
  assert.equal(el.querySelectorAll(".delivery-link").length, 0);
  ctl.click("queue");
  assert.equal(ctl.armed(), null);
  ctl.show("off");
  assert.equal(el.hidden, true);
});

test("the phone's short text and chips: the same line in a few words", () => {
  const line = deliveryLine({ phase: "thinking", gen: thinkingGen(42), cutAfter: 25, now: NOW, armed: "queue" });
  assert.equal(line.short, "\u21B3 after this thinking · 0:42");
  assert.equal(line.cut.short, "cut in");
  assert.equal(line.queue.short, "queue \u2713");
  assert.equal(deliveryLine({ phase: "running a tool", tool: { name: "read", startedAt: NOW - 3000 }, now: NOW }).short, "\u21B3 after this tool call · 0:03");
  assert.equal(deliveryLine({ phase: "writing", now: NOW }).short, "\u21B3 after this answer");
});

test("the thinking clock counts from the first thinking delta when the page saw it (as the worker's cut does), else the generation's start", () => {
  const gen = { thinking: "hm", text: "", tools: [], startedAt: NOW - 10_000, thinkingAt: NOW - 4000 };
  assert.equal(genAge(gen, null, NOW), 4);
  assert.match(deliveryLine({ phase: "thinking", gen, cutAfter: 25, now: NOW }).text, / · 0:04 · /);
  assert.equal(genAge({ ...gen, thinkingAt: null }, null, NOW), 10);
});

test("QUEUE_NEEDS_WORKER: what Alt+Enter says to a worker without the delivery feature", () => {
  assert.match(QUEUE_NEEDS_WORKER, /newer worker/);
});
