// The live-vs-reload harness, cards included (audit r20, direction B): for
// each turn with a card that waits (spec/shared/stage_cuts/*.json, written by
// spec/web/session_show_cuts_spec.rb through Web::SessionShow) and each of
// its cuts, the page that lived through the events to that cut and the page
// that reloads there (the cut's show, drawn as session_view.js
// renderSessionView draws a read) read the same: the stage (stageShape:
// what waits in it, docked, the lead-in bubbles, the card in front, the
// fold, the asking slot) and the history (history_shape.js). Today's known
// differences are listed in EXPECTED, each by its scenario, cut and field:
// a difference not listed fails, and so does one listed that is gone (the
// build that removes it flips it here). On both pages the stage's waiting
// cards as data (stage_waiting.js) agree with the slots (the DOM read is a
// cross-check here only).
import test from "node:test";
import assert from "node:assert/strict";
import { failOnWaitingWarnings } from "./waiting_warnings.js";

failOnWaitingWarnings();
import { readdirSync, readFileSync } from "node:fs";

const { livePage, clearSession } = await import("./live_page.js");
const { compareShapes, historyShape } = await import("../../../lib/samagotchi/web/public/history_shape.js");
const { turnHistoryNodes } = await import("../../../lib/samagotchi/web/public/turn_block.js");
const { splitSnapshotCards } = await import("../../../lib/samagotchi/web/public/card.js");
const { waitingKey, waitingKind } = await import("../../../lib/samagotchi/web/public/stage_waiting.js");

const DIR = new URL("../../shared/stage_cuts/", import.meta.url);
const scenarios = readdirSync(DIR).filter((f) => f.endsWith(".json")).sort()
  .map((f) => ({ name: f.replace(/\.json$/, ""), ...JSON.parse(readFileSync(new URL(f, DIR), "utf8")) }));

// The page settles: the stage's refresh (a microtask, a frame) and the
// cards' own redraws.
const settle = async () => {
  for (let i = 0; i < 3; i += 1) await new Promise((resolve) => setTimeout(resolve, 20));
};

// What the stage shows, read off the DOM: the cards in its slots (key,
// kind, slot), the docked ones (the asking form's cards: what waits for
// the user in the extras, not a warning), the lead-in bubbles in the
// history (their question id, still asking or not), the card in front, the
// docked card that shows (one at a time) and the pager's words, the fold,
// check-in's row (asks-live, the phase word, the mini row) and the text
// streamed under it, where the turn's prompt and block are.
export function stageShape(stageEl, historyEl, waiting) {
  const cards = [];
  for (const slot of ["ts-extras", "ts-tail"]) {
    for (const el of stageEl.querySelector(`.${slot}`)?.children || []) {
      const kind = waitingKind(el);
      if (kind) cards.push({ key: waitingKey(el), kind, slot, behind: el.classList.contains("ts-behind") });
    }
  }
  const askingForm = stageEl.classList.contains("asking-form");
  return {
    shown: !stageEl.hidden,
    cards,
    docked: askingForm ? cards.filter((c) => c.slot === "ts-extras" && c.kind !== "warn").map((c) => c.key) : [],
    leadIns: [...historyEl.querySelectorAll(":scope > .bubble.said")].map((el) => ({ question: el.dataset.questionId ?? null, asking: el.classList.contains("pending") })),
    front: waiting.front(),
    showing: askingForm ? cards.filter((c) => c.slot === "ts-extras" && c.kind !== "warn" && !c.behind).map((c) => c.key) : [],
    pager: stageEl.querySelector(".ts-pager:not([hidden]) .ts-page-label")?.textContent || "",
    folded: stageEl.classList.contains("collapsed"),
    // check-in docked: the row's word, its running call or the folded card's
    // text (.ts-mini), the text streamed under the card.
    asksLive: stageEl.classList.contains("asks-live"),
    phaseWord: stageEl.querySelector(".ts-phase")?.textContent || "",
    miniRow: stageEl.querySelector(".ts-mini")?.textContent || "",
    asksText: (() => { const el = stageEl.querySelector(".ts-asks-text"); return el && !el.hidden ? el.textContent : ""; })(),
    waits: stageEl.classList.contains("waiting"),
    prompt: stageEl.querySelector(".ts-prompt .bubble.user") ? "stage" : historyEl.querySelector(":scope > .bubble.user") ? "history" : null,
    block: stageEl.dataset.block || (stageEl.querySelector(".ts-cloud-body .turn-work, .ts-answer .turn-work") ? "stage" : null),
  };
}

