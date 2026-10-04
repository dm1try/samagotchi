import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  elapsedSince,
  formatDuration,
  mergeTiming,
  normalizeTiming,
  turnRecordAt,
  timedTurnIndexes,
  appendAboveLiveTiming,
  turnTimingText,
} from "../../../lib/samagotchi/web/public/timing.js";

// Shared contract: spec/shared/timing_matrix.json. One source of truth for the
// web (JS) and TUI (Ruby) suites — edit it to change either side's output.
const matrix = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("../../../spec/shared/timing_matrix.json", import.meta.url)),
    "utf8",
  ),
);

test("formatDuration renders compact elapsed values", () => {
  for (const { ms, expected } of matrix.cases) {
    assert.equal(formatDuration(ms), expected, `timing for ${ms}ms`);
  }
});

test("elapsedSince uses supplied time and rejects invalid dates", () => {
  assert.equal(elapsedSince("2026-09-21T10:00:00.000Z", Date.parse("2026-09-21T10:00:01.250Z")), 1250);
  assert.equal(elapsedSince("not-a-date", Date.now()), null);
});

test("normalizeTiming keeps usable persisted records and turnRecordAt preserves order", () => {
  const timing = normalizeTiming({
    started_at: "2026-09-21T10:00:00.000Z",
    session_duration_ms: 2500,
    turn_records: [{ id: "turn-1", duration_ms: 1000 }, null, "bad"],
    tool_records: [{ id: "tool-1", duration_ms: 20 }],
  });

  assert.equal(timing.sessionDurationMs, 2500);
  assert.deepEqual(timing.turnRecords.map((record) => record.id), ["turn-1"]);
  assert.equal(turnRecordAt(timing, 0).duration_ms, 1000);
  assert.equal(turnRecordAt(timing, 1), null);
});

test("timedTurnIndexes marks only each turn's last assistant message", () => {
  const items = [
    { role: "user" },
    { role: "assistant" }, // a tool-calling iteration
    { role: "assistant" }, // the turn's answer
    { role: "user" },
    { role: "assistant" },
    { role: "user" }, // a turn with no answer: canceled, or still running (no record yet)
  ];

  assert.deepEqual(timedTurnIndexes(items), [null, null, 0, null, 1, 2]);
});

test("timedTurnIndexes: a canceled turn that saved only its prompt keeps its timing, on the prompt", () => {
  const items = [{ role: "user" }, { role: "note" }, { role: "user" }, { role: "assistant" }];

  assert.deepEqual(timedTurnIndexes(items), [0, null, null, 1]);
});

import { turnGroups } from "../../../lib/samagotchi/web/public/timing.js";

const TIMING = normalizeTiming({
  turn_records: [{ id: "T1", status: "completed", duration_ms: 18503 }, { id: "T2", status: "canceled", duration_ms: 900 }],
  tool_records: [
    { id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 },
    { id: "T1:2:1", turn_id: "T1", iteration: 2, call_index: 1, tool: "read", status: "error", duration_ms: 1 },
  ],
});

test("turnGroups: a turn's steps come from its iterations (tool records), its texts in order, the last text is the answer", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Let me check." }, // iteration 1's narration; iteration 2 wrote none
    { role: "assistant", content: "Both fine." },
    { role: "note", content: "n" },
    { role: "user", content: "again" }, // canceled before an answer
  ];
  assert.deepEqual(turnGroups(items, TIMING), [
    { kind: "turn", turnIndex: 0, user: 0, answer: 2, record: TIMING.turnRecords[0], steps: [
      { i: 1, iteration: 1, tools: [{ key: "1:1", tool: "execute", status: "ok", duration_ms: 7 }] },
      { i: null, iteration: 2, tools: [{ key: "2:1", tool: "read", status: "error", duration_ms: 1 }] },
    ] },
    { kind: "note", i: 3 },
    { kind: "turn", turnIndex: 1, user: 4, answer: null, record: TIMING.turnRecords[1], steps: [] },
  ]);
});

test("turnGroups: a plain answer has no steps; an assistant message before any prompt is its own answer", () => {
  const items = [{ role: "assistant", content: "hello" }, { role: "user", content: "p" }, { role: "assistant", content: "PONG" }];
  const groups = turnGroups(items, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 5 }] }));
  assert.deepEqual(groups.map((g) => [g.kind, g.user, g.answer, g.steps?.length]), [["answer", undefined, 0, undefined], ["turn", 1, 2, 0]]);
});

const EXECUTE = { tool: "execute", params: 'command="true"', output: "[execute]\nexit: 0" };
const READ = { tool: "read", params: 'path="README.md"', output: "[read]\n# T" };

