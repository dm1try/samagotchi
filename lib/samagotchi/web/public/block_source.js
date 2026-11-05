// A drawn block's two faces (block_host.js): the picture, or its source. The
// source <pre> stays in the DOM right after the figure, `hidden` while the
// picture shows, so whatever reads text (a claim's walk, copy) sees what it
// always did. The DOM is the state: a Revise clone carries both with it.
//
// Pure DOM, so it runs under `node --test`. A module of its own, for
// history_reveal.js too: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.

export const DRAWN = "block-drawn";

const SHOW = "Show the source";
const HIDE = "Show the picture";

// The figure drawn for +pre+, or null.
export function figureOf(pre) {
  const before = pre?.previousElementSibling;
  return before?.classList?.contains(DRAWN) ? before : null;
}

// The source shown (and the picture hidden), or the other way round.
export function setSourceShown(figure, pre, shown) {
  pre.hidden = !shown;
  figure.classList.toggle("source", shown);
  const toggle = figure.querySelector(":scope > .block-toggle");
  if (!toggle) return;
  toggle.setAttribute("aria-pressed", shown ? "true" : "false");
  toggle.setAttribute("aria-label", shown ? HIDE : SHOW);
  toggle.title = shown ? HIDE : SHOW;
}

// A jump that lands in a drawn block's source shows it (history_reveal.js).
export function revealBlockSource(el) {
  const pre = el?.closest?.("pre[hidden]");
  const figure = figureOf(pre);
  if (figure) setSourceShown(figure, pre, true);
}
