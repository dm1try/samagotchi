import test from "node:test";
import assert from "node:assert/strict";
import {
  flashOf, handOffDue, handOffOrder, headlineOf, inUseFrom, isPlain, liveSlots, placeFor, plainHeadline, toolKind, trailFlashText, trailItemText, trailMark, trailTone,
} from "../../../lib/samagotchi/web/public/stage_model.js";
import { newTurn, takeAnswer } from "../../../lib/samagotchi/web/public/turn_model.js";
import { applyEvent } from "./turn_feed.js";

function turnOf(...events) {
  const turn = newTurn();
  applyEvent(turn, { type: "turn_started" });
  for (const e of events) applyEvent(turn, e);
  return turn;
}
const started = (it, ci, tool, title) => ({ type: "tool_call_started", iteration: it, call_index: ci, tool, params: `p${ci}`, ...(title ? { title } : {}) });
const done = (it, ci, tool, status = "ok") => ({ type: "tool_call_completed", iteration: it, call_index: ci, tool, output: "x", activity: { status } });

test("toolKind: read-like, edit, exec, other", () => {
  for (const t of ["read", "memory_read", "web_fetch", "task_get", "task_list", "list_sessions"]) assert.equal(toolKind(t), "read");
  for (const t of ["edit", "write", "memory_write"]) assert.equal(toolKind(t), "edit");
  for (const t of ["execute", "task_create", "task_wait", "task_stop", "delegate", "delegate_result"]) assert.equal(toolKind(t), "exec");
  assert.equal(toolKind("mcp_chrome_screenshot"), "other");
  assert.equal(toolKind(undefined), "other");
});

test("liveSlots: thinking first, headline from the thinking sentence, no tool yet", () => {
  const turn = turnOf({ type: "generation_chunk", iteration: 1, thinking: "Hmm. Let me see", text: "" });
  const slots = liveSlots(turn, { thinking: "Hmm." });
  assert.equal(slots.phase, "thinking");
  assert.equal(slots.step, 1);
  assert.deepEqual(slots.headline, { text: "Hmm.", thinking: true });
  assert.equal(slots.tool, null);
  assert.deepEqual(slots.trail, []);
  assert.deepEqual(slots.ticks, []);
});

test("liveSlots: narration wins the headline; a running tool is the tool row; the phase says so", () => {
  const turn = turnOf(
    { type: "generation_chunk", iteration: 1, thinking: "t.", text: "Let me look." },
    { type: "generation_completed" },
    started(1, 1, "execute", "rspec a"),
  );
  const slots = liveSlots(turn, { narration: "Let me look.", thinking: "t." });
  assert.equal(slots.phase, "running a tool");
  assert.deepEqual(slots.headline, { text: "Let me look.", thinking: false });
  assert.deepEqual(slots.tool, { name: "execute", title: "rspec a", kind: "exec" });
  assert.deepEqual(slots.ticks, [{ kind: "exec", status: "running", step: 0 }]);
});

test("trailItemText: the shown text and the hover — the command when there is one, else the whole line", () => {
  assert.deepEqual(trailItemText({ name: "read", title: "lib/a.rb", status: "ok" }),
    { text: "✓ read lib/a.rb", hover: "✓ read lib/a.rb" });
  assert.deepEqual(trailItemText({ name: "execute", title: "rspec", status: "ok", command: "cd x && rspec" }),
    { text: "✓ execute rspec", hover: "cd x && rspec" });
  assert.deepEqual(trailItemText({ name: "edit", title: "b.rb", status: "error" }),
    { text: "✕ edit b.rb", hover: "✕ edit b.rb" });
  assert.deepEqual(trailItemText({ name: "task_wait", title: "t1", status: "stopped" }),
    { text: "■ task_wait t1", hover: "■ task_wait t1" });
  // No title: the mark and the name only.
  assert.deepEqual(trailItemText({ name: "mcp_x", status: "ok" }), { text: "✓ mcp_x", hover: "✓ mcp_x" });
});

