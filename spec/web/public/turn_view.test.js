import test from "node:test";
import assert from "node:assert/strict";
import { turnHistoryHtml } from "../../../lib/samagotchi/web/public/turn_view.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";
import { failedTurnText } from "../../../lib/samagotchi/web/public/format.js";
import { commandBlockHtml } from "../../../lib/samagotchi/web/public/command_view.js";

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
    '<details class="gen"><summary class="repeats"><span class="gen-head">Let me &lt;check&gt;.</span><span class="gen-sep"> · </span><span class="gen-calls">1 tool call</span></summary><div class="gen-text">Let me &lt;check&gt;.</div>' +
    '<div class="activity-body"><div class="activity-row" data-key="1:1"><span class="activity-status ok" role="img" aria-label="done" title="done"></span><span class="activity-tool">execute</span><span class="activity-duration">7ms</span></div></div></details>' +
    '<details class="gen"><summary>working with read · 1 tool call</summary>' +
    '<div class="activity-body"><div class="activity-row" data-key="2:1"><span class="activity-status ok" role="img" aria-label="done" title="done"></span><span class="activity-tool">read</span><span class="activity-duration">1.2s</span></div></div></details>' +
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

test("turnHistoryHtml: a `!cmd`'s saved user message renders as its command bubble, not a user bubble", () => {
  const items = [{ role: "user", content: "!(echo <hi>)\n<hi>" }, { role: "assistant", content: "done" }];
  const html = turnHistoryHtml(items, normalizeTiming({}), { thumbs });
  assert.match(html, /^<div class="bubble command"><div class="command-line">!echo &lt;hi&gt;<\/div><pre class="command-output">&lt;hi&gt;<\/pre><\/div>/);
  assert.doesNotMatch(html, /bubble user/);
  // A message that merely starts with "!(" without the newline shape stays a user bubble.
  const plain = turnHistoryHtml([{ role: "user", content: "!(no newline" }], normalizeTiming({}), { thumbs });
  assert.match(plain, /^<div class="bubble user"/);
});

test("turnHistoryHtml: a turn canceled before any answer keeps its timing under the prompt, after its steps", () => {
  const items = [{ role: "user", content: "p" }];
  const canceled = normalizeTiming({
    turn_records: [{ id: "T1", status: "canceled", duration_ms: 900 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 }],
  });
  const html = turnHistoryHtml(items, canceled, { thumbs });
  assert.match(html, /<\/details><div class="turn-timing">turn 1 · 0.9s · canceled<\/div><div class="bubble cancel stopped">\u25A0 canceled<\/div>$/);
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
    '<details class="gen"><summary class="repeats"><span class="gen-head">Let me check.</span><span class="gen-sep"> · </span><span class="gen-calls">1 tool call</span></summary><details class="thinking"><summary>thinking</summary><div class="thinking-body">plan &lt;a&gt;</div></details><div class="gen-text">Let me check.</div>' +
    '<div class="activity-body"><div class="activity-row" data-key="1:1"><span class="activity-status ok" role="img" aria-label="done" title="done"></span><span class="activity-tool">execute</span>' +
    '<span class="activity-params">command=&quot;true&quot;</span><span class="activity-duration">7ms</span><div class="activity-output" title="exit: 0">exit: 0</div></div></div></details>' +
    '<details class="gen"><summary>working with read · 1 tool call</summary>' +
    '<div class="activity-body"><div class="activity-row" data-key="2:1"><span class="activity-status ok" role="img" aria-label="done" title="done"></span><span class="activity-tool">read</span>' +
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
  assert.match(html, /<div class="turn-timing">turn 1 · 4.4s · canceled<\/div><div class="bubble cancel stopped">\u25A0 canceled \(stopped\)<\/div>$/);
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
  assert.match(html, /<\/details><div class="turn-timing">turn 1 · 12s · canceled<\/div><div class="bubble cancel stopped">■ canceled \(stopped\)<\/div>$/);
});

