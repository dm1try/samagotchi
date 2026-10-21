import { clip, normalize } from "./format.js";

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

// Whether the title's ✎ shows (session_rename.js): any session but a plain
// terminal's (`owner: "tui"`: it takes no commands from the web).
export function renameShown(owner) {
  return owner !== "tui";
}

// The browser tab: "<title, cut at 40> · <base>", the base alone without a
// session title (base = "Chi · <project>" or "Chi").
export function tabTitle({ title, base }) {
  const text = normalize(title);
  if (!text) return base;
  return `${clip(text, TAB_TITLE_CHARS + 1)} · ${base}`;
}
