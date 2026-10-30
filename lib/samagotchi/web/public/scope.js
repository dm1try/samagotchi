// The page's scope: ?dir=<folder> shows that folder's project (`chi web` in
// a repo opens it so); ?scope=all shows every session. A bare page is chi
// web's start folder's project when that folder is in a repo (the server
// names it in data-scope-dir; web.start_dir, --start-dir), else every
// session. ?dir= beats ?scope=all. The hash routes (#/s/<id>, #/sessions)
// work in each.
import { html, nothing } from "./vendor/lit-html.js";

// The ?dir= folder in a location.search string, or null.
export function scopeDir(search) {
  const dir = new URLSearchParams(search || "").get("dir");
  return dir && dir.trim() ? dir : null;
}

// The same place in the all view: ?scope=all without ?dir (a bare page
// may be the start folder's project), keeping the hash. +fromDir+ (the
// project view's folder) rides along as ?from=, so the all view can link
// back to it.
export function allScopeHref(hash, fromDir = null) {
  const params = ["scope=all", fromDir ? `from=${dirParam(fromDir)}` : ""].filter(Boolean);
  return `/?${params.join("&")}${hash || ""}`;
}

// A folder's project view, keeping the hash.
export function projectScopeHref(dir, hash) {
  return `/?dir=${dirParam(dir)}${hash || ""}`;
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

// The header's project chip opens the picker. The "all" link remains the
// direct way to every session from a project view. +scope+: { dir,
// projectName, projectDir, serverDir, backDir, backName }; +error+: why
// the ?dir= folder can't be shown; +where+: () => { hash } (the
// page's location, read again at a click).
export function scopeTemplate(scope, { error = null, where = () => ({ hash: "" }) } = {}) {
  const at = where();
  const allHref = () => allScopeHref(where().hash, scope.dir);
  const all = html`<a class="scope-all" href=${allScopeHref(at.hash, scope.dir)} title=${"Sessions of every project"} @click=${(e) => { e.currentTarget.href = allHref(); }}>all</a>`;
  if (error) return html`<button id="scopePick" class="scope-name error" type="button" aria-haspopup="dialog" title=${error}>folder not found</button>${all}`;
  if (scope.projectName) return html`<button id="scopePick" class="scope-name" type="button" aria-haspopup="dialog" title=${`Sessions of ${scope.projectDir}`}>${scope.projectName}</button>${all}`;
  const dir = scope.dir || scope.serverDir;
  const backHref = () => projectScopeHref(scope.backDir, where().hash);
  const back = scope.backName
    ? html`<a class="scope-all scope-back" href=${projectScopeHref(scope.backDir, at.hash)} title=${`Sessions of ${scope.backName} only`} @click=${(e) => { e.currentTarget.href = backHref(); }}>← ${scope.backName}</a>`
    : nothing;
  const newSession = dir ? html`<span class="scope-where" title=${`New sessions start in ${dir}`}>new session in<span class="path"><bdi>${dir}</bdi></span></span>` : nothing;
  return html`<button id="scopePick" class="scope-name" type="button" aria-haspopup="dialog" title="Sessions of every project">all projects</button>${back}${newSession}`;
}
