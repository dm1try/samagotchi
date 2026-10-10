// A DOM for the specs that render with lit-html (turn_view.js): happy-dom's
// window as the globals lit reads at import (document) and render time.
// Dev-only; import it first, before the module under test.
import { Window } from "happy-dom";

const window = new Window();
for (const k of ["window", "document", "Node", "Element", "HTMLElement", "DocumentFragment", "Comment", "Text", "NodeFilter", "HTMLTemplateElement", "getComputedStyle", "requestAnimationFrame"]) {
  if (!(k in globalThis)) globalThis[k] = k === "window" ? window : window[k];
}

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
