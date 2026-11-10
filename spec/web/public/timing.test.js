
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  elapsedSince,
  formatDuration,
  liveDurationText,
  mergeTiming,
  normalizeTiming,
  sessionDurationNow,
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

test("liveDurationText: the live line's duration — tenths under a second, formatDuration from 1 s on", () => {
  assert.equal(liveDurationText(0), "0.0s");
  assert.equal(liveDurationText(200), "0.2s");
  assert.equal(liveDurationText(849), "0.8s");
  assert.equal(liveDurationText(1000), "1.0s");
  assert.equal(liveDurationText(1500), "1.5s");
  assert.equal(liveDurationText(9999), "10.0s");
  assert.equal(liveDurationText(10000), "10s");
  assert.equal(liveDurationText(61000), "1m 01s");
  assert.equal(liveDurationText(-1), "");
  assert.equal(liveDurationText("nope"), "");
});

test("elapsedSince uses supplied time and rejects invalid dates", () => {
  assert.equal(elapsedSince("2026-09-21T10:00:00.000Z", Date.parse("2026-09-21T10:00:01.250Z")), 1250);
  assert.equal(elapsedSince("not-a-date", Date.now()), null);
});

test("normalizeTiming keeps usable persisted records, in order", () => {
  const timing = normalizeTiming({
    started_at: "2026-09-21T10:00:00.000Z",
    session_duration_ms: 2500,
    turn_records: [{ id: "turn-1", duration_ms: 1000 }, null, "bad"],
    tool_records: [{ id: "tool-1", duration_ms: 20 }],
  });

  assert.equal(timing.sessionDurationMs, 2500);
  assert.deepEqual(timing.turnRecords.map((record) => record.id), ["turn-1"]);
  assert.equal(timing.turnRecords[0].duration_ms, 1000);
});

import { turnGroups } from "../../../lib/samagotchi/web/public/timing.js";

const EXECUTE = { tool: "execute", params: 'command="true"', output: "[execute]\nexit: 0" };
const READ = { tool: "read", params: 'path="README.md"', output: "[read]\n# T" };

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

import { cancelLineText } from "../../../lib/samagotchi/web/public/timing.js";

