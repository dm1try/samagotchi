// The working set's page parts (web.working_set, the stage view): the turns'
// sets the page keeps (a reload's, then one per hand-off), the footprint
// line under each finished turn's block, the session bar's "set N" chip,
// the expanded view (a chip_popover.js popover; a bottom sheet on a phone)
// and the step tags' jump to a call. The rail is working_set_rail.js's; the
// rules are working_set.js's.
//
// The server's projection (WorkingSet: a :working_set_updated event, a GET
// working_set when a session's set is seeded and when the expanded view
// opens) is one session-wide snapshot: an event always taken, a GET's
// answer unless an event overtook it (working_set.js newerSnapshot); every form
// overlays its state and tokens on the rows' items by key (working_set.js
// overlay), so a state is the item's now, not then. A new snapshot redraws
// them all: the chip, the open popover, the footprints in place and the rail
// (onServer).
//
// A row's place is ordinals, stamped on the DOM: data-turn on a turn's
// .turn-work block (its place in the page's turns) and data-at="step.row"
// on its tool rows, live (stampRows) and reloaded (stampHistory); a jump
// finds the row by them, never by a row key.
import { html, nothing, render, svg } from "./vendor/lit-html.js";
import { createChipPopover } from "./chip_popover.js";
import { showRow } from "./refs.js";
import {
  BUDGETS, fold, footprint, footprintText, GLYPHS, isFresh, itemsOfTurn, labelText, labelTitle, newerSnapshot, opsText, overlay,
  sessionItems, stepRange, stepTag, tokensText,
} from "./working_set.js";

// The popover's files fold to this many lines (groups open in place, one at
// a time), its memories past this many to one group.
const POP_BUDGET = 6;

// A reloaded turn's items: its steps (timing.js turnGroups) as gens.
export function groupItems(group, ordinal) {
  return itemsOfTurn({ gens: (group.steps || []).map((step) => ({ tools: step.tools || [] })) }, ordinal);
}

// The live turn's block and rows stamped with their ordinals (+turn+: the
// turn's model; new rows only).
export function stampRows(blockEl, turn, ordinal) {
  if (!blockEl || !turn) return;
  if (blockEl.dataset.turn !== String(ordinal)) blockEl.dataset.turn = String(ordinal);
  turn.gens.forEach((gen, step) => {
    gen.tools.forEach((row, i) => {
      const el = blockEl.querySelector(`.activity-row[data-key="${String(row.key).replace(/"/g, '\\"')}"]`);
      if (el && !el.dataset.at) el.dataset.at = `${step}.${i}`;
    });
  });
}

// A reloaded history's blocks stamped: +blocks+ the .turn-work elements,
// +ordinals+ each one's turn.
export function stampHistory(blocks, ordinals) {
  blocks.forEach((block, i) => {
    block.dataset.turn = String(ordinals[i]);
    [...block.querySelectorAll(":scope > .gen")].forEach((gen, step) => {
      [...gen.querySelectorAll(":scope > .activity-body > .activity-row")].forEach((row, j) => { row.dataset.at = `${step}.${j}`; });
    });
  });
}

function atAttr(at) {
  return `${at.turn}.${at.step}.${at.row}`;
}

// A label's step tag in the footprint: a memory's step, a memory group's
// range (it jumps to the first); none for files and URLs.
function footTag(label) {
  if (label.kind !== "memory") return nothing;
  const first = label.members.find((m) => m.at);
  if (!first) return nothing;
  const text = label.type === "leaf" ? stepTag(first) : stepRange(label.members);
  const title = label.type === "leaf" ? `entered at step ${first.at.step + 1}: go to the call` : `entered at ${text}: go to the first call`;
  return html` <button type="button" class="ws-step p" data-ws="jump" data-at=${atAttr(first.at)} title=${title}>${text}</button>`;
}

