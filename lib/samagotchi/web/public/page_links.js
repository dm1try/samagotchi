// A #/p/NAME link (in chi's answer, or on a page) opens the page in place
// (docs/pages.md): the sanitiser gives an answer's links target=_blank, so
// without this a page link would open a new tab (and leave the iPhone's Home
// Screen app for Safari). One delegated click handler per root, for anchors
// whose href starts with #/p/: a plain left click (button 0, no modifier
// key, not a ref link) opens the view and stops the new tab; a modified or
// middle click keeps the browser's own way. Other in-page links are left as
// they are. Installed only with the pages capability (app.js).
import { pageNameFromHash } from "./page_route.js";

// The page a click on +event+ asks for, or null when it isn't one this
// handler takes.
export function pageLinkTarget(event) {
  if (event.defaultPrevented || event.button !== 0) return null;
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return null;
  const link = event.target?.closest?.("a[href]");
  if (!link || link.hasAttribute("data-ref-kind")) return null;
  const href = link.getAttribute("href") || "";
  return href.startsWith("#/p/") ? pageNameFromHash(href) : null;
}

// +roots()+: the elements to listen on (the turn roots, the page view).
// +open(name)+: views.js openPage.
export function installPageLinks(roots, { open }) {
  for (const root of roots) {
    root?.addEventListener("click", (event) => {
      const name = pageLinkTarget(event);
      if (!name) return;
      event.preventDefault();
      open(name);
    });
  }
}
