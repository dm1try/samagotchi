import test from "node:test";
import assert from "node:assert/strict";
import {
  foldedSections, headLine, headSections, heldTwice, heldTwiceNote, lensTouched, memoryName, memoryPartWords, startTokensText,
} from "../../../lib/samagotchi/web/public/ws_sections.js";
import { overlay, sessionItems } from "../../../lib/samagotchi/web/public/working_set.js";
import { ctxTokensOf, loadedCtxTokens } from "../../../lib/samagotchi/web/public/ctx_tokens.js";

const part = (kind, label, tokens, ref = null) => ({ kind, label, chars: tokens * 4, tokens, ref });
const PARTS = [
  part("tools", "31 declared", 6200),
  part("base", "base prompt", 2100),
  part("identity", "identity", 600, "identity"),
  part("notes", "model_notes_style", 400, "model_notes_style"),
  part("agents", "AGENTS.md", 3400, "/p/AGENTS.md"),
  part("plugins", "btw: aside", 300, "btw/aside"),
  part("indexes", "project memory index", 3000, "project"),
  part("session", "session", 100),
];
const file = (key, at, extra = {}) => ({ kind: "file", key, label: key.split("/").pop(), path: key, ops: ["read"], at, count: 1, state: "live", ...extra });
const mem = (key, at, extra = {}) => ({ kind: "memory", key, label: key, ops: ["read"], at, count: 1, state: "live", ...extra });
const at = (turn, step = 0) => ({ turn, step, row: 0 });

function setOf({ turns = [], notes = [], preloaded = [], used = [], server = null } = {}) {
  const set = sessionItems({ turns, notes, preloaded, used });
  return { items: overlay(set.items, server), muted: set.muted };
}

test("headSections: no parts (an old session or worker, a participant) is null, today's list", () => {
  const set = setOf({ turns: [[file("/p/a.rb", at(0))]] });
  assert.equal(headSections(set, 6, {}), null);
  assert.equal(headSections(set, 6, { parts: [] }), null);
  assert.equal(headSections(set, 6, { parts: null, ctxTokens: 9000 }), null);
});

test("headSections: the parts in prompt order, the tools part first; part rows a label, a sub, their tokens", () => {
  const set = setOf({ notes: [{ name: "model_notes_style" }], turns: [[file("/p/a.rb", at(0))]] });
  const [start, read] = headSections(set, 6, { parts: PARTS, turns: 1 });
  assert.equal(start.key, "start");
  assert.equal(start.title, "From the start");
  assert.equal(start.meta, "8 parts · in every turn");
  assert.equal(start.tokens, 16100);
  assert.deepEqual(start.rows.map((r) => [r.kind, r.label, r.sub ?? null]), [
    ["part", "tools", "31 declared"], ["part", "base prompt", ""], ["memory", "identity", null], ["memory", "model_notes_style", null],
    ["part", "AGENTS.md", "project instructions"], ["part", "btw: aside", "plugin section"], ["part", "project memory index", ""],
    ["part", "session", ""],
  ]);
  assert.deepEqual(start.rows.filter((r) => r.kind === "part").map((r) => r.partTokens), [6200, 2100, 3400, 300, 3000, 100]);
  assert.equal(read.key, "read");
  assert.deepEqual(read.inner.map((s) => s.key), ["files"]);
  // A turn lens: the meta drops the count.
  assert.equal(headSections(set, 6, { parts: PARTS, inTurn: true })[0].meta, "in every turn");
});

test("headSections: a memory part IS the memory row: merged with the set's row (note), its own row (identity), system/x is x", () => {
  // A preloaded system/x and a turn's read of x: one row, in the start section only.
  const parts = [...PARTS, part("preloads", "x", 50, "x")];
  const set = setOf({
    notes: [{ name: "model_notes_style" }], preloaded: ["system/x"],
    turns: [[mem("x", at(0, 1)), file("/p/a.rb", at(0))]],
    server: { items: [{ kind: "memory", key: "x", state: "live", tokens: 80 }], at: 3 },
  });
  const [start, read] = headSections(set, 6, { parts });
  const x = start.rows.find((r) => r.label === "x");
  assert.equal(x.kind, "memory");
  assert.equal(x.key, "x", "the read one's key: a steer line names it");
  assert.deepEqual(x.mergedKeys.sort(), ["memory:system/x", "memory:x"]);
  assert.equal(x.preloaded, true);
  assert.equal(x.partTokens, 50);
  assert.equal(x.tokens, 80);
  assert.deepEqual(x.at, at(0, 1));
  // The note row is the set's (prompt-memories put it there); identity has none: its own row.
  const note = start.rows.find((r) => r.label === "model_notes_style");
  assert.deepEqual([note.kind, note.preloaded, note.ops], ["memory", true, []]);
  const identity = start.rows.find((r) => r.label === "identity");
  assert.deepEqual([identity.kind, identity.key, identity.ops, identity.mergedKeys], ["memory", "identity", [], []]);
  // Read lists neither of them, nor x.
  assert.deepEqual(read.inner.map((s) => s.key), ["files"]);
  assert.equal(memoryName("system/x"), "x");
  assert.equal(memoryName("project/notes/a"), "notes/a");
  assert.equal(memoryName("other/x"), "other/x");
});

