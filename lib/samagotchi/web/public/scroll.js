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
