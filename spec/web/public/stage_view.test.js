// The stage view's hand-off timing (stage_view.js), in happy-dom: what
// arrives while the finished turn slides away goes after it.
import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

for (const k of ["MutationObserver", "CustomEvent", "localStorage", "getSelection"]) {
  if (!(k in globalThis)) globalThis[k] = window[k];
}
globalThis.ResizeObserver ??= class { observe() {} disconnect() {} };
// The question room's sight of its card (happy-dom's isn't a global): the
// tests call an observer's callback themselves (seeCard).
const sights = [];
globalThis.IntersectionObserver ??= class {
  constructor(fn, options) { Object.assign(this, { fn, options, els: new Set() }); sights.push(this); }
  observe(el) { this.els.add(el); }
  unobserve(el) { this.els.delete(el); }
  disconnect() { this.els.clear(); }
};
globalThis.matchMedia ??= () => ({ matches: false });
if (!window.HTMLElement.prototype.animate) window.HTMLElement.prototype.animate = () => ({ finished: Promise.resolve(), cancel() {}, playState: "finished" });

const { createStageView } = await import("../../../lib/samagotchi/web/public/stage_view.js");

function page({ taskStop = null, renderMarkdown } = {}) {
  document.body.innerHTML = '<div id="center"><div id="history"></div><div id="dock"><div id="composer"></div></div></div>';
  const historyEl = document.getElementById("history");
  const view = createStageView({
    historyEl,
    appendToHistory: (el) => historyEl.appendChild(el),
    isNearBottom: () => false,
    sawText: () => false,
    sessionId: () => "s1",
    dockEl: document.getElementById("dock"),
    centerEl: document.getElementById("center"),
    composerEl: document.getElementById("composer"),
    taskStop,
    renderMarkdown,
  });
  // app.js's appendToHistory: the stage first, else the history's end.
  const append = (el) => { if (!view.place(el)) historyEl.appendChild(el); };
  return { historyEl, view, append };
}

function endedTurn(view) {
  const prompt = document.createElement("div");
  prompt.className = "bubble user";
  view.turnStarted({ promptBubble: prompt });
  view.generationStarted({ iteration: 1 });
  view.chunk({ iteration: 1, text: "Done." });
  view.generationCompleted();
  view.turnEnded({ kind: "completed" });
  view.answerReady();
  return prompt;
}

test("a row placed while the finished turn slides away lands after the turn, not above it", () => {
  const { historyEl, view, append } = page();
  const prompt = endedTurn(view);
  view.handOff();
  assert.ok(view.root.classList.contains("leaving"));
  const row = document.createElement("div");
  row.className = "bubble note";
  append(row);
  const kids = [...historyEl.children];
  assert.ok(kids.includes(prompt), "the turn is in the history");
  assert.ok(kids.indexOf(row) > kids.indexOf(prompt), "the row comes after the turn");
  assert.ok(view.root.hidden);
});

test("the timing host settles a sliding stage too: a late timing line goes after the turn", () => {
  const { historyEl, view } = page();
  const prompt = endedTurn(view);
  view.handOff();
  assert.equal(view.timingHost(), null);
  const line = document.createElement("div");
  historyEl.appendChild(line);
  const kids = [...historyEl.children];
  assert.ok(kids.includes(prompt), "the turn is in the history");
  assert.ok(kids.indexOf(line) > kids.indexOf(prompt));
});

test("a ref's show-in-turn on a row of a turn sliding away finishes the slide; the stage doesn't reopen", () => {
  const { historyEl, view } = page();
  endedTurn(view);
  const row = document.createElement("div");
  view.root.querySelector(".ts-cloud-body").appendChild(row);
  view.handOff();
  row.dispatchEvent(new window.CustomEvent("ref:reveal", { bubbles: true, detail: {} }));
  // The fold finished at once: the turn is in the history, the stage hidden
  // and its cloud left closed.
  assert.ok(view.root.hidden);
  assert.ok(!view.root.classList.contains("cloud-open"));
  assert.ok(historyEl.querySelector(".bubble.user"));
});

test("a reset while the turn slides away (another session opens) drops the turn: it never reaches the new history", () => {
  const { historyEl, view } = page();
  const prompt = endedTurn(view);
  view.handOff();
  assert.ok(view.root.classList.contains("leaving"));
  // select(): "Loading…" first, then closeStream's reset.
  historyEl.replaceChildren(Object.assign(document.createElement("div"), { className: "hint", textContent: "Loading…" }));
  view.reset();
  assert.equal(historyEl.contains(prompt), false);
  assert.equal(historyEl.querySelector(":scope > .hint")?.textContent, "Loading…");
  assert.ok(view.root.hidden);
  assert.ok(!view.root.classList.contains("leaving"));
  // The fold's timer is gone with it: nothing arrives later.
  view.settleFold();
  assert.equal(historyEl.contains(prompt), false);
});