test("held twice: a start memory row read again; its tokens the part's + the read's; the turn lens note", () => {
  const set = setOf({
    notes: [{ name: "model_notes_style" }], turns: [[mem("model_notes_style", at(0, 2))]],
    server: { items: [{ kind: "memory", key: "model_notes_style", state: "live", tokens: 400 }], at: 3 },
  });
  const [start] = headSections(set, 6, { parts: PARTS });
  const note = start.rows.find((r) => r.label === "model_notes_style");
  const identity = start.rows.find((r) => r.label === "identity");
  assert.equal(heldTwice(note), true);
  assert.equal(heldTwice(identity), false);
  assert.equal(startTokensText(note), "~400 +400");
  assert.equal(startTokensText(identity), "~600");
  assert.equal(memoryPartWords(note), "model note");
  assert.equal(memoryPartWords(identity), "identity memory");
  assert.equal(heldTwiceNote(note, { ops: ["read"] }), "read again in this turn: already in the prompt, held twice (+400)");
  assert.equal(heldTwiceNote({ ...note, tokens: undefined }, { ops: ["read"] }), "read again in this turn: already in the prompt, held twice");
  assert.equal(heldTwiceNote(note, { ops: ["write"] }), "");
  assert.equal(heldTwiceNote(note, undefined), "");
});

test("lensTouched: a turn's read under the set's other spelling lights the merged row", () => {
  const set = setOf({ preloaded: ["system/x"], turns: [[mem("system/x", at(0))]] });
  const sections = headSections(set, 6, { parts: [part("preloads", "x", 50, "x")] });
  const turnItem = mem("system/x", at(0));
  const touched = new Map([["memory:system/x", turnItem]]);
  const out = lensTouched(sections, touched);
  assert.equal(out.get("memory:system/x"), turnItem);
  assert.equal(touched.size, 1, "the given map is not changed");
  assert.equal(lensTouched(null, touched), touched);
  assert.equal(lensTouched(sections, null), null);
});

test("the conversation row: the context's tokens minus the parts' and the held items'; none unknown or nothing left", () => {
  const set = setOf({
    turns: [[file("/p/a.rb", at(0)), file("/p/b.rb", at(0)), file("/p/c.rb", at(1))]],
    server: { items: [
      { kind: "file", key: "/p/a.rb", state: "live", tokens: 1000 }, { kind: "file", key: "/p/b.rb", state: "stale", tokens: 500 },
      { kind: "file", key: "/p/c.rb", state: "forgotten", tokens: 700 },
    ], at: 5 },
  });
  const parts = [part("tools", "3 declared", 2000), part("base", "base prompt", 1000)];
  const sections = headSections(set, 6, { parts, ctxTokens: 10000, turns: 2 });
  assert.deepEqual(sections.map((s) => s.key), ["start", "read", "talk"]);
  const [, read, talk] = sections;
  assert.equal(read.meta, "2 held · 1 out");
  assert.equal(read.tokens, 1500, "the forgotten one isn't sent");
  assert.equal(talk.title, "Conversation");
  assert.equal(talk.tokens, 10000 - 3000 - 1500);
  assert.deepEqual([talk.rows[0].label, talk.rows[0].sub, talk.rows[0].partTokens], ["conversation", "2 turns", 5500]);
  // A start memory's read counts as held too.
  const withNote = setOf({ notes: [{ name: "n" }], turns: [[mem("n", at(0))]], server: { items: [{ kind: "memory", key: "n", state: "live", tokens: 300 }], at: 1 } });
  const t = headSections(withNote, 6, { parts: [part("notes", "n", 100, "n")], ctxTokens: 1000, turns: 1 }).at(-1);
  assert.deepEqual([t.key, t.tokens, t.rows[0].sub], ["talk", 600, "1 turn"]);
  // Unknown context, or nothing left over: no row.
  assert.deepEqual(headSections(set, 6, { parts, ctxTokens: null }).map((s) => s.key), ["start", "read"]);
  assert.deepEqual(headSections(set, 6, { parts, ctxTokens: 4500 }).map((s) => s.key), ["start", "read"]);
});

