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
const { createCardsPlace } = await import("../../../lib/samagotchi/web/public/cards_place.js");

function page({ taskStop = null, renderMarkdown, onCancel = null, clock, streamLive, onHandedOff = null } = {}) {
  document.body.innerHTML = '<div id="center"><div id="history"></div><div id="dock"><div id="composer"></div></div></div>';
  const historyEl = document.getElementById("history");
  const view = createStageView({
    historyEl,
    isNearBottom: () => false,
    sawText: () => false,
    sessionId: () => "s1",
    dockEl: document.getElementById("dock"),
    centerEl: document.getElementById("center"),
    taskStop,
    renderMarkdown,
    onCancel,
    clock,
    streamLive,
    onHandedOff,
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

test("the answer's turn key (data-answer-turn) arrives in the history with the hand-off", () => {
  const { historyEl, view } = page();
  const prompt = document.createElement("div");
  prompt.className = "bubble user";
  view.turnStarted({ promptBubble: prompt });
  view.generationStarted({ iteration: 1 });
  view.chunk({ iteration: 1, text: "Done." });
  view.generationCompleted();
  view.turnEnded({ kind: "completed", turnId: "T7" });
  view.answerReady();
  view.handOff({ immediate: true });
  const answer = historyEl.querySelector(".bubble.output");
  assert.equal(answer?.textContent, "Done.");
  assert.equal(answer.dataset.answerTurn, "T7");
});

test("the hand-off: an outlined completed turn lands closed, a canceled or failed one open", () => {
  const landed = (kind) => {
    const { historyEl, view } = page();
    view.turnStarted({ promptBubble: document.createElement("div") });
    view.generationStarted({ iteration: 1 });
    view.chunk({ iteration: 1, text: "Looking first." });
    view.generationCompleted();
    view.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: 'path="A.md"' });
    view.toolCompleted({ iteration: 1, call_index: 1, tool: "read", status: "ok", output: "ok" });
    view.generationStarted({ iteration: 2 });
    view.toolStarted({ iteration: 2, call_index: 1, tool: "read", params: 'path="B.md"' });
    view.turnEnded({ kind });
    view.answerReady();
    assert.equal(view.root.querySelector(".turn-work").open, true, `${kind}: open while in the stage`);
    view.handOff({ immediate: true });
    const block = historyEl.querySelector(".turn-work");
    assert.ok(block.classList.contains("outline"), kind);
    return block.open;
  };
  assert.equal(landed("completed"), false);
  assert.equal(landed("gone"), false);
  assert.equal(landed("canceled"), true);
  assert.equal(landed("failed"), true);
});

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

// A short notice's update to a long body swaps its element (card.js drawCard:
// <details> to <div>). In the slide the pieces are already listed: the old
// element would arrive and the new one go with the stage.
test("a card's update that swaps its element during the slide arrives in the history, not the old element", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { historyEl, view, append } = page();
  const cards = createCardsPlace({
    historyEl,
    turnDom: view,
    findInTurnRoots: (selector) => [...historyEl.querySelectorAll(selector), ...view.root.querySelectorAll(selector)],
    selected: () => "s1",
    clientId: "me",
    questionCards: null,
    bubbles: { removeHintIfEmpty: () => {}, placeFollowing: (el) => { append(el); return el; } },
    followWokenWorker: () => {},
    api: {},
  });
  endedTurn(view);
  cards.upsertCard({ id: "short", title: "Short version", body: "…" });
  assert.equal(view.root.querySelector(".plugin-card").tagName, "DETAILS");
  view.handOff();
  assert.ok(view.root.classList.contains("leaving"));
  cards.upsertCard({ id: "short", title: "Short version", body: "The answer.\n\nAsked about it." });
  t.mock.timers.tick(1000);
  const shown = [...historyEl.querySelectorAll(".plugin-card")];
  assert.equal(shown.length, 1);
  assert.equal(shown[0].tagName, "DIV");
  assert.match(shown[0].textContent, /The answer\./);
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

const SKELETON = '<section class="turn-stage" id="turnStage" hidden="" aria-label="Running turn"><div class="ts-status"><span class="ts-mark"></span><span class="ts-phase"></span><span class="ts-step"></span><span class="ts-timing"></span><span class="ts-stall-head"></span><span class="ts-mini"></span><span class="ts-defer">moves up when you leave</span><button class="ts-cancel" type="button" title="Cancel the running turn, whoever sent it" hidden="">Stop turn</button><button class="ts-fold" type="button"></button></div><div class="ts-scroll"><div class="ts-prompt" title="Show the whole prompt"></div><div class="ts-live"><div class="ts-headline" tabindex="0" role="button" title="Show this step\'s reasoning"></div><div class="ts-asking" hidden=""></div><div class="ts-now"></div><div class="ts-trail"></div></div><div class="ts-extras"></div><div class="ts-answer"></div><div class="ts-tail"></div><div class="ts-cloud-body" hidden=""></div><div class="ts-hold" aria-hidden="true"></div></div><div class="ts-foot"><button class="ts-chip" type="button"><span class="ts-chip-label"></span><span class="ts-ticks"></span></button></div><div class="ts-queued"></div></section>';

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
  assert.equal(slot(view, ".ts-status"), '<div class="ts-status"><span class="ts-mark"></span><span class="ts-phase"></span><span class="ts-step"></span><span class="ts-timing"></span><span class="ts-stall-head"></span><span class="ts-mini" title=""></span><span class="ts-defer">moves up when you leave</span><button class="ts-cancel" type="button" title="Cancel the running turn, whoever sent it" hidden="">Stop turn</button><button class="ts-fold" type="button" aria-label="Collapse the running turn to its status" aria-expanded="true">▾</button></div>');
  assert.equal($(view, ".ts-chip-label").textContent, "");
});