// Two lines queued for after a turn (delivery queue): the first one's
// turn_started hands the ended turn off (both queued lines go into the
// history with it), then the stage takes the first as its prompt. The
// second still waits behind that turn: back below the new turn's card, as
// a reload's snapshot places it.
function queuedBubble(text) {
  const el = document.createElement("div");
  el.className = "bubble user queued";
  el.dataset.delivery = "queue";
  el.textContent = text;
  return el;
}

test("two queued lines: the next turn takes the first as its prompt, the second waits below that turn, not above it", () => {
  const { historyEl, view, append } = page();
  try {
    twoQueued(historyEl, view, append);
  } finally {
    view.reset();
  }
});

function twoQueued(historyEl, view, append) {
  const prompt = document.createElement("div");
  prompt.className = "bubble user";
  view.turnStarted({ promptBubble: prompt });
  const [a, b] = [queuedBubble("A"), queuedBubble("B")];
  append(a);
  append(b);
  const queued = view.root.querySelector(".ts-queued");
  const texts = (el) => [...el.children].map((c) => c.textContent);
  assert.deepEqual(texts(queued), ["A", "B"]);
  view.turnEnded({ kind: "completed" });
  view.answerReady();
  // A's turn_started (stream_handlers.js): the hand-off first, then the start.
  view.handOff({ immediate: true });
  assert.equal(historyEl.contains(a) && historyEl.contains(b), true);
  a.classList.remove("queued");
  view.turnStarted({ promptBubble: a });
  assert.equal(view.root.querySelector(".ts-prompt").contains(a), true);
  assert.deepEqual(texts(queued), ["B"]);
  assert.equal(historyEl.contains(b), false);
  // The ended turn's own rows stay in the history.
  assert.equal(historyEl.contains(prompt), true);
}

// ── the slots' markup and node identity (recorded before the split into
// stage_frame.js, stage_watch.js and stage_slots.js; they guard it) ──────

const SKELETON = '<section class="turn-stage" id="turnStage" hidden="" aria-label="Running turn"><div class="ts-status"><span class="ts-mark"></span><span class="ts-phase"></span><span class="ts-step"></span><span class="ts-timing"></span><span class="ts-mini"></span><span class="ts-defer">moves up when you leave</span><button class="ts-fold" type="button"></button></div><div class="ts-scroll"><div class="ts-prompt" title="Show the whole prompt"></div><div class="ts-live"><div class="ts-headline" tabindex="0" role="button" title="Show this step\'s reasoning"></div><div class="ts-asking" hidden=""></div><div class="ts-now"></div><div class="ts-trail"></div></div><div class="ts-extras"></div><div class="ts-answer"></div><div class="ts-tail"></div><div class="ts-cloud-body" hidden=""></div><div class="ts-hold" aria-hidden="true"></div></div><div class="ts-foot"><button class="ts-chip" type="button"><span class="ts-chip-label"></span><span class="ts-ticks"></span></button><button class="ts-room-pill" type="button" aria-label="Go to the question" hidden="">❓ Answer ↓</button></div><div class="ts-queued"></div></section>';

// A stopper as task_stop.js's: a running task_wait's task.
const fakeTaskStop = {
  target: (row) => (row.status === "running" && row.tool === "task_wait" ? row.view.task_id : null),
  busy: () => false,
  stop: () => Promise.resolve(),
  watch: () => () => {},
};

// The next frame, after the stage's scheduled refresh (rAF runs in order).
const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));
const $ = (view, sel) => view.root.querySelector(sel);
const slot = (view, sel) => htmlOf($(view, sel));

function slotsPage() {
  const { historyEl, view, append } = page({ taskStop: fakeTaskStop });
  view.turnStarted({});
  view.generationStarted({ iteration: 1 });
  return { historyEl, view, append };
}

test("the stage's skeleton, right after it is made", () => {
  const { view } = page();
  assert.equal(htmlOf(view.root), SKELETON);
});

// The stage lets go of a turn (a re-render, a new session): the slots empty,
// and the status row and chip say nothing either — left as they were, a
// hidden stage still reads "thinking · step 1", the stale stage of a turn
// the page stopped following.
test("resetting the stage clears the status row and the chip, not only the slots", async () => {
  const { view } = page({ taskStop: fakeTaskStop });
  view.turnStarted({});
  view.generationStarted({ iteration: 1 });
  view.chunk({ iteration: 1, thinking: "I look at the file first. Then I read it." });
  await frame();
  assert.equal($(view, ".ts-phase").textContent, "thinking");
  assert.equal($(view, ".ts-step").textContent, "step 1");
  view.turnEnded({ kind: "completed" });
  await frame();
  view.reset();
  assert.equal(slot(view, ".ts-status"), '<div class="ts-status"><span class="ts-mark"></span><span class="ts-phase"></span><span class="ts-step"></span><span class="ts-timing"></span><span class="ts-mini" title=""></span><span class="ts-defer">moves up when you leave</span><button class="ts-fold" type="button" aria-label="Collapse the running turn to its status" aria-expanded="true">▾</button></div>');
  assert.equal($(view, ".ts-chip-label").textContent, "");
});

