import test from "node:test";
import assert from "node:assert/strict";
import { createAnnotateBar } from "../../../lib/samagotchi/web/public/annotate_bar.js";
import { annotationActions } from "../../../lib/samagotchi/web/public/annotate_actions.js";

// Light DOM stand-ins: elements with the few members the bar touches.
function el(tag, { classes = [] } = {}) {
  const listeners = {};
  return {
    tag, id: "", hidden: false, disabled: false, type: "", className: "", textContent: "", title: "",
    dataset: {}, style: {}, attrs: {}, children: [], childNodes: [],
    offsetWidth: 120, offsetHeight: 30,
    setAttribute(k, v) { this.attrs[k] = v; },
    appendChild(c) { this.children.push(c); c.parentElement = this; },
    replaceChildren(...cs) { this.children = []; cs.forEach((c) => this.appendChild(c)); },
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    fire(type, e) { (listeners[type] || []).forEach((fn) => fn(e)); },
    contains(node) { for (let n = node; n; n = n.parentElement) if (n === this) return true; return false; },
    closest(sel) {
      if (sel === "button") return this.tag === "button" ? this : null;
      return sel.split(".").filter(Boolean).every((c) => classes.includes(c)) ? this : null;
    },
    classList: {
      contains: (c) => classes.includes(c),
      add: (c) => { if (!classes.includes(c)) classes.push(c); },
      remove: (c) => { const i = classes.indexOf(c); if (i >= 0) classes.splice(i, 1); },
    },
    querySelectorAll: () => [],
    getBoundingClientRect: () => ({ top: 0, bottom: 30, left: 0, right: 120 }),
  };
}

function fakePage({ selectionText = "the answer", inRoot = true, commands = [], touch = false, dock = null, options = {} } = {}) {
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
    matchMedia: (query) => ({ matches: touch && query === "(pointer: coarse)" }),
  };
  const quotes = [];
  const actions = [];
  const state = { can: true, live: false, running: false, commands };
  const bar = createAnnotateBar({
    presets: ["Agreed", "Why?"],
    canAnnotate: () => state.can,
    roots: () => [history],
    isLive: () => state.live,
    onQuote: (text) => quotes.push(text),
    actions: () => annotationActions(state.commands),
    running: () => state.running,
    onAction: (action, fields) => actions.push([action.label, fields]),
    dock: () => dock,
    doc, win,
    ...options,
  });
  const selectionChange = () => {
    docListeners.selectionchange.forEach((fn) => fn());
    frames.splice(0).forEach((fn) => fn());
  };
  return { actions, answer, bar, doc, quotes, state, selectionChange, win };
}

const click = (bar, btn) => bar.fire("click", { target: btn });

test("a page's own source and quote (the participant page's): read for the selection, the quote theirs", () => {
  const seen = [];
  const options = {
    source: (node) => { seen.push(node.parentElement.classList.contains("output")); return { kind: "plan", root: node.parentElement }; },
    quote: (text, source) => `From ${source.kind}:\n> ${text}\n\n`,
  };
  const { bar, quotes, selectionChange } = fakePage({ options });
  selectionChange();
  assert.deepEqual(seen, [true]);
  click(bar.el, bar.el.children[1]);
  assert.deepEqual(quotes, ["From plan:\n> the answer\n\nAgreed"]);
});

test("a page's own source refusing a selection hides the bar", () => {
  const { bar, selectionChange } = fakePage({ options: { source: () => null } });
  selectionChange();
  assert.equal(bar.el.hidden, true);
});

