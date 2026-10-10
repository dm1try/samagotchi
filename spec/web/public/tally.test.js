import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { newActivity, addStarted, addCompleted } from "../../../lib/samagotchi/web/public/activity.js";
import { tallyText } from "../../../lib/samagotchi/web/public/tally.js";

// Shared contract: spec/shared/tally_matrix.json (the Ruby TurnTally spec reads it too).
const matrix = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("../../../spec/shared/tally_matrix.json", import.meta.url)),
    "utf8",
  ),
);

function replay(events) {
  const model = newActivity();
  for (const e of events) {
    if (e.event === "started") {
      addStarted(model, { iteration: e.iteration, call_index: e.call_index, tool: e.tool, params: e.params });
    } else {
      addCompleted(model, {
        iteration: e.iteration,
        call_index: e.call_index,
        tool: e.tool,
        activity: { status: e.status, params: e.params },
      });
    }
  }
  return model;
}

for (const c of matrix.cases) {
  test(`tallyText matches the shared matrix: ${c.name}`, () => {
    const model = replay(c.events);
    assert.equal(tallyText(model.rows), c.text);
    assert.equal(tallyText(model.rows, { last: false }), c.text_no_last);
  });
}

test("tallyText takes no rows", () => {
  assert.equal(tallyText(undefined), null);
  assert.equal(tallyText([]), null);
});

test("tallyText: a grep's no-match (ok, no_match) isn't a failed call; a real failure is", () => {
  const model = newActivity();
  const calls = [["ok", true], ["error", false], ["ok", false]];
  calls.forEach(([status, noMatch], i) => {
    addStarted(model, { iteration: 1, call_index: i + 1, tool: "execute", params: "command=x" });
    addCompleted(model, { iteration: 1, call_index: i + 1, tool: "execute",
      activity: { status, params: "command=x", ...(noMatch ? { no_match: true } : {}) } });
  });
  assert.match(tallyText(model.rows), /\(1 failed\)/);
});