test("turnHistoryHtml with parts: a call's images are thumbs on its reloaded row, as live", () => {
  const items = [
    { role: "user", content: "shoot" },
    { role: "assistant", content: "", parts: { tools: [
      { tool: "mcp_chrome_screenshot", params: "", output: "[mcp_chrome_screenshot]\n/tmp/s.png", images: [{ file: "images/aa.png", name: "s.png" }] },
      { tool: "execute", params: 'command="true"', output: "[execute]\n" },
    ] } },
    { role: "assistant", content: "A page." },
  ];
  const seen = [];
  const html = turnHistoryHtml(items, normalizeTiming({}), { thumbs: (images) => { if (!images?.length) return ""; seen.push(images); return `<div class="thumbs">${images.map((i) => i.name).join(",")}</div>`; } });
  assert.deepEqual(seen, [[{ file: "images/aa.png", name: "s.png" }]]);
  assert.match(html, /<span class="activity-tool">mcp_chrome_screenshot<\/span>.*\/tmp\/s\.png<\/div><div class="thumbs">s\.png<\/div><\/div>/);
  assert.equal(html.match(/class="thumbs"/g).length, 1);
});

test("turnHistoryHtml: a plugin's steer is the first row of the step that answered it, not a prompt", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Let me check." },
    { role: "steer", content: "say what <you> found", source: "check-in", step: 2 },
    { role: "assistant", content: "Both fine." },
  ];
  const html = turnHistoryHtml(items, timing, { thumbs });
  assert.equal((html.match(/bubble user/g) || []).length, 1);
  assert.match(html, /<details class="gen"><summary>[^<]*<\/summary><details class="steer-row"><summary>check-in nudged the model<\/summary><div class="steer-text">say what &lt;you&gt; found<\/div><\/details><div class="activity-body">.*read/);
});

test("turnHistoryHtml: a steer the answer answered is a bubble after the block, before the answer", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Let me check." },
    { role: "steer", content: "wrap up", source: "check-in", step: 3 },
    { role: "assistant", content: "Both fine." },
  ];
  const html = turnHistoryHtml(items, timing, { thumbs });
  assert.match(html, /<\/details><details class="bubble steer-row"><summary>check-in nudged the model<\/summary><div class="steer-text">wrap up<\/div><\/details><div class="bubble output/);
});

test("turnHistoryHtml: the user's lines merged into a turn stay in it: a steered bubble after its steps, before its answer and timing", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Let me check." },
    { role: "user", content: "also <typos>", merged: true, step: 2 },
    { role: "assistant", content: "Both fine." },
    { role: "user", content: "next" },
    { role: "assistant", content: "ok" },
  ];
  const twoTurns = normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 5000 }, { id: "T2", duration_ms: 2000 }] });
  const html = turnHistoryHtml(items, twoTurns, { thumbs });
  assert.equal((html.match(/class="bubble user"/g) || []).length, 2);
  assert.match(html, /<\/details><div class="bubble user steered" data-user-state="steered" data-step="2"[^>]*><div class="user-message">also &lt;typos&gt;<\/div><span class="state-badge">steered<\/span><\/div><div class="bubble output[^"]*"[^>]*>.*Both fine.*<\/div><div class="turn-timing">turn 1 · 5\.0s<\/div>/);
  assert.match(html, /ok.*<div class="turn-timing">turn 2 · 2\.0s<\/div>/);
});

test("turnHistoryHtml: a delegate report keeps its label on reload: a wake turn's prompt, or merged into a turn", () => {
  const items = [
    { role: "user", content: "session: c1", source: "delegate_report", turn_id: "T1" },
    { role: "assistant", content: "The child found it." },
    { role: "user", content: "p", turn_id: "T2" },
    { role: "assistant", content: "Let me check." },
    { role: "user", content: "session: c2", source: "delegate_report", merged: true, step: 2 },
    { role: "assistant", content: "Both fine." },
  ];
  const html = turnHistoryHtml(items, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 5 }, { id: "T2", duration_ms: 5 }] }), { thumbs });
  assert.match(html, /^<div class="bubble user"[^>]*><span class="origin-label">delegate report<\/span><div class="user-message">session: c1<\/div>/);
  assert.match(html, /<div class="bubble user steered"[^>]*><span class="origin-label">delegate report<\/span><div class="user-message">session: c2/);
  assert.equal((html.match(/origin-label/g) || []).length, 2);
});