test("slots: a thinking headline, the quiet word and an empty trail", async () => {
  const { view } = slotsPage();
  try {
    view.chunk({ iteration: 1, thinking: "I look at the file first. Then I read it." });
    // The ticker's line shows on its own timer (thinking_ticker.js).
    for (let i = 0; i < 100 && !$(view, ".ts-headline.thinking"); i++) await new Promise((resolve) => setTimeout(resolve, 20));
    await frame();
    assert.equal(slot(view, ".ts-headline"), '<div class="ts-headline thinking fresh" tabindex="0" role="button" title="Show this step\'s reasoning"><span class="ts-think-tag">thinking</span>Then I read it.</div>');
    assert.equal(slot(view, ".ts-now"), '<div class="ts-now"><span class="ts-idle"></span><span class="ts-title quiet">thinking…</span></div>');
    assert.equal(slot(view, ".ts-trail"), '<div class="ts-trail"><span class="ts-trail-item none">no tool calls yet</span></div>');
  } finally {
    view.reset();
  }
});

test("slots: a narration headline, a running tool, its tick and the chip label", async () => {
  const { view } = slotsPage();
  try {
    view.chunk({ iteration: 1, text: "Reading the readme now. " });
    view.toolStarted({ iteration: 1, call_index: 1, tool: "execute", params: 'command="ls -la"', title: "ls -la", view: { command: "ls -la && pwd" } });
    await frame();
    assert.equal(slot(view, ".ts-headline"), '<div class="ts-headline fresh" tabindex="0" role="button" title="Show this step\'s reasoning">Reading the readme now.</div>');
    assert.equal(slot(view, ".ts-now"), '<div class="ts-now running"><span class="ts-spin"></span><span class="ts-tool exec">execute</span><span class="ts-title" title="ls -la &amp;&amp; pwd">ls -la</span></div>');
    assert.equal(slot(view, ".ts-foot"), '<div class="ts-foot"><button class="ts-chip" type="button" aria-expanded="false"><span class="ts-chip-label">1 step · 1 tool call</span><span class="ts-ticks"><span role="button" class="ts-tick exec running" data-step="0" title="step 1"></span></span></button><button class="ts-room-pill" type="button" aria-label="Go to the question" hidden="">❓ Answer ↓</button></div>');
    assert.equal(slot(view, ".ts-status"), '<div class="ts-status"><span class="ts-mark"></span><span class="ts-phase">running a tool</span><span class="ts-step">step 1</span><span class="ts-timing"></span><span class="ts-mini" title=""></span><span class="ts-defer">moves up when you leave</span><button class="ts-fold" type="button" aria-label="Collapse the running turn to its status" aria-expanded="true">▾</button></div>');
  } finally {
    view.reset();
  }
});

test("slots: a task_wait with its stop button, a flash and toned items in the trail, the ticks", async () => {
  const { view } = slotsPage();
  try {
    view.chunk({ iteration: 1, text: "Running the specs. " });
    view.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: 'path="lib/a.rb"', title: "lib/a.rb" });
    view.toolCompleted({ iteration: 1, call_index: 1, tool: "read", output: "ok", activity: { status: "ok" } });
    view.toolStarted({ iteration: 1, call_index: 2, tool: "execute", params: 'command="false"', title: "false" });
    view.toolCompleted({ iteration: 1, call_index: 2, tool: "execute", output: "x", activity: { status: "error" } });
    view.toolStarted({ iteration: 1, call_index: 3, tool: "execute", params: 'command="sleep 9"', title: "sleep 9" });
    view.toolCompleted({ iteration: 1, call_index: 3, tool: "execute", output: "x", activity: { status: "stopped" } });
    view.toolStarted({ iteration: 1, call_index: 4, tool: "task_wait", params: 'task_id="t1"', title: "npm test", view: { task_id: "t1" } });
    view.notice({ hook: "h", level: "warn", text: "careful" });
    await frame();
    assert.equal(slot(view, ".ts-now"), '<div class="ts-now running"><span class="ts-spin"></span><span class="ts-tool exec">task_wait</span><span class="ts-title" title="task_id=&quot;t1&quot;">npm test</span><button type="button" class="ghost task-stop" title="Kill this background task; the model is told you stopped it">stop task</button></div>');
    assert.equal(slot(view, ".ts-trail"), '<div class="ts-trail"><span class="ts-trail-item warn" title="⚠ h: careful">⚠ h: careful</span><span class="ts-trail-item" title="✓ read a.rb">✓ read a.rb</span><span class="ts-trail-item error" title="✕ execute false">✕ execute false</span><span class="ts-trail-item stopped" title="■ execute sleep 9">■ execute sleep 9</span></div>');
    assert.equal(slot(view, ".ts-ticks"), '<span class="ts-ticks"><span role="button" class="ts-tick read ok" data-step="0" title="step 1"></span><span role="button" class="ts-tick exec error" data-step="0" title="step 1"></span><span role="button" class="ts-tick exec stopped" data-step="0" title="step 1"></span><span role="button" class="ts-tick exec running" data-step="0" title="step 1"></span></span>');
  } finally {
    view.reset();
  }
});

