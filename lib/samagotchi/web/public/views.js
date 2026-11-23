// The page's views by hash: All sessions, its own view at #/sessions so the
// browser's back button leaves it, and the open session's #/s/<id>, so a
// reload or a copied link opens it again. A hash typed, pasted or reached by
// back selects what it names (hashIntent). Opened from the page, All sessions
// closes with history.back(). Moved out of app.js as it was; app.js makes it
// once its pieces exist and hands the functions on (lazily to anything made
// before it).
//
// +win+ / +doc+: the window (location, history, the hashchange listener) and
// the document. +participant+: the participant's page (createParticipantMain),
// or null on the owner's. +store+: the session store (selected, sessions,
// update). +lists+: lists_view.js (selecting, leaveSelect, chainPop,
// familyPop). +topStripEl+: #topStrip. +pictures+: the picture viewer.
// +eventsLive()+: the hub's stream is open. +refresh()+, +updateSessionTitle()+,
// +select(id)+, +clearSelection()+: the page's. +ownerClaim()+: owner_claim.js's
// (made after this, so a getter).
import { ALL_SESSIONS_HASH, sessionHash } from "./route.js";
import { hashIntent } from "./hash_intent.js";
import { claimFromHash } from "./claim_link.js";
import { sortedByUpdated } from "./sessions_list.js";

export function createViews({
  win = globalThis, doc = globalThis.document, participant, store, lists, topStripEl, pictures, eventsLive,
  refresh, updateSessionTitle, select, clearSelection, ownerClaim,
}) {
  const { location, history } = win;
  const $ = (sel) => doc.querySelector(sel);
  let allViewPushed = false;

  function allViewOpen() {
    return !participant && location.hash === ALL_SESSIONS_HASH;
  }
  function openAllView() {
    if (allViewOpen()) return;
    allViewPushed = true;
    location.hash = ALL_SESSIONS_HASH;
  }
  function closeAllView() {
    if (!allViewOpen()) return;
    if (allViewPushed) {
      history.back();
    } else {
      leaveAllView(sessionHash(store.selected));
    }
  }
  // Leave all sessions for a place of our own (a picked session, a new session):
  // replace its history entry, since history.back() would come back later
  // with the session the view was opened from.
  function leaveAllView(hash) {
    history.replaceState(null, "", location.pathname + location.search + hash);
    allViewPushed = false;
    applyView();
  }
  // The open session in the URL, so a reload or a copied link opens it again.
  // Switching sessions replaces the entry; only all sessions pushes one.
  function setSessionHash(id) {
    if (allViewOpen()) return;
    const hash = sessionHash(id);
    if (location.hash === hash || (!hash && !location.hash)) return;
    history.replaceState(null, "", location.pathname + location.search + hash);
  }
  // A #/s/<id> typed or pasted into the address bar, or reached by back.
  // A claim link (claim_link.js; #/s/<id>?t=…&q=…, or the participant's
  // #s=<id>&t=… opened in this browser) opens its session and, once drawn,
  // shows the claim. The start page's own hash ("#/", or none) while one is
  // open is the start page: the same clear the + button does, so the page and
  // the composer stop addressing the session the URL has left behind.
  function selectFromHash() {
    const claim = claimFromHash(location.hash);
    if (claim) ownerClaim().pending(claim);
    // A participant's page has one session, whatever the hash names.
    const intent = participant ? { kind: "session", id: participant.sessionId } : hashIntent(location.hash, { selected: store.selected, claim });
    if (intent.kind === "session" && intent.id !== store.selected) select(intent.id);
    else if (claim) ownerClaim().showPending();
    else if (intent.kind === "start") clearSelection();
  }
  function applyView() {
    const open = allViewOpen();
    if (!open) {
      allViewPushed = false;
      // A running batch ends on its own and clears the picks then.
      if (lists.selecting.on && !lists.selecting.running) lists.leaveSelect();
      topStripEl.scrollLeft = 0; // a phone's strip scrolls sideways to the tile
    }
    doc.body.classList.toggle("all-view", open);
    // The sessions pill is the view's button there: pressed while it is open.
    $("#stripStatus").setAttribute("aria-pressed", String(open));
    updateSessionTitle();
    // Its chip was in the list just hidden (the strip, or all sessions).
    lists.chainPop.close();
    if (open) {
      lists.familyPop.close(); pictures.close(); // the strip and #center (the picture viewer's parent) are hidden there
      // The list is live; only its order can lag (upserts keep cards in
      // place), so the all view opens in the server's order.
      // A new list: the lists' redraw draws the all view (lists.render).
      store.update({ sessions: sortedByUpdated(store.sessions) });
      if (!eventsLive()) refresh();
      $("#filter").select();
    }
  }
  win.addEventListener("hashchange", () => {
    applyView();
    selectFromHash();
  });

  return { allViewOpen, openAllView, closeAllView, leaveAllView, setSessionHash, selectFromHash, applyView };
}