test("turnHistoryHtml: the text that answered a delegate report mid-turn stays visible after its bubble, unless it is the answer", () => {
  const items = [
    { role: "user", content: "rename it", turn_id: "T1" },
    { role: "assistant", content: "Reading." },
    { role: "user", content: "session: c1", source: "delegate_report", merged: true, step: 2 },
    { role: "assistant", content: "The delegate found the bug. Back to the rename." },
    { role: "assistant", content: "Renamed." },
    { role: "user", content: "next", turn_id: "T2" },
    { role: "assistant", content: "Reading." },
    { role: "user", content: "session: c2", source: "delegate_report", merged: true, step: 2 },
    { role: "assistant", content: "Done; the delegate said ok." },
  ];
  const html = turnHistoryHtml(items, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 5 }, { id: "T2", duration_ms: 5 }] }), { thumbs });
  assert.match(html, /session: c1<\/div><span class="state-badge">steered<\/span><\/div><div class="bubble output report-reply"[^>]*>The delegate found the bug\. Back to the rename\.<\/div><div class="bubble output[^"]*"[^>]*>Renamed\./);
  assert.equal((html.match(/report-reply/g) || []).length, 1);
});

test("turnHistoryHtml: a steer in a turn with no block is a bubble after the prompt", () => {
  const items = [{ role: "user", content: "p" }, { role: "steer", content: "s", source: "check-in", step: 1 }, { role: "assistant", content: "a" }];
  const html = turnHistoryHtml(items, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 5 }] }), { thumbs });
  assert.match(html, /<\/div><\/div><details class="bubble steer-row"><summary>check-in nudged the model<\/summary>/);
});

test("turnHistoryHtml: a saved task_wait record the user's Stop ended reloads as stopped, not done", () => {
  const items = [{ role: "user", content: "p" }, { role: "assistant", content: "Waiting." }];
  const stopped = normalizeTiming({
    turn_records: [{ id: "T1", status: "canceled", duration_ms: 900 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "task_wait", status: "stopped", duration_ms: 800 }],
  });
  const html = turnHistoryHtml(items, stopped, { thumbs });
  assert.match(html, /<span class="activity-status stopped" role="img" aria-label="stopped" title="stopped"><\/span><span class="activity-tool">task_wait<\/span><span class="activity-state stopped">stopped<\/span><span class="activity-duration">/);
});

test("turnHistoryHtml: a saved guardrail-denied record reloads as blocked, not done", () => {
  const items = [{ role: "user", content: "p" }, { role: "assistant", content: "Searching." }];
  const denied = normalizeTiming({
    turn_records: [{ id: "T1", status: "canceled", duration_ms: 900 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "blocked", duration_ms: 0 }],
  });
  const html = turnHistoryHtml(items, denied, { thumbs });
  assert.match(html, /<span class="activity-status blocked" role="img" aria-label="blocked" title="blocked"><\/span><span class="activity-tool">execute<\/span><span class="activity-state blocked">blocked<\/span>/);
});

test("turnHistoryHtml with parts: an edit's row keeps its collapsed diff after a reload", () => {
  const diff = { text: "@@ -1 +1 @@\n-a\n+b", added: 1, removed: 1, new_file: false };
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "", parts: { tools: [{ tool: "edit", params: 'path="k.conf"', output: "[edit]\nEdited", diff }] } },
    { role: "assistant", content: "Done." },
  ];
  const html = turnHistoryHtml(items, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 500 }] }), { thumbs });
  assert.match(html, /<div class="activity-output"[^>]*>Edited<\/div><details class="activity-diff"><summary>diff \+1 \u22121<\/summary><pre class="diff">/);
});

