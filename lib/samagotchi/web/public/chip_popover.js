// The popover shell a session-bar chip opens (llm_context_chip.js,
// level_chip.js): a div.ctx-popover on the body, placed at the chip,
// opened by a click on it (delegated on +el+), closed by a second click,
// its × (data-act="close"), a click outside or Esc. Another session's
// summary (refresh) closes it. What it draws, and what a Set or another
// data-act does, is the caller's.

import { nothing, render } from "./vendor/lit-html.js";

const EDGE = 16;
const GAP = 8;

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

// id, className: the popover's; width: its widest (px); el: where the chip
// is drawn; anchor: the chip's selector; summary(): what the form is drawn
// from (null: nothing opens); session(): the open session's id.
// show(data, opening): draws the form into the popover (opening: a fresh
// open, else a refresh with a newer summary); onClose(): the caller forgets
// its open state; onSubmit(form); onAct(name): a data-act other than close.
// @return {pop, close, refresh, isOpen}
export function createChipPopover({ id, className, width: widest, el, anchor: anchorSel, summary,
                                    session = () => null, show, onClose = () => {}, onSubmit, onAct = () => {},
                                    doc = document, win = window }) {
  const pop = doc.createElement("div");
  pop.id = id;
  pop.className = className;
  pop.setAttribute("role", "dialog");
  pop.hidden = true;
  doc.body.appendChild(pop);
  // The session the open form is for.
  let openFor = null;

  function place(anchor) {
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

  function open(anchor) {
    const data = summary();
    if (!data) return;
    openFor = session();
    show(data, true);
    pop.hidden = false;
    place(anchor);
  }

  // A closed popover is empty, so each open draws a fresh form (unsent
  // edits are gone).
  function close() {
    pop.hidden = true;
    openFor = null;
    onClose();
    render(nothing, pop);
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

  el.addEventListener("click", (e) => {
    const anchor = e.target.closest(anchorSel);
    if (!anchor) return;
    e.stopPropagation();
    if (isOpen()) close();
    else open(anchor);
  });
  pop.addEventListener("submit", (e) => {
    e.preventDefault();
    onSubmit(e.target);
  });
  pop.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "close") close();
    else if (act) onAct(act);
  });
  doc.addEventListener("click", (e) => {
    if (isOpen() && !pop.contains(e.target) && !e.target.closest?.(anchorSel)) close();
  });
  doc.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && isOpen()) close();
  });

  return { pop, close, refresh, isOpen };
}
