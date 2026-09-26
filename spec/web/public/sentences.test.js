import test from "node:test";
import assert from "node:assert/strict";
import { splitSentences, createSentenceFeed } from "../../../lib/samagotchi/web/public/sentences.js";

// splitSentences(raw, { atEnd }): every complete sentence so far (collapsed),
// the trailing raw fragment and where it starts.

test("splitSentences: sentences, rest and restStart", () => {
  assert.deepEqual(splitSentences("A.  B! C", { atEnd: false }), { sentences: ["A.", "B!"], rest: "C", restStart: 7 });
  assert.deepEqual(splitSentences("", { atEnd: false }), { sentences: [], rest: "", restStart: 0 });
});

test("splitSentences: the end of the input is a boundary only with atEnd", () => {
  assert.deepEqual(splitSentences("Use version 3.", { atEnd: false }).sentences, []);
  assert.deepEqual(splitSentences("Use version 3.", { atEnd: true }).sentences, ["Use version 3."]);
});

test("splitSentences: a newline is a boundary, a blank line no sentence, whitespace collapsed", () => {
  assert.deepEqual(splitSentences("line  one\n\nline two\n", { atEnd: false }).sentences, ["line one", "line two"]);
});

test("splitSentences: a quote or bracket after the period belongs to the sentence", () => {
  assert.deepEqual(splitSentences('She said "stop." Then (42). x', { atEnd: false }).sentences, ['She said "stop."', "Then (42)."]);
});

test("splitSentences: a bare list number is a marker, not a sentence", () => {
  const r = splitSentences("Plan:\n1. check\n2. write", { atEnd: false });
  assert.deepEqual(r.sentences, ["Plan:", "1. check"]);
  assert.equal(r.rest, "2. write");
  assert.deepEqual(splitSentences("Recent:\n118. ", { atEnd: true }), { sentences: ["Recent:"], rest: "118. ", restStart: 8 });
});

// createSentenceFeed({ maxLen = 160 }): { feed, flush, reset } over an
// accumulating text; feed returns the sentences completed since the last call.

test("feed: incremental feeds return only the newly completed sentences", () => {
  const f = createSentenceFeed();
  assert.deepEqual(f.feed("A. "), ["A."]);
  assert.deepEqual(f.feed("A. B"), []);
  assert.deepEqual(f.feed("A. B. C. D"), ["B.", "C."]);
});

test("feed: the end of the text so far is no boundary (a decimal is not taken back)", () => {
  const f = createSentenceFeed();
  assert.deepEqual(f.feed("Use version 3."), []);
  assert.deepEqual(f.feed("Use version 3.5 now. "), ["Use version 3.5 now."]);
});

test("feed: newline boundary, quote after the period", () => {
  const f = createSentenceFeed();
  assert.deepEqual(f.feed('He said "go."\nnext'), ['He said "go."']);
  assert.deepEqual(f.feed('He said "go."\nnext line\n'), ["next line"]);
});

test("feed: the list guard never yields a bare number", () => {
  const f = createSentenceFeed();
  assert.deepEqual(f.feed("1. "), []);
  assert.deepEqual(f.feed("1. check\n2. "), ["1. check"]);
  assert.deepEqual(f.feed("1. check\n2. write"), []);
  assert.deepEqual(f.flush("1. check\n2. write"), ["2. write"]);
});

test("feed: a fragment longer than maxLen is cut as a sentence and not repeated", () => {
  const f = createSentenceFeed();
  const run = "x".repeat(161);
  assert.deepEqual(f.feed(run), [run]);
  assert.deepEqual(f.feed(run + "yy"), []);
  assert.deepEqual(f.flush(run + "yy"), ["yy"]);
});

test("feed: a fragment of maxLen or shorter waits", () => {
  const f = createSentenceFeed();
  assert.deepEqual(f.feed("x".repeat(160)), []);
});

test("flush: the remainder is one collapsed sentence, consumed", () => {
  const f = createSentenceFeed();
  assert.deepEqual(f.feed("Let me check the shell first"), []);
  assert.deepEqual(f.flush("Let me check the shell first"), ["Let me check the shell first"]);
  assert.deepEqual(f.feed("Let me check the shell first"), []);
  assert.deepEqual(f.flush("Let me check the shell first"), []);
});

test("flush: unfed complete sentences come first, then the remainder; blank → []", () => {
  const f = createSentenceFeed();
  assert.deepEqual(f.flush("A. B.  C"), ["A.", "B.", "C"]);
  assert.deepEqual(createSentenceFeed().flush("  \n "), []);
  assert.deepEqual(createSentenceFeed().flush(""), []);
});

test("feed: a text shorter than what was consumed resyncs and returns []", () => {
  const f = createSentenceFeed();
  assert.deepEqual(f.feed("A. B. "), ["A.", "B."]);
  assert.deepEqual(f.feed("A."), []);
  assert.deepEqual(f.feed("A. C. "), ["C."]);
});

test("reset: starts over", () => {
  const f = createSentenceFeed();
  f.feed("A. ");
  f.reset();
  assert.deepEqual(f.feed("A. "), ["A."]);
});
