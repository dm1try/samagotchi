// The picture viewer (#lightbox): an attached image, or a drawn diagram
// (block_host.js), over the whole page, fitted at first, with zoom and pan.
// The maths is pan_zoom.js's; this is the DOM and the gestures
// (docs/internals/web-frontend.md, Picture viewer).
//
// - Zoom is the picture's layout size (its box's width and height in px) and a
//   2D translate its place: an SVG <img> is drawn again at its layout size, a
//   scaled one can be a blurred bitmap. No will-change, no 3D transform, no
//   animation: a composited layer at the largest size is hundreds of MB.
// - One pointer drags, two pinch; plain wheel moves, Ctrl/Cmd + wheel (a
//   Chromium trackpad pinch) zooms at the cursor. Safari's gesture events are
//   always prevented and applied only with no touch pointer down (a Mac
//   trackpad): iOS fires them for a finger pinch too, beside the pointers.
// - A double tap or click goes close, or back to fit when already closer.
// - Closing is ✕ and Esc only; the keys are on the viewer's element.
//
// The picture and its place are one positioned box (.pv-pic), so an overlay on
// the picture shares it: a layer (useLayer; picture_regions.js) mounts its own
// child there and is told what is shown ({mount(box), show(picture), clear(),
// room()}: room() is the px it needs kept at the bottom, beside the bar's), and
// what the pointer and the keys do (tap, hover, key, selected, select, bind; its
// card and live line join the viewer's element).
// - A tap that isn't a move goes to the layer before the double-tap bookkeeping,
//   which is unchanged: a double tap's first tap has selected what it hit. A
//   selected node under the card slides into view TAP_MS after its tap, only if
//   no second tap came (a double tap zooms at the point it hit); a keyboard's at once.
// - The mouse over the picture, no button down, is the layer's hover, at most
//   once per frame.
// - Esc with a selection clears it; a second Esc closes.
//
// +picture+: {url, width, height, alt}; width and height may be absent.
// A module of its own: its exports are new (docs/internals/web-frontend.md,
// "New exports go in new modules").

import { html, render } from "./vendor/lit-html.js";
import { focusBack, modalDialog } from "./popover_modal.js";
import { BAR_ROOM, clampScale, clampView, fitScale, fitView, pinch, wheelStep, zoomAt } from "./pan_zoom.js";
import { revealOffset } from "./region_hit.js";

const LABEL = "Picture viewer";
const STEP = 1.25;
const ARROW_PX = 60;
const TAP_MS = 300;
// How far a pointer may move (|dx| + |dy|) and still be a tap: a finger wobbles more.
const TAP_SLOP = 4;
const TOUCH_TAP_SLOP = 10;
// A double tap goes this close to the fit, or to natural size if that is closer.
const CLOSE_FACTOR = 2.5;

const icon = (d) => html`<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d=${d} fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>`;

// A thumbnail's picture: its size once loaded, so most opens don't wait for
// a decode.
export function thumbPicture(img) {
  const sized = img.complete && img.naturalWidth > 0;
  return { url: img.src, alt: img.alt, width: sized ? img.naturalWidth : null, height: sized ? img.naturalHeight : null };
}

// The safe areas, as #lightbox's padding resolves them (index.html: --safe-*).
function paddingInsets(el, win) {
  const s = win.getComputedStyle?.(el);
  const px = (v) => parseFloat(v) || 0;
  return s ? { t: px(s.paddingTop), r: px(s.paddingRight), b: px(s.paddingBottom), l: px(s.paddingLeft) } : { t: 0, r: 0, b: 0, l: 0 };
}

