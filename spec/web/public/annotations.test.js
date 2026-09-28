import test from "node:test";
import assert from "node:assert/strict";
import { annotateBarLeft, annotationSource, appendQuote, quoteBlock, sourceLabel } from "../../../lib/samagotchi/web/public/annotations.js";

// A stand-in element: `closest` walks a chain of { matches, el } pairs.
function fakeEl(chain, { tool, classes = [] } = {}) {
  const el = {
    nodeType: 1,
    classList: { contains: (c) => classes.includes(c) },
    closest: (sel) => chain[sel] || null,
    querySelector: (sel) => (sel === ".activity-tool" && tool ? { textContent: ` ${tool} ` } : null),
  };
  return el;
}

test("annotationSource names a tool row by its tool", () => {
  const row = fakeEl({}, { tool: "read_file" });
  const node = fakeEl({ ".activity-row": row });
  assert.deepEqual(annotationSource(node), { kind: "tool", tool: "read_file", root: row });
});

test("annotationSource finds thinking, own messages and answers", () => {
  const body = fakeEl({});
  assert.equal(annotationSource(fakeEl({ ".thinking-body": body })).kind, "thinking");
  const own = fakeEl({});
  assert.deepEqual(annotationSource(fakeEl({ ".bubble.user .user-message": own })), { kind: "user", root: own });
  const answer = fakeEl({}, { classes: ["bubble", "output"] });
  assert.deepEqual(annotationSource(fakeEl({ ".bubble.output": answer })), { kind: "answer", root: answer });
});

test("annotationSource starts from a text node's parent", () => {
  const answer = fakeEl({}, { classes: ["bubble", "output"] });
  const parent = fakeEl({ ".bubble.output": answer });
  assert.equal(annotationSource({ nodeType: 3, parentElement: parent }).kind, "answer");
});

test("annotationSource skips a streaming answer and anything else", () => {
  const streaming = fakeEl({}, { classes: ["bubble", "output", "streaming"] });
  assert.equal(annotationSource(fakeEl({ ".bubble.output": streaming })), null);
  assert.equal(annotationSource(fakeEl({})), null);
  assert.equal(annotationSource(null), null);
});

test("sourceLabel", () => {
  assert.equal(sourceLabel("answer"), null);
  assert.equal(sourceLabel("thinking"), "From your thinking:");
  assert.equal(sourceLabel("tool", "shell"), "From the shell call:");
  assert.equal(sourceLabel("user"), "From my earlier message:");
});

test("quoteBlock quotes each line under the label and ends in a blank line", () => {
  assert.equal(
    quoteBlock("\n  first  \r\n\r\nsecond\n\n", { kind: "tool", tool: "read_file" }),
    "From the read_file call:\n>   first\n>\n> second\n\n",
  );
  assert.equal(quoteBlock("an answer line", { kind: "answer" }), "> an answer line\n\n");
});

test("quoteBlock is null for a blank selection", () => {
  assert.equal(quoteBlock(" \n\t\n", { kind: "answer" }), null);
});

test("appendQuote adds the block after a blank line", () => {
  assert.equal(appendQuote("", "> a\n\n"), "> a\n\n");
  assert.equal(appendQuote("> a\n\nnote \n", "> b\n\n"), "> a\n\nnote\n\n> b\n\n");
});

test("annotationSource quotes a step's narration in the turn view, not the live one", () => {
  const step = fakeEl({}, { classes: ["gen-text"] });
  assert.deepEqual(annotationSource(fakeEl({ ".gen-text": step })), { kind: "step", root: step });
  assert.equal(sourceLabel("step"), "From your earlier step:");
  const live = fakeEl({}, { classes: ["gen-text", "streaming"] });
  assert.equal(annotationSource(fakeEl({ ".gen-text": live })), null);
});

// The bar (324 px wide) in a 1400 px window, under the selection's last line.
test("annotateBarLeft: right-aligned to the selection's end; left-aligned to its line start where that would clamp", () => {
  assert.equal(annotateBarLeft({ left: 400, right: 900 }, 324, 1400), 576);
  // Ends near the bubble's left edge (x 237..257): by the text, not the gutter.
  assert.equal(annotateBarLeft({ left: 237, right: 257 }, 324, 1400), 237);
  // Still kept in the window at both edges.
  assert.equal(annotateBarLeft({ left: 2, right: 20 }, 324, 1400), 8);
  assert.equal(annotateBarLeft({ left: 1300, right: 1395 }, 324, 1400), 1068);
});
