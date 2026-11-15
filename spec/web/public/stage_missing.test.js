// A running session whose stage shows nothing of its turn (stage_missing.js):
// the bare status row, the `data-stage-missing` mark and the one console line
// per visit. The leads the plan named, drawn through the real stage, the real
// stream handlers and the real session view (live_page.js), with the read the
// page got built by hand.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { livePage, clearSession } from "./live_page.js";
import { createSessionView } from "../../../lib/samagotchi/web/public/session_view.js";
import { createGapClock } from "../../../lib/samagotchi/web/public/time_gaps.js";
import { createStageMissing, missingReason, readCounts, stageCovered } from "../../../lib/samagotchi/web/public/stage_missing.js";

const settle = async () => {
  for (let i = 0; i < 3; i += 1) await new Promise((resolve) => setTimeout(resolve, 20));
};
// The hand-off's fold (stage_handoff.js FOLD_MS) and its clearStage hook.
const folded = () => new Promise((resolve) => setTimeout(resolve, 600));

// A show as chi web sends it: the session's status, the turn in progress, the
// join's replay, and what the snapshot read gave (live_read).
function show({ status = "running", liveRead = "ok", currentTurn = null, replay = [], messages = [] } = {}) {
  return {
    session: { id: "s1", status, model_name: "m", working_directory: "/work" },
    messages, current_turn: currentTurn, live_read: liveRead, replay,
    cards: [], queued: [], queued_commands: [], recap: null,
    timing: { turn_records: [], tool_records: [], active_turn: currentTurn ? { id: currentTurn.turn_id, started_at: "2026-11-15T12:00:00.000Z" } : null },
  };
}

// The page as app.js wires it: the live stage and handlers, the session view
// over them, and stage_missing.js hung on the stage's hooks and the store.
function pageFor(win = { innerHeight: 800 }) {
  clearSession();
  const warnings = [];
  let missingRef = null;
  const page = livePage({ questions: true, onStageCleared: () => missingRef?.check() });
  missingRef = createStageMissing({
    store: page.store, turnDom: page.turnDom, composerEl: document.getElementById("composer"), win,
    warn: (line) => warnings.push(line),
  });
  page.store.on("infoBar", missingRef.checkOnStatus);
  const view = createSessionView({
    store: page.store, historyEl: page.historyEl, getSession: async () => show(),
    liveTurn: page.liveTurn, turnDom: page.turnDom, questionCards: page.questionCards,
    shownTexts: page.shownTexts, objectives: { reset() {}, seed() {} }, featureGates: { prime() {} },
    markdownTip: { show() {} }, gapClock: createGapClock(), bubbles: page.bubbles, cards: page.cards,
    markdown: { linkTextRefs() {}, applyFinalMarkdown() {} }, capabilities: () => ({}),
    page: {
      setReviseAnchor() {}, renderInitRow() {}, setMarkdownWarning() {}, setCapabilities() {},
      findInTurnRoots: (sel) => [...page.historyEl.querySelectorAll(sel), ...page.turnDom.root.querySelectorAll(sel)],
      appendToHistory: (el) => page.historyEl.appendChild(el),
      setTurnRunning: (on) => { page.liveTurn.running = !!on; page.turnDom.runningWithoutTurn?.(!on); },
      mergeTurnTiming: () => true, applySessionPayload() {}, turnEndStatus() {}, replaceSelectedCard() {},
    },
    later: {
      handlers: () => page.handlers, composer: () => ({ newVisit() {}, decideVisit: () => false }),
      ownerVerify: () => ({ renderSaved() {}, clear() {} }), commandList: () => ({ close() {} }),
      initTasks: () => new Map(), resetTurnView: () => page.turnDom.reset(),
    },
    cardRegistry: page.cardRegistry, stageMissing: missingRef,
  });
  page.store.update({ selected: "s1" });
  return { ...page, missing: missingRef, view, warnings };
}