// @param el the #lightbox element (index.html keeps its <img> for an older
//   cached app.js, which reads it; one is added when it is missing)
// The rest are seams for the specs: +measure+ the viewer's box, +insets+ its
// safe areas, +decode+ an image of unknown size, +now+ the clock of a double tap,
// +layer+ an overlay from the start (else useLayer), +later+ the slide's timer.
// Nothing here touches layout, PointerEvent or ResizeObserver until an open.
// @return {open(picture, {opener}), close(), isOpen(), useLayer(layer)}
export function createPictureViewer({
  el, doc = document, win = window, measure = () => el.getBoundingClientRect(), insets = () => paddingInsets(el, win),
  decode = (img) => img.decode(), now = Date.now, layer: firstLayer = null, later = (fn, ms) => setTimeout(fn, ms),
}) {
  const img = el.querySelector("img") || el.appendChild(doc.createElement("img"));
  img.draggable = false;
  el.tabIndex = -1;
  modalDialog(el, { label: LABEL, isOpen: () => isOpen(), doc });

  let drawn = false;
  let box = null;
  let pct = null;
  let picture = null;
  let view = { scale: 1, x: 0, y: 0 };
  let atFit = true;
  let opener = null;
  let opening = 0;
  const pointers = new Map();
  let pinchStart = null;
  let gesture = null;
  let down = null;
  let lastTap = null;
  let layer = firstLayer;
  let mounted = null;
  let hoverAt = null;
  let hoverFrame = 0;

  const isOpen = () => !el.hidden;

  function stage() {
    const rect = measure();
    return { width: rect.width, height: rect.height, insets: insets(), bar: BAR_ROOM + (layer?.room() ?? 0) };
  }

  const fit = () => fitScale(picture, stage());
  const limit = (scale) => clampScale(scale, { fit: fit(), picture });

  function paint() {
    if (!picture) return;
    view = clampView(view, picture, stage());
    box.style.width = `${picture.width * view.scale}px`;
    box.style.height = `${picture.height * view.scale}px`;
    box.style.transform = `translate(${view.x}px, ${view.y}px)`;
    pct.textContent = `${Math.round(view.scale * 100)}%`;
  }

  function toFit() {
    if (!picture) return;
    view = fitView(picture, stage());
    atFit = true;
    paint();
  }

  function zoomTo(scale, point) {
    if (!picture) return;
    view = zoomAt(view, limit(scale), point);
    atFit = false;
    paint();
  }

  function moveBy(dx, dy) {
    if (!picture) return;
    view = { ...view, x: view.x + dx, y: view.y + dy };
    atFit = false;
    paint();
  }

  function centre() {
    const rect = measure();
    return { x: rect.width / 2, y: rect.height / 2 };
  }

  function local(e) {
    const rect = measure();
    return { x: e.clientX - (rect.left || 0), y: e.clientY - (rect.top || 0) };
  }

  // A double tap at +point+: close in, or back to fit when already closer.
  function toggleClose(point) {
    const f = fit();
    if (view.scale > f * 1.05) toFit();
    else zoomTo(Math.max(f * CLOSE_FACTOR, 1), point);
  }

  function draw() {
    if (drawn) return;
    drawn = true;
    render(html`<div class="pv-pic">${img}</div>
<button type="button" class="pv-btn pv-close" aria-label="Close" title="Close (Esc)" @click=${() => close()}>${icon("M4 4l8 8M12 4l-8 8")}</button>
<div class="pv-bar">
  <button type="button" class="pv-btn pv-out" aria-label="Zoom out" title="Zoom out (-)" @click=${() => zoomTo(view.scale / STEP, centre())}>${icon("M3.5 8h9")}</button>
  <span class="pv-pct" aria-live="polite"></span>
  <button type="button" class="pv-btn pv-in" aria-label="Zoom in" title="Zoom in (+)" @click=${() => zoomTo(view.scale * STEP, centre())}>${icon("M3.5 8h9M8 3.5v9")}</button>
  <span class="pv-sep" aria-hidden="true"></span>
  <button type="button" class="pv-btn pv-fit" aria-label="Fit to the screen" title="Fit (0)" @click=${() => toFit()}>Fit</button>
</div>`, el);
    box = el.querySelector(".pv-pic");
    pct = el.querySelector(".pv-pct");
    mountLayer();
  }

  // The layer's own child goes into .pv-pic once, when both are there.
  function mountLayer() {
    if (!layer || !box || mounted === layer) return;
    mounted = layer;
    layer.mount(box);
    for (const part of [layer.card, layer.live]) if (part) el.append(part);
    layer.bind?.({
      selected: (region, how) => { if (region && how !== "tap") reveal(); },
      home: () => el.focus({ preventScroll: true }),
    });
  }

  // A surface point → fractions of the picture.
  function toPicture(at) {
    return { x: (at.x - view.x) / (picture.width * view.scale), y: (at.y - view.y) / (picture.height * view.scale) };
  }

  function shownSize() {
    return { width: picture.width * view.scale, height: picture.height * view.scale };
  }

  // The selected node clear of the card: zoomed in, the view moves up so far.
  function reveal() {
    const region = layer?.selected();
    if (!picture || !region || !layer.card) return;
    const p = region.points?.[Math.floor(region.points.length / 2)];
    const box = region.box || (p && [p[0], p[1], 0, 0]);
    const cover = layer.card.getBoundingClientRect().top - (measure().top || 0);
    const offset = revealOffset(box, view, picture, stage(), cover);
    if (offset > 0) moveBy(0, -offset);
  }

  function hoverSoon(at) {
    hoverAt = at;
    if (hoverFrame) return;
    hoverFrame = win.requestAnimationFrame?.(() => {
      hoverFrame = 0;
      const over = !!(picture && hoverAt && layer?.hover(toPicture(hoverAt), shownSize()));
      el.classList.toggle("over", over);
    }) || 0;
  }

  function hoverOff() {
    hoverAt = null;
    layer?.hover(null);
    el.classList.remove("over");
  }

  function useLayer(next) {
    layer = next;
    mountLayer();
  }

  function onResize() {
    if (atFit) toFit();
    else paint();
  }

  async function open(next, { opener: from = null } = {}) {
    draw();
    const token = ++opening;
    opener = from;
    pointers.clear();
    pinchStart = null;
    gesture = null;
    lastTap = null;
    picture = null;
    layer?.clear();
    el.classList.remove("over");
    box.classList.add("waiting");
    img.alt = next.alt || "";
    img.src = next.url;
    if (!isOpen()) {
      el.hidden = false;
      win.addEventListener?.("resize", onResize);
    }
    el.focus({ preventScroll: true });
    let size = next.width > 0 && next.height > 0 ? { width: next.width, height: next.height } : null;
    if (!size) {
      try { await decode(img); } catch (_) { /* its natural size, if any, all the same */ }
      if (token !== opening || !isOpen()) return;
      size = { width: img.naturalWidth || 300, height: img.naturalHeight || 150 };
    }
    picture = size;
    // Its size as shown, a decoded one too: the layer's arrow keys measure in it.
    layer?.show({ ...next, ...size });
    toFit();
    // Placed already; shown once there is something to show (WebKit draws a
    // broken-image box while even a cached URL loads).
    if (!img.complete) {
      try { await decode(img); } catch (_) { /* shown all the same */ }
      if (token !== opening || !isOpen()) return;
    }
    box.classList.remove("waiting");
  }

  function close() {
    if (!isOpen()) return;
    opening++;
    const back = focusBack(el, { doc, preventScroll: true });
    el.hidden = true;
    el.classList.remove("dragging");
    win.removeEventListener?.("resize", onResize);
    pointers.clear();
    pinchStart = null;
    gesture = null;
    layer?.clear();
    back(opener);
    opener = null;
  }

  const onControls = (e) => e.target.closest?.(".pv-close, .pv-bar, .pv-sel");
  const touchDown = () => [...pointers.values()].some((p) => p.type === "touch");

  el.addEventListener("pointerdown", (e) => {
    if (onControls(e) || !picture) return;
    if (e.pointerType === "mouse" && e.button !== 0) return;
    try { el.setPointerCapture?.(e.pointerId); } catch (_) { /* a pointer already gone */ }
    pointers.set(e.pointerId, { ...local(e), type: e.pointerType });
    el.classList.add("dragging");
    if (pointers.size === 1) down = { ...local(e), type: e.pointerType, moved: false };
    if (pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      pinchStart = { a, b, view };
      down.moved = true;
    }
  });

  el.addEventListener("pointermove", (e) => {
    const was = pointers.get(e.pointerId);
    if (!was) {
      if (layer && !pointers.size && e.pointerType === "mouse") {
        if (onControls(e)) hoverOff();
        else hoverSoon(local(e));
      }
      return;
    }
    const at = { ...local(e), type: was.type };
    pointers.set(e.pointerId, at);
    if (pointers.size === 1) {
      if (!down.moved && Math.abs(at.x - down.x) + Math.abs(at.y - down.y) > (down.type === "touch" ? TOUCH_TAP_SLOP : TAP_SLOP)) {
        down.moved = true;
        if (layer) hoverOff();
      }
      moveBy(at.x - was.x, at.y - was.y);
    } else if (pointers.size === 2 && pinchStart) {
      const [a, b] = [...pointers.values()];
      view = pinch(pinchStart, a, b, limit);
      atFit = false;
      paint();
    }
  });

  function up(e) {
    if (!pointers.delete(e.pointerId)) return;
    if (pointers.size < 2) pinchStart = null;
    if (pointers.size) return;
    el.classList.remove("dragging");
    if (e.type !== "pointerup" || down?.moved) { lastTap = null; return; }
    const t = now();
    const at = local(e);
    if (layer && picture) {
      const hit = layer.tap(toPicture(at), shownSize(), down?.type);
      if (hit) {
        const first = lastTap;
        // Only a first tap slides, and only if no second one comes.
        later(() => { if (lastTap && lastTap !== first && lastTap.t === t) reveal(); }, TAP_MS);
      }
    }
    if (lastTap && t - lastTap.t < TAP_MS && Math.abs(at.x - lastTap.x) + Math.abs(at.y - lastTap.y) < 30) {
      lastTap = null;
      toggleClose(at);
    } else {
      lastTap = { t, ...at };
    }
  }
  el.addEventListener("pointerup", up);
  el.addEventListener("pointercancel", up);
  el.addEventListener("pointerleave", () => { if (layer) hoverOff(); });
  // A focused node's button out of sight mustn't scroll the surface: the
  // picture is placed by its translate alone.
  el.addEventListener("scroll", () => { el.scrollTop = 0; el.scrollLeft = 0; });
  el.addEventListener("dragstart", (e) => e.preventDefault());

  el.addEventListener("wheel", (e) => {
    e.preventDefault();
    if (!picture) return;
    const step = wheelStep(e);
    if (e.ctrlKey || e.metaKey) zoomTo(view.scale * step.zoom, local(e));
    else moveBy(-step.dx, -step.dy);
  }, { passive: false });

  // Safari's gestures: always prevented (they would zoom the page), applied
  // only for a Mac trackpad (no touch pointer down).
  el.addEventListener("gesturestart", (e) => {
    e.preventDefault();
    gesture = picture && !touchDown() ? { view, point: local(e) } : null;
  });
  el.addEventListener("gesturechange", (e) => {
    e.preventDefault();
    if (!gesture || touchDown() || !picture) return;
    view = zoomAt(gesture.view, limit(gesture.view.scale * e.scale), gesture.point);
    atFit = false;
    paint();
  });
  el.addEventListener("gestureend", (e) => {
    e.preventDefault();
    gesture = null;
  });

  el.addEventListener("keydown", (e) => {
    const k = e.key;
    const plain = !e.ctrlKey && !e.metaKey && !e.altKey;
    let done = true;
    if (plain && layer?.key(e)) { /* the layer's: an arrow between the nodes */ }
    else if (k === "Escape" && layer?.selected()) layer.select(null);
    else if (k === "Escape") close();
    else if (plain && (k === "+" || k === "=")) zoomTo(view.scale * STEP, centre());
    else if (plain && (k === "-" || k === "_")) zoomTo(view.scale / STEP, centre());
    else if (plain && k === "0") toFit();
    else if (plain && k === "ArrowLeft") moveBy(ARROW_PX, 0);
    else if (plain && k === "ArrowRight") moveBy(-ARROW_PX, 0);
    else if (plain && k === "ArrowUp") moveBy(0, ARROW_PX);
    else if (plain && k === "ArrowDown") moveBy(0, -ARROW_PX);
    else done = false;
    if (!done) return;
    e.preventDefault();
    e.stopPropagation();
  });

  return { open, close, isOpen, useLayer };
}
