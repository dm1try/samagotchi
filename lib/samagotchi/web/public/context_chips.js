// The session bar's attached context (chi context): a chip per source the
// open session sees (name · age; a dot for a change the agent hasn't read,
// red for a failing refresh), and a popover with its summary, hint link,
// text and detach. The chips refresh when a context note arrives in the
// stream and when the page gets focus (no event of their own), and their
// ages tick every minute. A "+ URL" chip (when an installed bundle's
// provider can attach one: GET …/context's can_add_url) opens a form that
// attaches a URL (a GitHub PR); the web never adds a command.

import { html, nothing, render } from "./vendor/lit-html.js";
import { keepFocus } from "./keep_focus.js";
import { popoverPlace } from "./chip_popover.js";
import { cantText } from "./format.js";
import { createLatest, stillOn } from "./latest.js";

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

const ADD_TITLE = "Attach a URL (a GitHub PR) the agent can read and hears about when it changes";

// The chips (a lit-html template; attributes after a bound one are bound
// too, so they keep their order). addUrl: end with the "+ URL" chip;
// open: the chip whose popover is open (a source's name), addOpen: the
// "+ URL" form is.
export function chipsTemplate(chips, { addUrl = false, open = null, addOpen = false } = {}) {
  return html`${chips.map((chip) => html`<button type="button" class=${`ctx-chip ${chip.state}${chip.name === open ? " open" : ""}`}
    data-name=${chip.name} title=${chip.title} aria-haspopup=${"dialog"}>${
      chip.state === "unread" ? html`<span class="ctx-dot" aria-hidden="true"></span>` : nothing}${chip.label}</button>`)}${
    addUrl ? html`<button type="button" class=${`ctx-chip ctx-add${addOpen ? " open" : ""}`} data-act=${"add"} title=${ADD_TITLE}
      aria-haspopup=${"dialog"}>+ URL</button>` : nothing}`;
}

// The "+ URL" popover: the URL, an optional why, Attach; +error+ after a
// try that failed, +busy+ while one runs.
export function addFormTemplate({ error = null, busy = false } = {}) {
  return html`<form class="ctx-add-form"><div class="ctx-pop-head"><strong>Attach a URL</strong
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    ><div class="ctx-pop-meta">A link an installed bundle knows (github-pr: a pull request). The agent gets a note when it changes.</div
    ><input class="ctx-add-input" name="url" type="url" inputmode="url" placeholder="https://github.com/owner/repo/pull/123" required autocomplete="off"
    ><input class="ctx-add-input" name="why" type="text" placeholder="why (optional)" maxlength="300" autocomplete="off"
    >${error ? html`<div class="ctx-pop-error" role="alert">${error}</div>` : nothing
    }<div class="ctx-pop-actions"><button type="submit" class="ctx-add-submit" ?disabled=${busy}>Attach</button></div></form>`;
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
// show(id, name), detach(id, name), add(id, {url, why})}; toast(text).
// Chips, popover and form are lit templates: a redraw (a refresh, the
// minute's tick) keeps their nodes, so focus and typed text stay.
export function createContextChips({ el, api, toast = () => {}, doc = document, win = window }) {
  let sessionId = null;
  let rows = [];
  let canAdd = false;
  let openName = null;
  // Only the newest list read for the open session is drawn (latest.js).
  const latest = createLatest(() => sessionId);
  // The open row's text once read (view text), and the "+ URL" form's
  // state ({error, busy}).
  let text = null;
  let addState = {};
  const pop = doc.createElement("div");
  pop.id = "contextPopover";
  pop.className = "ctx-popover";
  pop.setAttribute("role", "dialog");
  pop.hidden = true;
  doc.body.appendChild(pop);

  // openName ADD: the "+ URL" form is open.
  const ADD = "\u0000add";

  function drawChips() {
    const chips = chipModel(rows);
    // A source inserted before the focused chip: the focus stays on its source.
    keepFocus(el, "data-name", () => render(chipsTemplate(chips, { addUrl: canAdd, open: openName === ADD ? null : openName,
                                                                   addOpen: openName === ADD }), el));
    el.hidden = chips.length === 0 && !canAdd;
    // The "+ URL" chip alone sits inline, not on a row of its own.
    el.classList.toggle("only-add", chips.length === 0 && canAdd);
  }

  // The chips, and the open popover closed when what it is for has gone.
  function draw() {
    if (openName === ADD ? !canAdd : openName && !chipModel(rows).some((chip) => chip.name === openName)) close();
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
      canAdd = data.can_add_url === true;
    } catch {
      // A session the server doesn't know (gone, or an older chi web): no chips.
      if (!fresh()) return;
      rows = [];
      canAdd = false;
    }
    draw();
    // An open popover follows its row, but not while it shows the text.
    if (openName && openName !== ADD && text === null) {
      const row = rows.find((r) => r.name === openName);
      if (row) fill(row);
    }
  }

  function load(id) {
    sessionId = id;
    rows = [];
    canAdd = false;
    close();
    return refresh();
  }

  function clear() {
    sessionId = null;
    rows = [];
    canAdd = false;
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
    fill(row);
    pop.hidden = false;
    place(chip);
    drawChips();
  }

  const drawAdd = (changes = {}) => {
    addState = { ...addState, ...changes };
    render(addFormTemplate(addState), pop);
  };

  function openAdd(chip) {
    render(nothing, pop);
    openName = ADD;
    text = null;
    addState = {};
    drawAdd();
    pop.hidden = false;
    place(chip);
    drawChips();
    pop.querySelector('input[name="url"]')?.focus();
  }

  async function submitAdd(form) {
    const id = sessionId;
    const url = form.elements.url.value.trim();
    const why = form.elements.why.value.trim();
    if (!id || !url) return;
    const still = stillOn(() => sessionId);
    drawAdd({ busy: true });
    try {
      const data = await api.add(id, { url, why: why || undefined });
      if (!still()) return;
      close();
      await refresh();
      toast(`Attached ${data.name}: the agent gets a note before your next message`);
    } catch (e) {
      if (!still() || openName !== ADD) return;
      // The same form again: what the user typed stays; the URL gets focus.
      drawAdd({ busy: false, error: e.message });
      pop.querySelector('input[name="url"]')?.focus();
    }
  }

  function close() {
    openName = null;
    text = null;
    addState = {};
    pop.hidden = true;
    render(nothing, pop);
    drawChips();
  }

  async function viewText() {
    const name = openName;
    if (!name || name === ADD) return;
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
    if (chip.dataset.act === "add") {
      if (openName === ADD) close();
      else openAdd(chip);
    } else if (openName === chip.dataset.name) close();
    else open(chip.dataset.name, chip);
  });
  pop.addEventListener("submit", (e) => {
    e.preventDefault();
    submitAdd(e.target);
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
    if (e.key === "Escape" && openName) close();
  });
  win.addEventListener("resize", placeAtOpenChip);
  win.addEventListener("focus", () => refresh());
  // The ages move on by themselves.
  win.setInterval(() => { if (rows.length) drawChips(); }, 60_000);

  return { load, clear, refresh, close, get rows() { return rows; } };
}
