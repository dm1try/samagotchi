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
    { role: "user" }, // a turn with no answer yet
  ];

  assert.deepEqual(timedTurnIndexes(items), [null, null, 0, null, 1, null]);
});
