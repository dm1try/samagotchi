// The project picker opened by the top-bar scope chip. The server supplies
// the project roots and their current/default marks; links never carry a
// session hash into another project's list.

import { html, nothing, render } from "./vendor/lit-html.js";
import { allScopeHref, projectScopeHref } from "./scope.js";
import { createChipPopover } from "./chip_popover.js";
import { createLatest } from "./latest.js";

function sessionCount(count) {
  const n = Number(count) || 0;
  return `${n} session${n === 1 ? "" : "s"}`;
}

function projectRow(row) {
  return html`<a class=${`project-row${row.default ? " default" : ""}${row.current ? " current" : ""}`}
    href=${row.default ? "/" : projectScopeHref(row.dir, "")}
    aria-current=${row.current ? "page" : nothing}>
    <span class="project-main"><span class="project-name">${row.name}</span
      >${row.default ? html`<span class="project-default">default</span>` : nothing
      }<span class="project-root">${row.root_label}</span></span>
    <span class="project-meta">${Number(row.waiting) > 0 ? html`<span class="attn">${Number(row.waiting)} waiting</span>` : nothing
      }<span class="project-count">${sessionCount(row.sessions)}</span>${row.current ? html`<span class="project-check" aria-hidden="true">✓</span>` : nothing}</span>
  </a>`;
}

function projectParent(rootLabel) {
  if (typeof rootLabel !== "string" || !rootLabel) return "~/";
  const slash = rootLabel.lastIndexOf("/");
  if (slash < 0) return "~/";
  const parent = rootLabel.slice(0, slash);
  return parent ? `${parent.replace(/\/$/, "")}/` : "/";
}

// +rows+ is the API's ordered list. When there is no project scope, the
// all-projects row is current; a bad ?dir= has no current project to mark.
export function pickerTemplate({ rows = [], loading = false, error = "", currentDir = null,
                                 allCurrent = false, createOpen = false, createPath = "~/", creating = false,
                                 createError = "", onPathInput = () => {} } = {}) {
  const allHref = allScopeHref("", currentDir);
  return html`<div class="ctx-pop-head"><strong>Projects</strong><button type="button" class="ctx-pop-close"
      data-act="close" aria-label="Close">×</button></div>
    ${loading ? html`<div class="project-note" role="status">Loading projects…</div>` : nothing}
    ${error ? html`<div class="project-note project-error" role="alert">${error}</div>` : nothing}
    <nav class="project-list" aria-label="Projects">${rows.map((row) => projectRow(row))}
      <a id="projectAll" class=${`project-row project-all${allCurrent ? " current" : ""}`}
        href=${allHref} aria-current=${allCurrent ? "page" : nothing}>
        <span class="project-main"><span class="project-name">All projects</span
          ><span class="project-hint">Every session</span></span>
        ${allCurrent ? html`<span class="project-check" aria-hidden="true">✓</span>` : nothing}
      </a>${createOpen ? html`<form class="project-create" aria-busy=${creating}>
        <label for="projectCreatePath">Folder path</label>
        <input id="projectCreatePath" name="dir" type="text" autocomplete="off" .value=${createPath}
          aria-invalid=${createError ? "true" : "false"} aria-describedby=${createError ? "projectCreateError" : nothing}
          @input=${onPathInput}>
        ${createError ? html`<div class="project-note project-error" id="projectCreateError" role="alert">${createError}</div>` : nothing}
        <div class="project-create-actions"><button type="submit">${creating ? "Creating…" : "Create"}</button>
          <button type="button" class="ghost" data-act="cancel-new">Cancel</button></div>
      </form>` : html`<button type="button" class="project-row project-new" data-act="new-project">New project…</button>`}
    </nav>`;
}

// +scopeError+ returns the page's current folder error, if any.
export function createProjectPicker({ el, scope, scopeError = () => null, api,
                                      doc = globalThis.document, win = globalThis.window }) {
  let rows = [];
  let loading = false;
  let error = "";
  // Only the newest read is drawn; a close drops the one out (latest.js).
  const latest = createLatest();
  // Creating a project must not invalidate an in-flight list read.
  const createLatestAnswer = createLatest();
  let createOpen = false;
  let createPath = "~/";
  let creating = false;
  let createError = "";

  const currentDir = () => scopeError() ? null : scope.dir || null;
  const paint = (focus = false) => {
    const failedScope = !!scopeError();
    render(pickerTemplate({
      rows, loading, error, currentDir: currentDir(),
      allCurrent: !scope.dir && !failedScope,
      createOpen, createPath, creating, createError,
      onPathInput: (event) => { createPath = event.currentTarget.value; },
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
      // An open form keeps the caret: a late list must not pull focus to a row.
      paint(focus && !createOpen);
      shell.replace();
    }
  }

  async function submitProject() {
    if (creating) return;
    const fresh = createLatestAnswer.begin();
    creating = true;
    createError = "";
    paint();
    shell.replace();
    try {
      const answer = await api("/api/projects", { method: "POST", body: JSON.stringify({ dir: createPath }) });
      if (!fresh()) return;
      win.location.assign(projectScopeHref(answer.dir, ""));
    } catch (e) {
      if (!fresh()) return;
      createError = e?.body?.detail || e?.message || String(e);
      creating = false;
      paint();
      shell.replace();
    }
  }

  function openCreateForm() {
    createOpen = true;
    createPath = projectParent(rows.find((row) => row.default)?.root_label);
    createError = "";
    creating = false;
    paint();
    shell.replace();
    const input = shell.pop.querySelector("#projectCreatePath");
    input?.focus();
    input?.setSelectionRange(input.value.length, input.value.length);
  }

  function closeCreateForm() {
    createLatestAnswer.drop();
    createOpen = false;
    creating = false;
    createError = "";
    paint();
    shell.replace();
  }

  const shell = createChipPopover({
    id: "projectPicker", className: "ctx-popover project-picker", width: 380, el, anchor: "#scopePick",
    summary: () => ({}), sheet: true, label: "Projects", doc, win,
    show: () => {
      rows = [];
      loading = true;
      error = "";
      createOpen = false;
      createPath = "~/";
      creating = false;
      createError = "";
      paint();
      void load(true);
    },
    onSubmit: () => { void submitProject(); },
    onAct: (name) => {
      if (name === "new-project") openCreateForm();
      else if (name === "cancel-new") closeCreateForm();
    },
    onClose: () => {
      latest.drop();
      createLatestAnswer.drop();
      createOpen = false;
      creating = false;
      createError = "";
    },
  });

  return { pop: shell.pop, isOpen: shell.isOpen, load };
}
