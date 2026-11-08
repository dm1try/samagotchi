// The history's shape (history_shape.js): what each kind reads as, what it
// leaves out, and compareShapes with and without an ACCEPTED entry.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { ACCEPTED, KINDS, compareShapes, historyShape } from "../../../lib/samagotchi/web/public/history_shape.js";
import { turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_block.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";

const NOW = Date.parse("2026-10-02T00:00:00Z");

function historyOf(markup) {
  const el = document.createElement("div");
  el.innerHTML = markup;
  return el;
}

test("historyShape reads a reloaded turn: prompt, block, steps, rows, answer, timing", () => {
  const holder = document.createElement("div");
  holder.append(turnHistoryNodes([
    { role: "user", content: "check it", turn_id: "T1", at: "2026-10-01T10:00:00Z" },
    { role: "assistant", content: "Let me look.", parts: { tools: [{ tool: "read", params: 'path="a.rb"', output: "[read]\nok", tool_id: "t1" }] } },
    { role: "assistant", content: "All good." },
  ], normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 1500 }], tool_records: [{ turn_id: "T1", iteration: 1, call_index: 1, tool: "read", status: "ok", duration_ms: 12 }] }),
  { thumbs: () => "", now: NOW }));

  const shape = historyShape(holder);
  assert.deepEqual(shape.map((it) => it.kind), ["prompt", "block", "step", "row", "answer", "timing"]);
  assert.equal(shape[0].text, "check it");
  assert.equal(shape[1].text, "1 step · 1 tool call");
  const row = shape[3];
  assert.equal(row.cls, "ok");
  assert.match(row.text, /^read · /);
  assert.equal(row.output, "ok");
  assert.equal(shape[4].text, "All good.");
  assert.equal(shape[5].text, "turn 1 · 1.5s");
  assert.ok(shape.every((it) => KINDS.includes(it.kind)));
});

test("historyShape reads each other kind, and leaves out the copy button, the time dividers and view state", () => {
  const shape = historyShape(historyOf([
    '<div class="time-gap">3 hours later</div>',
    '<div class="bubble user steered"><div class="user-message">also this</div><span class="state-badge">steered</span></div>',
    '<div class="bubble note"><div class="note-line">note from c1</div><div class="note-text">done</div></div>',
    '<div class="bubble command"><div class="command-line">/help</div><pre class="command-output">…</pre></div>',
    '<details class="bubble recap"><summary>recap</summary><div class="recap-body">so far</div></details>',
    '<div class="bubble hook-notice warn">loop-guard: cut</div>',
    '<div class="bubble hook-notice empty-answer">no answer</div>',
    '<details class="bubble thinking"><summary>thinking</summary></details>',
    '<div class="bubble output report-reply">ok <button class="copy-btn">Copy</button></div>',
    '<div class="bubble cancel stopped">■ stopped</div>',
    '<div class="bubble cancel">✕ turn failed</div>',
    '<details class="bubble question answered"><summary>Which? → A</summary></details>',
    '<div class="bubble plugin-card card-updated" data-card-id="c-1"><div class="card-head"><span class="card-title">Check-in</span></div></div>',
    '<details class="bubble steer-row"><summary>check-in nudged the model</summary></details>',
    '<div class="revise-row entering"></div>',
  ].join("")));

  assert.deepEqual(shape, [
    { kind: "steered", cls: "", text: "also this" },
    { kind: "note", cls: "", text: "note from c1done" },
    { kind: "command", cls: "", text: "/help" },
    { kind: "recap", cls: "", text: "so far" },
    { kind: "notice", cls: "warn", text: "loop-guard: cut" },
    { kind: "empty-answer", cls: "", text: "no answer" },
    { kind: "thinking", cls: "", text: "" },
    { kind: "answer", cls: "report-reply", text: "ok" },
    { kind: "cancel", cls: "", text: "■ stopped" },
    { kind: "failed", cls: "", text: "✕ turn failed" },
    { kind: "question", cls: "", text: "Which? → A" },
    { kind: "card", cls: "", text: "c-1 Check-in" },
    { kind: "steer", cls: "", text: "check-in nudged the model" },
    { kind: "other", cls: "revise-row", text: "" },
  ]);
});