test("trailFlashText: the whole flash line, shown and hovered", () => {
  assert.deepEqual(trailFlashText({ kind: "warn", text: "rate limit soon" }, "⚠"),
    { text: "⚠ rate limit soon", hover: "⚠ rate limit soon" });
  assert.deepEqual(trailFlashText({ kind: "info", text: "memory saved" }, "ℹ"),
    { text: "ℹ memory saved", hover: "ℹ memory saved" });
});

test("liveSlots: the trail is the last three finished calls, newest last, a file's title without its dir", () => {
  const turn = turnOf(
    started(1, 1, "read", "lib/a.rb"), done(1, 1, "read"),
    started(1, 2, "edit", "lib/web/b.rb"), done(1, 2, "edit", "error"),
    { type: "generation_started", iteration: 2 },
    started(2, 1, "execute", "cd x && rspec spec/c_spec.rb"), done(2, 1, "execute"),
    started(2, 2, "mcp_x"), done(2, 2, "mcp_x"),
    started(2, 3, "read", "lib/d.rb"),
  );
  const slots = liveSlots(turn);
  assert.deepEqual(slots.trail, [
    { name: "edit", title: "b.rb", status: "error" },
    { name: "execute", title: "cd x && rspec spec/c_spec.rb", status: "ok" },
    { name: "mcp_x", title: "p2", status: "ok" },
  ]);
  assert.equal(slots.step, 2);
  assert.deepEqual(slots.ticks.map((t) => [t.kind, t.status, t.step]), [
    ["read", "ok", 0], ["edit", "error", 0], ["exec", "ok", 1], ["other", "ok", 1], ["read", "running", 1],
  ]);
  assert.deepEqual(slots.tool, { name: "read", title: "lib/d.rb", kind: "read" });
});

test("liveSlots: writing while the step's narration streams, waiting for you with a card, the end phases", () => {
  const writing = turnOf({ type: "generation_chunk", iteration: 1, thinking: "t", text: "Let me" });
  assert.equal(liveSlots(writing).phase, "writing");
  const plain = turnOf({ type: "generation_chunk", iteration: 1, text: "Hello" });
  assert.equal(liveSlots(plain).phase, "writing the answer");
  assert.equal(liveSlots(plain, { pending: true }).phase, "waiting for you");
  assert.equal(liveSlots(plain, { ended: "completed" }).phase, "answered");
  assert.equal(liveSlots(plain, { ended: "canceled" }).phase, "canceled");
  assert.equal(liveSlots(plain, { ended: "failed" }).phase, "failed");
  assert.equal(liveSlots(plain, { ended: "gone" }).phase, "failed");
  assert.deepEqual(liveSlots(newTurn()).headline, { text: "…", thinking: false });
});

test("liveSlots: the now row's quiet word while no call runs, none once the turn has ended", () => {
  const thinking = turnOf({ type: "generation_chunk", iteration: 1, thinking: "Hmm." });
  assert.equal(liveSlots(thinking).quiet, "thinking…");
  const writing = turnOf({ type: "generation_chunk", iteration: 1, thinking: "t", text: "Let me" });
  assert.equal(liveSlots(writing).quiet, "writing…");
  for (const ended of ["completed", "canceled", "failed"]) {
    assert.equal(liveSlots(thinking, { ended }).quiet, "", ended);
    assert.equal(liveSlots(writing, { ended }).quiet, "", ended);
  }
});

test("liveSlots: at the end an answer-only step is no step (as the block summary counts)", () => {
  const turn = turnOf(started(1, 1, "read"), done(1, 1, "read"), { type: "generation_started", iteration: 2 }, { type: "generation_chunk", iteration: 2, text: "Done." });
  assert.equal(liveSlots(turn).step, 2);
  applyEvent(turn, { type: "turn_completed" });
  takeAnswer(turn, turn.gens[1]);
  assert.equal(liveSlots(turn, { ended: "completed" }).step, 1);
});

