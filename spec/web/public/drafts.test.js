// The composer's drafts (drafts.js): the one writer of the message box and
// its chips, over a happy-dom textarea and a stand-in mount.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createDrafts } from "../../../lib/samagotchi/web/public/drafts.js";

// +shown+: the key on view. The mount's chips as composer_mount.js keeps them.
function setup({ shown = "s1", text = "" } = {}) {
  const promptEl = document.createElement("textarea");
  document.body.append(promptEl);
  promptEl.value = text;
  const log = [];
  let list = [];
  const view = {
    chips: () => list,
    setChips: (next, opts) => { log.push(["setChips", next.map((c) => c.name), opts ?? null]); list = next; },
  };
  let key = shown;
  const drafts = createDrafts({
    promptEl, view, fit: () => log.push("fit"), shownKey: () => key,
    reveal: { openForVisit: () => log.push("openForVisit"), focusPrompt: () => log.push("focusPrompt") },
  });
  return { drafts, promptEl, log, view, switchTo: (next) => { key = next; } };
}

test("setText writes the box and fits it; reveal, focus and the caret at the end on demand", () => {
  const { drafts, promptEl, log } = setup();
  drafts.setText("s1", "hello");
  assert.equal(promptEl.value, "hello");
  assert.deepEqual(log, ["fit"]);
  log.length = 0;
  drafts.setText("s1", "line one\nline two", { reveal: true, focus: true, caretEnd: true });
  assert.deepEqual(log, ["openForVisit", "fit", "focusPrompt"]);
  assert.equal(promptEl.selectionStart, "line one\nline two".length);
  assert.equal(promptEl.selectionEnd, "line one\nline two".length);
});

test("text and has read the box and the chips; clear empties the text only, the chips stay", () => {
  const { drafts, promptEl } = setup({ text: "draft" });
  assert.equal(drafts.text("s1"), "draft");
  assert.equal(drafts.has("s1"), true);
  drafts.putChips("s1", [{ name: "a.png" }]);
  drafts.clear("s1");
  assert.equal(promptEl.value, "");
  assert.deepEqual(drafts.chips("s1").map((c) => c.name), ["a.png"]);
  assert.equal(drafts.has("s1"), true, "a chip alone is a draft");
  drafts.putChips("s1", []);
  assert.equal(drafts.has("s1"), false);
  promptEl.value = "   ";
  assert.equal(drafts.has("s1"), false, "white space alone is no draft");
});

test("putChips hands the list to the mount", () => {
  const { drafts, log } = setup();
  drafts.putChips("s1", [{ name: "a.png" }, { name: "b.png" }]);
  assert.deepEqual(log, [["setChips", ["a.png", "b.png"], null]]);
});

// One slot (Phase R): the key is taken, not read yet.
test("one slot: a write for a key not on view still writes the box; move and show change nothing", () => {
  const { drafts, promptEl, switchTo } = setup({ text: "typed" });
  drafts.setText("s2", "for s2");
  assert.equal(promptEl.value, "for s2");
  assert.equal(drafts.text("s1"), "for s2");
  drafts.move("s2", "s3");
  drafts.show("s3");
  switchTo("s3");
  assert.equal(drafts.text("s3"), "for s2");
  assert.equal(promptEl.value, "for s2");
});
