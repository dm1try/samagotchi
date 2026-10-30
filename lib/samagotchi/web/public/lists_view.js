// The session lists: the strip of the latest sessions over the chat (with
// its All sessions tile and the hidden strip's pill), the all-sessions view
// (#allList, its search, count and select mode), their cards, and the
// family and chain popovers. Split out of app.js.
//
// The pure parts (a card's markup, the search match, the lists' orders and
// counts) are exported for node specs; createListsView draws them and binds
// the clicks. Everything that changes while the page runs is read through
// deps when a list draws, never captured at creation.
//
// deps:
//   doc, win              document and window
//   topStripEl, allListEl the strip and the all-sessions list
//   sessions()            every session the page knows (archived ones too)
//   selected()            the open session's id, or null
//   scope                 the page's scope (scope.js; projectName read live)
//   scopeError()          why the server refused ?dir, or null
//   eventsLive()          whether the hub's events stream is open
//   refresh()             fetch the list (no events stream)
//   select(id)            open a session
//   confirmDelete(id), setArchived(id, archive), archiveOne(id, archive)
//   updateSessionTitle(), showToast(text, action)
//   allViewOpen(), openAllView(), leaveAllView(hash)
//   renameShown(owner)    whether a card's title has its ✎ (session_title.js)
//   onRename()            the active card's ✎ clicked (session_rename.js open)
//   renaming()            whether that rename input is open (the strip holds)

import { ownerBadge, relativeTime, delegatedBy, cardTitleSource } from "./format.js";
import { html, nothing, render } from "./vendor/lit-html.js";
import { cardCtxText, ctxBarTip } from "./ctx.js";
import { allScopeHref, cardFolder } from "./scope.js";
import { sessionHash } from "./route.js";
import { stripColumns, stripStatusParts } from "./strip.js";
import { createFamilyPop, familyChipTemplate, familyRowsTemplate } from "./families_view.js";
import { allViewChains, chainChipTemplate, chainRowsTemplate, chainTitle, foldChains } from "./chains.js";
import {
  batchCounts, batchTargets, batchToastText, families, familyId, familyOpen, familyWaits, filterFamilies, heldOrder,
  listedSessions, rangeIds, runBatch, stoppedBadge, waitingBadge, waitingFirst, waitingSearchText,
} from "./sessions_list.js";

// Whether a session matches the all view's search +q+ (lower case);
// +title+ is its card's title (cardTitle).
export function matchesFilter(s, q, title) {
  return title.toLowerCase().includes(q) ||
    (s.first_preview || "").toLowerCase().includes(q) ||
    s.short_id.toLowerCase().includes(q) ||
    s.id.toLowerCase().includes(q) ||
    s.status.toLowerCase().includes(q) ||
    waitingSearchText(s).includes(q);
}

// The strip's cards before the pointer's hold and the cut to what fits:
// families in the list's order (a family in its first-listed member's
// place, so a hub upsert doesn't move it), chains folded, waiting ones
// first. A family is one card. +shown+: the strip's sessions (no archived
// ones); +all+: every session (a chain's links).
export function stripOrder(shown, all) {
  return waitingFirst(foldChains(families(shown, { order: "list" }), all));
}

// The all view's families: +all+ (a search and the archived ones see every
// link as a card, allViewChains), +shown+ (the ones a search keeps, with
// their matchIds; every family without a search), waiting ones first, and
// how many delegates +all+ folds in.
// @param matches (session) → whether it matches the search
export function allViewFamilies(listed, every, { query = "", includeArchived = false, matches = () => true } = {}) {
  const all = allViewChains(families(listed), every, { query, includeArchived });
  const shown = query ? filterFamilies(all, matches) : all;
  const delegates = all.reduce((n, f) => n + f.members.length, 0);
  return { all, shown: waitingFirst(shown), delegates };
}

// The all view's count: "14 (+7 delegates)", or "3 / 14" under a search.
export function allCountText(shown, total, delegates) {
  return shown === total
    ? `${total}${delegates ? ` (+${delegates} ${delegates === 1 ? "delegate" : "delegates"})` : ""}`
    : `${shown} / ${total}`;
}

// The All sessions tile's count: the strip's sessions, or "N archived"
// when every session is archived.
export function stripCountText(shown, total) {
  return shown || total === shown
    ? `${shown} ${shown === 1 ? "session" : "sessions"}`
    : `${total - shown} archived`;
}

// How long a new card fades in and a status dot's pulse period: index.html's
// `.card.entering` fadeIn (.28s) and `.card .dot` dot-pulse / attn-pulse (1.6s).
export const CARD_FADE_MS = 280;
export const DOT_PULSE_MS = 1600;

