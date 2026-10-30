// The popover shell a session-bar chip opens (settings_chip.js' ⚙ panel,
// the working set's, the start page's panels): a div.ctx-popover on the body, placed
// at the chip, opened by a click on it (delegated on +el+) or by open()
// (another opener: the working set's rail and footprint), closed by a second
// click, its × (data-act="close"), a click outside or Esc; focus goes back
// to the opener. Another session's summary (refresh) closes it. What it
// draws, and what a Set or another data-act does, is the caller's. With
// +sheet+, a window narrower than SHEET_MAX gets it as a bottom sheet. An
// open one is placed again when the window (or a phone's visual viewport:
// its keyboard) resizes.
// It is modal as every popover is (popover_modal.js).

import { nothing, render } from "./vendor/lit-html.js";
import { focusBack, modalDialog } from "./popover_modal.js";

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

// The share of a phone's window a bottom sheet takes at most (the rest
// scrolls); a caller's taller view asks for SHEET_TALL.
export const SHEET_SHARE = 0.6;
export const SHEET_TALL = 0.85;

// A bottom sheet's place in a phone's window: the window's width less its
// edges, at its bottom, at most +share+ of its height. +viewport+: the
// visual viewport ({height, offsetTop}) when it is shorter than the window
// (a phone's keyboard over the page): the sheet sits on it, sized to it.
// @return {left, bottom, width, maxHeight}
export function sheetPlace({ innerWidth, innerHeight }, { share = SHEET_SHARE, viewport = null } = {}) {
  const height = viewport ? Math.min(innerHeight, viewport.height) : innerHeight;
  const below = viewport ? Math.max(0, innerHeight - viewport.offsetTop - viewport.height) : 0;
  return { left: SHEET_EDGE, bottom: SHEET_EDGE + Math.round(below), width: innerWidth - 2 * SHEET_EDGE,
           maxHeight: Math.round(height * share) };
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
// while it is still hidden). sheetShare: the share of a phone's window the
// sheet takes at most (SHEET_SHARE). Always a modal dialog (modalDialog);
// the opener clicked (and the anchor it is placed at) carries aria-expanded
// "true" while it is open, "false" once closed: a lit-drawn chip writes
// aria-expanded="false" as a static attribute (lit leaves it to the shell).
// @return {pop, open, close, refresh, isOpen, opener}
export function createChipPopover({ id, className, width: widest, el, anchor: anchorSel, openers = anchorSel, summary,
                                    session = () => null, show, onClose = () => {}, onSubmit, onAct = () => {}, onOpen = () => {},
                                    sheet = false, label = null, sheetShare = SHEET_SHARE,
                                    doc = document, win = window }) {
  const pop = doc.createElement("div");
  pop.id = id;
  pop.className = className;
  pop.hidden = true;
  doc.body.appendChild(pop);
  // The session the open form is for, the element it is placed at, and the
  // one focus goes back to (the opener clicked).
  let openFor = null;
  let opener = null;
  let returnTo = null;
  // The openers marked aria-expanded="true" (the anchor and the one clicked).
  let marked = [];

  const expanded = (els) => {
    marked.forEach((e) => e.setAttribute("aria-expanded", "false"));
    marked = [...new Set(els)].filter(Boolean);
    marked.forEach((e) => e.setAttribute("aria-expanded", "true"));
  };

  function place(anchor) {
    const narrow = sheet && win.innerWidth < SHEET_MAX;
    pop.classList.toggle("sheet", narrow);
    if (narrow) {
      const vv = win.visualViewport;
      const at = sheetPlace({ innerWidth: win.innerWidth, innerHeight: win.innerHeight },
                            { share: sheetShare, viewport: vv ? { height: vv.height, offsetTop: vv.offsetTop } : null });
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

  // Opens at +anchor+ (open already: drawn anew there); focus goes back to
  // +from+ on close (an opener that isn't the anchor; the anchor when +from+
  // is gone or hidden by then).
  function open(anchor, { from = anchor } = {}) {
    const data = summary(anchor);
    if (!data) return;
    openFor = session();
    opener = anchor;
    returnTo = from;
    expanded([anchor, from]);
    show(data, true);
    pop.hidden = false;
    place(anchor);
    onOpen();
  }

  // A closed popover is empty, so each open draws a fresh form (unsent
  // edits are gone). Focus that was in it (or +refocus+: Esc) goes back to
  // its opener.
  function close({ refocus = false } = {}) {
    const back = focusBack(pop, { refocus, doc });
    const to = returnTo?.isConnected && !returnTo.hidden ? returnTo : opener;
    expanded([]);
    pop.hidden = true;
    openFor = null;
    opener = null;
    returnTo = null;
    onClose();
    render(nothing, pop);
    back(to);
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
  modalDialog(pop, { label, isOpen, doc });
  // A resize (a rotation, a phone's keyboard) places an open one again: a
  // sheet's height follows the window, a popover its chip.
  win.addEventListener?.("resize", replace);
  win.visualViewport?.addEventListener?.("resize", replace);

  return { pop, open, close, refresh, isOpen, replace, opener: () => opener };
}
