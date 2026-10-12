import test from "node:test";
import assert from "node:assert/strict";
import { easeScrollTo, shouldFollowScroll, keepFollowing, SCROLL_FOLLOW_PX } from "../../../lib/samagotchi/web/public/scroll.js";

test("follows when pinned to the bottom (gap 0)", () => {
  assert.equal(shouldFollowScroll({ scrollHeight: 1000, scrollTop: 800, clientHeight: 200 }), true);
});

test("follows when within the default threshold", () => {
  assert.equal(shouldFollowScroll({ scrollHeight: 1000, scrollTop: 737, clientHeight: 200 }), true);
  assert.equal(
    shouldFollowScroll({ scrollHeight: 1000, scrollTop: 1000 - SCROLL_FOLLOW_PX - 200, clientHeight: 200 }),
    true,
  );
});

test("stops following just past the default threshold", () => {
  assert.equal(shouldFollowScroll({ scrollHeight: 1000, scrollTop: 735, clientHeight: 200 }), false);
});

test("content shorter than the viewport counts as following", () => {
  // Nothing to scroll: the new bubble should be visible.
  assert.equal(shouldFollowScroll({ scrollHeight: 150, scrollTop: 0, clientHeight: 200 }), true);
});

test("custom threshold is respected", () => {
  const m = { scrollHeight: 1000, scrollTop: 750, clientHeight: 200 }; // gap 50
  assert.equal(shouldFollowScroll(m, 50), true);
  assert.equal(shouldFollowScroll(m, 49), false);
});

// A fake scroller whose content grows when mutated.
function scroller({ scrollHeight, scrollTop, clientHeight }) {
  return { scrollHeight, scrollTop, clientHeight };
}

test("keepFollowing: a pinned view stays pinned after several rows are added", () => {
  const el = scroller({ scrollHeight: 1000, scrollTop: 800, clientHeight: 200 });
  keepFollowing(el, () => { el.scrollHeight += 146; }); // bubble + live timing row
  assert.equal(el.scrollTop, el.scrollHeight);
});

test("keepFollowing: a user who scrolled up keeps their position", () => {
  const el = scroller({ scrollHeight: 1000, scrollTop: 300, clientHeight: 200 });
  keepFollowing(el, () => { el.scrollHeight += 146; });
  assert.equal(el.scrollTop, 300);
});

test("keepFollowing returns what the mutation returns", () => {
  const el = scroller({ scrollHeight: 100, scrollTop: 0, clientHeight: 200 });
  assert.equal(keepFollowing(el, () => 42), 42);
});

test("easeScrollTo: eases to the target, marked data-following until it is there", async () => {
  const el = { scrollTop: 0, dataset: {} };
  let clock = 0;
  const frames = [];
  const raf = (fn) => frames.push(fn);
  const done = easeScrollTo(el, 100, { ms: 100, raf, now: () => clock });
  assert.equal(el.dataset.following, "");
  clock = 50;
  frames.shift()();
  assert.ok(el.scrollTop > 50 && el.scrollTop < 100, `eased: ${el.scrollTop}`);
  clock = 100;
  frames.shift()();
  await done;
  assert.equal(el.scrollTop, 100);
  assert.equal(el.dataset.following, undefined);
});

test("easeScrollTo: a moving target is read each frame; reduce jumps; a newer call takes over", async () => {
  const el = { scrollTop: 0, dataset: {} };
  let clock = 0;
  let end = 100;
  const frames = [];
  const raf = (fn) => frames.push(fn);
  const first = easeScrollTo(el, () => end, { ms: 100, raf, now: () => clock });
  end = 200;
  clock = 100;
  frames.shift()();
  await first;
  assert.equal(el.scrollTop, 200);
  await easeScrollTo(el, 40, { reduce: true });
  assert.equal(el.scrollTop, 40);
  const older = easeScrollTo(el, 300, { ms: 100, raf, now: () => clock });
  const newer = easeScrollTo(el, 0, { ms: 100, raf, now: () => clock });
  await older;
  assert.equal(el.dataset.following, "");
  clock = 300;
  while (frames.length) frames.shift()();
  await newer;
  assert.equal(el.scrollTop, 0);
  assert.equal(el.dataset.following, undefined);
});