test("Stop turn: in the status row before the fold while the turn runs, disabled during its request, gone once it ended", async () => {
  let settle;
  let calls = 0;
  const { view } = page({ onCancel: () => { calls += 1; return new Promise((resolve) => { settle = resolve; }); } });
  const stop = $(view, ".ts-cancel");
  assert.equal(stop.hidden, true, "no turn: none");
  view.turnStarted({});
  view.generationStarted({ iteration: 1 });
  assert.equal(stop.hidden, false);
  assert.ok(stop.nextElementSibling === $(view, ".ts-fold"));
  stop.click();
  stop.click();
  assert.equal(calls, 1, "one request at a time");
  assert.equal(stop.disabled, true);
  settle();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(stop.disabled, false);
  view.turnEnded({ kind: "canceled" });
  assert.equal(stop.hidden, true, "an ended turn has none");
  view.reset();
  assert.equal(stop.hidden, true);
});

// A join that knows the session runs a turn but has none to draw (no
// current_turn): the stage shows its status row alone, with Stop turn.
test("Stop turn: a running turn the stage holds none of gets the status row alone, with Stop turn; its end, a reset or a real turn take it back", async () => {
  let calls = 0;
  const { view } = page({ onCancel: async () => { calls += 1; } });
  const stop = $(view, ".ts-cancel");
  view.runningWithoutTurn(true);
  assert.equal(view.root.hidden, false);
  assert.ok(view.root.classList.contains("bare"));
  assert.equal($(view, ".ts-phase").textContent, "running");
  assert.equal(stop.hidden, false);
  stop.click();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(calls, 1);
  view.runningWithoutTurn(false);
  assert.equal(view.root.hidden, true);
  assert.equal(view.root.classList.contains("bare"), false);
  // A real turn takes over the row; the bare call changes nothing then.
  view.runningWithoutTurn(true);
  view.turnStarted({});
  assert.equal(view.root.classList.contains("bare"), false);
  view.runningWithoutTurn(true);
  assert.equal(view.root.classList.contains("bare"), false);
  view.runningWithoutTurn(false);
  assert.equal(view.root.hidden, false, "the held turn's stage stays");
  view.reset();
  view.runningWithoutTurn(true);
  view.reset();
  assert.equal(view.root.hidden, true);
  assert.equal(view.root.classList.contains("bare"), false);
});

test("Stop turn: none without an onCancel", () => {
  const { view } = page();
  view.turnStarted({});
  assert.equal($(view, ".ts-cancel").hidden, true);
  view.reset();
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
    assert.equal(slot(view, ".ts-status"), '<div class="ts-status"><span class="ts-mark"></span><span class="ts-phase">running a tool</span><span class="ts-step">step 1</span><span class="ts-timing"></span><span class="ts-stall-head"></span><span class="ts-mini" title=""></span><span class="ts-defer">moves up when you leave</span><button class="ts-cancel" type="button" title="Cancel the running turn, whoever sent it" hidden="">Stop turn</button><button class="ts-fold" type="button" aria-label="Collapse the running turn to its status" aria-expanded="true">▾</button></div>');
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
    assert.ok(row.querySelector("b") === null);
    assert.ok(row.textContent.endsWith("https://x.com/JIRA-1, <b>x</b>"));
    assert.ok(view.root.querySelector(".ts-trail a") === null);
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
    view.flush(); // inside the flush interval (turn_block.js): nothing would write it yet
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

// ── cards that wait in the stage: an answered card's line, a tall
// approval's raised cap, the frame at the next step ─────────────────────

// The page's and the panel's sizes (happy-dom has no layout): room is
// 2000 - 10 - 32, so the cap is the page's share (600 px, 850 px with a
// raised cap).
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
async function askPage(t, { overflow = true, cards = [["bubble question", { kind: "question" }]], cardHeight = null } = {}) {
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
    if (cardHeight !== null) Object.defineProperty(card, "offsetHeight", { configurable: true, get: () => cardHeight });
    view.place(card);
    return card;
  });
  // The asking text's final form (here a null render: the raw text), then
  // the redraw that measures it.
  await tick();
  await frame();
  return { view, asking, card: els[els.length - 1] };
}

