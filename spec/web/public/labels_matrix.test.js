import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { cancelLineText } from "../../../lib/samagotchi/web/public/timing.js";
import { clientLabel, emptyAnswerLine, emptyRetryLine, hookNoticeLabel, reminderText, retryStatusLine } from "../../../lib/samagotchi/web/public/turn_events.js";
import { servedModelDiffers } from "../../../lib/samagotchi/web/public/format.js";
import { costText, speedText } from "../../../lib/samagotchi/web/public/ctx.js";

// Shared contract: spec/shared/labels_matrix.json, the words the web and the
// TUI put on the same event. spec/labels_matrix_spec.rb reads the same file;
// edit it to change either side's words.
const matrix = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../../spec/shared/labels_matrix.json", import.meta.url)), "utf8"),
);

const cases = (section) => matrix[section].cases;
// The JS expectation of a case: its own, else the shared one.
const expected = (entry) => ("js" in entry ? entry.js : entry.expected);

test("cancel reasons per the shared labels matrix", () => {
  for (const entry of cases("cancel_reasons")) {
    const label = expected(entry);
    assert.equal(cancelLineText(entry.reason), `✕ canceled${label ? ` (${label})` : ""}`, `reason ${entry.reason}`);
  }
});

test("client labels per the shared labels matrix", () => {
  for (const entry of cases("client_labels")) {
    assert.equal(clientLabel(entry.client_id), expected(entry), `client ${entry.client_id}`);
  }
});

test("hook notice labels per the shared labels matrix", () => {
  for (const entry of cases("hook_notice_labels")) {
    assert.equal(hookNoticeLabel(entry.hook), expected(entry), `hook ${entry.hook}`);
  }
});

test("empty-answer retry lines per the shared labels matrix", () => {
  for (const entry of cases("empty_retry_lines")) {
    assert.equal(emptyRetryLine(entry.event), expected(entry));
  }
});

test("no-answer notices per the shared labels matrix", () => {
  for (const entry of cases("empty_answer_lines")) {
    assert.equal(emptyAnswerLine({ retries: entry.retries }), expected(entry));
  }
});

test("provider retry lines per the shared labels matrix", () => {
  for (const entry of cases("retry_lines")) {
    assert.equal(retryStatusLine(entry.event), expected(entry));
  }
});

test("reminder lines per the shared labels matrix", () => {
  for (const entry of cases("reminder_lines")) {
    assert.equal(reminderText({ reminders: entry.reminders }), expected(entry));
  }
});

test("served-model check per the shared labels matrix", () => {
  for (const entry of cases("served_model")) {
    assert.equal(servedModelDiffers(entry.asked, entry.served), entry.differs, `${entry.served} for ${entry.asked}`);
  }
});

test("speeds per the shared labels matrix", () => {
  for (const entry of cases("speeds")) {
    assert.equal(speedText(entry.tps, entry.source), expected(entry), `speed ${entry.tps} ${entry.source}`);
  }
});

test("costs per the shared labels matrix", () => {
  for (const entry of cases("costs")) {
    assert.equal(costText(entry.cost), expected(entry), `cost ${entry.cost}`);
  }
});
