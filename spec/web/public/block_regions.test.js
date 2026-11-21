import test from "node:test";
import assert from "node:assert/strict";
import { cleanRegions, cleanText, MAX_REGION_BYTES, MAX_REGIONS, REGION_KINDS } from "../../../lib/samagotchi/web/public/block_regions.js";

const node = (over = {}) => ({ kind: "node", id: "BR", label: "Bridge", box: [0.1, 0.2, 0.3, 0.1], ...over });
const edge = (over = {}) => ({ kind: "edge", id: "", label: "events", points: [[0.1, 0.5], [0.9, 0.5]], from: "BR", to: "EN", ...over });
const one = (raw) => cleanRegions([raw]);

test("the four kinds, cleaned into new objects with known keys only", () => {
  assert.deepEqual([...REGION_KINDS], ["node", "group", "edge", "note"]);
  const raw = node({ extra: "x", onclick: "y" });
  const [clean] = cleanRegions([raw]);
  assert.deepEqual(clean, { kind: "node", id: "BR", label: "Bridge", box: [0.1, 0.2, 0.3, 0.1] });
  assert.notEqual(clean, raw);
  assert.notEqual(clean.box, raw.box);
  assert.deepEqual(one(edge()), [{ kind: "edge", id: "", label: "events", points: [[0.1, 0.5], [0.9, 0.5]], from: "BR", to: "EN" }]);
  assert.deepEqual(one(node({ kind: "group" }))[0].kind, "group");
  assert.deepEqual(one(node({ kind: "note" }))[0].kind, "note");
});

test("not an array, or nothing sent: null; an unknown kind or a non-object entry is skipped", () => {
  assert.equal(cleanRegions(undefined), null);
  assert.equal(cleanRegions({ length: 1, 0: node() }), null);
  assert.equal(cleanRegions("[]"), null);
  assert.deepEqual(cleanRegions([null, 1, "node", [node()], node({ kind: "toString" }), node({ kind: "__proto__" }), node()]), [one(node())[0]]);
  class Fancy { constructor() { Object.assign(this, node()); } }
  assert.deepEqual(cleanRegions([new Fancy()]), []);
});

test("over 600 entries: null, never cut", () => {
  const many = Array.from({ length: MAX_REGIONS + 1 }, () => node());
  assert.equal(cleanRegions(many), null);
  assert.equal(cleanRegions(many.slice(1)).length, MAX_REGIONS);
});

test("a number where a string goes is \"\"; an object as id isn't stringified", () => {
  let called = 0;
  const sneaky = { toString() { called += 1; return "<b>"; } };
  assert.deepEqual(one(node({ id: 42, label: sneaky })), [{ kind: "node", id: "", label: "", box: [0.1, 0.2, 0.3, 0.1] }]);
  assert.equal(called, 0);
});

test("a box: 4 finite numbers, clamped, cut to the picture; no area skips a node, an edge loses its box", () => {
  assert.deepEqual(one(node({ box: [-0.5, 1e9, 0.5, 0.5] })), []); // y clamped to 1: no height left
  assert.deepEqual(one(node({ box: [-0.5, 0.2, 2, 0.1] }))[0].box, [0, 0.2, 1, 0.1]);
  assert.ok(Math.abs(one(node({ box: [0.8, 0.2, 0.5, 0.1] }))[0].box[2] - 0.2) < 1e-9, "cut at the right edge");
  for (const bad of [[0.1, 0.2, 0.3, NaN], [0.1, 0.2, 0.3, Infinity], [0.1, 0.2, 0.3], [0.1, 0.2, 0.3, 0.1, 0.1], ["0.1", 0.2, 0.3, 0.1], [0.1, 0.2, 0.3, 1n], "0 0 1 1"]) {
    assert.deepEqual(one(node({ box: bad })), [], String(bad));
  }
  const [e] = one(edge({ box: [0.1, 0.2, NaN, 0.1] }));
  assert.equal("box" in e, false);
  assert.deepEqual(one(edge({ box: [0.4, 0.45, 0.2, 0.1] }))[0].box, [0.4, 0.45, 0.2, 0.1]);
});

test("points: 2..16 pairs of finite numbers, clamped; anything else skips the edge", () => {
  const pts = (n) => Array.from({ length: n }, (_, i) => [i / n, 0.5]);
  assert.equal(one(edge({ points: pts(16) }))[0].points.length, 16);
  assert.deepEqual(one(edge({ points: pts(17) })), []);
  assert.deepEqual(one(edge({ points: pts(1) })), []);
  assert.deepEqual(one(edge({ points: [[0, 0, 0], [1, 1, 1]] })), []);
  assert.deepEqual(one(edge({ points: [[0, NaN], [1, 1]] })), []);
  assert.deepEqual(one(edge({ points: undefined })), []);
  assert.deepEqual(one(edge({ points: [[-1, 2], [0.5, 0.5]] }))[0].points, [[0, 1], [0.5, 0.5]]);
});

test("a __proto__ own key, a cycle and a BigInt are data, never followed", () => {
  const raw = JSON.parse('{"kind":"node","id":"A","label":"a","box":[0,0,0.5,0.5],"__proto__":{"polluted":true}}');
  const [clean] = one(raw);
  assert.equal(clean.polluted, undefined);
  assert.equal({}.polluted, undefined);
  const cyclic = node();
  cyclic.self = cyclic;
  cyclic.label = cyclic;
  assert.deepEqual(one(cyclic), [{ kind: "node", id: "BR", label: "", box: [0.1, 0.2, 0.3, 0.1] }]);
  assert.deepEqual(one(node({ id: 10n })), [{ kind: "node", id: "", label: "Bridge", box: [0.1, 0.2, 0.3, 0.1] }]);
});

test("past the bytes budget over the cleaned fields: null", () => {
  // Each entry keeps 80 + 120 chars + 4 numbers (48): 248; the budget holds 528 of them.
  const big = () => node({ id: "i".repeat(500), label: "l".repeat(500) });
  const fits = Math.floor(MAX_REGION_BYTES / 248);
  assert.equal(cleanRegions(Array.from({ length: fits }, big)).length, fits);
  assert.equal(cleanRegions(Array.from({ length: fits + 1 }, big)), null);
});

test("a 200 KB label is cut to 120 code points, quickly", () => {
  const started = performance.now();
  const [clean] = one(node({ label: "x".repeat(200 * 1024) }));
  assert.equal(clean.label.length, 120);
  assert.ok(performance.now() - started < 50);
});

test("text: one line, no controls, bidi or zero-width characters, runs of whitespace one space, cut by code points", () => {
  assert.equal(cleanText("a b c\u0085d\ne\tf", 80), "a b c d e f");
  assert.equal(cleanText("‮evil​⁦x", 80), "evilx");
  assert.equal(cleanText("  a   \n\n  b  ", 80), "a b");
  assert.equal(cleanText(`${"a".repeat(79)}😀😀`, 80), `${"a".repeat(79)}😀`);
  assert.equal(cleanText(`${"a".repeat(79)}😀`, 80).length, 81);
  assert.equal(cleanText("x\uD800y", 80), "xy", "a lone surrogate goes");
  assert.equal(cleanText("<img src=x onerror=alert(1)>", 120), "<img src=x onerror=alert(1)>", "text stays its characters");
  assert.equal(cleanText(["a"], 80), "");
});
