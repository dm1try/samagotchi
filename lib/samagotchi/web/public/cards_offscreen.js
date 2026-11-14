// A snapshot's cards placed into a holder that is not the page (cards_offscreen.js):
// the opt-in reload check (reload_check.js) draws a handed-off turn offscreen and
// compares it with what the page has. A reload's render (turnHistoryNodes) doesn't
// run the placement (cards_place.js placeSnapshotCards), so the check needs its own.
//
// It is the real placer, not a copy: createCardsPlace, createBubbles and
// createQuestionCards over a detached holder, with every page hook made inert:
// no stage (turnDom answers "nothing holds it", and has no settleFold/settleWaiting
// — cards_place.js calls those with `?.`), no scroll, no hint, no info bar, no
// session id, no api. Nothing outside +holder+ is read or written; the page's
// questionCards, its turnDom and its appendToHistory are never touched.
import { createBubbles } from "./bubbles.js";
import { createCardsPlace } from "./cards_place.js";
import { createQuestionCards } from "./question_cards.js";
import { splitSnapshotCards } from "./card.js";

// +cards+ the read's snapshot (data.cards); +capabilities+ the page's, for the
// notices it shows elsewhere (splitSnapshotCards); +answers+ whether this viewer
// may answer cards at all (viewer.js answer_cards).
export function placeCardsOffscreen(holder, cards, { capabilities = null, answers = true, doc = globalThis.document } = {}) {
  const shared = {
    historyEl: holder,
    findInTurnRoots: (selector) => [...holder.querySelectorAll(selector)],
    isNearBottom: () => false,
    selected: () => null,
    clientId: null,
  };
  // No running turn here: nothing holds a piece, nothing takes a card or a steer.
  const turnDom = { card: () => false, steer: () => false, holds: () => false };
  const bubbles = createBubbles({
    ...shared,
    appendToHistory: (el) => holder.appendChild(el),
    turnDom,
    shownTexts: { shows: () => false },
    liveTurn: { timing: { el: null } },
  });
  const questionCards = createQuestionCards({
    ...shared,
    sessionId: () => null,
    place: (card) => { holder.appendChild(card); return false; },
    scrollToEnd: () => {},
    removeHintIfEmpty: () => {},
    askingText: () => "",
    renderMarkdown: () => Promise.resolve(null),
    onPending: () => {},
    onSettled: () => {},
    answers,
    doc,
    // A card's button is inert here: a placed card is a comparison, not a live ask.
    api: {
      sendAnswer: () => Promise.reject(new Error("offscreen card")),
      dismissQuestion: () => Promise.reject(new Error("offscreen card")),
      sendCommand: () => Promise.reject(new Error("offscreen card")),
    },
  });
  const place = createCardsPlace({
    ...shared,
    turnDom,
    questionCards,
    bubbles,
    followWokenWorker: () => {},
    api: {
      getSession: () => Promise.reject(new Error("offscreen card")),
      sendCommand: () => Promise.reject(new Error("offscreen card")),
    },
  });
  place.placeSnapshotCards(splitSnapshotCards(cards, capabilities).placed, { before: null });
  return holder;
}
