// The session bar's attached context (chi context): a chip per source the
// open session sees (name · age; a dot for a change the agent hasn't read,
// red for a failing refresh), and a popover with its summary, hint link,
// text and detach. The chips refresh when a context note arrives in the
// stream and when the page gets focus (no event of their own), and their
// ages tick every minute. The web attaches nothing itself (`chi context
// add` does; GET …/context's can_add_url is left unread).

import { html, nothing, render } from "./vendor/lit-html.js";
import { keepFocus } from "./keep_focus.js";
import { popoverPlace } from "./chip_popover.js";
import { focusBack, modalDialog } from "./popover_modal.js";
import { cantText } from "./format.js";
import { createLatest } from "./latest.js";

// "now", "3m", "2h", "4d" since an ISO time; "" for none.
export function ageText(iso, now = Date.now()) {
  const at = Date.parse(iso || "");
  if (Number.isNaN(at)) return "";
  const s = Math.max(0, Math.round((now - at) / 1000));
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

// A hint the popover may link to: http(s) only.
export function hintUrl(hint) {
  const text = String(hint || "").trim();
  return /^https?:\/\/\S+$/i.test(text) ? text : null;
}

// GET …/context's rows as chips: the muted ones left out. state: "error"
// (the last refresh failed), "unread" (a text the agent hasn't read),
// "empty" (no text yet) or "ok".
export function chipModel(rows, now = Date.now()) {
  return (rows || []).filter((row) => row && !row.muted).map((row) => {
    const state = row.error ? "error" : !row.has_text ? "empty" : row.unread ? "unread" : "ok";
    const age = ageText(row.fetched_at, now);
    const why = { error: `last refresh failed: ${row.error}`, unread: "changed; the agent hasn't read it yet",
                  empty: "no text yet", ok: "the agent has read the latest" }[state];
    const title = [row.summary, why].filter(Boolean).join(" · ");
    return { name: row.name, label: age ? `${row.name} · ${age}` : row.name, state, title };
  });
}

// The chips (a lit-html template; attributes after a bound one are bound
// too, so they keep their order). open: the chip whose popover is open (a
// source's name).
export function chipsTemplate(chips, { open = null } = {}) {
  return html`${chips.map((chip) => html`<button type="button" class=${`ctx-chip ${chip.state}${chip.name === open ? " open" : ""}`}
    data-name=${chip.name} title=${chip.title} aria-haspopup=${"dialog"} aria-expanded=${chip.name === open ? "true" : "false"}>${
      chip.state === "unread" ? html`<span class="ctx-dot" aria-hidden="true"></span>` : nothing}${chip.label}</button>`)}`;
}

// The popover's inside for one row (GET …/context's); +text+ the row's
// text once "view text" read it (null before).
export function popoverTemplate(row, { text = null, now = Date.now() } = {}) {
  const kind = row.kind === "cmd" ? `runs every ${row.every_seconds ? `${row.every_seconds}s` : "few minutes"}` : "pushed";
  const url = hintUrl(row.hint);
  const hint = url
    ? html`<a class="ctx-pop-hint" href=${url} target=${"_blank"} rel=${"noopener noreferrer"}>${url}</a>`
    : (row.hint ? html`<div class="ctx-pop-hint">${row.hint}</div>` : nothing);
  const age = ageText(row.fetched_at, now);
  const meta = [age ? (age === "now" ? "fetched just now" : `fetched ${age} ago`) : "no text yet",
                row.unread ? "the agent hasn't read this change" : (row.has_text ? "the agent has read it" : "")]
    .filter(Boolean).join(" · ");
  const detach = row.scope === "project" ? "mute here" : "detach";
  const detachTitle = row.scope === "project"
    ? "The project's source: this session stops seeing it (chi context unmute brings it back)"
    : "Remove it from this session";
  return html`<div class="ctx-pop-head"><strong>${row.name}</strong
    ><span class="ctx-pop-kind">${row.scope} · ${kind}</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    >${row.why ? html`<div class="ctx-pop-why">${row.why}</div>` : nothing}${hint}${
      row.summary ? html`<div class="ctx-pop-summary">${row.summary}</div>` : nothing
    }<div class="ctx-pop-meta">${meta}</div
    >${row.error ? html`<div class="ctx-pop-error">last refresh failed: ${row.error}</div>` : nothing
    }<pre class="ctx-pop-text" ?hidden=${text === null}>${text ?? ""}</pre
    ><div class="ctx-pop-actions">${row.has_text && text === null ? html`<button type="button" data-act="view">view text</button>` : nothing
    }<button type="button" class="ctx-pop-detach" data-act="detach" title=${detachTitle}>${detach}</button></div>`;
}

// The chips for the session bar. el: #contextChips; api: {list(id),
// show(id, name), detach(id, name)}; toast(text). Chips and popover are
// lit templates: a redraw (a refresh, the minute's tick) keeps their nodes,
// so focus stays. The
// popover behaves as every popover does (popover_modal.js): a modal dialog, its chip's
// aria-expanded, Esc closes it and focus goes back to the chip.
export function createContextChips({ el, api, toast = () => {}, doc = document, win = window }) {
  let sessionId = null;
  let rows = [];
  let openName = null;
  // Only the newest list read for the open session is drawn (latest.js).
  const latest = createLatest(() => sessionId);
  // The open row's text once read (view text).
  let text = null;
  const pop = doc.createElement("div");
  pop.id = "contextPopover";
  pop.className = "ctx-popover";
  pop.hidden = true;
  doc.body.appendChild(pop);
  modalDialog(pop, { isOpen: () => openName !== null, doc });

  function drawChips() {
    const chips = chipModel(rows);
    // A source inserted before the focused chip: the focus stays on its source.
    keepFocus(el, "data-name", () => render(chipsTemplate(chips, { open: openName }), el));
    el.hidden = chips.length === 0;
  }

  // The chips, and the open popover closed when what it is for has gone.
  function draw() {
    if (openName && !chipModel(rows).some((chip) => chip.name === openName)) close();
    else drawChips();
  }

  async function refresh() {
    const id = sessionId;
    if (!id) return;
    const fresh = latest.begin();
    try {
      const data = await api.list(id);
      if (!fresh()) return;
      rows = data.sources || [];
    } catch {
      // A session the server doesn't know (gone, or an older chi web): no chips.
      if (!fresh()) return;
      rows = [];
    }
    draw();
    // An open popover follows its row, but not while it shows the text.
    if (openName && text === null) {
      const row = rows.find((r) => r.name === openName);
      if (row) fill(row);
    }
  }

  function load(id) {
    sessionId = id;
    rows = [];
    close();
    return refresh();
  }

  function clear() {
    sessionId = null;
    rows = [];
    close();
  }

  function fill(row) {
    render(popoverTemplate(row, { text }), pop);
  }

  // At the chip as the session bar's chips place theirs (popoverPlace):
  // above it, or below when the room above is short; capped to the room
  // (it scrolls), inside the window with a 16px gutter.
  function place(chip) {
    const width = Math.min(380, win.innerWidth - 32);
    pop.style.width = `${width}px`;
    pop.style.maxHeight = "";
    const at = popoverPlace(chip.getBoundingClientRect(), { width, height: pop.offsetHeight,
                                                            innerWidth: win.innerWidth, innerHeight: win.innerHeight });
    pop.style.left = `${at.left}px`;
    pop.style.top = at.top === undefined ? "" : `${at.top}px`;
    pop.style.bottom = at.bottom === undefined ? "" : `${at.bottom}px`;
    if (at.maxHeight !== undefined) pop.style.maxHeight = `${at.maxHeight}px`;
  }

  function placeAtOpenChip() {
    const chip = openName && el.querySelector(".ctx-chip.open");
    if (chip) place(chip);
  }

  function open(name, chip) {
    const row = rows.find((r) => r.name === name);
    if (!row) return;
    // Another popover's nodes go, so this one starts fresh.
    render(nothing, pop);
    openName = name;
    text = null;
    pop.setAttribute("aria-label", name);
    fill(row);
    pop.hidden = false;
    place(chip);
    drawChips();
  }

  // Focus that was in it (or +refocus+: Esc) goes back to its chip.
  function close({ refocus = false } = {}) {
    const back = focusBack(pop, { refocus, doc });
    const name = openName;
    openName = null;
    text = null;
    pop.hidden = true;
    render(nothing, pop);
    drawChips();
    if (name !== null) back([...el.querySelectorAll(".ctx-chip[data-name]")].find((chip) => chip.dataset.name === name));
  }

  async function viewText() {
    const name = openName;
    if (!name) return;
    try {
      const data = await api.show(sessionId, name);
      if (name !== openName) return;
      const row = rows.find((r) => r.name === name);
      if (!row) return;
      text = data.text || "";
      fill(row);
      // The text makes it taller: placed again.
      placeAtOpenChip();
    } catch (e) {
      toast(cantText(`read ${name}`, e));
    }
  }
  async function detach() {
    const row = rows.find((r) => r.name === openName);
    if (!row) return;
    const ask = row.scope === "project"
      ? `Mute ${row.name} for this session? It is the project's: other sessions keep it.`
      : `Detach ${row.name} from this session?`;
    if (!win.confirm(ask)) return;
    try {
      await api.detach(sessionId, row.name);
      close();
      await refresh();
    } catch (e) {
      toast(cantText(`detach ${row.name}`, e));
    }
  }

  el.addEventListener("click", (e) => {
    const chip = e.target.closest(".ctx-chip");
    if (!chip) return;
    // On to the document: a session-bar chip's popover closes (the close
    // below leaves clicks in +el+ alone).
    if (openName === chip.dataset.name) close();
    else open(chip.dataset.name, chip);
  });
  pop.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "close") close();
    else if (act === "view") viewText();
    else if (act === "detach") detach();
  });
  doc.addEventListener("click", (e) => {
    if (openName && !pop.contains(e.target) && !el.contains(e.target)) close();
  });
  doc.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && openName) close({ refocus: true });
  });
  win.addEventListener("resize", placeAtOpenChip);
  win.addEventListener("focus", () => refresh());
  // The ages move on by themselves.
  win.setInterval(() => { if (rows.length) drawChips(); }, 60_000);

  return { load, clear, refresh, close, get rows() { return rows; } };
}
