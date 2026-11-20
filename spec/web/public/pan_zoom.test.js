import test from "node:test";
import assert from "node:assert/strict";
import {
  clampScale, clampView, fitScale, fitView, KEEP, MAX_SHOWN_PIXELS, MAX_SHOWN_SIDE, MAX_ZOOM, maxScale, pinch, wheelStep, zoomAt,
} from "../../../lib/samagotchi/web/public/pan_zoom.js";

const near = (a, b, eps = 1e-9) => assert.ok(Math.abs(a - b) < eps, `${a} ≈ ${b}`);
const STAGE = { width: 1000, height: 800, insets: { t: 0, r: 0, b: 0, l: 0 }, bar: 56 };

test("fitScale: a wide picture fits the width, a tall one the height, inside the padding and the bar", () => {
  // Room: 1000 - 48 = 952 wide, 800 - 56 - 48 = 696 tall.
  near(fitScale({ width: 1904, height: 400 }, STAGE), 0.5);
  near(fitScale({ width: 400, height: 1392 }, STAGE), 0.5);
});

test("fitScale: the safe areas come off too", () => {
  const phone = { width: 390, height: 844, insets: { t: 59, r: 0, b: 34, l: 0 }, bar: 56 };
  // 844 - 59 - 34 - 56 - 48 = 647 tall; 390 - 48 = 342 wide.
  near(fitScale({ width: 342, height: 6470 }, phone), 0.1);
  const landscape = { width: 932, height: 430, insets: { t: 0, r: 59, b: 21, l: 59 }, bar: 56 };
  near(fitScale({ width: 7660, height: 10 }, landscape), 0.1); // 932 - 118 - 48 = 766
});

test("fitScale: a tiny picture isn't blown up past 3", () => {
  assert.equal(fitScale({ width: 20, height: 10 }, STAGE), 3);
});

test("fitView centres the fitted picture in the room the bar and the safe areas leave", () => {
  const view = fitView({ width: 1904, height: 400 }, { ...STAGE, insets: { t: 40, r: 0, b: 0, l: 0 } });
  near(view.x, 24);
  // 800 - 40 - 56 = 704 tall room from 40; the picture 200 tall.
  near(view.y, 40 + (704 - 200) / 2);
});

test("zoomAt keeps the picture's point under the pointer still", () => {
  const view = { scale: 1, x: 100, y: 50 };
  const point = { x: 400, y: 300 };
  const next = zoomAt(view, 2.5, point);
  assert.equal(next.scale, 2.5);
  // The picture's point (300, 250) at scale 1 is still under (400, 300).
  near((point.x - next.x) / next.scale, 300);
  near((point.y - next.y) / next.scale, 250);
});

test("clampScale: half of min(fit, 1) at the farthest, 8 × natural at the closest", () => {
  const picture = { width: 400, height: 300 };
  assert.equal(clampScale(0.01, { fit: 0.6, picture }), 0.3);
  assert.equal(clampScale(0.01, { fit: 2, picture }), 0.5);
  assert.equal(clampScale(50, { fit: 0.6, picture }), MAX_ZOOM);
  assert.equal(clampScale(1.7, { fit: 0.6, picture }), 1.7);
});

test("clampScale: a large picture's closest keeps a side under 16,000 px and the area under the budget", () => {
  const long = { width: 4000, height: 100 };
  assert.equal(maxScale(long), MAX_SHOWN_SIDE / 4000);
  const big = { width: 2600, height: 2600 };
  const max = maxScale(big);
  near(big.width * max * big.height * max, MAX_SHOWN_PIXELS, 1e-3);
  assert.equal(clampScale(100, { fit: 0.2, picture: big }), max);
  // Never under the fit, whatever the budget says.
  assert.equal(maxScale({ width: 50000, height: 50000 }, 0.1), 0.1);
});

test("clampView: a smaller picture is centred, a larger one keeps 60 px on screen", () => {
  const picture = { width: 400, height: 300 };
  const small = clampView({ scale: 1, x: -999, y: 999 }, picture, STAGE);
  near(small.x, 300);
  near(small.y, (744 - 300) / 2);
  const big = { scale: 5, x: 0, y: 0 }; // 2000 x 1500
  assert.deepEqual(clampView({ ...big, x: 2000, y: 2000 }, picture, STAGE), { scale: 5, x: 1000 - KEEP, y: 800 - KEEP });
  assert.deepEqual(clampView({ ...big, x: -5000, y: -5000 }, picture, STAGE), { scale: 5, x: KEEP - 2000, y: KEEP - 1500 });
  assert.deepEqual(clampView({ ...big, x: -300, y: -200 }, picture, STAGE), { scale: 5, x: -300, y: -200 });
});

test("pinch: the spread scales, and the picture point under the start's midpoint follows the midpoint", () => {
  const start = { a: { x: 100, y: 100 }, b: { x: 200, y: 100 }, view: { scale: 1, x: 0, y: 0 } };
  const next = pinch(start, { x: 50, y: 120 }, { x: 250, y: 120 });
  near(next.scale, 2);
  // The point (150, 100) is now under the new midpoint (150, 120).
  near(150 - next.x, 150 * 2);
  near(120 - next.y, 100 * 2);
  // Through a limit: the scale stops, the anchor still holds.
  const held = pinch(start, { x: 0, y: 100 }, { x: 1000, y: 100 }, (s) => Math.min(s, 3));
  assert.equal(held.scale, 3);
  near(500 - held.x, 150 * 3);
});

test("wheelStep: lines are 16 px, px are px, and the zoom follows the delta", () => {
  assert.deepEqual({ ...wheelStep({ deltaMode: 1, deltaX: 0, deltaY: 3 }), zoom: 0 }, { dx: 0, dy: 48, zoom: 0 });
  const px = wheelStep({ deltaMode: 0, deltaX: 4, deltaY: -10 });
  assert.equal(px.dx, 4);
  assert.equal(px.dy, -10);
  near(px.zoom, Math.exp(0.1));
  // A small trackpad delta is a small zoom; a mouse notch's is capped.
  near(wheelStep({ deltaMode: 0, deltaY: 2 }).zoom, Math.exp(-0.02));
  near(wheelStep({ deltaMode: 0, deltaY: 100 }).zoom, Math.exp(-0.6));
  // Shift + a wheel moves sideways.
  assert.equal(wheelStep({ deltaMode: 0, deltaY: 30, shiftKey: true }).dx, 30);
});