// fitFrame runs on the cap's change: a resize that moves the cap there and
// back refits the frame (happy-dom has no ResizeObserver callbacks).
async function refit(view) {
  const was = Object.getOwnPropertyDescriptor(window, "innerHeight");
  const h = window.innerHeight;
  Object.defineProperty(window, "innerHeight", { configurable: true, get: () => h + 200 });
  window.dispatchEvent(new window.Event("resize"));
  Object.defineProperty(window, "innerHeight", was);
  window.dispatchEvent(new window.Event("resize"));
  await frame();
}
const capOf = (view) => view.root.style.getPropertyValue("--stage-max");
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const resize = () => window.dispatchEvent(new window.Event("resize"));

async function answer(card) {
  card.classList.add("answered");
  card.querySelector("button")?.remove();
  await tick();
}

test("a tall card answered: its line comes back for a reader who had scrolled down it, as little as shows it; its slot shows its end", async (t) => {
  const { view, card } = await askPage(t, { overflow: false, cards: [["bubble question approval", { kind: "approval" }]] });
  try {
    const scroller = $(view, ".ts-scroll");
    const extras = $(view, ".ts-extras");
    Object.defineProperty(extras, "offsetTop", { configurable: true, get: () => 200 });
    Object.defineProperty(extras, "offsetHeight", { configurable: true, get: () => 60 });
    Object.defineProperty(extras, "scrollHeight", { configurable: true, get: () => 60 });
    Object.defineProperty(card, "offsetTop", { configurable: true, get: () => 200 });
    Object.defineProperty(scroller, "clientHeight", { configurable: true, get: () => 400 });
    scroller.scrollTop = 500;
    await answer(card);
    assert.equal(view.root.classList.contains("waiting"), false);
    assert.equal(scroller.scrollTop, 192, "the line at the view's top, not the blank the card left");
    assert.equal(extras.scrollTop, 60);
  } finally {
    view.reset();
  }
});

test("a card answered at the view's top stays exactly there, with its line's blank below it", async (t) => {
  const { view, card } = await askPage(t, { overflow: false, cards: [["bubble question approval", { kind: "approval" }]] });
  try {
    const scroller = $(view, ".ts-scroll");
    const extras = $(view, ".ts-extras");
    Object.defineProperty(extras, "offsetTop", { configurable: true, get: () => 200 });
    Object.defineProperty(extras, "offsetHeight", { configurable: true, get: () => 60 });
    Object.defineProperty(card, "offsetTop", { configurable: true, get: () => 200 });
    Object.defineProperty(scroller, "clientHeight", { configurable: true, get: () => 200 });
    scroller.scrollTop = 192;
    await answer(card);
    assert.equal(scroller.scrollTop, 192);
  } finally {
    view.reset();
  }
});

test("a card answered with the view's top exactly at its line's edge: the line comes back (the edge is rounded)", async (t) => {
  const { view, card } = await askPage(t, { overflow: false, cards: [["bubble question approval", { kind: "approval" }]] });
  try {
    const scroller = $(view, ".ts-scroll");
    const extras = $(view, ".ts-extras");
    Object.defineProperty(extras, "offsetTop", { configurable: true, get: () => 200 });
    Object.defineProperty(extras, "offsetHeight", { configurable: true, get: () => 60 });
    Object.defineProperty(card, "offsetTop", { configurable: true, get: () => 200 });
    Object.defineProperty(scroller, "clientHeight", { configurable: true, get: () => 400 });
    scroller.scrollTop = 220;
    await answer(card);
    assert.equal(scroller.scrollTop, 192);
  } finally {
    view.reset();
  }
});

test("a card answered leaves alone a reader who still sees where it was", async (t) => {
  const { view, card } = await askPage(t, { overflow: false, cards: [["bubble question approval", { kind: "approval" }]] });
  try {
    const scroller = $(view, ".ts-scroll");
    const extras = $(view, ".ts-extras");
    Object.defineProperty(extras, "offsetTop", { configurable: true, get: () => 200 });
    Object.defineProperty(extras, "offsetHeight", { configurable: true, get: () => 60 });
    Object.defineProperty(scroller, "clientHeight", { configurable: true, get: () => 400 });
    scroller.scrollTop = 190;
    await answer(card);
    assert.equal(scroller.scrollTop, 190);
  } finally {
    view.reset();
  }
});

// A blocking approval too tall for the stage's view gets a raised cap (it
// opens at its question and command).
const APPROVAL_CARD = ["bubble question approval", { kind: "approval" }];

