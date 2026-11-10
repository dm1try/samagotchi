// A finished turn's drawing (turn_drawing.js; turn_block.js draws it):
// its fold into steps, and turnHistoryNodes' drawn branch for each kind of
// part, its overlays from the saved items and a card without a stored body.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { drawingTurn, drawnIds, drawnKind } from "../../../lib/samagotchi/web/public/turn_drawing.js";
import { turnGroups } from "../../../lib/samagotchi/web/public/timing.js";
import { turnHistoryNodes } from "../../../lib/samagotchi/web/public/turn_block.js";
import { historyShape } from "../../../lib/samagotchi/web/public/history_shape.js";

const started = { type: "turn_started", prompt: "hi", turn_id: "T1" };
const gen = (n) => ({ type: "generation_started", iteration: n });
const say = (n, text, thinking = "") => ({ type: "generation_chunk", iteration: n, text, thinking });
const row = (n) => [
  { type: "tool_call_started", iteration: n, call_index: 1, tool: "read", params: 'path="a"', title: "a", tool_id: "t1" },
  { type: "tool_call_completed", iteration: n, call_index: 1, tool: "read", tool_id: "t1", output: "x", duration_ms: 40, activity: { status: "ok" } },
];
const done = { type: "turn_completed", turn_id: "T1" };

function drawn(events, items, { end = done, cards = null } = {}) {
  const host = document.createElement("div");
  host.append(turnHistoryNodes(items, {}, { thumbs: () => null, drawings: { T1: { events, end } }, cards }));
  return host;
}

test("drawnKind reads the end event's type; drawingTurn folds the steps and rows as live", () => {
  assert.equal(drawnKind({ type: "turn_canceled" }), "canceled");
  assert.equal(drawnKind({}), "completed");
  const turn = drawingTurn({ events: [started, gen(1), say(1, "Look."), ...row(1), gen(2), say(2, "Done.")] });
  assert.equal(turn.gens.length, 2);
  assert.deepEqual(turn.gens[0].tools.map((r) => [r.tool, r.status, r.duration_ms]), [["read", "ok", 40]]);
  assert.deepEqual([...drawnIds([{ drawn: "T1" }, { drawn: "T9" }, {}], { T1: {} })], ["T1"]);
});

test("turnGroups makes a drawn turn's stamped items one group, a reminder turn's too, its steps the drawing's", () => {
  const items = [{ role: "user", content: "hi", turn_id: "T0", drawn: "T0" }, { role: "assistant", content: "a", drawn: "T0" },
    { role: "assistant", content: "Tea.", drawn: "T1" }];
  const drawings = { T0: { events: [started, gen(1), say(1, "a")], end: done }, T1: { events: [started, gen(1), say(1, "Tea.")], end: done } };
  const groups = turnGroups(items, {}, { drawings });
  assert.deepEqual(groups.map((g) => [g.kind, g.drawn ?? null, g.user]), [["turn", "T0", 0], ["turn", "T1", null]]);
  assert.equal(groups[1].answer, 2);
  assert.equal(groups[1].steps.length, 1);
  // A stamp with no drawing sent is no stamp: plain rows.
  assert.deepEqual(turnGroups(items, {}).map((g) => g.kind), ["plain", "plain", "plain"]);
});

// The steer's step is the answer's, which leaves the block: the steer
// leaves with it, before the answer (as live's promote).
test("a drawn turn's notice stays in its step, a reminder is its bubble, a steer goes where live put it", () => {
  const events = [started, { type: "reminder_injected", reminders: [{ name: "tea" }] }, gen(1), say(1, "", "hmm"),
    { type: "empty_answer_retry", iteration: 1, attempt: 1, of: 1 }, ...row(1),
    { type: "pending_input_merged", count: 0, content: null, steers: [{ source: "check-in", text: "go on" }] },
    gen(2), say(2, "Done.")];
  const items = [{ role: "user", content: "hi", turn_id: "T1", drawn: "T1" }, { role: "assistant", content: "Done.", drawn: "T1" }];
  const shape = historyShape(drawn(events, items));
  assert.deepEqual(shape.map((it) => it.kind), ["prompt", "block", "step", "notice", "row", "command", "steer", "answer"]);
  assert.equal(shape.find((it) => it.kind === "command").text, "reminder: tea");
});

test("the answer and the steps' texts take their items' markdown; a row its tool's mark only from the drawing", () => {
  const events = [started, gen(1), say(1, "Look **here**."), ...row(1), gen(2), say(2, "**Done**.")];
  const items = [{ role: "user", content: "hi", turn_id: "T1", drawn: "T1" },
    { role: "assistant", content: "Look **here**.", html: "<p>Look <b>here</b>.</p>", drawn: "T1", marks: { t1: { kind: "forgot" } } },
    { role: "assistant", content: "**Done**.", html: "<p><b>Done</b>.</p>", drawn: "T1" }];
  const host = drawn(events, items);
  assert.equal(host.querySelector(".bubble.output").innerHTML, "<p><b>Done</b>.</p>");
  assert.equal(host.querySelector(".bubble.output").dataset.answerTurn, "T1");
  assert.equal(host.querySelector(".gen > .gen-text.markdown").getAttribute("data-copy-source"), "Look **here**.");
  assert.ok([...host.children].every((el) => el.dataset.drawn === "T1"));
});