// Which of a list's cards fade in. Every draw makes new nodes (draw), and a
// new node starts its CSS animation again: so only a card the list did not
// draw last time (+prev+: id → when it was first drawn, from performance.now();
// none for a list not drawn yet, or emptied: every card is new) gets
// `entering`, and one drawn again during its own fade keeps it, carried on
// from where it was (+entering+: id → ms since its first draw, the negative
// animation-delay) instead of starting over or snapping to full.
// +ids+: the cards drawn now. +drawn+ is the next draw's +prev+ (only +ids+).
export function enteringCards(prev, ids, now, fadeMs = CARD_FADE_MS) {
  const drawn = new Map();
  const entering = new Map();
  for (const id of ids) {
    const at = prev?.get(id) ?? now;
    drawn.set(id, at);
    if (now - at < fadeMs) entering.set(id, Math.max(0, now - at));
  }
  return { drawn, entering };
}

// A card's inline animation phases: its fade's delay (+enterMs+ into it) and
// the status dots' pulse, phase-locked to the clock (+now+, performance.now())
// so a redrawn dot carries on pulsing where the last one was. "" for neither.
export function cardAnimStyle({ enterMs = null, now = null } = {}, period = DOT_PULSE_MS) {
  const parts = [];
  if (enterMs) parts.push(`--enter-delay:-${Math.round(enterMs)}ms`);
  if (now !== null) parts.push(`--pulse-delay:-${Math.round(now % period)}ms`);
  return parts.join(";");
}

// A card: the first message as its title, then status, how long ago, owner
// and memories. The id is in the tooltip (and the search) only. A session
// that waits on the user (a question, an approval, a card with actions)
// wears the warning colour and says what for.
// deletable / archivable: the all-sessions view's cards get a delete and an
// archive (unarchive, on an archived card) button. selectable: select mode's
// checkbox instead (picked: checked), and skipReason: why a batch skipped it.
// family: the family the session heads (sessions_list.js families): with
// members, its chip (which opens their list), and the card waits when any
// member does; with rows (all sessions) an open family lists its members
// inline, the strip's opens in a popover; matchIds: a search's matching
// members. A family in a session chain (chains.js foldChains) carries its
// `#N` chip, which opens the other links in a popover. entering: a card
// new to its list (enteringCards: it fades in); anim: its inline animation
// phases (cardAnimStyle).
// +ctx+: title (cardTitle), projectName (the page's scope), activeId (the
// open session), chainOpen (its chain's popover is open), parent (the
// delegating session, or null).
// renamable: the title line ends in a ✎ (the strip's cards; CSS shows it on
// the active one alone, since a select only paints the cards again).
export function cardTemplate(s, { deletable = false, archivable = false, selectable = false, picked = false, skipReason = null, family = null, open = false, rows = false, matchIds = null, entering = false, anim = "", renamable = false } = {}, { title = "", projectName = null, activeId = null, chainOpen = false, parent = null } = {}) {
  const fam = family && family.members.length ? family : null;
  const ts = s.updated_at || s.created_at || "";
  const tip = `${s.id} · updated ${ts} · ${s.status}`;
  const memTitle = s.used_memory_names && s.used_memory_names.length ? `mem: ${s.used_memory_names.join(", ")}` : "";
  const ago = relativeTime(ts);
  const time = ago ? html`<span class="time" title=${new Date(ts).toLocaleString()}>${ago}</span>` : nothing;
  const folder = cardFolder(s.working_directory, projectName);
  const folderT = folder ? html`<span class="folder" title=${s.working_directory}>${folder}</span>` : nothing;
  const archived = s.archived ? html`<span class="archived-badge" title="Archived: hidden from the lists, kept for good">archived</span>` : nothing;
  const ctx = cardCtxText(s.ctx_pct);
  const ctxT = ctx ? html`<span class="ctx" title=${ctxBarTip(s.tokens, s.memory_index, { pct: s.ctx_pct }, null, s.side)}>${ctx}</span>` : nothing;
  const waiting = waitingBadge(s);
  const waitingT = waiting ? html`<span class=${`attn attn-${waiting.kind}`} title=${waiting.title}>${waiting.text}</span>` : nothing;
  // A turn a hook stopped wears its own badge, unless the session waits on
  // the user (the waiting badge wins: the stop is behind the need).
  const stopped = waiting ? null : stoppedBadge(s);
  const stoppedT = stopped ? html`<span class="stopped-badge" title=${stopped.title}>${stopped.text}</span>` : nothing;
  const dotWord = waiting ? waiting.title : s.status;
  const pick = selectable ? html`<input type="checkbox" class="card-pick" aria-label=${`Select session ${s.short_id}`} ?checked=${picked}>` : nothing;
  const skip = skipReason ? html`<div class="skip-reason">skipped: ${skipReason}</div>` : nothing;
  const familyWaiting = !!family && familyWaits(family);
  // The family and chain chips and rows (families_view.js, chains.js).
  const chain = family?.chain ? chainChipTemplate(family, { open: chainOpen }) : nothing;
  const kids = fam ? familyChipTemplate(fam, { open }) : nothing;
  const famRows = fam && rows && open ? familyRowsTemplate(fam, { activeId, matchIds, archivable: !selectable }) : nothing;
  // Its delegates and its chain's other links: the card is .contains-active while one is open.
  const memberIds = [...(fam ? fam.members.map((m) => m.session.id) : []),
    ...(family?.chain ? family.chain.links.map((x) => x.id).filter((id) => id !== s.id) : [])];
  const cls = `card${s.archived ? " archived" : ""}${waiting || familyWaiting ? " waiting" : ""}${selectable && picked ? " picked" : ""}${fam && rows && open ? " family-open" : ""}${entering ? " entering" : ""}`;
  const preview = renamable
    ? html`<div class="preview-row"><div class="preview">${title}</div><button type="button" class="card-rename" data-rename=${s.id} title="Rename this session" aria-label="Rename this session">\u270e</button></div>`
    : html`<div class="preview">${title}</div>`;
  // No recap line when the title is the recap's first sentence (D5).
  const recap = s.recap && cardTitleSource(s) !== "recap" ? html`<div class="recap" title=${s.recap}>${s.recap}</div>` : nothing;
  return html`<div class=${cls} data-id=${s.id} data-members=${memberIds.length ? memberIds.join(" ") : nothing} style=${anim || nothing} title=${`${tip}${memTitle ? ` · ${memTitle}` : ""}`}>${preview}${recap}<div class="meta"><span class=${`status dot ${s.status}${waiting ? " waiting" : ""}`} title=${dotWord} aria-label=${dotWord}></span>${waitingT}${stoppedT}${time}${ctxT}${folderT}${parentChipTemplate(s, parent)}${chain}${kids}${ownerBadgeTemplate(s)}${archived}</div>${famRows}${skip}${pick}${selectable ? nothing : cardToolsTemplate(s, { deletable, archivable })}</div>`;
}