test("an approval too tall for the stage raises the cap; one that fits doesn't", async (t) => {
  const tall = await askPage(t, { overflow: false, cards: [APPROVAL_CARD], cardHeight: 700 });
  try {
    assert.equal(capOf(tall.view), "850px");
  } finally {
    tall.view.reset();
  }
  const short = await askPage(t, { overflow: false, cards: [APPROVAL_CARD], cardHeight: 300 });
  try {
    assert.equal(capOf(short.view), "600px");
  } finally {
    short.view.reset();
  }
});

test("a delegate's relayed approval too tall for the stage raises the cap too; a relayed hook question doesn't", async (t) => {
  const relayed = await askPage(t, { overflow: false, cards: [["bubble question approval", { kind: "approval", relay: "1" }]], cardHeight: 700 });
  try {
    assert.equal(capOf(relayed.view), "850px");
  } finally {
    relayed.view.reset();
  }
  const hook = await askPage(t, { overflow: false, cards: [["bubble question", { kind: "hook", relay: "1" }]], cardHeight: 700 });
  try {
    assert.equal(capOf(hook.view), "600px");
  } finally {
    hook.view.reset();
  }
});

test("an approval's raised cap holds at the tap and comes down once at the next step", async (t) => {
  const { view, card } = await askPage(t, { overflow: false, cards: [APPROVAL_CARD], cardHeight: 700 });
  try {
    await answer(card);
    assert.equal(capOf(view), "850px");
    view.generationStarted({ iteration: 2 });
    assert.equal(capOf(view), "600px");
  } finally {
    view.reset();
  }
});

// After a blocking card's answer the frame holds until the next step (nothing
// moves at the tap), and the next step lets go of it once: the waiting height,
// the tallest content seen, a raised cap. Later steps are grow-only again.
function frameLaidOut(view, { natural }) {
  const content = { value: natural };
  for (const [sel, props] of [[".ts-prompt", { offsetTop: 0, offsetHeight: 0 }]]) {
    for (const [k, v] of Object.entries(props)) Object.defineProperty($(view, sel), k, { configurable: true, get: () => v });
  }
  const extras = $(view, ".ts-extras");
  Object.defineProperty(extras, "getClientRects", { configurable: true, value: () => [{}] });
  Object.defineProperty(extras, "offsetTop", { configurable: true, get: () => 0 });
  Object.defineProperty(extras, "offsetHeight", { configurable: true, get: () => content.value });
  return content;
}
const heightOf = (view) => parseFloat(view.root.style.height);

test("the next step after an answered card shrinks the frame; the tap doesn't, and a later step doesn't", async (t) => {
  const { view, card } = await askPage(t, { overflow: false, cards: [APPROVAL_CARD] });
  try {
    const content = frameLaidOut(view, { natural: 500 });
    await refit(view);
    const tall = heightOf(view);
    assert.ok(tall >= 500, `held ${tall}`);
    content.value = 60;
    await answer(card);
    await refit(view);
    assert.equal(heightOf(view), tall, "the tap: grow-only, nothing moves");
    assert.equal(view.root.classList.contains("held-wait"), true);
    view.generationStarted({ iteration: 2 });
    const shrunk = heightOf(view);
    assert.ok(shrunk < tall, `the next step: ${tall} to ${shrunk}`);
    assert.equal(view.root.classList.contains("held-wait"), false);
    // Grow-only again: growth stays, a later step lets nothing go.
    content.value = 300;
    await refit(view);
    const grown = heightOf(view);
    assert.ok(grown > shrunk);
    content.value = 60;
    view.generationStarted({ iteration: 3 });
    await refit(view);
    assert.equal(heightOf(view), grown, "only once: a second generationStarted holds");
  } finally {
    view.reset();
  }
});

test("a next step with no answered card before it keeps the frame", async (t) => {
  const { view } = page({ taskStop: fakeTaskStop });
  sizePage(t);
  try {
    view.turnStarted({});
    view.generationStarted({ iteration: 1 });
    await frame();
    const content = frameLaidOut(view, { natural: 400 });
    await refit(view);
    const tall = heightOf(view);
    content.value = 40;
    view.generationStarted({ iteration: 2 });
    await refit(view);
    assert.equal(heightOf(view), tall);
  } finally {
    view.reset();
  }
});

test("a card still waiting at a generation keeps the held state", async (t) => {
  const { view } = await askPage(t, { overflow: false, cards: [APPROVAL_CARD] });
  try {
    view.generationStarted({ iteration: 2 });
    assert.equal(view.root.classList.contains("held-wait"), true);
  } finally {
    view.reset();
  }
});

// The quiet signal (stage_stall.js) as the stage drives it: the page's clock
// ticks (app.js's live timing), the turn's events are what count as alive.
function quietPage({ live = () => true } = {}) {
  let t = Date.now();
  const p = page({ clock: () => t, streamLive: live });
  return { ...p, at: (ms) => { t = ms; }, now: () => t };
}

