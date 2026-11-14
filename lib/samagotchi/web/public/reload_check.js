// The opt-in reload check (web.reload_check; <body data-reload-check="1">):
// once a finished turn's pieces have reached the history (the stage's
// hand-off), the page reads the session again as a reload would, draws the
// turn offscreen (turnHistoryNodes, a reload's renderer) and compares the
// two (history_shape.js) strictly: no ACCEPTED entry excuses a difference,
// so `same` is false for a known divergence too, and `excused` names the
// entries that would explain the differences (`explained`: all of them
// have one), so chi web's log counts each class apart (the bugs turn
// drawings close, the deliberate ones). It posts the counts, never
// content: {turn_id, same, kinds, excused, explained, drawn, undrawn}; chi
// web logs them (reload_checked, reload_mismatch). `undrawn`: how many rows
// of the reload came without their turn's drawing (turn_block.js's plain
// fallback, data-undrawn): 0 unless chi web missed one. Fire-and-forget: no toast, no
// store write, a failure is dropped.
//
// Compared: the turn's own cards and questions too. A drawn turn already
// renders its plugin cards (turn_block.js), and the snapshot's questions and
// an undrawn turn's entries are placed into the offscreen holder by
// cards_offscreen.js, the same placer the page uses with inert hooks. Only
// entries CardStore attributes to this turn (of_turn) are compared; a card
// the turn doesn't own (another turn's, a between-turn notice) is dropped on
// both sides, and a question the read attributes to no turn and stamps to no
// opening (an older worker) is dropped as well, since nothing places it.
// What a card's equality means: its id and title, or a question's summary line
// — not its body, its buttons, its fold or the tag it is drawn in.
// Between-turn cards and notices are out of scope (the e2e reload checks
// cover them).
import { compareShapes, historyShape } from "./history_shape.js";
import { isCard, splitSnapshotCards } from "./card.js";
import { turnElements } from "./turn_range.js";

// The opening of a turn: its prompt, a wake's note, /continue no's line.
const OPENING = "[data-turn-id], [data-opening-id]";
// Not the turn's: the lines queued for after it (they open the next turns).
const NOT_THE_TURNS = ".bubble.user.queued, .bubble.command.queued";

function openingId(el) {
  return el?.dataset?.turnId || el?.dataset?.openingId || null;
}

// The snapshot entries this turn owns (CardStore's of_turn): a drawn turn
// already renders its cards, so only its questions come from the placer; an
// undrawn turn has all of them placed, as a reload places them. Entries the
// page shows elsewhere, the running turn's and the ones that came during it
// are out (splitSnapshotCards), as in session_view.js.
function turnEntries(cards, capabilities, turnId, drawn) {
  const placed = splitSnapshotCards(cards, capabilities).placed.filter((entry) => entry?.of_turn === turnId);
  return drawn ? placed.filter((entry) => entry?.type === "question") : placed;
}

// A question the read attributes to no turn (an older worker: no of_turn, and
// no opening it came after, or one stamped to this very turn) has nothing to
// place it from, so its card is left out of the compare. Only entries that
// could belong to this turn count: one stamped to another turn does not
// silence questions here.
function looseQuestions(cards, turnId) {
  return (Array.isArray(cards) ? cards : []).some((entry) => entry?.type === "question"
    && entry?.of_turn == null && (entry?.opening_id == null || String(entry.opening_id) === String(turnId)));
}

// The ids of the snapshot's cards that are not this turn's.
function foreignIds(cards, turnId) {
  return new Set((Array.isArray(cards) ? cards : [])
    .filter((entry) => isCard(entry) && entry?.of_turn !== turnId)
    .map((entry) => String(entry.id ?? "")));
}

// This turn's items only: a card of another turn or between turns is dropped
// by id; a question the worker didn't attribute to a turn (an older worker)
// has nothing to place it from, so questions are dropped on both sides.
function turnOnly(shape, foreign, questions) {
  return shape.filter((item) => {
    if (item.kind === "card") return !foreign.has(item.id);
    if (item.kind === "question") return questions;
    return true;
  });
}

// @param enabled () => whether the check is on (the body's attribute)
// @param sessionId () => the open session's id
// @param running () => whether a turn runs now (liveTurn.running: a queued
//   turn started streaming)
// @param read (id) => the session as a reload reads it (the full GET)
// @param render (data) => that read drawn as a reload draws it (a fragment)
// @param place (holder, entries) puts the turn's snapshot entries into that
//   holder as a reload's placement would (cards_offscreen.js); without it,
//   cards and questions are dropped from both sides
// @param capabilities () => the page's capabilities (which notices it shows
//   elsewhere)
// @param post (id, body) => the counts to chi web
export function createReloadCheck({ enabled, sessionId, running, read, render, place = null, capabilities = () => null, post }) {
  // The hand-off's pieces (stage_view.js onHandedOff), in their order;
  // +immediate+: another turn took the stage at once.
  async function handedOff({ pieces = [], immediate = false } = {}) {
    if (!enabled() || immediate || running()) return;
    const [opening, ...rest] = pieces;
    const turnId = openingId(opening?.matches?.(OPENING) ? opening : null);
    if (!turnId) return;
    const id = sessionId();
    try {
      const data = await read(id);
      if (sessionId() !== id || running()) return;
      // The live pieces as they read now, after the read: a canceled or
      // failed turn hands off at once, and its timing line takes the turn
      // record's figure when its own re-read lands (refreshTimingFromSession),
      // which started at the turn's end, before this one.
      // Whether the read had a drawing for the turn (turn drawings, P2): a
      // drawn one already renders its own cards, an undrawn one has them
      // placed after the render.
      const drawn = !!data?.turn_drawings?.[turnId];
      const entries = place ? turnEntries(data.cards, capabilities(), turnId, drawn) : [];
      // A question the read can't place for this turn (see looseQuestions) is
      // left out of the compare on both sides.
      const questions = !!place && !looseQuestions(data.cards, turnId);
      const shapeOf = (shape) => turnOnly(shape, foreignIds(data.cards, turnId), questions);
      const live = shapeOf(historyShape(rest.filter((el) => !el.matches?.(NOT_THE_TURNS))));
      const holder = document.createElement("div");
      holder.append(render(data));
      // The turn's own cards and questions, where a reload would put them.
      if (place) place(holder, entries);
      const reopened = [...holder.querySelectorAll(OPENING)].find((el) => openingId(el) === turnId);
      const reloaded = reopened ? shapeOf(historyShape(turnElements(reopened, { container: holder }))) : [];
      const { same, kinds, excused, explained } = reopened ? compareShapes(live, reloaded)
        : { same: false, kinds: ["prompt"], excused: [], explained: false };
      const undrawn = holder.querySelectorAll("[data-undrawn]").length;
      await post(id, { turn_id: turnId, same, kinds, excused, explained, drawn, undrawn });
    } catch (_) {
      // Fire-and-forget: a failed read or post is no finding.
    }
  }
  return { handedOff };
}
