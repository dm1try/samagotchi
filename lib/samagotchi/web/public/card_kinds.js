// What a card waits as, from its data (stage_waiting.js KINDS): the kind,
// whether it is an approval, and the folded row's text (stage_asking.js
// foldedText), read from the pending question, the continue offer or the
// plugin card before its node is drawn. question_cards.js and cards_place.js
// hand it to the stage (onArrive / expectWaiting) right before the card is
// placed; the stage still reads the node (waitingKind, foldedText) as a
// cross-check, and as the fallback for a card that came without it.
// Pure: no DOM. The same rules question_cards.js and card.js draw by:
// data-kind, data-relay and the step-limit class; the question text and the
// approval's summary line; a plugin card's actions and level.
import { approvalView, isContinue, relayView, summaryText } from "./question_card.js";

// The question a card shows (its .question-text): a delegate's relayed
// question's own words, else the question.
export function questionText(pq) {
  return String((relayView(pq) && pq.relay.asked) || pq?.question || "");
}

// A pending question's wait: the step limit is "continue", a delegate's
// relayed card "relay", else its kind (approval, hook, question).
export function questionWait(pq) {
  const approval = pq?.kind === "approval";
  const kind = isContinue(pq) ? "continue" : relayView(pq) ? "relay" : ["approval", "hook"].includes(pq?.kind) ? pq.kind : "question";
  if (!approval) return { kind, approval, summary: questionText(pq) };
  // The summary's own words and the command's (or the tool's) first line.
  const view = approvalView(pq);
  const what = String(view.what || view.tool || "").trim().split("\n")[0].trim();
  return { kind, approval, summary: [summaryText(pq).trim(), what].filter(Boolean).join(" ") };
}

// The old continue card: no question text.
export function continueWait() {
  return { kind: "continue", approval: false, summary: "" };
}

// A plugin card's wait: a running turn's card with an action asks (as
// check-in's), a warning stays in sight; null: it doesn't wait.
export function cardWait(card) {
  const asks = !!card?.in_turn && (card.actions || []).some((a) => a && a.command);
  return { kind: asks ? "asks" : card?.level === "warn" ? "warn" : null, approval: false, summary: String(card?.title || "") };
}

// The cross-check: the data and the node disagree about +key+'s +what+
// ("kind", "summary"). Said once per key and field.
const said = new Set();
export function warnDiffers(what, key, data, dom) {
  const id = `${what}:${key}`;
  if (said.has(id)) return;
  said.add(id);
  console.warn(`stage: waiting ${what} differs`, key, data, dom);
}