function cardToolsTemplate(s, { deletable, archivable }) {
  if (!deletable && !archivable) return nothing;
  const short = s.short_id;
  const arch = !archivable ? nothing : s.archived
    ? html`<button type="button" class="card-arch" data-arch=${s.id} title=${"Unarchive: back to the lists"} aria-label=${`Unarchive session ${short}`}></button>`
    : html`<button type="button" class="card-arch" data-arch=${s.id} title=${"Archive: hide from the lists, keep for good"} aria-label=${`Archive session ${short}`}></button>`;
  const del = deletable ? html`<button type="button" class="card-del" data-del=${s.id} title=${"Delete session"} aria-label=${`Delete session ${short}`}>\u2715</button>` : nothing;
  // title is bound, as data-arch and aria-label are, so the attributes keep
  // their order (lit sets bound ones after the static ones).
  return html`<div class="card-tools">${arch}${del}</div>`;
}

// A delegated session's `↳ <parent>` chip; the parent's preview is the tooltip.
function parentChipTemplate(s, parent) {
  const chip = delegatedBy(s.parent_id, parent);
  return chip ? html`<span class="parent" title=${chip.title}>${chip.text}</span>` : nothing;
}

function ownerBadgeTemplate(s) {
  const badge = ownerBadge(s.owner, s.id);
  return badge ? html`<span class=${`owner ${badge.kind}`} title=${badge.title}>${badge.text}</span>` : nothing;
}

// The strip's end: the All sessions tile (with its count), the strip's own
// last cell (the grip on the edge is the strip's handle now, not a button
// in here). entering / anim: as a card's (cardTemplate). id and title are
// bound, as class is, so the attributes keep their order.
export function stripTileTemplate(count, { entering = false, anim = "" } = {}) {
  return html`<button type="button" class=${entering ? "card entering" : "card"} id=${"allTile"} style=${anim || nothing} title=${"All sessions, with search"}>All sessions →<span class="count">${count}</span></button>`;
}

// The hidden strip's status pill: "5 sessions · ● 1 live · ● 1 waiting"
// (strip.js stripStatusParts). Not a toggle any more (the grip hides and
// shows the strip): a click opens the all-sessions view, as the tile does.
// The count (and the dot after it) in its own span: a phone's narrow top
// bar drops it when live or waiting shows (index.html).
export function stripPillTemplate({ count, live, waiting }) {
  const liveT = live ? html`<span class="live"><span class="live-dot" aria-hidden="true"></span>${live}</span>` : nothing;
  const waitingT = waiting ? html`${live ? " · " : ""}<span class="waiting"><span class="waiting-dot" aria-hidden="true"></span>${waiting}</span>` : nothing;
  return html`<span class="pill-count">${count}${live || waiting ? " · " : ""}</span>${liveT}${waitingT}`;
}

// Draws +template+ into +el+ as new nodes, as an innerHTML write did: no
// node of the last draw is kept (the cards' clicks are bound per draw, and
// a card's checked box or marks never carry over to another session's).
function draw(el, template) {
  const frag = el.ownerDocument.createDocumentFragment();
  render(template, frag);
  el.replaceChildren(frag);
}