test("a live notice row with a URL links it; the trail's flash stays text", async () => {
  const { view } = slotsPage();
  try {
    view.notice({ hook: "source-links", text: "sources: JIRA JIRA-1 → https://x.com/JIRA-1, <b>x</b>" });
    await frame();
    const row = view.root.querySelector(".gen .hook-notice");
    const a = row.querySelector("a");
    assert.equal(a.getAttribute("href"), "https://x.com/JIRA-1");
    assert.equal(a.getAttribute("target"), "_blank");
    assert.equal(a.getAttribute("rel"), "noopener noreferrer");
    assert.equal(row.querySelectorAll("a").length, 1);
    assert.equal(row.querySelector("b"), null);
    assert.ok(row.textContent.endsWith("https://x.com/JIRA-1, <b>x</b>"));
    assert.equal(view.root.querySelector(".ts-trail a"), null);
  } finally {
    view.reset();
  }
});

test("identity: tick nodes are kept as the list grows (their blink never restarts)", async () => {
  const { view } = slotsPage();
  try {
    view.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: "a" });
    await frame();
    const first = $(view, ".ts-ticks").children[0];
    view.toolCompleted({ iteration: 1, call_index: 1, tool: "read", output: "ok", activity: { status: "ok" } });
    view.toolStarted({ iteration: 1, call_index: 2, tool: "read", params: "b" });
    await frame();
    const kids = $(view, ".ts-ticks").children;
    assert.equal(kids.length, 2);
    assert.ok(kids[0] === first);
    assert.equal(first.className, "ts-tick read ok");
  } finally {
    view.reset();
  }
});

test("identity: the headline element is kept; fresh is added again only when its text changes", async () => {
  const { view } = slotsPage();
  try {
    view.chunk({ iteration: 1, text: "One sentence here. " });
    await frame();
    const headline = $(view, ".ts-headline");
    assert.ok(headline.classList.contains("fresh"));
    headline.classList.remove("fresh");
    view.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: "a" });
    await frame();
    assert.ok(!headline.classList.contains("fresh"), "same text: left alone");
    view.chunk({ iteration: 1, text: "Another one now. " });
    await frame();
    assert.ok($(view, ".ts-headline") === headline);
    assert.ok(headline.classList.contains("fresh"));
    assert.equal(headline.textContent, "Another one now.");
  } finally {
    view.reset();
  }
});

test("identity: the asking text reads from its top again only when it changes", async () => {
  const { view } = slotsPage();
  try {
    view.chunk({ iteration: 1, text: "Shall I go on?" });
    view.toolStarted({ iteration: 1, call_index: 1, tool: "ask", params: "q" });
    const card = document.createElement("div");
    card.className = "bubble question";
    view.place(card);
    const asking = $(view, ".ts-asking");
    assert.equal(asking.hidden, false);
    assert.equal(asking.textContent, "Shall I go on?");
    asking.scrollTop = 30;
    view.toolStarted({ iteration: 1, call_index: 1, tool: "ask", params: "q" });
    await frame();
    assert.equal(asking.scrollTop, 30, "same text: the scroll stays");
    view.chunk({ iteration: 1, text: " Say yes." });
    await frame();
    assert.equal(asking.textContent, "Shall I go on? Say yes.");
    assert.equal(asking.scrollTop, 0);
  } finally {
    view.reset();
  }
});

test("a foreign node in the timing slot (app.js's live timing line) survives the refreshes", async () => {
  const { view } = slotsPage();
  try {
    const line = document.createElement("span");
    line.className = "live-timing";
    view.timingHost().appendChild(line);
    view.chunk({ iteration: 1, text: "Hello there. " });
    view.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: "a" });
    await frame();
    view.toolCompleted({ iteration: 1, call_index: 1, tool: "read", output: "ok", activity: { status: "ok" } });
    view.generationCompleted();
    view.turnEnded({ kind: "completed" });
    assert.ok($(view, ".ts-timing").firstChild === line);
    // The chip leaves the time to that line.
    assert.equal($(view, ".ts-chip-label").textContent, "1 step · 1 tool call");
  } finally {
    view.reset();
  }
});