// The registry against the slots after each event (the drift check the page
// ran at each refresh until A1 phase 5): an entry whose card is gone from the
// extras and the tail or waits no more, a card there that waits with no entry.
function drift(page) {
  const root = page.turnDom.root;
  const slots = [...root.querySelector(".ts-extras").children, ...root.querySelector(".ts-tail").children];
  const kinds = new Map(slots.map((el) => [waitingKey(el), waitingKind(el)]).filter(([key, kind]) => key && kind));
  const keys = new Set(page.turnDom.waiting.list().map((e) => e.key));
  return [...[...keys].filter((key) => !kinds.has(key)), ...[...kinds.keys()].filter((key) => !keys.has(key))];
}

// The registry against the slots: the same keys and kinds, in order.
function crossCheck(page, label) {
  assert.deepEqual(drift(page), [], `${label}: no entry without its card, no waiting card without its entry`);
  const shape = stageShape(page.turnDom.root, page.historyEl, page.turnDom.waiting);
  const fromDom = shape.cards.filter((c) => c.kind !== "warn").map(({ key, kind }) => ({ key, kind }));
  assert.ok(shape.showing.length <= 1, `${label}: one docked card shows at a time`);
  const fromData = page.turnDom.waiting.list().filter((e) => e.kind !== "warn").map(({ key, kind }) => ({ key, kind }));
  assert.deepEqual(fromData, fromDom, `${label}: the waiting cards as data agree with the slots`);
  assert.deepEqual(page.turnDom.waiting.docked(), shape.docked, `${label}: docked as data agrees with the asking form`);
}

// The page that lived through +events+.
async function livedTo(events) {
  const page = livePage({ questions: true });
  for (const [i, event] of events.entries()) {
    await page.handlers[event.type]?.({ ...event });
    // Events apart, as they come live: each one's microtasks (the stage's
    // refresh on a card's change) run before the next.
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.deepEqual(drift(page), [], `after event ${i} (${event.type}): the waiting cards as data agree with the slots`);
  }
  page.turnDom.flush();
  await settle();
  // A turn handed off meanwhile has landed (its fold's end).
  page.turnDom.settleFold();
  return page;
}

// +page+ redrawn from +show+ (session_view.js renderSessionView's order): the
// history, the snapshot's placed cards, the replay, the running turn's cards,
// the pending question, the continue offer.
async function drawShow(page, show) {
  page.historyEl.replaceChildren(turnHistoryNodes(show.messages || [], {}, {
    thumbs: () => null, drawings: show.turn_drawings || null, cards: show.cards || null, runningTurnId: show.current_turn?.turn_id || null,
  }));
  const snapshotCards = splitSnapshotCards(show.cards, {});
  page.cards.placeSnapshotCards(snapshotCards.placed);
  for (const event of show.replay || []) await page.handlers[event.type]?.({ ...event, replayed: true });
  page.turnDom.flush();
  snapshotCards.current.forEach((card) => page.cards.upsertCard(card));
  snapshotCards.during.forEach((card) => page.cards.upsertCard(card));
  const pq = show.pending_question;
  if (pq?.id && pq.status === "pending") {
    if (pq.refs) page.turnDom.questionRefs(pq.refs);
    page.questionCards.renderQuestion(pq);
    page.questionCards.markRelayed(pq.id, pq.relayed_to || null);
  }
  if (show.continue_offer) page.questionCards.renderContinue(show.continue_offer);
  await settle();
  return page;
}