export function createListsView(deps) {
  const {
    doc, win, topStripEl, allListEl, sessions, selected, scope, scopeError, eventsLive, refresh, select,
    confirmDelete, setArchived, archiveOne, updateSessionTitle, showToast,
    allViewOpen, openAllView, leaveAllView, renameShown = () => false, onRename = () => {}, renaming = () => false,
  } = deps;
  const $ = (s) => doc.querySelector(s);

  // The hidden strip's status pill opens the all-sessions view (as the tile
  // does), saving the step of showing the strip first. Bound once: the pill
  // element stays, only its content is drawn again (draw()).
  $("#stripStatus").addEventListener("click", openAllView);

  // The strip, its count and the hidden strip's pill leave archived sessions
  // out; the all view shows them with "include archived". sessions() keeps
  // them all (parent chips, the open session).
  function shownSessions() {
    return listedSessions(sessions(), false);
  }

  function allViewSessions() {
    return listedSessions(sessions(), $("#includeArchived").checked);
  }

  function filterQuery() {
    return $("#filter").value.trim().toLowerCase();
  }

  // The page's sessions by id, built again only when the list changed.
  let byIdOf = { list: null, map: new Map() };
  function sessionsById() {
    const all = sessions();
    if (byIdOf.list !== all) byIdOf = { list: all, map: new Map(all.map((s) => [s.id, s])) };
    return byIdOf.map;
  }

  // A card's title: its preview, or its chain's first link's for a link
  // titled with the opener (chains.js chainTitle; display only).
  function cardTitle(s) {
    return chainTitle(s, sessionsById());
  }

  // A card with no title yet ("—": no first message) has no ✎ either.
  function cardFor(s, opts) {
    const title = cardTitle(s);
    return cardTemplate(s, { ...opts, renamable: !!opts.renamable && title !== "\u2014" }, {
      title,
      projectName: scope.projectName,
      activeId: selected(),
      chainOpen: !!opts.family?.chain && chainOpenHead() === s.id,
      parent: sessions().find((x) => x.id === s.parent_id) || null,
    });
  }

  // The strip's card count follows the window: more cards on wide screens
  // (each capped at 440 px) instead of 3 stretched ones. main's 16 px padding
  // sits on both sides; measuring main works while the strip is hidden too.
  let stripCols = 3;
  function fitStripColumns() {
    stripCols = stripColumns(topStripEl.parentElement.clientWidth - 32);
    topStripEl.style.setProperty("--strip-cols", stripCols);
  }

  // The order a list draws its cards in: +next+, what waits on the user
  // first (waitingFirst), back to its place once answered. Never under the
  // pointer, though: while it is over the list the order last drawn holds,
  // and its leaving draws the list again. A hidden list holds nothing: the
  // strip keeps :hover for a moment after a click on its All sessions tile
  // hid it, and an update held then brought it back from the all view in an
  // order nobody saw (a waiting family behind). +idOf+ names a card: a
  // session's id, or familyId (a card per family: its head's id). drawnOrder
  // is the cards drawn, which select mode picks from.
  const drawnOrder = new Map(); // list element → card ids in the order last drawn
  const heldLists = new Set(); // lists drawn in a held order
  // Lists whose last draw was hidden (the strip under the all view, which
  // the store's list write draws as the view opens): that order was never
  // seen, so a hover that stuck on the strip doesn't hold it afterwards.
  const drawnHidden = new Set();
  const canHover = win.matchMedia?.("(hover: hover)").matches ?? false;
  function listOrder(el, next, idOf = (s) => s.id) {
    // The strip's popover holds it too (the pointer leaves the strip for it,
    // and a touch screen has no hover at all), and so does a rename typed
    // over its active card (the card doesn't jump away under the input).
    const shown = el.getClientRects().length > 0;
    const holding = shown
      && ((canHover && el.matches(":hover")) || (el === topStripEl && (familyPop.isOpen() || renaming())) || chainPopIn(el));
    const held = holding && !drawnHidden.has(el) ? drawnOrder.get(el) : null;
    const ordered = held ? heldOrder(held, next, idOf) : next;
    if (held && ordered.some((x, i) => idOf(x) !== idOf(next[i]))) heldLists.add(el);
    else heldLists.delete(el);
    drawnOrder.set(el, ordered.map(idOf));
    if (shown) drawnHidden.delete(el);
    else drawnHidden.add(el);
    return ordered;
  }

  // The cards each list actually drew (the strip's after its cut to what
  // fits; not drawnOrder, which select mode reads), id → when first drawn:
  // a card not in it fades in (enteringCards). A list drawn empty forgets.
  const lastDrawn = new Map(); // list element → Map(id → performance.now() at its first draw)
  const STRIP_TILE = "#allTile"; // the All sessions tile's id there (no session id starts with #)
  function enteringFor(el, ids) {
    const now = win.performance?.now() ?? Date.now();
    const { drawn, entering } = enteringCards(lastDrawn.get(el), ids, now);
    lastDrawn.set(el, drawn);
    return (id) => ({ entering: entering.has(id), anim: cardAnimStyle({ enterMs: entering.get(id), now }) });
  }

  // The strip's cards: stripOrder, held under the pointer, as many as fit.
  function stripCards() {
    return listOrder(topStripEl, stripOrder(shownSessions(), sessions()), familyId).slice(0, stripCols);
  }

  // The strip's family popover (families_view.js): the open family's rows,
  // under its chip.
  let stripFamilies = new Map(); // head id → family, as the strip last drew it
  const familyPop = createFamilyPop({
    doc,
    win,
    rowsFor: (id) => {
      const f = stripFamilies.get(id);
      return f && f.members.length ? familyRowsTemplate(f, { activeId: selected() }) : null;
    },
    anchorFor: (id) => [...topStripEl.querySelectorAll(".card[data-id] .family-chip")].find((chip) => chip.closest(".card").dataset.id === id) || null,
    onPick: (id) => {
      familyPop.close();
      select(id);
    },
    // A strip order held while it was open catches up (unless the pointer is
    // back over the strip: its leaving does it then).
    onClose: () => {
      if (heldLists.has(topStripEl) && !(canHover && topStripEl.matches(":hover"))) renderTop(stripCards());
    },
  });
  win.addEventListener("keydown", (e) => familyPop.onKeydown(e), true);
  doc.addEventListener("pointerdown", (e) => familyPop.onPointerDown(e), true);
  doc.addEventListener("scroll", () => familyPop.reposition(), true);

  // A chain's popover (chains.js): the other links of the chain a card's
  // `#N` chip stands for, under the chip, in the strip or all sessions
  // (the list it was opened from: chainFrom). A row opens that link.
  const chainFamilies = new Map(); // head id → family, as the lists last drew it
  let chainFrom = null; // the list element the open popover's chip is in
  const chainPop = createFamilyPop({
    id: "chainPop",
    doc,
    win,
    rowsFor: (id) => {
      const f = chainFamilies.get(id);
      return f?.chain ? chainRowsTemplate(f, { activeId: selected() }) : null;
    },
    anchorFor: (id) => (chainFrom ? [...chainFrom.querySelectorAll(".card[data-id] .chain-chip")].find((chip) => chip.closest(".card").dataset.id === id) || null : null),
    onPick: (id) => {
      chainPop.close();
      if (allViewOpen()) leaveAllView(sessionHash(id));
      select(id);
    },
    // chainFrom stays (Esc focuses the chip again after the close); only an
    // open popover holds a list (chainPopIn).
    onClose: () => {
      if (chainFrom === topStripEl && heldLists.has(topStripEl) && !(canHover && topStripEl.matches(":hover"))) renderTop(stripCards());
    },
  });
  function chainOpenHead() {
    return chainPop.openHead();
  }
  function chainPopIn(el) {
    return chainPop.isOpen() && chainFrom === el;
  }
  function toggleChainPop(from, id, e) {
    if (chainPop.openHead() === id && chainFrom === from) {
      chainPop.close();
      return;
    }
    chainPop.close();
    chainFrom = from;
    chainPop.open(id);
    // From the keyboard the focus goes into the popover; Esc brings it back.
    if (e?.detail === 0 && chainPop.isOpen()) $("#chainPop .fr-open")?.focus();
  }
  win.addEventListener("keydown", (e) => chainPop.onKeydown(e), true);
  doc.addEventListener("pointerdown", (e) => chainPop.onPointerDown(e), true);
  doc.addEventListener("scroll", () => chainPop.reposition(), true);

  function render() {
    fitStripColumns();
    renderTop(stripCards());
    if (allViewOpen()) renderAll();
  }

  let stripResizeTimer = null;
  win.addEventListener("resize", () => {
    clearTimeout(stripResizeTimer);
    stripResizeTimer = setTimeout(() => {
      const before = stripCols;
      fitStripColumns();
      if (stripCols !== before && sessions().length) renderTop(stripCards());
      familyPop.reposition();
      chainPop.reposition();
    }, 150);
  });

  // onPick: a card's click (open it, or pick it in select mode); onFamily:
  // a family chip's (toggle its list); onRow: a family row's (open that
  // delegate).
  function bindCards(container, onPick, { onFamily = () => {}, onRow = () => {} } = {}) {
    container.querySelectorAll(".card[data-id]").forEach((el) => {
      el.addEventListener("click", (e) => {
        const chainChip = e.target.closest(".chain-chip");
        if (chainChip) {
          e.stopPropagation();
          toggleChainPop(container, el.dataset.id, e);
          return;
        }
        const chip = e.target.closest(".family-chip");
        if (chip) {
          e.stopPropagation();
          onFamily(el.dataset.id, chip, e);
          return;
        }
        const ren = e.target.closest(".card-rename");
        if (ren) {
          e.stopPropagation();
          onRename();
          return;
        }
        const del = e.target.closest(".card-del");
        if (del) {
          e.stopPropagation();
          confirmDelete(del.dataset.del);
          return;
        }
        // Archive from the list: the view stays open, the toast has Undo.
        const arch = e.target.closest(".card-arch");
        if (arch) {
          e.stopPropagation();
          const id = arch.dataset.arch;
          setArchived(id, !sessions().find((x) => x.id === id)?.archived);
          return;
        }
        const row = e.target.closest(".family-row[data-id]");
        if (row) {
          e.stopPropagation();
          onRow(row.dataset.id, e);
          return;
        }
        onPick(el.dataset.id, e);
      });
    });
    paintActive();
  }

  // The open session's marks: its card (.active), its row in a family's list
  // (in a card or the strip's popover), and a quieter .contains-active on the
  // card of the family it is folded into.
  function paintActive() {
    const id = selected();
    doc.querySelectorAll(".card[data-id]").forEach((el) => {
      el.classList.toggle("active", !!id && el.dataset.id === id);
      el.classList.toggle("contains-active", !!id && (el.dataset.members || "").split(" ").includes(id));
    });
    doc.querySelectorAll(".family-row[data-id]").forEach((el) => {
      el.classList.toggle("active", !!id && el.dataset.id === id);
    });
    // The open session's card may have come into the strip or left it.
    updateSessionTitle();
  }

  // The latest sessions (as many as fit, a family one card), then the way
  // to all of them.
  function renderTop(cards) {
    topStripEl.classList.remove("loading");
    renderStripStatus();
    stripFamilies = new Map(cards.map((f) => [f.head.id, f]));
    noteChainFamilies(cards);
    const refused = scopeError();
    if (refused) {
      draw(topStripEl, html`<div class="hint scope-error">${refused} · <a href=${allScopeHref("", null, win.location.search)}>show every session</a></div>`);
      lastDrawn.delete(topStripEl);
      familyPop.close();
      chainPop.close();
      return;
    }
    const all = sessions();
    // Only archived sessions: no cards, but the tile stays, the way to them.
    if (!all.length) {
      topStripEl.replaceChildren();
      lastDrawn.delete(topStripEl);
      familyPop.close();
      chainPop.close();
      return;
    }
    const anim = enteringFor(topStripEl, [...cards.map(familyId), STRIP_TILE]);
    const tile = stripTileTemplate(stripCountText(shownSessions().length, all.length), anim(STRIP_TILE));
    draw(topStripEl, html`${cards.map((f) => cardFor(f.head, { family: f, open: familyPop.openHead() === f.head.id, renamable: renameShown(f.head.owner), ...anim(familyId(f)) }))}${tile}`);
    bindCards(topStripEl, select, {
      onFamily: (id, _chip, e) => {
        familyPop.toggle(id);
        // From the keyboard (Enter / Space: no pointer, detail 0) the focus
        // goes into the popover, which sits at the end of body; Esc brings it back.
        if (e.detail === 0 && familyPop.isOpen()) $("#familyPop .fr-open")?.focus();
      },
    });
    $("#allTile").addEventListener("click", openAllView);
    familyPop.refresh();
    if (chainFrom === topStripEl) chainPop.refresh();
  }

  // The chain families a list drew: the popover's rows come from them.
  function noteChainFamilies(fams) {
    for (const f of fams) {
      if (f.chain) chainFamilies.set(f.head.id, f);
      else chainFamilies.delete(f.head.id);
    }
  }

  // The hidden strip's pill, following the list: its sessions, the number
  // the All sessions tile shows, and the live and waiting ones (a waiting
  // delegate too).
  function renderStripStatus() {
    draw($("#stripStatus"), stripPillTemplate(stripStatusParts(shownSessions())));
  }

  // A parent's card holds its delegates (families, by the newest member: a
  // hub snapshot hands the list back in the server's order), folded unless
  // one waits on the user, a search matched one or the user opened it. The
  // search runs over the families, so a matching delegate brings its parent's
  // card along. Select mode picks cards (a family's rows have no checkbox:
  // archiving the parent takes its delegates).
  const familyToggles = new Map(); // head id → open, the user's chip clicks (this page's life)
  const searchToggles = new Map(); // the same while a search matched a member; a new search clears it
  const drawnOpen = new Map(); // head id → open as last drawn in all sessions

  function renderAll() {
    const listed = allViewSessions();
    const q = filterQuery();
    const { all, shown, delegates } = allViewFamilies(listed, sessions(), {
      query: q, includeArchived: $("#includeArchived").checked, matches: (s) => matchesFilter(s, q, cardTitle(s)),
    });
    noteChainFamilies(all);
    const fams = listOrder(allListEl, shown, familyId);
    $("#count").textContent = allCountText(fams.length, all.length, delegates);
    updateSelectBar();
    if (!fams.length) {
      drawnOpen.clear();
      lastDrawn.delete(allListEl);
      draw(allListEl, html`<div class="hint">${listed.length ? "No session matches." : "No sessions yet."}</div>`);
      if (chainFrom === allListEl) chainPop.refresh();
      return;
    }
    // A hub event redraws the list under a checkbox or a chip the keyboard is on.
    const focusSel = [".card-pick", ".family-chip", ".chain-chip"].find((sel) => doc.activeElement?.matches?.(`#allList ${sel}`));
    const focused = focusSel ? { id: doc.activeElement.closest(".card")?.dataset.id, sel: focusSel } : null;
    const opts = (s) => (selecting.on
      ? { selectable: true, picked: selecting.picked.has(s.id), skipReason: selecting.skipReasons.get(s.id) }
      : { deletable: true, archivable: true });
    drawnOpen.clear();
    const anim = enteringFor(allListEl, fams.map(familyId));
    draw(allListEl, html`${fams.map((f) => {
      const matched = !!f.matchIds?.size;
      const open = familyOpen(f, matched ? searchToggles : familyToggles, { matched });
      drawnOpen.set(f.head.id, open);
      return cardFor(f.head, { ...opts(f.head), family: f, open, rows: true, matchIds: q ? f.matchIds : null, ...anim(familyId(f)) });
    })}`);
    bindCards(allListEl, (id, e) => {
      if (selecting.on) {
        togglePick(id, e);
        return;
      }
      leaveAllView(sessionHash(id));
      select(id);
    }, {
      onFamily: (headId) => {
        const matched = !!q && !!fams.find((f) => f.head.id === headId)?.matchIds?.size;
        (matched ? searchToggles : familyToggles).set(headId, !drawnOpen.get(headId));
        renderAll();
      },
      // In select mode a row does nothing: rows aren't picked.
      onRow: (id) => {
        if (selecting.on) return;
        leaveAllView(sessionHash(id));
        select(id);
      },
    });
    if (focused?.id) allListEl.querySelector(`.card[data-id="${focused.id}"] ${focused.sel}`)?.focus();
    if (chainFrom === allListEl) chainPop.refresh();
  }

  // ── Select mode (all sessions) ─────────────────────────────────────────────
  // "Select" turns the cards into picks: a click (or Shift-click, a range in
  // the drawn order) toggles one instead of opening it, and the bar acts on
  // the picked ones that are shown. The picks live here, not in the DOM:
  // renderAll draws the list again on every hub event.
  const selecting = {
    on: false,
    picked: new Set(),
    last: null, // the last toggled id: a Shift-click's range starts there
    skipReasons: new Map(), // id → why the last batch skipped it
    running: null, // {done, total, archive} while a batch runs
  };

  function enterSelect() {
    selecting.on = true;
    renderAll();
  }

  function leaveSelect() {
    selecting.on = false;
    selecting.picked.clear();
    selecting.last = null;
    selecting.skipReasons.clear();
    if (allViewOpen()) renderAll();
    else updateSelectBar();
  }

  function togglePick(id, e) {
    if (selecting.running) return; // the grid reflows while a batch runs
    const order = drawnOrder.get(allListEl) || [];
    const on = !selecting.picked.has(id);
    const ids = e?.shiftKey ? rangeIds(order, selecting.last, id) : [id];
    for (const x of ids) {
      if (on) selecting.picked.add(x);
      else selecting.picked.delete(x);
      paintPick(x);
    }
    selecting.last = id;
    updateSelectBar();
  }

  // A card's pick state in place (no redraw: the focus stays put).
  function paintPick(id) {
    const el = allListEl.querySelector(`.card[data-id="${id}"]`);
    if (!el) return;
    const on = selecting.picked.has(id);
    el.classList.toggle("picked", on);
    const box = el.querySelector(".card-pick");
    if (box) box.checked = on;
  }

  // The bar's numbers: picks of sessions still in the list (a snapshot can
  // drop one with no session_gone), and the shown ones a batch would act on.
  function selectCounts() {
    const byId = new Map(sessions().map((s) => [s.id, s]));
    const shown = drawnOrder.get(allListEl) || [];
    const shownSet = new Set(shown);
    const live = [...selecting.picked].filter((id) => byId.has(id));
    return {
      picked: live.length,
      hidden: live.filter((id) => !shownSet.has(id)).length,
      archive: batchTargets(selecting.picked, shown, true, byId),
      unarchive: batchTargets(selecting.picked, shown, false, byId),
    };
  }

  function updateSelectBar() {
    $("#allView").classList.toggle("selecting", selecting.on);
    $("#selectBtn").hidden = selecting.on;
    const bar = $("#selectBar");
    bar.hidden = !selecting.on;
    if (!selecting.on) return;
    const c = selectCounts();
    const run = selecting.running;
    $("#selectCount").textContent = run
      ? `${run.archive ? "Archiving" : "Unarchiving"} ${run.done}/${run.total}…`
      : `${c.picked} selected${c.hidden ? ` · ${c.hidden} not shown` : ""}`;
    $("#batchArchiveBtn").textContent = `Archive ${c.archive.length}`;
    $("#batchArchiveBtn").disabled = !!run || !c.archive.length;
    $("#batchUnarchiveBtn").textContent = `Unarchive ${c.unarchive.length}`;
    $("#batchUnarchiveBtn").hidden = !c.unarchive.length;
    $("#batchUnarchiveBtn").disabled = !!run;
    $("#selectAllBtn").disabled = !!run;
    $("#selectDoneBtn").disabled = !!run;
  }

  // The batch: the picked shown ones, one request at a time in the drawn
  // order (parents before their delegates), through the info bar's
  // archiveOne. A refused one stays picked with the server's reason on its
  // card; the end toast's Undo runs the opposite batch on the ones that went.
  async function runSelectBatch(archive) {
    if (selecting.running) return;
    const byId = new Map(sessions().map((s) => [s.id, s]));
    const ids = batchTargets(selecting.picked, drawnOrder.get(allListEl) || [], archive, byId);
    if (!ids.length) return;
    selecting.skipReasons.clear();
    const outcome = await archiveBatch(ids, archive);
    if (!outcome) return;
    if (!allViewOpen()) leaveSelect(); // left the view while it ran
    else renderAll();
    showToast(batchToastText(batchCounts(outcome, archive)), outcome.done.length ? {
      label: "Undo",
      run: async () => {
        const undone = await archiveBatch(outcome.done, !archive);
        if (!undone) return;
        if (allViewOpen()) renderAll();
        showToast(batchToastText(batchCounts(undone, !archive)));
      },
    } : null);
  }

  // runBatch over archiveOne, with the bar's progress; the picks and skip
  // reasons follow the outcome. null when a batch already runs.
  async function archiveBatch(ids, archive) {
    if (selecting.running) return null;
    selecting.running = { done: 0, total: ids.length, archive };
    updateSelectBar();
    try {
      // An archived one flips in the store's list (archiveOne): the lists
      // and the bar redraw from there.
      const outcome = await runBatch(ids, (id) => archiveOne(id, archive), (done) => {
        selecting.running.done = done;
        updateSelectBar();
      });
      for (const id of [...outcome.done, ...outcome.covered, ...outcome.gone]) {
        selecting.picked.delete(id);
        selecting.skipReasons.delete(id);
      }
      for (const { id, reason } of outcome.skipped) selecting.skipReasons.set(id, reason);
      return outcome;
    } finally {
      selecting.running = null;
      updateSelectBar();
      if (!eventsLive()) refresh();
    }
  }

  $("#batchArchiveBtn").addEventListener("click", () => runSelectBatch(true));
  $("#batchUnarchiveBtn").addEventListener("click", () => runSelectBatch(false));
  $("#selectBtn").addEventListener("click", enterSelect);
  $("#selectDoneBtn").addEventListener("click", leaveSelect);
  $("#selectAllBtn").addEventListener("click", () => {
    for (const id of drawnOrder.get(allListEl) || []) {
      selecting.picked.add(id);
      paintPick(id);
    }
    updateSelectBar();
  });
  // A Shift-click picks a range: keep the browser from selecting the text
  // between the two cards.
  allListEl.addEventListener("mousedown", (e) => {
    if (selecting.on && e.shiftKey) e.preventDefault();
  });

  $("#includeArchived").addEventListener("change", () => {
    if (allViewOpen()) renderAll();
  });
  $("#filter").addEventListener("input", () => {
    searchToggles.clear();
    renderAll();
  });
  // A list whose order was held under the pointer (listOrder) catches up.
  topStripEl.addEventListener("pointerleave", () => {
    // Not while its family popover is open: the pointer went there (close() catches up).
    if (heldLists.has(topStripEl) && !familyPop.isOpen()) renderTop(stripCards());
  });
  allListEl.addEventListener("pointerleave", () => {
    if (heldLists.has(allListEl) && allViewOpen()) renderAll();
  });

  return {
    render,
    renderAll,
    // The rename input closed: a strip held for it catches up (unless the
    // pointer or a popover holds it still).
    catchUp() {
      if (heldLists.has(topStripEl) && !(canHover && topStripEl.matches(":hover")) && !familyPop.isOpen() && !chainPopIn(topStripEl)) {
        renderTop(stripCards());
      }
    },
    paintActive,
    cardTitle,
    sessionsById,
    selecting,
    leaveSelect,
    // A session the hub says is gone: no pick, no skip reason.
    forget(id) {
      selecting.picked.delete(id);
      selecting.skipReasons.delete(id);
    },
    familyPop,
    chainPop,
  };
}
