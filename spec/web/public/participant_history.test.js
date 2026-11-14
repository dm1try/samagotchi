import test from "node:test";
import assert from "node:assert/strict";
import { fetchOwnHistory, hasHistory, historyLoader } from "../../../lib/samagotchi/web/public/participant_history.js";

const ok = (body) => Promise.resolve({ ok: true, status: 200, statusText: "OK", json: async () => body });
const viewer = (...can) => ({ can: (name) => can.includes(name) });

test("fetchOwnHistory reads the session's own list; a non-array is none", async () => {
  const calls = [];
  const fetchImpl = (path, opts) => {
    calls.push([path, opts.method]);
    return ok(calls.length === 1 ? { entries: ["one", "two"] } : { entries: "nope" });
  };
  assert.deepEqual(await fetchOwnHistory("abc", { fetchImpl }), ["one", "two"]);
  assert.deepEqual(await fetchOwnHistory("abc", { fetchImpl }), []);
  assert.deepEqual(calls, [["/api/sessions/abc/prompt_history", undefined], ["/api/sessions/abc/prompt_history", undefined]]);
});

test("historyLoader: the owner's shared history, a participant's own for the selected session, else none", async () => {
  const fetchHistory = () => Promise.resolve(["owner"]);
  assert.equal(historyLoader(viewer("prompt_history"), { fetchHistory, selected: () => "abc" }), fetchHistory);
  assert.equal(historyLoader(viewer("send"), { fetchHistory, selected: () => "abc" }), null);

  const load = historyLoader(viewer("own_prompt_history"), { fetchHistory, selected: () => null });
  assert.notEqual(load, fetchHistory);
  assert.deepEqual(await load(), []);
});

test("hasHistory: either list names ↑ history in the idle hint", () => {
  assert.equal(hasHistory(viewer("prompt_history")), true);
  assert.equal(hasHistory(viewer("own_prompt_history")), true);
  assert.equal(hasHistory(viewer("send")), false);
});
