// The working set's rail (web.working_set, the stage view): a column on the
// right of the stage's live slots (a row under the trail in a narrow stage)
// with the running turn's set folded into a few fixed 18 px lines
// (working_set.js fold). It never sets the live block's height: the rail is
// out of the flow (index.html .ts-ws), the row a fixed line. Lines are
// keyed by their label's id and patched only when what they show changes,
// so nothing restarts; a fold fades the absorbed lines out in place and the
// lines below slide up once (each line sits at its slot by a transform).
// Collapsed (kept per browser), it is its head line only, with the newest
// entry ticking through it.
import { BUDGETS, ariaLabel, fold, isFresh, labelTitle, nextSettle, shown } from "./working_set.js";
import { readStored, writeStored } from "./storage.js";
import { reducedMotion } from "./stage_frame.js";

export const COLLAPSE_KEY = "chi_working_set_collapsed";
// The stage width (px) under which the rail is a row; the phone's
// (index.html, under 600 px of window) shows neither.
export const RAIL_MIN = 760;
const LINE = 18;
const LEAVE_MS = 150;
const SVG = "http://www.w3.org/2000/svg";
const RING_R = 5.5;
const RING_LEN = 2 * Math.PI * RING_R;

function el(tag, cls, parent = null) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (parent) parent.appendChild(node);
  return node;
}

// The context ring (14 px): the fill's share of the window, warn from 70 %,
// danger from 90 % (the :context_status buckets); hidden until a value.
export function ringBucket(pct) {
  if (pct >= 90) return "danger";
  if (pct >= 70) return "warn";
  return "";
}

export function createRing(parent) {
  const svg = document.createElementNS(SVG, "svg");
  svg.setAttribute("class", "ws-ring");
  svg.setAttribute("viewBox", "0 0 14 14");
  svg.setAttribute("role", "img");
  const title = document.createElementNS(SVG, "title");
  svg.appendChild(title);
  for (const cls of ["track", "fill"]) {
    const c = document.createElementNS(SVG, "circle");
    c.setAttribute("class", cls);
    c.setAttribute("cx", "7");
    c.setAttribute("cy", "7");
    c.setAttribute("r", String(RING_R));
    svg.appendChild(c);
  }
  svg.style.display = "none";
  parent.appendChild(svg);
  let shownPct = null;
  return {
    el: svg,
    draw(pct) {
      const value = Number.isFinite(pct) ? Math.max(0, Math.min(100, Math.round(pct))) : null;
      if (value === shownPct) return;
      shownPct = value;
      svg.style.display = value === null ? "none" : "";
      if (value === null) return;
      svg.setAttribute("class", `ws-ring${ringBucket(value) ? ` ${ringBucket(value)}` : ""}`);
      svg.querySelector(".fill").setAttribute("stroke-dasharray", `${(RING_LEN * value) / 100} ${RING_LEN}`);
      title.textContent = `context ${value}% used`;
    },
  };
}

