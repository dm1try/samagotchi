import test from "node:test";
import assert from "node:assert/strict";
import { createHold, HOLD_MS, REVEAL_MS, SAFETY_MS } from "../../../lib/samagotchi/web/public/hold.js";

// A bubble with just what the hold touches.
function fakeBubble(scrollHeight = 500) {
  const classes = new Set(["bubble", "output"]);
  return {
    scrollHeight,
    scrollTop: 0,
    style: {},
    classList: { add: (...c) => c.forEach((x) => classes.add(x)), remove: (...c) => c.forEach((x) => classes.delete(x)), contains: (c) => classes.has(c) },
    removeAttribute(name) { if (name === "style") this.style = {}; },
    get held() { return classes.has("boxed") || !!this.style.maxHeight; },
  };
}

function setup(t, { nearBottom = true } = {}) {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const follows = [];
  const hold = createHold({ isNearBottom: () => nearBottom, follow: () => follows.push(1), timers: globalThis });
  return { hold, follows };
}

test("a hold boxes the bubble at the given height, scrolled to its tail", (t) => {
  const { hold } = setup(t);
  const b = fakeBubble(500);
  hold.start(b, 96);
  assert.equal(b.classList.contains("boxed"), true);
  assert.equal(b.style.maxHeight, "96px");
  assert.equal(b.scrollTop, 500);
  assert.equal(hold.bubble, b);
});

test("reveal grows it to its content, and it is a plain bubble REVEAL_MS later, followed when at the bottom", (t) => {
  const { hold, follows } = setup(t);
  const b = fakeBubble(500);
  hold.start(b, 96);
  hold.reveal();
  assert.equal(b.style.maxHeight, "500px");
  assert.equal(b.classList.contains("revealing"), true);
  t.mock.timers.tick(REVEAL_MS);
  assert.equal(b.held, false);
  assert.equal(b.classList.contains("revealing"), false);
  assert.equal(follows.length, 1);
  assert.equal(hold.bubble, null);
});

test("with no reveal, the hold pops by itself after HOLD_MS", (t) => {
  const { hold } = setup(t);
  const b = fakeBubble();
  hold.start(b, 96);
  t.mock.timers.tick(HOLD_MS);
  t.mock.timers.tick(REVEAL_MS);
  assert.equal(b.held, false);
});

test("two turn ends within 1.5 s: the first bubble is un-boxed when the second is held, and both end plain", (t) => {
  const { hold } = setup(t);
  const first = fakeBubble();
  const second = fakeBubble();
  hold.start(first, 96);
  t.mock.timers.tick(700);
  hold.start(second, 120);
  assert.equal(first.held, false, "the first hold is finished, not leaked");
  assert.equal(second.style.maxHeight, "120px");
  // The first turn's late answerReady reveals the current hold only.
  hold.reveal();
  t.mock.timers.tick(REVEAL_MS);
  assert.equal(second.held, false);
  t.mock.timers.tick(SAFETY_MS);
  assert.equal(first.held, false);
});

test("the safety timer un-boxes a bubble even if something re-boxes it after the hold moved on", (t) => {
  const { hold } = setup(t);
  const first = fakeBubble();
  hold.start(first, 96);
  // A leak of the old kind: the bubble is boxed again behind the hold's back.
  const second = fakeBubble();
  hold.start(second, 96);
  first.classList.add("boxed");
  first.style.maxHeight = "96px";
  t.mock.timers.tick(SAFETY_MS);
  assert.equal(first.held, false);
  assert.equal(second.held, false);
});

test("finish is idempotent, and reveal with nothing held is a no-op", (t) => {
  const { hold, follows } = setup(t);
  hold.reveal();
  hold.finish();
  const b = fakeBubble();
  hold.start(b, 96);
  hold.finish();
  hold.finish();
  assert.equal(b.held, false);
  assert.equal(follows.length, 0, "not revealed, so no follow decision was taken");
});

test("a second reveal does not push the end back", (t) => {
  const { hold } = setup(t);
  const b = fakeBubble();
  hold.start(b, 96);
  hold.reveal();
  t.mock.timers.tick(REVEAL_MS - 50);
  hold.reveal();
  t.mock.timers.tick(50);
  assert.equal(b.held, false);
});

test("following, the pop keeps the history pinned every frame until it ends", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const frames = [];
  const timers = { setTimeout, clearTimeout, requestAnimationFrame: (f) => frames.push(f) };
  const follows = [];
  const hold = createHold({ isNearBottom: () => true, follow: () => follows.push(1), timers });
  const b = fakeBubble();
  hold.start(b, 96);
  hold.reveal();
  frames.shift()();
  frames.shift()();
  assert.equal(follows.length, 2);
  t.mock.timers.tick(REVEAL_MS);
  assert.equal(follows.length, 3, "finish follows once more");
  frames.shift()();
  assert.equal(follows.length, 3, "no pinning after the pop");
  assert.equal(frames.length, 0);
});

test("scrolled up to read, the pop pins nothing", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const frames = [];
  const timers = { setTimeout, clearTimeout, requestAnimationFrame: (f) => frames.push(f) };
  const hold = createHold({ isNearBottom: () => false, follow: () => assert.fail("followed"), timers });
  hold.start(fakeBubble(), 96);
  hold.reveal();
  t.mock.timers.tick(REVEAL_MS);
  assert.equal(frames.length, 0);
});
