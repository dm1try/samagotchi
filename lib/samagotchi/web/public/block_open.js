// Whether a finished turn's steps block stays open: a completed turn's closes
// to its summary line, whatever its steps said (opened, it shows the outline).
// A canceled or failed turn with an outline stays open: its last narrated step
// is the only text the reader gets. A "gone" end (the worker left) counts as
// completed: its partial answer bubble carries the text, and a reload, which
// can't tell it from one, draws the same. The live end, the stage's hand-off
// and a reload all ask here.
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.
export function openAfterEnd(kind, outlined) {
  return !!outlined && (kind === "canceled" || kind === "failed");
}