test("turnGroups with parts (?parts=1): one step per saved message, its thinking and its calls with the records' status", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Let me check.", parts: { thinking: "plan", tools: [EXECUTE] } },
    { role: "assistant", content: "", parts: { tools: [READ] } }, // a text-less step, kept with its parts
    { role: "assistant", content: "Both fine.", parts: { thinking: "sum up" } },
  ];
  assert.deepEqual(turnGroups(items, TIMING)[0], {
    kind: "turn", turnIndex: 0, user: 0, answer: 3, record: TIMING.turnRecords[0], steps: [
      { i: 1, iteration: 1, thinking: "plan", tools: [{ key: "1:1", status: "ok", duration_ms: 7, ...EXECUTE }] },
      { i: 2, iteration: 2, thinking: "", tools: [{ key: "2:1", status: "error", duration_ms: 1, ...READ }] },
      // The answer's thinking stays in the block as a step, as it does live.
      { i: null, iteration: 3, thinking: "sum up", tools: [] },
    ],
  });
});

test("turnGroups with parts: a reloaded row keeps its call's view (the full command)", () => {
  const view = { command: "cd /p && rg -n foo lib |\n  head -5", cwd: "lib" };
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Checking.", parts: { tools: [{ ...EXECUTE, view }] } },
  ];
  assert.deepEqual(turnGroups(items, TIMING)[0].steps[0].tools[0].view, view);
});

test("turnGroups with parts: a turn that ended on a call has no answer; a call with no record shows done", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Checking.", parts: { tools: [EXECUTE, READ] } },
  ];
  const timing = normalizeTiming({ turn_records: [{ id: "T1", status: "canceled", duration_ms: 5 }],
    tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 }] });
  const group = turnGroups(items, timing)[0];
  assert.equal(group.answer, null);
  assert.deepEqual(group.steps, [{ i: 1, iteration: 1, thinking: "", tools: [
    { key: "1:1", status: "ok", duration_ms: 7, ...EXECUTE },
    { key: "1:2", status: "ok", duration_ms: undefined, ...READ },
  ] }]);
});

test("turnGroups with parts: an empty retry mid-turn (an iteration with no message) shifts no call's record", () => {
  const items = [
    { role: "user", content: "p", turn_id: "T1" },
    { role: "assistant", content: "Let me check.", parts: { tools: [EXECUTE] } },
    // Iteration 2 was an empty generation, retried: it left no message.
    { role: "assistant", content: "", parts: { tools: [READ] } },
    { role: "assistant", content: "Both fine." },
  ];
  const timing = normalizeTiming({ turn_records: [{ id: "T1", status: "completed", duration_ms: 50 }],
    tool_records: [
      { id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 },
      { id: "T1:3:1", turn_id: "T1", iteration: 3, call_index: 1, tool: "read", status: "error", duration_ms: 4 },
    ] });
  const group = turnGroups(items, timing)[0];
  assert.equal(group.answer, 3);
  assert.deepEqual(group.steps, [
    { i: 1, iteration: 1, thinking: "", tools: [{ key: "1:1", status: "ok", duration_ms: 7, ...EXECUTE }] },
    { i: 2, iteration: 2, thinking: "", tools: [{ key: "2:1", status: "error", duration_ms: 4, ...READ }] },
  ]);
});

test("turnGroups with parts: records no saved message took (a generation that saved nothing) are steps after them", () => {
  const items = [
    { role: "user", content: "p", turn_id: "T1" },
    { role: "assistant", content: "Checking.", parts: { tools: [EXECUTE] } },
  ];
  const timing = normalizeTiming({ turn_records: [{ id: "T1", status: "canceled", duration_ms: 50 }],
    tool_records: [
      { id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 },
      { id: "T1:2:1", turn_id: "T1", iteration: 2, call_index: 1, tool: "read", status: "ok", duration_ms: 3 },
    ] });
  assert.deepEqual(turnGroups(items, timing)[0].steps, [
    { i: 1, iteration: 1, thinking: "", tools: [{ key: "1:1", status: "ok", duration_ms: 7, ...EXECUTE }] },
    { i: null, iteration: 2, thinking: "", tools: [{ key: "2:1", tool: "read", status: "ok", duration_ms: 3 }] },
  ]);
});

function fakeParent() {
  const parent = {
    children: [],
    appendChild(el) { parent.children.push(el); el.parentNode = parent; },
    insertBefore(el, ref) { parent.children.splice(parent.children.indexOf(ref), 0, el); el.parentNode = parent; },
  };
  return parent;
}

