// The page's one list of pages (GET /api/pages, docs/pages.md): what the
// pages' ways in read (the top bar's pages pill and the Pages list,
// pages_wiring.js). DOM-free. +load()+ reads the list, or returns the read
// already out (one request at boot however many views ask); +reload()+
// always asks again (something changed: the hub's `pages` event, a
// reconnect, a Delete), and an answer older than the newest ask is dropped
// (createLatest). A failed read keeps the last list and +loaded+ as they
// were (chi web restarting doesn't hide the pill); +failed+ says the last
// read failed. Subscribers are called with the state after every answer.
//
// +api+: data.js api.
import { createLatest } from "./latest.js";

export function createPagesModel({ api }) {
  let state = { pages: [], loaded: false, failed: false };
  let inFlight = null;
  const subscribers = new Set();
  const latest = createLatest();

  function publish(fields) {
    state = { ...state, ...fields };
    for (const fn of [...subscribers]) fn(state);
  }

  function reload() {
    const fresh = latest.begin();
    const ask = (async () => {
      await null; // inFlight is set before the read starts, even when api throws at once
      try {
        const answer = await api("/api/pages");
        if (!fresh()) return;
        publish({ pages: Array.isArray(answer?.pages) ? answer.pages : [], loaded: true, failed: false });
      } catch (_) {
        if (!fresh()) return;
        publish({ failed: true });
      } finally {
        if (fresh()) inFlight = null;
      }
    })();
    inFlight = ask;
    return ask;
  }

  function load() {
    return inFlight || reload();
  }

  function subscribe(fn) {
    subscribers.add(fn);
    return () => subscribers.delete(fn);
  }

  return { load, reload, subscribe, state: () => state };
}
