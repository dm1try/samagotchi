import test from "node:test";
import assert from "node:assert/strict";
import { emptySessionState, sessionStateFrom } from "../../../lib/samagotchi/web/public/session_state.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";

test("starts every field empty", () => {
  const s = emptySessionState();
  assert.equal(s.parentId, null);
  assert.equal(s.continues, null);
  assert.equal(s.owner, null);
  assert.equal(s.ctxPct, null);
  assert.equal(s.ctxWindow, null);
  assert.equal(s.ctxWindowSource, null);
  assert.equal(s.llmContext, null);
  assert.equal(s.served, null);
  assert.equal(s.status, "");
  assert.equal(s.model, "");
  assert.equal(s.dir, "");
  assert.equal(s.firstPreview, "");
  assert.deepEqual(s.commands, []);
  assert.deepEqual(s.usedMemories, []);
  assert.deepEqual(s.preloadedMemories, []);
  assert.deepEqual(s.mutedMemories, []);
  assert.deepEqual(s.timing, normalizeTiming());
});

test("each call is a fresh object: one session's writes never reach the next", () => {
  const a = emptySessionState();
  a.parentId = "parent-1";
  a.commands.push({ name: "/x" });
  a.usedMemories.push("m");
  a.timing.turnRecords.push({});
  const b = emptySessionState();
  assert.equal(b.parentId, null);
  assert.deepEqual(b.commands, []);
  assert.deepEqual(b.usedMemories, []);
  assert.deepEqual(b.timing.turnRecords, []);
});

// A GET /sessions/:id payload with only what each test needs.
function payload({ session = {}, ...rest } = {}) {
  return { session: { status: "idle", model_name: "m", working_directory: "/w", ...session }, ...rest };
}

test("sessionStateFrom reads the session's fields, with the empty defaults for missing ones", () => {
  const st = sessionStateFrom(payload());
  assert.equal(st.status, "idle");
  assert.equal(st.model, "m");
  assert.equal(st.dir, "/w");
  assert.equal(st.served, null);
  assert.equal(st.owner, null);
  assert.equal(st.llmContext, null);
  assert.equal(st.thinking, null);
  assert.equal(st.reasoningHistory, null);
  assert.equal(st.parentId, null);
  assert.equal(st.continues, null);
  assert.deepEqual(st.usedMemories, []);
  assert.deepEqual(st.preloadedMemories, []);
  assert.deepEqual(st.mutedMemories, []);
  assert.deepEqual(st.promptNotes, []);
  assert.deepEqual(st.commands, []);
  assert.deepEqual(st.timing, normalizeTiming(undefined));
});

test("sessionStateFrom copies the lists, owner, links and served model", () => {
  const notes = [{ name: "model_notes_x" }];
  const st = sessionStateFrom(payload({
    session: {
      owner: "worker",
      served_model: "srv", served_model_for: "m",
      used_memory_names: ["a"], preloaded_memory_names: ["b"], muted_memory_names: ["c"],
      prompt_notes: notes, llm_context: { strategy: "none" }, thinking: { level: "high" }, reasoning_history: { level: "drop" },
      parent_id: "p1", continues: "c1",
    },
    commands: [{ name: "/x" }],
  }));
  assert.equal(st.owner, "worker");
  assert.deepEqual(st.served, ["srv", "m", null]);
  assert.deepEqual(st.usedMemories, ["a"]);
  assert.deepEqual(st.preloadedMemories, ["b"]);
  assert.deepEqual(st.mutedMemories, ["c"]);
  assert.equal(st.promptNotes, notes);
  assert.deepEqual(st.llmContext, { strategy: "none" });
  assert.deepEqual(st.thinking, { level: "high" });
  assert.deepEqual(st.reasoningHistory, { level: "drop" });
  assert.equal(st.parentId, "p1");
  assert.equal(st.continues, "c1");
  assert.deepEqual(st.commands, [{ name: "/x" }]);
});

test("sessionStateFrom drops a prompt_notes or commands that is not a list", () => {
  const st = sessionStateFrom(payload({ session: { prompt_notes: "x" }, commands: { a: 1 } }));
  assert.deepEqual(st.promptNotes, []);
  assert.deepEqual(st.commands, []);
});

test("sessionStateFrom leaves ctxPct and the window out when the payload has none (the page keeps its own)", () => {
  const st = sessionStateFrom(payload({ timing: {} }));
  assert.equal("ctxPct" in st, false);
  assert.equal("ctxWindow" in st, false);
  assert.equal("ctxWindowSource" in st, false);
});

test("sessionStateFrom reads the saved fill and window, counted against a smaller budget", () => {
  const timing = { context: { used_tokens: 1000, window_tokens: 10000, window_source: "server" } };
  assert.equal(sessionStateFrom(payload({ timing })).ctxPct, 10);
  const st = sessionStateFrom(payload({ timing, session: { llm_context: { budget_tokens: 2000 } } }));
  assert.equal(st.ctxPct, 50);
  assert.equal(st.ctxWindow, 10000);
  assert.equal(st.ctxWindowSource, "server");
  const bare = sessionStateFrom(payload({ timing: { context: { window_tokens: 8000 } } }));
  assert.equal(bare.ctxWindowSource, null);
  assert.equal("ctxPct" in bare, false);
});

test("sessionStateFrom's title: the first user message wins over the card's preview", () => {
  const st = sessionStateFrom(payload({
    session: { first_preview: "card" },
    messages: [{ role: "assistant", content: "hi" }, { role: "user", content: "  first\n message " }],
  }));
  assert.equal(st.firstPreview, "first message");
});

test("sessionStateFrom's title: the card's preview, else its last prompt, else a dash", () => {
  assert.equal(sessionStateFrom(payload({ session: { first_preview: "card" } })).firstPreview, "card");
  assert.equal(sessionStateFrom(payload({ session: { last_prompt: "last" } })).firstPreview, "last");
  assert.equal(sessionStateFrom(payload()).firstPreview, "—");
  // A dash is a title: the history's first prompt doesn't replace it.
  assert.equal(sessionStateFrom(payload({ history: ["h1"] })).firstPreview, "—");
});

test("sessionStateFrom's title is cut with an ellipsis, also from messages", () => {
  const long = "x".repeat(200);
  const st = sessionStateFrom(payload({ messages: [{ role: "user", content: long }] }));
  assert.ok(st.firstPreview.endsWith("…"));
  assert.ok(st.firstPreview.length < long.length);
});
