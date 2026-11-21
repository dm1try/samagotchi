import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { failBlock } from "../../../lib/samagotchi/web/public/block_watch.js";
import { ASK_LABEL, askText, FIXED_TEXT, markFixed, noteOf, setFixNote } from "../../../lib/samagotchi/web/public/block_fix_note.js";
import { DRAWN } from "../../../lib/samagotchi/web/public/block_source.js";

function failed(lang = "mermaid", reason = "Parse error on line 4: got 'PS'\nmore detail") {
  const bubble = document.createElement("div");
  bubble.className = "bubble output markdown";
  bubble.innerHTML = `<p>before</p><pre data-lang="${lang}"><code>graph</code></pre>`;
  document.body.append(bubble);
  const pre = bubble.querySelector("pre");
  failBlock(pre, lang, reason, { fixable: true });
  return { bubble, pre };
}

const buttonOf = (pre) => noteOf(pre).querySelector(".block-fix-ask");

test.afterEach(() => { document.body.innerHTML = ""; });

// One per row of block_fix.js's table (the mock-up's states).
const ROWS = [
  ["asking", "Couldn't draw this mermaid block: Parse error on line 4: got 'PS' · asking for a fix…", false],
  ["nohelp", "Couldn't draw this mermaid block: Parse error on line 4: got 'PS' · a fix didn't help", true],
  ["again", "Couldn't draw this mermaid block, also after a fix: Parse error on line 4: got 'PS'", true],
  ["older", "Couldn't draw this mermaid block: Parse error on line 4: got 'PS'", true],
  ["restart", "Couldn't draw this mermaid block: Parse error on line 4: got 'PS' · restart this session to fix", false],
  ["today", "Couldn't draw this mermaid block: Parse error on line 4: got 'PS'", false],
];

for (const [state, words, ask] of ROWS) {
  test(`the line, ${state}: its words an attribute, ${ask ? "with" : "without"} Ask in chat, no text in the bubble`, () => {
    const { bubble, pre } = failed();
    const text = bubble.textContent;
    const note = setFixNote(pre, state);
    assert.equal(note.dataset.text, words);
    assert.equal(note.getAttribute("aria-label"), words);
    assert.equal(note.dataset.fix, state === "today" ? undefined : state);
    assert.equal(!!buttonOf(pre), ask);
    if (ask) {
      assert.equal(buttonOf(pre).dataset.label, ASK_LABEL);
      assert.equal(buttonOf(pre).getAttribute("aria-label"), ASK_LABEL);
      assert.equal(buttonOf(pre).type, "button");
    }
    assert.equal(bubble.textContent, text);
  });
}

test("the line's words change in place, the button comes and goes, and a block without a line is left alone", () => {
  const { pre } = failed();
  const note = setFixNote(pre, "asking");
  assert.equal(setFixNote(pre, "nohelp"), note);
  assert.ok(buttonOf(pre));
  setFixNote(pre, "older");
  assert.equal(note.querySelectorAll(".block-fix-ask").length, 1);
  setFixNote(pre, "asking");
  assert.ok(buttonOf(pre) === null);
  const drawn = document.createElement("pre");
  document.body.append(drawn);
  assert.ok(setFixNote(drawn, "asking") === null);
});

test("Ask in chat's sentence: the block's language and the error's first line", () => {
  assert.equal(askText("mermaid", "Parse error on line 4: got 'PS'.\nmore"),
    "The mermaid block in your answer didn't draw: Parse error on line 4: got 'PS'. Please send it again, corrected.");
  assert.equal(askText("chi-ui", ""), "The chi-ui block in your answer didn't draw. Please send it again, corrected.");
});

test("Drawn after a fix: under a fixed block that drew, once; gone when it fails after all", () => {
  const bubble = document.createElement("div");
  bubble.className = "bubble output markdown";
  bubble.innerHTML = '<pre data-lang="mermaid" data-block-fixed=""><code>graph</code></pre>';
  document.body.append(bubble);
  const pre = bubble.querySelector("pre");
  const text = bubble.textContent;
  markFixed(pre);
  assert.ok(bubble.querySelector(".block-note.fixed") === null, "not before it drew");
  const figure = document.createElement("figure");
  figure.className = DRAWN;
  pre.before(figure);
  markFixed(pre);
  markFixed(pre);
  const marks = bubble.querySelectorAll(".block-note.fixed");
  assert.equal(marks.length, 1);
  assert.equal(marks[0].dataset.text, FIXED_TEXT);
  assert.equal(bubble.textContent, text);
  assert.ok(noteOf(pre) === null, "it is no failed block's line");
  pre.dataset.blockFailed = "1";
  pre.after(document.createElement("div"));
  pre.nextElementSibling.className = "block-note";
  markFixed(pre);
  assert.equal(bubble.querySelectorAll(".block-note.fixed").length, 0);
});
