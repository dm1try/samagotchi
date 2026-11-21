import test from "node:test";
import assert from "node:assert/strict";
import { hitRegion, nearestInDirection, regionCentre, revealOffset, sameRegion } from "../../../lib/samagotchi/web/public/region_hit.js";

// A 1000 x 500 px picture: 0.01 of x is 10 px, of y 5 px.
const SIZE = { width: 1000, height: 500 };
const node = (id, box) => ({ kind: "node", id, label: id, box });
const A = node("A", [0.1, 0.1, 0.1, 0.1]);
const B = node("B", [0.4, 0.1, 0.1, 0.1]);
const C = node("C", [0.1, 0.6, 0.1, 0.1]);
const G = { kind: "group", id: "g", label: "Group", box: [0.05, 0.05, 0.6, 0.8] };
const E = { kind: "edge", id: "", label: "", from: "A", to: "B", points: [[0.2, 0.15], [0.3, 0.15], [0.4, 0.15]] };
const LABELLED = { kind: "edge", id: "", label: "events", from: "A", to: "C", points: [[0.15, 0.2], [0.15, 0.6]], box: [0.13, 0.38, 0.04, 0.04] };
const REGIONS = [G, A, B, C, E, LABELLED];

test("a node wins over an edge, an edge over a group", () => {
  assert.equal(hitRegion(REGIONS, { x: 0.15, y: 0.15 }, SIZE, 3), A);
  assert.equal(hitRegion(REGIONS, { x: 0.35, y: 0.15 }, SIZE, 3), E);
  assert.equal(hitRegion(REGIONS, { x: 0.35, y: 0.5 }, SIZE, 3), G);
  // On a node's edge with an arrow leaving it: the node.
  assert.equal(hitRegion(REGIONS, { x: 0.2, y: 0.15 }, SIZE, 3), A);
});

test("a touch's tolerance takes the nearest of two nodes; a mouse's takes neither", () => {
  // x 0.392: 192 px right of A, 8 px left of B; x 0.215: 15 px right of A. The gap point is 50 px under B.
  const gap = { x: 0.392, y: 0.3 };
  assert.equal(hitRegion([A, B], { x: 0.392, y: 0.15 }, SIZE, 18), B);
  assert.equal(hitRegion([A, B], { x: 0.215, y: 0.15 }, SIZE, 18), A);
  assert.equal(hitRegion([A, B], { x: 0.3, y: 0.15 }, SIZE, 3), null);
  assert.equal(hitRegion([A, B], gap, SIZE, 18), null);
});

test("an edge is hit between two of its points, at its line's tolerance (7 px at least)", () => {
  assert.equal(hitRegion([E], { x: 0.25, y: 0.15 + 6 / 500 }, SIZE, 3), E);
  assert.equal(hitRegion([E], { x: 0.25, y: 0.15 + 8 / 500 }, SIZE, 3), null);
  assert.equal(hitRegion([E], { x: 0.25, y: 0.15 + 15 / 500 }, SIZE, 18), E);
});

test("an edge is hit on its label's box too, to its corner", () => {
  assert.equal(hitRegion([LABELLED], { x: 0.17, y: 0.42 }, SIZE, 3), LABELLED);
  assert.equal(hitRegion([LABELLED], { x: 0.17 + 2 / 1000, y: 0.42 + 2 / 500 }, SIZE, 3), LABELLED);
});

test("nothing under the point: null; no regions: null", () => {
  assert.equal(hitRegion(REGIONS, { x: 0.9, y: 0.9 }, SIZE, 18), null);
  assert.equal(hitRegion([], { x: 0.1, y: 0.1 }, SIZE, 18), null);
  assert.equal(hitRegion(null, { x: 0.1, y: 0.1 }, SIZE, 18), null);
});

test("a node inside a node at one distance: the smaller; nested groups: the inner", () => {
  const outer = node("O", [0, 0, 0.5, 0.5]);
  const inner = node("I", [0.1, 0.1, 0.1, 0.1]);
  assert.equal(hitRegion([outer, inner], { x: 0.15, y: 0.15 }, SIZE, 3), inner);
  const g2 = { kind: "group", id: "g2", label: "", box: [0.3, 0.3, 0.2, 0.2] };
  assert.equal(hitRegion([G, g2], { x: 0.4, y: 0.4 }, SIZE, 3), g2);
});

test("sameRegion: one object, or one kind and one non-empty id", () => {
  assert.ok(sameRegion(A, A));
  assert.ok(sameRegion(A, { ...A, box: [0, 0.9, 0.1, 0.1] }));
  assert.ok(!sameRegion(A, { ...A, kind: "group" }));
  assert.ok(!sameRegion(E, { ...E }), "no id: not the same unless one object");
  assert.ok(!sameRegion(A, null));
});

test("the arrows move to the nearest region that way, along + 2 x across", () => {
  assert.equal(nearestInDirection([A, B, C], A, "ArrowRight", SIZE), B);
  assert.equal(nearestInDirection([A, B, C], A, "ArrowDown", SIZE), C);
  assert.equal(nearestInDirection([A, B, C], B, "ArrowLeft", SIZE), A);
  assert.equal(nearestInDirection([A, B, C], A, "ArrowLeft", SIZE), null);
  assert.equal(nearestInDirection([A, B, C], A, "Enter", SIZE), null);
  // A twin of A (its bottom box) is never the move.
  assert.equal(nearestInDirection([A, { ...A, box: [0.1, 0.8, 0.1, 0.1] }, B], A, "ArrowDown", SIZE), null);
});

test("a group is an arrow's move only when nothing else is that way", () => {
  const inner = node("I", [0.5, 0.5, 0.1, 0.1]);
  const far = node("F", [0.9, 0.55, 0.05, 0.05]);
  const group = { kind: "group", id: "g", label: "", box: [0.45, 0.2, 0.3, 0.6] };
  assert.equal(nearestInDirection([inner, far, group], inner, "ArrowRight", SIZE), far);
  assert.equal(nearestInDirection([inner, group], inner, "ArrowUp", SIZE), group);
});

test("an edge's centre is its label box's, else its middle point", () => {
  assert.deepEqual(regionCentre(LABELLED), { x: 0.15, y: 0.4 });
  assert.deepEqual(regionCentre(E), { x: 0.3, y: 0.15 });
});

test("revealOffset: how far up a box under the card moves; 0 when clear or when the picture fits", () => {
  const stage = { width: 400, height: 800, insets: { t: 0, r: 0, b: 0, l: 0 }, bar: 120 };
  const picture = { width: 1000, height: 1000 };
  const view = { scale: 2, x: 0, y: -400 }; // 2000 px tall, top at -400
  // A box at 0.5..0.55: 600..700 px on screen; the card's top at 660.
  assert.equal(revealOffset([0.1, 0.5, 0.1, 0.05], view, picture, stage, 660), 700 + 12 - 660);
  assert.equal(revealOffset([0.1, 0.2, 0.1, 0.05], view, picture, stage, 660), 0);
  // Fitted (the shown height inside the free 680): no move.
  assert.equal(revealOffset([0.1, 0.9, 0.1, 0.1], { scale: 0.4, x: 0, y: 140 }, picture, stage, 660), 0);
  // A box taller than the room above the card: its top stays 12 px from the top.
  assert.equal(revealOffset([0.1, 0.25, 0.1, 0.5], view, picture, stage, 660), 100 - 12);
  assert.equal(revealOffset(null, view, picture, stage, 660), 0);
});