test("liveSlots: a completed turn with no answer (turn_summary.empty_answer) reads no answer, not answered", () => {
  const turn = turnOf({ type: "generation_chunk", iteration: 1, thinking: "Hmm." });
  applyEvent(turn, { type: "turn_completed" });
  assert.equal(liveSlots(turn, { ended: "completed", emptyAnswer: true }).phase, "no answer");
  assert.equal(liveSlots(turn, { ended: "completed" }).phase, "answered");
  // Only a completed turn: a canceled or failed one keeps its own word.
  assert.equal(liveSlots(turn, { ended: "canceled", emptyAnswer: true }).phase, "canceled");
  assert.equal(liveSlots(turn, { ended: "failed", emptyAnswer: true }).phase, "failed");
  // Not over yet: the flag means nothing.
  assert.equal(liveSlots(turn, { emptyAnswer: true }).phase, "thinking");
});

test("trailTone: error and blocked red, stopped amber, as their rows; ok and unknown none", () => {
  assert.equal(trailTone("error"), "error");
  assert.equal(trailTone("blocked"), "blocked");
  assert.equal(trailTone("stopped"), "stopped");
  assert.equal(trailTone("ok"), "");
  assert.equal(trailTone(undefined), "");
});

test("isPlain: one step, no thinking, no tool rows, not over", () => {
  assert.equal(isPlain(turnOf({ type: "generation_chunk", iteration: 1, text: "Hi" })), true);
  assert.equal(isPlain(turnOf()), true);
  assert.equal(isPlain(turnOf({ type: "generation_chunk", iteration: 1, thinking: "t", text: "" })), false);
  assert.equal(isPlain(turnOf(started(1, 1, "read"))), false);
  assert.equal(isPlain(turnOf({ type: "generation_chunk", iteration: 1, text: "a" }, { type: "generation_started", iteration: 2 }, { type: "generation_chunk", iteration: 2, text: "b" })), false);
  assert.equal(isPlain(null), false);
});

test("inUseFrom: pointer, focus, selection, or a touch/scroll in the last 4 s", () => {
  const base = { pointerIn: false, lastTouchMs: 0, focusInside: false, selectionInside: false, nowMs: 100000 };
  assert.equal(inUseFrom(base), false);
  assert.equal(inUseFrom({ ...base, pointerIn: true }), true);
  assert.equal(inUseFrom({ ...base, focusInside: true }), true);
  assert.equal(inUseFrom({ ...base, selectionInside: true }), true);
  assert.equal(inUseFrom({ ...base, lastTouchMs: 96001 }), true);
  assert.equal(inUseFrom({ ...base, lastTouchMs: 96000 }), false);
});

test("handOffDue: 1.5 s not in use after the end, nothing pending; in use resets the quiet clock", () => {
  const at = (nowMs, over = {}) => handOffDue({ ended: true, pending: false, inUse: false, quietSinceMs: null, nowMs, ...over });
  assert.deepEqual(at(1000), { due: false, quietSinceMs: 1000 });
  assert.deepEqual(at(2400, { quietSinceMs: 1000 }), { due: false, quietSinceMs: 1000 });
  assert.deepEqual(at(2500, { quietSinceMs: 1000 }), { due: true, quietSinceMs: 1000 });
  assert.deepEqual(at(2500, { quietSinceMs: 1000, inUse: true }), { due: false, quietSinceMs: null });
  assert.deepEqual(at(2500, { quietSinceMs: 1000, pending: true }), { due: false, quietSinceMs: null });
  assert.deepEqual(at(2500, { quietSinceMs: 1000, ended: false }), { due: false, quietSinceMs: null });
});

test("handOffOrder: prompt, block, extras in arrival order, answer, timing, end line, kept cards", () => {
  const order = handOffOrder({ prompt: "P", block: "B", extras: ["x1", "x2"], answer: ["think", "A"], timing: "T", end: "E", kept: ["k1"] });
  assert.deepEqual(order, ["P", "B", "x1", "x2", "think", "A", "T", "E", "k1"]);
  // A reminder turn has no prompt bubble; a plain answer no block.
  assert.deepEqual(handOffOrder({ prompt: null, block: null, extras: [], answer: ["A"], timing: "T" }), ["A", "T"]);
});

