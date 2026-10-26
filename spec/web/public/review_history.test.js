// A participant's ↑/↓ list (review_history.js): one per grant, guarded.
import test from "node:test";
import assert from "node:assert/strict";
import { Window } from "happy-dom";
import {
  REVIEW_HISTORY_MAX, forgetReviewHistory, pruneReviewHistory, readReviewHistory, recordReviewComment, rememberReviewHistory,
  reviewHistoryKey, withComment,
} from "../../../lib/samagotchi/web/public/review_history.js";

if (!("localStorage" in globalThis)) globalThis.localStorage = new Window().localStorage;

test("withComment: added at the end, trimmed, not twice in a row, the oldest dropped past the cap", () => {
  assert.deepEqual(withComment([], "  a "), ["a"]);
  assert.deepEqual(withComment(["a"], "a"), ["a"]);
  assert.deepEqual(withComment(["a", "b"], "a"), ["a", "b", "a"]);
  assert.deepEqual(withComment(["a"], "   "), ["a"]);
  const full = Array.from({ length: REVIEW_HISTORY_MAX }, (_, i) => `c${i}`);
  const next = withComment(full, "new");
  assert.equal(next.length, REVIEW_HISTORY_MAX);
  assert.equal(next[0], "c1");
  assert.equal(next.at(-1), "new");
});

test("one list per grant; none without a grant id; forgetting one keeps the others", (t) => {
  t.after(() => { forgetReviewHistory("g1"); forgetReviewHistory("g2"); });
  assert.equal(reviewHistoryKey(""), null);
  recordReviewComment(undefined, "lost");
  assert.deepEqual(readReviewHistory(undefined), []);
  recordReviewComment("g1", "one");
  recordReviewComment("g2", "two");
  assert.deepEqual(readReviewHistory("g1"), ["one"]);
  forgetReviewHistory("g1");
  assert.deepEqual(readReviewHistory("g1"), []);
  assert.deepEqual(readReviewHistory("g2"), ["two"]);
});

test("forgetting an ended session uses only its remembered grant, and tolerates no mapping", (t) => {
  t.after(() => {
    forgetReviewHistory("g1", "s1");
    forgetReviewHistory("g2");
    localStorage.removeItem("chi_review_history_session:s2");
  });
  recordReviewComment("g1", "one");
  recordReviewComment("g2", "two");
  rememberReviewHistory("s1", "g1");
  localStorage.setItem("chi_review_history_session:s2", "g2");
  forgetReviewHistory(undefined, "s1");
  assert.deepEqual(readReviewHistory("g1"), []);
  assert.deepEqual(readReviewHistory("g2"), ["two"]);
  assert.doesNotThrow(() => forgetReviewHistory(undefined, "missing"));
});

test("a page's first read drops the lists and pointers of every other link, keeping its own and the rest of storage", (t) => {
  t.after(() => {
    forgetReviewHistory("g-now", "s-now");
    for (const key of ["chi_review_history:g-old", "chi_review_history_session:s-old", "chi_theme"]) localStorage.removeItem(key);
  });
  recordReviewComment("g-old", "an ended link's comment");
  rememberReviewHistory("s-old", "g-old");
  recordReviewComment("g-now", "mine");
  rememberReviewHistory("s-now", "g-now");
  localStorage.setItem("chi_theme", "dark");

  pruneReviewHistory(undefined, "g-now");
  pruneReviewHistory("s-now", undefined);
  assert.deepEqual(readReviewHistory("g-old"), ["an ended link's comment"], "no ids (the owner's view): nothing goes");

  pruneReviewHistory("s-now", "g-now");
  assert.deepEqual(readReviewHistory("g-old"), []);
  assert.equal(localStorage.getItem("chi_review_history_session:s-old"), null);
  assert.deepEqual(readReviewHistory("g-now"), ["mine"]);
  assert.equal(localStorage.getItem("chi_review_history_session:s-now"), "g-now");
  assert.equal(localStorage.getItem("chi_theme"), "dark");
});

test("a list that can't be read or written is no list, never a throw", (t) => {
  const saved = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  Object.defineProperty(globalThis, "localStorage", { configurable: true, get() { throw new Error("blocked"); } });
  t.after(() => Object.defineProperty(globalThis, "localStorage", saved));
  assert.deepEqual(readReviewHistory("g1"), []);
  assert.doesNotThrow(() => recordReviewComment("g1", "x"));
  assert.doesNotThrow(() => rememberReviewHistory("s1", "g1"));
  assert.doesNotThrow(() => forgetReviewHistory(undefined, "s1"));
  assert.doesNotThrow(() => forgetReviewHistory("g1"));
  assert.doesNotThrow(() => pruneReviewHistory("s1", "g1"));
});
