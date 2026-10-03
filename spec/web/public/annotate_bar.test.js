import test from "node:test";
import assert from "node:assert/strict";
import { createAnnotateBar } from "../../../lib/samagotchi/web/public/annotate_bar.js";

// Light DOM stand-ins: elements with the few members the bar touches.
function el(tag, { classes = [] } = {}) {
  const listeners = {};
  return {
    tag, id: "", hidden: false, type: "", className: "", textContent: "", title: "",
    dataset: {}, style: {}, attrs: {}, children: [], childNodes: [],
    offsetWidth: 120, offsetHeight: 30,
    setAttribute(k, v) { this.attrs[k] = v; },
    appendChild(c) { this.children.push(c); c.parentElement = this; },
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    fire(type, e) { (listeners[type] || []).forEach((fn) => fn(e)); },
    contains(node) { for (let n = node; n; n = n.parentElement) if (n === this) return true; return false; },
    closest(sel) {
      if (sel === "button") return this.tag === "button" ? this : null;
      return sel.split(".").filter(Boolean).every((c) => classes.includes(c)) ? this : null;
    },
    classList: { contains: (c) => classes.includes(c) },
    querySelectorAll: () => [],
    getBoundingClientRect: () => ({ top: 0, bottom: 30, left: 0, right: 120 }),
  };
}

function fakePage({ selectionText = "the answer", inRoot = true } = {}) {
  const docListeners = {};
  const doc = {
    body: el("body"),
    createElement: (tag) => el(tag),
    addEventListener(type, fn) { (docListeners[type] ||= []).push(fn); },
  };
  const history = el("div");
  const answer = el("div", { classes: ["bubble", "output"] });
  if (inRoot) history.appendChild(answer);
  const textNode = { nodeType: 3, parentElement: answer };
  let ranges = 1;
  const range = {
    startContainer: textNode,
    endContainer: textNode,
    cloneRange() { return this; },
    setEnd() {},
    toString: () => selectionText,
    getClientRects: () => [{ top: 100, bottom: 120, left: 50, right: 300 }],
  };
  const frames = [];
  const win = {
    innerWidth: 1000, innerHeight: 800,
    getSelection: () => ({
      get isCollapsed() { return ranges === 0; },
      get rangeCount() { return ranges; },
      getRangeAt: () => range,
      removeAllRanges: () => { ranges = 0; },
    }),
    requestAnimationFrame: (fn) => frames.push(fn),
    addEventListener() {},
  };
  const quotes = [];
  const state = { can: true, live: false };
  const bar = createAnnotateBar({
    presets: ["Agreed", "Why?"],
    canAnnotate: () => state.can,
    roots: () => [history],
    isLive: () => state.live,
    onQuote: (text) => quotes.push(text),
    doc, win,
  });
  const selectionChange = () => {
    docListeners.selectionchange.forEach((fn) => fn());
    frames.splice(0).forEach((fn) => fn());
  };
  return { answer, bar, doc, quotes, state, selectionChange, win };
}

const click = (bar, btn) => bar.fire("click", { target: btn });

test("the bar: Annotate then the presets, hidden, in the body", () => {
  const { bar, doc } = fakePage();
  assert.equal(doc.body.children[0], bar.el);
  assert.equal(bar.el.id, "annotateBar");
  assert.equal(bar.el.hidden, true);
  assert.deepEqual(bar.el.children.map((b) => [b.className, b.textContent, b.dataset.index]),
    [["annotate-main", "Annotate", undefined], ["annotate-preset", "Agreed", "0"], ["annotate-preset", "Why?", "1"]]);
});

test("a selection in an answer shows the bar under it; Annotate quotes it", () => {
  const { bar, quotes, selectionChange } = fakePage();
  selectionChange();
  assert.equal(bar.el.hidden, false);
  assert.equal(bar.el.style.top, "126px");
  click(bar.el, bar.el.children[0]);
  assert.deepEqual(quotes, ["> the answer\n\n"]);
  assert.equal(bar.el.hidden, true);
});

test("a preset quotes with its text as the note", () => {
  const { bar, quotes, selectionChange } = fakePage();
  selectionChange();
  click(bar.el, bar.el.children[2]);
  assert.deepEqual(quotes, ["> the answer\n\nWhy?"]);
});

test("hidden when the session can't take it, the step is live, or the selection is outside the roots", () => {
  for (const setup of [(p) => { p.state.can = false; }, (p) => { p.state.live = true; }]) {
    const page = fakePage();
    setup(page);
    page.selectionChange();
    assert.equal(page.bar.el.hidden, true);
    click(page.bar.el, page.bar.el.children[0]);
    assert.deepEqual(page.quotes, []);
  }
  const outside = fakePage({ inRoot: false });
  outside.selectionChange();
  assert.equal(outside.bar.el.hidden, true);
});

test("a blank selection quotes nothing", () => {
  const { bar, selectionChange } = fakePage({ selectionText: "  \n " });
  selectionChange();
  assert.equal(bar.el.hidden, true);
});

test("schedule reads the selection once per frame", () => {
  const { bar, win } = fakePage();
  let reads = 0;
  const get = win.getSelection;
  win.getSelection = () => { reads += 1; return get(); };
  const frames = [];
  win.requestAnimationFrame = (fn) => frames.push(fn);
  bar.schedule();
  bar.schedule();
  assert.equal(frames.length, 1);
  frames[0]();
  assert.equal(reads, 1);
  assert.equal(bar.el.hidden, false);
});

test("the bar moves below a copy button it would cover (this bubble's or the next one's)", () => {
  const copyBtn = (top, bottom) => ({ getBoundingClientRect: () => ({ top, bottom, left: 0, right: 1000 }) });
  const run = ({ own = [], next = [] } = {}) => {
    const page = fakePage();
    // The bar's box follows where it was placed (120 x 30, as offsetWidth/Height).
    page.bar.el.getBoundingClientRect = function () {
      const top = parseFloat(this.style.top); const left = parseFloat(this.style.left);
      return { top, bottom: top + 30, left, right: left + 120 };
    };
    page.answer.querySelectorAll = (sel) => (sel === ".copy-btn" ? own : []);
    if (next.length) page.answer.nextElementSibling = { querySelectorAll: (sel) => (sel === ".copy-btn" ? next : []) };
    page.selectionChange();
    return page.bar.el.style.top;
  };
  assert.equal(run(), "126px"); // under the selection (bottom 120 + 6)
  assert.equal(run({ own: [copyBtn(300, 330)] }), "126px"); // a button elsewhere: stays
  assert.equal(run({ own: [copyBtn(120, 150)] }), "154px"); // over this bubble's button: just below it
  assert.equal(run({ next: [copyBtn(140, 160)] }), "164px"); // the next bubble's button too
  assert.equal(run({ own: [copyBtn(140, 790)] }), "762px"); // never below the viewport (800 - 30 - 8)
});
