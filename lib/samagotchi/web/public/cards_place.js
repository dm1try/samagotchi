// Where the open session's plugin cards and a snapshot's notices go in the
// history (the cards' own markup is card.js'):
//
// A plugin's card (docs/plugins.md, Cards): a glass card between turns, or
// a row of the running turn's step. The same id updates the card in place.
// An action button runs its command line in the session (sendCommand), as
// if typed. A snapshot's cards and notices go back where they showed live:
// above the first turn after them, a finished turn's notice in its step, a
// finished turn's question resolved where it was asked.
import { getSession, sendCommand } from "./data.js";
import { cardPlace, drawCard, isCard, isNoticeCard, refreshCardBody, turnNoticePlace } from "./card.js";
import { elementOf } from "./turn_html.js";
import { stepText } from "./turn_view.js";
import { llmContextNotice, noticeLine } from "./turn_events.js";
import { hookNoticeTemplate, TURN_PROMPT, turnPromptBubbles } from "./bubbles.js";

// The elements of the reloaded turn that ends before +before+ (the next
// turn's prompt, or null for the last turn), its prompt first.
export function reloadedTurnEls(historyEl, before) {
  const turnEls = [];
  for (let el = before ? before.previousElementSibling : historyEl.lastElementChild; el; el = el.previousElementSibling) {
    turnEls.unshift(el);
    if (el.matches(TURN_PROMPT)) break;
  }
  return turnEls;
}

// What goes after a reloaded turn's own rows and cards: its answer, else
// its timing line; null when it has neither.
export function turnAnswerEl(turnEls) {
  return turnEls.filter((el) => el.matches(".bubble.output, .empty-answer")).pop() || turnEls.find((el) => el.matches(".turn-timing")) || null;
}

