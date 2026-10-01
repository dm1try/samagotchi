import test from "node:test";
import assert from "node:assert/strict";
import { blockSummary, currentGen, genLabel, newTurn, notice, takeAnswer } from "../../../lib/samagotchi/web/public/turn_model.js";
import { applyEvent } from "./turn_feed.js";
import { snapshotEvents } from "../../../lib/samagotchi/web/public/turn_events.js";

const feed = (events, turn = newTurn()) => {
  const log = [];
  for (const event of events) {
    const r = applyEvent(turn, event);
    if (r?.closed) log.push(`close:${r.closed.iteration}`);
    if (r?.opened) log.push(`open:${r.gen.iteration}`);
  }
  return { turn, log };
};
const shape = (gen) => ({ iteration: gen.iteration, thinking: gen.thinking, text: gen.text, tools: gen.tools.map((r) => `${r.tool}:${r.status}`), closed: gen.closed });

// The kernel's live order: started, chunks, completed, then the tool rows.
const LIVE = [
  { type: "turn_started", prompt: "p" },
  { type: "generation_started", iteration: 1 },
  { type: "generation_chunk", iteration: 1, text: "", thinking: "hmm " },
  { type: "generation_chunk", iteration: 1, text: "\nLet me look.", thinking: "" },
  { type: "generation_completed", iteration: 1 },
  { type: "tool_call_started", iteration: 1, call_index: 1, tool: "execute", params: "command=\"true\"" },
  { type: "tool_call_completed", iteration: 1, call_index: 1, tool: "execute", output: "exit: 0", activity: { status: "ok" } },
  { type: "generation_started", iteration: 2 },
  { type: "generation_chunk", iteration: 2, text: "", thinking: "read it\n" },
  { type: "generation_completed", iteration: 2 },
  { type: "tool_call_started", iteration: 2, call_index: 1, tool: "read", params: "path=\"a\"" },
  { type: "tool_call_completed", iteration: 2, call_index: 1, tool: "read", output: "x", activity: { status: "ok" } },
  { type: "generation_started", iteration: 3 },
  { type: "generation_chunk", iteration: 3, text: "", thinking: "done" },
  { type: "generation_chunk", iteration: 3, text: "All good.", thinking: "" },
  { type: "generation_completed", iteration: 3 },
  { type: "turn_completed" },
];

test("a live 3-iteration turn: one gen per iteration, the first opened by turn_started", () => {
  const { turn, log } = feed(LIVE);
  assert.deepEqual(turn.gens.map(shape), [
    { iteration: 1, thinking: "hmm", text: "Let me look.", tools: ["execute:ok"], closed: true },
    { iteration: 2, thinking: "read it", text: "", tools: ["read:ok"], closed: true },
    { iteration: 3, thinking: "done", text: "All good.", tools: [], closed: true },
  ]);
  // turn_started opens the first gen (no iteration yet); generation_started(1) takes it over.
  assert.deepEqual(log, ["open:null", "close:1", "open:2", "close:2", "open:3", "close:3"]);
  assert.equal(currentGen(turn), null);
  assert.equal(turn.ended, true);
});

test("the tool rows of a gen arrive after its generation_completed and stay with it", () => {
  const { turn } = feed(LIVE.slice(0, 8));
  assert.equal(turn.gens.length, 2);
  assert.equal(turn.gens[0].textDone, true);
  assert.deepEqual(turn.gens[0].tools.map((r) => r.key), ["1:1"]);
  assert.equal(currentGen(turn), turn.gens[1]);
});

test("the replay of a 3-iteration snapshot groups like the live stream", () => {
  const snapshot = { current_turn: { prompt: "p", parts: [
    { kind: "thinking", iteration: 1, text: "hmm" },
    { kind: "text", iteration: 1, text: "Let me look." },
    { kind: "tool", iteration: 1, call_index: 1, tool: "execute", params: "command=\"true\"", status: "ok", output: "exit: 0" },
    { kind: "thinking", iteration: 2, text: "read it" },
    { kind: "tool", iteration: 2, call_index: 1, tool: "read", params: "path=\"a\"", status: "running" },
    { kind: "thinking", iteration: 3, text: "do" },
  ] } };
  const events = snapshotEvents(snapshot);
  assert.deepEqual(events.slice(1, 3), [
    { type: "generation_chunk", text: "", thinking: "hmm", iteration: 1 },
    { type: "generation_chunk", text: "Let me look.", thinking: "", iteration: 1 },
  ]);
  const { turn } = feed(events);
  assert.deepEqual(turn.gens.map(shape), [
    { iteration: 1, thinking: "hmm", text: "Let me look.", tools: ["execute:ok"], closed: true },
    { iteration: 2, thinking: "read it", text: "", tools: ["read:running"], closed: true },
    { iteration: 3, thinking: "do", text: "", tools: [], closed: false },
  ]);
});

