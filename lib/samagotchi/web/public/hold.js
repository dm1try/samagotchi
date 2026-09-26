// The answer pop (D6): the promoted answer bubble is held at the live box's
// height (`.boxed` + an inline max-height, scrolled to its tail), then grows
// to its content while the content fades in, then becomes a plain bubble.
// One hold at a time: a new hold, and reset, finish the previous one first,
// and a safety timer un-boxes its own bubble whatever happens to the rest, so
// no bubble is left clipped for good.
//
// Timers, not transitionend: under reduced motion and in a hidden tab none
// fires. No rAF either (a hidden tab has none): heights are read at once.
export const HOLD_MS = 1500;
export const REVEAL_MS = 400;
export const SAFETY_MS = HOLD_MS + REVEAL_MS + 1000;

export function createHold({ isNearBottom, follow, timers = globalThis }) {
  // { bubble, timer, follow, revealing }
  let held = null;

  function unbox(bubble) {
    bubble.classList.remove("boxed", "revealing");
    bubble.removeAttribute("style");
  }

  // Hold +bubble+ at +maxHeight+ px until reveal() or HOLD_MS.
  function start(bubble, maxHeight) {
    finish();
    bubble.classList.add("boxed");
    bubble.style.maxHeight = `${maxHeight}px`;
    bubble.scrollTop = bubble.scrollHeight;
    held = {
      bubble,
      timer: timers.setTimeout(reveal, HOLD_MS),
      follow: false,
    };
    timers.setTimeout(() => {
      if (held?.bubble === bubble) finish();
      else unbox(bubble);
    }, SAFETY_MS);
  }

  // The pop: the held bubble grows to its content under the CSS transition;
  // the class and the inline style go REVEAL_MS later (reload parity).
  function reveal() {
    if (!held || held.revealing) return;
    timers.clearTimeout(held.timer);
    const { bubble } = held;
    held.revealing = true;
    held.follow = isNearBottom();
    bubble.scrollTop = 0;
    bubble.style.maxHeight = `${bubble.scrollHeight}px`;
    bubble.classList.add("revealing");
    held.timer = timers.setTimeout(finish, REVEAL_MS);
  }

  // The held bubble as a plain answer bubble, at once.
  function finish() {
    if (!held) return;
    // The safety timer stays: it un-boxes its bubble again, a no-op on a
    // plain one.
    timers.clearTimeout(held.timer);
    const { bubble, follow: wasFollowing } = held;
    held = null;
    unbox(bubble);
    if (wasFollowing) follow();
  }

  return { start, reveal, finish, get bubble() { return held?.bubble ?? null; } };
}
