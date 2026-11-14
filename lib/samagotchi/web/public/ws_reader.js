// The working set's reader (scene A of the working-set preview): what chi
// has of one item, as its timeline, newest first (ws_timeline.js cards,
// ws_cards.js templates): a file's reads as merged line slices over a strip
// of the whole file, its edits as diffs, a memory's reads with their
// overlay and, for a changed one, "Now · diff"; a slice chi no longer has
// greyed. It replaces the stage (#center: the history and the composer,
// kept under it, inert, so their scroll place stays) until "← Stage" or
// Esc; the session's set stays beside it with the open item marked, ↑↓
// step through it. On a phone it is full screen: ‹ Set back to the list's
// sheet, ‹ › the other items.
//
// Ways in: the popover peek's "Open the timeline" (ws_peek.js), a tool
// row's "timeline" (ws_way_in.js), the ref ▾ menu's "What chi has" on a
// file in the set (refs.js REF_ACTIONS.file, its env's +whatChiHas+). All
// the owner's: app.js makes this only for a viewer with working_set_items.
//
// The timeline comes from the item route (getWorkingSetItem); an answer for
// an item no longer open, or another session, is dropped (latest.js). While
// open, each new server snapshot asks again (the route builds from the
// session's messages, which lag a running turn's events). Leaving the
// session (another one, the start page) resets it: session_view.js
// forgetSession calls reset(), so #center is never left inert under it.

import { html, nothing, render } from "./vendor/lit-html.js";
import { api } from "./data.js";
import { createLatest } from "./latest.js";
import { diffTemplate } from "./diff_view.js";
import { createPeek } from "./ws_peek.js";
import { setTimelineWayIn } from "./ws_way_in.js";
import { cardTemplate } from "./ws_cards.js";
import { bandBox, countsText, eventTag, fileStrip, itemPath, linesText, timelineCards } from "./ws_timeline.js";
import { GLYPHS, leafText, opsText, steerId, steerLine, tokensText } from "./working_set.js";

// The item route's answer for session +id+ (+now+: a memory's text now).
export function getWorkingSetItem(id, kind, key, { now = false } = {}) {
  return api(itemPath(id, kind, key, { now }));
}

const PHONE_MAX = 600;

// The head's pill: what is true of the item as a whole.
function itemPill(item, events) {
  if (item.state === "stale") return { text: item.kind === "memory" ? "changed since chi read it" : "the file changed since chi saw it", warn: true };
  if (item.state === "dropped") return { text: "dropped by you: chi no longer has it", warn: false };
  if (item.state === "forgotten") return { text: "chi no longer has it", warn: false };
  const edits = events.filter((e) => e.op === "edit" || e.op === "write").length;
  return edits ? { text: `chi edited it ${edits}× · newest first`, warn: true } : null;
}

// What an item is called in the head: a file by its path in the session's
// folder, a memory by its name.
function itemName(item) {
  if (item.kind === "file") return item.path || item.key;
  if (item.kind === "url") return item.url || item.key;
  return `${GLYPHS.memory} ${item.key}`;
}

