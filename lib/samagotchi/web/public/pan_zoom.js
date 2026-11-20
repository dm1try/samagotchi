// The picture viewer's maths (picture_viewer.js), pure: no DOM, `node --test`.
//
// A view is {scale, x, y}: the picture drawn at scale × its natural size, its
// top-left corner at (x, y) in the stage's px. A stage is {width, height,
// insets: {t, r, b, l}, bar}: the viewer's box, the safe areas and the bar's
// room at the bottom; the picture is fitted and centred in what they leave.
// A picture is {width, height}, its natural size.
//
// A module of its own: its exports are new (docs/internals/web-frontend.md).

// Never closer than 8 × natural.
export const MAX_ZOOM = 8;
// A fitted picture is never blown up past this: a tiny diagram stays small.
export const MAX_FIT = 3;
// A side of the shown picture past this isn't asked of the browser.
export const MAX_SHOWN_SIDE = 16000;
// Nor a shown area past this: 4096², iOS Safari's own canvas cap, as the budget
// for an image drawn at its layout size on an iPhone (block_host.js's
// MAX_PICTURE_PIXELS, 100M, is what the page holds at all, far over what a phone draws).
export const MAX_SHOWN_PIXELS = 4096 * 4096;
// The room kept around a fitted picture.
export const FIT_PAD = 24;
// The bar's room at the bottom (its height and its offset).
export const BAR_ROOM = 56;
// A larger picture keeps at least this much of itself on screen.
export const KEEP = 60;
// A trackpad sends many small deltas: the zoom follows them, not fixed steps.
const WHEEL_ZOOM = 0.01;
// A mouse's one notch with Ctrl held is about 100 px: no more than this per event.
const WHEEL_ZOOM_MAX_DELTA = 60;
const LINE_PX = 16;
const PAGE_PX = 400;

const insetsOf = (stage) => ({ t: 0, r: 0, b: 0, l: 0, ...(stage.insets || {}) });

// The part of the stage the picture is fitted and centred in.
export function freeBox(stage) {
  const i = insetsOf(stage);
  const bar = stage.bar ?? 0;
  return { left: i.l, top: i.t, width: Math.max(0, stage.width - i.l - i.r), height: Math.max(0, stage.height - i.t - i.b - bar) };
}

// The scale at which the whole picture shows in the stage, minus its padding,
// the safe areas and the bar; never above +max+.
export function fitScale(picture, stage, { pad = FIT_PAD, max = MAX_FIT } = {}) {
  if (!(picture?.width > 0 && picture?.height > 0)) return 1;
  const box = freeBox(stage);
  const w = Math.max(1, box.width - pad * 2);
  const h = Math.max(1, box.height - pad * 2);
  return Math.min(w / picture.width, h / picture.height, max);
}

// The closest a picture goes: 8 × natural, less when a side would pass
// MAX_SHOWN_SIDE or the area MAX_SHOWN_PIXELS; never under +fit+.
export function maxScale(picture, fit = 0) {
  const side = Math.max(picture.width, picture.height);
  const byArea = Math.sqrt(MAX_SHOWN_PIXELS / (picture.width * picture.height));
  return Math.max(Math.min(MAX_ZOOM, MAX_SHOWN_SIDE / side, byArea), fit);
}

// +scale+ within the limits: half of min(fit, 1) at the farthest, maxScale at
// the closest. +limits+: {fit, picture}.
export function clampScale(scale, { fit, picture }) {
  const min = Math.min(fit, 1) / 2;
  return Math.min(Math.max(scale, min), maxScale(picture, fit));
}

// The view at scale +next+ that keeps the picture's point under +point+ still.
export function zoomAt(view, next, point) {
  const k = next / view.scale;
  return { scale: next, x: point.x - (point.x - view.x) * k, y: point.y - (point.y - view.y) * k };
}

function clampAxis(at, size, start, room, keep) {
  if (size <= room) return start + (room - size) / 2;
  return Math.min(start + room - keep, Math.max(start + keep - size, at));
}

// A picture smaller than the free box on an axis is centred on it; a larger one
// keeps at least +keep+ px of itself on screen.
export function clampView(view, picture, stage, keep = KEEP) {
  const box = freeBox(stage);
  const w = picture.width * view.scale;
  const h = picture.height * view.scale;
  const x = w <= box.width ? box.left + (box.width - w) / 2 : clampAxis(view.x, w, 0, stage.width, keep);
  const y = h <= box.height ? box.top + (box.height - h) / 2 : clampAxis(view.y, h, 0, stage.height, keep);
  return { scale: view.scale, x, y };
}

// The fitted view: the whole picture, centred.
export function fitView(picture, stage) {
  return clampView({ scale: fitScale(picture, stage), x: 0, y: 0 }, picture, stage);
}

const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
const midpoint = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });

// Two pointers against the pinch's +start+ ({a, b, view}): the view whose scale
// follows their spread (through +limit+, a scale => scale) and whose picture
// point under the start's midpoint stays under the new midpoint.
export function pinch(start, a, b, limit = (s) => s) {
  const from = distance(start.a, start.b);
  const ratio = from > 0 ? distance(a, b) / from : 1;
  const scale = limit(start.view.scale * ratio);
  const was = midpoint(start.a, start.b);
  const now = midpoint(a, b);
  const k = scale / start.view.scale;
  return { scale, x: now.x - (was.x - start.view.x) * k, y: now.y - (was.y - start.view.y) * k };
}

// A wheel event's move in px and its zoom factor: lines (deltaMode 1) are 16 px,
// pages (2) 400; the factor is exp(-deltaY × 0.01), each event's capped.
export function wheelStep(event) {
  const unit = event.deltaMode === 1 ? LINE_PX : event.deltaMode === 2 ? PAGE_PX : 1;
  let dx = (event.deltaX || 0) * unit;
  let dy = (event.deltaY || 0) * unit;
  // Shift + a mouse wheel moves sideways.
  if (event.shiftKey && !dx) [dx, dy] = [dy, 0];
  const capped = Math.max(-WHEEL_ZOOM_MAX_DELTA, Math.min(WHEEL_ZOOM_MAX_DELTA, (event.deltaY || 0) * unit));
  return { dx, dy, zoom: Math.exp(-capped * WHEEL_ZOOM) };
}