const stage = (page) => page.turnDom.root;
const marked = (page) => stage(page).dataset.stageMissing;
const bare = (page) => stage(page).classList.contains("bare");

test("a running read with a turn and its replay draws the turn: no mark, no warning", async () => {
  const page = pageFor();
  page.view.renderSessionView(show({
    currentTurn: { turn_id: "t1", prompt: "do it", status: "running" },
    replay: [{ type: "turn_started", turn_id: "t1", prompt: "do it", started_at: "2026-11-15T12:00:00.000Z" }],
  }));
  await settle();
  assert.ok(page.turnDom.holds(), "the stage holds the running turn");
  assert.ok(!stage(page).hidden, "the stage shows");
  assert.equal(marked(page), undefined);
  assert.deepEqual(page.warnings, []);
});

test("current_turn with no turn_started in the replay: the bare stage and the line", async () => {
  const page = pageFor();
  page.view.renderSessionView(show({
    liveRead: "ok",
    currentTurn: { turn_id: "t1", prompt: "do it", status: "running" },
    replay: [],
  }));
  await settle();
  assert.ok(!page.turnDom.holds(), "nothing was drawn");
  assert.equal(marked(page), "1");
  assert.ok(bare(page), "the stage keeps its status row rather than vanishing");
  assert.equal(page.warnings.length, 1, "one line per visit");
  assert.match(page.warnings[0], /stage-missing s1 \(none\) live_read=ok current_turn=t1 replay=0 events=none/);
});

test("a failed snapshot read of a running session: the bare stage and the line", async () => {
  const page = pageFor();
  page.view.renderSessionView(show({ liveRead: "failed", currentTurn: null, replay: [] }));
  await settle();
  assert.equal(marked(page), "1");
  assert.ok(bare(page), "Stop turn stays in reach");
  assert.match(page.warnings[0], /live_read=failed current_turn=none replay=0 events=none last_end=none/);
});

test("a replay that carries the turn's end while the status says running: bare after the hand-off", async () => {
  const page = pageFor();
  page.view.renderSessionView(show({
    currentTurn: { turn_id: "t1", prompt: "do it", status: "running" },
    replay: [
      { type: "turn_started", turn_id: "t1", prompt: "do it", started_at: "2026-11-15T12:00:00.000Z" },
      { type: "turn_completed", turn_id: "t1" },
    ],
  }));
  // The quiet watch hands it off; the fold's end is where the stage clears.
  page.turnDom.handOff();
  await folded();
  assert.ok(!page.turnDom.holds(), "the turn left the stage");
  assert.equal(marked(page), "1");
  assert.ok(bare(page), "the stage is not gone: its status row is there");
  assert.match(page.warnings[0], /replay=2 events=turn_started=1 turn_completed=1 last_end=t1 vs turn=t1/);
});

test("only an earlier turn's end in the replay: the bare stage at once", async () => {
  const page = pageFor();
  page.view.renderSessionView(show({
    currentTurn: { turn_id: "t2", prompt: "next", status: "running" },
    replay: [{ type: "turn_completed", turn_id: "t1" }],
  }));
  await settle();
  assert.equal(marked(page), "1");
  assert.ok(bare(page), "the stage shows the running session at once");
  assert.match(page.warnings[0], /last_end=t1 vs turn=t2/);
});



test("a stage the composer covers: marked covered, and nothing else", async () => {
  const page = pageFor({ innerHeight: 800 });
  page.view.renderSessionView(show({
    currentTurn: { turn_id: "t1", prompt: "do it", status: "running" },
    replay: [{ type: "turn_started", turn_id: "t1", prompt: "do it", started_at: "2026-11-15T12:00:00.000Z" }],
  }));
  await settle();
  assert.equal(marked(page), undefined);
  const row = stage(page).querySelector(".ts-status");
  row.getBoundingClientRect = () => ({ top: 910, bottom: 940, left: 0, right: 400 });
  document.getElementById("composer").getBoundingClientRect = () => ({ top: 700, bottom: 780, left: 0, right: 400 });
  assert.equal(page.missing.check(), "covered");
  assert.equal(marked(page), "covered");
  assert.ok(page.turnDom.holds(), "the turn is still on the stage: only its place is wrong");
  assert.match(page.warnings[0], /stage-missing s1 \(covered\).*stage_row=910\.\.940 composer_top=700 window=800/);
});

