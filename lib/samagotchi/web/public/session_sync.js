// The open session's sync with the server (split out of app.js): select()
// opens a session, resync() (re)renders it from GET /api/sessions/:id and
// streams on from the cursor that render covers, and the stream's life
// (startStream, workerGone, closeStream, restart). The stream handle and the
// re-read bookkeeping (resyncsInFlight, resyncAgain, resyncAttempts, the
// resync_reach.js instance) live here and nowhere else: the page reads them
// through hasStream() and streamLive().
//
// Everything that changes while the page runs is read through deps at the
// call, never captured at creation (as stream_handlers.js): the open session
// (store.selected), its fields (store.current), the views made after this
// one (the getters in +later+), the session view's hooks (+view+).
//
// deps:
//   store                 the page's session store (session_store.js)
//   historyEl, emptyEl    the history and the start page's empty box
//   getSession(id, opts), openStream(id, fromSeq, handlers, opts)  data.js
//   liveTurn, turnDom, questionCards, contextChips, participantsControl  the page's views
//   view: {forgetSession(opts), renderSessionView(data, opts), endTurnView(kind, endText, opts)}
//                         the session view (session_view.js)
//   page: {clearNotice(), setSessionHash(id), setTurnRunning(running), setLiveStatus(status),
//          replaceCard(id, change), addEndBubble(text)}  the page's hooks
//   later: {handlers(), composer(), focusPrompt(opts), sessionActions(), ownerClaim()}
//                         the views made after this one: the stream handlers,
//                         the composer, session_actions.js, owner_claim.js
//
// @return {select, resync, followSelectedSession, followWokenWorker, workerGone, resetTurnView, closeStream,
//          restart, closeLive, hasStream, streamLive, startStream, retryResync}
//   hasStream(): a stream object exists (the info bar's streaming, also while it connects);
//   streamLive(): it delivers (its .live); restart(): close it and resync;
//   closeLive(): close it, keeping the handle (workerGone clears it, through onStreamClosed).
// Its own module: new exports go in new modules (web-frontend.md).

import { fieldsFromCard } from "./session_fields.js";
import { hintEl } from "./bubbles.js";
import { withoutWorker } from "./format.js";
import { resyncRetry, streamDropEnd } from "./turn_events.js";
import { createResyncReach } from "./resync_reach.js";
import { keptCommandBubbles } from "./commands.js";

// +opened+ false: the stream never delivered a frame (the proxy answered
// 503, or the bridge refused it), so a retry waits a moment rather than
// spinning through resync → stream → error.
export const STREAM_RETRY_MS = 3000;
// A re-read that failed (the phone still offline, chi web a moment): try it
// again, backing off, and stop when the tries run out. The running turn's DOM
// is left alone meanwhile: a worker that still owns the turn keeps showing it running,
// and the hub's next event for the session is the fallback once the tries end.
export const RESYNC_RETRIES = 3;