test("the head line: '~X of Y', no 'of Y' without a window, nothing without the context's tokens", () => {
  assert.equal(headLine(37700, 128000), "in chi's head now · ~38k of 128k");
  assert.equal(headLine(840, null), "in chi's head now · ~840");
  assert.equal(headLine(null, 128000), "");
  assert.equal(headLine(undefined, undefined), "");
});

test("foldedSections: the stored JSON list of keys; anything else folds nothing", () => {
  assert.deepEqual([...foldedSections('["start","talk"]')], ["start", "talk"]);
  assert.deepEqual([...foldedSections(null)], []);
  assert.deepEqual([...foldedSections("{")], []);
  assert.deepEqual([...foldedSections('{"a":1}')], []);
  assert.deepEqual([...foldedSections('["start",3]')], ["start"]);
});

test("ctxTokensOf: a context_status's estimated used tokens, a chunk's total; loadedCtxTokens: the live % as tokens, else the saved count", () => {
  assert.equal(ctxTokensOf({ usage: { estimated_used_tokens: 1200, estimated_pct: 3 } }), 1200);
  assert.equal(ctxTokensOf({ counts: { total_tokens: 900 } }), 900);
  assert.equal(ctxTokensOf({ usage: null }), null);
  assert.equal(ctxTokensOf(null), null);
  assert.equal(loadedCtxTokens({ pct: 25, context: { window_tokens: 100000, used_tokens: 1 } }), 25000);
  assert.equal(loadedCtxTokens({ pct: 50, context: { window_tokens: 100000 }, budgetTokens: 20000 }), 10000, "counted against the smaller budget");
  assert.equal(loadedCtxTokens({ pct: 25, context: { used_tokens: 777 } }), 777, "no window: the saved count");
  assert.equal(loadedCtxTokens({ context: { used_tokens: 777, window_tokens: 1000 } }), 777);
  assert.equal(loadedCtxTokens({}), null);
});

test("a struck read is not held: no held twice, no +X, no note, not in the conversation's arithmetic", () => {
  for (const state of ["forgotten", "dropped"]) {
    const set = setOf({
      notes: [{ name: "n" }], turns: [[mem("n", at(0))]],
      server: { items: [{ kind: "memory", key: "n", state, tokens: 300 }], at: 1 },
    });
    const sections = headSections(set, 6, { parts: [part("notes", "n", 100, "n")], ctxTokens: 1000, turns: 1 });
    const row = sections[0].rows[0];
    assert.equal(row.state, state);
    assert.equal(heldTwice(row), false, state);
    assert.equal(startTokensText(row), "~100", state);
    assert.equal(heldTwiceNote(row, { ops: ["read"] }), "", state);
    assert.equal(sections.at(-1).tokens, 900, `${state}: its tokens aren't sent`);
  }
});

test("the conversation counts a start memory's tokens only when it was read (startTokensText's gate)", () => {
  // Tokens without a read (the server's, on an edit-only row): not held, not counted.
  const set = setOf({ notes: [{ name: "n" }], turns: [[{ ...mem("n", at(0)), ops: ["write"] }]], server: { items: [{ kind: "memory", key: "n", state: "live", tokens: 300 }], at: 1 } });
  const sections = headSections(set, 6, { parts: [part("notes", "n", 100, "n")], ctxTokens: 1000, turns: 1 });
  assert.equal(startTokensText(sections[0].rows[0]), "~100");
  assert.equal(sections.at(-1).tokens, 900);
});

test("a ref-less preloads / notes part: the preloaded-only memories stay out of the read section and its count", () => {
  const set = setOf({ preloaded: ["a", "b"], notes: [{ name: "model_notes_x" }], turns: [[file("/p/a.rb", at(0)), mem("b", at(0))]],
    server: { items: [{ kind: "file", key: "/p/a.rb", state: "live", tokens: 10 }, { kind: "memory", key: "b", state: "live", tokens: 20 }], at: 2 } });
  const parts = [part("tools", "1 declared", 10), part("preloads", "preloads", 50), part("notes", "notes", 40)];
  const [start, read] = headSections(set, 6, { parts });
  assert.deepEqual(start.rows.map((r) => r.kind), ["part", "part", "part"]);
  const listed = read.inner.flatMap((s) => s.labels.flatMap((l) => l.members.map((m) => m.key)));
  assert.deepEqual(listed.sort(), ["/p/a.rb", "b"], "a and model_notes_x (never read) are the prompt's; b was read");
  assert.equal(read.meta, "2 held");
});