test("two turns in a row: the second turn's slots start empty and draw again", async () => {
  const { view } = slotsPage();
  try {
    view.chunk({ iteration: 1, text: "First turn. " });
    view.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: "a" });
    view.toolCompleted({ iteration: 1, call_index: 1, tool: "read", output: "ok", activity: { status: "ok" } });
    view.generationCompleted();
    view.turnEnded({ kind: "completed" });
    view.answerReady();
    view.handOff({ immediate: true });
    view.turnStarted({});
    assert.equal($(view, ".ts-ticks").children.length, 0);
    assert.equal($(view, ".ts-headline").textContent, "…");
    view.generationStarted({ iteration: 1 });
    view.chunk({ iteration: 1, text: "Second turn. " });
    view.toolStarted({ iteration: 1, call_index: 1, tool: "edit", params: 'path="b.rb"', title: "b.rb" });
    view.toolCompleted({ iteration: 1, call_index: 1, tool: "edit", output: "ok", activity: { status: "ok" } });
    view.toolStarted({ iteration: 1, call_index: 2, tool: "execute", params: 'command="ls"', title: "ls" });
    await frame();
    assert.equal($(view, ".ts-headline").textContent, "Second turn.");
    assert.equal(slot(view, ".ts-now"), '<div class="ts-now running"><span class="ts-spin"></span><span class="ts-tool exec">execute</span><span class="ts-title" title="ls">ls</span></div>');
    assert.equal(slot(view, ".ts-trail"), '<div class="ts-trail"><span class="ts-trail-item" title="✓ edit b.rb">✓ edit b.rb</span></div>');
    assert.equal(slot(view, ".ts-ticks"), '<span class="ts-ticks"><span role="button" class="ts-tick edit ok" data-step="0" title="step 1"></span><span role="button" class="ts-tick exec running" data-step="0" title="step 1"></span></span>');
    assert.equal($(view, ".ts-chip-label").textContent, "1 step · 2 tool calls");
  } finally {
    view.reset();
  }
});

// ── the question room: a model's own question whose asking text overflows
// its cap gets the stage's raised cap and an uncapped asking slot ─────────

// The page's and the panel's sizes (happy-dom has no layout): room is
// 2000 - 10 - 32, so the cap is the page's share (600 px, 850 px with the
// room's cap).
function sizePage(t) {
  const center = document.getElementById("center");
  Object.defineProperty(center, "clientHeight", { configurable: true, get: () => 2000 });
  const was = Object.getOwnPropertyDescriptor(window, "innerHeight");
  Object.defineProperty(window, "innerHeight", { configurable: true, get: () => 1000 });
  t.after(() => { if (was) Object.defineProperty(window, "innerHeight", was); else delete window.innerHeight; });
}

// A turn whose reply asks: the asking text drawn, overflowing its cap
// (+overflow+) or not, then +cards+ placed in the extras (each a
// [className, dataset]).
async function askPage(t, { overflow = true, cards = [["bubble question", { kind: "question" }]] } = {}) {
  const { view } = page({ taskStop: fakeTaskStop });
  sizePage(t);
  view.turnStarted({});
  view.generationStarted({ iteration: 1 });
  view.chunk({ iteration: 1, text: "Here is the plan. ".repeat(40) });
  view.toolStarted({ iteration: 1, call_index: 1, tool: "ask_user_question", params: "q" });
  const asking = $(view, ".ts-asking");
  Object.defineProperty(asking, "scrollHeight", { configurable: true, get: () => (overflow ? 900 : 100) });
  Object.defineProperty(asking, "clientHeight", { configurable: true, get: () => 100 });
  const els = cards.map(([cls, data]) => {
    const card = document.createElement("details");
    card.className = cls;
    Object.assign(card.dataset, data);
    // The card's buttons: an answer removes them (a childList change, as
    // question_cards.js's resolve does).
    card.appendChild(document.createElement("button"));
    view.place(card);
    return card;
  });
  // The asking text's final form (here a null render: the raw text), then
  // the redraw that measures it.
  await tick();
  await frame();
  return { view, asking, card: els[els.length - 1] };
}

const room = (view) => view.root.classList.contains("question-room");
const capOf = (view) => view.root.style.getPropertyValue("--stage-max");
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const resize = () => window.dispatchEvent(new window.Event("resize"));

async function answer(card) {
  card.classList.add("answered");
  card.querySelector("button")?.remove();
  await tick();
}

