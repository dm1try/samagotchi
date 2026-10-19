import { html, nothing, render } from "./vendor/lit-html.js";

// The page's toasts (app.js showToast): a stack in #toast, newest last, at
// most MAX_TOASTS. Each item has its own 6 s timer, or none when sticky: a
// sticky one stays until its action, its ✕ or a link in it is clicked, so a
// later notice can't hide an error. +text+: words, or a template
// (chains.js openChildrenTemplate: a link in it opens that session and hides
// the toast). The same text again while it shows reuses its item, moved to
// the end with a fresh timer. When a 4th comes, the oldest non-sticky goes
// (the oldest of all if every one is sticky).
const TOAST_MS = 6000;
const MAX_TOASTS = 3;

export function createToasts({ el, onChange = () => {}, doc = globalThis.document }) {
  const entries = [];

  function sync() {
    el.hidden = entries.length === 0;
    onChange();
  }

  function remove(entry, notify = true) {
    const index = entries.indexOf(entry);
    if (index < 0) return;
    if (entry.timer !== null) clearTimeout(entry.timer);
    entry.timer = null;
    entries.splice(index, 1);
    entry.el.remove();
    if (notify) sync();
  }

  function draw(entry, text, action, sticky) {
    render(html`<span class="toast-message" @click=${(e) => { if (e.target.closest?.("a[href]")) remove(entry); }}>${text}</span>${action
      ? html`<button type="button" class="toast-action" @click=${() => { remove(entry); action.run(); }}>${action.label}</button>`
      : nothing}${sticky ? html`<button type="button" class="toast-close" title="Dismiss" aria-label="Dismiss" @click=${() => remove(entry)}>✕</button>` : nothing}`,
    entry.el);
  }

  function item(text, action, sticky) {
    const entry = { el: doc.createElement("div"), timer: null, sticky, action, key: null };
    entry.el.className = "toast-item";
    draw(entry, text, action, sticky);
    entry.key = entry.el.querySelector(".toast-message").textContent;
    return entry;
  }

  function show(text, action = null, { sticky = false } = {}) {
    // Words are their own key; a template's key is its drawn text, so only
    // a template is drawn before the look-up.
    const candidate = typeof text === "string" ? null : item(text, action, sticky);
    const key = candidate ? candidate.key : text;

    const duplicate = entries.find((entry) => entry.key === key);
    if (duplicate) {
      if (duplicate.timer !== null) clearTimeout(duplicate.timer);
      duplicate.timer = null;
      duplicate.sticky = sticky || duplicate.sticky;
      duplicate.action = action || duplicate.action;
      draw(duplicate, text, duplicate.action, duplicate.sticky);
      entries.push(...entries.splice(entries.indexOf(duplicate), 1));
      el.appendChild(duplicate.el);
      if (!duplicate.sticky) duplicate.timer = setTimeout(() => remove(duplicate), TOAST_MS);
      sync();
      return;
    }

    if (entries.length === MAX_TOASTS) {
      remove(entries.find((entry) => !entry.sticky) || entries[0], false);
    }
    const entry = candidate || item(text, action, sticky);
    entries.push(entry);
    el.appendChild(entry.el);
    if (!sticky) entry.timer = setTimeout(() => remove(entry), TOAST_MS);
    sync();
  }

  return { show };
}
