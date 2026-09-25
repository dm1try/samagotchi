// The page's scope: ?dir=<folder> shows that folder's project (`chi web` in
// a repo opens it so); no dir shows every session. The hash routes
// (#/s/<id>, #/sessions) work in either.

// The ?dir= folder in a location.search string, or null.
export function scopeDir(search) {
  const dir = new URLSearchParams(search || "").get("dir");
  return dir && dir.trim() ? dir : null;
}

// The same place in the all view: the page without ?dir, keeping the hash.
export function allScopeHref(hash) {
  return `/${hash || ""}`;
}

// The folder a card shows when the scope doesn't make it obvious: every
// card in the all view, and in a project view a card from another folder
// than the project's own (a worktree). "" when it is obvious.
export function cardFolder(workingDirectory, projectName) {
  const folder = String(workingDirectory || "").replace(/\/+$/, "").split("/").pop() || "";
  if (!folder) return "";
  return folder === projectName ? "" : folder;
}