export function createSessionSync(deps) {
  const {
    store, historyEl, emptyEl, getSession, openStream,
    liveTurn, turnDom, questionCards, contextChips, participantsControl,
    page, later,
  } = deps;
  let streamControl = null;
  // resync() calls in flight, and whether a worker came up for the selected
  // session while one ran (its bridge_up event): the tail runs once more.
  let resyncsInFlight = 0;
  let resyncAgain = false;
  // A failed re-read keeps the drawn history and says so in the bar (resync_reach.js).
  const resyncReach = createResyncReach({ store, historyEl, errorHint: (message) => hintEl(`Error: ${message}`) });
  let resyncAttempts = 0;

  // The selected session's card changed: its owner and, without a live
  // stream, its status show in the info bar; a worker whose bridge is up
  // (a turn another client sent woke one, or a replacement after a kill)
  // gets the stream attached through one resync.
  function followSelectedSession(sess) {
    const streaming = !!(streamControl && streamControl.live);
    // A Verify gate that flips (a restart brought the feature) redraws the
    // cards' Verify fresh part: featureGates.
    store.batch(() => {
      store.update({ current: fieldsFromCard(sess) });
      store.setStatus(sess.status, "hub", { streaming });
    });
    if (streaming || !(sess.bridge_up || resyncReach.needsReread())) return;
    if (resyncsInFlight > 0) resyncAgain = true;
    else resync();
  }

  async function select(id) {
    page.clearNotice();
    const same = store.selected === id;
    // Its synchronous part in one batch: the active card, the composer and
    // the bar redraw once, at its end (never across the await).
    store.batch(() => {
      store.update({ selected: id });
      page.setSessionHash(id);
      historyEl.replaceChildren(hintEl("Loading…"));
      resyncReach.loading();
      emptyEl.classList.add("hidden");
      resyncAttempts = 0; // this session has its own re-read budget
      deps.view.forgetSession({ keepVerify: same });
      contextChips.load(id);
      participantsControl.load(id);
    });
    await resync();
    // A folded composer stays folded: typing on the page opens it.
    later.focusPrompt({ open: false });
  }

  // Clear everything that belongs to one turn's rendering.
  function resetTurnView() {
    closeStream();
    // workerGone and a re-render come through here: the answer_display wait
    // goes too.
    liveTurn.forget();
    questionCards.removeQuestion();
    questionCards.forgetContinue();
    page.setTurnRunning(false);
  }

  // @return whether another try is scheduled
  function retryResync(id, { endText = null } = {}) {
    if (id !== store.selected) return false;
    const { attempt, delayMs } = resyncRetry({ attempts: resyncAttempts, max: RESYNC_RETRIES, baseMs: STREAM_RETRY_MS });
    if (delayMs === null) return false;
    resyncAttempts = attempt;
    setTimeout(() => {
      if (id !== store.selected || (streamControl && streamControl.live)) return;
      resync({ endText });
    }, delayMs);
    return true;
  }

  // (Re)render the selected session from the server and stream on from the
  // event_seq that render covers. Used on select, when the stream resets
  // (its cursor could not be replayed) and when it dropped (workerGone).
  // Without a live bridge there is nothing to stream: the session's next
  // event with bridge_up (a worker another client woke) resyncs again
  // (followSelectedSession); a bridge_up that arrived while this ran is
  // taken by the tail. +endText+: what workerGone said about the turn the
  // worker left unfinished; shown again after the re-render when no worker
  // took over.
  async function resync({ endText = null } = {}) {
    const id = store.selected;
    if (!id) return;
    resyncsInFlight += 1;
    let data;
    try {
      try {
        data = await getSession(id);
      } catch (e) {
        if (e.status === 404) return later.sessionActions().leaveGoneSession(id, "not_found");
        if (id === store.selected) resyncReach.failed(id, e.message, { retrying: retryResync(id, { endText }) });
        return;
      }
      resyncAttempts = 0;
      if (id !== store.selected) return;
      // An archived session opens folded: decided once per visit, from its
      // first answer (the list may not hold it yet, or ever under ?dir).
      later.composer().decideVisit(data.session?.archived);
      const kept = keptCommandBubbles(historyEl, id);
      resetTurnView();
      deps.view.renderSessionView(data, { kept });
      resyncReach.drawn(id);
      later.ownerClaim().showPending();
      // Preview is read-only: a worker is woken only by POST /turn, so attach
      // only when a live bridge exists.
      store.update({ current: { streamSeq: typeof data.last_event_seq === "number" ? (data.last_event_id || data.last_event_seq) : null } });
      if (store.current.streamSeq !== null) startStream(id, store.current.streamSeq);
      else if (endText) page.addEndBubble(endText);
    } finally {
      resyncsInFlight -= 1;
      if (resyncsInFlight === 0 && resyncAgain) {
        resyncAgain = false;
        if (id === store.selected && !(streamControl && streamControl.live)) resync();
      }
    }
  }

  // A turn or command just woke the session's worker: follow its stream if
  // none is open, from the render's cursor. A render with none (no worker
  // then) streams from 0, the start of a new worker's events; should that
  // worker have been up already, turn_started says so (replaysDrawnTurn).
  function followWokenWorker() {
    if (streamControl?.live) return;
    startStream(store.selected, store.current.streamSeq ?? 0);
    store.update({ current: { streamFromGuess: store.current.streamSeq === null } });
  }

  function startStream(id, fromSeq) {
    store.update({ current: { streamFromGuess: false } });
    if (streamControl) {
      streamControl.close();
      streamControl = null;
    }
    streamControl = openStream(id, fromSeq, later.handlers(), {
      // The stream dropped or never opened: the worker left (idle exit, stop,
      // crash) or is starting. Its cursor means nothing to the next worker
      // (event_seq starts over), so re-read the session once one is live.
      onStreamClosed: () => workerGone(id),
      onStreamError: () => workerGone(id, { opened: false }),
    });
    store.touch("infoBar"); // streaming
  }

  function workerGone(id, { opened = true } = {}) {
    streamControl = null;
    if (id !== store.selected) return;
    // A turn that was running is over only when the worker really left: a
    // stream that merely dropped (no stop, it was open) waits for the re-read.
    const stopped = later.sessionActions().stoppingId() === id;
    const { endNow, endText } = streamDropEnd({ turnRunning: liveTurn.running, stopped, opened });
    if (endNow) deps.view.endTurnView("gone", endText, { stopped });
    store.batch(() => {
      if (endNow && !stopped) page.setLiveStatus("idle");
      store.update({ current: { ...(store.current.owner === "worker" ? { owner: null } : {}), bridgeUp: false } });
      // Its card says "live" (the list's owner, or setLiveStatus's) until the
      // hub's event says otherwise: the worker is gone now, as far as this
      // tab can tell.
      if (store.sessions.find((s) => s.id === id)?.owner === "worker") page.replaceCard(id, withoutWorker);
      store.touch("infoBar"); // streaming
    });
    // Once: a worker still alive with a bridge (the stream dropped, not the
    // worker: chi web restarted) reconnects right here. Otherwise the next
    // worker's bridge_up event brings the stream back (followSelectedSession).
    if (opened) resync({ endText });
    else setTimeout(() => { if (id === store.selected && !(streamControl && streamControl.live)) resync({ endText }); }, STREAM_RETRY_MS);
  }

  function closeStream() {
    turnDom.reset();
    if (streamControl) {
      streamControl.close();
      streamControl = null;
    }
  }

  // The stream handlers' restart (a reset the cursor can't replay): close
  // the stream and resync.
  function restart() {
    streamControl?.close();
    streamControl = null;
    resync();
  }

  return {
    select, resync, followSelectedSession, followWokenWorker, workerGone, resetTurnView, closeStream, restart,
    // session_actions.js closeLiveStream: close only, the handle stays (workerGone clears it).
    closeLive: () => streamControl?.close(),
    hasStream: () => !!streamControl,
    streamLive: () => !!streamControl?.live,
    // For the spec.
    startStream, retryResync,
  };
}
