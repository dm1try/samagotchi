import test from "node:test";
import assert from "node:assert/strict";
import { routeChunk } from "../../../lib/samagotchi/web/public/chunk_router.js";

test("routes text and thinking to their lanes", () => {
  const r = routeChunk({ text: "clean", thinking: "thought" });
  assert.equal(r.text, "clean");
  assert.equal(r.thinking, "thought");
});

test("a chunk that is all tool call: both lanes empty", () => {
  assert.deepEqual(routeChunk({ text: "", thinking: "", tool_call: true }), { text: "", thinking: "" });
});

test("thinking-only chunk yields empty text", () => {
  const r = routeChunk({ text: "", thinking: "just thinking" });
  assert.equal(r.text, "");
  assert.equal(r.thinking, "just thinking");
});

test("a raw content (no longer on the wire) is never shown", () => {
  assert.deepEqual(routeChunk({ content: "raw only" }), { text: "", thinking: "" });
});

test("empty/undefined data and non-string fields are empty lanes", () => {
  assert.deepEqual(routeChunk(null), { text: "", thinking: "" });
  assert.deepEqual(routeChunk({}), { text: "", thinking: "" });
  assert.deepEqual(routeChunk({ text: 42, thinking: null }), { text: "", thinking: "" });
});
