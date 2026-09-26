import test from "node:test";
import assert from "node:assert/strict";
import { turnHistoryHtml } from "../../../lib/samagotchi/web/public/turn_view.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";

const timing = normalizeTiming({
  turn_records: [{ id: "T1", status: "completed", duration_ms: 18503 }],
  tool_records: [
    { id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 },
    { id: "T1:2:1", turn_id: "T1", iteration: 2, call_index: 1, tool: "read", status: "ok", duration_ms: 1200 },
  ],
});
const thumbs = () => "";

test("turnHistoryHtml: a reloaded tool turn is a collapsed block of steps, then the answer with its timing", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Let me <check>." },
    { role: "assistant", content: "Both fine.", html: "<p>Both <em>fine</em>.</p>" },
  ];
  const html = turnHistoryHtml(items, timing, { thumbs });
  assert.equal(html,
    '<div class="bubble user" data-copy-source="p"><div class="user-message">p</div></div>' +
    '<details class="turn-work done"><summary>2 steps · 2 tool calls</summary>' +
    '<details class="gen"><summary>Let me &lt;check&gt;. · 1 tool call</summary><div class="gen-text">Let me &lt;check&gt;.</div>' +
    '<div class="activity-body"><div class="activity-row" data-key="1:1"><span class="activity-status ok">done</span><span class="activity-tool">execute</span><span class="activity-duration">7ms</span></div></div></details>' +
    '<details class="gen"><summary>working with read · 1 tool call</summary>' +
    '<div class="activity-body"><div class="activity-row" data-key="2:1"><span class="activity-status ok">done</span><span class="activity-tool">read</span><span class="activity-duration">1.2s</span></div></div></details>' +
    '</details>' +
    '<div class="bubble output markdown" data-copy-source="Both fine."><p>Both <em>fine</em>.</p></div><div class="turn-timing">turn 1 · 19s</div>');
});

test("turnHistoryHtml: a plain answer and a note; the timing line under the answer, where the live view leaves it", () => {
  const items = [{ role: "user", content: "p" }, { role: "assistant", content: "PONG" }, { role: "note", content: "n", label: "x" }];
  const plain = normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 500 }] });
  assert.equal(turnHistoryHtml(items, plain, { thumbs }),
    '<div class="bubble user" data-copy-source="p"><div class="user-message">p</div></div>' +
    '<div class="bubble output">PONG</div><div class="turn-timing">turn 1 · 0.5s</div>' +
    '<div class="bubble note"><div class="note-line">note from x</div><div class="note-text">n</div></div>');
});

test("turnHistoryHtml: a turn canceled before any answer keeps its timing under the prompt, after its steps", () => {
  const items = [{ role: "user", content: "p" }];
  const canceled = normalizeTiming({
    turn_records: [{ id: "T1", status: "canceled", duration_ms: 900 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 }],
  });
  const html = turnHistoryHtml(items, canceled, { thumbs });
  assert.match(html, /<\/details><div class="turn-timing">turn 1 · 0.9s · canceled<\/div><div class="bubble cancel">\u2715 canceled<\/div>$/);
  assert.match(html, /<summary>1 step · 1 tool call<\/summary><details class="gen"><summary>working with execute · 1 tool call<\/summary>/);
});

