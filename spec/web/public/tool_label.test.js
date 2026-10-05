import test from "node:test";
import assert from "node:assert/strict";
import { newActivity, addStarted, addCompleted, toolName } from "../../../lib/samagotchi/web/public/activity.js";
import { tallyText } from "../../../lib/samagotchi/web/public/tally.js";
import { genLabel } from "../../../lib/samagotchi/web/public/turn_model.js";
import { snapshotEvents } from "../../../lib/samagotchi/web/public/turn_events.js";
import { turnHistoryHtml } from "../../../lib/samagotchi/web/public/turn_view.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";

// A plugin tool's label ("chrome: screenshot") stands for its raw name
// (mcp_chrome_screenshot) wherever a row, a step title or the tally names it.
const MCP = { tool: "mcp_chrome_screenshot", label: "chrome: screenshot" };

test("toolName: the label, else the tool, else 'tool'", () => {
  assert.equal(toolName(MCP), "chrome: screenshot");
  assert.equal(toolName({ tool: "execute" }), "execute");
  assert.equal(toolName({}), "tool");
});

test("a live row keeps the label from tool_call_started", () => {
  const model = newActivity();
  const { row } = addStarted(model, { iteration: 1, call_index: 1, ...MCP, params: "" });
  addCompleted(model, { iteration: 1, call_index: 1, tool: MCP.tool, output: "ok", activity: { status: "ok" } });
  assert.equal(row.label, "chrome: screenshot");
  assert.equal(row.tool, "mcp_chrome_screenshot");
});

test("the step title and the tally use the label", () => {
  const rows = [MCP, MCP, { tool: "execute" }];
  assert.equal(genLabel({ iteration: 1, thinking: "", text: "", tools: rows }), "working with chrome: screenshot, execute · 3 tool calls");
  assert.equal(tallyText(rows), "3 tool calls · chrome: screenshot ×2 · execute ×1 · last: execute");
});

test("a joined-mid-turn snapshot carries the label to the replayed row events", () => {
  const events = snapshotEvents({
    current_turn: { prompt: "p", origin: {}, parts: [{ kind: "tool", iteration: 1, call_index: 1, ...MCP, params: "", status: "ok", output: "x" }] },
  });
  const tools = events.filter((e) => e.type.startsWith("tool_call"));
  assert.deepEqual(tools.map((e) => e.label), ["chrome: screenshot", "chrome: screenshot"]);
});

test("a reloaded row and its step title show the label saved with the result", () => {
  const timing = normalizeTiming({
    turn_records: [{ id: "T1", status: "completed", duration_ms: 1000 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: MCP.tool, status: "ok", duration_ms: 5 }],
  });
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "", parts: { thinking: "t", tools: [{ ...MCP, params: "" }] } },
    { role: "assistant", content: "Done." },
  ];
  const html = turnHistoryHtml(items, timing, { thumbs: () => "" });
  assert.match(html, /<summary>working with chrome: screenshot · 1 tool call<\/summary>/);
  assert.match(html, /<span class="activity-tool">chrome: screenshot<\/span>/);
  assert.doesNotMatch(html, /mcp_chrome_screenshot/);
});

// Tool titles (the server's `title`: a project-relative path, a command
// without its "cd … &&") stand in for the params line where there is one.
test("a live row keeps the title from tool_call_started and the completed activity", () => {
  const model = newActivity();
  const { row } = addStarted(model, { iteration: 1, call_index: 1, tool: "execute", params: 'command="cd /x && ls"', title: "ls" });
  assert.equal(row.title, "ls");
  addCompleted(model, { iteration: 1, call_index: 1, tool: "execute", output: "ok", activity: { status: "ok", params: 'command="cd /x && ls"', title: "ls" } });
  assert.equal(row.title, "ls");
  const late = addCompleted(model, { iteration: 1, call_index: 2, tool: "read", output: "x", activity: { status: "ok", params: 'path="/p/a.rb"', title: "a.rb" } });
  assert.equal(late.title, "a.rb");
});

test("a step without narration is titled by its first call's title, else by its tools", () => {
  const rows = [{ tool: "edit", title: "lib/source_links.rb" }, { tool: "read", title: "lib/a.rb" }, { tool: "execute" }];
  assert.equal(genLabel({ iteration: 1, thinking: "", text: "", tools: rows }), "edit lib/source_links.rb · 3 tool calls");
  assert.equal(genLabel({ iteration: 1, thinking: "", text: "Let me look.", tools: rows }), "Let me look. · 3 tool calls");
  assert.equal(genLabel({ iteration: 1, thinking: "", text: "", tools: [{ tool: "execute" }, rows[0]] }), "working with execute, edit · 2 tool calls");
  const long = genLabel({ iteration: 1, thinking: "", text: "", tools: [{ tool: "execute", title: "y".repeat(100) }] });
  assert.equal(long, `execute ${"y".repeat(72)}… · 1 tool call`);
});

test("a joined-mid-turn snapshot replays the title on both row events", () => {
  const events = snapshotEvents({
    current_turn: { prompt: "p", origin: {}, parts: [{ kind: "tool", iteration: 1, call_index: 1, tool: "execute", params: "p", title: "ls", status: "ok", output: "x" }] },
  });
  const tools = events.filter((e) => e.type.startsWith("tool_call"));
  assert.equal(tools[0].title, "ls");
  assert.equal(tools[1].activity.title, "ls");
  const untitled = snapshotEvents({ current_turn: { prompt: "p", parts: [{ kind: "tool", iteration: 1, call_index: 1, tool: "x", params: "", status: "running" }] } });
  assert.equal("title" in untitled.find((e) => e.type === "tool_call_started"), false);
});

test("a reloaded row shows the saved title in place of the params, its step is titled by it", () => {
  const timing = normalizeTiming({
    turn_records: [{ id: "T1", status: "completed", duration_ms: 1000 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 5 }],
  });
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "", parts: { tools: [{ tool: "execute", params: 'command="cd /x && rspec"', title: "rspec" }] } },
    { role: "assistant", content: "Done." },
  ];
  const html = turnHistoryHtml(items, timing, { thumbs: () => "" });
  // The full params line stays on hover.
  assert.match(html, /<span class="activity-params" title="command=&quot;cd \/x &amp;&amp; rspec&quot;">rspec<\/span>/);
  assert.match(html, /<summary class="repeats"><span class="gen-head">execute rspec<\/span><span class="gen-sep"> · <\/span><span class="gen-calls">1 tool call<\/span><\/summary>/);
});
