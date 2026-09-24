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
