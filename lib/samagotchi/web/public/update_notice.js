// An open tab keeps its JS across a `chi web` restart (its event streams
// just reconnect), so after an upgrade old page code talks to a new server.
// The page knows the version that served it (body data-version); each
// GET /api/events snapshot names the one serving now.

// The toast's text when the chi web serving now is another version than
// the one that served this page, else null: also when either side doesn't
// say (an older chi web, a page from before data-version), and when the
// toast was already shown for this version (+shown+: the reconnects'
// snapshots carry it again).
export function updateNotice(loaded, served, shown = null) {
  const known = (v) => typeof v === "string" && v !== "";
  if (!known(loaded) || !known(served) || loaded === served || served === shown) return null;
  return `chi was updated to ${served}`;
}
