import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { charsText, clockText, CUT_LABEL, deliveryLine, deliveryLineTemplate, genAge, QUEUE_LABEL } from "../../../lib/samagotchi/web/public/delivery_line.js";

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
  assert.deepEqual(line.cut, { enabled: true, shown: true, reason: "", label: CUT_LABEL });
  assert.deepEqual(line.queue, { enabled: true, shown: true, label: QUEUE_LABEL });
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
  assert.deepEqual(line.queue, { enabled: false, shown: false, label: QUEUE_LABEL });
  assert.equal(line.armed, null);
  assert.equal(line.cut.enabled, true);
});

test("the view: the where text, then the links; a disabled cut keeps its reason on hover; clicks reach the handlers", () => {
  const clicks = [];
  const div = document.createElement("div");
  const draw = (line) => render(deliveryLineTemplate(line, { onCut: () => clicks.push("cut"), onQueue: () => clicks.push("queue") }), div);
  draw(deliveryLine({ phase: "running a tool", tool: { name: "read" }, cutAfter: 25, now: NOW }));
  assert.equal(div.querySelector(".delivery-where").textContent, "\u21B3 goes in after this tool call (read)");
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