// +live+: the stage's live block (the rail goes last in it); +stage+: the
// stage (its width picks the form); +onOpen(railEl)+: the expanded view;
// +onChange()+: redraw (the stage's scheduleRefresh), for the fresh cue's
// end and a form change.
export function createWorkingSetRail({ live, stage, onOpen, onChange }) {
  const rail = el("div", "ts-ws", live);
  rail.setAttribute("role", "button");
  rail.tabIndex = 0;
  const head = el("div", "ws-head", rail);
  const name = el("span", "ws-name", head);
  const count = el("span", "ws-count", head);
  const tick = el("span", "ws-tick", head);
  const ring = createRing(head);
  const foldBtn = el("button", "ws-fold", head);
  foldBtn.type = "button";
  const list = el("div", "ws-list", rail);

  let collapsed = readStored(COLLAPSE_KEY) === "1";
  let width = 0;
  // The turn's fold so far (its groups stay), each line's node by label id
  // and what it shows, the items' first sight (the fresh cue), and when the
  // next cue ends.
  let kept = [];
  const nodes = new Map();
  const seen = new Map();
  let first = true;
  let settleTimer = null;
  let shownHead = null;

  const observer = typeof ResizeObserver === "function" ? new ResizeObserver(() => {
    const next = stage.clientWidth;
    if ((next >= RAIL_MIN) !== (width >= RAIL_MIN)) onChange?.();
    width = next;
  }) : null;
  observer?.observe(stage);

  function form() {
    return (width || stage.clientWidth) >= RAIL_MIN ? "rail" : "row";
  }

  function applyCollapsed() {
    rail.classList.toggle("collapsed", collapsed);
    rail.setAttribute("aria-expanded", String(!collapsed));
    foldBtn.textContent = collapsed ? "◂" : "–";
    foldBtn.setAttribute("aria-label", collapsed ? "Show the working set" : "Fold the working set to one line");
    foldBtn.title = foldBtn.getAttribute("aria-label");
  }
  applyCollapsed();

  function setCollapsed(value) {
    collapsed = value;
    writeStored(COLLAPSE_KEY, value ? "1" : "0");
    applyCollapsed();
    shownHead = null;
    onChange?.();
  }

  rail.addEventListener("click", (e) => {
    if (e.target.closest(".ws-fold")) {
      e.stopPropagation();
      setCollapsed(!collapsed);
      return;
    }
    if (collapsed) setCollapsed(false);
    else onOpen?.(rail);
  });
  rail.addEventListener("keydown", (e) => {
    if (e.target !== rail || (e.key !== "Enter" && e.key !== " ")) return;
    e.preventDefault();
    if (collapsed) setCollapsed(false);
    else onOpen?.(rail);
  });

  // A line's node: its glyph, text, count and marks (✎ edited, a group's
  // ✂ forgotten members).
  function lineNode(label) {
    const node = el("div", `ws-item ${label.kind}`);
    el("span", "k", node);
    el("span", "t", node);
    el("span", "n", node);
    el("span", "e", node);
    el("span", "c", node);
    return node;
  }

  // A state (the server's: stale faded, forgotten struck) is a class and a
  // mark on the same line: it never refolds and never moves a line.
  function fillLine(node, label, fresh) {
    const state = label.state && label.state !== "live" ? ` ${label.state}` : "";
    node.className = `ws-item ${label.kind}${label.type !== "leaf" ? " group" : ""}${fresh ? " fresh" : ""}${state}`;
    const [k, t, n, e, c] = node.children;
    k.textContent = label.glyph || "";
    t.textContent = label.text;
    n.textContent = label.count ? `· ${label.count}` : "";
    e.textContent = label.edited ? (label.type === "leaf" ? "✎" : `✎${label.edited}`) : "";
    c.textContent = label.type !== "leaf" && label.cut ? `✂${label.cut}` : "";
    node.title = labelTitle(label);
  }

  // A line at its slot. A new line is placed before it is in the page (no
  // transition); a kept one slides there (index.html .ws-item).
  function place(node, i) {
    node.style.transform = `translateY(${i * LINE}px)`;
    // The row form lays the lines out in a flex row: by order, not by DOM.
    node.style.order = String(i);
  }

  // The fresh cue's end redraws once it is due.
  function scheduleSettle(now) {
    clearTimeout(settleTimer);
    const left = nextSettle(seen.values(), now);
    if (left !== null) settleTimer = setTimeout(() => onChange?.(), left + 20);
  }

  // Draws +items+ (the running turn's, working_set.js itemsOfTurn); +ctxPct+
  // the ring's value (null: no ring yet).
  function draw(items, { ctxPct = null, now = Date.now() } = {}) {
    // A turn joined mid-way (a reload, another tab): what is there already
    // is not new.
    for (const item of items) {
      const id = `${item.kind}:${item.key}`;
      if (!seen.has(id)) seen.set(id, first ? -Infinity : now);
    }
    first = false;
    const budget = form() === "rail" ? BUDGETS.rail : BUDGETS.row;
    const folded = fold(items, budget, { kept });
    kept = folded.groups;
    const view = shown(folded.labels, budget);
    const freshOf = (label) => label.members.some((m) => isFresh(seen.get(`${m.kind}:${m.key}`), now));
    const newest = items[items.length - 1];

    // The head: its name, the count, the ring; collapsed, the newest entry.
    name.textContent = collapsed ? "set" : "working set";
    count.textContent = String(items.length);
    const tickText = collapsed && newest ? `${newest.kind === "memory" ? "◆ " : newest.kind === "url" ? "↗ " : ""}${newest.label}` : "";
    if (tick.textContent !== tickText) {
      tick.textContent = tickText;
      tick.classList.remove("fresh");
      if (tickText && !reducedMotion()) {
        void tick.offsetWidth;
        tick.classList.add("fresh");
      }
    }
    ring.draw(ctxPct);
    const aria = ariaLabel(view.labels, view.more);
    if (shownHead !== aria) {
      shownHead = aria;
      rail.setAttribute("aria-label", aria);
    }

    // The lines, by key: an unchanged one is left alone.
    const animate = !reducedMotion();
    const lines = view.labels.map((label) => ({ id: label.id, label, fresh: freshOf(label) }));
    if (view.more) lines.push({ id: "more", more: view.more });
    const ids = new Set(lines.map((l) => l.id));
    for (const [id, entry] of nodes) {
      if (ids.has(id)) continue;
      nodes.delete(id);
      const gone = entry.node;
      if (!animate) { gone.remove(); continue; }
      gone.classList.add("leave");
      setTimeout(() => gone.remove(), LEAVE_MS);
    }
    lines.forEach((line, i) => {
      let entry = nodes.get(line.id);
      const key = JSON.stringify(line.more ? ["more", line.more] : [line.id, line.label.text, line.label.count || "", line.label.n, line.label.edited, line.label.cut || 0, line.label.state || "live", line.fresh]);
      if (!entry) {
        const node = line.more ? el("div", "ws-more") : lineNode(line.label);
        entry = { node, key: null, slot: -1 };
        nodes.set(line.id, entry);
        place(node, i);
        list.appendChild(node);
        if (animate) node.classList.add("enter");
      }
      if (entry.key !== key) {
        entry.key = key;
        if (line.more) entry.node.textContent = `+ ${line.more} more`;
        else fillLine(entry.node, line.label, line.fresh);
      }
      if (entry.slot !== i) {
        place(entry.node, i);
        entry.slot = i;
      }
    });
    rail.classList.toggle("empty", !items.length);
    scheduleSettle(now);
  }

  // A new turn (or none): no lines, no fold, nothing seen.
  function reset() {
    clearTimeout(settleTimer);
    for (const { node } of nodes.values()) node.remove();
    list.replaceChildren();
    nodes.clear();
    seen.clear();
    kept = [];
    first = true;
    shownHead = null;
    tick.textContent = "";
  }

  // For the expanded view: when an item was first seen (its fresh cue).
  const seenAt = (item) => seen.get(`${item.kind}:${item.key}`);

  return { el: rail, draw, reset, seenAt, form, isCollapsed: () => collapsed };
}