test("question room: an overflowing plain ask question gets the class and the raised cap", async (t) => {
  const { view } = await askPage(t);
  try {
    assert.equal(room(view), true);
    assert.equal(capOf(view), "850px");
  } finally {
    view.reset();
  }
});

test("question room: none for a short question, an approval, the step limit, a hook's question or a relayed one", async (t) => {
  const cases = {
    short: { overflow: false },
    approval: { cards: [["bubble question approval", { kind: "approval" }]] },
    "step limit": { cards: [["bubble question step-limit", { kind: "continue" }]] },
    "continue card": { cards: [["bubble continue", {}]] },
    hook: { cards: [["bubble question", { kind: "hook" }]] },
    relayed: { cards: [["bubble question", { kind: "question", relay: "1" }]] },
  };
  for (const [name, opts] of Object.entries(cases)) {
    const { view } = await askPage(t, opts);
    try {
      assert.equal(room(view), false, name);
      assert.equal(capOf(view), "600px", name);
    } finally {
      view.reset();
    }
  }
});

test("question room: none when an answered ask card sits in the extras and an approval blocks", async (t) => {
  const { view } = await askPage(t, {
    cards: [["bubble question answered", { kind: "question" }], ["bubble question approval", { kind: "approval" }]],
  });
  try {
    assert.equal(room(view), false);
    assert.equal(capOf(view), "600px");
  } finally {
    view.reset();
  }
});

test("question room: the class goes at the answer, the cap stays for the turn; a new turn and a clear drop it", async (t) => {
  const { view, card } = await askPage(t);
  try {
    await answer(card);
    assert.equal(room(view), false);
    resize();
    assert.equal(capOf(view), "850px", "the frame is grow-only: the cap never drops at the answer");
    view.turnStarted({});
    assert.equal(capOf(view), "600px");
    const again = await askPage(t);
    assert.equal(capOf(again.view), "850px");
    again.view.reset();
    assert.equal(capOf(again.view), "600px");
    assert.equal(room(again.view), false);
  } finally {
    view.reset();
  }
});

// ── the question room's arrival reveal and jump pill ─────────────────────

// Layout stubs (happy-dom has none): the asking text at 100, the card's
// extras from 600 to 800, the card itself from 610, a 400 px tall scroller.
function laidOut(t, view) {
  t.mock.method(globalThis, "matchMedia", () => ({ matches: true })); // reduced motion: the reveal is at once
  const set = (el, props) => {
    for (const [k, v] of Object.entries(props)) Object.defineProperty(el, k, { configurable: true, get: () => v });
  };
  set($(view, ".ts-asking"), { offsetTop: 100, offsetHeight: 450 });
  set($(view, ".ts-extras"), { offsetTop: 600, offsetHeight: 200 });
  set(view.scrollEl, { clientHeight: 400 });
  for (const card of $(view, ".ts-extras").children) set(card, { offsetTop: 610, offsetHeight: 180 });
}

// A long ask question placed with the layout in place, then its arrival
// reveal (two frames on, no growth running).
async function arrived(t, opts = {}) {
  const { view } = page({ taskStop: fakeTaskStop });
  sizePage(t);
  view.turnStarted({});
  view.generationStarted({ iteration: 1 });
  view.chunk({ iteration: 1, text: "Here is the plan. ".repeat(40) });
  view.toolStarted({ iteration: 1, call_index: 1, tool: "ask_user_question", params: "q" });
  const asking = $(view, ".ts-asking");
  const overflow = opts.overflow ?? true;
  Object.defineProperty(asking, "scrollHeight", { configurable: true, get: () => (overflow ? 900 : 100) });
  Object.defineProperty(asking, "clientHeight", { configurable: true, get: () => 100 });
  const card = document.createElement("details");
  card.className = opts.cls || "bubble question";
  card.dataset.kind = opts.kind || "question";
  card.appendChild(document.createElement("button"));
  $(view, ".ts-extras").appendChild(card);
  laidOut(t, view);
  card.remove();
  view.place(card);
  const pill = $(view, ".ts-room-pill");
  const pillShownBefore = !pill.hidden;
  await frame();
  await frame();
  await tick();
  return { view, card, pill, pillShownBefore };
}

// The sight's callback for +card+, as the browser's would call it.
function seeCard(card, inSight) {
  const sight = sights.find((s) => s.els.has(card));
  assert.ok(sight, "the card is watched");
  sight.fn([{ target: card, isIntersecting: inSight }]);
}

