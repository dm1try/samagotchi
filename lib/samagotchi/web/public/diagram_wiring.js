// The drawn diagrams' wiring, so app.js holds one line of it (its size cap):
// the block host (block_host.js) with the picture viewer as its openPicture, and
// the viewer closed on a system theme change (the diagram behind is redrawn; the
// viewer holds the old picture). docs/internals/block-renderers.md.
//
// The viewer is made by app.js, not here: createSessionView reads it at once,
// before this runs (boot order).
//
// A module of its own: static JS is cached at unversioned URLs.

import { createBlockHost } from "./block_host.js";

// @param roots the turn roots
// @param sessionId () => the open session's id
// @param drawers the core drawers (inline_widgets.js), asked before the bundles'
// @param renderers false for a page without the bundles' renderers (a participant's)
// @param pictures the picture viewer (picture_viewer.js createPictureViewer)
// @return {host} the block host
export function wireDiagrams({ roots, sessionId, drawers = [], renderers = true, pictures, win = window, ...hostOpts }) {
  const host = createBlockHost({ roots, sessionId, drawers, renderers, win, openPicture: (p, o) => pictures.open(p, o), ...hostOpts });
  win.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", () => pictures.close());
  return { host };
}
