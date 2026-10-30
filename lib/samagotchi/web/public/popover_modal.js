// What every popover does alike (chip_popover.js' shell, and the ones that
// place themselves: context_chips.js, families_view.js' family and chain
// lists): a modal dialog (modalDialog: aria-modal, Tab and Shift+Tab wrap
// inside it, a Tab from outside goes in), its opener's aria-expanded, Esc
// closes it and focus goes back to the opener (focusBack). Their :hover
// tints are gated on (hover:hover) in index.html, so a tap on a phone
// leaves none behind. A module of its own: its exports are new (see
// docs/internals/web-frontend.md, "New exports go in new modules").
//
// Not popovers in this sense, so not modal: model_picker.js and
// command_list.js (a combobox's listbox: the focus stays in its input),
// ref_menu.js (a menu: arrow keys, Tab leaves it), update_sheet.js (a
// native <dialog> shown modal: the browser holds the focus).

const FOCUSABLE = "button, [href], input, select, textarea, [tabindex]:not([tabindex='-1'])";

// The elements Tab reaches in +root+, in order (none hidden or disabled).
export function tabStops(root) {
  return [...root.querySelectorAll(FOCUSABLE)].filter((e) => !e.disabled && !e.closest("[hidden]") && e.tabIndex >= 0);
}

// Tab past +root+'s last stop goes to its first, Shift+Tab before the first
// to the last; a Tab from outside (the opener kept the focus, or a redraw
// dropped it) goes in. +e+: the Tab's keydown.
export function holdFocus(e, root, doc = document) {
  const stops = tabStops(root);
  if (!stops.length) return;
  const first = stops[0];
  const last = stops[stops.length - 1];
  const at = doc.activeElement;
  let to = null;
  if (!root.contains(at)) to = e.shiftKey ? last : first;
  else if (e.shiftKey && at === first) to = last;
  else if (!e.shiftKey && at === last) to = first;
  if (!to) return;
  e.preventDefault();
  to.focus();
}

// +pop+ as every popover is: a dialog (named +label+) that holds the focus
// while +isOpen()+ and on the page (aria-modal; Tab and Shift+Tab wrap inside it).
export function modalDialog(pop, { label = null, isOpen, doc = document }) {
  pop.setAttribute("role", "dialog");
  pop.setAttribute("aria-modal", "true");
  if (label) pop.setAttribute("aria-label", label);
  doc.addEventListener("keydown", (e) => {
    if (e.key === "Tab" && isOpen() && pop.isConnected) holdFocus(e, pop, doc);
  });
}

// Called before +pop+ closes: whether the focus was in it (or +refocus+:
// an Esc), and so goes back(to) its opener once it has closed.
// @return (to) => focuses +to+ when it should and still can
export function focusBack(pop, { refocus = false, doc = document } = {}) {
  const had = refocus || pop.contains(doc.activeElement);
  return (to) => { if (had && to?.isConnected) to.focus?.(); };
}
