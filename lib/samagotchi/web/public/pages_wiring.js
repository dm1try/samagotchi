// The pages capability's parts on the main page, wired in one place so
// app.js keeps one call (docs/pages.md, docs/internals/pages.md): the page's
// list of pages (pages_model.js), the top bar's pages pill (#pagesBtn), the
// Pages list at #/pages (pages_list.js), the page view at #/p/NAME
// (page_view.js) and the #/p/ links opening a page in place (page_links.js).
// Null without the capability (the null-control rule): the pill stays
// withheld, nothing of pages is made and nothing is read.
//
// The list is read once at boot (one request: a view opened at boot shares
// it), again when All sessions, the Pages list or a page opens, after a
// Delete, and live: on the hub's `pages` event (a script made or removed)
// and on every reconnect's snapshot (the hub has no replay; the first
// snapshot is the boot's, which the boot read covers). The pill shows while
// the list has a page, in every view; a failed read keeps it as it was.
//
// +viewer+: viewer.js. +$+: the page's querySelector. +api+: data.js api.
// +toast(text)+, +copyText(text)+: the page's. +turnRoots()+: the roots an
// answer's links are in. +views()+: views.js's (made after this, so a
// getter): openPage, closePage, leavePage, pageBackLabel, openPagesList,
// closePagesList.
import { createPagesModel } from "./pages_model.js";
import { createPageView } from "./page_view.js";
import { createPagesList } from "./pages_list.js";
import { installPageLinks } from "./page_links.js";

export function wirePages({ viewer, $, api, toast, copyText, turnRoots, views, win = window }) {
  const pill = viewer.control($("#pagesBtn"), "pages");
  if (!viewer.can("pages")) return null;
  const model = createPagesModel({ api });
  const open = (name) => views().openPage(name);
  const view = createPageView({
    root: $("#pageView"), api, toast, copyText, back: () => views().closePage(),
    // Gone (a Delete, or no such page on Refresh): the list is read again, so the pill hides with the last page.
    gone: () => { model.reload(); views().leavePage(); },
    backLabel: () => views().pageBackLabel(), phone: () => !!win.matchMedia?.("(max-width: 600px)").matches,
  });
  // A page opened reads the list too (views.js calls open again while it is open: once per page).
  const pageView = { ...view, open: (name) => { if (view.name() !== name) model.load(); return view.open(name); } };
  const pagesList = createPagesList({ root: $("#pagesList"), model, open, back: () => views().closePagesList?.() });
  installPageLinks([...turnRoots(), $("#pageView")], { open });

  model.subscribe((state) => {
    if (pill) pill.hidden = !state.pages.length;
  });
  pill?.addEventListener("click", () => views().openPagesList?.());
  model.load();

  let snapshots = 0;
  return {
    pageView,
    pagesList,
    // All sessions just opened.
    allViewOpened: () => model.load(),
    // The hub's `pages` event.
    changed: () => model.reload(),
    // A hub snapshot: every one after the first is a reconnect.
    snapshot: () => {
      snapshots += 1;
      if (snapshots > 1) model.reload();
    },
  };
}
