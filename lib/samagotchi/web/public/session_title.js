import { normalize } from "./format.js";

// Where the open session's title shows: once on screen. Its strip card says
// it when the strip is shown and has an `.active` card for it; otherwise
// (strip hidden, an older session without a card, a delegate folded into its
// parent's card) the top bar does. The All sessions view shows none.
// Plain rules, no DOM; app.js wires them (updateSessionTitle).

const TAB_TITLE_CHARS = 40;

// The top bar's text, or "" when it shows no title.
export function topBarTitle({ title, cardShown, stripHidden, allView }) {
  const text = normalize(title);
  if (!text || allView) return "";
  if (cardShown && !stripHidden) return "";
  return text;
}

// The browser tab: "<title, cut at 40> · <base>", the base alone without a
// session title (base = "Chi · <project>" or "Chi").
export function tabTitle({ title, base }) {
  const text = normalize(title);
  if (!text) return base;
  const cut = text.length > TAB_TITLE_CHARS ? `${text.slice(0, TAB_TITLE_CHARS)}…` : text;
  return `${cut} · ${base}`;
}
