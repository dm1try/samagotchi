// The one way the stage moves a turn's pieces into the history
// (stage_view.js): to its end, in the order given (the hand-off's
// handOffOrder, or what a turn opened in the history sends there as it
// arrives). The original nodes move (their ref bindings, selection and late
// updates with them); the empty history's hint goes first. +animate+: each
// piece arrives with .ts-arrive (gone at its animationend).
export function moveToHistoryEnd(historyEl, pieces, { animate = false } = {}) {
  historyEl.querySelector(":scope > .hint")?.remove();
  for (const el of pieces) {
    historyEl.appendChild(el);
    if (animate) {
      el.classList.add("ts-arrive");
      el.addEventListener("animationend", () => el.classList.remove("ts-arrive"), { once: true });
    }
  }
}
