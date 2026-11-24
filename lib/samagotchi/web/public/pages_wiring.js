// The pages capability's parts on the main page, wired in one place so
// app.js keeps one call (docs/pages.md, docs/internals/pages.md): the page's
// list of pages (pages_model.js), the page view at #/p/NAME (page_view.js),
// All sessions' Pages group (pages_group.js) and the #/p/ links opening a
// page in place (page_links.js). Null without the capability (the
// null-control rule): then nothing of pages is made and nothing is read.
//
// +viewer+: viewer.js. +$+: the page's querySelector. +api+: data.js api.
// +toast(text)+, +copyText(text)+: the page's. +turnRoots()+: the roots an
// answer's links are in. +views()+: views.js's (made after this, so a
// getter): openPage, closePage, leavePage, pageBackLabel.
import { createPagesModel } from "./pages_model.js";
import { createPageView } from "./page_view.js";
import { createPagesGroup } from "./pages_group.js";
import { installPageLinks } from "./page_links.js";

export function wirePages({ viewer, $, api, toast, copyText, turnRoots, views, win = window }) {
  if (!viewer.can("pages")) return null;
  const model = createPagesModel({ api });
  const pageView = createPageView({
    root: $("#pageView"), api, toast, copyText, back: () => views().closePage(), gone: () => views().leavePage(),
    backLabel: () => views().pageBackLabel(), phone: () => !!win.matchMedia?.("(max-width: 600px)").matches,
  });
  const open = (name) => views().openPage(name);
  const group = createPagesGroup({ root: $("#pagesGroup"), filterEl: $("#filter"), api, open, model });
  installPageLinks([...turnRoots(), $("#pageView")], { open });
  return {
    pageView,
    // All sessions just opened: the group reads the list.
    allViewOpened: () => group.load(),
  };
}