function fakeEl(name, classes = []) {
  return { name, parentNode: null, classList: { contains: (c) => classes.includes(c) } };
}

test("appendAboveLiveTiming keeps a running turn's timing line last", () => {
  const parent = fakeParent();
  const timing = fakeEl("timing", ["turn-timing", "live"]);
  parent.appendChild(fakeEl("prompt"));
  parent.appendChild(timing);

  appendAboveLiveTiming(parent, fakeEl("thinking"), timing);
  appendAboveLiveTiming(parent, fakeEl("answer"), timing);

  assert.deepEqual(parent.children.map((el) => el.name), ["prompt", "thinking", "answer", "timing"]);
});

test("appendAboveLiveTiming appends after a finished timing line, or with none", () => {
  const parent = fakeParent();
  const finished = fakeEl("timing", ["turn-timing"]);
  parent.appendChild(finished);

  appendAboveLiveTiming(parent, fakeEl("next prompt"), finished);
  appendAboveLiveTiming(parent, fakeEl("recap"), null);

  assert.deepEqual(parent.children.map((el) => el.name), ["timing", "next prompt", "recap"]);
});

test("turnTimingText: the turn's number live and after it ends, as a reload shows it", () => {
  assert.equal(turnTimingText(3, 1000, { running: true }), "turn 3 running · 1.0s");
  assert.equal(turnTimingText(3, 4100), "turn 3 · 4.1s");
  // No number known (no timing yet): the old wording.
  assert.equal(turnTimingText(null, 4100), "turn · 4.1s");
  assert.equal(turnTimingText(null, 0, { running: true }), "turn running · 0ms");
});

test("turnTimingText: a canceled turn says so", () => {
  assert.equal(turnTimingText(2, 1600, { canceled: true }), "turn 2 · 1.6s · canceled");
});

import { cancelLineHtml, cancelLineText } from "../../../lib/samagotchi/web/public/timing.js";

test("cancelLineText / cancelLineHtml: the live line and the one a re-render draws from the turn record", () => {
  assert.equal(cancelLineText("user"), "\u2715 canceled (stopped)");
  assert.equal(cancelLineText("ctrl_c"), "\u2715 canceled (Ctrl-C)");
  assert.equal(cancelLineText("hook"), "\u2715 canceled (by a hook)");
  assert.equal(cancelLineText("shutdown"), "\u2715 canceled (shutdown)");
  assert.equal(cancelLineText(""), "\u2715 canceled");
  const esc = (s) => s.replace(/</g, "&lt;");
  assert.equal(cancelLineHtml({ status: "canceled", cancellation_reason: "ctrl_c" }, esc), '<div class="bubble cancel">\u2715 canceled (Ctrl-C)</div>');
  assert.equal(cancelLineHtml({ status: "canceled" }, esc), '<div class="bubble cancel">\u2715 canceled</div>');
  assert.equal(cancelLineHtml({ status: "canceled", cancellation_reason: "<x>" }, esc), '<div class="bubble cancel">\u2715 canceled (&lt;x>)</div>');
  assert.equal(cancelLineHtml({ status: "canceled", cancellation_reason: "hook", cancelled_by: "loop-guard" }, esc),
    '<div class="bubble cancel">\u2715 stopped by loop-guard</div>');
  assert.equal(cancelLineHtml({ status: "completed" }, esc), "");
  assert.equal(cancelLineHtml(null, esc), "");
});

// Live, a canceled turn's partial text stays in the block unless the turn
// was one step with no tools (turn_view.js turnEnded); a reload agrees.
const CANCELED = normalizeTiming({
  turn_records: [{ id: "T1", status: "canceled", cancellation_reason: "user", duration_ms: 12000 }],
  tool_records: [{ id: "T1:1:1", turn_id: "T1", iteration: 1, call_index: 1, tool: "execute", status: "ok", duration_ms: 7 }],
});

test("turnGroups with parts: a canceled multi-step turn's last text is a step, not the answer", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Checking.", parts: { thinking: "plan", tools: [EXECUTE] } },
    { role: "assistant", content: "Both checks passed:\n[interrupted]", parts: { thinking: "sum up" } },
  ];
  assert.deepEqual(turnGroups(items, CANCELED)[0], {
    kind: "turn", turnIndex: 0, user: 0, answer: null, record: CANCELED.turnRecords[0], steps: [
      { i: 1, iteration: 1, thinking: "plan", tools: [{ key: "1:1", status: "ok", duration_ms: 7, ...EXECUTE }] },
      { i: 2, iteration: 2, thinking: "sum up", tools: [] },
    ],
  });
});

