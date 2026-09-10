import test from "node:test";
import assert from "node:assert/strict";
import { routeChunk } from "../../../lib/samagotchi/web/public/chunk_router.js";

test("uses text/thinking when the new wire fields are present", () => {
  const r = routeChunk({ content: "raw", text: "clean", thinking: "thought" });
  assert.equal(r.text, "clean");
  assert.equal(r.thinking, "thought");
});

test("empty text still selects the new wire (no raw fallback)", () => {
  // A chunk that is entirely a tool_call body: text is "" (dropped), thinking "".
  const r = routeChunk({ content: "<|tool_call>call:x<tool_call|>", text: "", thinking: "" });
  assert.equal(r.text, "");
  assert.equal(r.thinking, "");
});

test("thinking-only chunk yields empty text", () => {
  const r = routeChunk({ content: "raw", text: "", thinking: "just thinking" });
  assert.equal(r.text, "");
  assert.equal(r.thinking, "just thinking");
});

test("falls back to raw content when neither new field is present", () => {
  const r = routeChunk({ content: "raw only" });
  assert.equal(r.text, "raw only");
  assert.equal(r.thinking, "");
});

test("falls back when data is empty/undefined", () => {
  assert.deepEqual(routeChunk(null), { text: "", thinking: "" });
  assert.deepEqual(routeChunk({}), { text: "", thinking: "" });
});

test("ignores a non-string content on fallback", () => {
  assert.deepEqual(routeChunk({ content: 42 }), { text: "", thinking: "" });
});
