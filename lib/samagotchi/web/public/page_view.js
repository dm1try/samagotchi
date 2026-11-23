// The page view, #/p/NAME (docs/pages.md, docs/internals/pages.md): in
// place of the session area, a page's header (Back, the title, when it ran
// and how long it took, Refresh, ⋯ with Delete) and its blocks. Opening
// reads the stored page (GET /api/pages/NAME) and runs nothing; Refresh
// runs the script (POST …/run, answered when the run ended) and redraws
// from its answer. A failed run keeps the last result, dimmed, under the
// failure line; a script changed since the result says so. Nothing is
// live: a run from a terminal shows after the next open.
//
// Made only with the pages capability (app.js; the null-control rule).
// +root+: #pageView. +api+: data.js api. +toast(text)+, +copyText(text)+:
// the page's. +back()+: Back (views.js closePage). +gone()+: the page was
// removed (a Delete, or a Refresh answered "no such page"): views.js leaves
// for All sessions. +backLabel()+: what Back says ("Sessions" or "Back").
// +phone()+: the page's phone width now (the table's phone form). The view
// keeps each table's sort and opened rows (page_table.js) until another
// page opens.
import { html, nothing, render } from "./vendor/lit-html.js";
import { createLatest } from "./latest.js";
import { cantText } from "./format.js";
import { blocksTemplate, drawWalks } from "./page_blocks.js";
import { tableTemplate } from "./page_table.js";
import { nextSort } from "./page_table_model.js";
import { changedText, errorCopy, failureParts, keptAfterFailure, metaText } from "./page_model.js";