test("question room: the arrival reads from the reply's start; a short question keeps the card-end rule", async (t) => {
  const long = await arrived(t);
  try {
    assert.equal(long.view.scrollEl.scrollTop, 100);
    const sight = sights.find((s) => s.els.has(long.card));
    assert.ok(sight.options.root === long.view.scrollEl);
    assert.equal(sight.options.rootMargin, "0px 0px -40px 0px");
  } finally {
    long.view.reset();
  }
  const short = await arrived(t, { overflow: false });
  try {
    assert.equal(short.view.scrollEl.scrollTop, 400);
  } finally {
    short.view.reset();
  }
});

test("question room: the pill shows only after the arrival, while the card is out of sight; never while collapsed; gone at the answer", async (t) => {
  const { view, card, pill, pillShownBefore } = await arrived(t);
  try {
    assert.equal(pillShownBefore, false, "no pill while the stage grows to the card");
    seeCard(card, false);
    assert.equal(pill.hidden, false);
    seeCard(card, true);
    assert.equal(pill.hidden, true);
    seeCard(card, false);
    assert.equal(pill.hidden, false);
    $(view, ".ts-fold").click();
    await frame();
    assert.equal(pill.hidden, true, "collapsed");
    $(view, ".ts-fold").click();
    await frame();
    assert.equal(pill.hidden, false);
    await answer(card);
    assert.equal(pill.hidden, true);
    assert.equal(sights.some((s) => s.els.has(card)), false, "the answered card isn't watched");
  } finally {
    view.reset();
  }
});

test("question room: no pill for an approval or a short question", async (t) => {
  for (const opts of [{ cls: "bubble question approval", kind: "approval" }, { overflow: false }]) {
    const { view, card, pill } = await arrived(t, opts);
    try {
      assert.equal(sights.some((s) => s.els.has(card)), false);
      assert.equal(pill.hidden, true);
    } finally {
      view.reset();
    }
  }
});

test("question room: the pill's click brings the card's end into sight (not the reply's start)", async (t) => {
  const { view, card, pill } = await arrived(t);
  try {
    seeCard(card, false);
    pill.click();
    assert.equal(view.scrollEl.scrollTop, 400);
    // A reader below the card (the cloud open under it): back up to it.
    view.scrollEl.scrollTop = 900;
    pill.click();
    assert.equal(view.scrollEl.scrollTop, 602);
  } finally {
    view.reset();
  }
});

test("question room: a new turn hides the pill and stops watching the card", async (t) => {
  const { view, card, pill } = await arrived(t);
  try {
    seeCard(card, false);
    assert.equal(pill.hidden, false);
    view.turnStarted({});
    assert.equal(pill.hidden, true);
    assert.equal(sights.some((s) => s.els.has(card)), false);
  } finally {
    view.reset();
  }
});

test("question room: measured at the asking text's draws only: a short question stays short when its cap drops later", async (t) => {
  let overflow = false;
  const { view, asking } = await askPage(t, { overflow: false });
  try {
    Object.defineProperty(asking, "scrollHeight", { configurable: true, get: () => (overflow ? 900 : 100) });
    // A phone's keyboard: the cap (and the slot's) drops, the text overflows now.
    overflow = true;
    view.toolStarted({ iteration: 1, call_index: 1, tool: "ask_user_question", params: "q" });
    await frame();
    assert.equal(room(view), false);
  } finally {
    view.reset();
  }
});

// After the answer the live slots keep the waiting height (held-wait) until
// the next step; with the room that height is the whole reply's. At the
// next step it goes as far as the stage's scroll can absorb it (the scroll
// moves up by as much): the card in view doesn't move.
function heldLive(view, { waiting, running }) {
  const live = $(view, ".ts-live");
  Object.defineProperty(live, "offsetHeight", { configurable: true, get: () => {
    if (live.style.minHeight) return Math.max(running, parseFloat(live.style.minHeight));
    return view.root.classList.contains("held-wait") ? waiting : running;
  } });
  return live;
}

test("question room: the next step lets the held height go under the scroll's cover (the card stays put)", async (t) => {
  const { view, card } = await askPage(t);
  try {
    const live = heldLive(view, { waiting: 700, running: 100 });
    await answer(card);
    view.scrollEl.scrollTop = 450;
    view.generationStarted({ iteration: 2 });
    // 600 px to let go, 450 absorbed by the scroll: 150 kept.
    assert.equal(view.scrollEl.scrollTop, 0);
    assert.equal(live.style.minHeight, "250px");
    assert.equal(view.root.classList.contains("held-wait"), false);
    // All of it when the scroll covers it.
    view.chunk({ iteration: 2, text: "Reading. " });
    view.turnStarted({});
    assert.equal(live.style.minHeight, "");
  } finally {
    view.reset();
  }
  const again = await askPage(t);
  try {
    heldLive(again.view, { waiting: 700, running: 100 });
    await answer(again.card);
    again.view.scrollEl.scrollTop = 800;
    again.view.generationStarted({ iteration: 2 });
    assert.equal(again.view.scrollEl.scrollTop, 200);
    assert.equal($(again.view, ".ts-live").style.minHeight, "");
  } finally {
    again.view.reset();
  }
});

