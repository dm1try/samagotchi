// The open session's peers as the page knows them: GET …/peers (owner only,
// read from the session's files: its peer sources and the exchange log), and
// one small model of it that the conversation (peer_links.js) and, later,
// the peer chips share. docs/internals/web-frontend.md, The peer exchange.
// Its own module: new exports go in new modules (web-frontend.md).

import { api } from "./data.js";
import { createLatest } from "./latest.js";

// GET /api/sessions/:id/peers → {peers: [{name, label, inbox, outbox,
// exchanges: [newest first]}]}. An older chi web has no route: its 404 is
// an empty list here, on its own (any other failure throws).
export async function listPeers(id, opts = {}) {
  try {
    return await api(`/api/sessions/${encodeURIComponent(id)}/peers`, opts);
  } catch (error) {
    if (error?.status === 404) return { peers: [] };
    throw error;
  }
}

// How often a waiting exchange is read again (its age moves on).
export const WAITING_TICK_MS = 60_000;

// How many exchanges GET …/peers gives a peer at most (PeerExchanges.joined
// last: 20): a full list may leave older sends out.
export const EXCHANGES_CAP = 20;

// The model. +sessionId+() the open session; +hasPeer+() whether it has a
// peer at all (a context row with `peer`, a drawn send or answer): without
// one, refresh asks nothing. +onChange+() after each read for the open
// session (also a failed one: what is drawn may follow it). +list+: the
// fetch (listPeers). +win+: focus and the waiting tick.
//
// @return {refresh(), exchange(id), answer(name, serial, re), peer(name), touch(), loaded(), clear(), peers()}
export function createPeers({ sessionId, hasPeer = () => false, onChange = () => {}, list = listPeers,
                              win = globalThis, tickMs = WAITING_TICK_MS } = {}) {
  // The last read: {id: the session it is for, peers}.
  let data = null;
  let inFlight = null;
  let tick = null;
  // Only the newest read for the open session is kept (latest.js).
  const latest = createLatest(() => sessionId());

  const current = () => (data && data.id === sessionId() ? data.peers : []);

  function stopTick() {
    if (tick !== null) win.clearInterval?.(tick);
    tick = null;
  }

  // One interval while an exchange waits, none otherwise.
  function syncTick() {
    const waiting = current().some((peer) => (peer.exchanges || []).some((ex) => ex?.state === "waiting"));
    if (!waiting) stopTick();
    else if (tick === null && win.setInterval) tick = win.setInterval(() => refresh(), tickMs);
  }

  function refresh({ reuse = false } = {}) {
    const id = sessionId();
    if (!id || !hasPeer()) return Promise.resolve(false);
    if (reuse && inFlight?.id === id) return inFlight.promise;
    if (reuse && data?.id === id) return Promise.resolve(true);
    const fresh = latest.begin();
    const request = (async () => {
      try {
        const answer = await list(id);
        if (!fresh()) return false;
        data = { id, peers: Array.isArray(answer?.peers) ? answer.peers : [] };
      } catch {
        // Unreachable for now: what was read stays.
        if (!fresh()) return false;
      }
      syncTick();
      onChange();
      return true;
    })();
    const flight = { id, promise: request };
    inFlight = flight;
    const clearFlight = () => { if (inFlight === flight) inFlight = null; };
    request.then(clearFlight, clearFlight);
    return request;
  }

  // The newest exchange of send +id+, with its peer's name; null when
  // none is read. Each send has its own id now; an older chi's resend
  // shared one, and the newest of them wins.
  function exchange(id) {
    if (!id) return null;
    let found = null;
    for (const peer of current()) {
      for (const ex of peer.exchanges || []) {
        if (ex?.id === id && (!found || Date.parse(ex.at || "") > Date.parse(found.at || ""))) found = { ...ex, peer: peer.name };
      }
    }
    return found;
  }

  // The send answer +serial+ of peer +name+ answers: the exchange its
  // serial (its outbox revision's, the note's) is in, when that one is a
  // send's; else the send +re+ names (a second answer to one send is an
  // unclaimed row of its own on the server); null for an answer no send
  // claims.
  function answer(name, serial, re = null) {
    const peer = current().find((p) => p.name === name);
    if (!peer) return null;
    const exchanges = peer.exchanges || [];
    const bySerial = serial !== null && serial !== undefined && serial !== ""
      ? exchanges.find((ex) => ex?.answer && String(ex.answer.serial) === String(serial)) : null;
    const ex = bySerial?.id ? bySerial : (re ? exchanges.find((e) => e?.id === re) : null);
    return ex ? { ...ex, peer: peer.name } : null;
  }

  function clear() {
    latest.drop();
    data = null;
    inFlight = null;
    stopTick();
  }

  win.addEventListener?.("focus", () => refresh());

  return {
    refresh, exchange, answer, clear, peers: current,
    loaded: () => !!data && data.id === sessionId(),
    // Peer +name+ as the last read gives it, or null (not paired, detached).
    peer: (name) => current().find((p) => p.name === name) || null,
    // What is drawn follows the read again without a fetch (a turn ended).
    touch: () => { if (data && data.id === sessionId()) onChange(); },
  };
}
