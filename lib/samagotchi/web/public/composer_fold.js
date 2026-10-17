// The session's composer can fold away for room to read (the info bar under
// it stays and becomes the page's bottom edge). The user's own fold or
// unfold is saved per browser (chi_composer_collapsed); an archived
// session opens folded for that visit; the page expanding it by itself (a
// focus, a restored line, a quote) opens it for the visit only. A visit is
// one select() call.

export const COMPOSER_FOLD_KEY = "chi_composer_collapsed";

// Whether the composer is folded: the saved choice or an archived visit,
// unless this visit opened it.
export function composerFolded({ saved, archivedVisit, visitOpen }) {
  if (visitOpen) return false;
  return !!saved || !!archivedVisit;
}

// The composer's grip while it is the fold's handle. Expanded it only says
// how to resize and hide; folded it is drawn as the handle on the info
// bar's top edge, pulled up or clicked to open, and marked: `draft` (the
// box holds text or images: folding never clears them: the accent),
// `waiting` (the attention colour: the session waits on the user, and its
// card may not take the focus while a draft is there). The title carries
// the words.
// @return {title, folded, draft, waiting}
export function foldHandle({ folded, draft, waiting }) {
  if (!folded) {
    return { title: "Drag to make the message box taller, down to hide it (double-click resets)", folded: false, draft: false, waiting: false };
  }
  const marked = !!draft;
  let title = "Pull up or click to write";
  if (marked) title += " · a draft is in it";
  if (waiting) title += " · the session waits on you";
  return { title, folded: true, draft: marked, waiting: !!waiting };
}

// Whether a key pressed on the page (the composer folded) opens it and
// lands in the message box: a printable character, not Space (it scrolls,
// and the turn marker and the stage headline use it), no Ctrl/Meta/Alt,
// not taken already, not mid-composition, and not while the focus is in a
// field of its own (an input, textarea, select or contenteditable), the
// all-sessions view or the lightbox is open. An IME's first key arrives as
// "Process": it doesn't open it.
// +active+: document.activeElement.
export function opensOnKey(e, { active, allView, lightbox }) {
  if (!e || e.defaultPrevented || e.isComposing) return false;
  if (e.ctrlKey || e.metaKey || e.altKey) return false;
  const key = typeof e.key === "string" ? e.key : "";
  if ([...key].length !== 1 || key === " ") return false;
  if (allView || lightbox) return false;
  return !editable(active);
}

function editable(el) {
  if (!el) return false;
  if (el.isContentEditable) return true;
  const tag = (el.tagName || "").toUpperCase();
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
}