// The footprint line of a finished turn's +items+ (turn +ordinal+), nothing
// for a turn that touched nothing: "touched web/public/ · 9 files · ◆ 3
// memories s1–5 · +1 url · edited 2". A click opens the expanded view at
// that turn; a step tag jumps to its call.
export function footprintTemplate(items, ordinal) {
  const fp = footprint(items, BUDGETS.footprint);
  if (!fp) return nothing;
  const sep = html` <span class="sep">·</span> `;
  const parts = fp.labels.map((l, i) => html`${i ? sep : nothing}<span class=${`l ${l.kind}${l.state && l.state !== "live" ? ` ${l.state}` : ""}`} title=${labelTitle(l)}>${l.glyph ? html`<span class="k">${l.glyph}</span> ` : nothing}${labelText({ ...l, glyph: "" })}</span>${footTag(l)}`);
  const text = footprintText(items, BUDGETS.footprint);
  return html`<div class="ws-foot" role="button" tabindex="0" data-ws-turn=${ordinal} data-ws-sig=${footSig(items)} aria-label=${`Working set of this turn: ${text.replace(/^touched /, "")}. Open the list.`}><span class="w">touched</span> ${parts}${fp.tail ? html`${sep}<span class="w">${fp.tail}</span>` : nothing}${fp.edited ? html`${sep}<span class="e">edited ${fp.edited}</span>` : nothing}${fp.forgotten ? html`${sep}<span class="f">${fp.forgotten} forgotten</span>` : nothing}</div>`;
}

// What a footprint shows that can change after it is drawn: its items'
// states (the server's). The same signature draws nothing.
function footSig(items) {
  return items.map((i) => `${i.kind}:${i.key}:${i.state || "live"}`).join("|");
}

// The footprint as an element (the hand-off's), or null.
export function footprintNode(items, ordinal) {
  const template = footprintTemplate(items, ordinal);
  if (template === nothing) return null;
  const frag = document.createDocumentFragment();
  render(template, frag);
  return frag.querySelector(".ws-foot");
}

function ringTemplate(pct) {
  if (!Number.isFinite(pct)) return nothing;
  const value = Math.max(0, Math.min(100, Math.round(pct)));
  const len = 2 * Math.PI * 5.5;
  const bucket = value >= 90 ? " danger" : value >= 70 ? " warn" : "";
  return html`<svg class=${`ws-ring${bucket}`} viewBox="0 0 14 14" role="img">${svg`<title>context ${value}% used</title><circle class="track" cx="7" cy="7" r="5.5"></circle><circle class="fill" cx="7" cy="7" r="5.5" stroke-dasharray=${`${(len * value) / 100} ${len}`}></circle>`}</svg>`;
}

// A group's member as the popover names it: its path below the group's
// directory ("adapters/by_api.rb"), else its leaf text.
function memberName(item, group) {
  if (item.kind === "file" && group?.dir) return String(item.path || item.key).slice(group.dir.length + 1);
  return item.label;
}

