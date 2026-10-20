// Where the toast sits (dock_reserve.js placeToast measures, this decides): in a
// session, +gap+ above the highest of the composer card and what opens
// over it (the stage while it shows, a fresh link's open model panel), so
// it covers none of them; null elsewhere (the CSS's 24 px from the bottom).
// When that leaves the toast no room on screen it stays +gap+ from the top
// (covering what's under it rather than going off screen).
// @param tops the tops (px from the viewport's top) of what shows over the
//   card; null for one that doesn't
// @return {number|null} the toast's bottom offset in px
export function toastBottom({ inSession, viewportHeight, dockTop, tops = [], toastHeight = 0, gap = 12 }) {
  if (!inSession) return null;
  const top = Math.min(dockTop, ...tops.filter((t) => Number.isFinite(t)));
  const bottom = viewportHeight - top + gap;
  const cap = viewportHeight - toastHeight - gap;
  return Math.round(Math.max(0, Math.min(bottom, cap)));
}
