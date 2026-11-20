import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  foldedSections, headItems, headLine, headSections, heldTwice, heldTwiceNote, lensTouched, memoryName, memoryPartWords, promptKeys, same, startTokensText,
} from "../../../lib/samagotchi/web/public/ws_sections.js";
import { overlay, sessionItems, turnLens } from "../../../lib/samagotchi/web/public/working_set.js";
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

// The sections by key (every reader finds one by its key; the drawn order is
// read, talk, start).
const byKey = (sections) => Object.fromEntries(sections.map((s) => [s.key, s]));

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
  const { start, read } = byKey(headSections(set, 6, { parts: PARTS, turns: 1 }));
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
  assert.equal(byKey(headSections(set, 6, { parts: PARTS, inTurn: true })).start.meta, "in every turn");
});

test("headSections: a memory part IS the memory row: merged with the set's row (note), its own row (identity), system/x is x", () => {
  // A preloaded system/x and a turn's read of x: one row, in the start section only.
  const parts = [...PARTS, part("preloads", "x", 50, "x")];
  const set = setOf({
    notes: [{ name: "model_notes_style" }], preloaded: ["system/x"],
    turns: [[mem("x", at(0, 1)), file("/p/a.rb", at(0))]],
    server: { items: [{ kind: "memory", key: "x", state: "live", tokens: 80 }], at: 3 },
  });
  const { start, read } = byKey(headSections(set, 6, { parts }));
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
  const { start } = byKey(headSections(set, 6, { parts: PARTS }));
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

// Scope + name: a part and a set memory are one row when their names match and
// their scopes do, or either lacks one (an older worker's).
const scoped = (kind, name, tokens, scope) => ({ ...part(kind, name, tokens, name), ...(scope ? { scope } : {}) });
const readX = (scope, extra = {}) => setOf({
  preloaded: ["x"], turns: [[mem("x", at(1, 0))]],
  server: { items: [{ kind: "memory", key: "x", state: "live", tokens: 80, ...(scope ? { scope } : {}) }], at: 3 }, ...extra,
});

test("scope match: a project x read beside a system x preloaded is two rows, no held twice", () => {
  const set = readX("project");
  const sections = headSections(set, 6, { parts: [scoped("preloads", "x", 50, "system")] });
  const { start, read } = byKey(sections);
  const own = start.rows.find((r) => r.label === "x");
  assert.equal(own.key, "x@system", "its own key: never the read item's");
  assert.deepEqual([own.ops, own.mergedKeys, own.preloaded], [[], [], true]);
  assert.equal(heldTwice(own), false);
  assert.equal(heldTwiceNote(own, { ops: ["read"] }), "");
  assert.equal(memoryPartWords(own), "preloaded · system");
  assert.equal(startTokensText(own), "~50");
  // The project x stays in Read, a plain read (not "the prompt's").
  const memories = read.inner.find((s) => s.key === "memories");
  const x = memories.labels.flatMap((l) => l.members).find((m) => m.key === "x");
  assert.deepEqual([x.scope, x.preloaded, x.tokens], ["project", false, 80]);
  assert.equal(read.tokens, 80);
  // A turn lens: the read is new to the head (not a prompt memory); the turn's
  // read of x (no scope in a tool title) lights the system row by name too.
  assert.equal(promptKeys(sections).has("memory:x"), false);
  const lit = lensTouched(sections, new Map([["memory:x", mem("x", at(1, 0))]]));
  assert.ok(lit.has("memory:x@system"));
});

test("scope match: a system x read beside a system x preloaded is one row, held twice", () => {
  const set = readX("system");
  const { start, read } = byKey(headSections(set, 6, { parts: [scoped("preloads", "x", 50, "system")] }));
  const x = start.rows.find((r) => r.label === "x");
  assert.equal(x.key, "x");
  assert.deepEqual(x.mergedKeys, ["memory:x"]);
  assert.equal(heldTwice(x), true);
  assert.equal(startTokensText(x), "~50 +80");
  assert.equal(memoryPartWords(x), "preloaded");
  assert.deepEqual(read.inner.map((s) => s.key), []);
});

test("scope match: a scope either side lacks falls back to the name alone (an older worker's part or item)", () => {
  for (const [partScope, itemScope] of [[null, "project"], ["system", null], [null, null]]) {
    const { start } = byKey(headSections(readX(itemScope), 6, { parts: [scoped("preloads", "x", 50, partScope)] }));
    const x = start.rows.find((r) => r.label === "x");
    assert.equal(x.key, "x", `${partScope}/${itemScope}`);
    assert.equal(heldTwice(x), true, `${partScope}/${itemScope}`);
  }
  assert.equal(same({ ref: "x", scope: "system" }, { kind: "memory", key: "x" }), true);
  assert.equal(same({ ref: "x", scope: "system" }, { kind: "memory", key: "x", scope: "project" }), false);
  assert.equal(same({ ref: "x" }, { kind: "memory", key: "system/x", scope: "project" }), true, "an older page's spelling: the name is x");
  assert.equal(same({ ref: "x" }, { kind: "file", key: "x" }), false);
});

test("same: follows the shared prompt-memory scope-and-name cases", () => {
  const cases = JSON.parse(readFileSync(new URL("../../shared/prompt_memory_match.json", import.meta.url), "utf8"));
  for (const { part, target, expected } of cases) {
    assert.equal(same(part, { kind: "memory", key: target.key, scope: target.scope }), expected, JSON.stringify({ part, target }));
  }
});

test("scope match: a project x note and a system x preload are two rows, each its own size", () => {
  const set = setOf({ notes: [{ name: "x" }] });
  const parts = [scoped("notes", "x", 30, "project"), scoped("preloads", "x", 50, "system")];
  const { start } = byKey(headSections(set, 6, { parts }));
  const rows = start.rows.filter((r) => r.label === "x");
  assert.deepEqual(rows.map((r) => [r.key, r.partKind, r.partTokens]), [["x", "notes", 30], ["x@system", "preloads", 50]]);
  assert.equal(new Set(rows.map((r) => `memory:${r.key}`)).size, 2, "never two rows of one key");
  // One scope in two parts (a note also preloaded): one row, both sizes.
  const { start: one } = byKey(headSections(set, 6, { parts: [scoped("notes", "x", 30, "system"), scoped("preloads", "x", 50, "system")] }));
  assert.deepEqual(one.rows.filter((r) => r.label === "x").map((r) => r.partTokens), [80]);
});

test("overlay: a memory's scope from the server; the same object while nothing changed", () => {
  const items = [mem("x", at(0)), file("/p/a.rb", at(0))];
  const server = { items: [{ kind: "memory", key: "x", state: "live", tokens: 5, scope: "project" }, { kind: "file", key: "/p/a.rb", state: "live", tokens: 9, scope: "system" }], at: 2 };
  const once = overlay(items, server);
  assert.equal(once[0].scope, "project");
  assert.equal(once[1].scope, undefined, "a file has none");
  const twice = overlay(once, server);
  assert.equal(twice[0], once[0]);
  assert.equal(twice[1], once[1]);
  const older = overlay(once, { items: [{ kind: "memory", key: "x", state: "live", tokens: 5 }], at: 3 });
  assert.equal(older[0].scope, undefined, "an older worker's item: no scope");
});

test("headItems: a turn lens counts another scope's first read as new (the plain read, not the prompt's)", () => {
  // System x preloaded; project x first read in turn 3.
  const set = setOf({
    preloaded: ["x"], turns: [[], [], [mem("x", at(2, 0))]],
    server: { items: [{ kind: "memory", key: "x", state: "live", tokens: 80, scope: "project" }], at: 5 },
  });
  const parts = [scoped("preloads", "x", 50, "system")];
  const sections = headSections(set, 6, { parts });
  const inPrompt = promptKeys(sections);
  const list = headItems(set, parts).filter((item) => !inPrompt.has(`${item.kind}:${item.key}`));
  assert.equal(turnLens(list, [mem("x", at(2, 0))], 2).fresh, 1);
  assert.equal(turnLens(set.items, [mem("x", at(2, 0))], 2).fresh, 0, "the set's own item still says preloaded");
  // Same scope: the prompt's, never new; no parts: the items as they are.
  const same = readX("system");
  assert.equal(headItems(same, parts).find((i) => i.key === "x").preloaded, true);
  assert.equal(headItems(set, []), set.items);
});

test("lensTouched: a row with a merged read lights by its items' keys only; the bare name lights a part-only row", () => {
  // System x preloaded and read (the page's system/x item), project x read too.
  const set = { items: [mem("system/x", at(0), { preloaded: true, scope: "system" }), mem("x", at(1), { scope: "project", tokens: 80 })], muted: [] };
  const sections = headSections(set, 6, { parts: [scoped("preloads", "x", 50, "system")] });
  const row = byKey(sections).start.rows.find((r) => r.label === "x");
  assert.deepEqual([row.key, row.mergedKeys], ["system/x", ["memory:system/x"]]);
  // A turn that read project x: the merged row stays unlit, no held-twice note.
  const turnX = mem("x", at(1));
  const lit = lensTouched(sections, new Map([["memory:x", turnX]]));
  assert.equal(lit.has("memory:system/x"), false);
  assert.equal(heldTwiceNote(row, lit.get("memory:system/x")), "");
  // A turn that read it under its own key lights it.
  assert.ok(lensTouched(sections, new Map([["memory:system/x", mem("system/x", at(0))]])).has("memory:system/x"));
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
  assert.deepEqual(sections.map((s) => s.key), ["read", "talk", "start"]);
  const [read, talk] = sections;
  assert.equal(read.meta, "2 held · 1 out");
  assert.equal(read.tokens, 1500, "the forgotten one isn't sent");
  assert.equal(talk.title, "Conversation");
  assert.equal(talk.tokens, 10000 - 3000 - 1500);
  assert.deepEqual([talk.rows[0].label, talk.rows[0].sub, talk.rows[0].partTokens], ["conversation", "2 turns", 5500]);
  // A start memory's read counts as held too.
  const withNote = setOf({ notes: [{ name: "n" }], turns: [[mem("n", at(0))]], server: { items: [{ kind: "memory", key: "n", state: "live", tokens: 300 }], at: 1 } });
  const t = byKey(headSections(withNote, 6, { parts: [part("notes", "n", 100, "n")], ctxTokens: 1000, turns: 1 })).talk;
  assert.deepEqual([t.key, t.tokens, t.rows[0].sub], ["talk", 600, "1 turn"]);
  // Unknown context, or nothing left over: no row.
  assert.deepEqual(headSections(set, 6, { parts, ctxTokens: null }).map((s) => s.key), ["read", "start"]);
  assert.deepEqual(headSections(set, 6, { parts, ctxTokens: 4500 }).map((s) => s.key), ["read", "start"]);
});

test("the head line: '~X of Y', no 'of Y' without a window, nothing without the context's tokens", () => {
  assert.equal(headLine(37700, 128000), "in chi's head now · ~38k of 128k");
  assert.equal(headLine(840, null), "in chi's head now · ~840");
  assert.equal(headLine(null, 128000), "");
  assert.equal(headLine(undefined, undefined), "");
});

test("foldedSections: the stored JSON list of keys as it is, an empty one too; nothing stored or unreadable: start folded", () => {
  assert.deepEqual([...foldedSections('["start","talk"]')], ["start"], "Conversation never folds: a stored talk is ignored");
  assert.deepEqual([...foldedSections(null)], ["start"], "nothing stored: the default fold");
  assert.deepEqual([...foldedSections(undefined)], ["start"]);
  assert.deepEqual([...foldedSections("[]")], [], "a stored []: the user opened it, kept");
  assert.deepEqual([...foldedSections('["read"]')], ["read"], "a stored list without start: start open");
  assert.deepEqual([...foldedSections("{")], ["start"]);
  assert.deepEqual([...foldedSections('{"a":1}')], ["start"]);
  assert.deepEqual([...foldedSections('["start",3]')], ["start"]);
});

test("headSections: drawn read, talk, start; start's twice counts the rows held twice", () => {
  const set = setOf({
    notes: [{ name: "n" }, { name: "m" }], turns: [[file("/p/a.rb", at(0)), mem("n", at(0, 1))]],
    server: { items: [{ kind: "memory", key: "n", state: "live", tokens: 300 }, { kind: "file", key: "/p/a.rb", state: "live", tokens: 100 }], at: 1 },
  });
  const parts = [part("tools", "3 declared", 2000), part("notes", "n", 100, "n"), part("notes", "m", 100, "m")];
  const sections = headSections(set, 6, { parts, ctxTokens: 10000, turns: 1 });
  assert.deepEqual(sections.map((s) => s.key), ["read", "talk", "start"]);
  assert.equal(byKey(sections).start.twice, 1, "n is in the prompt and read again; m only in the prompt");
  assert.equal(byKey(sections).read.twice, undefined);
  // Nothing read again: 0.
  const plain = setOf({ notes: [{ name: "m" }], turns: [[file("/p/a.rb", at(0))]] });
  assert.equal(byKey(headSections(plain, 6, { parts })).start.twice, 0);
});

test("headSections: the read section's rows follow the set's order (the view's, last touched first)", () => {
  const items = [file("/p/a.rb", at(0)), file("/p/z/b.rb", at(1)), mem("u", at(1, 1)), mem("v", at(0, 2))];
  const set = { items: [items[2], items[1], items[3], items[0]], muted: [] };
  const { read } = byKey(headSections(set, 6, { parts: [part("tools", "3 declared", 2000)] }));
  const keys = (key) => read.inner.find((s) => s.key === key).labels.flatMap((l) => l.members.map((m) => m.key));
  assert.deepEqual(keys("files"), ["/p/z/b.rb", "/p/a.rb"]);
  assert.deepEqual(keys("memories"), ["u", "v"]);
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
    const row = byKey(sections).start.rows[0];
    assert.equal(row.state, state);
    assert.equal(heldTwice(row), false, state);
    assert.equal(startTokensText(row), "~100", state);
    assert.equal(heldTwiceNote(row, { ops: ["read"] }), "", state);
    assert.equal(byKey(sections).talk.tokens, 900, `${state}: its tokens aren't sent`);
  }
});

test("the conversation counts a start memory's tokens only when it was read (startTokensText's gate)", () => {
  // Tokens without a read (the server's, on an edit-only row): not held, not counted.
  const set = setOf({ notes: [{ name: "n" }], turns: [[{ ...mem("n", at(0)), ops: ["write"] }]], server: { items: [{ kind: "memory", key: "n", state: "live", tokens: 300 }], at: 1 } });
  const sections = headSections(set, 6, { parts: [part("notes", "n", 100, "n")], ctxTokens: 1000, turns: 1 });
  assert.equal(startTokensText(byKey(sections).start.rows[0]), "~100");
  assert.equal(byKey(sections).talk.tokens, 900);
});

test("a ref-less preloads / notes part: the preloaded-only memories stay out of the read section and its count", () => {
  const set = setOf({ preloaded: ["a", "b"], notes: [{ name: "model_notes_x" }], turns: [[file("/p/a.rb", at(0)), mem("b", at(0))]],
    server: { items: [{ kind: "file", key: "/p/a.rb", state: "live", tokens: 10 }, { kind: "memory", key: "b", state: "live", tokens: 20 }], at: 2 } });
  const parts = [part("tools", "1 declared", 10), part("preloads", "preloads", 50), part("notes", "notes", 40)];
  const { start, read } = byKey(headSections(set, 6, { parts }));
  assert.deepEqual(start.rows.map((r) => r.kind), ["part", "part", "part"]);
  const listed = read.inner.flatMap((s) => s.labels.flatMap((l) => l.members.map((m) => m.key)));
  assert.deepEqual(listed.sort(), ["/p/a.rb", "b"], "a and model_notes_x (never read) are the prompt's; b was read");
  assert.equal(read.meta, "2 held");
});
