// A diagram's regions under a point, by maths (picture_regions.js): pure, no
// DOM, `node --test`. The viewer keeps its pointer capture, so a drag, a pinch
// and a double tap work as before, and a finger's tap can take the nearest node.
//
// Points and boxes are fractions of the picture (block_regions.js); +size+ is the
// picture's shown size in px, {width, height}, so tolerances are screen px.
// Nodes and notes win over arrows, arrows over groups; the nearest wins within
// its kind, and between two at one distance (a node inside a node) the smaller.
// A finger's margin is the exception: an arrow right under it beats a node only
// near it (hitRegion).
//
// A module of its own: its exports are new (docs/internals/web-frontend.md).

import { freeBox } from "./pan_zoom.js";

// An arrow's line is this easy to hit at least, whatever the pointer.
export const EDGE_TOLERANCE = 7;
// How far a selected box stays above the card.
export const REVEAL_MARGIN = 12;
// An arrow key's move needs a region at least this far that way (px).
const MIN_ALONG = 4;

const area = (r) => (r.box ? r.box[2] * r.box[3] : 0);

// Two regions that select together: one object, or one kind and one non-empty
// id (a sequence participant's top and bottom box).
export function sameRegion(a, b) {
  if (!a || !b) return false;
  return a === b || (a.kind === b.kind && a.id !== "" && a.id === b.id);
}

function boxDistance([x, y, w, h], p, size) {
  const dx = Math.max(x - p.x, 0, p.x - (x + w)) * size.width;
  const dy = Math.max(y - p.y, 0, p.y - (y + h)) * size.height;
  return Math.hypot(dx, dy);
}

function segmentDistance(p, a, b, size) {
  const px = p.x * size.width;
  const py = p.y * size.height;
  const ax = a[0] * size.width;
  const ay = a[1] * size.height;
  const bx = b[0] * size.width;
  const by = b[1] * size.height;
  const len = (bx - ax) ** 2 + (by - ay) ** 2;
  const t = len > 0 ? Math.max(0, Math.min(1, ((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / len)) : 0;
  return Math.hypot(px - (ax + (bx - ax) * t), py - (ay + (by - ay) * t));
}

function lineDistance(points, p, size) {
  let best = Infinity;
  for (let i = 1; i < points.length; i++) best = Math.min(best, segmentDistance(p, points[i - 1], points[i], size));
  return best;
}

const within = (d, limit) => (d <= limit ? d : Infinity);
const nodeAt = (point, size, limit) => (r) => (r.kind === "node" || r.kind === "note" ? within(boxDistance(r.box, point, size), limit) : Infinity);
const groupAt = (point, size) => (r) => (r.kind === "group" ? within(boxDistance(r.box, point, size), 0) : Infinity);
// An edge's distance: its line's within +line+ px, or its label box's within +label+.
const edgeAt = (point, size, line, label) => (r) => {
  if (r.kind !== "edge") return Infinity;
  const onLine = within(lineDistance(r.points, point, size), line);
  return r.box ? Math.min(onLine, within(boxDistance(r.box, point, size), label)) : onLine;
};

// The nearest region by +dist+ (Infinity: not one), the smaller between two at
// one distance; or null.
function nearest(regions, dist) {
  let best = null;
  let bestD = Infinity;
  for (const r of regions) {
    const d = dist(r);
    if (d < bestD || (d !== Infinity && d === bestD && area(r) < area(best))) { best = r; bestD = d; }
  }
  return best;
}

// The region under +point+ ({x, y} in fractions), within +tol+ px, or null.
// A pointer whose tolerance is within an arrow's own (a mouse) takes the nodes
// at it first, then the arrows. A wider one (a finger) takes a node only on its
// box first: an arrow's line or label right under it (7 px) beats a node that is
// only within the finger's margin, so an arrow between two close nodes can be
// tapped at a phone's fit; then the nodes and the arrows at its margin.
export function hitRegion(regions, point, size, tol) {
  if (!regions?.length || !point) return null;
  const inner = tol > EDGE_TOLERANCE ? 0 : tol;
  const direct = nearest(regions, nodeAt(point, size, inner)) ?? nearest(regions, edgeAt(point, size, EDGE_TOLERANCE, Math.min(tol, EDGE_TOLERANCE)));
  if (direct) return direct;
  const margin = inner === tol ? null : nearest(regions, nodeAt(point, size, tol)) ?? nearest(regions, edgeAt(point, size, tol, tol));
  return margin ?? nearest(regions, groupAt(point, size));
}

// A region's centre in fractions: its box's, an edge's label box's, else the
// middle of its line.
export function regionCentre(r) {
  if (r.box) return { x: r.box[0] + r.box[2] / 2, y: r.box[1] + r.box[3] / 2 };
  const p = r.points[Math.floor(r.points.length / 2)];
  return { x: p[0], y: p[1] };
}

const DIRECTIONS = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };

// The region nearest +from+ along an arrow key's way (along + 2 × across, in
// px through +size+), or null: none that way, or not an arrow key. A group is
// the move only when nothing else is that way: its centre is near everything
// it holds.
export function nearestInDirection(regions, from, key, size = { width: 1, height: 1 }) {
  return nearestOf(regions.filter((r) => r.kind !== "group"), from, key, size) ?? nearestOf(regions, from, key, size);
}

function nearestOf(regions, from, key, size) {
  const dir = DIRECTIONS[key];
  if (!dir || !from) return null;
  const me = regionCentre(from);
  let best = null;
  let score = Infinity;
  for (const r of regions) {
    if (sameRegion(r, from)) continue;
    const c = regionCentre(r);
    const dx = (c.x - me.x) * size.width;
    const dy = (c.y - me.y) * size.height;
    const along = dx * dir[0] + dy * dir[1];
    if (along < MIN_ALONG) continue;
    const s = along + 2 * Math.abs(dx * dir[1] + dy * dir[0]);
    if (s < score) { score = s; best = r; }
  }
  return best;
}

// How far up (px) the view moves so +box+ clears the card, whose top is at
// +cover+ in the stage's px; 0 when it is clear, or when the picture fits the
// free height (clampView centres it there, so a move would be undone). The box's
// top never goes above the free area for it.
export function revealOffset(box, view, picture, stage, cover) {
  if (!box) return 0;
  const free = freeBox(stage);
  const shown = picture.height * view.scale;
  if (shown <= free.height) return 0;
  const top = view.y + box[1] * shown;
  const bottom = view.y + (box[1] + box[3]) * shown;
  const need = bottom + REVEAL_MARGIN - cover;
  if (need <= 0) return 0;
  return Math.max(0, Math.min(need, top - (free.top + REVEAL_MARGIN)));
}