test("a replay from an older server (no iteration on chunks): a chunk after tool rows opens a new gen", () => {
  const { turn } = feed([
    { type: "turn_started", prompt: "p" },
    { type: "generation_chunk", text: "", thinking: "one" },
    { type: "tool_call_started", iteration: 1, call_index: 1, tool: "execute", params: "" },
    { type: "tool_call_completed", iteration: 1, call_index: 1, tool: "execute", output: "", activity: { status: "ok" } },
    // The text-less iteration got no generation_completed; its thinking still starts a new gen.
    { type: "generation_chunk", text: "", thinking: "two" },
    { type: "tool_call_started", iteration: 2, call_index: 1, tool: "read", params: "" },
    { type: "generation_chunk", text: "Answer", thinking: "" },
  ]);
  assert.deepEqual(turn.gens.map(shape), [
    { iteration: 1, thinking: "one", text: "", tools: ["execute:ok"], closed: true },
    { iteration: 2, thinking: "two", text: "", tools: ["read:running"], closed: true },
    { iteration: null, thinking: "", text: "Answer", tools: [], closed: false },
  ]);
});

test("a chunk after generation_completed without an iteration opens a new gen", () => {
  const { turn } = feed([
    { type: "turn_started", prompt: "p" },
    { type: "generation_chunk", text: "one", thinking: "" },
    { type: "generation_completed" },
    { type: "generation_chunk", text: "two", thinking: "" },
  ]);
  assert.deepEqual(turn.gens.map((g) => [g.text, g.closed]), [["one", true], ["two", false]]);
});

test("a canceled turn mid-generation closes the current gen in place with its text", () => {
  const { turn, log } = feed([...LIVE.slice(0, 10), { type: "turn_canceled", cancellation_reason: "manual" }]);
  assert.equal(turn.gens.length, 2);
  assert.equal(turn.gens[1].closed, true);
  assert.equal(turn.gens[1].thinking, "read it");
  assert.equal(log.at(-1), "close:2");
  assert.equal(turn.ended, true);
});

test("a plain answer is one gen with text only; a tool-only generation is one with rows only", () => {
  const plain = feed([
    { type: "turn_started", prompt: "p" },
    { type: "generation_started", iteration: 1 },
    { type: "generation_chunk", iteration: 1, text: "PONG", thinking: "" },
    { type: "generation_completed", iteration: 1 },
    { type: "turn_completed" },
  ]).turn;
  assert.deepEqual(plain.gens.map(shape), [{ iteration: 1, thinking: "", text: "PONG", tools: [], closed: true }]);
  assert.equal(plain.plainAnswer, true);
  const toolOnly = feed([
    { type: "turn_started", prompt: "p" },
    { type: "generation_started", iteration: 1 },
    { type: "generation_completed", iteration: 1 },
    { type: "tool_call_started", iteration: 1, call_index: 1, tool: "execute", params: "" },
    { type: "tool_call_completed", iteration: 1, call_index: 1, tool: "execute", output: "", activity: { status: "error" } },
    { type: "turn_completed" },
  ]).turn;
  assert.deepEqual(toolOnly.gens.map(shape), [{ iteration: 1, thinking: "", text: "", tools: ["execute:error"], closed: true }]);
  assert.equal(toolOnly.plainAnswer, false);
  assert.equal(feed(LIVE).turn.plainAnswer, false);
});

test("retrying, cancelled generations, dispatch and merged input are no-ops", () => {
  const { turn, log } = feed([
    { type: "turn_started", prompt: "p" },
    { type: "generation_started", iteration: 1 },
    { type: "generation_retrying", iteration: 1 },
    { type: "generation_cancelled", iteration: 1 },
    { type: "tool_dispatch_started", iteration: 1 },
    { type: "tool_dispatch_completed", iteration: 1 },
    { type: "pending_input_merged", iteration: 2, content: "also" },
    { type: "merged_input", content: "also" },
    { type: "reminder_injected" },
  ]);
  assert.equal(turn.gens.length, 1);
  assert.deepEqual(log, ["open:null"]);
});

test("a duplicate tool_call_started (a replay overlap) updates its row instead of adding one", () => {
  const { turn } = feed([
    ...LIVE.slice(0, 6),
    { type: "tool_call_started", iteration: 1, call_index: 1, tool: "execute", params: "command=\"true\"" },
    LIVE[6],
  ]);
  assert.deepEqual(turn.gens[0].tools.map((r) => `${r.key}:${r.status}`), ["1:1:ok"]);
});