test("the bar: Annotate then the presets, hidden, in the body", () => {
  const { bar, doc } = fakePage();
  assert.equal(doc.body.children[0], bar.el);
  assert.equal(bar.el.id, "annotateBar");
  assert.equal(bar.el.hidden, true);
  assert.deepEqual(bar.el.children.slice(0, 3).map((b) => [b.className, b.textContent, b.dataset.index]),
    [["annotate-main", "Annotate", undefined], ["annotate-preset", "Agreed", "0"], ["annotate-preset", "Why?", "1"]]);
  // Then the plugin pills' group, empty and hidden without any.
  assert.equal(bar.el.children[3].className, "annotate-actions");
  assert.equal(bar.el.children[3].hidden, true);
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

test("on a touch screen the bar docks above the composer, away from the OS selection menu", () => {
  const dock = { getBoundingClientRect: () => ({ top: 650, height: 120 }) };
  const { bar, quotes, selectionChange } = fakePage({ touch: true, dock });
  selectionChange();
  assert.equal(bar.el.hidden, false);
  // 650 - the bar's 30px - 8px gap, not under the selection (126px).
  assert.equal(bar.el.style.top, "612px");
  assert.equal(bar.el.style.left, "8px");
  assert.equal(bar.el.classList.contains("docked"), true);
  click(bar.el, bar.el.children[0]);
  assert.deepEqual(quotes, ["> the answer\n\n"]);
});

test("docked without a laid-out composer: the bottom of the window", () => {
  for (const dock of [null, { getBoundingClientRect: () => ({ top: 0, height: 0 }) }]) {
    const { bar, selectionChange } = fakePage({ touch: true, dock });
    selectionChange();
    assert.equal(bar.el.style.top, "762px");
  }
});

test("a pointer screen floats the bar under the selection, not docked", () => {
  const dock = { getBoundingClientRect: () => ({ top: 650, height: 120 }) };
  const { bar, selectionChange } = fakePage({ dock });
  selectionChange();
  assert.equal(bar.el.style.top, "126px");
  assert.equal(bar.el.classList.contains("docked"), false);
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

// The plugin pills: the group after the presets (its children: a separator,
// the inline pills, then ⋯ and its list when there are more).
const pillGroup = (bar) => bar.el.children[3];
const pills = (bar) => pillGroup(bar).children.filter((c) => c.className === "annotate-action");
const command = (name, labels, extra = {}) => ({
  name, mid_turn: "refuse", source: "peer", ...extra,
  annotations: labels.map((label) => ({ label, line: `${name} go`, template: "{quote}", send: false })),
});

test("plugin pills follow the session's listing, re-read on each selection", () => {
  const page = fakePage();
  page.selectionChange();
  assert.equal(pillGroup(page.bar).hidden, true);
  page.state.commands = [command("/claude", ["Confirm with Claude"])];
  page.selectionChange();
  assert.equal(pillGroup(page.bar).hidden, false);
  assert.deepEqual(pills(page.bar).map((p) => [p.textContent, p.title, p.disabled]),
    [["Confirm with Claude", "Confirm with Claude (peer)", false]]);
  page.state.commands = [];
  page.selectionChange();
  assert.equal(pillGroup(page.bar).hidden, true);
});

test("a pill hands its action and the selection's fields over, and the bar hides", () => {
  const page = fakePage({ commands: [command("/claude", ["Confirm"])] });
  page.selectionChange();
  click(page.bar.el, pills(page.bar)[0]);
  assert.deepEqual(page.actions, [["Confirm", { quote: "> the answer\n\n", text: "the answer", source: "answer" }]]);
  assert.equal(page.bar.el.hidden, true);
  assert.deepEqual(page.quotes, []);
});

test("beyond 3 pills the rest are behind ⋯, which opens their list and keeps the bar", () => {
  const page = fakePage({ commands: [command("/a", ["A1", "A2"]), command("/b", ["B1", "B2", "B3"])] });
  page.selectionChange();
  assert.deepEqual(pills(page.bar).map((p) => p.textContent), ["A1", "A2", "B1"]);
  const more = pillGroup(page.bar).children.find((c) => c.className === "annotate-more");
  const list = pillGroup(page.bar).children.find((c) => c.className === "annotate-more-list");
  assert.equal(list.hidden, true);
  click(page.bar.el, more);
  assert.equal(list.hidden, false);
  assert.equal(page.bar.el.hidden, false);
  assert.deepEqual(list.children.map((p) => p.textContent), ["B2", "B3"]);
  click(page.bar.el, list.children[1]);
  assert.deepEqual(page.actions.map(([label]) => label), ["B3"]);
});

test("a send pill is disabled while a turn runs unless its command is anytime", () => {
  const send = (name, extra) => ({ ...command(name, ["Go"], extra), annotations: [{ label: `Go ${name}`, line: name, template: "{text}", send: true }] });
  const page = fakePage({ commands: [send("/q"), send("/now", { mid_turn: "anytime" })] });
  page.state.running = true;
  page.selectionChange();
  assert.deepEqual(pills(page.bar).map((p) => [p.textContent, p.disabled]), [["Go /q", true], ["Go /now", false]]);
  assert.equal(pills(page.bar)[0].title, "Go /q (peer): /q waits for the turn to end");
  assert.equal(pills(page.bar)[0].dataset.sends, "");
  click(page.bar.el, pills(page.bar)[0]);
  assert.deepEqual(page.actions, []);
  page.state.running = false;
  page.selectionChange();
  assert.equal(pills(page.bar)[0].disabled, false);
});

test("Copy link: hidden without a link for the selection; with one, last, titled, and it hands the link over", () => {
  const plain = fakePage();
  plain.selectionChange();
  const linkBtn = plain.bar.el.children.at(-1);
  assert.equal(linkBtn.className, "annotate-link");
  assert.equal(linkBtn.hidden, true);

  const links = [];
  const asked = [];
  const { bar, quotes, selectionChange } = fakePage({ options: {
    link: (source, range) => { asked.push([source.kind, range.toString()]); return { url: "http://x/#s=1&t=2", title: "For Alex's browser" }; },
    onLink: (target) => links.push(target.url),
  } });
  selectionChange();
  const btn = bar.el.children.at(-1);
  assert.equal(btn.hidden, false);
  assert.equal(btn.textContent, "Copy link");
  assert.equal(btn.title, "For Alex's browser");
  assert.deepEqual(asked, [["answer", "the answer"]]);
  click(bar.el, btn);
  assert.deepEqual(links, ["http://x/#s=1&t=2"]);
  assert.deepEqual(quotes, []);
  assert.equal(bar.el.hidden, true);
});

test("a {label, text} preset (Verify): its label on the button, its text the title and the note", () => {
  const { bar, quotes, selectionChange } = fakePage({ options: { presets: ["Agreed", { label: "Verify", text: "Check it." }] } });
  const btn = bar.el.children[2];
  assert.deepEqual([btn.className, btn.textContent, btn.title], ["annotate-preset", "Verify", "Check it."]);
  selectionChange();
  click(bar.el, btn);
  assert.deepEqual(quotes, ["> the answer\n\nCheck it."]);
});

test("a gated Verify preset is disabled with the restart hint and cannot fill the composer", () => {
  const { bar, quotes, selectionChange } = fakePage({
    options: {
      presets: ["Agreed", { label: "Verify", text: "Check it." }],
      disabledPreset: (preset) => preset.label === "Verify" ? "restart this session to use Verify" : null,
    },
  });
  selectionChange();
  const verify = bar.el.children[2];
  assert.equal(verify.disabled, true);
  assert.equal(verify.title, "restart this session to use Verify");
  click(bar.el, verify);
  assert.deepEqual(quotes, []);
});