test("a drawn card that asked sits beside the block; the drawing's own copy (no stored card) has its buttons off", () => {
  const card = { type: "card", in_turn: true, id: "check-in", source: "check-in", title: "Check in", body: "still?", level: "info",
    actions: [{ label: "Nudge", command: "/check-in nudge" }] };
  const events = [started, gen(1), say(1, "Work."), ...row(1), card, gen(2), say(2, "Done.")];
  const items = [{ role: "user", content: "hi", turn_id: "T1", drawn: "T1" }, { role: "assistant", content: "Work.", drawn: "T1" },
    { role: "assistant", content: "Done.", drawn: "T1" }];
  const host = drawn(events, items);
  const el = host.querySelector(":scope > .plugin-card");
  assert.ok(el);
  assert.match(el.textContent, /still\?/);
  assert.ok([...el.querySelectorAll(".card-action")].every((b) => b.disabled));
  assert.deepEqual(historyShape(host).map((it) => it.kind), ["prompt", "block", "step", "row", "card", "answer"]);
});

test("a canceled drawn turn ends with its cancel line, a failed one with its failure", () => {
  const events = [started, gen(1), say(1, "Start."), ...row(1), gen(2), say(2, "Half")];
  const items = [{ role: "user", content: "hi", turn_id: "T1", drawn: "T1" }, { role: "assistant", content: "Start.", drawn: "T1" },
    { role: "assistant", content: "Half", drawn: "T1" }];
  const canceled = historyShape(drawn(events, items, { end: { type: "turn_canceled", turn_id: "T1", cancellation_reason: "user" } }));
  assert.deepEqual(canceled.slice(-1), [{ kind: "cancel", cls: "", text: "■ canceled (stopped)" }]);
  const failed = historyShape(drawn(events.slice(0, -2), items.slice(0, 2),
    { end: { type: "turn_failed", turn_id: "T1", summary: "server down", kept_steps: 1 } }));
  assert.equal(failed[failed.length - 1].kind, "failed");
});

test("a wake's note just before the range (its id the drawn turn's) opens the drawn turn: one group, one timing", () => {
  const items = [{ role: "note", turn_start: true, turn_id: "T1", content: "task done" }, { role: "assistant", content: "Ran.", drawn: "T1" }];
  const groups = turnGroups(items, {}, { drawings: { T1: { events: [started, gen(1), say(1, "Ran.")], end: done } } });
  assert.deepEqual(groups.map((g) => [g.drawn, g.user]), [["T1", 0]]);
  const shape = historyShape(drawn([started, gen(1), say(1, "Ran.")], items));
  assert.deepEqual(shape.map((it) => it.kind), ["note", "answer"]);
});

test("a drawn card CardStore still lists keeps its buttons as CardStore gives them, and its latest body", () => {
  const card = { type: "card", in_turn: true, id: "go", source: "b", title: "Go on?", body: "first", level: "info",
    actions: [{ label: "Go", command: "/go" }] };
  const events = [started, gen(1), say(1, "Work."), ...row(1), card, gen(2), say(2, "Done.")];
  const items = [{ role: "user", content: "hi", turn_id: "T1", drawn: "T1" }, { role: "assistant", content: "Work.", drawn: "T1" },
    { role: "assistant", content: "Done.", drawn: "T1" }];
  const stored = [{ ...card, body: "latest" }];
  const el = drawn(events, items, { cards: stored }).querySelector(":scope > .plugin-card");
  assert.match(el.textContent, /latest/);
  assert.ok([...el.querySelectorAll(".card-action")].length === 1);
  assert.ok([...el.querySelectorAll(".card-action")].every((b) => !b.disabled));
  const dead = drawn(events, items, { cards: [{ ...card, actions: [] }] }).querySelector(".plugin-card");
  assert.equal(dead.querySelectorAll(".card-action").length, 0);
});

