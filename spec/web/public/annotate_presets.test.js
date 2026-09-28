import test from "node:test";
import assert from "node:assert/strict";
import { MAX_PRESETS, parsePresets, presetNote } from "../../../lib/samagotchi/web/public/annotate_presets.js";
import { appendQuote, quoteBlock } from "../../../lib/samagotchi/web/public/annotations.js";

test("parsePresets splits the default on |", () => {
  assert.deepEqual(parsePresets("Agreed|Could you please elaborate?"), ["Agreed", "Could you please elaborate?"]);
});

test("parsePresets trims around | and drops blanks", () => {
  assert.deepEqual(parsePresets("  Yes | No  ||  Why? "), ["Yes", "No", "Why?"]);
});

test("parsePresets gives none for empty, null, undefined and bare separators", () => {
  for (const raw of ["", null, undefined, "|||", "  |  "]) assert.deepEqual(parsePresets(raw), []);
});

test("parsePresets drops repeats and keeps the first", () => {
  assert.deepEqual(parsePresets("Yes|No|Yes| No"), ["Yes", "No"]);
});

test("parsePresets keeps at most five", () => {
  assert.equal(MAX_PRESETS, 5);
  assert.deepEqual(parsePresets("a|b|c|d|e|f|g"), ["a", "b", "c", "d", "e"]);
  // Repeats don't use up a place.
  assert.deepEqual(parsePresets("a|a|b|c|d|e|f"), ["a", "b", "c", "d", "e"]);
});

test("parsePresets keeps unicode as is", () => {
  assert.deepEqual(parsePresets("Согласен|なぜ？|👍"), ["Согласен", "なぜ？", "👍"]);
});

test("presetNote puts the preset under a labelled quote", () => {
  const block = quoteBlock("the quoted line", { kind: "thinking" });
  assert.equal(presetNote(block, "Could you please elaborate?"),
    "From your thinking:\n> the quoted line\n\nCould you please elaborate?");
});

test("presetNote puts the preset under an unlabelled quote", () => {
  const block = quoteBlock("one\ntwo", { kind: "answer" });
  assert.equal(presetNote(block, "Agreed"), "> one\n> two\n\nAgreed");
});

test("a preset quote appended after another quote keeps a blank line between", () => {
  const first = presetNote(quoteBlock("first", { kind: "answer" }), "Agreed");
  const second = presetNote(quoteBlock("second", { kind: "thinking" }), "Why?");
  assert.equal(appendQuote(first, second),
    "> first\n\nAgreed\n\nFrom your thinking:\n> second\n\nWhy?");
});
