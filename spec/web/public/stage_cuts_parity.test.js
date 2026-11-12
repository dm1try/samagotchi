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
import { readdirSync, readFileSync } from "node:fs";

const { livePage } = await import("./live_page.js");
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
// fold, check-in's row (asks-live, the phase word, the mini row) and the
// text streamed under it, where the turn's prompt and block are.
export function stageShape(stageEl, historyEl, waiting) {
  const cards = [];
  for (const slot of ["ts-extras", "ts-tail"]) {
    for (const el of stageEl.querySelector(`.${slot}`)?.children || []) {
      const kind = waitingKind(el);
      if (kind) cards.push({ key: waitingKey(el), kind, slot });
    }
  }
  const askingForm = stageEl.classList.contains("asking-form");
  return {
    shown: !stageEl.hidden,
    cards,
    docked: askingForm ? cards.filter((c) => c.slot === "ts-extras" && c.kind !== "warn").map((c) => c.key) : [],
    leadIns: [...historyEl.querySelectorAll(":scope > .bubble.said")].map((el) => ({ question: el.dataset.questionId ?? null, asking: el.classList.contains("pending") })),
    front: waiting.front(),
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

// The registry against the slots: the same keys and kinds, in order.
function crossCheck(page, label) {
  const shape = stageShape(page.turnDom.root, page.historyEl, page.turnDom.waiting);
  const fromDom = shape.cards.filter((c) => c.kind !== "warn").map(({ key, kind }) => ({ key, kind }));
  const fromData = page.turnDom.waiting.list().filter((e) => e.kind !== "warn").map(({ key, kind }) => ({ key, kind }));
  assert.deepEqual(fromData, fromDom, `${label}: the waiting cards as data agree with the slots`);
  assert.deepEqual(page.turnDom.waiting.docked(), shape.docked, `${label}: docked as data agrees with the asking form`);
}

// The page that lived through +events+.
async function livedTo(events) {
  const page = livePage({ questions: true });
  for (const event of events) {
    await page.handlers[event.type]?.({ ...event });
    // Events apart, as they come live: each one's microtasks (the stage's
    // refresh on a card's change) run before the next.
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  page.turnDom.flush();
  await settle();
  return page;
}

// The page that reloads to +show+, in renderSessionView's order: the
// history, the snapshot's placed cards, the replay, the running turn's
// cards, the pending question, the continue offer.
async function reloadedTo(show) {
  const page = livePage({ questions: true });
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

// Today's live-vs-reload differences at a cut, "<scenario>/<cut>": the
// stageShape fields (and "history") that differ.
// - The step limit: live, its card waits in the stage's tail with the ended
//   turn; after a reload the turn and the card are in the history and the
//   stage is gone, and the status row's word with it (the
//   interaction-in-conversation plan's F4 flips it).
// - check-in's card and an approval waiting together: live, check-in's card
//   first (it came first); a reload replays the approval with the turn and
//   places the running turn's cards after the replay, so the approval comes
//   first (both docked, in that order). The card in front is the approval on
//   both.
const EXPECTED = {
  "step_limit/waiting": ["cards", "front", "shown", "prompt", "block", "waits", "phaseWord", "history"],
  "checkin_approval/both": ["cards", "docked"],
};

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

test("every waiting cut has a card waiting on the live page", async () => {
  assert.ok(scenarios.length >= 9);
  for (const scenario of scenarios) {
    const page = await livedTo(scenario.events.slice(0, scenario.cuts[0].at));
    assert.ok(page.turnDom.waiting.count({ asks: true }) > 0 || page.historyEl.querySelector(".bubble.question:not(.answered)"), scenario.name);
    page.turnDom.reset();
  }
});