test("genLabel: the narration's first line, else the tools, else thinking", () => {
  const gen = (o) => ({ iteration: 1, thinking: "", text: "", tools: [], ...o });
  assert.equal(genLabel(gen({ text: "Let me look.\nMore." })), "Let me look.");
  assert.equal(genLabel(gen({ text: "  Let me look.", tools: [{ tool: "execute" }] })), "Let me look. · 1 tool call");
  assert.equal(genLabel(gen({ tools: [{ tool: "execute" }, { tool: "read" }, { tool: "execute" }] })), "working with execute, read · 3 tool calls");
  assert.equal(genLabel(gen({ tools: ["a", "b", "c", "d"].map((tool) => ({ tool })) })), "working with a, b, c, … · 4 tool calls");
  assert.equal(genLabel(gen({ thinking: "just thinking" })), "thinking");
  assert.equal(genLabel(gen({ text: `${"x".repeat(100)} y` })), `${"x".repeat(80).trimEnd()}…`);
});

test("blockSummary counts steps and tool calls, with the tally from 3 calls", () => {
  const { turn } = feed(LIVE);
  assert.equal(blockSummary(turn), "3 steps · 2 tool calls");
  assert.equal(blockSummary(feed(LIVE.slice(0, 8)).turn, { running: true }), "working · 2 steps · 1 tool call");
  const heavy = feed([
    { type: "turn_started", prompt: "p" },
    ...[1, 2, 3, 4].flatMap((i) => [
      { type: "generation_started", iteration: i },
      { type: "tool_call_started", iteration: i, call_index: 1, tool: i < 4 ? "execute" : "read", params: "" },
      { type: "tool_call_completed", iteration: i, call_index: 1, tool: i < 4 ? "execute" : "read", output: "", activity: { status: i === 2 ? "error" : "ok" } },
    ]),
  ]).turn;
  assert.equal(blockSummary(heavy, { running: true }), "working · 4 steps · 4 tool calls (1 failed) · execute ×3 · read ×1");
  assert.equal(blockSummary(feed([{ type: "turn_started", prompt: "p" }]).turn, { running: true }), "working · 1 step");
});

test("blockSummary: an answer that moved out of the block is no step unless its thinking stays behind", () => {
  const events = (thinking) => [
    { type: "turn_started", prompt: "p" },
    { type: "generation_started", iteration: 1 },
    { type: "tool_call_started", iteration: 1, call_index: 1, tool: "execute", params: "" },
    { type: "tool_call_completed", iteration: 1, call_index: 1, tool: "execute", output: "", activity: { status: "ok" } },
    { type: "generation_started", iteration: 2 },
    { type: "generation_chunk", iteration: 2, thinking, text: "Done." },
    { type: "generation_completed", iteration: 2 },
    { type: "turn_completed" },
  ];
  const plain = feed(events("")).turn;
  takeAnswer(plain, plain.gens[1]);
  assert.equal(blockSummary(plain), "1 step · 1 tool call");
  const thought = feed(events("hm")).turn;
  takeAnswer(thought, thought.gens[1]);
  assert.equal(blockSummary(thought), "2 steps · 1 tool call");
});

test("a live gen's thinking starts at its first visible character; later whitespace stays", () => {
  const { turn } = feed([
    { type: "turn_started", prompt: "p" },
    { type: "generation_started", iteration: 1 },
    { type: "generation_chunk", iteration: 1, text: "", thinking: "\n" },
    { type: "generation_chunk", iteration: 1, text: "", thinking: " \nFirst" },
    { type: "generation_chunk", iteration: 1, text: "", thinking: " line.\n\nSecond" },
  ]);
  assert.equal(currentGen(turn).thinking, "First line.\n\nSecond");
});

// A hook's notice (before_tool_call hooks run before tool_call_started) lands
// in the current step, ahead of the call it judged; with no running turn it
// has no step (the page shows it as a bubble).
test("notice: a hook's line goes to the current gen, before its tool row; none once the turn ended", () => {
  const { turn } = feed(LIVE.slice(0, 5));
  const r = notice(turn, { hook: "x.rb (bundle known-names)", text: "saw it", level: "warn" });
  assert.equal(r.gen, currentGen(turn));
  assert.deepEqual(r.gen.notices, [{ hook: "x.rb (bundle known-names)", text: "saw it", level: "warn" }]);
  feed(LIVE.slice(5, 7), turn);
  assert.equal(turn.gens[0].tools.length, 1);
  assert.equal(blockSummary(turn), "1 step · 1 tool call");
  assert.equal(genLabel(turn.gens[0]), "Let me look. · 1 tool call");
  applyEvent(turn, { type: "turn_completed" });
  assert.equal(notice(turn, { hook: "h", text: "late" }), null);
  assert.equal(notice(null, { hook: "h", text: "none" }), null);
});

test("notice: a new gen starts with no notices", () => {
  const { turn } = feed(LIVE.slice(0, 2));
  assert.deepEqual(currentGen(turn).notices, []);
});
