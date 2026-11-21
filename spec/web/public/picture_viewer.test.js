import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createPictureViewer, thumbPicture } from "../../../lib/samagotchi/web/public/picture_viewer.js";
import { createRegionLayer } from "../../../lib/samagotchi/web/public/picture_regions.js";

const URL_A = "data:image/png;base64,AAAA";
// A 1000 x 800 stage with no insets: the room is 952 x 696 (pad 24, bar 56),
// so a 476 x 200 picture fits at 2, centred at (24, 172).
const PIC = { url: URL_A, alt: "a shot", width: 476, height: 200 };

function setup({ markup = '<img alt="">', decode = async () => {}, layer = null, later = undefined } = {}) {
  const el = document.createElement("div");
  el.id = "lightbox";
  el.hidden = true;
  el.innerHTML = markup;
  document.body.append(el);
  let clock = 1000;
  const pictures = createPictureViewer({
    el, measure: () => ({ left: 0, top: 0, width: 1000, height: 800 }), insets: () => ({ t: 0, r: 0, b: 0, l: 0 }),
    decode, now: () => clock, layer, ...(later ? { later } : {}),
  });
  const box = () => el.querySelector(".pv-pic");
  return {
    el, pictures, img: () => el.querySelector("img"), box,
    pct: () => el.querySelector(".pv-pct").textContent,
    width: () => parseFloat(box().style.width),
    place: () => box().style.transform,
    tick: (ms) => { clock += ms; },
  };
}

const key = (el, k, opts = {}) => {
  const e = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...opts });
  el.dispatchEvent(e);
  return e;
};
const pointer = (el, type, id, x, y, pointerType = "mouse") => el.dispatchEvent(new window.PointerEvent(type, { bubbles: true, cancelable: true, pointerId: id, clientX: x, clientY: y, pointerType, button: 0 }));
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const gestureEvent = (type, scale) => {
  const e = new window.Event(type, { bubbles: true, cancelable: true });
  if (scale) Object.defineProperty(e, "scale", { value: scale });
  return e;
};

test.afterEach(() => { document.body.innerHTML = ""; });

test("closed, the viewer is hidden, a modal dialog named Picture viewer", () => {
  const { el, pictures } = setup();
  assert.equal(el.hidden, true);
  assert.equal(pictures.isOpen(), false);
  assert.equal(el.getAttribute("role"), "dialog");
  assert.equal(el.getAttribute("aria-modal"), "true");
  assert.equal(el.getAttribute("aria-label"), "Picture viewer");
});

test("open shows the picture fitted, in the kept <img>, with its ✕ and bar, and takes the focus", async () => {
  const { el, pictures, img, pct, width, place } = setup();
  const kept = img();
  await pictures.open(PIC);
  assert.equal(el.hidden, false);
  assert.ok(img() === kept);
  assert.ok(kept.parentElement === el.querySelector(".pv-pic"));
  assert.equal(kept.getAttribute("src"), URL_A);
  assert.equal(kept.draggable, false);
  assert.equal(width(), 952);
  assert.equal(place(), "translate(24px, 172px)");
  assert.equal(pct(), "200%");
  assert.deepEqual([...el.querySelectorAll("button")].map((b) => b.getAttribute("aria-label")), ["Close", "Zoom out", "Zoom in", "Fit to the screen"]);
  assert.ok(document.activeElement === el);
});

test("an #lightbox with no <img> gets one", async () => {
  const { pictures, img } = setup({ markup: "" });
  await pictures.open(PIC);
  assert.equal(img().getAttribute("src"), URL_A);
});

test("the bar's buttons and the keys change the zoom; Fit and 0 return", async () => {
  const { el, pictures, pct, width } = setup();
  await pictures.open(PIC);
  el.querySelector(".pv-in").click();
  assert.equal(pct(), "250%");
  assert.equal(width(), 476 * 2.5);
  el.querySelector(".pv-out").click();
  el.querySelector(".pv-out").click();
  assert.equal(pct(), "160%");
  el.querySelector(".pv-fit").click();
  assert.equal(pct(), "200%");
  assert.ok(key(el, "+").defaultPrevented);
  assert.equal(pct(), "250%");
  key(el, "-");
  key(el, "-");
  assert.equal(pct(), "160%");
  key(el, "0");
  assert.equal(pct(), "200%");
});