test("quiet: a turn silent for 31 s says so in the now row; its next chunk clears it at once", () => {
  const { view, at, now } = quietPage();
  const start = now();
  view.turnStarted({ promptBubble: document.createElement("div") });
  view.generationStarted({ iteration: 1 });
  view.chunk({ iteration: 1, text: "Looking at it." });
  view.flush();
  view.tick(start + 31000);
  const stage = view.root;
  assert.equal(stage.querySelector(".ts-now .ts-stall .long")?.textContent, "quiet 0:31 · no new events");
  assert.equal(stage.querySelector(".ts-stall-head").textContent, "quiet 0:31");
  assert.equal(stage.dataset.stall, "1");
  at(start + 31500);
  view.chunk({ iteration: 1, text: " More." });
  assert.ok(stage.querySelector(".ts-stall") === null);
  assert.equal(stage.dataset.stall, undefined);
  view.tick(start + 32000);
  assert.ok(stage.querySelector(".ts-stall") === null);
  view.reset();
});

test("quiet: before the first token it waits 45 s and reads thinking quietly", () => {
  const { view, now } = quietPage();
  const start = now();
  view.turnStarted({ promptBubble: document.createElement("div") });
  view.generationStarted({ iteration: 1 }, start);
  view.tick(start + 40000);
  assert.ok(view.root.querySelector(".ts-stall") === null);
  view.tick(start + 50000);
  assert.equal(view.root.querySelector(".ts-stall .short")?.textContent, "thinking quietly 0:50");
  view.reset();
});

test("quiet: a running tool shows its own clock, never the stall, however long it runs", () => {
  const { view } = quietPage();
  view.turnStarted({ promptBubble: document.createElement("div") });
  view.generationStarted({ iteration: 1 });
  // The call's start is the turn block's own Date.now().
  view.toolStarted({ iteration: 1, call_index: 1, tool: "execute", params: 'command="sleep 200"', title: "sleep 200" });
  const started = Date.now();
  view.flush();
  view.tick(started + 120000);
  const stage = view.root;
  assert.ok(stage.querySelector(".ts-stall") === null);
  assert.ok(!stage.classList.contains("stalled"));
  assert.match(stage.querySelector(".ts-now .ts-tool-clock")?.textContent || "", /^2:0\d$/);
  view.reset();
});

test("quiet: a stream that is not live reads reconnecting (after a second), whatever the silence", () => {
  let live = true;
  const { view, now } = quietPage({ live: () => live });
  const start = now();
  view.turnStarted({ promptBubble: document.createElement("div") });
  view.generationStarted({ iteration: 1 });
  live = false;
  view.tick(start + 2000);
  assert.ok(view.root.querySelector(".ts-stall") === null);
  view.tick(start + 3000);
  assert.equal(view.root.querySelector(".ts-stall .short")?.textContent, "reconnecting…");
  assert.equal(view.root.dataset.stall, "net");
  view.reset();
});

test("quiet: a tick under the threshold writes nothing to the stage", () => {
  const { view, now } = quietPage();
  const start = now();
  view.turnStarted({ promptBubble: document.createElement("div") });
  view.generationStarted({ iteration: 1 });
  view.chunk({ iteration: 1, text: "Looking at it." });
  view.flush();
  view.tick(start + 1000);
  const observer = new MutationObserver(() => {});
  observer.observe(view.root, { subtree: true, childList: true, attributes: true, characterData: true });
  view.tick(start + 5000);
  view.tick(start + 29000);
  assert.equal(observer.takeRecords().length, 0);
  observer.disconnect();
  view.reset();
});

test("quiet: a new turn and the turn's end clear it", () => {
  const { view, at, now } = quietPage();
  const start = now();
  view.turnStarted({ promptBubble: document.createElement("div") });
  view.generationStarted({ iteration: 1 });
  view.chunk({ iteration: 1, text: "Looking at it." });
  view.tick(start + 40000);
  assert.ok(view.root.classList.contains("stalled"));
  at(start + 40000);
  view.turnStarted({ promptBubble: document.createElement("div") });
  assert.ok(!view.root.classList.contains("stalled"));
  view.tick(start + 60000);
  assert.ok(!view.root.classList.contains("stalled"));
  view.tick(start + 90000);
  assert.ok(view.root.classList.contains("stalled"));
  view.turnEnded({ kind: "canceled" });
  assert.ok(!view.root.classList.contains("stalled"));
  view.reset();
});

// ── a turn opened in the history (stage_opened.js) ───────────────────────

