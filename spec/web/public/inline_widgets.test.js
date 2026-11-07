import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createWidgetDrawer, hostOf, STYLESHEET } from "../../../lib/samagotchi/web/public/inline_widgets.js";
import { createBlockWatch } from "../../../lib/samagotchi/web/public/block_watch.js";
import { figureOf } from "../../../lib/samagotchi/web/public/block_source.js";
import { viewOf } from "../../../lib/samagotchi/web/public/revise_switch.js";
import { createWalker, drawWalk, swimlaneCells, trailText, USUAL, walkRoutes } from "../../../lib/samagotchi/web/public/widget_walk.js";
import { drawPicks, initialPicks, replyText, withDraft } from "../../../lib/samagotchi/web/public/widget_picks.js";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

const WALK = {
  type: "walk",
  title: "A tab reconnects",
  actors: ["user", "web", "worker"],
  steps: [
    { id: "s1", actor: "user", does: "reopens the laptop", sees: "reconnecting" },
    { id: "s2", actor: "worker", does: "checks the event id", cases: [{ when: "still buffered", goto: "s3" }, { when: "too old", goto: "s5" }] },
    { id: "s3", actor: "worker", does: "replays the missed events", next: "s5" },
    { id: "s4", actor: "web", does: "never reached" },
    { id: "s5", actor: "web", does: "shows the page", behind: "a reset event" },
  ],
};

const PICKS = {
  type: "picks",
  title: "Findings",
  rows: [
    { id: "1", text: "Bridge drops the buffer", options: ["fix now", "skip", "later"], recommended: "fix now", why: "loses events" },
    { id: "D4", text: "Cache key", options: ["A", "B"], recommended: "B" },
    { id: "3", text: "No recommendation", options: ["yes", "no"] },
  ],
};

// ---- walk: routes ----

test("next: a step's next, else the step below, else the end", () => {
  const r = walkRoutes(WALK);
  assert.equal(r.nextOf(0), 1);
  assert.equal(r.nextOf(2), 4); // next: s5
  assert.equal(r.nextOf(3), 4);
  assert.ok(r.nextOf(4) === null);
});

test("cases: a fork's cases in order, each to its step; a step without cases is no fork", () => {
  const r = walkRoutes(WALK);
  assert.deepEqual(r.casesOf(1), [{ when: "still buffered", to: 2 }, { when: "too old", to: 4 }]);
  assert.ok(r.casesOf(0) === null);
});

test("cases: a goto naming no step leads nowhere (P1a refuses it; the page doesn't break)", () => {
  const r = walkRoutes({ actors: ["a", "b"], steps: [{ id: "x", actor: "a", does: "x", cases: [{ when: "w", goto: "nope" }] }] });
  assert.deepEqual(r.casesOf(0), [{ when: "w", to: null }]);
});

test("cases normalised from round 1's branches: 'always' alone is the next; among conditions it reads as the usual path, and a next is offered first", () => {
  const steps = [
    { id: "a", actor: "x", does: "a", cases: [{ when: "always", goto: "c" }] },
    { id: "b", actor: "x", does: "b" },
    { id: "c", actor: "y", does: "c", next: "e", cases: [{ when: "it fails", goto: "d" }] },
    { id: "d", actor: "y", does: "d", cases: [{ when: "it fails", goto: "a" }, { when: "Otherwise", goto: "e" }] },
    { id: "e", actor: "y", does: "e" },
  ];
  const r = walkRoutes({ actors: ["x", "y"], steps });
  assert.ok(r.casesOf(0) === null);
  assert.equal(r.nextOf(0), 2);
  assert.deepEqual(r.casesOf(2), [{ when: USUAL, to: 4 }, { when: "it fails", to: 3 }]);
  assert.deepEqual(r.casesOf(3), [{ when: "it fails", to: 0 }, { when: USUAL, to: 4 }]);
});

