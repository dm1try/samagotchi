// Collapsibles keep their shape: a steps block, a thinking block, the recap
// and the answer fold are the same box open or closed (the bar, the border,
// the width), and a click only changes the height. This module is the
// motion: a click on one of their summaries animates the height between the
// two states (Web Animations, MOTION_MS) instead of snapping, and the
// answer fold borrows animateHeight for its bubble. Nothing moves when the
// viewer prefers reduced motion or the element cannot animate (an old
// engine, a spec's DOM): the click is the native toggle then.
//
// Only a hand's click animates: the page's own opens and closes (a turn's
// end closing a block, a reload drawing the outline) stay instant, as they
// are not a change the viewer watches.
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.

export const MOTION_MS = 220;

// Whether +el+ can animate for this viewer.
export function canAnimate(el) {
  if (typeof el?.animate !== "function") return false;
  const win = el.ownerDocument?.defaultView;
  return !win?.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches;
}

// Animates +el+'s height from +from+ to +to+ (px), its overflow clipped
// meanwhile; +fade+ fades it with the height. Resolves when the animation
// is over (or canceled).
export async function animateHeight(el, from, to, { fade = false, ms = MOTION_MS } = {}) {
  const at = (h, o) => (fade ? { height: `${h}px`, opacity: String(o) } : { height: `${h}px` });
  const anim = el.animate([at(from, from ? 1 : 0), at(to, to ? 1 : 0)], { duration: ms, easing: "ease" });
  el.style.overflow = "hidden";
  try {
    await anim.finished;
  } catch {
    // canceled: the element is where its class puts it
  } finally {
    el.style.overflow = "";
  }
}

// A <details>' height closed: its summary and its own padding and borders.
function closedHeight(details, summary) {
  const win = details.ownerDocument?.defaultView;
  const cs = win?.getComputedStyle?.(details);
  const px = (v) => Number.parseFloat(v) || 0;
  const frame = cs ? px(cs.paddingTop) + px(cs.paddingBottom) + px(cs.borderTopWidth) + px(cs.borderBottomWidth) : 0;
  return summary.offsetHeight + frame;
}

// Installs the motion on +root+ for the <details> matching +selector+ whose
// own summary is clicked. +motion+: whether to animate +el+ (canAnimate).
export function installDetailsMotion({ root, selector, motion = canAnimate }) {
  const busy = new WeakSet();
  root.addEventListener("click", (e) => {
    const summary = e.target.closest?.("summary");
    const details = summary?.parentElement;
    if (!details || !details.matches?.(selector) || summary.parentElement !== details) return;
    if (e.target.closest("a, button, input, label") !== null && e.target !== summary) return;
    if (!motion(details)) return;
    e.preventDefault();
    if (busy.has(details)) return;
    busy.add(details);
    const done = () => busy.delete(details);
    if (details.open) {
      const from = details.offsetHeight;
      animateHeight(details, from, closedHeight(details, summary)).then(() => { details.open = false; done(); });
    } else {
      const from = closedHeight(details, summary);
      details.open = true;
      animateHeight(details, from, details.offsetHeight).then(done);
    }
  });
}