test("+ with Cmd or Ctrl held is left to the browser", async () => {
  const { el, pictures, pct } = setup();
  await pictures.open(PIC);
  const e = key(el, "+", { metaKey: true });
  assert.equal(e.defaultPrevented, false);
  assert.equal(pct(), "200%");
  key(el, "+");
  key(el, "0", { ctrlKey: true });
  assert.equal(pct(), "250%");
});

test("the keys stay in the viewer: the document's listeners don't see them", async (t) => {
  const { el, pictures } = setup();
  await pictures.open(PIC);
  const seen = [];
  const listener = (e) => seen.push(e.key);
  document.addEventListener("keydown", listener);
  t.after(() => document.removeEventListener("keydown", listener));
  key(el, "ArrowLeft");
  key(el, "+");
  key(el, "Escape");
  assert.deepEqual(seen, []);
});

test("arrows move a picture larger than the screen; a drag moves it", async () => {
  const { el, pictures, place } = setup();
  await pictures.open(PIC);
  key(el, "+");
  key(el, "+"); // 3.125: 1487.5 wide, larger than the screen
  const before = place();
  key(el, "ArrowLeft");
  assert.notEqual(place(), before);
  const x = (s) => parseFloat(s.match(/translate\(([-\d.]+)px/)[1]);
  const at = x(place());
  pointer(el, "pointerdown", 1, 500, 400);
  assert.ok(el.classList.contains("dragging"));
  pointer(el, "pointermove", 1, 450, 400);
  pointer(el, "pointerup", 1, 450, 400);
  assert.equal(x(place()), at - 50);
  assert.ok(!el.classList.contains("dragging"));
});

test("a click on the surface doesn't close it; ✕ and Esc do, giving the focus back to the opener before hiding", async () => {
  const opener = document.createElement("button");
  document.body.append(opener);
  const { el, pictures } = setup();
  await pictures.open(PIC, { opener });
  pointer(el, "pointerdown", 1, 500, 400);
  pointer(el, "pointerup", 1, 500, 400);
  el.click();
  assert.equal(pictures.isOpen(), true);
  el.querySelector(".pv-close").click();
  assert.equal(pictures.isOpen(), false);
  assert.ok(document.activeElement === opener);
  await pictures.open(PIC, { opener });
  key(el, "Escape");
  assert.equal(el.hidden, true);
  assert.ok(document.activeElement === opener);
});

test("a pointerdown on the bar starts no drag", async () => {
  const { el, pictures } = setup();
  await pictures.open(PIC);
  pointer(el.querySelector(".pv-in"), "pointerdown", 1, 500, 780);
  assert.ok(!el.classList.contains("dragging"));
});

test("a double tap goes close at the point, and a second one back to fit", async () => {
  const { el, pictures, pct, tick } = setup();
  await pictures.open(PIC);
  const tap = () => { pointer(el, "pointerdown", 1, 500, 400, "touch"); pointer(el, "pointerup", 1, 500, 400, "touch"); };
  tap();
  tick(150);
  tap();
  assert.equal(pct(), "500%"); // 2.5 × fit
  tick(1000);
  tap();
  tick(150);
  tap();
  assert.equal(pct(), "200%");
  // Two taps too far apart in time are two single taps.
  tick(1000);
  tap();
  tick(500);
  tap();
  assert.equal(pct(), "200%");
});

test("a plain wheel moves; with Ctrl it zooms at the cursor", async () => {
  const { el, pictures, pct, place } = setup();
  await pictures.open(PIC);
  key(el, "+");
  key(el, "+");
  const before = place();
  el.dispatchEvent(new window.WheelEvent("wheel", { bubbles: true, cancelable: true, deltaX: 30, deltaY: 0, deltaMode: 0 }));
  assert.notEqual(place(), before);
  assert.equal(pct(), "313%");
  const e = new window.WheelEvent("wheel", { bubbles: true, cancelable: true, deltaY: -20, deltaMode: 0 });
  // happy-dom's WheelEvent takes no modifiers or place from its init.
  Object.defineProperties(e, { ctrlKey: { value: true }, clientX: { value: 500 }, clientY: { value: 400 } });
  el.dispatchEvent(e);
  assert.ok(e.defaultPrevented);
  assert.equal(pct(), `${Math.round(312.5 * Math.exp(0.2))}%`);
});

test("two touch pointers plus Safari's gesturechange apply the pinch once", async () => {
  const { el, pictures, pct } = setup();
  await pictures.open(PIC);
  pointer(el, "pointerdown", 1, 400, 400, "touch");
  pointer(el, "pointerdown", 2, 500, 400, "touch");
  const start = gestureEvent("gesturestart");
  el.dispatchEvent(start);
  pointer(el, "pointermove", 2, 600, 400, "touch");
  const change = gestureEvent("gesturechange", 2);
  el.dispatchEvent(change);
  assert.ok(start.defaultPrevented && change.defaultPrevented);
  assert.equal(pct(), "400%"); // the pointers' 2 ×, not 4 ×
});

test("a Mac trackpad's gesture (no touch pointer) zooms", async () => {
  const { el, pictures, pct } = setup();
  await pictures.open(PIC);
  el.dispatchEvent(gestureEvent("gesturestart"));
  el.dispatchEvent(gestureEvent("gesturechange", 1.5));
  assert.equal(pct(), "300%");
});

test("the native image drag is prevented", async () => {
  const { pictures, img } = setup();
  await pictures.open(PIC);
  const e = new window.Event("dragstart", { bubbles: true, cancelable: true });
  img().dispatchEvent(e);
  assert.ok(e.defaultPrevented);
});

test("a picture of unknown size waits for its decode, showing nothing till then", async () => {
  let release;
  const decoding = new Promise((resolve) => { release = resolve; });
  const { pictures, box, img, width } = setup({ decode: () => decoding });
  const opened = pictures.open({ url: URL_A });
  await settle();
  assert.ok(box().classList.contains("waiting"));
  Object.defineProperty(img(), "naturalWidth", { value: 476, configurable: true });
  Object.defineProperty(img(), "naturalHeight", { value: 200, configurable: true });
  release();
  await opened;
  assert.ok(!box().classList.contains("waiting"));
  assert.equal(width(), 952);
});

test("each open starts fitted", async () => {
  const { el, pictures, pct } = setup();
  await pictures.open(PIC);
  key(el, "+");
  pictures.close();
  await pictures.open(PIC);
  assert.equal(pct(), "200%");
});

test("thumbPicture takes a loaded thumbnail's size, and none before it loads", () => {
  const loaded = { src: URL_A, alt: "x", complete: true, naturalWidth: 40, naturalHeight: 30 };
  assert.deepEqual(thumbPicture(loaded), { url: URL_A, alt: "x", width: 40, height: 30 });
  assert.deepEqual(thumbPicture({ ...loaded, complete: false }), { url: URL_A, alt: "x", width: null, height: null });
});

test("a finger's tap may move up to 10 px (a mouse's 4) and still count toward a double tap", async () => {
  const { el, pictures, pct, tick } = setup();
  await pictures.open(PIC);
  const tap = (dx, type) => { pointer(el, "pointerdown", 1, 500, 400, type); pointer(el, "pointermove", 1, 500 + dx, 400, type); pointer(el, "pointerup", 1, 500 + dx, 400, type); };
  tap(7, "touch");
  tick(150);
  tap(7, "touch");
  assert.equal(pct(), "500%");
  el.querySelector(".pv-fit").click();
  tick(1000);
  tap(7, "mouse");
  tick(150);
  tap(7, "mouse");
  assert.equal(pct(), "200%", "a mouse that moved 7 px dragged");
});

test("made without PointerEvent, ResizeObserver or a layout read", () => {
  const saved = { PointerEvent: globalThis.PointerEvent, ResizeObserver: globalThis.ResizeObserver };
  delete globalThis.PointerEvent;
  delete globalThis.ResizeObserver;
  try {
    const el = document.createElement("div");
    el.hidden = true;
    document.body.append(el);
    let measured = 0;
    const pictures = createPictureViewer({ el, measure: () => { measured += 1; return { width: 0, height: 0 }; }, insets: () => { measured += 1; return {}; } });
    pictures.useLayer({ mount() {}, show() {}, clear() {}, room: () => { measured += 1; return 0; } });
    assert.equal(measured, 0);
    assert.equal(pictures.isOpen(), false);
  } finally {
    Object.assign(globalThis, saved);
  }
});

// A layer that records what the viewer tells it.
function fakeLayer(room = 0) {
  const calls = [];
  return {
    calls,
    mount: (box) => calls.push(["mount", box.className]),
    show: (picture) => calls.push(["show", picture]),
    clear: () => calls.push(["clear"]),
    room: () => room,
  };
}

test("a layer mounts once on .pv-pic, is cleared and shown the open's picture on each open, and cleared on close", async () => {
  const { pictures } = setup();
  const layer = fakeLayer();
  pictures.useLayer(layer);
  assert.deepEqual(layer.calls, []);
  await pictures.open({ ...PIC, extra: 1 });
  assert.deepEqual(layer.calls, [["mount", "pv-pic"], ["clear"], ["show", { ...PIC, extra: 1 }]]);
  pictures.close();
  await pictures.open(PIC);
  assert.deepEqual(layer.calls.map((c) => c[0]), ["mount", "clear", "show", "clear", "clear", "show"]);
});

test("a layer is shown a picture of unknown size with its decoded size", async () => {
  const { pictures, img } = setup();
  const layer = fakeLayer();
  pictures.useLayer(layer);
  Object.defineProperty(img(), "naturalWidth", { value: 800, configurable: true });
  Object.defineProperty(img(), "naturalHeight", { value: 200, configurable: true });
  await pictures.open({ url: URL_A, regions: [] });
  assert.deepEqual(layer.calls.at(-1), ["show", { url: URL_A, regions: [], width: 800, height: 200 }]);
});

test("a layer given after the first open mounts at once; its room is kept at the bottom of the fit", async () => {
  const { pictures, width, place } = setup();
  await pictures.open(PIC);
  const layer = fakeLayer(96);
  pictures.useLayer(layer);
  assert.deepEqual(layer.calls, [["mount", "pv-pic"]]);
  await pictures.open(PIC);
  // The room is 952 x 600 now: 476 x 200 still fits at 2 by width, centred in the 600.
  assert.equal(width(), 952);
  assert.equal(place(), "translate(24px, 124px)");
});

test("without a layer the viewer fits as before", async () => {
  const { pictures, place } = setup();
  await pictures.open(PIC);
  assert.equal(place(), "translate(24px, 172px)");
});

// With the regions' layer: the room is 952 x 632 (pad 24, bar 56, the card's 64),
// so the 476 x 200 picture fits at 2, centred at (24, 140) in the free 680.
const NODE = { kind: "node", id: "BR", label: "Bridge", box: [0.5, 0.5, 0.1, 0.1] }; // 500..595 x 340..380 at fit
const LOW = { kind: "node", id: "LO", label: "Low", box: [0.4, 0.85, 0.2, 0.1] };
const WITH_REGIONS = { ...PIC, regions: [NODE, LOW] };

function regionsSetup() {
  const timers = [];
  const layer = createRegionLayer();
  const v = setup({ layer, later: (fn) => timers.push(fn) });
  layer.card.getBoundingClientRect = () => ({ top: 660 });
  const tap = (x, y, type = "mouse") => { pointer(v.el, "pointerdown", 1, x, y, type); pointer(v.el, "pointerup", 1, x, y, type); };
  const y = () => parseFloat(v.place().match(/, ([-\d.]+)px/)[1]);
  return { ...v, layer, timers, tap, y, runTimers: () => timers.splice(0).forEach((fn) => fn()) };
}

test("a picture with regions fits with the card's room; one without fits as before, the same layer there", async () => {
  const { pictures, place } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  assert.equal(place(), "translate(24px, 140px)");
  await pictures.open(PIC);
  assert.equal(place(), "translate(24px, 172px)");
});

test("the layer's card and live line join the viewer, after its bar", async () => {
  const { el, pictures, layer } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  assert.ok(layer.card.parentElement === el && layer.live.parentElement === el);
  assert.ok(el.querySelector(".pv-pic .pv-marks"));
  assert.ok(el.querySelector(".pv-bar").compareDocumentPosition(layer.card) & 4);
});

test("a tap selects and still counts toward a double tap, which zooms at its point; the picture doesn't slide between the taps", async () => {
  const { pictures, layer, tap, tick, pct, timers, runTimers, place } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  tap(520, 360);
  assert.equal(layer.selected(), NODE);
  tick(150);
  tap(520, 360);
  assert.equal(pct(), "500%");
  assert.equal(layer.selected(), NODE);
  const zoomed = place();
  assert.ok(timers.length >= 1);
  runTimers();
  assert.equal(place(), zoomed, "no slide after a double tap");
});

test("a drag doesn't select; a tap on empty space clears", async () => {
  const { el, pictures, layer, tap } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  pointer(el, "pointerdown", 1, 520, 360);
  pointer(el, "pointermove", 1, 540, 360);
  pointer(el, "pointerup", 1, 540, 360);
  assert.equal(layer.selected(), null);
  tap(560, 365);
  assert.equal(layer.selected(), NODE);
  tap(100, 150);
  assert.equal(layer.selected(), null);
});

test("zoomed in, a selected node under the card slides up into view after the double-tap wait", async () => {
  const { el, pictures, layer, tap, y, runTimers, tick } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  for (let i = 0; i < 4; i++) key(el, "+"); // 4.88: 976.5 px tall, more than the free 680
  const before = y();
  const tall = 200 * 2 * 1.25 ** 4;
  tap(500, before + 0.9 * tall); // LOW, its bottom under the card's top (660)
  assert.equal(layer.selected(), LOW);
  assert.equal(y(), before, "not before the wait");
  tick(400);
  runTimers();
  const bottom = before + 0.95 * tall;
  assert.ok(bottom > 660);
  assert.ok(Math.abs(y() - (before - (bottom + 12 - 660))) < 1, `${before} → ${y()}`);
});

test("a fitted picture never slides: a node is above the card already", async () => {
  const { pictures, layer, tap, place, runTimers } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  tap(520, 520); // LOW at fit: 480..520
  assert.equal(layer.selected(), LOW);
  runTimers();
  assert.equal(place(), "translate(24px, 140px)");
});

test("Esc clears the selection first, then closes", async () => {
  const { el, pictures, layer, tap } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  tap(520, 360);
  key(el, "Escape");
  assert.equal(layer.selected(), null);
  assert.equal(pictures.isOpen(), true);
  key(el, "Escape");
  assert.equal(pictures.isOpen(), false);
});

test("from the card's ✕: Esc clears and the focus goes to the node's button; Esc again closes", async () => {
  const { el, pictures, layer, tap } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  tap(520, 360);
  const x = el.querySelector(".pv-sel-x");
  x.focus();
  key(x, "Escape");
  assert.equal(layer.selected(), null);
  assert.equal(document.activeElement.getAttribute("aria-label"), "node Bridge, BR");
  key(document.activeElement, "Escape");
  assert.equal(pictures.isOpen(), false);
});

test("the keyboard: a node's Enter selects (its click), arrows move between nodes, not the picture", async () => {
  const { el, pictures, layer, place } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  const [bridge] = el.querySelectorAll(".pv-node");
  bridge.focus();
  const at = place();
  assert.ok(key(bridge, "ArrowDown").defaultPrevented);
  assert.equal(document.activeElement.getAttribute("aria-label"), "node Low, LO");
  assert.equal(place(), at);
  document.activeElement.click();
  assert.equal(layer.selected(), LOW);
});

test("a pointerdown on the card starts no drag; close and a new open clear the selection", async () => {
  const { el, pictures, layer, tap } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  tap(520, 360);
  pointer(el.querySelector(".pv-sel"), "pointerdown", 1, 500, 700);
  assert.ok(!el.classList.contains("dragging"));
  pointer(el, "pointerup", 1, 500, 700);
  pictures.close();
  assert.equal(layer.selected(), null);
  await pictures.open(WITH_REGIONS);
  tap(520, 360);
  await pictures.open(WITH_REGIONS);
  assert.equal(layer.selected(), null);
});

test("the mouse over a node, no button down, outlines it and shows the hand", async () => {
  const { el, pictures } = regionsSetup();
  await pictures.open(WITH_REGIONS);
  pointer(el, "pointermove", 1, 520, 360);
  await new Promise((r) => setTimeout(r, 40));
  assert.ok(el.classList.contains("over"));
  assert.equal(el.querySelectorAll(".pv-mark.pv-hover").length, 1);
  el.dispatchEvent(new window.PointerEvent("pointerleave", { pointerType: "mouse" }));
  assert.ok(!el.classList.contains("over"));
  assert.equal(el.querySelectorAll(".pv-mark.pv-hover").length, 0);
});