test("turnHistoryHtml with parts: each step expands to its thinking, text and calls with params and output, as live", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Let me check.", parts: { thinking: "plan <a>", tools: [{ tool: "execute", params: 'command="true"', output: "[execute]\nexit: 0" }] } },
    { role: "assistant", content: "", parts: { tools: [{ tool: "read", params: 'path="R.md"', output: `[read]\n${"x".repeat(310)}` }] } },
    { role: "assistant", content: "Both fine.", parts: { thinking: "sum up" } },
  ];
  const html = turnHistoryHtml(items, timing, { thumbs });
  assert.equal(html,
    '<div class="bubble user" data-copy-source="p"><div class="user-message">p</div></div>' +
    '<details class="turn-work done"><summary>3 steps · 2 tool calls</summary>' +
    '<details class="gen"><summary>Let me check. · 1 tool call</summary><details class="thinking"><summary>thinking</summary><div class="thinking-body">plan &lt;a&gt;</div></details><div class="gen-text">Let me check.</div>' +
    '<div class="activity-body"><div class="activity-row" data-key="1:1"><span class="activity-status ok">done</span><span class="activity-tool">execute</span>' +
    '<span class="activity-params">command=&quot;true&quot;</span><span class="activity-duration">7ms</span><div class="activity-output" title="exit: 0">exit: 0</div></div></div></details>' +
    '<details class="gen"><summary>working with read · 1 tool call</summary>' +
    '<div class="activity-body"><div class="activity-row" data-key="2:1"><span class="activity-status ok">done</span><span class="activity-tool">read</span>' +
    `<span class="activity-params">path=&quot;R.md&quot;</span><span class="activity-duration">1.2s</span><div class="activity-output" title="${"x".repeat(310)}">${"x".repeat(300)}…</div></div></div></details>` +
    // A thinking-only step: one header, the body directly under it (no
    // nested wrap that would repeat "thinking"), as the live view leaves it.
    '<details class="gen"><summary>thinking</summary><div class="thinking-body">sum up</div></details>' +
    '</details>' +
    '<div class="bubble output">Both fine.</div><div class="turn-timing">turn 1 · 19s</div>');
});

test("turnHistoryHtml with parts: a plain answer's thinking is the chat view's collapsed thinking block, no step block", () => {
  const items = [{ role: "user", content: "p" }, { role: "assistant", content: "PONG", parts: { thinking: "easy" } }];
  const html = turnHistoryHtml(items, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 500 }] }), { thumbs });
  assert.equal(html,
    '<div class="bubble user" data-copy-source="p"><div class="user-message">p</div></div>' +
    '<details class="bubble thinking"><summary>thinking</summary><div class="thinking-body">easy</div></details>' +
    '<div class="bubble output">PONG</div><div class="turn-timing">turn 1 · 0.5s</div>');
});

test("turnHistoryHtml: a canceled turn with an answer ends with its cancel line and reason, after the answer", () => {
  const items = [{ role: "user", content: "p" }, { role: "assistant", content: "Running the slow\n[interrupted]" }];
  const canceled = normalizeTiming({ turn_records: [{ id: "T1", status: "canceled", cancellation_reason: "user", duration_ms: 4400 }] });
  const html = turnHistoryHtml(items, canceled, { thumbs });
  assert.match(html, /<div class="turn-timing">turn 1 · 4.4s · canceled<\/div><div class="bubble cancel">\u2715 canceled \(user\)<\/div>$/);
  const done = normalizeTiming({ turn_records: [{ id: "T1", status: "completed", duration_ms: 4400 }] });
  assert.doesNotMatch(turnHistoryHtml(items, done, { thumbs }), /bubble cancel/);
});

test("turnHistoryHtml: a canceled multi-step turn keeps its partial text in the block, as live: no answer bubble", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Checking.", parts: { tools: [{ tool: "execute", params: 'command="true"', output: "exit: 0" }] } },
    { role: "assistant", content: "Both checks passed:\n[interrupted]" },
  ];
  const canceled = normalizeTiming({
    turn_records: [{ id: "T1", status: "canceled", cancellation_reason: "user", duration_ms: 12000 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 }],
  });
  const html = turnHistoryHtml(items, canceled, { thumbs });
  assert.doesNotMatch(html, /bubble output/);
  assert.match(html, /2 steps · 1 tool call/);
  assert.match(html, /Both checks passed:/);
  assert.match(html, /<\/details><div class="turn-timing">turn 1 · 12s · canceled<\/div><div class="bubble cancel">✕ canceled \(user\)<\/div>$/);
});
