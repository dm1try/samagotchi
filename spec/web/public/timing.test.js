import test from "node:test";
import assert from "node:assert/strict";
import {
  elapsedSince,
  formatDuration,
  normalizeTiming,
  turnRecordAt,
} from "../../../lib/samagotchi/web/public/timing.js";

test("formatDuration renders compact elapsed values", () => {
  assert.equal(formatDuration(0), "0.0s");
  assert.equal(formatDuration(1_250), "1.3s");
  assert.equal(formatDuration(12_400), "12s");
  assert.equal(formatDuration(62_400), "1m 02s");
  assert.equal(formatDuration(-1), "");
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