test("next: end ends the walk at that step: no next, an end tag, Start over", () => {
  const walk = {
    actors: ["user", "app"],
    steps: [
      { id: "1", actor: "user", does: "submits" },
      { id: "2", actor: "app", does: "checks", cases: [{ when: "valid", goto: "3" }, { when: "invalid", goto: "5" }] },
      { id: "3", actor: "app", does: "saves" },
      { id: "4", actor: "user", sees: "success", next: "end" },
      { id: "5", actor: "user", sees: "the error" },
    ],
  };
  const r = walkRoutes(walk);
  assert.ok(r.nextOf(3) === null);
  assert.equal(swimlaneCells(walk, r)[3].tag.text, "end");
  const box = drawWalk(walk, document);
  for (let i = 0; i < 2; i++) box.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowRight" }));
  box.querySelectorAll(".ww-case")[0].click();
  box.querySelector(".ww-nav .primary").click();
  assert.equal(box.querySelector(".ww-sees").textContent, "You seesuccess");
  assert.equal(box.querySelector(".ww-nav .primary").textContent, "Start over");
  box.querySelector(".ww-nav .primary").click();
  assert.equal(box.querySelector(".ww-does").textContent, "submits");
});

test("the walker: go, back, next, and next at the end starts over", () => {
  const r = walkRoutes(WALK);
  const w = createWalker(r);
  assert.equal(w.at, 0);
  w.next();
  w.go(2);
  assert.deepEqual(w.path, [0, 1, 2]);
  assert.ok(w.seen(1));
  w.back();
  assert.equal(w.at, 1);
  w.go(4);
  w.next();
  assert.deepEqual(w.path, [0]);
  assert.ok(!w.seen(4));
  w.go(null);
  w.go(0);
  assert.deepEqual(w.path, [0]);
  assert.equal(trailText([0]), "");
  assert.equal(trailText([0, 1, 4]), "path 1 → 2 → 5");
});

// ---- walk: the swimlane ----

test("the swimlane: one cell per step in its actor's column and its own row, tagged where it doesn't go below", () => {
  const cells = swimlaneCells(WALK);
  assert.deepEqual(cells.map((c) => [c.column, c.row]), [[2, 2], [4, 3], [4, 4], [3, 5], [3, 6]]);
  assert.deepEqual(cells.map((c) => c.tag?.text ?? null), [null, "2 cases", "→ 5", null, null]);
  assert.equal(cells[1].tag.fork, true);
  assert.equal(cells[0].text, "reopens the laptop");
  const ends = swimlaneCells({ actors: ["a", "b"], steps: [{ id: "1", actor: "b", sees: "x", next: "1" }, { id: "2", actor: "a", does: "y" }] });
  assert.equal(ends[0].text, "x");
  assert.equal(ends[0].tag.text, "→ 1");
});

test("the drawn walk: a case click moves the step and the path, Back returns, arrow keys step", () => {
  const box = drawWalk(WALK, document);
  document.body.append(box);
  const card = () => box.querySelector(".ww-does").textContent;
  assert.equal(box.querySelectorAll(".ww-cell").length, 5);
  assert.equal(box.querySelector(".ww-cell.cur").textContent, "reopens the laptop");
  assert.equal(box.querySelector(".ww-sees").textContent, "You seereconnecting");
  box.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
  assert.equal(card(), "checks the event id");
  assert.ok(box.querySelector(".ww-nav .primary").hidden);
  const cases = box.querySelectorAll(".ww-case");
  assert.deepEqual([...cases].map((c) => c.textContent), ["still bufferedstep 3 →", "too oldstep 5 →"]);
  cases[1].click();
  assert.equal(card(), "shows the page");
  assert.equal(box.querySelector(".ww-trail").textContent, "path 1 → 2 → 5");
  assert.equal(box.querySelector(".ww-nav .primary").textContent, "Start over");
  assert.equal(box.querySelector(".w-count").textContent, "step 5 of 5");
  box.querySelector(".ww-nav .btn").click();
  assert.equal(card(), "checks the event id");
  box.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }));
  assert.equal(card(), "reopens the laptop");
  box.querySelectorAll(".ww-cell")[3].click();
  assert.equal(card(), "never reached");
  assert.ok(box.querySelectorAll(".ww-cell")[1].classList.contains("seen"));
});

