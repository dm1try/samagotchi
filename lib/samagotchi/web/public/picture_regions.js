// A drawn diagram's regions over the picture viewer (picture_viewer.js useLayer):
// the pointer over a node outlines it, a tap selects it and the card above the
// zoom bar names it; the keyboard and a screen reader reach the nodes as buttons.
// docs/internals/web-frontend.md (Picture viewer, Regions).
//
// The regions are block_regions.js's clean ones: their text is only ever text
// (lit's text and attribute bindings), their numbers percent offsets. Nothing
// here is markup, a selector or a URL made from them, and no data-* value.
//
// The pointer path is the viewer's: it keeps its pointer capture, so a click
// never reaches a button (the buttons take no pointer). tap and hover are the
// hit test (region_hit.js); a button's click is a keyboard's Enter or Space, or an
// assistive activation.
//
// Only two lines are drawn, the hovered and the selected edge's: at the closest
// zoom the box is up to 16,000 px a side.
//
// A module of its own: its exports are new (docs/internals/web-frontend.md).

import { html, nothing, render, svg } from "./vendor/lit-html.js";
import { hitRegion, nearestInDirection, sameRegion } from "./region_hit.js";

// The card's room kept at the bottom of a fitted picture that has regions, beside
// the bar's (P10): the card (48 px, 64 with a coarse pointer's 44 px ✕) and its 8 px
// gaps. A fitted node is never under the card, and selecting never moves the picture.
export const CARD_ROOM = 64;
export const COARSE_CARD_ROOM = 80;
// How near a tap must be, in screen px.
export const MOUSE_TOLERANCE = 3;
export const TOUCH_TOLERANCE = 18;
// An edge without a label's box gets a button this size at its middle point.
const EDGE_BUTTON_PX = 24;

// A button's own inline reset, the stylesheet's .pv-node as well: with a stale
// index.html (a proxy ignoring no-cache) the new modules' buttons are still
// placed, see-through and never take a pointer, not 600 primary-colour buttons
// in the picture's flow.
const INERT = "position:absolute;box-sizing:border-box;margin:0;padding:0;border:0;background:none;pointer-events:none;";

const KIND_WORDS = { node: "node", group: "group", edge: "arrow", note: "note" };
const PLURALS = { node: "nodes", group: "groups", edge: "arrows", note: "notes" };
const X_ICON = html`<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>`;

const pct = (n) => `${n * 100}%`;
const boxStyle = ([x, y, w, h]) => `left:${pct(x)};top:${pct(y)};width:${pct(w)};height:${pct(h)}`;

// An edge's end by name: its node's label when the diagram has it, else its id.
function endName(regions, id) {
  const end = regions.find((r) => r.kind !== "edge" && r.id === id);
  return end?.label || id;
}

// What the card's line and a button say of +r+.
export function regionTitle(r, regions) {
  if (r.kind !== "edge") return r.label || r.id;
  const ends = r.from && r.to ? `${endName(regions, r.from)} → ${endName(regions, r.to)}` : "";
  if (ends && r.label) return `${ends} · ${r.label}`;
  return ends || r.label;
}

// A button's name: "node Bridge, BR", "arrow Bridge to Engine, events".
export function regionName(r, regions) {
  const kind = KIND_WORDS[r.kind];
  if (r.kind === "edge") {
    const ends = r.from && r.to ? `${endName(regions, r.from)} to ${endName(regions, r.to)}` : "";
    return [`${kind} ${ends || r.label}`, ends && r.label ? r.label : ""].filter(Boolean).join(", ");
  }
  const label = r.label || r.id;
  return r.id && r.id !== label ? `${kind} ${label}, ${r.id}` : `${kind} ${label}`;
}

// "Diagram: 8 nodes, 1 group, 7 arrows".
function countLine(buttons) {
  const counts = new Map();
  for (const r of buttons) counts.set(r.kind, (counts.get(r.kind) || 0) + 1);
  const parts = ["node", "note", "edge", "group"].filter((k) => counts.has(k)).map((k) => `${counts.get(k)} ${counts.get(k) === 1 ? KIND_WORDS[k] : PLURALS[k]}`);
  return `Diagram: ${parts.join(", ")}`;
}

