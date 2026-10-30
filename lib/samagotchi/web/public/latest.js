// Stale-answer guards: an answer that comes back after an await is applied
// only while what it was asked for is still what the page shows. The page
// switches sessions, reopens a popover or asks again while a fetch is out;
// an answer for the old ask must be dropped, not drawn over the new one.
//
// Two shapes (docs/internals/web-frontend.md, "Stale answers"):
// - stillOn(get): the thing asked about (the open session's id) hasn't
//   changed. For a one-off read: the same session may ask twice and both
//   answers are good.
// - createLatest(get): also only the newest ask counts. For a list that is
//   re-read (a refresh while a refresh is out): an older answer landing
//   last would draw the older list.
//
//   const latest = createLatest(() => sessionId);
//   async function refresh() {
//     const fresh = latest.begin();
//     const data = await api.list(sessionId);
//     if (!fresh()) return;
//     …
//   }

// @param get () => the key the answer is for (the open session's id)
// @param at the key asked for (default: get() now)
// @return () => true while get() is still +at+
export function stillOn(get, at = get()) {
  return () => get() === at;
}

// @param get () => the key the asks are for (default: none, the newest ask
//   alone decides)
// @return {begin(), drop()}: begin() starts an ask and gives its guard,
//   () => true while it is the newest ask and get() is unchanged; drop()
//   makes every ask out stale (a reset)
export function createLatest(get = () => null) {
  let seq = 0;
  return {
    begin() {
      const mine = ++seq;
      const same = stillOn(get);
      return () => mine === seq && same();
    },
    drop() {
      seq += 1;
    },
  };
}
