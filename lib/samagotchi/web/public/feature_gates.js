// The open session's feature gates: a page action that its worker must
// support (its sidecar features, a live bridge), and the redraw that
// follows when that flips. Registered with the session store as its
// `featureGates` redraw (session_store.js ORDER): it runs whenever a field
// it reads changes, and a gate's own redraw only when its answer flipped.
//
// A session switch (forgetSession) and a full load (renderSessionView) draw
// every card with the gate's answer already: they prime() the gates, so the
// redraw that follows their write sees no flip. A write anywhere else (a
// restart's hub event bringing the feature, the worker going) fires it.
//
// A new module: the page's modules are cached at unversioned URLs, and a
// new export of an old module would leave a cached copy without it.

// @param entries [{name, unavailable(current) → bool, redraw()}]
// @return {prime(current), check(current)}: prime takes each gate's answer
//   without redrawing; check redraws the gates whose answer flipped since
export function createFeatureGates(entries) {
  const last = new Map();
  return {
    prime(current) {
      for (const gate of entries) last.set(gate.name, !!gate.unavailable(current));
    },
    check(current) {
      for (const gate of entries) {
        const now = !!gate.unavailable(current);
        const flipped = last.has(gate.name) && last.get(gate.name) !== now;
        last.set(gate.name, now);
        if (flipped) gate.redraw();
      }
    },
  };
}
