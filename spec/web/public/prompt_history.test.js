import test from "node:test";
import assert from "node:assert/strict";
import { createPromptHistory } from "../../../lib/samagotchi/web/public/prompt_history.js";

// The composer as the keys see it: its value, the caret at the end (or
// where given), no selection.
const at = (value, start = value.length, end = start) => ({ value, start, end });

function withEntries(list) {
  const h = createPromptHistory();
  h.setEntries(list);
  return h;
}

test("↑ in an empty composer recalls the newest entry, caret at the start", () => {
  const h = withEntries(["one", "two"]);
  assert.deepEqual(h.up(at("")), { value: "two", caret: 0 });
  assert.deepEqual(h.up(at("two", 0)), { value: "one", caret: 0 });
  assert.equal(h.up(at("one", 0)), null, "nothing older");
});

test("↑ on the first line of a draft recalls; on a later line, or with a selection, it doesn't", () => {
  const h = withEntries(["one"]);
  assert.equal(h.up(at("first\nsecond")), null, "caret on line 2");
  assert.equal(h.up(at("first\nsecond", 0, 3)), null, "a selection");
  assert.deepEqual(h.up(at("first\nsecond", 2)), { value: "one", caret: 0 });
});

test("↓ past the newest entry brings the draft back, caret at the end", () => {
  const h = withEntries(["one", "two"]);
  h.up(at("my draft", 0));
  h.up(at("two", 0));
  assert.deepEqual(h.down(at("one", 0)), { value: "two", caret: 3 });
  assert.deepEqual(h.down(at("two")), { value: "my draft", caret: 8 });
  assert.equal(h.down(at("my draft")), null, "browsing ended");
});

test("↓ moves forward only from the last line of a recalled entry", () => {
  const h = withEntries(["a\nb", "c"]);
  h.up(at(""));
  h.up(at("c", 0));
  assert.equal(h.down(at("a\nb", 0)), null, "caret on the first of two lines");
  assert.deepEqual(h.down(at("a\nb", 3)), { value: "c", caret: 1 });
});

test("↓ while not browsing is the browser's", () => {
  const h = withEntries(["one"]);
  assert.equal(h.down(at("")), null);
  assert.equal(h.down(at("typed")), null);
});

test("an entry equal to the one just shown is skipped", () => {
  const h = withEntries(["one", "two", "two", "two"]);
  assert.deepEqual(h.up(at("")), { value: "two", caret: 0 });
  assert.deepEqual(h.up(at("two", 0)), { value: "one", caret: 0 });
  assert.deepEqual(h.down(at("one")), { value: "two", caret: 3 });
  assert.deepEqual(h.down(at("two")), { value: "", caret: 0 });
});

test("a draft equal to the newest entry starts at the one before", () => {
  const h = withEntries(["one", "two"]);
  assert.deepEqual(h.up(at("two", 0)), { value: "one", caret: 0 });
});

test("no entries: the keys are the browser's", () => {
  const h = createPromptHistory();
  assert.equal(h.up(at("")), null);
  assert.equal(h.down(at("")), null);
});

test("a value the history didn't set ends browsing: ↑ starts again from the newest", () => {
  const h = withEntries(["one", "two", "three"]);
  h.up(at(""));
  h.up(at("three", 0));
  // Typing, a send clearing it, a refill: anything else set the value.
  assert.equal(h.down(at("two edited")), null);
  assert.deepEqual(h.up(at("two edited", 0)), { value: "three", caret: 0 });
  assert.deepEqual(h.down(at("three")), { value: "two edited", caret: 10 });
});

test("new entries while browsing keep the place when the shown entry is still there", () => {
  const h = withEntries(["one", "two"]);
  h.up(at("draft"));
  h.setEntries(["one", "two", "three"]);
  assert.deepEqual(h.down(at("two")), { value: "three", caret: 5 });
  assert.deepEqual(h.down(at("three")), { value: "draft", caret: 5 });
});
