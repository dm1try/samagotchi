import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  elapsedSince,
  formatDuration,
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
