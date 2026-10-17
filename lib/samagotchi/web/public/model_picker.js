// The start page's model picker: a quiet button with the chosen name that
// opens a searchable list (#modelPanel) over the conversation, like the /
// list. The rows and the matching are model_pick.js'; this is the DOM.
//
// The panel is a child of #composer, not of the button (an input can't sit
// in a button, and the button clips). It opens upward, or downward when
// #center (overflow hidden, and #dock's backdrop-filter traps position:
// fixed) leaves too little room above, over the composer when neither side
// has it. The search input keeps the focus:
// ↑/↓ PageUp/PageDown move, ⏎ picks, Esc and Tab close without a change.

import { moveSelection } from "./command_complete.js";
import { readStored, writeStored } from "./storage.js";
import {
  MODEL_KEY, RECENT_KEY, groupRows, matchModels, modelRows, pickModel, pushRecent, recentRows, rowNote, rowTitle,
} from "./model_pick.js";
import { html, nothing, render as draw } from "./vendor/lit-html.js";

const PAGE = 8;
const MAX_HEIGHT = 360;
const MIN_ROOM = 200;
const GAP = 8;

// The text with the [start, end) ranges in <mark> (lit-html parts).
function markedTemplate(text, marks) {
  const parts = [];
  let at = 0;
  for (const [a, b] of marks || []) {
    parts.push(text.slice(at, a), html`<mark>${text.slice(a, b)}</mark>`);
    at = b;
  }
  parts.push(text.slice(at));
  return parts;
}

// A group's head ("Recent", a host with its notes).
function headTemplate(label, note = "") {
  return html`<div class="model-group" role="presentation">${label}${note ? html` <span>${note}</span>` : nothing}</div>`;
}

function readRecent() {
  try {
    const list = JSON.parse(readStored(RECENT_KEY) || "[]");
    return Array.isArray(list) ? list : [];
  } catch (_) {
    return [];
  }
}