const kinds = (el) => [...el.children].map((c) => [...c.classList].slice(0, 2).join(" "));
function questionCard({ qid = "q1", kind = "question", relay = false, cls = "bubble question" } = {}) {
  const card = document.createElement("details");
  card.className = cls;
  card.dataset.qid = qid;
  card.dataset.kind = kind;
  if (relay) card.dataset.relay = "1";
  card.open = true;
  const summary = document.createElement("summary");
  summary.textContent = "Question";
  card.append(summary, document.createElement("button"));
  return card;
}
function row(cls, text = "") {
  const el = document.createElement("div");
  el.className = cls;
  el.textContent = text;
  return el;
}
// A turn whose step +it+ replied +text+ and called ask_user_question.
function asks(view, { it = 1, text = "Both files matter. Which first?" } = {}) {
  view.generationStarted({ iteration: it });
  if (text) view.chunk({ iteration: it, text });
  view.toolStarted({ iteration: it, call_index: 1, tool: "ask_user_question", params: "q" });
}
function openedPage(opts = {}) {
  const p = page({ taskStop: fakeTaskStop, ...opts });
  const prompt = row("bubble user");
  prompt.dataset.turnId = "t1";
  p.view.turnStarted({ promptBubble: prompt });
  return { ...p, prompt };
}
async function resolve(card, cls = "answered") {
  card.classList.add(cls);
  card.querySelector(":scope > button")?.remove();
  card.querySelector(":scope > summary").textContent = "Question → README.md";
  await tick();
}

test("opened: the model's question after a reply opens the turn in the history; the reason is a bubble there, the card stays in the stage", async () => {
  const { view, historyEl, append, prompt } = openedPage();
  try {
    // A note that arrived before the question goes with the turn, in order.
    append(row("bubble note", "a note"));
    asks(view);
    const card = questionCard();
    append(card);
    assert.deepEqual(kinds(historyEl), ["bubble user", "turn-work", "bubble note", "bubble said"]);
    assert.ok(historyEl.firstElementChild === prompt);
    const block = historyEl.querySelector(".turn-work");
    assert.equal(block.open, false);
    const said = historyEl.querySelector(".bubble.said");
    assert.ok(said.classList.contains("pending"));
    assert.equal(said.dataset.questionId, "q1");
    assert.equal(said.dataset.saidTurn, "t1");
    assert.equal(said.dataset.turnId, undefined, "never a turn's opening");
    assert.equal(said.querySelector(".said-label").textContent, "chi · step 1asking you");
    assert.equal(said.querySelector(".said-text").textContent, "Both files matter. Which first?");
    assert.ok(card.parentElement === $(view, ".ts-extras"));
    assert.ok(view.root.classList.contains("asking-form"));
    assert.equal(view.root.dataset.block, "history");
    assert.equal(card.querySelector("summary .question-reason-link").textContent, "↑ its reason");
  } finally {
    view.reset();
  }
});

test("opened: an approval, a hook's or a relayed question, a question with no reply before it keep today's stage", async () => {
  for (const [card, text] of [
    [questionCard({ kind: "approval", cls: "bubble question approval" }), "Running it."],
    [questionCard({ kind: "hook" }), "Hm."],
    [questionCard({ relay: true }), "Hm."],
    [questionCard(), ""],
  ]) {
    const { view, historyEl, append } = openedPage();
    try {
      asks(view, { text });
      append(card);
      assert.deepEqual(kinds(historyEl), [], `${card.dataset.kind} ${text}`);
      assert.ok(!view.root.classList.contains("asking-form"));
      assert.equal(view.root.dataset.block, undefined);
    } finally {
      view.reset();
    }
  }
});

test("opened: rows go to the history's end, a warning and an asking card stay; the answer moves the card under its reason and the working form comes back", async () => {
  const { view, historyEl, append } = openedPage();
  try {
    asks(view);
    const card = questionCard();
    append(card);
    const warn = row("plugin-card warn");
    const nudge = row("plugin-card");
    nudge.dataset.inTurn = "1";
    nudge.appendChild(row("card-action"));
    append(warn);
    append(nudge);
    await resolve(card);
    assert.deepEqual(kinds(historyEl), ["bubble user", "turn-work", "bubble said", "bubble question"]);
    assert.ok(!historyEl.querySelector(".bubble.said").classList.contains("pending"));
    assert.ok(!view.root.classList.contains("asking-form"));
    assert.deepEqual(kinds($(view, ".ts-extras")), ["plugin-card warn", "plugin-card"]);
    append(row("bubble note", "later"));
    assert.equal(historyEl.lastElementChild.className, "bubble note");
  } finally {
    view.reset();
  }
});

test("opened: the turn's steps stay in order in the history from the opening on", async () => {
  const { view, historyEl, append } = openedPage();
  try {
    asks(view);
    const card = questionCard();
    append(card);
    await resolve(card);
    view.generationStarted({ iteration: 2 });
    view.chunk({ iteration: 2, text: "Reading it." });
    view.toolStarted({ iteration: 2, call_index: 1, tool: "read", params: "README.md" });
    view.flush();
    const steps = [...historyEl.querySelectorAll(".turn-work > details.gen")].map((g) => g.textContent);
    assert.equal(steps.length, 2);
    assert.match(steps[0], /^Both files matter/);
    assert.match(steps[1], /^step 2.*README\.md/);
    // Its block is the history's: no re-host into the stage's cloud.
    await frame();
    assert.ok(historyEl.querySelector(".turn-work").parentElement === historyEl);
    assert.equal($(view, ".ts-cloud-body").children.length, 0);
    assert.equal($(view, ".ts-foot").hidden, false, "the chip shows the block in the history");
  } finally {
    view.reset();
  }
});

