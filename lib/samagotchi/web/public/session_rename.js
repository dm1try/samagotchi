// The title's ✎ (Rename this session): a small input over the title as it
// shows on screen (the active strip card's title row, or the top bar's),
// prefilled with the session's title ("" for none). Enter sends
// `/title TEXT` (blank: `/title --clear`) through the chips' command path
// (composer.js run: the reply shows as a command bubble, a refusal in the
// failed bubble, the composer untouched); leaving the field saves the same
// way (a phone's keyboard dismissed keeps what was typed). Esc, opening
// another session, or the title leaving the screen closes it unsent. The
// cards follow from the saved file (the hub's scan), as for any title.
//
// The input lives at the end of body, fixed over its anchor's rect: the
// strip draws every card from new nodes on each session event, so an input
// inside a card would be thrown away mid-typing.
import { normalize } from "./format.js";

// As long as a title may be (TitleCommand::LIMIT).
const TITLE_CHARS = 80;
// The narrowest field (a short title still gets room to type), the gap kept
// to the window's right edge, and the lowest field.
const MIN_WIDTH_PX = 192;
const EDGE_PX = 16;
const MIN_HEIGHT_PX = 24;

// The line the input's +text+ sends.
export function titleLine(text) {
  const title = normalize(text);
  return title ? `/title ${title}` : "/title --clear";
}

// Where the input goes over +rect+ (the anchor's) in a window +innerWidth+
// wide: the anchor's box, at least MIN_WIDTH_PX wide and MIN_HEIGHT_PX tall
// (centred on it), never closer than EDGE_PX to the right edge.
export function inputBox(rect, innerWidth) {
  const height = Math.max(rect.height, MIN_HEIGHT_PX);
  const room = Math.max(innerWidth - rect.left - EDGE_PX, 0);
  const width = Math.min(Math.max(rect.width, MIN_WIDTH_PX), room);
  return { left: rect.left, top: rect.top + (rect.height - height) / 2, width, height };
}

// Whether a card's title row +rect+ has left its scroller's +clip+ (a
// phone's strip swiped sideways: a fixed input isn't clipped by its overflow).
export function outsideClip(rect, clip) {
  return rect.left < clip.left - 1 || rect.right > clip.right + 1 || rect.bottom < clip.top || rect.top > clip.bottom;
}

// @param doc the document (the input goes at the end of its body)
// @param anchor () => the title row on screen for the open session (its ✎
//   inside), or null when none shows
// @param session () => the open session's id, or null
// @param titleOf (id) => that session's title, or null
// @param shownTitle (id) => the title as the page shows it (the
//   placeholder: an untitled chain link shows its chain's), or ""
// @param closePopovers () => close the family and chain popovers (their Esc
//   would close the popover and refocus its chip: a blur, so a save)
// @param onClose () => after the input closed (a held strip catches up)
// @param run (line) => composer.js run's promise
export function createRename({ doc = document, anchor, session, titleOf, shownTitle = () => "", closePopovers = () => {}, onClose = () => {}, run }) {
  let input = null;
  let openFor = null;
  const win = doc.defaultView;

  // Removing the input blurs it: input is cleared first, so that blur sends
  // nothing (a close is always unsent).
  function close() {
    if (!input) return;
    const el = input;
    input = null;
    openFor = null;
    el.remove();
    onClose();
  }

  // Enter's and blur's: once (closing it blurs it again), and only to the
  // session it was opened for.
  function submit() {
    if (!input) return null;
    const id = openFor;
    const before = normalize(input.dataset.before);
    const text = input.value;
    close();
    if (!id || session() !== id || normalize(text) === before) return null;
    return run(titleLine(text));
  }

  // Over the anchor's title row, in its title's font size (CSS keeps a
  // phone's at 16px: under that, iOS zooms the page on focus).
  function place(a) {
    const box = inputBox(a.getBoundingClientRect(), win.innerWidth);
    Object.assign(input.style, {
      left: `${box.left}px`, top: `${box.top}px`, width: `${box.width}px`, height: `${box.height}px`,
    });
    const text = a.firstElementChild;
    const size = text && win.getComputedStyle ? win.getComputedStyle(text).fontSize : "";
    if (size) input.style.setProperty("--rename-font", size);
    // The top bar's row runs to the bell: CSS caps the input there, so it
    // reads as the title edited, not a field across the bar.
    input.classList.toggle("over-bar", !a.closest("#topStrip"));
  }

  // A card's row out of the strip's sight (swiped sideways).
  function clipped(a) {
    const strip = a.closest("#topStrip");
    return !!strip && outsideClip(a.getBoundingClientRect(), strip.getBoundingClientRect());
  }

  function open() {
    const id = session();
    if (input || !id) return;
    const a = anchor();
    if (!a) return;
    closePopovers();
    // The active card may sit scrolled sideways out of a phone's strip.
    a.scrollIntoView?.({ block: "nearest", inline: "nearest" });
    const el = doc.createElement("input");
    el.type = "text";
    el.className = "rename-input";
    el.maxLength = TITLE_CHARS;
    el.placeholder = normalize(shownTitle(id)) || "Session title";
    el.setAttribute("aria-label", "Session title (Enter saves, empty clears, Esc cancels)");
    el.value = titleOf(id) || "";
    el.dataset.before = el.value;
    el.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        submit();
      } else if (e.key === "Escape") {
        e.preventDefault();
        close();
        // The ✎ as drawn now (the strip may have drawn its card again).
        anchor()?.querySelector("button")?.focus();
      }
    });
    el.addEventListener("blur", () => submit());
    input = el;
    openFor = id;
    doc.body.append(el);
    place(a);
    el.focus();
    el.select();
  }

  // The title moved (a strip draw, the strip hidden or shown, the page
  // scrolled or resized): the input follows it. With no title on screen (the
  // All sessions view, the title gone, the card swiped away) it closes unsent.
  function reposition() {
    if (!input) return;
    const a = anchor();
    if (!a || clipped(a)) close();
    else place(a);
  }

  // The page shows +id+ (app.js updateSessionTitle): an input opened for
  // another session closes.
  function follow(id) {
    if (input && openFor !== id) close();
  }

  return { open, close, follow, reposition, isOpen: () => !!input };
}