test("the status turning idle without setTurnRunning: the bare row goes", async () => {
  const page = pageFor();
  page.view.renderSessionView(show({ liveRead: "failed", currentTurn: null, replay: [] }));
  await settle();
  assert.equal(marked(page), "1");
  assert.ok(bare(page), "the net put the row there");
  // turnEndStatus and the hub write the status without the turn's own path.
  page.store.setStatus("idle", "turnEnd", { running: false });
  await settle();
  assert.equal(marked(page), undefined);
  assert.ok(!bare(page), "no row left behind");
  assert.ok(stage(page).hidden, "the stage is empty again");
});

test("the pure rule: running with no turn, a covered stage, a stopped session", () => {
  assert.equal(missingReason({ status: "running", holds: false, hidden: true, stageTop: 0, stageBottom: 0, composerTop: 500, viewport: 800 }), "none");
  assert.equal(missingReason({ status: "running", holds: true, hidden: false, stageTop: 910, stageBottom: 940, composerTop: 700, viewport: 800 }), "covered");
  assert.equal(missingReason({ status: "running", holds: true, hidden: false, stageTop: -100, stageBottom: -20, composerTop: null, viewport: 800 }), "covered");
  assert.equal(missingReason({ status: "running", holds: true, hidden: false, stageTop: 200, stageBottom: 300, composerTop: 400, viewport: 800 }), null);
  assert.equal(missingReason({ status: "idle", holds: false, hidden: true, stageTop: 0, stageBottom: 0, composerTop: null, viewport: 800 }), null);
  // A folded composer (composer.css: #composer display:none) shows no top.
  assert.equal(stageCovered({ hidden: false, stageTop: 200, stageBottom: 300, composerTop: null, viewport: 800 }), false);
  const counts = readCounts({ live_read: "failed", replay: [{ type: "turn_completed", turn_id: "t1" }, { type: "turn_completed", turn_id: "t2" }] });
  assert.deepEqual(counts, { liveRead: "failed", currentTurn: null, replay: 2, events: { turn_completed: 2 }, lastEndTurn: "t2" });
});

test("switching A to B and back while A's turn is folding: A's turn is on the stage again", async () => {
  const page = pageFor();
  const a = show({ currentTurn: { turn_id: "a1", prompt: "A's turn", status: "running" }, replay: [{ type: "turn_started", turn_id: "a1", prompt: "A's turn", started_at: "2026-11-15T12:00:00.000Z" }] });
  const b = show({ currentTurn: { turn_id: "b1", prompt: "B's turn", status: "running" }, replay: [{ type: "turn_started", turn_id: "b1", prompt: "B's turn", started_at: "2026-11-15T12:01:00.000Z" }] });
  page.view.renderSessionView(a);
  await settle();
  assert.ok(page.turnDom.holds(), "A's turn is on the stage");
  // A's turn ends and starts sliding into the history; the switch happens mid-fold.
  page.turnDom.turnEnded({ kind: "completed", endNote: null, emptyAnswer: false, turnId: "a1" });
  page.turnDom.handOff();
  page.view.forgetSession();
  page.view.renderSessionView(b);
  await settle();
  assert.ok(page.turnDom.holds(), "B's turn is on the stage");
  assert.equal(marked(page), undefined, "no mark on a stage that shows its turn");
  page.view.forgetSession();
  page.view.renderSessionView(a);
  await settle();
  assert.ok(page.turnDom.holds(), "A's turn came back from the read");
  assert.equal(marked(page), undefined);
  assert.equal(page.warnings.length, 0, "nothing was missing at any point");
});