test("opened: ask, answer, end: the hand-off leaves the turn in the finished turn's order with no reason bubble; the reload check gets the whole turn", async () => {
  const handed = [];
  const { view, historyEl, append, prompt } = openedPage({ onHandedOff: (h) => handed.push(h) });
  try {
    asks(view);
    const card = questionCard();
    append(card);
    await resolve(card);
    view.generationStarted({ iteration: 2 });
    view.chunk({ iteration: 2, text: "Done." });
    view.generationCompleted();
    view.turnEnded({ kind: "completed", turnId: "t1" });
    view.answerReady();
    view.handOff({ immediate: true });
    assert.deepEqual(kinds(historyEl), ["bubble user", "turn-work done", "bubble question", "bubble output"]);
    assert.ok(historyEl.querySelector(".bubble.said") === null);
    assert.equal(handed.length, 1);
    assert.ok(handed[0].pieces[0] === prompt, "the whole turn, from its prompt");
    assert.deepEqual(handed[0].pieces.map((el) => el.className.split(" ").slice(0, 2).join(" ")), ["bubble user", "turn-work done", "bubble question", "bubble output"]);
  } finally {
    view.reset();
  }
});

test("opened: Stop turn while the card waits: the reason stays, the cancelled card under it, the end after", async () => {
  const { view, historyEl, append } = openedPage();
  try {
    asks(view);
    const card = questionCard();
    append(card);
    view.turnEnded({ kind: "canceled" });
    await resolve(card, "cancelled");
    append(row("bubble end", "canceled"));
    view.handOff({ immediate: true });
    const order = kinds(historyEl);
    assert.deepEqual(order.slice(0, 3), ["bubble user", "turn-work done", "bubble question"]);
    assert.equal(order.at(-1), "bubble end");
  } finally {
    view.reset();
  }
});

test("opened, released without its end (the next turn started): its reasons go, what it moved stays", async () => {
  const { view, historyEl, append } = openedPage();
  try {
    asks(view);
    append(questionCard());
    assert.equal(historyEl.querySelectorAll(".bubble.said").length, 1);
    const next = row("bubble user");
    next.dataset.turnId = "t2";
    view.turnStarted({ promptBubble: next });
    assert.ok(historyEl.querySelector(".bubble.said") === null);
    assert.deepEqual(kinds(historyEl), ["bubble user", "turn-work"]);
    assert.ok(!view.root.classList.contains("asking-form"));
  } finally {
    view.reset();
  }
});

test("opened: a late recap goes above the opened turn, not inside it", async () => {
  const { view, historyEl, append, prompt } = openedPage();
  try {
    asks(view);
    append(questionCard());
    const recap = row("bubble recap", "earlier: …");
    append(recap);
    assert.ok(recap.nextElementSibling === prompt);
    assert.deepEqual(kinds(historyEl), ["bubble recap", "bubble user", "turn-work", "bubble said"]);
  } finally {
    view.reset();
  }
});

test("opened: the reason's link moves nothing once the reason is gone", async () => {
  const { view, historyEl, append } = openedPage();
  try {
    asks(view);
    const card = questionCard();
    append(card);
    historyEl.querySelector(".bubble.said").remove();
    historyEl.scrollTop = 0;
    card.querySelector(".question-reason-link").click();
    await frame();
    await frame();
    assert.equal(historyEl.scrollTop, 0);
  } finally {
    view.reset();
  }
});

test("the reload check gets a wake's turn from its note (no prompt), opened or not; a note mid-turn doesn't cut it", async () => {
  for (const ask of [false, true]) {
    const handed = [];
    const { view, historyEl, append } = page({ taskStop: fakeTaskStop, onHandedOff: (h) => handed.push(h) });
    try {
      const wake = row("bubble note", "a task finished");
      wake.dataset.openingId = "w1";
      historyEl.appendChild(wake);
      view.turnStarted({});
      if (ask) {
        asks(view);
        const card = questionCard();
        append(card);
        append(row("bubble note", "mid-turn note"));
        await resolve(card);
      }
      view.generationStarted({ iteration: 2 });
      view.toolStarted({ iteration: 2, call_index: 1, tool: "read", params: "x" });
      view.toolCompleted({ iteration: 2, call_index: 1, status: "ok" });
      view.generationStarted({ iteration: 3 });
      view.chunk({ iteration: 3, text: "Done." });
      view.generationCompleted();
      view.turnEnded({ kind: "completed", turnId: "t9" });
      view.answerReady();
      view.handOff({ immediate: true });
      assert.ok(handed[0].pieces[0] === wake, `opened: ${ask}`);
      assert.ok(handed[0].pieces.at(-1).matches(".bubble.output"), `opened: ${ask}`);
    } finally {
      view.reset();
    }
  }
});