test("turnGroups: a canceled multi-step turn without parts keeps every text as a step; a one-step one keeps its answer", () => {
  const items = [{ role: "user", content: "p" }, { role: "assistant", content: "Checking." }, { role: "assistant", content: "Both\n[interrupted]" }];
  const g = turnGroups(items, CANCELED)[0];
  assert.equal(g.answer, null);
  assert.deepEqual(g.steps.map((s) => [s.i, s.iteration, s.tools.length]), [[1, 1, 1], [2, 2, 0]]);
  const plain = [{ role: "user", content: "p" }, { role: "assistant", content: "Half an answer\n[interrupted]", parts: { thinking: "t" } }];
  const oneStep = normalizeTiming({ turn_records: [{ id: "T1", status: "canceled", duration_ms: 900 }] });
  assert.equal(turnGroups(plain, oneStep)[0].answer, 1);
  assert.equal(turnGroups(plain.map(({ parts, ...m }) => m), oneStep)[0].answer, 1);
});

test("turnGroups: a plugin's steer goes to the step that answered it (its `step`), never starting a turn", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Let me check." },
    { role: "steer", content: "status?", source: "check-in", step: 2 },
    { role: "assistant", content: "Both fine." },
  ];
  const [group, ...rest] = turnGroups(items, TIMING);
  assert.equal(rest.length, 0);
  assert.equal(group.answer, 3);
  assert.deepEqual(group.steps.map((s) => [s.iteration, s.steers]), [[1, []], [2, [2]]]);
  assert.deepEqual(group.steers, []);
});

test("turnGroups: a steer answered by the answer (no such step) stays on the group, as one in a turn with no steps", () => {
  const past = [{ role: "user", content: "p" }, { role: "steer", content: "s", step: 3 }, { role: "assistant", content: "a" }];
  const answered = turnGroups(past, TIMING)[0];
  assert.deepEqual([answered.steps.map((s) => s.steers), answered.steers], [[[], []], [1]]);

  const plain = [{ role: "user", content: "p" }, { role: "steer", content: "s", step: 1 }, { role: "assistant", content: "a" }];
  const group = turnGroups(plain, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 5 }] }))[0];
  assert.deepEqual([group.steps, group.steers], [[], [1]]);
});

test("turnGroups: a line merged into the running turn stays in that turn (merged), the next prompt is the next turn", () => {
  const items = [
    { role: "user", content: "p" }, { role: "assistant", content: "a" },
    { role: "user", content: "also", merged: true }, { role: "assistant", content: "b" },
    { role: "user", content: "q" }, { role: "assistant", content: "c" },
  ];
  const groups = turnGroups(items, normalizeTiming({ turn_records: [{ id: "T1", duration_ms: 1 }, { id: "T2", duration_ms: 2 }] }));
  assert.deepEqual(groups.map((g) => [g.turnIndex, g.user, g.merged, g.answer, g.record?.id]), [[0, 0, [2], 3, "T1"], [1, 4, undefined, 5, "T2"]]);
});

test("turnGroups: a prompt with its turn_id pairs with that record, so a failed turn's record (its prompt went back) shifts nothing", () => {
  const timing = normalizeTiming({ turn_records: [
    { id: "A", status: "completed", duration_ms: 1000 },
    { id: "B", status: "failed", duration_ms: 50 },
    { id: "C", status: "completed", duration_ms: 3000 },
  ] });
  const items = [
    { role: "user", content: "one", turn_id: "A" },
    { role: "assistant", content: "1" },
    { role: "user", content: "three", turn_id: "C" },
    { role: "assistant", content: "3" },
  ];
  assert.deepEqual(turnGroups(items, timing).map((g) => g.record?.id), ["A", "C"]);
  // A prompt saved before turn ids (none) still pairs by its place.
  const old = items.map(({ turn_id, ...m }) => m);
  assert.deepEqual(turnGroups(old, timing).map((g) => g.record?.id), ["A", "B"]);
  // An id with no record yet (the running turn): no record, not another turn's.
  assert.equal(turnGroups([{ role: "user", content: "x", turn_id: "Z" }], timing)[0].record, null);
});

// mergeTiming: a turn-end re-read's newest records merged by id.
const T = (id, at, extra = {}) => ({ id, started_at: `2026-10-03T10:0${at}:00.000Z`, duration_ms: at * 1000, ...extra });
const page = (turns, tools = []) => normalizeTiming({ turn_records: turns, tool_records: tools });
const ids = (records) => records.map((r) => r.id);

