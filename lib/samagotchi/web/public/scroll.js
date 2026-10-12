// Pure sticky-follow predicate for the conversation viewport.
// A user "follows" the live stream only while the visible gap between the
// bottom of the viewport and the bottom of the content is within the
// threshold. Once they scroll up to read, the gap grows past the threshold
// and the app must stop auto-scrolling (no yank-back on each stream frame).
export const SCROLL_FOLLOW_PX = 64;

export function shouldFollowScroll(
  { scrollHeight, scrollTop, clientHeight },
  thresholdPx = SCROLL_FOLLOW_PX,
) {
  return scrollHeight - scrollTop - clientHeight <= thresholdPx;
}

// Run a DOM change that grows the content and keep a pinned view pinned:
// the follow decision is taken before the change, as the gap measured after
// several rows land at once (a turn's start adds the answer bubble and the
// live timing row) is already past the threshold.
export function keepFollowing(el, mutate, thresholdPx = SCROLL_FOLLOW_PX) {
  const follow = shouldFollowScroll(el, thresholdPx);
  const result = mutate();
  if (follow) el.scrollTop = el.scrollHeight;
  return result;
}

// A follow that eases instead of jumping: +el+'s scrollTop goes to +top+
// over +ms+ (ease-out), +el+ marked data-following meanwhile (a layout
// watcher reads that as a follow, not a jump). +top+ may be a function,
// read each frame (a target that moves on: the history's end while its
// bottom reserve eases). With +reduce+ (prefers-reduced-motion) it jumps.
// A newer call on the same element takes over. Resolves when it is there.
export const FOLLOW_MS = 180;
const easing = new WeakMap();
export function easeScrollTo(el, top, { ms = FOLLOW_MS, reduce = false, raf = (fn) => requestAnimationFrame(fn), now = () => performance.now() } = {}) {
  const target = () => (typeof top === "function" ? top() : top);
  easing.get(el)?.stop();
  if (reduce || ms <= 0) {
    el.scrollTop = target();
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    const from = el.scrollTop;
    const start = now();
    let done = false;
    const run = { stop: () => finish() };
    function finish() {
      if (done) return;
      done = true;
      if (easing.get(el) === run) {
        easing.delete(el);
        delete el.dataset.following;
      }
      resolve();
    }
    easing.set(el, run);
    el.dataset.following = "";
    const step = () => {
      if (done) return;
      const t = Math.min(1, (now() - start) / ms);
      el.scrollTop = from + (target() - from) * (1 - (1 - t) ** 3);
      if (t < 1) raf(step);
      else finish();
    };
    raf(step);
  });
}