test("opened: the asking step's own text is hidden in the block while its reason shows; the hand-off shows it again", async () => {
  const { view, historyEl, append } = openedPage();
  try {
    asks(view);
    const card = questionCard();
    append(card);
    const steps = () => [...historyEl.querySelectorAll(".turn-work > details.gen")];
    assert.equal(steps().length, 1);
    assert.equal(steps()[0].dataset.said, "1");
    await resolve(card);
    view.generationStarted({ iteration: 2 });
    view.chunk({ iteration: 2, text: "Done." });
    view.flush();
    assert.equal(steps()[0].dataset.said, "1", "kept by a redraw of the step and the next step");
    assert.equal(steps()[1].dataset.said, undefined);
    view.generationCompleted();
    view.turnEnded({ kind: "completed", turnId: "t1" });
    view.answerReady();
    view.handOff({ immediate: true });
    assert.ok(historyEl.querySelector("details.gen[data-said]") === null);
  } finally {
    view.reset();
  }
});

test("opened: two questions in one turn: two reasons, each card under its own", async () => {
  const { view, historyEl, append } = openedPage();
  try {
    asks(view, { text: "First, the readme." });
    const one = questionCard({ qid: "q1" });
    append(one);
    await resolve(one);
    view.toolCompleted({ iteration: 1, call_index: 1, status: "ok" });
    asks(view, { it: 2, text: "Then the gems." });
    const two = questionCard({ qid: "q2" });
    append(two);
    assert.deepEqual(kinds(historyEl), ["bubble user", "turn-work", "bubble said", "bubble question", "bubble said"]);
    assert.equal(historyEl.querySelectorAll(".bubble.said")[1].querySelector(".said-label span").textContent, "chi · step 2");
    await resolve(two);
    assert.deepEqual(kinds(historyEl), ["bubble user", "turn-work", "bubble said", "bubble question", "bubble said", "bubble question"]);
    assert.ok(historyEl.lastElementChild === two);
  } finally {
    view.reset();
  }
});

test("opened, replayed (a reload, a resync): the asking call completed before its question comes, the turn opens all the same; its answer and the next step in one task let the held frame go", async () => {
  const { view, historyEl, append } = openedPage();
  try {
    view.generationStarted({ iteration: 1 });
    view.chunk({ iteration: 1, text: "Both files matter. Which first?" });
    view.generationCompleted();
    view.toolStarted({ iteration: 1, call_index: 1, tool: "ask_user_question", params: "q" });
    view.toolCompleted({ iteration: 1, call_index: 1, status: "ok" });
    assert.equal(view.askingText(), "Both files matter. Which first?", "the answered card keeps it");
    const card = questionCard();
    append(card);
    assert.deepEqual(kinds(historyEl), ["bubble user", "turn-work", "bubble said"]);
    assert.ok(view.root.classList.contains("held-wait"));
    card.classList.add("answered");
    card.querySelector(":scope > button").remove();
    view.generationStarted({ iteration: 2 });
    assert.ok(!view.root.classList.contains("held-wait"));
    await tick();
    assert.deepEqual(kinds(historyEl), ["bubble user", "turn-work", "bubble said", "bubble question"]);
  } finally {
    view.reset();
  }
});

test("opened: a step whose last call isn't the question doesn't open the turn after it completed", async () => {
  const { view, historyEl, append } = openedPage();
  try {
    view.generationStarted({ iteration: 1 });
    view.chunk({ iteration: 1, text: "Reading first." });
    view.toolStarted({ iteration: 1, call_index: 1, tool: "read", params: "README.md" });
    view.toolCompleted({ iteration: 1, call_index: 1, status: "ok" });
    append(questionCard());
    assert.deepEqual(kinds(historyEl), []);
  } finally {
    view.reset();
  }
});

test("replayed: a later question card of the same step doesn't take the reply a card already took", async () => {
  const { view, historyEl, append } = openedPage();
  try {
    view.generationStarted({ iteration: 1 });
    view.chunk({ iteration: 1, text: "Both files matter. Which first?" });
    view.toolStarted({ iteration: 1, call_index: 1, tool: "ask_user_question", params: "q" });
    view.toolCompleted({ iteration: 1, call_index: 1, status: "ok" });
    const one = questionCard({ qid: "q1" });
    append(one);
    await resolve(one);
    assert.equal(view.askingText(), "", "taken");
    append(questionCard({ qid: "q2" }));
    assert.equal(historyEl.querySelectorAll(".bubble.said").length, 1);
  } finally {
    view.reset();
  }
});