test("placeFor: the stage's extras while a turn is live, else the history; the recap always the history", () => {
  assert.equal(placeFor({ live: true, handingOff: false, kind: "card" }), "stage");
  assert.equal(placeFor({ live: true, handingOff: true, kind: "card" }), "history");
  assert.equal(placeFor({ live: false, handingOff: false, kind: "command" }), "history");
  assert.equal(placeFor({ live: true, handingOff: false, kind: "recap" }), "history");
});

test("plainHeadline: markdown syntax out of a headline, the words kept", () => {
  assert.equal(plainHeadline("## Plan"), "Plan");
  assert.equal(plainHeadline("###### Deep"), "Deep");
  assert.equal(plainHeadline("| file | change |"), "file · change");
  assert.equal(plainHeadline("| settings.conf | **beta** to 3 |"), "settings.conf · beta to 3");
  assert.equal(plainHeadline("|---|---|"), "");
  assert.equal(plainHeadline("| :--- | ---: |"), "");
  assert.equal(plainHeadline("```ruby"), "");
  assert.equal(plainHeadline("~~~"), "");
  assert.equal(plainHeadline("---"), "");
  assert.equal(plainHeadline("I check **two files** and the `config` key, per [the docs](https://example.com/docs)."),
    "I check two files and the config key, per the docs.");
  assert.equal(plainHeadline("> - [x] done _now_, *really*"), "done now, really");
  assert.equal(plainHeadline("![a chart](chart.png) and <https://example.com/x>"), "a chart and https://example.com/x");
});

test("plainHeadline: mid-stream leftovers go, code-ish text stays", () => {
  assert.equal(plainHeadline("**Bold start"), "Bold start");
  assert.equal(plainHeadline("see [the docs](https://exa"), "see the docs");
  assert.equal(plainHeadline("snake_case_name and `__init__.py`, `**kwargs`"), "snake_case_name and __init__.py, **kwargs");
  assert.equal(plainHeadline("2 * 3 * 4 is 24"), "2 * 3 * 4 is 24");
  assert.equal(plainHeadline("use a || b here"), "use a || b here");
});

test("headlineOf: the newest sentence as plain text, syntax-only lines skipped", () => {
  const table = "## Plan\n\n| file | change |\n|---|---|\n";
  assert.equal(headlineOf(table, false), "file · change");
  assert.equal(headlineOf("Fixed it.\n```js\n", false), "Fixed it.");
  assert.equal(headlineOf("# Heading only", true), "Heading only");
  assert.equal(headlineOf("**Done**. Next: **more", false), "Done.");
  assert.equal(headlineOf("", false), "");
});

test("headlineOf: a line of code inside a fence is no headline, open or closed", () => {
  assert.equal(headlineOf("Here is the fix.\n```ruby\nputs value.inspect\n", false), "Here is the fix.");
  assert.equal(headlineOf("Here is the fix.\n```ruby\nputs value.inspect\nexit 1", true), "Here is the fix.");
  assert.equal(headlineOf("Here is the fix.\n```\nfoo. bar.\n```\n", false), "Here is the fix.");
  assert.equal(headlineOf("Before.\n~~~\ncode\n~~~\nAfter the block.\n", false), "After the block.");
  assert.equal(headlineOf("Before.\n```\ncode\n```\nand after", true), "and after");
});

test("flashOf: a hook's notice (warn or info) and a plugin's nudge flash; chi's asking-again row does not", () => {
  assert.deepEqual(flashOf("notice", { hook: "plugin.rb (bundle loop-guard)", text: "thinking repeats itself", level: "warn" }),
    { kind: "warn", text: "loop-guard: thinking repeats itself" });
  assert.deepEqual(flashOf("notice", { hook: "plugin.rb (bundle check-in)", text: "5 tool calls in this turn, no answer yet", level: "info" }),
    { kind: "info", text: "check-in: 5 tool calls in this turn, no answer yet" });
  assert.equal(flashOf("notice", { line: "↻ empty answer, asking again (1/1)" }), null);
  assert.deepEqual(flashOf("steer", { source: "check-in", text: "You've made 3 tool calls" }), { kind: "steer", text: "check-in nudged the model" });
  assert.deepEqual(flashOf("steer", {}), { kind: "steer", text: "nudged the model" });
});

