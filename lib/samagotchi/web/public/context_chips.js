// The session bar's attached context (chi context): a chip per source the
// open session sees (name · age; a dot for a change the agent hasn't read,
// red for a failing refresh), and a popover with its summary, hint link,
// text and detach. The chips refresh when a context note arrives in the
// stream and when the page gets focus (no event of their own), and their
// ages tick every minute. The web attaches nothing itself (`chi context
// add` does; GET …/context's can_add_url is left unread).

import { html, nothing, render } from "./vendor/lit-html.js";
import { keepFocus } from "./keep_focus.js";
import { popoverPlace, SHEET_MAX, sheetPlace } from "./chip_popover.js";
import { focusBack, modalDialog } from "./popover_modal.js";
import { cantText } from "./format.js";
import { createLatest } from "./latest.js";
import { peerChipModel, peerGroups, peerKey, peerPopoverTemplate } from "./peer_chip.js";

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
// too, so they keep their order). open: the chip whose popover is open (its
// key: a source's name, or a peer chip's "peer:<name>", peer_chip.js). A
// peer chip (peerChipModel) is drawn as one: class "peer", its dot when it
// says answered.
export function chipsTemplate(chips, { open = null } = {}) {
  return html`${chips.map((chip) => html`<button type="button" class=${`ctx-chip${chip.peer ? " peer" : ""} ${chip.state}${chip.name === open ? " open" : ""}`}
    data-name=${chip.name} title=${chip.title} aria-haspopup=${"dialog"} aria-expanded=${chip.name === open ? "true" : "false"}>${
      chip.state === "unread" || chip.dot ? html`<span class="ctx-dot" aria-hidden="true"></span>` : nothing}${chip.label}</button>`)}`;
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
// A paired peer is one chip (peer_chip.js), drawn first: +peers+() the
// peers model (peer_data.js createPeers, GET …/peers: the chip's only feed;
// null: none, no peer chips), read when a session's chips load, and the
// chips redrawn on its change (peersChanged); +peerActions+: {status(name):
// the status card's command line ("/claude") when the session has it, else
// null; run(line); drawn(id): whether that send's row is in the
// conversation; jump(id): to it}. +api+ also reads a peer's message
// (message(id, name, serial)) and ends a pairing (unpair(id, name)).
// +focusAway+(): where focus goes when a detach or Unpair took the last chip
// (the composer).
export function createContextChips({ el, api, toast = () => {}, peers = () => null, peerActions = {},
                                     focusAway = () => doc.getElementById("prompt")?.focus?.({ preventScroll: true }),
                                     doc = document, win = window }) {
  let sessionId = null;
  let rows = [];
  // The chip whose popover is open: its key (a source's name, or "peer:<name>").
  let openKey = null;
  // Only the newest list read for the open session is drawn (latest.js).
  const latest = createLatest(() => sessionId);
  // The open popover's text once read (view text; a peer's: a message's).
  let text = null;
  const pop = doc.createElement("div");
  pop.id = "contextPopover";
  pop.className = "ctx-popover";
  pop.hidden = true;
  doc.body.appendChild(pop);
  modalDialog(pop, { isOpen: () => openKey !== null, doc });

  const groups = () => peerGroups(peers()?.peers?.() || []);
  const groupOf = (key) => groups().find((group) => group.key === key) || null;
  const exchangesOf = (name) => peers()?.peer?.(name)?.exchanges || [];
  const rowOf = (name) => rows.find((r) => r.name === name) || null;

  function chips(now = Date.now()) {
    const peerChips = groups().map((group) => peerChipModel(group, exchangesOf(group.name), now));
    return [...peerChips, ...chipModel(rows, now)];
  }

  function drawChips() {
    const drawn = chips();
    // A source inserted before the focused chip: the focus stays on its source.
    keepFocus(el, "data-name", () => render(chipsTemplate(drawn, { open: openKey }), el));
    el.hidden = drawn.length === 0;
  }

  // The chips, and the open popover closed when its chip isn't drawn any more.
  function draw() {
    if (openKey && !chips().some((chip) => chip.name === openKey)) close();
    else drawChips();
  }

  // The open popover drawn again from what is known (not while it shows a text).
  function follow() {
    if (openKey === null || text !== null) return;
    const group = groupOf(openKey);
    const row = group ? null : rowOf(openKey);
    if (group || row) fill(group, row);
  }

  async function refresh({ loading = false } = {}) {
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
    follow();
    // The peers for their chips: at a session's open (reuse the
    // conversation's read if loaded or in flight).
    if (loading) peers()?.refresh?.({ reuse: true });
  }

  function load(id) {
    sessionId = id;
    rows = [];
    close();
    return refresh({ loading: true });
  }

  function clear() {
    sessionId = null;
    rows = [];
    close();
  }

  function fill(group, row) {
    if (group) {
      const actions = peerActions;
      render(peerPopoverTemplate(group, exchangesOf(group.name), {
        text, status: actions.status?.(group.name) || null, drawn: (id) => !!actions.drawn?.(id),
      }), pop);
    } else render(popoverTemplate(row, { text }), pop);
  }

  // At the chip as the session bar's chips place theirs (popoverPlace):
  // above it, or below when the room above is short; capped to the room
  // (it scrolls), inside the window with a 16px gutter. A peer's popover in
  // a phone's window is a bottom sheet (sheetPlace), as scene 2 has it.
  function place(chip) {
    const sheet = !!groupOf(openKey) && win.innerWidth < SHEET_MAX;
    pop.classList.toggle("sheet", sheet);
    if (sheet) {
      const at = sheetPlace({ innerWidth: win.innerWidth, innerHeight: win.innerHeight });
      pop.style.width = `${at.width}px`;
      pop.style.left = `${at.left}px`;
      pop.style.top = "";
      pop.style.bottom = `calc(${at.bottom}px + var(--safe-b, 0px))`;
      pop.style.maxHeight = `${at.maxHeight}px`;
      return;
    }
    // A peer's is wider: its actions on one line (scene 2).
    const width = Math.min(groupOf(openKey) ? 440 : 380, win.innerWidth - 32);
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
    const chip = openKey && el.querySelector(".ctx-chip.open");
    if (chip) place(chip);
  }

  function open(key, chip) {
    const group = groupOf(key);
    const row = group ? null : rowOf(key);
    if (!group && !row) return;
    // Another popover's nodes go, so this one starts fresh.
    render(nothing, pop);
    openKey = key;
    text = null;
    pop.setAttribute("aria-label", group ? group.label : key);
    pop.classList.toggle("peer-pop", !!group);
    fill(group, row);
    pop.hidden = false;
    place(chip);
    drawChips();
  }

  // Focus that was in it (or +refocus+: Esc) goes back to its chip.
  function close({ refocus = false } = {}) {
    const back = focusBack(pop, { refocus, doc });
    const key = openKey;
    openKey = null;
    text = null;
    pop.hidden = true;
    pop.classList.remove("sheet", "peer-pop");
    render(nothing, pop);
    drawChips();
    if (key !== null) back([...el.querySelectorAll(".ctx-chip[data-name]")].find((chip) => chip.dataset.name === key));
  }

  // The open popover's text: a source's, or a peer's message (+serial+;
  // default its newest).
  async function viewText(serial = null, box = null) {
    const key = openKey;
    if (!key) return;
    const peer = groupOf(key);
    const number = peer ? serial ?? peer.peer.messages?.[0]?.serial : null;
    const name = peer ? `${peer.label}'s message #${number}` : key;
    if (peer && (number === null || number === undefined)) return;
    try {
      const data = peer ? await api.message(sessionId, peer.name, number, box) : await api.show(sessionId, key);
      if (key !== openKey) return;
      const group = groupOf(key);
      const row = group ? null : rowOf(key);
      if (!group && !row) return;
      text = data.text || "";
      fill(group, row);
      // The text makes it taller: placed again.
      placeAtOpenChip();
    } catch (e) {
      toast(cantText(`read ${name}`, e));
    }
  }
  async function detach() {
    const row = rowOf(openKey);
    if (!row) return;
    const ask = row.scope === "project"
      ? `Mute ${row.name} for this session? It is the project's: other sessions keep it.`
      : `Detach ${row.name} from this session?`;
    if (!win.confirm(ask)) return;
    try {
      await api.detach(sessionId, row.name);
      close();
      await refresh();
      focusAfterRemoval();
    } catch (e) {
      toast(cantText(`detach ${row.name}`, e));
    }
  }

  // Unpair: one confirm, then the pairing ends (DELETE …/peers/NAME; its
  // messages stay) and the peers are read again: the chip goes.
  async function unpair() {
    const group = groupOf(openKey);
    if (!group) return;
    if (!win.confirm(`Unpair ${group.label}? chi stops sending to it; its messages stay.`)) return;
    const id = sessionId;
    close();
    try {
      await api.unpair(id, group.name);
    } catch (e) {
      toast(cantText(`unpair ${group.label}`, e));
    }
    await peers()?.refresh?.();
    drawChips();
    focusAfterRemoval();
  }

  // A chip the focus was given back to went with its source: the focus goes
  // to the strip's first chip, else to +focusAway+ (the composer).
  function focusAfterRemoval() {
    const at = doc.activeElement;
    if (at && at !== doc.body && at.isConnected) return;
    const chip = el.querySelector(".ctx-chip");
    if (chip) chip.focus();
    else focusAway();
  }

  function act(name, target) {
    const group = groupOf(openKey);
    if (name === "close") close();
    else if (name === "view") viewText();
    else if (name === "detach") detach();
    else if (name === "unpair") unpair();
    else if (name === "status" && group) {
      const line = peerActions.status?.(group.name);
      close();
      if (line) peerActions.run?.(line);
    } else if (name === "jump") {
      const id = target.dataset.peerId;
      close();
      if (id) peerActions.jump?.(id);
    }
  }

  el.addEventListener("click", (e) => {
    const chip = e.target.closest(".ctx-chip");
    if (!chip) return;
    // On to the document: a session-bar chip's popover closes (the close
    // below leaves clicks in +el+ alone).
    if (openKey === chip.dataset.name) close();
    else open(chip.dataset.name, chip);
  });
  pop.addEventListener("click", (e) => {
    const target = e.target.closest("[data-act]");
    if (target) act(target.dataset.act, target);
  });
  doc.addEventListener("click", (e) => {
    if (openKey && !pop.contains(e.target) && !el.contains(e.target)) close();
  });
  doc.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && openKey) close({ refocus: true });
  });
  win.addEventListener("resize", placeAtOpenChip);
  win.addEventListener("focus", () => refresh());
  // The ages move on by themselves.
  win.setInterval(() => { if (rows.length) drawChips(); }, 60_000);

  // The popover of chip +key+ on its text (+serial+: a peer's message), at
  // its chip. In a task of its own: the click that asks would close it on
  // its way to the document.
  function showAt(key, serial = null, box = null) {
    setTimeout(() => {
      const chip = [...el.querySelectorAll(".ctx-chip[data-name]")].find((c) => c.dataset.name === key);
      if (!chip) return;
      chip.scrollIntoView?.({ block: "nearest", inline: "nearest" });
      if (openKey !== key) open(key, chip);
      if (openKey === key && text === null) viewText(serial, box);
    }, 0);
  }

  // +name+'s popover on its text: an older peer answer's "Read the full
  // answer" (peer_links.js; its context source, an ordinary chip now).
  const showText = (name) => showAt(name);
  // Peer +name+'s chip on its message +serial+ (a mailbox note's "Read the
  // full answer", peer_links.js).
  const showMessage = (name, serial, box) => showAt(peerKey(name), serial, box);

  // The peers model read again: the chips and an open peer's popover follow it.
  function peersChanged() {
    if (!sessionId) return;
    drawChips();
    if (groupOf(openKey)) follow();
  }

  return { load, clear, refresh, close, showText, showMessage, peersChanged, get rows() { return rows; } };
}
