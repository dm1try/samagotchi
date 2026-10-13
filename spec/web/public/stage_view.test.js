// The stage view's hand-off timing (stage_view.js), in happy-dom: what
// arrives while the finished turn slides away goes after it.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";

for (const k of ["MutationObserver", "CustomEvent", "localStorage", "getSelection"]) {
  if (!(k in globalThis)) globalThis[k] = window[k];
}
globalThis.ResizeObserver ??= class { observe() {} disconnect() {} };
globalThis.matchMedia ??= () => ({ matches: false });
if (!window.HTMLElement.prototype.animate) window.HTMLElement.prototype.animate = () => ({ finished: Promise.resolve(), cancel() {}, playState: "finished" });

const { createStageView } = await import("../../../lib/samagotchi/web/public/stage_view.js");

function page() {
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