test("historyShape reads a step's steers, rows, notices and cards in order", () => {
  const shape = historyShape(historyOf(
    '<details class="turn-work done outline"><summary><span class="tw-sum"><span class="turn-steps">1 step · 1 tool call</span></span></summary>'
    + '<div class="outline-fold">1 step</div>'
    + '<details class="gen folded"><summary>read a.rb · 1 tool call</summary>'
    + '<details class="steer-row"><summary>check-in nudged the model</summary></details>'
    + '<div class="activity-body">'
    + '<div class="activity-row"><span class="activity-status error"></span><span class="activity-tool">read</span>'
    + '<span class="activity-params">a.rb</span><span class="activity-state error">error</span><span class="activity-duration">12ms</span>'
    + '<div class="activity-edit">✂ stubbed: stale</div><div class="activity-output" title="[read] boom">boom</div></div>'
    + '<div class="hook-notice">↻ empty answer, asking again (1/1)</div>'
    + '<div class="plugin-card" data-card-id="c-2"><span class="card-title">Warn</span></div>'
    + "</div></details></details>",
  ));

  assert.deepEqual(shape, [
    { kind: "block", cls: "", text: "1 step · 1 tool call" },
    { kind: "step", cls: "", text: "read a.rb · 1 tool call" },
    { kind: "steer", cls: "", text: "check-in nudged the model" },
    { kind: "row", cls: "error", text: "read · a.rb · error · 12ms", output: "[read] boom", edit: "✂ stubbed: stale" },
    { kind: "notice", cls: "", text: "↻ empty answer, asking again (1/1)" },
    { kind: "card", cls: "", text: "c-2 Warn" },
  ]);
});

const item = (kind, text = "", extra = {}) => ({ kind, cls: "", text, ...extra });

test("compareShapes: the same lists are the same; a changed or missing item is a difference of its kind", () => {
  const live = [item("prompt", "p"), item("row", "read · a · 12ms"), item("answer", "ok"), item("timing", "turn 1 · 1.5s")];
  assert.deepEqual(compareShapes(live, structuredClone(live)), { same: true, kinds: [], differences: [] });

  const reloaded = [item("prompt", "p"), item("row", "read · a · 14ms"), item("timing", "turn 1 · 1.5s")];
  const result = compareShapes(live, reloaded);
  assert.equal(result.same, false);
  assert.deepEqual(result.kinds, ["answer", "row"]);
  assert.deepEqual(result.differences, [[live[1], reloaded[1]], [live[2], null]]);
});

test("compareShapes: an ACCEPTED entry explains its difference only when allowed", () => {
  const live = [item("prompt", "p"), item("block", "2 steps"), item("step", "thinking"),
    item("notice", "↻ empty answer, asking again (1/1)"), item("step", "thinking"), item("answer", "PONG")];
  const reloaded = [item("prompt", "p"), item("thinking"), item("notice", "↻ empty answer, asking again (1/1)"), item("answer", "PONG")];
  assert.deepEqual(compareShapes(live, reloaded).kinds, ["block", "step", "thinking"]);
  assert.deepEqual(compareShapes(live, reloaded, { allow: ["retry-row"] }), { same: true, kinds: [], differences: [] });

  // A command's reply bubble, dropped on a reload; one that came back is not.
  const command = [item("prompt", "p"), item("command", "/model x")];
  assert.equal(compareShapes(command, [item("prompt", "p")], { allow: ["command-bubble"] }).same, true);
  assert.equal(compareShapes([item("prompt", "p")], command, { allow: ["command-bubble"] }).same, false);

  // A ✂ mark only a reload shows: the rows are otherwise the same.
  const row = item("row", "read · a · 1ms");
  assert.equal(compareShapes([row], [{ ...row, edit: "✂ stubbed: stale" }], { allow: ["edit-mark"] }).same, true);
  assert.equal(compareShapes([row], [{ ...row, text: "read · b · 1ms", edit: "✂" }], { allow: ["edit-mark"] }).same, false);

  // A card placed after the turn on a reload: moved, not lost.
  const card = item("card", "c-1");
  const moved = compareShapes([item("prompt", "p"), card, item("answer", "a")], [item("prompt", "p"), item("answer", "a"), card],
    { allow: ["in-turn-card"] });
  assert.equal(moved.same, true);
  assert.equal(compareShapes([item("prompt", "p"), card], [item("prompt", "p")], { allow: ["in-turn-card"] }).same, false);
});

test("ACCEPTED: each entry has an id and a reason; the found ones name their test; P2 closes the bugs", () => {
  const ids = ACCEPTED.map((entry) => entry.id);
  assert.deepEqual(ids, ["retry-row", "command-bubble", "edit-mark", "failed-step", "in-turn-card"]);
  for (const entry of ACCEPTED) {
    assert.ok(entry.reason.length > 20, entry.id);
    assert.equal(typeof entry.match, "function");
  }
  assert.deepEqual(ACCEPTED.filter((entry) => entry.found).map((entry) => entry.id), ["failed-step", "in-turn-card"]);
  assert.deepEqual(ACCEPTED.filter((entry) => entry.closedBy).map((entry) => entry.id), ["retry-row", "failed-step", "in-turn-card"]);
});
