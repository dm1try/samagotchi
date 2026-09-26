import test from "node:test";
import assert from "node:assert/strict";
import { currentSentence, createTicker } from "../../../lib/samagotchi/web/public/thinking_ticker.js";

// currentSentence(text, { maxLen = 160 }): the newest complete sentence, else
// the trailing fragment when longer than maxLen, else "".

test("currentSentence: no boundary yet → ''", () => {
  assert.equal(currentSentence(""), "");
  assert.equal(currentSentence("   "), "");
  assert.equal(currentSentence("just some words flowing"), "");
});

test("currentSentence: one sentence", () => {
  assert.equal(currentSentence("Hello world."), "Hello world.");
});

test("currentSentence: quote/bracket after the period", () => {
  assert.equal(currentSentence('She said "stop."'), 'She said "stop."');
  assert.equal(currentSentence("The result (42) is ready."), "The result (42) is ready.");
});

test("currentSentence: newline boundary", () => {
  assert.equal(currentSentence("line one\nline two"), "line one");
  assert.equal(currentSentence("line one\nline two\n"), "line two");
});

test("currentSentence: a bare list number is a marker, not a sentence", () => {
  assert.equal(currentSentence("Plan:\n1. check the log\n2. write it up\n"), "2. write it up");
  assert.equal(currentSentence("1. check the log\n2. write"), "1. check the log");
  assert.equal(currentSentence("Recent:\n118. `d48e707` - Attached TUI stays up\n119. `x` - next"), "118. `d48e707` - Attached TUI stays up");
  // The number alone is not a sentence yet.
  assert.equal(currentSentence("Recent:\n118. "), "Recent:");
  // A number that ends a real sentence still splits.
  assert.equal(currentSentence("It took 3. Then more."), "Then more.");
});

test("currentSentence: ellipsis …", () => {
  assert.equal(currentSentence("Wait… then act."), "then act.");
  assert.equal(currentSentence("Wait…"), "Wait…");
});

test("currentSentence: multiple sentences → the newest", () => {
  assert.equal(currentSentence("First. Second. Third."), "Third.");
});

test("currentSentence: fragment longer than maxLen counts; shorter → ''", () => {
  assert.equal(currentSentence("x".repeat(160)), "");
  assert.equal(currentSentence("x".repeat(161)), "x".repeat(161));
});

test("currentSentence: whitespace collapsed, trimmed", () => {
  assert.equal(
    currentSentence("Hello    world.\n\n  This is  a test.  "),
    "This is a test.",
  );
});

// createTicker({ now, dwellMs = 1500 }): { feed, tick, close }, clock-free.

test("createTicker: nothing shown, no boundary → unchanged", () => {
  const t = createTicker({ now: () => 0 });
  assert.deepEqual(t.feed("no boundary"), { line: "", changed: false, dueIn: 0 });
});

test("createTicker: first sentence shows immediately (nothing shown yet)", () => {
  const t = createTicker({ now: () => 0 });
  assert.deepEqual(t.feed("Hello."), { line: "Hello.", changed: true, dueIn: 0 });
});

test("createTicker: same sentence → no change", () => {
  const t = createTicker({ now: () => 0 });
  t.feed("Hello.");
  assert.deepEqual(t.feed("Hello. "), { line: "Hello.", changed: false, dueIn: 0 });
});

test("createTicker: dwell holds the first line, then jumps to the newest (skips the incomplete middle)", () => {
  let now = 0;
  const t = createTicker({ now: () => now, dwellMs: 1500 });
  assert.deepEqual(t.feed("Hello."), { line: "Hello.", changed: true, dueIn: 0 });
  now = 500;
  // incomplete: no complete sentence → no change
  assert.deepEqual(t.feed("Hello. This is"), { line: "Hello.", changed: false, dueIn: 0 });
  now = 1000;
  // a complete sentence, but the dwell has not passed → pending
  assert.deepEqual(t.feed("Hello. This is a test."), { line: "Hello.", changed: false, dueIn: 500 });
  now = 1500;
  // dwell passed → shows the newest (the incomplete middle was skipped)
  assert.deepEqual(t.tick(), { line: "This is a test.", changed: true, dueIn: 0 });
});

test("createTicker: dueIn counts down", () => {
  let now = 0;
  const t = createTicker({ now: () => now, dwellMs: 1500 });
  t.feed("First sentence.");
  now = 200;
  assert.deepEqual(t.feed("First sentence. Second."), { line: "First sentence.", changed: false, dueIn: 1300 });
  now = 400;
  assert.deepEqual(t.tick(), { line: "First sentence.", changed: false, dueIn: 1100 });
});

test("createTicker: feed keeps overwriting pending with the newest, tick shows it when due", () => {
  let now = 0;
  const t = createTicker({ now: () => now, dwellMs: 1500 });
  t.feed("First.");
  now = 1000;
  assert.deepEqual(t.feed("First. Second."), { line: "First.", changed: false, dueIn: 500 });
  now = 1200;
  assert.deepEqual(t.feed("First. Second. Third."), { line: "First.", changed: false, dueIn: 300 });
  now = 1500;
  assert.deepEqual(t.tick(), { line: "Third.", changed: true, dueIn: 0 });
});

test("createTicker: after close nothing shows", () => {
  const t = createTicker({ now: () => 0 });
  t.feed("Something.");
  assert.equal(t.close(), "");
  assert.deepEqual(t.feed("After close."), { line: "", changed: false, dueIn: 0 });
});
