// The session's objectives above the conversation: the fold's current state
// (Objectives.view), from the session read (seed) and live from the stream's
// objectives_updated (update). No list: the element stays hidden, nothing on
// the page. A page-lifetime factory drawn with lit, so a focus survives a
// redraw. A module of its own: static JS is cached at unversioned URLs.
import { html, nothing, render } from "./vendor/lit-html.js";
import { DONE, progress, stripItems } from "./objectives_model.js";

// @param el the strip's element (index.html #objectivesStrip)
export function createObjectivesStrip({ el }) {
  let list = null;

  function chip(item) {
    return html`<span class=${`obj-chip ${item.status}`} title=${item.text}><span class="obj-id">${item.id}</span><span class="obj-text">${item.status === DONE ? "✓ " : ""}${item.text}</span></span>`;
  }

  function draw() {
    const items = stripItems(list);
    el.hidden = !list;
    if (!list) {
      render(nothing, el);
      return;
    }
    const { done, total } = progress(list);
    render(html`<div class="obj-strip" role="group" aria-label="Objectives">
      <div class="obj-chips">${items.map(chip)}</div>
      <span class="obj-count">${done}/${total}</span>
    </div>`, el);
  }

  const take = (view) => {
    list = view && Array.isArray(view.items) ? view : null;
    draw();
  };

  return {
    // A session read's list; none clears it.
    seed: take,
    // The stream's objectives_updated.
    update: take,
    // No session open.
    reset: () => take(null),
    list: () => list,
  };
}
