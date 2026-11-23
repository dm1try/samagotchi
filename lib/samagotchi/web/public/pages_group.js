// All sessions' Pages group (decision D1 A, docs/pages.md): above the
// session cards, one row of page cards that scrolls sideways (it never takes
// more than a row of a phone's first screen), each with its title and "ran 2
// min ago", "failed 1 h ago" or "never ran"; a tap opens the page. A
// "Sessions" heading sits over the session cards while the group shows. It
// is read when All sessions opens (GET /api/pages) and filtered by the
// search field (#filter) by name and title; with no page, or none the search
// matches, the group and its heading are not there. Not live: a page made
// meanwhile shows the next time All sessions opens.
//
// Made only with the pages capability (app.js). +root+: #pagesGroup.
// +filterEl+: #filter. +api+: data.js api. +open(name)+: views.js openPage.
import { html, nothing, render } from "./vendor/lit-html.js";
import { createLatest } from "./latest.js";
import { relativeTime } from "./format.js";

// A card's second line.
export function pageCardMeta(page, now = Date.now()) {
  if (page.state === "failed" && page.failed_at) return `failed ${relativeTime(page.failed_at, now)}`;
  if (page.ran_at) return `ran ${relativeTime(page.ran_at, now)}`;
  return "never ran";
}

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

export function createPagesGroup({ root, filterEl, api, open, now = () => Date.now() }) {
  let pages = [];
  const latest = createLatest();

  function draw() {
    const shown = filterPages(pages, filterEl?.value || "");
    root.hidden = !shown.length;
    render(pagesGroupTemplate(shown, { open, now: now() }), root);
  }

  async function load() {
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

  filterEl?.addEventListener("input", draw);
  draw();
  return { load, redraw: draw };
}
