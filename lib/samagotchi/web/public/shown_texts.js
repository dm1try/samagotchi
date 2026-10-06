// The texts the running turn already shows (its generations as they close,
// the bubbles a render drew): turn_completed's answer gets a bubble of its
// own only when it isn't one of them (it wasn't streamed). A new turn starts
// over, so an earlier turn's "Done." doesn't hide this one's.
export function createShownTexts() {
  let seen = new Set();
  return {
    turnStarted() { seen = new Set(); },
    seed(texts) { seen = new Set(texts.filter(Boolean)); },
    saw(text) { if (text) seen.add(text); },
    shows(text) { return seen.has(text); },
  };
}
