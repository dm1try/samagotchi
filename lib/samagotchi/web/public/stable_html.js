// A block redrawn every tick (the info bar, once a second while a turn
// runs) keeps its nodes: +html+ is written only when it changed, so a
// shown tooltip stays up and a press on one of its buttons isn't lost to a
// rewrite between mousedown and mouseup. +live+ ({selector: text}) names
// the parts that change every tick (a running clock): +html+ carries them
// empty and only their text is set, so a tick alone rewrites nothing else.
const shown = new WeakMap();

export function renderStable(el, html, live = {}) {
  if (shown.get(el) !== html) {
    el.innerHTML = html;
    shown.set(el, html);
  }
  for (const [selector, text] of Object.entries(live)) {
    const part = el.querySelector(selector);
    if (part && part.textContent !== text) part.textContent = text;
  }
}