test("a keyboard move that removes or hides the focused button keeps the focus in the widget", () => {
  const box = drawWalk(WALK, document);
  document.body.append(box);
  box.querySelector(".ww-nav .primary").focus();
  box.querySelector(".ww-nav .primary").click(); // to the fork: Next hides
  assert.equal(document.activeElement, box);
  const [first] = box.querySelectorAll(".ww-case");
  first.focus();
  first.click(); // the cases go
  assert.equal(document.activeElement, box);
  box.querySelectorAll(".ww-cell")[0].click();
  assert.deepEqual(box.querySelector(".ww-trail").textContent, "path 1 → 2 → 3 → 1");
  box.querySelectorAll(".ww-cell")[0].click(); // the current step: no move
  assert.deepEqual(box.querySelector(".ww-trail").textContent, "path 1 → 2 → 3 → 1");
});

test("a step's markup is text: no element is made from the model's words", () => {
  const evil = '<img src=x onerror="globalThis.pwned=1">';
  const walk = { actors: [evil, "b"], title: evil, steps: [{ id: "1", actor: evil, does: evil, sees: evil, behind: evil, cases: [{ when: evil, goto: "1" }] }] };
  const box = drawWalk(walk, document);
  const picks = drawPicks({ title: evil, rows: [{ id: evil, text: evil, why: evil, options: [evil, "b"], recommended: evil }] }, { fill() {}, doc: document });
  for (const el of [box, picks]) {
    assert.equal(el.querySelectorAll("img").length, 0);
    assert.ok(el.textContent.includes(evil));
  }
  assert.ok(!globalThis.pwned);
});

// ---- picks ----

test("the reply: id: option (note) per picked row, an unpicked row left out", () => {
  const picks = initialPicks(PICKS.rows);
  assert.deepEqual(picks.map((p) => p.pick), ["fix now", "B", null]);
  assert.equal(replyText(PICKS.rows, picks), "1: fix now · D4: B");
  picks[0].note = "  today\n first ";
  picks[2].pick = "no";
  picks[1].pick = null;
  assert.equal(replyText(PICKS.rows, picks), "1: fix now (today first) · 3: no");
  assert.equal(replyText(PICKS.rows, picks.map(() => ({ pick: null, note: "x" }))), "");
});

test("a draft keeps its text, and the reply goes after it on a new line", () => {
  assert.equal(withDraft("", "1: a"), "1: a");
  assert.equal(withDraft("   \n", "1: a"), "1: a");
  assert.equal(withDraft("my words\n\n", "1: a"), "my words\n1: a");
});

test("the drawn picks: the recommended preselected, a chip click toggles, a note, Fill reply fills and only fills", () => {
  const filled = [];
  const box = drawPicks(PICKS, { fill: (r) => filled.push(r), doc: document });
  document.body.append(box);
  const pressed = () => [...box.querySelectorAll('.wp-opt[aria-pressed="true"]')].map((b) => b.firstChild.textContent);
  assert.deepEqual(pressed(), ["fix now", "B"]);
  assert.equal(box.querySelectorAll(".rec").length, 2);
  assert.equal(box.querySelector(".w-count").textContent, "2 of 3 picked");
  const [, , rowThree] = box.querySelectorAll(".wp-row");
  rowThree.querySelectorAll(".wp-opt")[0].click();
  box.querySelectorAll(".wp-row")[1].querySelector('.wp-opt[aria-pressed="true"]').click();
  assert.deepEqual(pressed(), ["fix now", "yes"]);
  box.querySelector(".wp-addnote").click();
  const note = box.querySelector(".wp-note");
  note.value = "today";
  note.dispatchEvent(new window.Event("input"));
  box.querySelector(".wp-fill").click();
  assert.deepEqual(filled, ["1: fix now (today) · 3: yes"]);
  for (const b of box.querySelectorAll('.wp-opt[aria-pressed="true"]')) b.click();
  assert.ok(box.querySelector(".wp-fill").disabled);
});

