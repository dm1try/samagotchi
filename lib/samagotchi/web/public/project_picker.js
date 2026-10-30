// The project picker opened by the top-bar scope chip. The server supplies
// the project roots and their current/default marks; links carry the view
// without carrying a session hash into another project's list.

import { html, nothing, render } from "./vendor/lit-html.js";
import { allScopeHref, projectScopeHref } from "./scope.js";
import { createChipPopover } from "./chip_popover.js";
import { createLatest } from "./latest.js";

function homeHref(search) {
  const view = new URLSearchParams(search || "").get("view");
  return view ? `/?view=${encodeURIComponent(view)}` : "/";
}

function sessionCount(count) {
  const n = Number(count) || 0;
  return `${n} session${n === 1 ? "" : "s"}`;
}

function projectRow(row, search) {
  return html`<a class=${`project-row${row.default ? " default" : ""}${row.current ? " current" : ""}`}
    href=${row.default ? homeHref(search) : projectScopeHref(row.dir, "", search)}
    aria-current=${row.current ? "page" : nothing}>
    <span class="project-main"><span class="project-name">${row.name}</span
      >${row.default ? html`<span class="project-default">default</span>` : nothing
      }<span class="project-root">${row.root_label}</span></span>
    <span class="project-meta">${Number(row.waiting) > 0 ? html`<span class="attn">${Number(row.waiting)} waiting</span>` : nothing
      }<span class="project-count">${sessionCount(row.sessions)}</span>${row.current ? html`<span class="project-check" aria-hidden="true">✓</span>` : nothing}</span>
  </a>`;
}

// +rows+ is the API's ordered list. When there is no project scope, the
// all-projects row is current; a bad ?dir= has no current project to mark.
export function pickerTemplate({ rows = [], loading = false, error = "", search = "", currentDir = null,
                                 allCurrent = false } = {}) {
  const allHref = allScopeHref("", currentDir, search);
  return html`<div class="ctx-pop-head"><strong>Projects</strong><button type="button" class="ctx-pop-close"
      data-act="close" aria-label="Close">×</button></div>
    ${loading ? html`<div class="project-note" role="status">Loading projects…</div>` : nothing}
    ${error ? html`<div class="project-note project-error" role="alert">${error}</div>` : nothing}
    <nav class="project-list" aria-label="Projects">${rows.map((row) => projectRow(row, search))}
      <a id="projectAll" class=${`project-row project-all${allCurrent ? " current" : ""}`}
        href=${allHref} aria-current=${allCurrent ? "page" : nothing}>
        <span class="project-main"><span class="project-name">All projects</span
          ><span class="project-hint">Every session</span></span>
        ${allCurrent ? html`<span class="project-check" aria-hidden="true">✓</span>` : nothing}
      </a>
    </nav>`;
}

// +scopeError+ returns the page's current folder error, if any. +where+
// supplies the live query string so links retain ?view= without a hash.
export function createProjectPicker({ el, scope, scopeError = () => null, api, where = () => ({ search: "" }),
                                      doc = globalThis.document, win = globalThis.window }) {
  let rows = [];
  let loading = false;
  let error = "";
  // Only the newest read is drawn; a close drops the one out (latest.js).
  const latest = createLatest();

  const currentDir = () => scopeError() ? null : scope.dir || null;
  const paint = (focus = false) => {
    const failedScope = !!scopeError();
    render(pickerTemplate({
      rows, loading, error, search: where().search, currentDir: currentDir(),
      allCurrent: !scope.dir && !failedScope,
    }), shell.pop);
    if (focus) {
      const target = shell.pop.querySelector('.project-row[aria-current="page"]') ||
        shell.pop.querySelector(".project-row");
      target?.focus();
    }
  };

  async function load(focus = false) {
    const fresh = latest.begin();
    loading = true;
    error = "";
    if (shell.isOpen()) {
      paint();
      shell.replace();
    }
    try {
      // A dead ?dir (the folder-not-found chip) is left out: the list is the way out of it.
      const dir = currentDir();
      const answer = await api(`/api/projects${dir ? `?dir=${encodeURIComponent(dir)}` : ""}`);
      if (!Array.isArray(answer)) throw new Error("the server returned an invalid project list");
      if (!fresh()) return;
      rows = answer;
    } catch (e) {
      if (!fresh()) return;
      error = `Can't read projects: ${e?.message || e}`;
      rows = [];
    }
    if (!fresh()) return;
    loading = false;
    if (shell.isOpen()) {
      paint(focus);
      shell.replace();
    }
  }

  const shell = createChipPopover({
    id: "projectPicker", className: "ctx-popover project-picker", width: 380, el, anchor: "#scopePick",
    summary: () => ({}), sheet: true, label: "Projects", doc, win,
    show: () => {
      rows = [];
      loading = true;
      error = "";
      paint();
      void load(true);
    },
    onClose: () => { latest.drop(); },
  });

  return { pop: shell.pop, isOpen: shell.isOpen, load };
}
