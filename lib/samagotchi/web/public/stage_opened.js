// A running turn opened in the history (stage_view.js). When the model's
// own question blocks the turn after a reply, the reply that asked it (the
// reason) becomes a conversation bubble at the history's end, and from then
// to the turn's end the turn's prompt, its steps block and the rows that
// arrive are the history's; only what waits for the user (the card), the
// live slots and the answer stay in the stage. This module draws the reason
// bubble and moves things into the history (history_end.js), following a
// reader who was at the history's end (a reader scrolled up is never
// moved). At the hand-off the reasons go (end): each answered card's own
// two-line clamp says it then, as a finished turn and its reload have it.
//
// The reason bubble (.bubble.said, live only): a label line ("chi · step
// N", "asking you" while its card waits: .pending), the text raw at once,
// then its markdown when the page's render answers, refs linked on both
// draws. It carries data-question-id and data-said-turn (never
// data-turn-id: that marks a turn's opening, turn_range.js).
import { moveToHistoryEnd } from "./history_end.js";
import { revealInHistory } from "./history_reveal.js";
import { easeScrollTo } from "./scroll.js";

// What the history scrolls to sits this far under its top edge.
const READ_GAP = 8;

// +historyEl+: the history; +atHistoryEnd()+: the reader is at its end;
// +renderMarkdown(text)+: a promise of the text's HTML (null: keep it raw);
// +linkRefs(el, refs)+: the page's ref pass; +reduce()+: reduced motion;
// +afterSettle(fn)+: +fn+ once the stage has settled for a change made now
// (stage_frame.js afterGrowth: the asking form's shrink moves the history's
// bottom reserve, whose own follow of the end must not win over the
// reason's first line).
export function createOpenedTurn({
  historyEl, atHistoryEnd, renderMarkdown = () => null, linkRefs = () => {}, reduce = () => false,
  afterSettle = (fn) => requestAnimationFrame(() => requestAnimationFrame(fn)),
}) {
  // card → its reason bubble, for the turn in the stage.
  const reasons = new Map();
  // The asking steps whose text a reason shows (data-said: their text is
  // hidden in the block meanwhile, index.html), to clear at the end.
  const saidSteps = new Set();

  // The asking step: the last step of the history's last steps block (in
  // order from the opening on, turn_block.js inOrder).
  function askingStep() {
    const block = [...historyEl.querySelectorAll(":scope > .turn-work")].at(-1);
    return block?.querySelector(":scope > details.gen:last-of-type") || null;
  }

  // The reasons go: their steps show their own text again.
  function clearSaid() {
    for (const step of saidSteps) delete step.dataset.said;
    saidSteps.clear();
  }

  // +el+'s top in the history's scroll.
  function topIn(el) {
    return historyEl.scrollTop + el.getBoundingClientRect().top - historyEl.getBoundingClientRect().top;
  }

  // The history to +el+'s top (none: its end). An +el+ gone meanwhile (a
  // session switch drew another history) moves nothing: the scroll stays.
  function scrollTo(el = null) {
    return easeScrollTo(historyEl, () => {
      if (el && !el.isConnected) return historyEl.scrollTop;
      const end = historyEl.scrollHeight - historyEl.clientHeight;
      return el ? Math.max(0, Math.min(end, topIn(el) - READ_GAP)) : end;
    }, { reduce: reduce() });
  }

  // +pieces+ to the history's end in order; a reader at the end follows
  // (+follow+: false when a reason's read follows instead).
  function add(pieces, { follow = atHistoryEnd() } = {}) {
    moveToHistoryEnd(historyEl, pieces);
    if (follow) scrollTo();
  }

  function reasonBubble({ text, refs, step, turnId, questionId }) {
    const bubble = document.createElement("div");
    bubble.className = "bubble said pending";
    if (questionId != null) bubble.dataset.questionId = String(questionId);
    if (turnId) bubble.dataset.saidTurn = turnId;
    const label = document.createElement("div");
    label.className = "said-label";
    const who = document.createElement("span");
    who.textContent = step ? `chi · step ${step}` : "chi";
    const asking = document.createElement("span");
    asking.className = "said-asking";
    asking.textContent = "asking you";
    label.append(who, asking);
    const body = document.createElement("div");
    body.className = "said-text";
    body.textContent = text;
    bubble.append(label, body);
    linkRefs(body, refs);
    // Its markdown, under the reader's first lines (the bubble's one
    // height change).
    Promise.resolve()
      .then(() => renderMarkdown(text))
      .catch(() => null)
      .then((html) => {
        if (!html || !bubble.isConnected) return;
        // Sanitised on the server (POST /api/render).
        body.innerHTML = html;
        body.classList.add("markdown", "md-compact");
        linkRefs(body, refs);
      });
    return bubble;
  }

  // The card's way back to its reason, at its title line's right.
  function reasonLink(card, bubble) {
    const summary = card.querySelector(":scope > summary");
    if (!summary) return;
    const link = document.createElement("button");
    link.type = "button";
    link.className = "question-reason-link";
    link.textContent = "↑ its reason";
    link.title = "Show the reply that asked this";
    link.addEventListener("click", (e) => {
      // Inside the summary: no toggle.
      e.preventDefault();
      e.stopPropagation();
      if (bubble.isConnected) scrollTo(bubble);
    });
    summary.appendChild(link);
  }

  // The first of the history's rows after one of +going+ (they move when
  // it goes) whose bottom is below the view's top; null: none (what shows
  // is above them all, and stays).
  function firstInView(going) {
    const top = historyEl.getBoundingClientRect().top;
    let after = false;
    for (const el of historyEl.children) {
      if (going.includes(el)) {
        after = true;
        continue;
      }
      if (after && el.getBoundingClientRect().bottom > top) return el;
    }
    return null;
  }

  return {
    // The turn's pieces so far (handOffOrder's order) into the history; the
    // reason's read (ask) does the follow.
    open: (pieces) => add(pieces, { follow: false }),
    // A row of the opened turn: to the history's end.
    add: (el) => add([el]),
    // +card+ blocks the turn: its reason's bubble at the history's end, in
    // the card's task; a reader at the end reads it from its first line.
    // +follow+: the reader was at the end before the turn opened.
    ask({ card, text, refs = null, step = 0, turnId = null, questionId = null, follow = atHistoryEnd() }) {
      const bubble = reasonBubble({ text, refs, step, turnId, questionId });
      moveToHistoryEnd(historyEl, [bubble]);
      reasons.set(card, bubble);
      // The step's own text is the reason: not twice (and raw while the
      // step runs). data-said, not a class: lit owns the step's class.
      const stepEl = askingStep();
      if (stepEl) {
        stepEl.dataset.said = "1";
        saidSteps.add(stepEl);
      }
      reasonLink(card, bubble);
      // The reader at the end reads it from its first line: meanwhile the
      // history is marked data-reading, so the bottom reserve's follow
      // (dock_reserve.js) doesn't take the end back.
      if (follow) {
        historyEl.dataset.reading = "";
        afterSettle(() => {
          const done = () => { delete historyEl.dataset.reading; };
          if (bubble.isConnected) scrollTo(bubble).then(done, done);
          else done();
        });
      }
      return bubble;
    },
    has: (card) => reasons.has(card),
    // +card+ no longer waits (answered, cancelled): it goes right under its
    // reason, which stops saying "asking you"; another card of the turn to
    // the history's end. A reader at the end follows.
    settle(card) {
      const bubble = reasons.get(card);
      if (!bubble?.isConnected) return add([card]);
      const follow = atHistoryEnd();
      bubble.classList.remove("pending");
      bubble.after(card);
      if (follow) scrollTo();
    },
    // The turn's steps block (or one of its steps, +el+) in the history:
    // unfolded and brought into view.
    reveal(el) {
      if (!el) return;
      revealInHistory(el);
      if (el.matches?.("details") && !el.open) el.open = true;
      scrollTo(el);
    },
    // The reasons drawn (the hand-off waits while one is in use).
    watched: () => [...reasons.values()].filter((el) => el.isConnected),
    // The hand-off: the reasons go; each card's own clamp says it now. The
    // reader keeps what they see: the first row in view that stays (the
    // card under a reason they read) stays where it is (the history's own
    // scroll anchoring has none to keep when the row it anchored on goes);
    // a reader at the end then follows the turn's arrival (stage_view.js
    // finishFold).
    end() {
      const gone = [...reasons.values()].filter((el) => el.isConnected);
      reasons.clear();
      clearSaid();
      if (!gone.length) return;
      const anchor = firstInView(gone);
      const before = anchor?.getBoundingClientRect().top;
      for (const bubble of gone) bubble.remove();
      if (anchor) historyEl.scrollTop += anchor.getBoundingClientRect().top - before;
    },
    // The turn left the stage without a hand-off (a reset): forgotten, the
    // history is drawn anew.
    reset() {
      reasons.clear();
      saidSteps.clear();
    },
    // The turn was released without its end (a lost turn_completed, the
    // next turn started): its reasons go, nothing else moves.
    drop() {
      for (const bubble of reasons.values()) bubble.remove();
      reasons.clear();
      clearSaid();
    },
  };
}