// +centerEl+: what the reader covers (#center); +session()+, +state()+: the
// open session's id and fields (its folder: the undrop line); +getItem+: the
// item route (tests pass a stand-in); +sendLine(line)+: a steer line
// (undrop; null: none).
export function createWorkingSetPreview({ centerEl, session, state = () => ({}), getItem = getWorkingSetItem, sendLine = null,
  doc = document, win = window }) {
  let workingSet = null;
  // The open item ({kind, key}), its answer, the memory's now, the tab.
  let open = null;
  let data = null;
  let failed = false;
  let tab = "has";
  let openFor = null;
  const latest = createLatest(() => `${session()}|${open ? `${open.kind}:${open.key}` : ""}`);
  const peek = createPeek({ session, getItem: (id, kind, key) => getItem(id, kind, key), onChange: () => workingSet?.peekChanged() });

  const el = doc.createElement("section");
  el.className = "ws-reader";
  el.id = "wsReader";
  el.setAttribute("aria-label", "What chi has");
  el.hidden = true;
  centerEl?.appendChild(el);
  const covered = () => [...(centerEl?.children || [])].filter((child) => child !== el);

  const items = () => workingSet?.items() || [];
  // The rows the set beside it draws (and ↑↓, ‹ › step over): not the muted.
  const shown = () => items().filter((it) => !it.muted);
  // Where focus was when it opened: it goes back there on close.
  let returnTo = null;
  const idOf = (it) => steerId(it);
  // The open item as the set has it (its runs, state, tokens); a stand-in
  // when the set doesn't hold it (yet).
  const current = () => items().find((it) => it.kind === open?.kind && it.key === open?.key)
    || (open ? { kind: open.kind, key: open.key, label: open.key, ops: [], state: "live", runs: [] } : null);

  function load() {
    const id = session();
    if (!id || !open) return;
    const fresh = latest.begin();
    const { kind, key } = open;
    Promise.resolve()
      .then(() => getItem(id, kind, key, { now: kind === "memory" }))
      .then((answer) => {
        if (!fresh()) return;
        data = answer;
        failed = false;
        draw();
      })
      .catch(() => {
        if (!fresh()) return;
        failed = true;
        draw();
      });
  }

  function stripTemplate(events) {
    const strip = fileStrip(events);
    if (!strip) return nothing;
    const merged = strip.bands.filter((b) => !b.latest).sort((a, b) => a.first - b.first);
    const ranges = merged.map((b) => `${b.first}–${b.last}`).join(", ");
    const bands = strip.bands.map((band) => {
      const box = bandBox(band, strip.length);
      return html`<button type="button" class=${`wsr-band ${band.state}${band.latest ? " latest" : ""}`} data-wsr="band" data-first=${band.first} style=${`left:${box.left};width:${box.width}`} title=${`${linesText(band)}${band.state === "sent" ? "" : ` (${band.state})`}: go to its lines`}></button>`;
    });
    const chips = merged.map((band) => html`<button type="button" class=${`wsr-chip ${band.state}`} data-wsr="band" data-first=${band.first}>${band.first}–${band.last}</button>`);
    return html`<div class="wsr-strip"><div class="wsr-strip-k"><span>1</span><span>read: ${ranges} of ${strip.length} lines known · tap a band to jump</span><span>${strip.length}</span></div><div class="wsr-bar" aria-label=${`read ${ranges} of ${strip.length} lines`}>${bands}</div><div class="wsr-chips">${chips}</div></div>`;
  }

  function memoryTemplate(item, events) {
    const now = data?.now;
    const changed = item.state === "stale" && now;
    const lastRead = events.filter((e) => e.op === "memory_read").at(-1);
    const memory = lastRead?.memory;
    const banner = changed ? html`<div class="wsr-banner">Changed since chi's last read${lastRead ? ` (${eventTag(lastRead, item)})` : ""}: what chi has is not what the memory says now.</div>` : nothing;
    const tabs = changed ? html`<div class="wsr-tabs" role="tablist"><button type="button" role="tab" aria-selected=${String(tab === "has")} class=${tab === "has" ? "on" : ""} data-wsr="tab" data-tab="has">What chi has</button><button type="button" role="tab" aria-selected=${String(tab === "now")} class=${tab === "now" ? "on" : ""} data-wsr="tab" data-tab="now">Now · diff</button></div>` : nothing;
    const from = memory?.path ? html`<div class="wsr-from">${memory.scope} memory · from ${memory.path.replace(/[^/]*$/, "")}</div>` : nothing;
    return { banner, tabs, from, nowBody: changed && tab === "now" ? (now.gone ? html`<div class="diff-note warn">the memory's file is gone</div>` : html`<article class="wsr-card now"><header class="wsr-card-h"><span class="wsr-card-t">what chi has → now</span></header>${diffTemplate(now.diff)}</article>`) : null };
  }

  function setTemplate(item) {
    const rows = shown().map((it) => {
      const on = it.kind === item.kind && it.key === item.key;
      const state = it.state && it.state !== "live" ? ` ${it.state}` : "";
      return html`<button type="button" class=${`ws-row wsr-item ${it.kind}${state}${on ? " on" : ""}`} data-wsr="item" data-ws-id=${idOf(it)} aria-current=${on ? "true" : "false"}><span class="k">${GLYPHS[it.kind] || ""}</span><span class="t">${leafText(it)}</span><span class="st">${opsText(it)}</span></button>`;
    });
    const files = items().filter((it) => it.kind === "file").length;
    const memories = items().filter((it) => it.kind === "memory").length;
    const pct = Number.isFinite(state().ctxPct) ? ` · ctx ${Math.round(state().ctxPct)} %` : "";
    return html`<aside class="wsr-set" aria-label="Working set"><div class="wsr-set-h"><strong>working set</strong><span class="wsr-set-m">session</span></div><div class="wsr-set-n">${items().length} items${pct} · files · ${files} · memories · ${memories}</div><div class="wsr-set-rows">${rows}</div><div class="wsr-set-hint">↑↓ steps through the set · Esc back to the stage (same scroll place)</div></aside>`;
  }

  function draw() {
    if (!open) return;
    const item = current();
    const events = data?.events || [];
    const cards = timelineCards(events);
    const tokens = tokensText(item.tokens);
    const counts = countsText(events);
    const pill = data ? itemPill(item, events) : null;
    const memory = item.kind === "memory" ? memoryTemplate(item, events) : null;
    const scope = item.kind === "memory" ? events.find((e) => e.memory)?.memory?.scope : null;
    const meta = [scope ? `${scope} memory` : "", "timeline, newest first", counts, tokens ? `${tokens} tokens` : ""].filter(Boolean).join(" · ");
    const phoneMeta = [scope ? `${scope} memory` : "", counts, tokens ? `${tokens} tokens` : ""].filter(Boolean).join(" · ");
    const undrop = sendLine && (item.state === "dropped" || item.hasDrop) ? html`<button type="button" class="ws-act-b" data-wsr="undrop">undrop</button>` : nothing;
    let body;
    if (failed) body = html`<div class="wsr-note">Couldn't load what chi has of it.</div>`;
    else if (!data) body = html`<div class="wsr-note">Loading…</div>`;
    else if (!cards.length) body = html`<div class="wsr-note">Nothing of it in the conversation yet: a running turn's reads show at its next step.</div>`;
    else if (memory?.nowBody) body = memory.nowBody;
    else body = cards.map((card) => cardTemplate(card, { item, undrop }));
    const list = shown();
    const at = list.findIndex((it) => it.kind === item.kind && it.key === item.key);
    const tpl = html`<div class="wsr-main">
      <div class="wsr-head">
        <button type="button" class="wsr-back" data-wsr="back"><span class="wsr-wide">← Stage</span><span class="wsr-narrow">‹ Set</span></button>
        <span class="wsr-title"><span class="wsr-name" title=${item.key}>${itemName(item)}</span><span class="wsr-meta wsr-wide">${meta}</span><span class="wsr-meta wsr-narrow">${phoneMeta}</span></span>
        ${pill ? html`<span class=${`wsr-head-pill${pill.warn ? " warn" : ""}`}>${pill.text}</span>` : nothing}
        <span class="wsr-nav wsr-narrow"><button type="button" data-wsr="prev" aria-label="Previous item" ?disabled=${at <= 0}>‹</button><button type="button" data-wsr="next" aria-label="Next item" ?disabled=${at < 0 || at >= list.length - 1}>›</button></span>
      </div>
      ${memory ? memory.banner : nothing}${memory ? memory.tabs : nothing}
      ${item.kind === "file" ? stripTemplate(events) : nothing}
      <div class="wsr-body" tabindex="-1">${body}</div>
      ${memory ? memory.from : nothing}
      <div class="wsr-foot wsr-narrow">‹ › the next item · lines don't wrap, scroll sideways in the code</div>
    </div>${setTemplate(item)}`;
    render(tpl, el);
  }

  // Opens +target+ ({kind, key}): the stage stays under it, inert.
  function openItem(target) {
    if (!target?.kind || !target.key) return;
    const again = open && open.kind === target.kind && open.key === target.key;
    open = { kind: target.kind, key: target.key };
    openFor = session();
    if (!again) {
      data = null;
      failed = false;
      tab = "has";
    }
    if (el.hidden) {
      const active = doc.activeElement;
      returnTo = active && active !== doc.body && !el.contains(active) ? active : null;
      for (const child of covered()) child.inert = true;
      el.hidden = false;
      doc.body.classList.add("ws-reading");
    }
    draw();
    el.querySelector(".wsr-body")?.scrollTo?.(0, 0);
    el.querySelector(".wsr-back")?.focus({ preventScroll: true });
    load();
  }

  // +refocus+: focus goes back where it was at the open (not for a jump,
  // which scrolls to its row, nor a reset).
  function close({ refocus = true } = {}) {
    if (el.hidden) return;
    open = null;
    data = null;
    latest.drop();
    el.hidden = true;
    for (const child of covered()) child.inert = false;
    doc.body.classList.remove("ws-reading");
    render(nothing, el);
    const back = returnTo;
    returnTo = null;
    if (refocus && back?.isConnected && !back.closest?.("[inert]")) back.focus?.({ preventScroll: true });
  }

  // The item +step+ places from the open one in the set.
  function stepItem(step) {
    const list = shown();
    const at = list.findIndex((it) => it.kind === open?.kind && it.key === open?.key);
    const next = list[at + step];
    if (next) openItem(next);
  }

  const phone = () => win.innerWidth < PHONE_MAX;

  el.addEventListener("click", (e) => {
    const act = e.target.closest("[data-wsr], [data-ws='jump']");
    if (!act) return;
    if (act.dataset.ws === "jump") {
      const [turn, step, row] = String(act.dataset.at).split(".").map(Number);
      close({ refocus: false });
      workingSet?.jump({ turn, step, row });
      return;
    }
    const what = act.dataset.wsr;
    if (what === "back") {
      close();
      // After this click has passed the list's outside-click close.
      if (phone()) setTimeout(() => workingSet?.openList(), 0);
    } else if (what === "item") {
      const found = items().find((it) => idOf(it) === act.dataset.wsId);
      if (found) openItem(found);
    } else if (what === "prev") stepItem(-1);
    else if (what === "next") stepItem(1);
    else if (what === "tab") {
      tab = act.dataset.tab === "now" ? "now" : "has";
      draw();
    } else if (what === "band") {
      const first = Number(act.dataset.first);
      const card = [...el.querySelectorAll(".wsr-card.slice")].find((c) => c.querySelector(`.read-line[data-line="${first}"]`));
      card?.scrollIntoView?.({ block: "start" });
    } else if (what === "undrop" && sendLine) {
      const item = current();
      Promise.resolve(sendLine(steerLine("undrop", [item], state().dir))).catch(() => {});
    }
  });

  doc.addEventListener("keydown", (e) => {
    if (el.hidden || e.defaultPrevented || e.altKey || e.ctrlKey || e.metaKey) return;
    if (e.target?.closest?.("input, textarea, [contenteditable]")) return;
    // A popover over the reader takes its own Esc.
    if (doc.querySelector(".ctx-popover:not([hidden])")) return;
    if (e.key === "Escape") {
      e.preventDefault();
      close();
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      stepItem(e.key === "ArrowDown" ? 1 : -1);
    }
  });

  // A tool row's "timeline" (ws_way_in.js).
  doc.addEventListener("click", (e) => {
    const button = e.target.closest?.(".activity-ws[data-ws-kind]");
    if (!button) return;
    e.preventDefault();
    openItem({ kind: button.dataset.wsKind, key: button.dataset.wsKey });
  });

  return {
    peek,
    // The working set's view (working_set_view.js), once made: the set,
    // its jumps and its list; rows get their way in from now on.
    attach(view) {
      workingSet = view;
      if (!view) return;
      setTimelineWayIn(true);
      // A new snapshot: asked again (a snapshot of another session: closed,
      // though forgetSession's reset has done it already).
      view.onServer(() => {
        if (el.hidden) return;
        if (session() !== openFor) close({ refocus: false });
        else load();
      });
    },
    open: openItem,
    close,
    isOpen: () => !el.hidden,
    // The ref ▾ menu's "What chi has" (refs.js): a file ref whose path is
    // an item of the set.
    whatChiHas: {
      has: (path) => items().some((it) => it.kind === "file" && it.key === path),
      open: (path) => openItem({ kind: "file", key: path }),
    },
    // The session forgotten (another one, the start page: session_view.js
    // forgetSession): closed, the stage no longer inert.
    reset() { close({ refocus: false }); peek.close(); },
  };
}
