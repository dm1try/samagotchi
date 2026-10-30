// The popover shell a session-bar chip opens (llm_context_chip.js,
// level_chip.js, the working set's): a div.ctx-popover on the body, placed
// at the chip, opened by a click on it (delegated on +el+) or by open()
// (another opener: the working set's rail and footprint), closed by a second
// click, its × (data-act="close"), a click outside or Esc; focus goes back
// to the opener. Another session's summary (refresh) closes it. What it
// draws, and what a Set or another data-act does, is the caller's. With
// +sheet+, a window narrower than SHEET_MAX gets it as a bottom sheet.

import { nothing, render } from "./vendor/lit-html.js";

const EDGE = 16;
const GAP = 8;
// Under this window width a +sheet+ popover is a bottom sheet.
export const SHEET_MAX = 600;
const SHEET_EDGE = 8;

// Where the popover goes for the chip's +rect+: above it, or below when
// the room above is short of its height and below has more; capped to the
// room on that side (it scrolls), never past the window's edges.
// @return {{left, top?, bottom?, maxHeight?}}
export function popoverPlace(rect, { width, height, innerWidth, innerHeight }) {
  const left = Math.max(EDGE, Math.min(rect.left, innerWidth - width - EDGE));
  const above = rect.top - GAP - EDGE;
  const below = innerHeight - rect.bottom - GAP - EDGE;
  const down = height > above && below > above;
  const room = Math.max(0, down ? below : above);
  const place = down ? { left, top: rect.bottom + GAP } : { left, bottom: Math.max(EDGE, innerHeight - rect.top + GAP) };
  return height > room ? { ...place, maxHeight: room } : place;
}

// A bottom sheet's place in a phone's window: the window's width less its
// edges, at its bottom, at most 60 % of its height (the rest scrolls).
// @return {left, bottom, width, maxHeight}
export function sheetPlace({ innerWidth, innerHeight }) {
  return { left: SHEET_EDGE, bottom: SHEET_EDGE, width: innerWidth - 2 * SHEET_EDGE, maxHeight: Math.round(innerHeight * 0.6) };
}

// id, className: the popover's; width: its widest (px); el: where the chip
// is drawn; anchor: the chip's selector; openers: the selector of every
// element that opens it (a click there is not a click outside; default the
// anchor's); summary(anchor): what the form is drawn from (null: nothing
// opens); session(): the open session's id.
// show(data, opening): draws the form into the popover (opening: a fresh
// open, else a refresh with a newer summary); onClose(): the caller forgets
// its open state; onSubmit(form); onAct(name): a data-act other than close.
// sheet: a bottom sheet in a narrow window (sheetPlace). label: the
// dialog's accessible name (aria-label), none by default. onOpen(): after
// an open has shown and placed it (where focus can go into it: show runs
// while it is still hidden). expands: the opener carries aria-expanded
// ("true" while open, "false" once closed; set "false" in the markup too),
// for an opener that is a fixed button (a lit-drawn chip owns its own).
// @return {pop, open, close, refresh, isOpen, opener}
export function createChipPopover({ id, className, width: widest, el, anchor: anchorSel, openers = anchorSel, summary,
                                    session = () => null, show, onClose = () => {}, onSubmit, onAct = () => {}, onOpen = () => {},
                                    sheet = false, label = null, expands = false, doc = document, win = window }) {
  const pop = doc.createElement("div");
  pop.id = id;
  pop.className = className;
  pop.setAttribute("role", "dialog");
  if (label) pop.setAttribute("aria-label", label);
  pop.hidden = true;
  doc.body.appendChild(pop);
  // The session the open form is for, and the element that opened it.
  let openFor = null;
  let opener = null;

  function place(anchor) {
    const narrow = sheet && win.innerWidth < SHEET_MAX;
    pop.classList.toggle("sheet", narrow);
    if (narrow) {
      const at = sheetPlace({ innerWidth: win.innerWidth, innerHeight: win.innerHeight });
      pop.style.width = `${at.width}px`;
      pop.style.left = `${at.left}px`;
      pop.style.top = "";
      pop.style.bottom = `${at.bottom}px`;
      pop.style.maxHeight = `${at.maxHeight}px`;
      return;
    }
    const width = Math.min(widest, win.innerWidth - 32);
    pop.style.width = `${width}px`;
    pop.style.maxHeight = "";
    const at = popoverPlace(anchor.getBoundingClientRect(), { width, height: pop.offsetHeight,
                                                              innerWidth: win.innerWidth, innerHeight: win.innerHeight });
    pop.style.left = `${at.left}px`;
    pop.style.top = at.top === undefined ? "" : `${at.top}px`;
    pop.style.bottom = at.bottom === undefined ? "" : `${at.bottom}px`;
    if (at.maxHeight !== undefined) pop.style.maxHeight = `${at.maxHeight}px`;
  }

  // Opens at +anchor+ (open already: drawn anew there).
  function open(anchor) {
    const data = summary(anchor);
    if (!data) return;
    openFor = session();
    if (expands && opener && opener !== anchor) opener.setAttribute("aria-expanded", "false");
    opener = anchor;
    if (expands) anchor.setAttribute("aria-expanded", "true");
    show(data, true);
    pop.hidden = false;
    place(anchor);
    onOpen();
  }

  // A closed popover is empty, so each open draws a fresh form (unsent
  // edits are gone). Focus that was in it (or +refocus+: Esc) goes back to
  // its opener.
  function close({ refocus = false } = {}) {
    const had = refocus || pop.contains(doc.activeElement);
    const back = opener;
    if (expands) back?.setAttribute("aria-expanded", "false");
    pop.hidden = true;
    openFor = null;
    opener = null;
    onClose();
    render(nothing, pop);
    if (had && back?.isConnected) back.focus?.();
  }

  function isOpen() { return !pop.hidden; }

  // A new summary (a command_ran, a re-read): the caller redraws the open
  // form; another session closes it.
  function refresh() {
    if (!isOpen()) return;
    const data = summary();
    if (!data || session() !== openFor) return close();
    show(data, false);
  }

  // A popover's own re-placement (its content grew or shrank).
  function replace() {
    if (isOpen() && opener?.isConnected) place(opener);
  }

  // The click goes on to the document: another chip's popover (or the
  // context popover) open meanwhile closes there. This one's own closer
  // leaves its chip's click alone.
  el.addEventListener("click", (e) => {
    const anchor = e.target.closest(anchorSel);
    if (!anchor) return;
    if (isOpen()) close();
    else open(anchor);
  });
  pop.addEventListener("submit", (e) => {
    e.preventDefault();
    onSubmit(e.target);
  });
  let ownClick = null;
  pop.addEventListener("click", (e) => {
    ownClick = e;
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "close") close();
    else if (act) onAct(act);
  });
  // A click the popover itself had is inside, even when its act redrew the
  // clicked button away (Cap swapped for its field): by the time it reaches
  // the document that button is no longer in the popover.
  doc.addEventListener("click", (e) => {
    if (isOpen() && e !== ownClick && !pop.contains(e.target) && !e.target.closest?.(openers)) close();
  });
  doc.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && isOpen()) close({ refocus: true });
  });

  return { pop, open, close, refresh, isOpen, replace, opener: () => opener };
}