test("turnHistoryHtml: the timing line numbers a turn by its record, after a failed turn as live", () => {
  const timing = normalizeTiming({ turn_records: [
    { id: "A", status: "completed", duration_ms: 1000 },
    { id: "B", status: "failed", duration_ms: 50 },
    { id: "C", status: "completed", duration_ms: 3000 },
  ] });
  const items = [
    { role: "user", content: "one", turn_id: "A" }, { role: "assistant", content: "1" },
    { role: "user", content: "three", turn_id: "C" }, { role: "assistant", content: "3" },
  ];
  const html = turnHistoryHtml(items, timing, { thumbs: () => "" });
  assert.match(html, /turn 1 · 1\.0s/);
  assert.match(html, /turn 3 · 3\.0s/);
});

test("turnHistoryHtml: a turn with no answer keeps its empty steps, then the muted notice before its timing", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "", parts: { thinking: "first" } },
    { role: "assistant", content: "", parts: { thinking: "second" } },
    { role: "empty_answer", content: "", retries: 1 },
  ];
  const html = turnHistoryHtml(items, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 3700 }] }), { thumbs });
  assert.equal(html,
    '<div class="bubble user" data-copy-source="p"><div class="user-message">p</div></div>' +
    '<details class="turn-work done"><summary>2 steps</summary>' +
    '<details class="gen"><summary>thinking</summary><div class="thinking-body">first</div></details>' +
    '<details class="gen"><summary>thinking</summary><div class="thinking-body">second</div></details>' +
    '</details>' +
    '<div class="bubble hook-notice empty-answer">no answer: the model returned nothing (after 1 retry)</div>' +
    '<div class="turn-timing">turn 1 · 3.7s</div>');
});

test("turnHistoryHtml: a one-step turn with no answer is its collapsed thinking and the notice, as live", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "", parts: { thinking: "hm" } },
    { role: "empty_answer", content: "", retries: 0 },
  ];
  const html = turnHistoryHtml(items, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 500 }] }), { thumbs });
  assert.equal(html,
    '<div class="bubble user" data-copy-source="p"><div class="user-message">p</div></div>' +
    '<details class="bubble thinking"><summary>thinking</summary><div class="thinking-body">hm</div></details>' +
    '<div class="bubble hook-notice empty-answer">no answer: the model returned nothing</div>' +
    '<div class="turn-timing">turn 1 · 0.5s</div>');
});

test("turnHistoryHtml: a turn with no answer after tool steps shows no step's text as its answer", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Looking." },
    { role: "empty_answer", content: "", retries: 1 },
  ];
  const tools = normalizeTiming({
    turn_records: [{ id: "T1", duration_ms: 900 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 }],
  });
  const html = turnHistoryHtml(items, tools, { thumbs });
  assert.doesNotMatch(html, /bubble output/);
  assert.match(html, /<div class="gen-text">Looking\.<\/div>/);
  assert.match(html, /<div class="bubble hook-notice empty-answer">no answer: the model returned nothing \(after 1 retry\)<\/div><div class="turn-timing">/);
});

test("turnHistoryHtml with parts: an execute's reloaded row shows its full command above the output, its hover the command", () => {
  const view = { command: "cd /p && rg -n foo lib |\n  head -5", cwd: "lib" };
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "", parts: { tools: [{ tool: "execute", params: 'command="cd /p && rg -n foo lib | head -5"', title: "rg -n foo lib |", output: "[execute]\na", view }] } },
    { role: "assistant", content: "Done." },
  ];
  const html = turnHistoryHtml(items, timing, { thumbs });
  assert.ok(html.includes(
    '<span class="activity-params" title="cd /p &amp;&amp; rg -n foo lib |\n  head -5">rg -n foo lib |</span><span class="activity-duration">7ms</span>' +
    `${commandBlockHtml(view)}<div class="activity-output" title="a">a</div>`), html);
});

