// The Pages list, #/pages (docs/pages.md): the one home of pages, opened by
// the top bar's pages pill (pages_wiring.js). In place of the session area,
// as a page is: Back, "Pages", and a card per page (its title, "ran 2 min
// ago", "failed 1 h ago" or "never ran") in /api/pages's order; a tap
// opens #/p/NAME. "Loading…" until the first answer, "No pages." when there
// is none. It draws the page's list (pages_model.js) and reads it again
// each time it opens. Also the list's hash, so views.js reads it where it
// reads a page's (a new module: page_route.js takes no new export).
//
// Made only with the pages capability (pages_wiring.js). +root+: #pagesList
// (null on an older cached index.html: nothing drawn). +model+:
// pages_model.js's. +open(name)+: views.js openPage. +back()+: views.js
// closePagesList.
import { html, nothing, render } from "./vendor/lit-html.js";
import { relativeTime } from "./format.js";

export const PAGES_HASH = "#/pages";

// Whether +hash+ is the Pages list for this viewer: never on a
// participant's page and never without the pages capability.
export function pagesListOpen(hash, { participant = null, canPages = false } = {}) {
  return !participant && !!canPages && hash === PAGES_HASH;
}

// A card's second line.
export function pageCardMeta(page, now = Date.now()) {
  if (page.state === "failed" && page.failed_at) return `failed ${relativeTime(page.failed_at, now)}`;
  if (page.ran_at) return `ran ${relativeTime(page.ran_at, now)}`;
  return "never ran";
}

// +state+: the model's ({pages, loaded}).
export function pagesListTemplate(state, { open, back, now = Date.now() }) {
  let body;
  if (!state.loaded) body = html`<div class="pg-note">Loading…</div>`;
  else if (!state.pages.length) body = html`<div class="pg-note">No pages.</div>`;
  else {
    body = html`<div class="pl-cards" role="list">${state.pages.map((page) => html`<button type="button" class="pg-card"
      role="listitem" data-page=${page.name} @click=${() => open(page.name)}><b>${page.title || page.name}</b><span
      class="pg-card-meta">${pageCardMeta(page, now)}</span></button>`)}</div>`;
  }
  return html`<div class="pg-head">
      <button type="button" class="pg-back ghost" @click=${back}>← Back</button>
      <h1 class="pg-title">Pages</h1>
    </div>${body}`;
}

export function createPagesList({ root, model, open, back, now = () => Date.now() }) {
  let shown = false;

  function draw() {
    if (!root) return;
    render(shown ? pagesListTemplate(model.state(), { open, back, now: now() }) : nothing, root);
  }

  model.subscribe(() => shown && draw());

  return {
    open() {
      if (!shown) {
        shown = true;
        draw();
      }
      model.load();
    },
    close() {
      if (!shown) return;
      shown = false;
      draw();
    },
  };
}
