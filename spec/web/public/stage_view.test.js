// The stage view's hand-off timing (stage_view.js), in happy-dom: what
// arrives while the finished turn slides away goes after it.
import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

for (const k of ["MutationObserver", "CustomEvent", "localStorage", "getSelection"]) {
  if (!(k in globalThis)) globalThis[k] = window[k];
}
globalThis.ResizeObserver ??= class { observe() {} disconnect() {} };
globalThis.matchMedia ??= () => ({ matches: false });
if (!window.HTMLElement.prototype.animate) window.HTMLElement.prototype.animate = () => ({ finished: Promise.resolve(), cancel() {}, playState: "finished" });

const { createStageView } = await import("../../../lib/samagotchi/web/public/stage_view.js");

function page({ taskStop = null } = {}) {
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

const SKELETON = '<section class="turn-stage" id="turnStage" hidden="" aria-label="Running turn"><div class="ts-status"><span class="ts-mark"></span><span class="ts-phase"></span><span class="ts-step"></span><span class="ts-timing"></span><span class="ts-mini"></span><span class="ts-defer">moves up when you leave</span><button class="ts-fold" type="button"></button></div><div class="ts-scroll"><div class="ts-prompt" title="Show the whole prompt"></div><div class="ts-live"><div class="ts-headline" tabindex="0" role="button" title="Show this step\'s reasoning"></div><div class="ts-asking" hidden=""></div><div class="ts-now"></div><div class="ts-trail"></div></div><div class="ts-extras"></div><div class="ts-answer"></div><div class="ts-tail"></div><div class="ts-cloud-body" hidden=""></div><div class="ts-hold" aria-hidden="true"></div></div><div class="ts-foot"><button class="ts-chip" type="button"><span class="ts-chip-label"></span><span class="ts-ticks"></span></button></div><div class="ts-queued"></div></section>';

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
    assert.equal(slot(view, ".ts-foot"), '<div class="ts-foot"><button class="ts-chip" type="button" aria-expanded="false"><span class="ts-chip-label">1 step · 1 tool call</span><span class="ts-ticks"><span role="button" class="ts-tick exec running" data-step="0" title="step 1"></span></span></button></div>');
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
