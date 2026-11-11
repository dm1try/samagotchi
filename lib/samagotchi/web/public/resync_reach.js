// A re-read of the open session (app.js resync) that could not reach chi web:
// the one rule for what the page does then. The history already drawn for
// this session stays as it is (the conversation is still right, only newer
// events are missing) and the info bar's status chip says the page is
// retrying, then, once the retries ran out, that it is offline (the full
// words in its tooltip); while a turn runs the stage's own line says
// "reconnecting…" instead (stage_stall.js) and the chip keeps the turn's word;
// the next re-read that succeeds clears it (the hub's next event re-reads a
// session left in that state: needsReread). Only a first load (select()'s
// "Loading…", nothing of the session drawn yet) shows the error in the
// history, as there is nothing to keep.
// Its own module: new exports go in new modules (web-frontend.md).

// The status chip's word (its class), text and tooltip per state. The texts
// fit the room the chip keeps for its widest word (running, stopped), so the
// bar doesn't move while one shows.
export const REACH = Object.freeze({
  reconnecting: Object.freeze({
    status: "reconnecting", text: "retrying",
    tip: "Reconnecting: can't reach chi web, trying again. The conversation shown is as it was; newer events show once it's back.",
  }),
  offline: Object.freeze({
    status: "offline", text: "offline",
    tip: "Can't reach chi web. The conversation shown is as it was; the page reads it again once chi web is back.",
  }),
});

// What a failed re-read does. +drawn+: the history shows this session's
// conversation; +retrying+: another try is scheduled.
// @return {{hint: boolean, reach: "reconnecting"|"offline"|null}}
//   hint: replace the history with the error; reach: the store's field.
export function readFailed({ drawn, retrying }) {
  if (!drawn) return { hint: true, reach: null };
  return { hint: false, reach: retrying ? "reconnecting" : "offline" };
}

// The page side. +store+: the session store (its current.reach); +historyEl+,
// +errorHint+(message): the node a first load's failure shows.
export function createResyncReach({ store, historyEl, errorHint }) {
  // The session whose conversation the history shows (null: a "Loading…"
  // or error hint, the start page).
  let drawnId = null;
  return {
    // select() put its "Loading…" hint in.
    loading() {
      drawnId = null;
    },
    // A re-read of +id+ drew it: the indicator goes.
    drawn(id) {
      drawnId = id;
      if (store.current.reach) store.update({ current: { reach: null } });
    },
    // A re-read of +id+ (the open session) failed with +message+.
    failed(id, message, { retrying }) {
      const { hint, reach } = readFailed({ drawn: drawnId === id, retrying });
      if (hint) historyEl.replaceChildren(errorHint(message));
      if (reach !== store.current.reach) store.update({ current: { reach } });
    },
    // The session still shows a failed re-read: any sign of chi web (a hub
    // event) is worth a re-read, not only a worker's bridge_up.
    needsReread: () => !!store.current.reach,
  };
}