// +historyEl+: where finished turns are; +stageRoot()+: the stage (the live
// turn's block); +state()+: the open session's fields (session_state.js:
// ctxPct and the preloaded, muted and used memories); +session()+: its id;
// +infoEl+: the session bar's line (the chip's popover is delegated there);
// +onChange()+: the chip's count or dot changed (app.js updateInfoBar).
// +getWorkingSet(id)+: the server's projection (data.js; null: none asked).
export function createWorkingSet({ historyEl, stageRoot = () => null, state, session = () => null, infoEl, onChange = () => {}, getWorkingSet = null, doc = document }) {
  // The finished turns' sets ({items, prompt}), the running turn's (null:
  // none), the rail's first-sight times (its fresh cue), the session count
  // at the last open (the chip's dot).
  let turns = [];
  let live = null;
  let seenAt = () => undefined;
  let openedCount = 0;
  // The open view: its scope ("turn" / "session"), its turn, the group open
  // in it.
  let view = { scope: "session", turn: null };
  let openGroup = null;
  // The server's snapshot ({items, at}) and the session it is of; what
  // redraws the rail when it changes. +events+ counts the events taken, so
  // a GET knows whether one came while it was on its way.
  let server = null;
  let serverOf = null;
  let events = 0;
  const listeners = new Set();
  const lit = (items) => overlay(items, server);

  const sessionSet = () => {
    const st = state();
    const set = sessionItems({
      turns: turns.map((t) => t.items), live: live?.items || [], preloaded: st.preloadedMemories, muted: st.mutedMemories,
      used: st.usedMemories,
    });
    return { items: lit(set.items), muted: set.muted };
  };
  const turnItems = (t) => lit(live && t === live.ordinal ? live.items : turns[t]?.items || []);
  const promptOf = (t) => (live && t === live.ordinal ? live.prompt : turns[t]?.prompt || "");

  const popover = createChipPopover({
    id: "workingSetPopover", className: "ctx-popover ws-popover", width: 420, el: infoEl, anchor: ".ws-chip",
    openers: ".ws-chip, .ts-ws, .ws-foot", sheet: true,
    // The chip opens the session's scope; the rail and a footprint set
    // theirs before they open it.
    summary: (anchor) => {
      if (anchor?.matches?.(".ws-chip")) {
        view = { scope: "session", turn: live ? live.ordinal : turns.length - 1 };
        // Opened: the chip's dot goes (chip()).
        queueMicrotask(onChange);
      }
      return { view };
    },
    session,
    // Opened: the server's set asked again (a file changed while the
    // session sat idle shows stale).
    show: (_data, opening) => {
      draw();
      if (opening) fetchServer();
    },
    onClose: () => { openGroup = null; onChange(); },
  });

  function rowTemplate(item, { session: inSession, group = null, now }) {
    const fresh = isFresh(seenAt(item), now);
    const tag = stepTag(item, { session: inSession });
    const words = `${opsText(item)}${fresh ? " · just now" : ""}`;
    const glyph = item.muted ? GLYPHS.muted : fresh ? "●" : GLYPHS[item.kind] || "";
    const name = memberName(item, group);
    const full = item.kind === "file" ? item.path || item.key : item.kind === "url" ? item.url || item.key : item.key;
    let nameEl;
    if (item.kind === "file") {
      const ref = item.ref || { path: full };
      nameEl = html`<span class="t ref" data-ref-kind="file" data-ref-path=${ref.path || full} data-ref-line=${ref.line || nothing} data-ref-end-line=${ref.end_line || nothing} title=${full}>${name}</span>`;
    } else if (item.kind === "url" && /^https?:\/\//i.test(full)) {
      nameEl = html`<a class="t" href=${full} target="_blank" rel="noopener noreferrer" title=${full}>${name}</a>`;
    } else {
      nameEl = html`<span class="t" title=${full}>${name}</span>`;
    }
    let tagEl = nothing;
    if (tag === "prompt") tagEl = html`<span class="ws-step p" title="preloaded into the system prompt">prompt</span>`;
    else if (tag) {
      const prompt = inSession ? promptOf(item.at.turn) : "";
      const where = inSession ? `turn ${item.at.turn + 1}${prompt ? ` (${prompt})` : ""}, step ${item.at.step + 1}` : `step ${item.at.step + 1}`;
      tagEl = html`<button type="button" class=${`ws-step${item.kind === "memory" ? " p" : ""}`} data-ws="jump" data-at=${atAttr(item.at)} title=${`entered at ${where}: go to the call`}>${tag}</button>`;
    }
    const edited = item.kind === "file" && item.ops.includes("edit");
    const state = item.state && item.state !== "live" ? ` ${item.state}` : "";
    const tokens = tokensText(item.tokens);
    return html`<div class=${`ws-row ${item.kind}${fresh ? " fresh" : ""}${item.muted ? " muted" : ""}${group ? " member" : ""}${state}`}><span class="k">${glyph}</span>${nameEl}${edited ? html`<span class="e">✎</span>` : nothing}<span class="st">${words}</span>${tokens ? html`<span class="tk" title=${`about ${item.tokens} tokens of it are sent`}>${tokens}</span>` : nothing}${tagEl}</div>`;
  }

  // A section's labels: leaves as rows, groups as an opener row and, open,
  // their members.
  function labelsTemplate(labels, opts) {
    return labels.map((label) => {
      if (label.type === "leaf") return rowTemplate(label.members[0], opts);
      const open = openGroup === label.id;
      const state = label.state && label.state !== "live" ? ` ${label.state}` : "";
      const head = html`<button type="button" class=${`ws-row ws-group-head ${label.kind}${state}`} data-ws="group" data-id=${label.id} aria-expanded=${String(open)} title=${labelTitle(label)}><span class="k">${open ? "▾" : "▸"}</span><span class="t">${label.glyph ? `${label.glyph} ` : ""}${label.text}</span>${label.count ? html`<span class="n">· ${label.count}</span>` : nothing}${label.edited ? html`<span class="e">✎${label.edited}</span>` : nothing}${label.cut ? html`<span class="c" title=${`${label.cut} forgotten`}>✂${label.cut}</span>` : nothing}<span class="chev">${open ? "close" : "open"}</span></button>`;
      return html`${head}${open ? label.members.map((m) => rowTemplate(m, { ...opts, group: label })) : nothing}`;
    });
  }

  function draw() {
    const now = Date.now();
    const st = state();
    const inSession = view.scope === "session";
    const set = inSession ? sessionSet() : { items: turnItems(view.turn), muted: [] };
    const files = set.items.filter((i) => i.kind === "file");
    const memories = set.items.filter((i) => i.kind === "memory");
    const urls = set.items.filter((i) => i.kind === "url");
    const opts = { session: inSession, now };
    const fileLabels = fold(files, POP_BUDGET).labels;
    // Memories are rows of their own; past the budget one group that opens.
    const memoryLabels = fold(memories, memories.length > POP_BUDGET ? 1 : Infinity).labels;
    const preloaded = memories.filter((m) => m.preloaded).length;
    const memMeta = [`${memories.length - preloaded} used`, preloaded ? `${preloaded} preloaded` : "", set.muted.length ? `${set.muted.length} muted` : ""].filter(Boolean).join(" · ");
    const turnLabel = view.turn !== null && view.turn >= 0 ? `turn ${view.turn + 1}` : "this turn";
    const pct = Number.isFinite(st.ctxPct) ? ` · ctx ${Math.round(st.ctxPct)} %` : "";
    const empty = !set.items.length && !set.muted.length;
    const tpl = html`<div class="ctx-pop-head"><strong>working set</strong><span class="ws-scope" role="group" aria-label="Scope"><button type="button" class=${!inSession ? "on" : ""} aria-pressed=${String(!inSession)} data-ws="scope" data-scope="turn" ?disabled=${view.turn === null || view.turn < 0}>${turnLabel}</button><button type="button" class=${inSession ? "on" : ""} aria-pressed=${String(inSession)} data-ws="scope" data-scope="session">session</button></span><span class="ctx-pop-kind">${set.items.length} item${set.items.length === 1 ? "" : "s"}${pct}</span>${ringTemplate(st.ctxPct)}<button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>
      ${empty ? html`<div class="ctx-pop-meta">Nothing yet: the files, memories and URLs ${inSession ? "this session's turns read" : "this turn reads"} show here.</div>` : nothing}
      ${files.length ? html`<div class="ctx-pop-meta">files · ${files.length}</div>${labelsTemplate(fileLabels, opts)}` : nothing}
      ${memories.length || set.muted.length ? html`<div class="ctx-pop-meta">memories${memMeta ? ` · ${memMeta}` : ""}</div>${labelsTemplate(memoryLabels, opts)}${set.muted.map((m) => rowTemplate(m, opts))}` : nothing}
      ${urls.length ? html`<div class="ctx-pop-meta">urls · ${urls.length}</div>${labelsTemplate(fold(urls, POP_BUDGET).labels, opts)}` : nothing}
      <div class="ctx-pop-meta ws-hint">A file opens its ref; a step tag goes to the call. Esc closes.</div>`;
    render(tpl, popover.pop);
  }

  // The row at +at+ ({turn, step, row}): the stage's block for the live
  // turn, else the history's.
  function rowAt(at) {
    const sel = `.turn-work[data-turn="${at.turn}"]`;
    const blocks = [...(stageRoot()?.querySelectorAll(sel) || []), ...[...historyEl.querySelectorAll(sel)].reverse()];
    for (const block of blocks) {
      const row = block.querySelector(`.activity-row[data-at="${at.step}.${at.row}"]`);
      if (row) return row;
    }
    return null;
  }

  function jump(at) {
    const row = rowAt(at);
    if (!row) return false;
    if (popover.isOpen()) popover.close();
    showRow(row);
    return true;
  }

  const parseAt = (text) => {
    const [turn, step, row] = String(text).split(".").map(Number);
    return [turn, step, row].every(Number.isInteger) ? { turn, step, row } : null;
  };

  popover.pop.addEventListener("click", (e) => {
    const act = e.target.closest("[data-ws]");
    if (!act) return;
    if (act.dataset.ws === "jump") {
      const at = parseAt(act.dataset.at);
      if (at) jump(at);
    } else if (act.dataset.ws === "scope") {
      view = { ...view, scope: act.dataset.scope };
      openGroup = null;
      draw();
      popover.replace();
    } else if (act.dataset.ws === "group") {
      openGroup = openGroup === act.dataset.id ? null : act.dataset.id;
      draw();
      popover.replace();
    }
  });

  // A footprint: its step tag jumps, the rest opens that turn's view.
  function footClick(e) {
    const foot = e.target.closest?.(".ws-foot");
    if (!foot) return;
    const tag = e.target.closest(".ws-step[data-at]");
    if (tag) {
      const at = parseAt(tag.dataset.at);
      if (at) jump(at);
      return;
    }
    if (popover.isOpen() && popover.opener() === foot) return popover.close();
    view = { scope: "turn", turn: Number(foot.dataset.wsTurn) };
    popover.open(foot);
  }
  doc.addEventListener("click", footClick);
  doc.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && e.target.matches?.(".ws-foot")) {
      e.preventDefault();
      footClick(e);
    }
  });

  function changed() {
    onChange();
    if (popover.isOpen()) popover.refresh();
  }

  // The footprints on the page (the history's, the hand-off's) drawn again
  // in place when their items' states changed: the same node (its focus,
  // the popover's opener), its children and label replaced.
  function refreshFootprints() {
    for (const root of [historyEl, stageRoot()]) {
      for (const foot of root?.querySelectorAll(".ws-foot[data-ws-turn]") || []) {
        const ordinal = Number(foot.dataset.wsTurn);
        if (!Number.isInteger(ordinal)) continue;
        const items = turnItems(ordinal);
        if (!items.length || foot.dataset.wsSig === footSig(items)) continue;
        const next = footprintNode(items, ordinal);
        if (!next) continue;
        foot.replaceChildren(...next.childNodes);
        foot.setAttribute("aria-label", next.getAttribute("aria-label"));
        foot.dataset.wsSig = next.dataset.wsSig;
      }
    }
  }

  // A newer server snapshot redraws every form; an older one (a GET that
  // answered after a newer event) is dropped. +how+: newerSnapshot's.
  function takeServer(snapshot, how) {
    const next = newerSnapshot(server, snapshot, how);
    if (next === server) return;
    server = next;
    serverOf = session();
    changed();
    refreshFootprints();
    for (const fn of listeners) fn();
  }

  // The server's set for the open session, asked again; an answer for a
  // session no longer open is dropped.
  function fetchServer() {
    const id = session();
    if (!getWorkingSet || !id) return;
    const asked = events;
    Promise.resolve()
      .then(() => getWorkingSet(id))
      .then((snapshot) => { if (session() === id) takeServer(snapshot, { overtaken: events !== asked }); })
      .catch(() => {});
  }

  return {
    // A session's history drawn anew: its turns' sets (+list+: [{items,
    // prompt}]), no running turn yet; the chip's dot starts off.
    seed(list) {
      turns = list.slice();
      live = null;
      if (popover.isOpen()) popover.close();
      // Another session's snapshot goes; the same session's (a resync)
      // stays until the newer one comes.
      if (serverOf !== session()) {
        server = null;
        serverOf = session();
      }
      openedCount = sessionSet().items.length;
      refreshFootprints();
      fetchServer();
    },
    // A :working_set_updated event's set ({items, at}).
    update(snapshot) {
      events += 1;
      takeServer(snapshot, { event: true });
    },
    // +fn()+ runs after each new server snapshot (the rail's redraw).
    onServer(fn) { listeners.add(fn); },
    // The running turn's items (its model +turn+), its ordinal the next
    // turn's; the chip follows.
    liveItems(turn, prompt = "") {
      const ordinal = turns.length;
      const items = itemsOfTurn(turn, ordinal);
      const before = live?.items.length ?? -1;
      live = { ordinal, items, prompt };
      if (items.length !== before) changed();
      return { items: lit(items), ordinal };
    },
    // The rail's first-sight times, for the popover's fresh rows.
    setSeen(fn) { seenAt = fn; },
    // The running turn hands off: its set joins the turns; its footprint
    // line (null: it touched nothing) goes after its block.
    handOff(turn, prompt = "") {
      const ordinal = turns.length;
      const items = itemsOfTurn(turn, ordinal);
      turns.push({ items, prompt });
      live = null;
      changed();
      return footprintNode(lit(items), ordinal);
    },
    // The running turn left without a hand-off (a reset): forgotten.
    release() {
      if (!live) return;
      live = null;
      changed();
    },
    // The rail opens the running turn's view.
    openTurn(anchor) {
      if (popover.isOpen() && popover.opener() === anchor) return popover.close();
      view = { scope: "turn", turn: live ? live.ordinal : turns.length - 1 };
      popover.open(anchor);
      openedCount = sessionSet().items.length;
      onChange();
    },
    // The session bar's chip: {n, changed} (the dot), null when the set is
    // empty (no chip). Opening it clears the dot.
    chip() {
      const n = sessionSet().items.length;
      if (popover.isOpen()) openedCount = n;
      return n ? { n, changed: n !== openedCount } : null;
    },
    jump,
    ctxPct: () => state().ctxPct,
    isOpen: () => popover.isOpen(),
    popover,
  };
}