// ---- the drawer ----

const pre = (attrs, src = "type: walk") => `<pre data-lang="chi-ui" ${attrs}><code>${src}</code></pre>`;
const attr = (data) => `data-widget="${JSON.stringify(data).replace(/&/g, "&amp;").replace(/"/g, "&quot;")}"`;

function setup(html, deps = {}) {
  const root = document.createElement("div");
  root.innerHTML = `<div class="bubble output markdown">${html}</div>`;
  document.body.append(root);
  const drawer = createWidgetDrawer({ roots: [root], composerText: () => "", fillComposer() {}, doc: document, win: window, ...deps });
  createBlockWatch({ roots: [root], sessionId: () => "s1", drawers: [drawer], watch: (_el, _sc, onNear) => onNear(), win: window });
  return root;
}

test.afterEach(() => { document.body.innerHTML = ""; });

test("a valid block: a figure with the toggle and a shadow host before the hidden <pre>; its words out of the bubble's text", async () => {
  const root = setup(pre(attr(WALK)));
  await settle();
  const source = root.querySelector("pre");
  const figure = figureOf(source);
  assert.ok(figure);
  assert.ok(source.hidden);
  assert.ok(figure.querySelector(":scope > .block-toggle"));
  const shadow = hostOf(figure).shadowRoot;
  assert.ok(shadow);
  assert.equal(shadow.querySelector("link").getAttribute("href"), STYLESHEET);
  assert.ok(shadow.querySelector(".ww-swim"));
  assert.equal(root.querySelector(".bubble").textContent, "type: walk");
});

test("a refused block stays source under the muted line; one with no widget data is left alone", async () => {
  const root = setup(pre('data-widget-error="step 2: actor &quot;x&quot; isn\'t one of the actors\nmore"') + pre(""));
  await settle();
  const [refused, plain] = root.querySelectorAll("pre");
  assert.ok(!figureOf(refused));
  assert.ok(!refused.hidden);
  assert.equal(refused.dataset.blockFailed, "1");
  assert.equal(refused.nextElementSibling.dataset.text, 'Couldn\'t draw this chi-ui block: step 2: actor "x" isn\'t one of the actors');
  assert.equal(refused.nextElementSibling.textContent, "");
  assert.ok(!figureOf(plain));
  assert.ok(!plain.dataset.blockFailed);
});

test("bad JSON or an unknown type fails only its block", async () => {
  const errors = console.error;
  console.error = () => {};
  let root;
  try {
    root = setup(pre('data-widget="{nope"') + pre(attr({ type: "table" })) + pre(attr(PICKS)));
    await settle();
  } finally { console.error = errors; }
  const [bad, unknown, good] = root.querySelectorAll("pre");
  assert.equal(bad.dataset.blockFailed, "1");
  assert.match(unknown.nextElementSibling.dataset.text, /no widget of type table/);
  assert.ok(figureOf(good));
});

test("a Revise clone arrives with an empty host and is drawn again", async () => {
  const root = setup(pre(attr(PICKS)));
  await settle();
  const bubble = root.querySelector(".bubble");
  const clone = viewOf(bubble, 0);
  assert.ok(!hostOf(figureOf(clone.querySelector("pre"))).shadowRoot);
  root.append(clone);
  await settle();
  const figure = figureOf(clone.querySelector("pre"));
  assert.equal(clone.querySelectorAll("figure").length, 1);
  assert.ok(hostOf(figure).shadowRoot.querySelector(".wp-fill"));
});

test("Fill reply goes through the composer: after the draft, never a send", async () => {
  const filled = [];
  const root = setup(pre(attr(PICKS)), { composerText: () => "my draft", fillComposer: (t) => filled.push(t) });
  await settle();
  hostOf(figureOf(root.querySelector("pre"))).shadowRoot.querySelector(".wp-fill").click();
  assert.deepEqual(filled, ["my draft\n1: fix now · D4: B"]);
});