export function createPageView({
  root, api, toast = () => {}, copyText = async () => false, back = () => {}, gone = () => {},
  backLabel = () => "Sessions", phone = () => false, doc = document, win = window, now = () => Date.now(),
}) {
  // The page open now: {name, status: "loading" | "ready" | "missing" |
  // "error", page, error, running, stderr, menu: "closed" | "open" |
  // "confirm", deleting, sorts: {block index: {index, dir}}, opened: {block
  // index: Set of rows}}; null while closed.
  let view = null;
  const runs = new Map();
  const latest = createLatest(() => view?.name ?? null);
  const path = (name) => `/api/pages/${encodeURIComponent(name)}`;

  function draw() {
    if (!view) {
      render(nothing, root);
      return;
    }
    render(template(view), root);
    drawWalks(root, { doc, win });
  }

  function set(fields) {
    view = { ...view, ...fields };
    draw();
  }

  async function open(name) {
    if (view?.name === name) return;
    const run = runs.get(name);
    view = { name, status: "loading", page: null, error: null, running: !!run, stderr: "", menu: "closed", deleting: false,
             sorts: {}, opened: {} };
    draw();
    const fresh = latest.begin();
    try {
      const page = await api(path(name));
      if (!fresh() || run?.answered) return;
      set({ status: "ready", page });
    } catch (error) {
      if (!fresh()) return;
      set(error.code === "page_missing" ? { status: "missing" } : { status: "error", error });
    }
  }

  function close() {
    latest.drop();
    view = null;
    draw();
  }

  async function refresh() {
    if (!view || view.running || view.status !== "ready") return;
    const name = view.name;
    const run = { answered: false };
    runs.set(name, run);
    set({ running: true, menu: "closed" });
    const still = () => view?.name === name;
    try {
      const page = await api(`${path(name)}/run`, { method: "POST" });
      run.answered = true;
      if (runs.get(name) === run) runs.delete(name);
      if (!still()) return;
      set({ status: "ready", running: false, page, stderr: page.stderr || "" });
    } catch (error) {
      if (runs.get(name) === run) runs.delete(name);
      if (!still()) return;
      set({ running: false });
      if (error.code === "page_missing") {
        toast(error.message);
        gone();
      } else if (error.code === "page_busy" || error.code === "server_stopping") {
        toast(error.message);
      } else {
        toast(cantText("refresh the page", error));
      }
    }
  }

  async function remove() {
    if (!view || view.deleting) return;
    const name = view.name;
    const title = view.page?.title || name;
    set({ deleting: true });
    try {
      await api(path(name), { method: "DELETE" });
      if (view?.name !== name) return;
      toast(`Deleted the page ${title}`);
      gone();
    } catch (error) {
      if (view?.name !== name) return;
      set({ deleting: false, menu: "closed" });
      if (error.code === "page_missing") gone();
      toast(error.code === "page_busy" ? error.message : cantText("delete the page", error));
    }
  }

  async function copyError() {
    const ok = await copyText(errorCopy(view.page, view.stderr));
    toast(ok ? "Copied the error" : "Can't copy here");
  }

  function menuTemplate(v) {
    if (v.menu === "closed") return nothing;
    if (v.menu === "confirm") {
      return html`<div class="pg-menu" role="menu">
        <span class="pg-confirm">Delete this page?</span>
        <button type="button" class="pg-delete danger" role="menuitem" ?disabled=${v.deleting} @click=${remove}>${v.deleting ? "Deleting…" : "Delete"}</button>
        <button type="button" class="ghost" role="menuitem" @click=${() => set({ menu: "closed" })}>Cancel</button>
      </div>`;
    }
    return html`<div class="pg-menu" role="menu">
      <button type="button" class="pg-delete-ask" role="menuitem" @click=${() => set({ menu: "confirm" })}>Delete</button>
    </div>`;
  }

  function headTemplate(v, page) {
    const meta = page ? metaText(page, now()) : null;
    const title = page?.title || v.name;
    const ready = v.status === "ready";
    return html`<div class="pg-head">
      <button type="button" class="pg-back ghost" @click=${back}>← ${backLabel()}</button>
      <h1 class="pg-title">${title}</h1>
      ${meta ? html`<span class="pg-meta">${meta}</span>` : nothing}
      ${ready ? html`<span class="pg-actions">
        <button type="button" class="pg-refresh primary" ?disabled=${v.running} @click=${refresh}>${v.running ? "Running…" : "Refresh"}</button>
        <span class="pg-more">
          <button type="button" class="pg-menu-btn ghost" aria-label="More" title="More" aria-haspopup="menu"
            aria-expanded=${v.menu === "closed" ? "false" : "true"}
            @click=${() => set({ menu: v.menu === "closed" ? "open" : "closed" })}>⋯</button>
          ${menuTemplate(v)}
        </span>
      </span>` : nothing}
    </div>`;
  }

  function linesTemplate(page) {
    const failed = failureParts(page);
    const changed = changedText(page, now());
    return html`${failed ? html`<div class="pg-line pg-failed" role="status">
        ${failed.lead}<code>${failed.message}</code>.${failed.tail}
        <button type="button" class="pg-copy ghost" @click=${copyError}>Copy the error</button>
      </div>` : nothing}
      ${changed ? html`<div class="pg-line pg-changed" role="status">${changed}</div>` : nothing}`;
  }

  function bodyTemplate(v) {
    if (v.status === "loading") return html`<div class="pg-note">Loading…</div>`;
    if (v.status === "missing") return html`<div class="pg-note">There is no page called ${v.name}.</div>`;
    if (v.status === "error") return html`<div class="pg-note">${cantText("read the page", v.error)}</div>`;
    const page = v.page;
    const kept = keptAfterFailure(page);
    const table = (block, index) => tableTemplate(block, {
      phone: phone(),
      sort: v.sorts[index] || null,
      onSort: (column, numeric) => set({ sorts: { ...v.sorts, [index]: nextSort(v.sorts[index], column, numeric) } }),
      opened: v.opened[index] || new Set(),
      onToggle: (row) => {
        const opened = new Set(view.opened[index] || []);
        if (opened.has(row)) opened.delete(row);
        else opened.add(row);
        set({ opened: { ...view.opened, [index]: opened } });
      },
    });
    const blocks = page.ran_at ? blocksTemplate(page.blocks, { table }) : nothing;
    return html`${linesTemplate(page)}
      ${page.ran_at ? html`<div class="pg-blocks ${kept ? "pg-kept" : ""}">${blocks}</div>`
        : html`<div class="pg-note">No result yet${page.state === "failed" ? "" : ": Refresh runs the script"}.</div>`}`;
  }

  function template(v) {
    return html`${headTemplate(v, v.status === "ready" ? v.page : null)}${bodyTemplate(v)}`;
  }

  // A click outside the open menu closes it (one inside it that redrew it
  // has a target no longer in the page: not outside).
  doc.addEventListener("click", (e) => {
    if (!view || view.menu === "closed" || !e.target?.isConnected || e.target.closest?.(".pg-more")) return;
    set({ menu: "closed" });
  });
  // The phone's table form follows the width.
  win.matchMedia?.("(max-width: 600px)")?.addEventListener?.("change", () => view && draw());

  return { open, close, refresh, name: () => view?.name ?? null };
}