test("without the room the next step lets the held height go as before (the scroll left alone)", async (t) => {
  const { view, card } = await askPage(t, { overflow: false });
  try {
    const live = heldLive(view, { waiting: 300, running: 100 });
    await answer(card);
    view.scrollEl.scrollTop = 150;
    view.generationStarted({ iteration: 2 });
    assert.equal(view.scrollEl.scrollTop, 150);
    assert.equal(live.style.minHeight, "");
  } finally {
    view.reset();
  }
});

// The CI flake (the question test's reload at 390x700 on Linux fonts): the
// raw text overflowed its cap, its markdown fits. The room is decided on the
// final form only, so a short question never gets it from its raw draw.
test("question room: decided on the asking text's final form: a raw text that overflows while its markdown fits gets none", async (t) => {
  let settle;
  const { view } = page({ taskStop: fakeTaskStop, renderMarkdown: () => new Promise((resolve) => { settle = resolve; }) });
  sizePage(t);
  try {
    view.turnStarted({});
    view.generationStarted({ iteration: 1 });
    view.chunk({ iteration: 1, text: "## Two files\n\nEither one." });
    view.toolStarted({ iteration: 1, call_index: 1, tool: "ask_user_question", params: "q" });
    const asking = $(view, ".ts-asking");
    Object.defineProperty(asking, "scrollHeight", { configurable: true, get: () => (asking.classList.contains("markdown") ? 100 : 160) });
    Object.defineProperty(asking, "clientHeight", { configurable: true, get: () => 147 });
    const card = document.createElement("details");
    card.className = "bubble question";
    card.dataset.kind = "question";
    view.place(card);
    await frame();
    assert.equal(room(view), false, "the raw draw decides nothing");
    settle("<h2>Two files</h2><p>Either one.</p>");
    await tick();
    await frame();
    assert.equal(asking.classList.contains("markdown"), true);
    assert.equal(room(view), false);
    assert.equal(capOf(view), "600px");
  } finally {
    view.reset();
  }
});

// The frames by hand (happy-dom's requestAnimationFrame is a setImmediate:
// any number of them run while a test awaits a timer): +run()+ runs the
// callbacks queued so far, one frame; those they queue wait for the next.
function handFrames(t) {
  let queue = [];
  t.mock.method(globalThis, "requestAnimationFrame", (fn) => { queue.push(fn); return queue.length; });
  return {
    run() {
      const now = queue;
      queue = [];
      for (const fn of now) fn(performance.now());
    },
  };
}

test("question room: a room decided after the arrival reveal reads from the reply's start then; the pill only after it", async (t) => {
  let settle;
  const frames = handFrames(t);
  const { view } = page({ taskStop: fakeTaskStop, renderMarkdown: () => new Promise((resolve) => { settle = resolve; }) });
  sizePage(t);
  try {
    view.turnStarted({});
    view.generationStarted({ iteration: 1 });
    view.chunk({ iteration: 1, text: "Here is the plan. ".repeat(40) });
    view.toolStarted({ iteration: 1, call_index: 1, tool: "ask_user_question", params: "q" });
    const asking = $(view, ".ts-asking");
    Object.defineProperty(asking, "scrollHeight", { configurable: true, get: () => 900 });
    Object.defineProperty(asking, "clientHeight", { configurable: true, get: () => 100 });
    const card = document.createElement("details");
    card.className = "bubble question";
    card.dataset.kind = "question";
    card.appendChild(document.createElement("button"));
    $(view, ".ts-extras").appendChild(card);
    laidOut(t, view);
    card.remove();
    view.place(card);
    // The arrival reveal: two frames on (afterGrowth), no growth running.
    frames.run();
    frames.run();
    assert.equal(room(view), false);
    assert.equal(view.scrollEl.scrollTop, 400, "no room yet: the card-end rule");
    // The markdown comes back: its redraw (the next frame) decides the room.
    settle("<p>Here is the plan.</p>");
    await tick();
    frames.run();
    assert.equal(room(view), true);
    seeCard(card, false);
    assert.equal($(view, ".ts-room-pill").hidden, true, "not before its reveal");
    assert.equal(view.scrollEl.scrollTop, 400);
    frames.run();
    assert.equal($(view, ".ts-room-pill").hidden, true, "one frame on: still growing");
    frames.run();
    assert.equal(view.scrollEl.scrollTop, 100);
    assert.equal($(view, ".ts-room-pill").hidden, false);
  } finally {
    view.reset();
  }
});