// The re-rendered line (turn_html.js cancelLineTemplate) has its own spec.
test("cancelLineText: the live line and the one a re-render draws from the turn record", () => {
  assert.equal(cancelLineText("user"), "\u25A0 canceled (stopped)");
  assert.equal(cancelLineText("ctrl_c"), "\u25A0 canceled (Ctrl-C)");
  assert.equal(cancelLineText("hook"), "\u25A0 canceled (by a hook)");
  assert.equal(cancelLineText("shutdown"), "\u25A0 canceled (shutdown)");
  assert.equal(cancelLineText(""), "\u25A0 canceled");
  assert.equal(cancelLineText("hook", "loop-guard"), "\u25A0 stopped by loop-guard");
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

// The rows per model: a reply with the key is authoritative (an empty list
// too: one model now), one without it keeps the page's.
test("mergeTiming takes the reply's model_segments when it has the key, else keeps the page's", () => {
  const rows = [{ model_ref: "a:one", turns: 1 }, { model_ref: "b:two", turns: 1 }];
  const withRows = normalizeTiming({ turn_records: [T("t1", 1)], model_segments: rows });
  assert.deepEqual(withRows.modelSegments, rows);
  assert.deepEqual(normalizeTiming({}).modelSegments, []);

  const reply = { turn_records: [T("t2", 2)], turn_count: 2 };
  assert.deepEqual(mergeTiming(withRows, reply).timing.modelSegments, rows);
  assert.deepEqual(mergeTiming(withRows, { ...reply, model_segments: [] }).timing.modelSegments, []);
  const fresh = [...rows, { model_ref: "a:one", turns: 1 }];
  assert.deepEqual(mergeTiming(withRows, { ...reply, model_segments: fresh }).timing.modelSegments, fresh);
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

test("normalizeTiming / mergeTiming keep the memory indexes; a reply without them keeps the page's", () => {
  const memoryIndex = { system: { tokens: 10, lines: 1 } };
  assert.deepEqual(normalizeTiming({ memory_index: memoryIndex }).memoryIndex, memoryIndex);
  assert.equal(normalizeTiming({}).memoryIndex, null);
  const newer = { system: { tokens: 20, lines: 2 } };
  assert.deepEqual(mergeTiming(normalizeTiming({ memory_index: memoryIndex }), { memory_index: newer, turn_count: 0 }).timing.memoryIndex, newer);
  assert.deepEqual(mergeTiming(normalizeTiming({ memory_index: memoryIndex }), { turn_count: 0 }).timing.memoryIndex, memoryIndex);
});

test("normalizeTiming / mergeTiming keep the side requests' block; a reply without it keeps the page's", () => {
  const side = { requests: 1, by_kind: { recap: { requests: 1 } } };
  assert.deepEqual(normalizeTiming({ side }).side, side);
  assert.equal(normalizeTiming({}).side, null);
  assert.equal(normalizeTiming({ side: "x" }).side, null);
  const newer = { requests: 2, by_kind: { recap: { requests: 1 }, btw: { requests: 1 } } };
  assert.deepEqual(mergeTiming(normalizeTiming({ side }), { side: newer, turn_count: 0 }).timing.side, newer);
  assert.deepEqual(mergeTiming(normalizeTiming({ side }), { turn_count: 0 }).timing.side, side);
});

test("normalizeTiming / mergeTiming keep the session's tokens; a reply without them keeps the page's", () => {
  const tokens = { prompt_sum: 10, completion_sum: 2, last_decode_tps: 50, tps_source: "server" };
  assert.deepEqual(normalizeTiming({ tokens }).tokens, tokens);
  assert.equal(normalizeTiming({ tokens: "bad" }).tokens, null);
  const newer = { ...tokens, prompt_sum: 30 };
  assert.deepEqual(mergeTiming(normalizeTiming({ tokens }), { tokens: newer, turn_count: 0 }).timing.tokens, newer);
  assert.deepEqual(mergeTiming(normalizeTiming({ tokens }), { turn_count: 0 }).timing.tokens, tokens);
});

test("sessionDurationNow counts from the session's start while a turn runs", () => {
  const timing = { startedAt: "2026-10-10T10:00:00.000Z", sessionDurationMs: 5, activeTurn: { started_at: "2026-10-10T10:00:30.000Z" } };
  const now = Date.parse("2026-10-10T10:01:00.000Z");
  assert.equal(sessionDurationNow(timing, true, now), 60000);
  assert.equal(sessionDurationNow(timing, false, now), 5);
});

test("sessionDurationNow falls back to the running turn's start on a session's first turn", () => {
  // A session created from the start page: its snapshot had no started_at
  // (session_duration_ms 0) and the first turn_started carries none either.
  const timing = { startedAt: null, sessionDurationMs: 0, activeTurn: { started_at: "2026-10-10T10:00:00.000Z" } };
  assert.equal(sessionDurationNow(timing, true, Date.parse("2026-10-10T10:00:07.000Z")), 7000);
});

test("sessionDurationNow keeps the server's duration without any start", () => {
  assert.equal(sessionDurationNow({ startedAt: null, sessionDurationMs: 0, activeTurn: null }, true, 1), 0);
  assert.equal(sessionDurationNow({ startedAt: null, sessionDurationMs: null, activeTurn: null }, false, 1), null);
  assert.equal(sessionDurationNow(undefined, false, 1), null);
});

// Shared contract: spec/shared/turn_ranges.json (Bridge::TurnRanges, written by
// spec/bridge/turn_ranges_spec.rb): the items as the show stamps them and
// each turn's drawing's end (its record's id, by turn id, else by place
// among the openings). The page's turns are the stamps': each group holds
// the items its range does, with the record its end names.
const turnRanges = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../../spec/shared/turn_ranges.json", import.meta.url)), "utf8"),
);

for (const [name, spec] of Object.entries(turnRanges)) {
  test(`turnGroups groups the stamped items as Bridge::TurnRanges cuts them, with their records: ${name}`, () => {
    const groups = turnGroups(spec.items, normalizeTiming({ turn_records: spec.records }), { drawings: spec.drawings })
      .filter((g) => g.kind === "turn");
    const itemsOf = (g) => {
      const all = [g.user, ...g.texts, ...(g.merged || []), ...(g.steers || []), g.emptyAnswer];
      // A wake's note opens its group from outside the range (stamped by its id, not its place).
      return [...new Set(all.filter((i) => i != null && !(i === g.user && spec.items[i]?.role === "note")))].sort((a, b) => a - b);
    };
    const held = spec.turns.filter((t) => t.items.length);
    assert.deepEqual(groups.map((g) => [itemsOf(g), g.record?.id ?? null]), held.map((t) => [t.items, t.record_id]), spec.description);
    assert.ok(turnGroups(spec.items, {}, { drawings: spec.drawings }).every((g) => g.kind !== "plain"), "every turn item stamped");
  });
}

test("turnGroups pairs a drawn turn with the record its end names (a made-up id's, by place), else its own id's", () => {
  const items = [{ role: "user", content: "old", drawn: "m1-0a1b2c3d" }, { role: "assistant", content: "a", drawn: "m1-0a1b2c3d" },
    { role: "user", content: "new", turn_id: "t2", drawn: "t2" }, { role: "assistant", content: "b", drawn: "t2" }];
  const drawing = (end) => ({ events: [{ type: "turn_started" }], end });
  const drawings = { "m1-0a1b2c3d": drawing({ type: "turn_completed", record_id: "r1" }), t2: drawing({ type: "turn_completed", turn_id: "t2" }) };
  const timing = normalizeTiming({ turn_records: [{ id: "r1", status: "completed", duration_ms: 1500 }, { id: "t2", status: "completed", duration_ms: 900 }] });
  const turns = turnGroups(items, timing, { drawings }).filter((g) => g.kind === "turn");
  assert.deepEqual(turns.map((g) => g.record?.id ?? null), ["r1", "t2"]);
});

test("turnGroups keeps a repeated turn id's two turns apart: the made one has an id of its own (spec/shared/turn_drawings/repeated_id.json)", () => {
  const { show } = JSON.parse(readFileSync(fileURLToPath(new URL("../../../spec/shared/turn_drawings/repeated_id.json", import.meta.url)), "utf8"));
  const turns = turnGroups(show.messages, normalizeTiming({}), { drawings: show.turn_drawings }).filter((g) => g.kind === "turn");
  assert.deepEqual(turns.map((g) => g.drawn), ["turn-again~1", "turn-again"]);
});
