// The stage's nodes (stage_view.js): the dock made a clear column (the
// stage's card, then the composer's: its rows moved into .dock-card, which
// wears the glass and the focus ring) and every slot of the stage, built
// once. Plain nodes, no behaviour: the listeners and the drawing are the
// stage's modules'. Its own module: new exports go in new modules
// (web-frontend.md).
import { node } from "./stage_slots.js";

// +dockEl+: the page's dock. Returns the nodes by name.
export function createStageDom(dockEl) {
  document.body.classList.add("stage-view");
  const card = node("div", "dock-card composer-card");
  card.append(...dockEl.children);
  dockEl.appendChild(card);
  const stage = node("section", "turn-stage");
  stage.id = "turnStage";
  stage.hidden = true;
  stage.setAttribute("aria-label", "Running turn");
  dockEl.prepend(stage);

  const status = node("div", "ts-status", stage);
  const mark = node("span", "ts-mark", status);
  const phaseEl = node("span", "ts-phase", status);
  // Two cards docked: one at a time, "‹ 1 of 2 ›" (stage_pager.js).
  const pager = node("span", "ts-pager", status);
  pager.hidden = true;
  const pagePrev = node("button", "ts-page", pager);
  pagePrev.type = "button";
  pagePrev.textContent = "‹";
  pagePrev.setAttribute("aria-label", "The card before");
  const pageLabel = node("span", "ts-page-label", pager);
  const pageNext = node("button", "ts-page", pager);
  pageNext.type = "button";
  pageNext.textContent = "›";
  pageNext.setAttribute("aria-label", "The next card");
  const stepEl = node("span", "ts-step", status);
  const timingSlot = node("span", "ts-timing", status);
  const miniTool = node("span", "ts-mini", status);
  const defer = node("span", "ts-defer", status);
  defer.textContent = "moves up when you leave";
  // Stop turn, at the row's right edge beside the fold: while the turn
  // hasn't ended (refresh), in a collapsed stage too (the row stays).
  const cancel = node("button", "ts-cancel", status);
  cancel.type = "button";
  cancel.title = "Cancel the running turn, whoever sent it";
  cancel.textContent = "Stop turn";
  cancel.hidden = true;
  const fold = node("button", "ts-fold", status);
  fold.type = "button";

  const scroller = node("div", "ts-scroll", stage);
  const promptSlot = node("div", "ts-prompt", scroller);
  promptSlot.title = "Show the whole prompt";
  const live = node("div", "ts-live", scroller);
  const headline = node("div", "ts-headline", live);
  headline.tabIndex = 0;
  headline.setAttribute("role", "button");
  headline.title = "Show this step's reasoning";
  // A participant's turn waiting for the owner: one line under the headline,
  // no card (stage_owner_wait.js).
  const ownerWaitLine = node("div", "ts-owner-wait", live);
  const now = node("div", "ts-now", live);
  const trail = node("div", "ts-trail", live);
  // (The working set's rail joins the live slots after the trail:
  // working_set_rail.js.)
  const extras = node("div", "ts-extras", scroller);
  // While check-in's card is docked: the live step's text, streamed under
  // the card (the steps are in the history then). The answer's own slot
  // takes it over at the turn's end (placeAnswer, in one task).
  const asksText = node("div", "ts-asks-text", scroller);
  asksText.hidden = true;
  const answer = node("div", "ts-answer", scroller);
  const tail = node("div", "ts-tail", scroller);
  // The cloud's steps, the scroller's last slot, right above the chip.
  const cloudBody = node("div", "ts-cloud-body", scroller);
  cloudBody.hidden = true;
  // A 1 px mark at the tallest content's end (absolute: out of the flow),
  // so the scroll extent never drops while the turn runs: content that
  // shrinks never lowers a scrolled reader's scrollTop (the browser would
  // clamp it, moving everything in sight), even in the layout before
  // fitFrame runs.
  const holdEl = node("div", "ts-hold", scroller);
  holdEl.setAttribute("aria-hidden", "true");
  // The footer: the chip, pinned to the stage's bottom edge as the status
  // row is to its top.
  const cloud = node("div", "ts-foot", stage);
  const chip = node("button", "ts-chip", cloud);
  chip.type = "button";
  const chipLabel = node("span", "ts-chip-label", chip);
  const ticks = node("span", "ts-ticks", chip);
  // Below the turn's card: the lines queued for after it (placeKind
  // "queued"), each to run as a turn of its own; they hand off last.
  const queuedSlot = node("div", "ts-queued", stage);

  return {
    stage, status, mark, phaseEl, pager, pagePrev, pageLabel, pageNext, stepEl, timingSlot, miniTool, cancel, fold,
    scroller, promptSlot, live, headline, ownerWaitLine, now, trail, extras, asksText, answer, tail, cloudBody, holdEl,
    cloud, chip, chipLabel, ticks, queuedSlot,
  };
}
