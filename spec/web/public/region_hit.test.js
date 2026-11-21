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

// The reviewer's phone probe: a 360 x 200 px picture at fit, nodes A and B 30 px
// apart (A 100..160, B 190..250 across; 80..120 down), the arrow between them on
// y 100 with its label box 167..183 x 92..108.
const PHONE = { width: 360, height: 200 };
const px = (x, y) => ({ x: x / 360, y: y / 200 });
const pbox = (x, y, w, h) => [x / 360, y / 200, w / 360, h / 200];
const PA = node("A", pbox(100, 80, 60, 40));
const PB = node("B", pbox(190, 80, 60, 40));
const PE = { kind: "edge", id: "", label: "events", from: "A", to: "B", points: [[160 / 360, 0.5], [190 / 360, 0.5]], box: pbox(167, 92, 16, 16) };
const PHONE_REGIONS = [PA, PB, PE];

test("a finger right on an arrow's label or line between two close nodes takes the arrow", () => {
  assert.equal(hitRegion(PHONE_REGIONS, px(175, 100), PHONE, 18), PE, "the label's centre, 15 px from each node");
  assert.equal(hitRegion(PHONE_REGIONS, px(165, 104), PHONE, 18), PE, "on the line, 5 px from A");
  assert.equal(hitRegion(PHONE_REGIONS, px(175, 113), PHONE, 18), PE, "5 px under the label");
  // On a node's box: the node, the arrow leaving it or not.
  assert.equal(hitRegion(PHONE_REGIONS, px(158, 100), PHONE, 18), PA);
});

test("a finger near a node with no arrow right under it still takes the node", () => {
  // 10 px above A, 30 px from the arrow's line, 22 from its label box.
  assert.equal(hitRegion(PHONE_REGIONS, px(150, 70), PHONE, 18), PA);
  // 12 px under B; the arrow 32 px away.
  assert.equal(hitRegion(PHONE_REGIONS, px(200, 132), PHONE, 18), PB);
  // Within the margin of a node and of an arrow (10 px from each, neither right under it): the node.
  assert.equal(hitRegion([PA, { ...PE, box: undefined, points: [[0, 70 / 200], [100 / 360, 70 / 200]] }], px(90, 80), PHONE, 18), PA);
});

test("a mouse is as before: a node within 3 px beats an arrow's line within 7", () => {
  // 2 px right of A, 4 px under the line: the node.
  assert.equal(hitRegion(PHONE_REGIONS, px(162, 104), PHONE, 3), PA);
  // The label's centre: the arrow; 5 px under the label (past 3, 13 px off the line): nothing.
  assert.equal(hitRegion(PHONE_REGIONS, px(175, 100), PHONE, 3), PE);
  assert.equal(hitRegion(PHONE_REGIONS, px(175, 113), PHONE, 3), null);
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
