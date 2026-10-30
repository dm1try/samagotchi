import test from "node:test";
import assert from "node:assert/strict";
import { FIELDS, fieldsFromCard, statusWrite } from "../../../lib/samagotchi/web/public/session_fields.js";
import { emptySessionState, sessionStateFrom } from "../../../lib/samagotchi/web/public/session_state.js";
import { sessionFieldsFrom } from "../../../lib/samagotchi/web/public/session_payload.js";
import { ORDER } from "../../../lib/samagotchi/web/public/session_store.js";
import { withLiveStatus } from "../../../lib/samagotchi/web/public/format.js";

// A payload that carries every source.
const FULL = {
  session: {
    status: "idle", model_name: "m", working_directory: "/p", owner: "worker", worker_version: "1.2.0",
    worker_features: ["delivery"], bridge_up: true, used_memory_names: ["a"], preloaded_memory_names: ["b"],
    muted_memory_names: ["c"], prompt_notes: [{ name: "n" }], verdicts: [{ check_turn_id: "t" }],
    verify_fresh: [{ of: "t", child_id: "c1" }], llm_context: { strategy: "forget" }, thinking: { level: "low" },
    created_at: "2026-10-30T10:00:00Z", parent_id: "p1", continues: "c0", title: "T",
  },
  timing: { turn_records: [] },
  commands: [{ name: "/x" }],
};

test("every field of the session state has its entry, and no other", () => {
  assert.deepEqual(Object.keys(FIELDS).sort(), Object.keys(emptySessionState()).sort());
});

test("every entry redraws only names the store runs, and says who writes it", () => {
  for (const [key, entry] of Object.entries(FIELDS)) {
    assert.ok(Array.isArray(entry.redraws), key);
    for (const name of entry.redraws) assert.ok(ORDER.includes(name), `${key}: ${name}`);
    assert.ok(entry.writers, key);
  }
});

// The ⚙ panel (settings_chip.js) redraws on each of its three summaries;
// the working set's pin rule still reads the LLM context's.
test("the session's settings redraw the ⚙ panel and the bar", () => {
  assert.deepEqual(FIELDS.thinking.redraws, ["settingsPanel", "infoBar"]);
  assert.deepEqual(FIELDS.reasoningHistory.redraws, ["settingsPanel", "infoBar"]);
  assert.deepEqual(FIELDS.llmContext.redraws, ["settingsPanel", "workingSetStrategy", "infoBar"]);
  assert.ok(ORDER.includes("settingsPanel"));
});

test("the payload sources agree with sessionStateFrom on a full payload", () => {
  const all = sessionStateFrom(FULL);
  for (const [key, entry] of Object.entries(FIELDS)) {
    if (!entry.source) continue;
    assert.notEqual(entry.source(FULL), undefined, `${key} has a source in the full payload`);
  }
  const sourced = Object.keys(FIELDS).filter((key) => FIELDS[key].source);
  const read = sessionFieldsFrom(FULL, sourced);
  assert.deepEqual(Object.keys(read).sort(), sourced.sort());
  for (const key of sourced) assert.deepEqual(read[key], all[key], key);
});

test("the payload sources are session_payload.js's 11", () => {
  assert.deepEqual(Object.keys(FIELDS).filter((key) => FIELDS[key].source).sort(), [
    "commands", "dir", "model", "mutedMemories", "preloadedMemories", "promptNotes", "status", "timing", "usedMemories",
    "verdicts", "verifyFresh",
  ]);
});

test("fieldsFromCard: exactly the owner and the worker, never the status", () => {
  const got = fieldsFromCard(FULL.session);
  assert.deepEqual(got, { owner: "worker", workerVersion: "1.2.0", workerFeatures: ["delivery"], bridgeUp: true });
  assert.equal("status" in got, false);
  assert.deepEqual(fieldsFromCard({ id: "s", status: "running" }),
                   { owner: null, workerVersion: null, workerFeatures: [], bridgeUp: false });
});

test("statusWrite: the rule per source", () => {
  assert.deepEqual(statusWrite("payload"), { apply: true, card: null });
  assert.deepEqual(statusWrite("payload", { streaming: true }), { apply: true, card: null });
  assert.deepEqual(statusWrite("hub", { streaming: false }), { apply: true, card: null });
  assert.deepEqual(statusWrite("hub", { streaming: true }), { apply: false, card: null });
  assert.deepEqual(statusWrite("stream"), { apply: true, card: withLiveStatus });
  assert.deepEqual(statusWrite("turnEnd"), { apply: true, card: null });
  assert.deepEqual(statusWrite("turnEnd", { streaming: true }), { apply: true, card: null });
  // D3: a re-read that lands after the next turn started doesn't write its "idle" over "running".
  assert.deepEqual(statusWrite("turnEnd", { running: true }), { apply: false, card: null });
  assert.deepEqual(statusWrite("turnEnd", { running: false }), { apply: true, card: null });
  assert.deepEqual(statusWrite("payload", { running: true }), { apply: true, card: null });
  assert.deepEqual(statusWrite("stream", { running: true }), { apply: true, card: withLiveStatus });
  assert.deepEqual(statusWrite("stop"), { apply: true, card: null });
  assert.throws(() => statusWrite("elsewhere"), /no source elsewhere/);
});
