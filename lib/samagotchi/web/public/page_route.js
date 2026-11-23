// A page's place in the URL: #/p/NAME (docs/pages.md). Pure, so the hash
// rules are testable where app.js is not. hashIntent (hash_intent.js) is
// not changed: views.js reads a page hash before the session intent, and
// a page hash is "keep" to it.

const PAGE_HASH = /^#\/p\/([^/?#]+)$/;

export function pageHash(name) {
  return `#/p/${name}`;
}

// The NAME in +hash+ as it is written (never decoded: a name that isn't one
// opens the view's "no such page"), or null when it isn't a page hash.
export function pageNameFromHash(hash = "") {
  const m = PAGE_HASH.exec(hash || "");
  return m ? m[1] : null;
}

// The page +hash+ opens for this viewer, or null: never on a participant's
// page and never without the pages capability (the null-control rule).
export function openPageName(hash, { participant = null, canPages = false } = {}) {
  if (participant || !canPages) return null;
  return pageNameFromHash(hash);
}
