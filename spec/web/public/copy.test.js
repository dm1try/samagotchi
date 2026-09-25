import test from "node:test";
import assert from "node:assert/strict";
import { bubbleCopyText, copySourceAttr, visibleText } from "../../../lib/samagotchi/web/public/copy.js";

// Just enough of an Element for the copy rules: children, classes, a
// selector test by class names, attributes.
function el(cls, children = [], attrs = {}) {
  const classes = cls ? cls.split(" ") : [];
  const node = {
    nodeType: 1,
    childNodes: children.map((c) => (typeof c === "string" ? { nodeType: 3, nodeValue: c } : c)),
    classList: { contains: (c) => classes.includes(c) },
    getAttribute: (name) => (name in attrs ? attrs[name] : null),
    // ".a, .b" or "tag" selectors, enough for the ones copy.js uses.
    matches: (sel) => sel.split(",").map((s) => s.trim()).some((s) => (s.startsWith(".") ? classes.includes(s.slice(1)) : s === node.tag)),
    querySelector: (sel) => find(node, sel),
  };
  return node;
}
function find(root, sel) {
  for (const c of root.childNodes) {
    if (c.nodeType !== 1) continue;
    if (c.matches(sel)) return c;
    const hit = find(c, sel);
    if (hit) return hit;
  }
  return null;
}
function tagged(tag, children) {
  const node = el("", children);
  node.tag = tag;
  return node;
}

test("an answer with rendered markdown copies its kept source", () => {
  const bubble = el("bubble output markdown", [tagged("p", ["Hello ", tagged("em", ["there"])]), el("copy-btn")],
    { "data-copy-source": "Hello *there*\n\n- a" });
  assert.equal(bubbleCopyText(bubble), "Hello *there*\n\n- a");
});

test("a plain answer copies its text, without the timing line or the button", () => {
  const bubble = el("bubble output", ["PONG\n  two", el("turn-timing", ["turn 1 · 0.5s"]), el("copy-btn")]);
  assert.equal(bubbleCopyText(bubble), "PONG\n  two");
});

test("a prompt copies the text as typed: its kept source, else its message without label and badge", () => {
  const kept = el("bubble user", [el("user-message", ["quoted"])], { "data-copy-source": "> quoted\n\nnote" });
  assert.equal(bubbleCopyText(kept), "> quoted\n\nnote");
  const bare = el("bubble user", [el("origin-label", ["web"]), el("user-message", ["hi", el("thumbs", ["x.png"])]), el("state-badge", ["queued"])]);
  assert.equal(bubbleCopyText(bare), "hi");
});

test("an empty kept source is still the source", () => {
  assert.equal(bubbleCopyText(el("bubble output", ["shown"], { "data-copy-source": "" })), "");
});

test("visibleText skips the matching subtrees", () => {
  assert.equal(visibleText(el("", ["a", el("x", ["b"]), el("y", ["c"])]), ".x"), "ac");
});

test("copySourceAttr: rendered answers and prompts keep their source, escaped; a plain answer does not", () => {
  assert.equal(copySourceAttr({ role: "assistant", content: 'a "b" <c> & d' }, true), ' data-copy-source="a &quot;b&quot; &lt;c&gt; &amp; d"');
  assert.equal(copySourceAttr({ role: "user", content: "> q\nnote" }, false), ' data-copy-source="&gt; q\nnote"');
  assert.equal(copySourceAttr({ role: "assistant", content: "plain" }, false), "");
});
