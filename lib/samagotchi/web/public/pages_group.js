// All sessions' former Pages group: KEPT for an older cached app.js until
// the next release (the mixed-cache rule, docs/internals/web-frontend.md):
// remove after 0.189.0, with index.html's inert #pagesGroup and pages.css's
// group rules. Pages have their own way in now: the top bar's pages pill
// and the Pages list (pages_list.js, pages_wiring.js); nothing new imports
// this. What it did: above the session cards, one row of page cards, read
// when All sessions opened (GET /api/pages) and filtered by the search
// field (#filter), under a "Pages" heading and over a "Sessions" one.
//
// +root+: #pagesGroup. +filterEl+: #filter. +api+: data.js api.
// +open(name)+: views.js openPage. +model+: pages_model.js's list, read
// through instead of its own GET when given.
import { html, nothing, render } from "./vendor/lit-html.js";
import { createLatest } from "./latest.js";
import { pageCardMeta } from "./pages_list.js";

// A card's second line (the list's).
export { pageCardMeta };

// The pages the search shows: +query+ in the name or the title, any case.
export function filterPages(pages, query = "") {
  const q = query.trim().toLowerCase();
  if (!q) return pages;
  return pages.filter((page) => page.name.toLowerCase().includes(q) || String(page.title || "").toLowerCase().includes(q));
}

export function pagesGroupTemplate(pages, { open, now = Date.now() }) {
  if (!pages.length) return nothing;
  return html`<div class="pg-group-label">Pages</div>
    <div class="pg-cards" role="list">${pages.map((page) => html`<button type="button" class="pg-card" role="listitem"
      data-page=${page.name} @click=${() => open(page.name)}><b>${page.title || page.name}</b><span class="pg-card-meta">${pageCardMeta(page, now)}</span></button>`)}</div>
    <div class="pg-group-label">Sessions</div>`;
}

export function createPagesGroup({ root, filterEl, api, open, model = null, now = () => Date.now() }) {
  let pages = [];
  const latest = createLatest();

  function draw() {
    const shown = filterPages(pages, filterEl?.value || "");
    root.hidden = !shown.length;
    render(pagesGroupTemplate(shown, { open, now: now() }), root);
  }

  async function load() {
    if (model) return model.load();
    const fresh = latest.begin();
    try {
      const answer = await api("/api/pages");
      if (!fresh()) return;
      pages = Array.isArray(answer?.pages) ? answer.pages : [];
    } catch (_) {
      if (!fresh()) return;
      pages = []; // the group is a way in, not a place for errors: the page itself says them
    }
    draw();
  }

  // A failed read empties the group, as its own read does.
  model?.subscribe((state) => {
    pages = state.failed ? [] : state.pages;
    draw();
  });
  filterEl?.addEventListener("input", draw);
  draw();
  return { load, redraw: draw };
}
