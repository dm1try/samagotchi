// The page's scope: ?dir=<folder> shows that folder's project (`chi web` in
// a repo opens it so); no dir shows every session. The hash routes
// (#/s/<id>, #/sessions) work in either.

// The ?dir= folder in a location.search string, or null.
export function scopeDir(search) {
  const dir = new URLSearchParams(search || "").get("dir");
  return dir && dir.trim() ? dir : null;
}

// The same place in the all view: the page without ?dir, keeping the hash.
// +fromDir+ (the project view's folder) rides along as ?from=, so the all
// view can link back to it. +search+ (the page's location.search) keeps
// its ?view= (VIEW_PARAM) on the new page.
export function allScopeHref(hash, fromDir = null, search = "") {
  const params = [fromDir ? `from=${dirParam(fromDir)}` : "", viewParam(search)].filter(Boolean);
  return `/${params.length ? `?${params.join("&")}` : ""}${hash || ""}`;
}

// A folder's project view, keeping the hash and +search+'s ?view=.
export function projectScopeHref(dir, hash, search = "") {
  const view = viewParam(search);
  return `/?dir=${dirParam(dir)}${view ? `&${view}` : ""}${hash || ""}`;
}

// "view=<v>" from a location.search string, or "" without one.
function viewParam(search) {
  const view = new URLSearchParams(search || "").get("view");
  return view ? `view=${encodeURIComponent(view)}` : "";
}

// A folder for the query string, its slashes left readable (as chi web
// prints ?dir=).
function dirParam(dir) {
  return encodeURIComponent(dir).replace(/%2F/g, "/");
}

// The folder a card shows when the scope doesn't make it obvious: every
// card in the all view, and in a project view a card from another folder
// than the project's own (a worktree). "" when it is obvious.
export function cardFolder(workingDirectory, projectName) {
  const folder = String(workingDirectory || "").replace(/\/+$/, "").split("/").pop() || "";
  if (!folder) return "";
  return folder === projectName ? "" : folder;
}
