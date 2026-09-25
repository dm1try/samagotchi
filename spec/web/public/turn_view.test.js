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
    '<div class="bubble user"><div class="user-message">p</div></div>' +
    '<details class="turn-work done"><summary>2 steps · 2 tool calls</summary>' +
    '<details class="gen"><summary>Let me &lt;check&gt;. · 1 tool call</summary><div class="gen-text">Let me &lt;check&gt;.</div>' +
    '<div class="activity-body"><div class="activity-row" data-key="1:1"><span class="activity-status ok">done</span><span class="activity-tool">execute</span><span class="activity-params">7ms</span></div></div></details>' +
    '<details class="gen"><summary>working with read · 1 tool call</summary>' +
    '<div class="activity-body"><div class="activity-row" data-key="2:1"><span class="activity-status ok">done</span><span class="activity-tool">read</span><span class="activity-params">1.2s</span></div></div></details>' +
    '</details>' +
    '<div class="bubble output markdown"><p>Both <em>fine</em>.</p><div class="turn-timing">turn 1 · 19s</div></div>');
});

test("turnHistoryHtml: a plain answer and a note render as the chat view does", () => {
  const items = [{ role: "user", content: "p" }, { role: "assistant", content: "PONG" }, { role: "note", content: "n", label: "x" }];
  const plain = normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 500 }] });
  assert.equal(turnHistoryHtml(items, plain, { thumbs }),
    '<div class="bubble user"><div class="user-message">p</div></div>' +
    '<div class="bubble output">PONG<div class="turn-timing">turn 1 · 0.5s</div></div>' +
    '<div class="bubble note"><div class="note-line">note from x</div><div class="note-text">n</div></div>');
});

test("turnHistoryHtml: a turn canceled before any answer keeps its timing under the prompt, after its steps", () => {
  const items = [{ role: "user", content: "p" }];
  const canceled = normalizeTiming({
    turn_records: [{ id: "T1", status: "canceled", duration_ms: 900 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 }],
  });
  const html = turnHistoryHtml(items, canceled, { thumbs });
  assert.match(html, /<\/details><div class="turn-timing">turn 1 · 0.9s · canceled<\/div>$/);
  assert.match(html, /<summary>1 step · 1 tool call<\/summary><details class="gen"><summary>working with execute · 1 tool call<\/summary>/);
});
