import test from "node:test";
import assert from "node:assert/strict";
import { shouldFollowScroll, keepFollowing, SCROLL_FOLLOW_PX } from "../../../lib/samagotchi/web/public/scroll.js";

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