// +onPick+ runs after a pick (the panel is closed by then). +remember+:
// whether a pick is this browser's choice for a new session (stored, and in
// Recent); false on a fresh chain link, where a pick is that link's only.
export function createModelPicker({ button, panel, input, list, composer, center, onPick, remember = () => true }) {
  let rows = [];
  let defaultName = "";
  let chosen = "";
  let shown = []; // the option rows in list order
  let active = 0;

  const isOpen = () => !panel.hidden;

  // Greyed while the chosen row's host is down (the button's tooltip,
  // app.js', carries the host's warning).
  function setChosen(name) {
    chosen = name;
    button.querySelector(".model-pick-name").textContent = name;
    button.classList.toggle("unavailable", rows.some((r) => r.name === name && r.unavailable === true));
  }

  // One option row. The active one is drawn so here and kept so by
  // showActive (the arrows and the pointer move it without a redraw).
  function rowTemplate(row, i, { hostMarks = [], idMarks = [], showHost = !row.isDefaultHost } = {}) {
    const host = showHost
      ? html`<span class="model-host">${markedTemplate(row.host, hostMarks)}</span><span class="model-dot"> · </span>` : nothing;
    const noteText = rowNote(row, defaultName);
    const note = noteText ? html`<span class="model-note">${noteText}</span>` : nothing;
    const cls = `model-option${i === active ? " active" : ""}${row.name === chosen ? " chosen" : ""}${row.unavailable ? " unavailable" : ""}`;
    return html`<div class=${cls} role="option" id=${`model-option-${i}`} aria-selected=${String(i === active)} data-index=${i} title=${rowTitle(row) || nothing}><span class="model-id">${host}${markedTemplate(row.id, idMarks)}</span>${note}</div>`;
  }

  function render() {
    const query = input.value.trim();
    const parts = [];
    shown = [];
    const add = (row, opts) => { parts.push(rowTemplate(row, shown.length, opts)); shown.push(row); };
    if (query) {
      for (const m of matchModels(rows, query)) add(m.row, { hostMarks: m.hostMarks, idMarks: m.idMarks });
      if (!shown.length) parts.push(html`<div class="model-empty" role="presentation">Nothing matches</div>`);
    } else {
      const recent = recentRows(rows, readRecent());
      if (recent.length) {
        parts.push(headTemplate("Recent"));
        recent.forEach((row) => add(row));
      }
      for (const group of groupRows(rows)) {
        parts.push(headTemplate(group.host, [group.isDefault ? "default host" : "", group.unavailable ? "host down" : ""].filter(Boolean).join(" · ")));
        group.rows.forEach((row) => add(row, { showHost: false }));
      }
    }
    if (active >= shown.length) active = 0;
    draw(parts, list);
    showActive();
  }

  function showActive() {
    list.querySelectorAll(".model-option.active").forEach((el) => {
      el.classList.remove("active");
      el.setAttribute("aria-selected", "false");
    });
    const el = list.querySelector(`#model-option-${active}`);
    if (!el) return input.removeAttribute("aria-activedescendant");
    el.classList.add("active");
    el.setAttribute("aria-selected", "true");
    input.setAttribute("aria-activedescendant", el.id);
    el.scrollIntoView({ block: "nearest" });
  }

  // Upward by default; downward when the room above #composer inside
  // #center is short and the room below is not; over the composer itself
  // (its bottom edge) when neither has the room, as in a short window,
  // where the start page centres the dock and leaves little on either side.
  function place() {
    const box = center.getBoundingClientRect();
    const at = composer.getBoundingClientRect();
    const up = at.top - box.top - GAP * 2;
    const down = box.bottom - at.bottom - GAP * 2;
    const side = up >= MIN_ROOM ? "up" : down >= MIN_ROOM ? "down" : "over";
    const room = { up, down, over: at.bottom - box.top - GAP }[side];
    panel.classList.toggle("down", side === "down");
    panel.classList.toggle("over", side === "over");
    const cap = window.matchMedia("(max-width:600px)").matches ? Math.min(MAX_HEIGHT, window.innerHeight / 2) : MAX_HEIGHT;
    panel.style.maxHeight = `${Math.max(0, Math.min(cap, room))}px`;
  }

  function open() {
    if (isOpen() || button.hidden) return;
    input.value = "";
    active = 0;
    panel.hidden = false;
    button.setAttribute("aria-expanded", "true");
    input.setAttribute("aria-expanded", "true");
    place();
    render();
    // Land on the chosen row: its Recent copy when it has one, so the list
    // opens at its top.
    const at = shown.findIndex((r) => r.name === chosen);
    if (at >= 0) { active = at; showActive(); }
    input.focus();
  }

  function close({ refocus = false } = {}) {
    if (!isOpen()) return;
    panel.hidden = true;
    draw(nothing, list);
    shown = [];
    button.setAttribute("aria-expanded", "false");
    input.setAttribute("aria-expanded", "false");
    input.removeAttribute("aria-activedescendant");
    if (refocus) button.focus();
  }

  function pick(index) {
    const row = shown[index];
    if (!row) return;
    setChosen(row.name);
    if (remember()) {
      writeStored(MODEL_KEY, row.name);
      writeStored(RECENT_KEY, JSON.stringify(pushRecent(readRecent(), row.name)));
    }
    close();
    onPick?.(row.name);
  }

  button.addEventListener("click", () => (isOpen() ? close() : open()));
  button.addEventListener("keydown", (e) => {
    if (e.isComposing || e.key !== "ArrowDown" || isOpen()) return;
    e.preventDefault();
    open();
  });
  input.addEventListener("input", () => { active = 0; render(); });
  input.addEventListener("keydown", (e) => {
    if (e.isComposing) return;
    const count = shown.length;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      active = moveSelection(active, count, e.key === "ArrowDown" ? 1 : -1);
      showActive();
    } else if (e.key === "PageDown" || e.key === "PageUp") {
      active = Math.max(0, Math.min(count - 1, active + (e.key === "PageDown" ? PAGE : -PAGE)));
      showActive();
    } else if (e.key === "Enter") {
      pick(active);
    } else if (e.key === "Escape") {
      e.stopPropagation();
      close({ refocus: true });
    } else if (e.key === "Tab") {
      close();
      return; // the focus moves on as it would
    } else {
      return;
    }
    e.preventDefault();
  });
  // Keep the focus in the search box: the pick happens on click.
  list.addEventListener("pointerdown", (e) => e.preventDefault());
  list.addEventListener("mousemove", (e) => {
    const option = e.target.closest(".model-option");
    if (!option || Number(option.dataset.index) === active) return;
    active = Number(option.dataset.index);
    showActive();
  });
  list.addEventListener("click", (e) => {
    const option = e.target.closest(".model-option");
    if (option) pick(Number(option.dataset.index));
  });
  document.addEventListener("pointerdown", (e) => {
    if (isOpen() && !panel.contains(e.target) && !button.contains(e.target)) close();
  });
  window.addEventListener("resize", () => { if (isOpen()) place(); });

  return {
    // GET /api/models' payload in: the rows, the preselected name (the
    // stored choice while offered, else the server's default). False when
    // the payload offers nothing (the button stays as it was).
    setModels(payload, stored) {
      const next = modelRows(payload);
      if (!next.length) return false;
      close();
      rows = next;
      defaultName = String(payload.default || "");
      setChosen(pickModel(rows, payload.default, stored || chosen));
      return true;
    },
    // A name on the button, nothing stored (a fresh link's model); one that
    // isn't a row (an alias, a typed host:id) shows as text, no row chosen.
    show(name) {
      setChosen(String(name || ""));
    },
    // Back to the start page's choice: +stored+ while offered, else the
    // default (no fetch; nothing before the list is in).
    restore(stored) {
      if (!rows.length) return;
      setChosen(pickModel(rows, defaultName, stored));
    },
    chosen: () => chosen,
    // The picked model's row (its llm_context too); null before the list.
    chosenRow: () => rows.find((r) => r.name === chosen) || null,
    close,
    isOpen,
  };
}
