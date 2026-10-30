import test from "node:test";
import assert from "node:assert/strict";
import { sessionFieldsFrom } from "../../../lib/samagotchi/web/public/session_payload.js";
import { sessionStateFrom } from "../../../lib/samagotchi/web/public/session_state.js";

test("the named fields, read as a full load reads them", () => {
  const data = {
    session: { status: "idle", model_name: "m", used_memory_names: ["a"], prompt_notes: [{ name: "n" }] },
    timing: {},
  };
  const full = sessionStateFrom(data);
  assert.deepEqual(sessionFieldsFrom(data, ["usedMemories", "promptNotes", "status"]),
                   { usedMemories: full.usedMemories, promptNotes: full.promptNotes, status: "idle" });
});

test("a field whose source the payload leaves out is not touched", () => {
  const data = { session: { prompt_notes: "not a list" } };
  assert.deepEqual(sessionFieldsFrom(data, ["usedMemories", "promptNotes", "status", "commands"]), {});
});

test("a payload without a session brings nothing", () => {
  assert.deepEqual(sessionFieldsFrom({}, ["status"]), {});
  assert.deepEqual(sessionFieldsFrom(null, ["status"]), {});
});

test("a field no payload sets is never taken", () => {
  assert.deepEqual(sessionFieldsFrom({ session: { status: "running" } }, ["status", "streamSeq"]), { status: "running" });
});