// H3 P5: chi web draws every finished turn, so the page groups by stamps
// only and an unstamped turn item (a bug, or a cover that failed) is a
// plain row of its text, logged once, never rebuilt into steps.
test("turnGroups groups by stamps only: unstamped turn items are plain rows, never a turn rebuilt from records", () => {
  const items = [{ role: "user", content: "hi", turn_id: "T0" }, { role: "assistant", content: "Looking." },
    { role: "steer", content: "go on", source: "check-in", step: 1 }, { role: "assistant", content: "Done." },
    { role: "note", content: "a note" }, { role: "assistant", content: "Tea.", drawn: "T1" }];
  const timing = { turnRecords: [{ id: "T0", status: "completed", duration_ms: 5 }],
    toolRecords: [{ turn_id: "T0", iteration: 1, tool: "read", status: "ok" }] };
  const groups = turnGroups(items, timing, { drawings: { T1: { events: [started, gen(1), say(1, "Tea.")], end: done } } });
  assert.deepEqual(groups.map((g) => [g.kind, g.i ?? g.drawn]), [["plain", 0], ["plain", 1], ["plain", 2], ["plain", 3], ["note", 4], ["turn", "T1"]]);
  assert.ok(groups.slice(0, 4).every((g) => !g.steps && !g.record && !g.running));
  // The running turn's items (never drawn yet: its line comes at its end) are plain and expected.
  const running = turnGroups(items.slice(0, 2), timing, { runningTurnId: "T0" });
  assert.deepEqual(running.map((g) => [g.kind, g.running]), [["plain", true], ["plain", true]]);
});

test("an unstamped turn item draws as a plain text row, marked undrawn, with one console.warn; the running turn's don't warn", () => {
  const items = [{ role: "user", content: "hi", turn_id: "T0" }, { role: "assistant", content: "Hello.", html: "<p>Hello.</p>" },
    { role: "assistant", content: "" }, { role: "empty_answer", content: "", retries: 0 }];
  const warned = [];
  const warn = console.warn;
  console.warn = (...args) => warned.push(args);
  try {
    const host = document.createElement("div");
    host.append(turnHistoryNodes(items, {}, { thumbs: () => null, drawings: {} }));
    // The prompt, the answer, the empty answer's notice: the text-less step has nothing to show.
    assert.deepEqual([...host.children].map((el) => [".bubble.user", ".bubble.output", ".empty-answer"].findIndex((sel) => el.matches(sel))), [0, 1, 2]);
    assert.ok(host.querySelector(".turn-work") === null);
    assert.equal(host.querySelector(".bubble.output").innerHTML, "<p>Hello.</p>");
    assert.ok([...host.children].every((el) => el.dataset.undrawn === "1"));
    assert.equal(warned.length, 1);
    const live = document.createElement("div");
    live.append(turnHistoryNodes(items.slice(0, 1), {}, { thumbs: () => null, drawings: {}, runningTurnId: "T0" }));
    assert.equal(live.querySelector(".bubble.user").textContent.trim(), "hi");
    assert.ok(live.querySelector("[data-undrawn]") === null);
    assert.equal(warned.length, 1);
  } finally {
    console.warn = warn;
  }
});

test("a drawn turn whose drawing has no parts (a minimal line) draws its prompt, its answer and its end", () => {
  const items = [{ role: "user", content: "hi", turn_id: "T1", drawn: "T1" }, { role: "assistant", content: "Tea.", drawn: "T1" }];
  const shape = historyShape(drawn([started], items));
  assert.deepEqual(shape.map((it) => it.kind), ["prompt"]);
  const canceled = historyShape(drawn([started], items, { end: { type: "turn_canceled", turn_id: "T1", cancellation_reason: "user" } }));
  assert.deepEqual(canceled.map((it) => it.kind), ["prompt", "cancel"]);
});

// Each kind of row a reload draws, from a drawing made from the messages
// (spec/shared/turn_drawings/row_kinds.json's synth show): what the
// deleted message-rebuild tests pinned on reloaded rows.
test("a turn made from its messages draws each kind of row as live: stopped, blocked, auto-allowed, no match, alias, via, images, diff, failed", async () => {
  const { readFileSync } = await import("node:fs");
  const { synth } = JSON.parse(readFileSync(new URL("../../shared/turn_drawings/row_kinds.json", import.meta.url), "utf8"));
  const host = document.createElement("div");
  host.append(turnHistoryNodes(synth.messages, {}, { thumbs: (images) => (images?.length ? images.map((i) => i.name).join(",") : ""), drawings: synth.turn_drawings }));
  // Each row's markup without lit's comment markers.
  const rows = [...host.querySelectorAll(".activity-row")].map((el) => el.outerHTML.replace(/<!--[^>]*-->/g, ""));
  assert.equal(rows.length, 9);
  assert.match(rows[0], /activity-status stopped.*task_wait.*activity-state stopped/);
  assert.match(rows[1], /activity-status blocked.*activity-state blocked/);
  assert.match(rows[2], /auto-allowed · System 1/);
  assert.match(rows[3], /no match/);
  assert.match(rows[4], /\(called as bash\)/);
  assert.match(rows[5], /\(via call_tool\)/);
  assert.match(rows[6], /s\.png/);
  assert.match(rows[7], /class="activity-diff"/);
  assert.match(rows[8], /activity-status error.*activity-state error/);
  assert.ok(host.querySelector("[data-undrawn]") === null);
});