test("mergeTiming appends the newest turn and its tool records; the count matches", () => {
  const { timing, short } = mergeTiming(page([T("t1", 1)], [{ id: "t1:1:1", turn_id: "t1" }]), {
    started_at: "2026-10-03T10:00:00.000Z",
    session_duration_ms: 9000,
    turn_records: [T("t2", 2)],
    tool_records: [{ id: "t2:1:1", turn_id: "t2" }, { id: "t2:1:2", turn_id: "t2" }],
    turn_count: 2,
  });
  assert.deepEqual(ids(timing.turnRecords), ["t1", "t2"]);
  assert.deepEqual(ids(timing.toolRecords), ["t1:1:1", "t2:1:1", "t2:1:2"]);
  assert.equal(timing.startedAt, "2026-10-03T10:00:00.000Z");
  assert.equal(timing.sessionDurationMs, 9000);
  assert.equal(short, false);
});

test("mergeTiming replaces a known record in place: a duplicate read doesn't grow the lists", () => {
  const before = page([T("t1", 1), T("t2", 2)], [{ id: "t2:1:1", turn_id: "t2", duration_ms: 1 }]);
  const reply = { turn_records: [T("t2", 2, { duration_ms: 2500 })], tool_records: [{ id: "t2:1:1", turn_id: "t2", duration_ms: 5 }], turn_count: 2 };
  const once = mergeTiming(before, reply).timing;
  const twice = mergeTiming(once, reply);
  assert.deepEqual(ids(twice.timing.turnRecords), ["t1", "t2"]);
  assert.equal(twice.timing.turnRecords[1].duration_ms, 2500);
  assert.deepEqual(twice.timing.toolRecords.map((r) => r.duration_ms), [5]);
  assert.equal(twice.short, false);
});

test("mergeTiming inserts an unknown turn by started_at (a late read of an earlier turn); ties and unparsable dates keep arrival order", () => {
  const inserted = mergeTiming(page([T("t1", 1), T("t3", 3)]), { turn_records: [T("t2", 2)], turn_count: 3 }).timing;
  assert.deepEqual(ids(inserted.turnRecords), ["t1", "t2", "t3"]);
  const tie = mergeTiming(page([T("a", 2)]), { turn_records: [T("b", 2)], turn_count: 2 }).timing;
  assert.deepEqual(ids(tie.turnRecords), ["a", "b"]);
  const undated = mergeTiming(page([T("t1", 1)]), { turn_records: [{ id: "x", started_at: "nope" }], turn_count: 2 }).timing;
  assert.deepEqual(ids(undated.turnRecords), ["t1", "x"]);
});

test("mergeTiming is short when the count says a turn is missing (a queued turn's read came late)", () => {
  // The page has none; the reply has B's only, and counts A and B.
  const { timing, short } = mergeTiming(page([]), { turn_records: [T("tB", 2)], turn_count: 2 });
  assert.deepEqual(ids(timing.turnRecords), ["tB"]);
  assert.equal(short, true);
});

test("mergeTiming keeps more records than the count (a worker died before saving a turn the page saw)", () => {
  const { timing, short } = mergeTiming(page([T("t1", 1), T("t2", 2)]), { turn_records: [], turn_count: 1 });
  assert.deepEqual(ids(timing.turnRecords), ["t1", "t2"]);
  assert.equal(short, false);
});

test("mergeTiming without turn_count (an older server's whole timing) replaces, as normalizeTiming", () => {
  const { timing, short } = mergeTiming(page([T("old", 1)]), { turn_records: [T("t1", 1), T("t2", 2)], active_turn: { id: "t3" } });
  assert.deepEqual(ids(timing.turnRecords), ["t1", "t2"]);
  assert.deepEqual(timing.activeTurn, { id: "t3" });
  assert.equal(short, false);
  assert.deepEqual(mergeTiming(page([T("t1", 1)]), undefined).timing, normalizeTiming());
});

test("normalizeTiming / mergeTiming keep the session's tokens; a reply without them keeps the page's", () => {
  const tokens = { prompt_sum: 10, completion_sum: 2, last_decode_tps: 50, tps_source: "server" };
  assert.deepEqual(normalizeTiming({ tokens }).tokens, tokens);
  assert.equal(normalizeTiming({ tokens: "bad" }).tokens, null);
  const newer = { ...tokens, prompt_sum: 30 };
  assert.deepEqual(mergeTiming(normalizeTiming({ tokens }), { tokens: newer, turn_count: 0 }).timing.tokens, newer);
  assert.deepEqual(mergeTiming(normalizeTiming({ tokens }), { turn_count: 0 }).timing.tokens, tokens);
});