// @param historyEl the history
// @param appendToHistory (el) puts +el+ at the history's end (or the stage's)
// @param isNearBottom () => whether the history follows its end
// @param turnDom the running turn's view (its card(el) takes a turn's card)
// @param findInTurnRoots (selector) => the matching elements in the history
//   and the stage
// @param selected () => the open session's id
// @param clientId this tab's id in the session's events
// @param questionCards the history's question cards (question_cards.js)
// @param bubbles {removeHintIfEmpty, showGuardrailWarning, showHookNotice}
//   (bubbles.js createBubbles)
// @param followWokenWorker () follows the worker a card's command woke
// @param api {getSession, sendCommand} (data.js)
// @return {cardElement(id), upsertCard(card, {before}), placeSnapshotCards(entries),
//   refreshCardBodies(), onCardAction(event)}
export function createCardsPlace({
  historyEl, appendToHistory, isNearBottom, turnDom, findInTurnRoots, selected, clientId, questionCards, bubbles,
  followWokenWorker, api = { getSession, sendCommand },
}) {
  function cardElement(id) {
    if (!id) return null;
    return findInTurnRoots(".plugin-card").find((el) => el.dataset.cardId === String(id)) || null;
  }

  // Show +card+: update the one with its id where it is, else add it (a
  // running turn's card as a row of its step; else before +before+ or at the
  // end of the history). A running turn's card with actions asks the user
  // something (check-in's Nudge / Keep going / Stop): it goes under the turn's
  // block, not into a step that collapses when the next one starts.
  function upsertCard(card, { before = null } = {}) {
    if (!card || !card.id) return;
    const existing = cardElement(card.id);
    if (existing) {
      const drawn = drawCard(existing, card);
      drawn.classList.add("card-updated");
      setTimeout(() => drawn.classList.remove("card-updated"), 900);
      return;
    }
    bubbles.removeHintIfEmpty();
    const el = drawCard(document.createElement(isNoticeCard(card) ? "details" : "div"), card);
    const asks = (card.actions || []).some((a) => a && a.command);
    if (card.in_turn && !before && !asks && turnDom.card(el)) return;
    const follow = isNearBottom();
    if (before) historyEl.insertBefore(el, before);
    else appendToHistory(el);
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
  }

  // A snapshot's cards and notices, each above the first turn after it; a
  // turn's own notice where it showed live (placeTurnNotice).
  function placeSnapshotCards(entries) {
    const users = turnPromptBubbles(historyEl);
    for (const entry of entries) {
      const before = cardPlace(users, entry);
      if (isCard(entry)) upsertCard(entry, { before });
      else if (entry.type === "question") placeResolvedQuestion(entry, before);
      else if (entry.type === "guardrail_warning") bubbles.showGuardrailWarning(entry.message, entry.label || "guardrails", { before });
      else if (entry.in_turn) placeTurnNotice(entry, before);
      else if (entry.type === "hook_notice") bubbles.showHookNotice(entry, { before });
    }
  }

  // A finished turn's row, a hook's notice or the loop's asking again
  // (+before+: the next turn's prompt, or null for the last turn): a row of
  // its step, above the row of the call it came before, as live; else (a
  // plain answer, a step the history doesn't have) a bubble before the
  // turn's answer, or before its timing line when it has none.
  function placeTurnNotice(entry, before) {
    const extra = entry.type === "llm_context_edited" ? llmContextNotice(entry) : {};
    const line = noticeLine(entry);
    const turnEls = reloadedTurnEls(historyEl, before);
    const place = turnNoticePlace(entry);
    const block = turnEls.find((el) => el.matches(".turn-work"));
    const step = place && block ? block.querySelectorAll(":scope > .gen")[place.step] : null;
    if (!step) {
      bubbles.showHookNotice({ ...entry, ...extra, line }, { before: turnAnswerEl(turnEls) || before });
      return;
    }
    const el = elementOf(hookNoticeTemplate({ line, level: entry.level, cls: extra.cls, title: extra.title }, { bubble: false }));
    let body = step.querySelector(":scope > .activity-body");
    if (!body) {
      body = document.createElement("div");
      body.className = "activity-body";
      step.appendChild(body);
    }
    const row = [...body.children].find((r) => r.dataset.key === place.rowKey);
    body.insertBefore(el, row || null);
  }

  // A finished turn's question (the snapshot's cards keep it with its
  // answer): the card as it was left live, resolved, before the lines the
  // user sent into the turn after it (a steered bubble's data-step: the step
  // that read it) and the turn's answer. A pending one is the running turn's
  // (pending_question draws it).
  function placeResolvedQuestion(entry, before) {
    const pq = entry.pending_question;
    if (!pq?.id || !(entry.answer || entry.cancelled)) return;
    const turnEls = reloadedTurnEls(historyEl, before);
    const asked = Number(entry.iteration) || 1;
    // The reply that asked: its step's text in the reloaded block (the card
    // keeps it, as live), never the running turn's.
    const said = stepText(turnEls.find((el) => el.matches(".turn-work")), asked);
    questionCards.renderQuestion(pq, { said });
    const card = questionCards.questionCard();
    if (!card || card.dataset.qid !== String(pq.id)) return;
    questionCards.resolveQuestion(pq.id, { answer: entry.answer || null, cancelled: !!entry.cancelled, reason: entry.reason || "" });
    const later = turnEls.find((el) => el.matches(".bubble.user.steered") && Number(el.dataset.step) > asked);
    historyEl.insertBefore(card, later || turnAnswerEl(turnEls) || before);
  }

  // A live card's body comes as text; the worker's snapshot (through the
  // server) has it rendered. One re-read for a burst of cards.
  let cardBodiesTimer = null;
  function refreshCardBodies() {
    clearTimeout(cardBodiesTimer);
    const id = selected();
    cardBodiesTimer = setTimeout(async () => {
      try {
        const data = await api.getSession(id, { cards: true });
        if (id !== selected()) return;
        for (const card of data.cards || []) {
          const el = card.type === "card" && cardElement(card.id);
          if (el) refreshCardBody(el, card);
        }
      } catch (_) {}
    }, 150);
  }

  // A card's action button (a click anywhere in the turn roots).
  function onCardAction(e) {
    const button = e.target.closest(".plugin-card .card-action");
    const id = selected();
    if (!button || !id) return;
    const card = button.closest(".plugin-card");
    const err = card.querySelector(".card-error");
    err.classList.add("hidden");
    button.disabled = true;
    api.sendCommand(id, button.dataset.command, { clientId, card: true })
      .then(() => {
        // The command woke the worker: follow its stream if none is open.
        followWokenWorker();
      })
      .catch((error) => {
        err.textContent = error.message;
        err.classList.remove("hidden");
      })
      .finally(() => { button.disabled = false; });
  }

  return { cardElement, upsertCard, placeSnapshotCards, refreshCardBodies, onCardAction };
}
