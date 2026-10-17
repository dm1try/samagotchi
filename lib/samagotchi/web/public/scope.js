// The page's scope: ?dir=<folder> shows that folder's project (`chi web` in
// a repo opens it so); no dir shows every session. The hash routes
// (#/s/<id>, #/sessions) work in either.
import { html, nothing } from "./vendor/lit-html.js";

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

// The header's scope chip: "<project> · all" in a project view (all links
// to the same place without ?dir); "all projects" otherwise, with a link
// back to the project it came from and where a new chat starts on the
// start page. +scope+: { dir, projectName, projectDir, serverDir, backDir,
// backName }; +error+: why the ?dir= folder can't be shown; +where+:
// () => { hash, search } (the page's location, read again at a click: the
// links follow an open session or the all-sessions view).
export function scopeTemplate(scope, { error = null, where = () => ({ hash: "", search: "" }) } = {}) {
  const at = where();
  const allHref = () => allScopeHref(where().hash, scope.dir, where().search);
  const all = html`<a class="scope-all" href=${allScopeHref(at.hash, scope.dir, at.search)} title=${"Sessions of every project"} @click=${(e) => { e.currentTarget.href = allHref(); }}>all</a>`;
  if (error) return html`<span class="scope-name error" title=${error}>folder not found</span>${all}`;
  if (scope.projectName) return html`<span class="scope-name" title=${`Sessions of ${scope.projectDir}`}>${scope.projectName}</span>${all}`;
  const dir = scope.dir || scope.serverDir;
  const backHref = () => projectScopeHref(scope.backDir, where().hash, where().search);
  const back = scope.backName
    ? html`<a class="scope-all scope-back" href=${projectScopeHref(scope.backDir, at.hash, at.search)} title=${`Sessions of ${scope.backName} only`} @click=${(e) => { e.currentTarget.href = backHref(); }}>← ${scope.backName}</a>`
    : nothing;
  const newChat = dir ? html`<span class="scope-where" title=${`New sessions start in ${dir}`}>new session in<span class="path"><bdi>${dir}</bdi></span></span>` : nothing;
  return html`<span class="scope-name" title="Sessions of every project">all projects</span>${back}${newChat}`;
}