// @param actions (region) => the card's actions row, a lit template or nothing
// @param onSelect (region | null) => told of each selection
// @return the layer picture_viewer.js useLayer takes: {mount(box), show(picture),
//   clear(), room(), tap(point, size, pointerType), hover(point, size), key(e),
//   selected(), select(region), bind({selected, home}), card, live}
export function createRegionLayer({ doc = document, win = window, actions = () => nothing, onSelect = () => {} } = {}) {
  const marks = doc.createElement("div");
  marks.className = "pv-marks";
  const card = doc.createElement("div");
  card.className = "pv-sel";
  card.hidden = true;
  card.setAttribute("role", "region");
  card.setAttribute("aria-label", "Selected");
  const live = doc.createElement("div");
  live.className = "pv-live";
  live.setAttribute("aria-live", "polite");

  // Made once: room() runs on every paint of a drag or a pinch.
  const coarse = win.matchMedia?.("(pointer:coarse)");
  let regions = null;
  let natural = { width: 1, height: 1 };
  // One button per region (twins share one): the keyboard's way in.
  let buttons = [];
  let selected = null;
  let hovered = null;
  // The roving Tab stop: the selection's button, else the last focused, else the first.
  let stop = null;
  let viewer = { selected: () => {}, home: () => {} };

  const buttonOf = (r) => buttons.find((b) => sameRegion(b, r)) || null;
  const nodeButton = (r) => (r ? [...marks.querySelectorAll(".pv-node")][buttons.indexOf(buttonOf(r))] || null : null);

  function line(r, cls) {
    return r?.kind === "edge" ? svg`<polyline class=${cls} points=${r.points.map((p) => p.join(",")).join(" ")}></polyline>` : nothing;
  }

  function boxMarks(r, cls) {
    if (!r || r.kind === "edge") return nothing;
    return regions.filter((o) => sameRegion(o, r)).map((o) => html`<div class=${`pv-mark ${cls}${o.kind === "group" ? " pv-group" : ""}`} style=${boxStyle(o.box)}></div>`);
  }

  function buttonStyle(r) {
    if (r.box) return INERT + boxStyle(r.box);
    const [x, y] = r.points[Math.floor(r.points.length / 2)];
    const half = EDGE_BUTTON_PX / 2;
    return `${INERT}left:calc(${pct(x)} - ${half}px);top:calc(${pct(y)} - ${half}px);width:${EDGE_BUTTON_PX}px;height:${EDGE_BUTTON_PX}px`;
  }

  function draw() {
    const hover = hovered && !sameRegion(hovered, selected) ? hovered : null;
    render(regions ? html`${boxMarks(hover, "pv-hover")}${boxMarks(selected, "pv-on")}<svg class="pv-lines" viewBox="0 0 1 1" preserveAspectRatio="none" aria-hidden="true">${line(hover, "pv-hover")}${line(selected, "pv-on")}</svg>
<div class="pv-nodes" role="group" aria-label=${countLine(buttons)}>${buttons.map((r) => html`<button type="button" class="pv-node" style=${buttonStyle(r)} tabindex=${sameRegion(r, stop) ? "0" : "-1"} aria-label=${regionName(r, regions)} aria-pressed=${sameRegion(r, selected) ? "true" : "false"} @click=${() => select(r, "key")} @focus=${() => { stop = r; }}></button>`)}</div>` : nothing, marks);
    drawCard();
  }

  function drawCard() {
    card.hidden = !selected;
    if (!selected) { render(nothing, card); return; }
    const r = selected;
    const title = regionTitle(r, regions);
    const row = actions(r);
    render(html`<div class="pv-sel-top"><span class="pv-sel-kind">${KIND_WORDS[r.kind]}</span><span class="pv-sel-label">${title}</span>${r.kind !== "edge" && r.id && r.id !== title ? html`<span class="pv-sel-id">${r.id}</span>` : nothing}<button type="button" class="pv-btn pv-sel-x" aria-label="Clear the selection" title="Clear the selection (Esc)" @click=${() => select(null)}>${X_ICON}</button></div>${row && row !== nothing ? html`<div class="pv-sel-acts">${row}</div>` : nothing}`, card);
  }

  // +how+: "tap" (the viewer slides after its double-tap wait) or "key" (at once).
  function select(r, how = "key") {
    const next = r && regions ? r : null;
    if (next && sameRegion(next, selected)) return;
    if (!next && !selected) return;
    const was = selected;
    const hadFocus = card.contains(doc.activeElement);
    selected = next;
    if (next) stop = buttonOf(next) || stop;
    live.textContent = next ? `${regionName(next, regions)} selected` : "";
    draw();
    // The card's going mustn't drop the focus to <body>: Esc would never reach the viewer.
    if (!next && hadFocus) {
      const back = nodeButton(was);
      if (back) back.focus({ preventScroll: true });
      else viewer.home();
    }
    onSelect(next);
    viewer.selected(next, how);
  }

  return {
    card,
    live,
    mount(box) {
      box.append(marks);
    },
    show(picture) {
      regions = picture?.regions?.length ? picture.regions : null;
      natural = { width: picture?.width || 1, height: picture?.height || 1 };
      buttons = [];
      // Every clean region has a name (block_regions.js): each gets a button.
      for (const r of regions || []) if (!buttons.some((b) => sameRegion(b, r))) buttons.push(r);
      selected = null;
      hovered = null;
      stop = buttons[0] || null;
      live.textContent = "";
      draw();
    },
    clear() {
      regions = null;
      buttons = [];
      selected = null;
      hovered = null;
      stop = null;
      live.textContent = "";
      draw();
    },
    room() {
      if (!regions) return 0;
      return coarse?.matches ? COARSE_CARD_ROOM : CARD_ROOM;
    },
    // A tap at +point+ (fractions of the picture), the picture shown at +size+ px:
    // selects what is under it, or clears. @return the region or null
    tap(point, size, pointerType) {
      if (!regions) return null;
      const hit = hitRegion(regions, point, size, pointerType === "touch" ? TOUCH_TOLERANCE : MOUSE_TOLERANCE);
      select(hit, "tap");
      return hit;
    },
    // The mouse over +point+ (null: it left). @return whether a region is under it
    hover(point, size) {
      if (!regions) return false;
      const hit = point ? hitRegion(regions, point, size, MOUSE_TOLERANCE) : null;
      if (hit !== hovered) {
        hovered = hit;
        draw();
      }
      return !!hit;
    },
    // The viewer's keydown, first: the arrows move between the nodes' buttons.
    // @return true when it was the layer's
    key(e) {
      if (!regions || !e.target?.classList?.contains("pv-node")) return false;
      const at = buttons[[...marks.querySelectorAll(".pv-node")].indexOf(e.target)];
      if (!at || !e.key?.startsWith("Arrow")) return false;
      const to = nearestInDirection(buttons, at, e.key, natural);
      if (to) {
        stop = to;
        draw();
        nodeButton(to)?.focus({ preventScroll: true });
      }
      return true;
    },
    selected: () => selected,
    select,
    // The viewer's hooks: +selected+ (region, how) after each selection, +home+
    // focuses the viewer.
    bind(hooks) {
      viewer = { ...viewer, ...hooks };
    },
  };
}