test("flashOf: the applied LLM context edit's ✂ row flashes (its cls, the line without the ✂)", () => {
  assert.deepEqual(flashOf("notice", { line: "✂ forgot 2 outputs · frees ~4.1k tokens", cls: "llm-context", title: "the outputs" }),
    { kind: "edit", text: "forgot 2 outputs · frees ~4.1k tokens" });
  assert.deepEqual(flashOf("notice", { line: "✂ LLM context edited", cls: "llm-context", title: "x" }),
    { kind: "edit", text: "LLM context edited" });
  assert.deepEqual(flashOf("notice", { line: "context trimmed", cls: "llm-context" }),
    { kind: "edit", text: "context trimmed" });
  assert.equal(flashOf("notice", { line: "some other row", cls: "hook-notice" }), null);
});

test("flashOf: the steer-cut row (a message cut in on a thinking-only generation) flashes, its line without the leading ↪", () => {
  assert.deepEqual(flashOf("notice", { line: "↪ cut in for your message", cls: "steer-cut" }), { kind: "steer", text: "cut in for your message" });
  assert.deepEqual(flashOf("notice", { line: "↪ cut in for a message sent with chi send", cls: "steer-cut" }), { kind: "steer", text: "cut in for a message sent with chi send" });
  assert.deepEqual(flashOf("notice", { line: "cut in", cls: "steer-cut" }), { kind: "steer", text: "cut in" });
  assert.equal(flashOf("notice", { line: "", cls: "steer-cut" }), null);
});

test("liveSlots: the running tool and the trail carry a call's full command (for the hover), only when it has one", () => {
  const command = "cd /p && rg -n foo lib |\n  head -5";
  const turn = turnOf(
    { ...started(1, 1, "execute", "rg -n foo lib | head -5"), view: { command } }, done(1, 1, "execute"),
    started(1, 2, "read", "lib/a.rb"), done(1, 2, "read"),
    { ...started(1, 3, "task_create", "npm test"), view: { command: "npm test", cwd: "web" } },
  );
  const slots = liveSlots(turn);
  assert.deepEqual(slots.trail, [
    { name: "execute", title: "rg -n foo lib | head -5", status: "ok", command },
    { name: "read", title: "a.rb", status: "ok" },
  ]);
  assert.deepEqual(slots.tool, { name: "task_create", title: "npm test", kind: "exec", command: "npm test" });
});

test("liveSlots: a running task_wait's tool slot carries its task id (the stop-task button)", () => {
  const turn = turnOf({ ...started(1, 1, "task_wait"), params: 'id="20261004120000-0a1b2c3d"', view: { task_id: "20261004120000-0a1b2c3d" } });
  assert.deepEqual(liveSlots(turn).tool,
    { name: "task_wait", title: 'id="20261004120000-0a1b2c3d"', kind: "exec", taskId: "20261004120000-0a1b2c3d", key: "1:1" });
});

test("liveSlots: a task_wait titled by its task's command keeps its id line (the params) for the hover", () => {
  const turn = turnOf(
    { ...started(1, 1, "task_get", "npm test"), params: 'id="t1"' }, done(1, 1, "task_get"),
    { ...started(1, 2, "task_wait", "npm test · up to 600s"), params: 'id="t1" timeout="600"', view: { task_id: "t1" } },
  );
  const slots = liveSlots(turn);
  assert.deepEqual(slots.trail, [{ name: "task_get", title: "npm test", status: "ok", command: 'id="t1"' }]);
  assert.deepEqual(slots.tool,
    { name: "task_wait", title: "npm test · up to 600s", kind: "exec", command: 'id="t1" timeout="600"', taskId: "t1", key: "1:2" });
});

test("trailMark: a call a Stop cut is ■, not a failure's ✕", () => {
  assert.equal(trailMark("ok"), "✓");
  assert.equal(trailMark("error"), "✕");
  assert.equal(trailMark("blocked"), "✕");
  assert.equal(trailMark("stopped"), "■");
});
