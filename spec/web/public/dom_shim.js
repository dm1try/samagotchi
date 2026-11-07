// A DOM for the specs that render with lit-html (turn_block.js): happy-dom's
// window as the globals lit reads at import (document) and render time.
// Dev-only; import it first, before the module under test.
import assert from "node:assert/strict";
import { inspect } from "node:util";
import { Window } from "happy-dom";

const window = new Window();
for (const k of ["window", "document", "Node", "Element", "HTMLElement", "DocumentFragment", "Comment", "Text", "NodeFilter", "HTMLTemplateElement", "getComputedStyle", "requestAnimationFrame"]) {
  if (!(k in globalThis)) globalThis[k] = k === "window" ? window : window[k];
}

// A node as a failure prints it: a short <tag id=… class=…>. util.inspect
// walking happy-dom's cyclic node graph takes minutes, so a failed
// assert.equal on two nodes looked like a hang.
function short(node) {
  if (node.nodeType === 1) {
    const id = node.id ? ` id=${node.id}` : "";
    const cls = node.className ? ` class=${node.className}` : "";
    return `<${node.localName}${id}${cls}>`;
  }
  if (node.nodeType === 3) return `#text ${JSON.stringify(node.data.slice(0, 40))}`;
  return node.nodeName;
}
// A node logged or inspected in a spec (console.log, a message built with inspect).
window.Node.prototype[inspect.custom] = function () { return short(this); };
// assert's own message inspects with customInspect off, so a node compared
// by reference fails here first, with the short form (any other value goes
// to assert as before).
const isNode = (v) => v instanceof window.Node;
const label = (v) => (isNode(v) ? short(v) : inspect(v, { depth: 1 }));
function byReference(original, same, words, operator) {
  return function (actual, expected, message) {
    if (!isNode(actual) && !isNode(expected)) return original.apply(this, arguments);
    if (Object.is(actual, expected) === same) return;
    if (message instanceof Error) throw message;
    // Labels, not the nodes: an AssertionError diffs node-valued actual and
    // expected under its message all the same.
    const error = new assert.AssertionError({ message: message ?? `Expected ${label(actual)} ${words} ${label(expected)}`, operator: "fail" });
    Object.assign(error, { actual: label(actual), expected: label(expected), operator });
    throw error;
  };
}
assert.equal = assert.strictEqual = byReference(assert.strictEqual, true, "to be", "strictEqual");
assert.notEqual = assert.notStrictEqual = byReference(assert.notStrictEqual, false, "not to be", "notStrictEqual");

// A rendered fragment's markup as a reload wrote it before: lit's marker
// comments dropped.
export function htmlOf(nodes) {
  const div = document.createElement("div");
  div.append(nodes.cloneNode ? nodes.cloneNode(true) : nodes);
  return div.innerHTML.replace(/<!--[^]*?-->/g, "");
}

// +markup+ as the DOM writes it back (text escapes only &, <, >).
export function canon(markup) {
  const t = document.createElement("template");
  t.innerHTML = markup;
  return htmlOf(t.content);
}

// lit reads document as it loads: imported once the globals are set.
const { render } = await import("../../../lib/samagotchi/web/public/vendor/lit-html.js");

// A lit template's markup as the page gets it (lit's marker comments dropped).
export function markupOf(template) {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return htmlOf(frag);
}
