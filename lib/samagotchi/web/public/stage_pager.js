// The stage's pager (stage_view.js): one docked card at a time, the others
// wait behind it (.ts-behind), and "‹ 1 of 2 ›" in the status row says where
// the shown one is (stage_waiting.js shown, page). Its own module: new
// exports go in new modules (web-frontend.md).
import { waitingKey } from "./stage_waiting.js";

// +card+'s first control takes the focus (its summary is out of the tab
// order while it waits), else the card.
function focusIn(card) {
  const control = card.querySelector('input:not([type="hidden"]), textarea, select, button:not([disabled]), a[href]');
  if (control) control.focus();
  else {
    if (!card.hasAttribute("tabindex")) card.tabIndex = -1;
    card.focus();
  }
}

// +pager+, +pagePrev+, +pageLabel+, +pageNext+, +extras+: stage_dom.js's
// nodes; +waiting+: the stage's waiting cards (stage_waiting.js); +cardOf+(key)
// and +askingCard+(): stage_asking.js's; +refresh+(): the stage's redraw;
// +frame+(): the stage's frame (stage_frame.js).
export function createStagePager({ pager, pagePrev, pageLabel, pageNext, extras, waiting, cardOf, askingCard, refresh, frame }) {
  // +shownCard+ (null: none docked) in front, the others behind it.
  function drawDocked(shownCard) {
    const keys = waiting.docked();
    for (const key of keys) cardOf(key)?.classList.toggle("ts-behind", !!shownCard && cardOf(key) !== shownCard);
    for (const el of extras.querySelectorAll(":scope > .ts-behind")) if (!keys.includes(waitingKey(el))) el.classList.remove("ts-behind");
    // Focus in a card that went behind (a new card came in front of it):
    // to the card that shows now.
    const focused = document.activeElement;
    if (shownCard && focused && [...extras.querySelectorAll(":scope > .ts-behind")].some((el) => el.contains(focused))) focusIn(shownCard);
    const at = shownCard ? keys.indexOf(waitingKey(shownCard)) : -1;
    pager.hidden = keys.length < 2 || at < 0;
    if (pager.hidden) return;
    const label = `${at + 1} of ${keys.length}`;
    if (pageLabel.textContent !== label) pageLabel.textContent = label;
    pagePrev.disabled = at === 0;
    pageNext.disabled = at === keys.length - 1;
    // A pager button the page just disabled keeps no focus: the other one has it.
    if (document.activeElement === pagePrev && pagePrev.disabled) pageNext.focus();
    else if (document.activeElement === pageNext && pageNext.disabled) pagePrev.focus();
  }

  for (const [button, by] of [[pagePrev, -1], [pageNext, 1]]) {
    button.addEventListener("click", (e) => {
      e.stopPropagation();
      waiting.page(by);
      refresh();
      const shown = askingCard();
      if (shown) frame().afterGrowth(() => frame().reveal(shown.parentElement));
    });
  }

  function reset() {
    pager.hidden = true;
  }

  return { drawDocked, reset };
}
