// The start page's 🧰 list: the toolkit the next new session starts on
// (GET /api/models' toolkits: {default, suggest, kits: [{name,
// description?}]}), a choice for that create only (start_page.js keeps it;
// never remembered). Auto, the everyday path, sends nothing: with
// toolkit.suggest.mode on, the first message may get a suggested kit, else
// the default. A kit picked is sent (the session is "chosen" and gets no
// suggestion), the default too while Auto is offered; without Auto the
// default's row is Auto's and sends nothing. A pick closes the list.
//
// Beside 🧰 on the row an override chip names the kit ("tools: web");
// on a phone 🧰 carries a dot instead (toolkitLabel()).

import { createChipPopover } from "./chip_popover.js";
import { html, nothing, render } from "./vendor/lit-html.js";

export const AUTO = "auto";
export const LIST_LABEL = "Toolkit";
export const NOTE = "Change it later with /toolkit.";
// The built-ins carry no description (one would make them System 1
// candidates): the page words them.
const BUILTIN_WORDS = { full: "every tool", lean: "core tools; find_tools reaches the rest" };

// Whether the first message may get a suggested kit (the Auto row).
export const offersAuto = (toolkits) => toolkits?.suggest === "on";

// The list's rows, each {value (AUTO or a kit's name), label, detail,
// title, pressed}. +choice+: the kit picked, null for none (Auto; the
// default's row without Auto).
export function toolkitRows(toolkits, choice) {
  if (!toolkits) return [];
  const auto = offersAuto(toolkits);
  const fallback = toolkits.default;
  const rows = auto ? [{
    value: AUTO, label: "Auto", detail: `may be picked on the first message, else ${fallback}`,
    title: `A described kit may be suggested on the first message; else the session starts on ${fallback}`,
  }] : [];
  for (const kit of toolkits.kits || []) {
    const own = kit.description || BUILTIN_WORDS[kit.name] || "";
    const isDefault = kit.name === fallback;
    rows.push({
      value: kit.name, label: kit.name,
      detail: isDefault ? [own, "default"].filter(Boolean).join(" · ") : own,
      title: isDefault && auto ? `${kit.name}, picked: the session starts on it and gets no suggestion`
        : kit.description || null,
    });
  }
  const pressed = choice || (auto ? AUTO : fallback);
  return rows.map((r) => ({ ...r, pressed: r.value === pressed }));
}

// What a row's pick sends: a kit's name, or null (Auto; the default's row
// without Auto).
export function pickValue(toolkits, value) {
  if (value === AUTO) return null;
  if (!offersAuto(toolkits) && value === toolkits?.default) return null;
  return value;
}

// The row's override chip for +choice+, {text, title}, or null.
export function toolkitOverride(choice) {
  if (!choice) return null;
  return { text: `tools: ${choice}`, title: `Toolkit: ${choice} for the new session (no suggestion). Click to change it.` };
}

// 🧰's state: whether a kit is picked (its dot on a phone) and its tooltip
// and accessible name.
export function toolkitLabel(choice) {
  return { set: !!choice, label: choice ? `${LIST_LABEL}: ${choice}` : LIST_LABEL };
}

// +state+: {toolkits, choice, review: review files set (with Auto checked
// a note says a review gets no suggestion), error: Start's refusal}.
export function listTemplate({ toolkits, choice, review = false, error = null }) {
  const rows = toolkitRows(toolkits, choice);
  return html`<div class="ctx-pop-head"><strong>Toolkit · new session</strong
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    ><div class="st-rows" role="group" aria-label="Toolkit">${rows.map((r) => html`<button type="button" class="st-row"
      data-act=${`kit:${r.value}`} aria-pressed=${r.pressed ? "true" : "false"} title=${r.title || nothing}
      ><span class="st-check" aria-hidden="true">${r.pressed ? "✓" : ""}</span><span class="st-name">${r.label}</span
      ><span class="st-detail">${r.detail}</span></button>`)}</div
    >${review && !choice && offersAuto(toolkits) ? html`<div class="ctx-pop-meta">A review session gets no suggestion: it starts on ${
      toolkits.default} unless you pick a kit.</div>` : nothing
    }<div class="ctx-pop-error" role="alert" ?hidden=${!error}>${error || ""}</div
    ><div class="ctx-pop-meta">${NOTE}</div>`;
}

// The list on chip_popover.js' shell, a bottom sheet on a phone. +el+:
// where 🧰 is; +button+: 🧰 (the list opens at it; focus goes back to it);
// +openers+: the selector of every element that opens it (🧰 and the
// override chip). Hooks: +toolkits()+ the payload's toolkits (null: nothing
// opens), +choice()+, +choose(next)+, +review()+ whether review files are
// set.
// @return {open, toggle, close, refresh, refuse(message), isOpen}
export function createStartToolkit({ el, button, openers = `#${button.id}`, toolkits, choice, choose,
                                     review = () => false, doc = document, win = window }) {
  // Start's refusal of the picked kit (400 toolkit_refused), until a pick.
  let error = null;

  function draw() {
    render(listTemplate({ toolkits: toolkits(), choice: choice(), review: review(), error }), shell.pop);
    shell.replace();
  }

  const rowsOf = () => [...shell.pop.querySelectorAll(".st-row")];
  // Focus on the checked row (the list sits at the end of <body>).
  function focusInside() {
    (shell.pop.querySelector(".st-row[aria-pressed=true]") || rowsOf()[0])?.focus();
  }

  const shell = createChipPopover({
    id: "startToolkitPopover", className: "ctx-popover start-toolkit", width: 380, el, anchor: `#${button.id}`, openers,
    summary: () => toolkits(), sheet: true, expands: true, label: LIST_LABEL, doc, win,
    show: () => draw(),
    onOpen: focusInside,
    onClose: () => { error = null; },
    onAct: (name) => {
      const [what, value] = name.split(/:(.*)/s);
      if (what !== "kit") return;
      error = null;
      choose(pickValue(toolkits(), value));
      shell.close({ refocus: true });
    },
  });
  // ↑/↓ between the rows (Enter is the button's own click).
  shell.pop.addEventListener("keydown", (e) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    const rows = rowsOf();
    const at = rows.indexOf(doc.activeElement);
    if (at < 0) return;
    e.preventDefault();
    rows[Math.max(0, Math.min(rows.length - 1, at + (e.key === "ArrowDown" ? 1 : -1)))].focus();
  });

  function open() {
    if (shell.isOpen()) {
      draw();
      focusInside();
    } else {
      shell.open(button);
    }
  }

  return {
    open,
    // The override chip's click: opens the list, or closes it.
    toggle: () => (shell.isOpen() ? shell.close() : open()),
    close: () => shell.close(),
    isOpen: () => shell.isOpen(),
    refresh: () => { if (shell.isOpen()) draw(); },
    // Start refused the picked kit (400 toolkit_refused): said in the list,
    // opened again.
    refuse: (message) => {
      error = message;
      open();
    },
  };
}