test("turnHistoryHtml with parts: a failed call's row keeps its word after the params; its step is marked failed", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "", parts: { tools: [{ tool: "execute", params: 'command="ls /x"', output: "[execute]\nexit: 1" }] } },
    { role: "assistant", content: "Done." },
  ];
  const failed = normalizeTiming({
    turn_records: [{ id: "T1", status: "completed", duration_ms: 900 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "error", duration_ms: 15 }],
  });
  const html = turnHistoryHtml(items, failed, { thumbs });
  assert.match(html, /<div class="activity-row" data-key="1:1"><span class="activity-status error" role="img" aria-label="error" title="error"><\/span>/);
  assert.match(html, /<span class="activity-params">command=&quot;ls \/x&quot;<\/span><span class="activity-state error">error<\/span><span class="activity-duration">15ms<\/span>/);
  // The step says so, with the red-chevron class, and the block's bare count too (under 3 calls).
  assert.match(html, /<details class="turn-work done"><summary>1 step · 1 tool call \(1 failed\)<\/summary><details class="gen has-failed"><summary>working with execute · 1 tool call \(1 failed\)<\/summary>/);
});

test("turnHistoryHtml: a task_wait titled by its task's command shows it, its id line on hover", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "", parts: { tools: [{ tool: "task_wait", params: 'id="t1" timeout="600"', title: "bundle exec rspec · up to 600s", output: "[task_wait]\nstatus: completed", view: { task_id: "t1" } }] } },
    { role: "assistant", content: "Done." },
  ];
  const html = turnHistoryHtml(items, timing, { thumbs });
  assert.match(html, /<span class="activity-tool">task_wait<\/span><span class="activity-params" title="id=&quot;t1&quot; timeout=&quot;600&quot;">bundle exec rspec · up to 600s<\/span>/);
});

test("turnHistoryHtml: a context wake turn starts with its note (turn_start): the note bubble, then its own answer and timing", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "PONG" },
    { role: "note", content: "Updated: pr-1.", label: "context pr-1", turn_start: true, turn_id: "T2" },
    { role: "assistant", content: "Bob asked for changes." },
  ];
  const two = normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 500 }, { id: "T2", duration_ms: 2000 }] });
  assert.equal(turnHistoryHtml(items, two, { thumbs }),
    '<div class="bubble user" data-copy-source="p"><div class="user-message">p</div></div>' +
    '<div class="bubble output">PONG</div><div class="turn-timing">turn 1 · 0.5s</div>' +
    '<div class="bubble note"><div class="note-line">note from context pr-1</div><div class="note-text">Updated: pr-1.</div></div>' +
    '<div class="bubble output">Bob asked for changes.</div><div class="turn-timing">turn 2 · 2.0s</div>');
});

test("turnHistoryHtml: a failed turn whose steps stayed ends with the live failure line, after its timing; its texts stay steps", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Checking.", parts: { tools: [{ tool: "execute", params: 'command="true"', output: "exit: 0" }] } },
    { role: "assistant", content: "Now the tests." },
  ];
  const failure = { summary: "402 Payment Required (openrouter)", kept_steps: 1 };
  const failed = normalizeTiming({
    turn_records: [{ id: "T1", status: "failed", duration_ms: 12000, failure }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 }],
  });
  const html = turnHistoryHtml(items, failed, { thumbs });
  assert.doesNotMatch(html, /bubble output/);
  assert.match(html, /Now the tests\./);
  // The live turn_failed's words (format.js failedTurnText), in the live class.
  const line = failedTurnText({ ...failure, kept_steps: 1 }).replace(/[()!]/g, "\\$&");
  assert.match(html, new RegExp(`<div class="turn-timing">turn 1 · 12s</div><div class="bubble cancel">${line}</div>$`));
  // A record from before failures were kept, or another end: no line.
  const bare = normalizeTiming({ turn_records: [{ id: "T1", status: "failed", duration_ms: 12000 }] });
  assert.doesNotMatch(turnHistoryHtml(items, bare, { thumbs }), /bubble cancel/);
});