// The page that reloads to +show+.
async function reloadedTo(show) {
  return drawShow(livePage({ questions: true }), show);
}

// The page that resyncs to +show+ mid-turn (session_sync.js resync:
// resetTurnView, then the session view drawn again) — the same tab, so what
// sessionStorage holds is still there.
async function resyncTo(page, show) {
  page.questionCards.removeQuestion();
  page.questionCards.forgetContinue();
  page.turnDom.reset();
  return drawShow(page, show);
}

// The live-vs-reload differences still known at a cut, "<scenario>/<cut>":
// the stageShape fields (and "history") that differ. None today: a build
// that brings one back lists it here with its reason.
const EXPECTED = {};

const changed = (live, reloaded) => Object.keys(live).filter((k) => JSON.stringify(live[k]) !== JSON.stringify(reloaded[k]));

for (const scenario of scenarios) {
  for (const cut of scenario.cuts) {
    const id = `${scenario.name}/${cut.label}`;
    test(`${id}: a reload at the cut draws the stage and the history as live drew them (or today's known difference)`, async () => {
      const live = await livedTo(scenario.events.slice(0, cut.at));
      crossCheck(live, `${id} live`);
      const liveStage = stageShape(live.turnDom.root, live.historyEl, live.turnDom.waiting);
      const liveHistory = historyShape(live.historyEl);
      live.turnDom.reset();
      const reloaded = await reloadedTo(cut.show);
      crossCheck(reloaded, `${id} reloaded`);
      const reloadedStage = stageShape(reloaded.turnDom.root, reloaded.historyEl, reloaded.turnDom.waiting);
      const reloadedHistory = historyShape(reloaded.historyEl);
      reloaded.turnDom.reset();
      const differs = changed(liveStage, reloadedStage);
      const historyVerdict = compareShapes(liveHistory, reloadedHistory);
      if (!historyVerdict.same) differs.push("history");
      if (process.env.STAGE_CUTS_DEBUG) console.log(id, JSON.stringify({ differs, stage: Object.fromEntries(differs.filter((k) => k !== "history").map((k) => [k, [liveStage[k], reloadedStage[k]]])), history: historyVerdict.differences }));
      assert.deepEqual(differs.sort(), [...(EXPECTED[id] || [])].sort(),
        `${scenario.description}\nlive: ${JSON.stringify({ stage: liveStage, history: liveHistory }, null, 1)}\n`
        + `reloaded: ${JSON.stringify({ stage: reloadedStage, history: reloadedHistory }, null, 1)}`);
    });
  }
}

// The fold the user gave the asking card (audit r20 D5): it is this tab's
// state, so a resync mid-turn and a reload of the same tab draw the stage as
// live did. At every cut where a card is docked: a replay that answers an
// earlier card of the turn (question_after_approval's question) keeps it.
test("a card folded by hand stays folded over a resync and a reload, at every cut", async () => {
  let folds = 0;
  for (const scenario of scenarios) {
    for (const cut of scenario.cuts) {
      // One tab per cut: the fold this tab kept is not the next one's.
      clearSession();
      const id = `${scenario.name}/${cut.label}`;
      const live = await livedTo(scenario.events.slice(0, cut.at));
      if (!stageShape(live.turnDom.root, live.historyEl, live.turnDom.waiting).docked.length) {
        live.turnDom.reset();
        continue;
      }
      folds += 1;
      live.turnDom.root.querySelector(".ts-fold").click();
      const key = live.turnDom.waiting.folded();
      assert.ok(key, `${id}: the asking card folds live`);
      assert.equal(stageShape(live.turnDom.root, live.historyEl, live.turnDom.waiting).folded, true, `${id}: the stage is folded`);

      const resynced = await resyncTo(live, cut.show);
      assert.equal(stageShape(resynced.turnDom.root, resynced.historyEl, resynced.turnDom.waiting).folded, true,
        `${id}: a mid-turn resync keeps the fold`);
      live.turnDom.reset();

      const reloaded = await reloadedTo(cut.show);
      assert.equal(stageShape(reloaded.turnDom.root, reloaded.historyEl, reloaded.turnDom.waiting).folded, true,
        `${id}: a reload brings the fold back`);
      assert.equal(reloaded.turnDom.waiting.folded(), key, `${id}: on the card live folded`);
      reloaded.turnDom.reset();
    }
  }
  assert.ok(folds > scenarios.length, "more than one cut per scenario on average");
});

