import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { createTurnBlock, turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_block.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";

// A block hides its chrome (index.html, the .turn-work:not(:has(…)) rules) only
// while it has nothing to stack: a plain answer streaming. A step that closed
// with text is a row with a summary, or its text can't be reached: the rule
// also hides that step's summary, and a closed <details> hides its text.
// happy-dom's :not(:has(…)) isn't reliable, so this runs the rules' own list as
// a query over the markup the live page and a reload really draw. The real
// browser's boxes, at both widths, are web.spec.js's steered-line journey.
const CSS = fs.readFileSync(new URL("../../../lib/samagotchi/web/public/index.html", import.meta.url), "utf8");
const LISTS = [...CSS.matchAll(/\.turn-work:not\(:has\(([^{}]*?)\)\)(?=[\s>{,])/g)].map((m) => m[1]);
const stacks = (block) => !!block.querySelector(LISTS[0]);

test("the block's chrome rules all read one list", () => {
  assert.ok(LISTS.length >= 4, `found ${LISTS.length}`);
  assert.equal(new Set(LISTS).size, 1);
});

function liveBlock() {
  const host = document.createElement("div");
  const answer = document.createElement("div");
  const turnBlock = createTurnBlock({
    historyEl: document.createElement("div"),
    isNearBottom: () => false,
    follow: () => {},
    sawText: () => {},
    sessionId: () => "s1",
    blockHost: (el) => host.appendChild(el),
    placeAnswer: (pieces, { plain, blockEl }) => {
      if (plain) blockEl.remove();
      answer.append(...pieces);
    },
  });
  return { turnBlock, host, answer };
}

// One step of text; the next generation starting closes it.
function textStep(turnBlock, iteration, text) {
  turnBlock.generationStarted({ iteration });
  turnBlock.chunk({ text, iteration });
  turnBlock.flush();
  turnBlock.generationCompleted();
}

function toolStep(turnBlock, iteration, text = "") {
  turnBlock.generationStarted({ iteration });
  if (text) turnBlock.chunk({ text, iteration });
  turnBlock.flush();
  turnBlock.generationCompleted();
  turnBlock.toolStarted({ iteration, call_index: 1, tool: "read", params: 'path="R.md"' });
  turnBlock.toolCompleted({ iteration, call_index: 1, tool: "read", status: "ok", output: "[read]\nok" });
}

const FIRST = "First reply.\n\nIts second paragraph.";

// What a reader needs: a block that keeps its chrome, its one step a row
// that says the reply's first line, and the whole reply under that row.
function assertReplyReachable(block, steps = 1) {
  assert.ok(stacks(block), "the block keeps its chrome");
  const gens = block.querySelectorAll(":scope > .gen");
  assert.equal(gens.length, steps);
  assert.equal(gens[0].querySelector(":scope > summary").textContent, "First reply.");
  assert.equal(gens[0].querySelector(":scope > .gen-text").textContent.trim(), FIRST);
}

test("live: a plain answer streaming has no chrome yet, and no block once it ended", () => {
  const { turnBlock, host, answer } = liveBlock();
  turnBlock.turnStarted({ prompt: "p" });
  turnBlock.chunk({ text: "An answer so far. ", iteration: 1 });
  turnBlock.flush();
  assert.equal(stacks(host.querySelector(".turn-work")), false);
  turnBlock.turnEnded({ kind: "completed" });
  assert.equal(host.querySelector(".turn-work"), null);
  assert.match(answer.querySelector(".bubble.output").textContent, /An answer so far/);
});

test("live: a text-only step steered into a second step stays a row of the block, its answer the bubble", () => {
  const { turnBlock, host, answer } = liveBlock();
  turnBlock.turnStarted({ prompt: "p" });
  textStep(turnBlock, 1, FIRST);
  textStep(turnBlock, 2, "Second reply.");
  assert.ok(stacks(host.querySelector(".turn-work")), "two steps while it runs");
  turnBlock.turnEnded({ kind: "completed", turnId: "T1" });
  const block = host.querySelector(".turn-work");
  assertReplyReachable(block);
  assert.equal(block.querySelector(":scope > summary").textContent, "1 step");
  assert.equal(answer.querySelector(".bubble.output").textContent, "Second reply.");
});

test("live: a plugin's steer after a text-only step keeps the step reachable too", () => {
  const { turnBlock, host, answer } = liveBlock();
  turnBlock.turnStarted({ prompt: "p" });
  textStep(turnBlock, 1, FIRST);
  turnBlock.steer({ source: "check-in", text: "say what you found" });
  textStep(turnBlock, 2, "Second reply.");
  turnBlock.turnEnded({ kind: "completed", turnId: "T1" });
  assertReplyReachable(host.querySelector(".turn-work"));
  assert.ok(answer.querySelector(".steer-row"));
});

test("live: a steer during text, then a tool step: both steps are rows", () => {
  const { turnBlock, host } = liveBlock();
  turnBlock.turnStarted({ prompt: "p" });
  textStep(turnBlock, 1, FIRST);
  toolStep(turnBlock, 2);
  textStep(turnBlock, 3, "Second reply.");
  turnBlock.turnEnded({ kind: "completed", turnId: "T1" });
  assertReplyReachable(host.querySelector(".turn-work"), 2);
});

test("live, the control: a steer after a tool step keeps its block as it always did", () => {
  const { turnBlock, host } = liveBlock();
  turnBlock.turnStarted({ prompt: "p" });
  toolStep(turnBlock, 1, "Let me look.");
  textStep(turnBlock, 2, "Second reply.");
  turnBlock.turnEnded({ kind: "completed", turnId: "T1" });
  const block = host.querySelector(".turn-work");
  assert.ok(stacks(block));
  assert.equal(block.querySelectorAll(":scope > .gen").length, 1);
  assert.ok(block.querySelector(".activity-body"));
});

// A reload's nodes in a holder, as #history holds them.
function reloaded(items, records = []) {
  const holder = document.createElement("div");
  holder.append(turnHistoryNodes(items, normalizeTiming({ turn_records: records }), { thumbs: () => "", now: 0 }));
  return holder;
}

const PROMPT = { role: "user", content: "p", turn_id: "T1" };
const STEERED = { role: "user", content: "also this", merged: true, step: 2 };

test("reload: a text-only step before a merged line is the live page's row, in the same place", () => {
  const holder = reloaded([PROMPT, { role: "assistant", content: FIRST }, STEERED, { role: "assistant", content: "Second reply." }],
    [{ id: "T1", status: "completed", duration_ms: 1000 }]);
  const block = holder.querySelector(":scope > .turn-work");
  assertReplyReachable(block);
  assert.equal(block.querySelector(":scope > summary").textContent, "1 step");
  const order = [...holder.children].map((el) => el.className.split(" ").slice(0, 3).join("."));
  assert.deepEqual(order, ["bubble.user", "turn-work.done.outline", "bubble.user.steered", "bubble.output", "turn-timing"]);
});

test("reload: the same step keeps its markdown as the step's text", () => {
  const holder = reloaded([PROMPT, { role: "assistant", content: FIRST, html: "<p>First reply.</p><p>Its second paragraph.</p>" }, STEERED, { role: "assistant", content: "Second reply." }],
    [{ id: "T1", status: "completed", duration_ms: 1000 }]);
  const block = holder.querySelector(":scope > .turn-work");
  assert.ok(stacks(block));
  assert.match(htmlOf(block), /<div class="gen-text markdown md-compact"[^>]*><p>First reply\.<\/p><p>Its second paragraph\.<\/p><\/div>/);
});

test("reload: a turn with no answer whose one step has text keeps it reachable (failed; empty answer)", () => {
  const failed = reloaded([PROMPT, { role: "assistant", content: FIRST }], [{ id: "T1", status: "failed", duration_ms: 1000 }]);
  assertReplyReachable(failed.querySelector(":scope > .turn-work"));
  const empty = reloaded([PROMPT, { role: "assistant", content: FIRST }, STEERED, { role: "empty_answer", content: "no answer" }],
    [{ id: "T1", status: "completed", duration_ms: 1000 }]);
  assertReplyReachable(empty.querySelector(":scope > .turn-work"));
});

test("reload: a lone step saved with nothing to show has no chrome for it", () => {
  const holder = reloaded([PROMPT, { role: "assistant", content: "", parts: {} }, STEERED, { role: "assistant", content: "Second reply.", parts: {} }],
    [{ id: "T1", status: "completed", duration_ms: 1000 }]);
  const block = holder.querySelector(":scope > .turn-work");
  assert.equal(block.querySelectorAll(":scope > .gen").length, 1);
  assert.equal(stacks(block), false);
});

test("reload, the control: a steer after a tool step keeps its block as it always did", () => {
  const holder = reloaded([PROMPT, { role: "assistant", content: "Let me look.", parts: { tools: [{ tool: "read", title: "R.md" }] } }, STEERED, { role: "assistant", content: "Second reply." }],
    [{ id: "T1", status: "completed", duration_ms: 1000 }]);
  const block = holder.querySelector(":scope > .turn-work");
  assert.ok(stacks(block));
  assert.ok(block.querySelector(".activity-body"));
});
