// The stage's answer reading (stage_view.js): the answer read from its top
// at the end, an answered card's line kept in sight, and the prompt's first
// words. Its own module: new exports go in new modules (web-frontend.md).
// No state of its own: nothing to reset at emptySlots.

// The answer reads from its top: at the end it is scrolled to unless this
// much of it (about three lines) shows already.
const ANSWER_SEEN = 72;
// A short answer cut by less than this at its foot isn't scrolled to.
const ANSWER_CUT = 12;
// An answered card's one line.
const ANSWERED_LINE = 40;
// That line brought back sits this far under the scroller's edge.
const ANSWERED_GAP = 8;

// +stage+, +scroller+ and the +answer+, +extras+ and +tail+ slots
// (stage_dom.js); +frame+() the stage's frame (stage_frame.js); +promptEl+()
// the turn's prompt bubble, or null.
export function createStageAnswer({ stage, scroller, answer, extras, tail, frame, promptEl }) {
  // The answer reads from its top (no tail pin in the stage): scrolled to
  // (eased, once the stage has grown for it) when its top is out of sight
  // or only its first line shows.
  function showAnswerTop() {
    frame().afterGrowth(() => {
      if (!answer.firstChild || answer.hidden || stage.hidden) return;
      const top = answer.offsetTop;
      const seen = scroller.scrollTop + scroller.clientHeight - top;
      if (top < scroller.scrollTop || seen < Math.min(answer.offsetHeight - ANSWER_CUT, ANSWER_SEEN)) frame().easeStage(Math.max(0, top - 8));
    });
  }

  // A card stopped waiting and its slot has its cap and own scroll again: the
  // slot's end shows (the answered card's line). The stage's scroll stays, so
  // nothing moves at the tap (the frame holds, and the blank goes at the next
  // step), unless the reader had scrolled down the tall card past its line:
  // then the line comes back, to the view's top and no further.
  function settleAnsweredCard() {
    const slot = tail.firstChild ? tail : extras;
    if (!slot.firstChild) return;
    slot.scrollTop = slot.scrollHeight;
    const end = slot.offsetTop + slot.offsetHeight;
    // Strictly below: offsetTop/offsetHeight are rounded, so a scroll exactly
    // at the line's edge can leave it a fraction of a pixel above the view.
    if (scroller.scrollTop < end - ANSWERED_LINE) return;
    scroller.scrollTop = Math.max(0, Math.min(slot.lastElementChild.offsetTop, end - ANSWERED_LINE) - ANSWERED_GAP);
  }

  // The prompt's first words (the working set's session tags say whose
  // turn a step was).
  function promptWords() {
    const text = (promptEl()?.querySelector(".user-message")?.textContent || "").replace(/\s+/g, " ").trim();
    return text.length > 60 ? `${text.slice(0, 59)}…` : text;
  }

  return { showAnswerTop, settleAnsweredCard, promptWords };
}