// An answered question of an earlier turn (the snapshot's cards, placed
// before the replay: placeSnapshotCards → placeResolvedQuestion) is not the
// folded card: a reload keeps the fold.
test("a fold survives a reload of a session with an answered question in its history", async () => {
  const scenario = scenarios.find((s) => s.name === "approval_bare");
  const cut = scenario.cuts[0];
  clearSession();
  const live = await livedTo(scenario.events.slice(0, cut.at));
  live.turnDom.root.querySelector(".ts-fold").click();
  const key = live.turnDom.waiting.folded();
  assert.ok(key);
  live.turnDom.reset();
  const earlier = {
    type: "question", in_turn: true, of_turn: "turn-earlier", iteration: 1, calls: 1, turns_since: 1,
    pending_question: { id: "q-earlier", kind: "question", question: "Which one, earlier?", options: ["a", "b"], status: "answered" },
    answer: { selected: ["a"] },
  };
  const reloaded = await reloadedTo({ ...cut.show, cards: [earlier, ...(cut.show.cards || [])] });
  assert.ok(reloaded.historyEl.querySelector('.bubble.question.answered[data-qid="q-earlier"]'), "the earlier question is drawn, answered");
  assert.equal(reloaded.turnDom.waiting.folded(), key, "the fold is back after the reload");
  assert.equal(stageShape(reloaded.turnDom.root, reloaded.historyEl, reloaded.turnDom.waiting).folded, true);
  reloaded.turnDom.reset();
});

// Live: two docked cards (check-in, then an approval), the pager on check-in
// and it folded; the approval answered from another client. A reload keeps
// check-in's fold: the answer settles the approval's own fold only.
test("a folded check-in card stays folded over a reload after the approval beside it is answered elsewhere", async () => {
  const scenario = scenarios.find((s) => s.name === "checkin_approval");
  const both = scenario.cuts.find((c) => c.label === "both");
  const after = scenario.cuts.find((c) => c.label === "approval answered");
  clearSession();
  const live = await livedTo(scenario.events.slice(0, both.at));
  assert.equal(live.turnDom.waiting.docked().length, 2);
  live.turnDom.root.querySelectorAll(".ts-pager .ts-page")[1].click();
  await settle();
  live.turnDom.root.querySelector(".ts-fold").click();
  const key = live.turnDom.waiting.folded();
  assert.ok(key?.startsWith("c:"), `check-in is folded (${key})`);
  for (const event of scenario.events.slice(both.at, after.at)) {
    await live.handlers[event.type]?.({ ...event, client_id: "web:other" });
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  await settle();
  assert.equal(live.turnDom.waiting.folded(), key, "live keeps the fold");
  live.turnDom.reset();
  const reloaded = await reloadedTo(after.show);
  assert.equal(reloaded.turnDom.waiting.folded(), key, "a reload brings it back");
  assert.equal(stageShape(reloaded.turnDom.root, reloaded.historyEl, reloaded.turnDom.waiting).folded, true);
  reloaded.turnDom.reset();
});

test("every waiting cut has a card waiting on the live page", async () => {
  assert.ok(scenarios.length >= 9);
  for (const scenario of scenarios) {
    const page = await livedTo(scenario.events.slice(0, scenario.cuts[0].at));
    assert.ok(page.turnDom.waiting.count({ asks: true }) > 0 || page.historyEl.querySelector(".bubble.question:not(.answered)"), scenario.name);
    page.turnDom.reset();
  }
});
