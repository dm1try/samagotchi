import { continueRefusal, continuedText, openChildrenTemplate, openerText } from "./chains.js";
import { cantText, deleteConfirmText, goneSessionNotice } from "./format.js";
import { sessionHash } from "./route.js";
import { inTree } from "./sessions_list.js";

// What the page does to a whole session (used by app.js): Continue, Archive
// and Unarchive, Delete and Stop, from the info bar's buttons, a card's or a
// batch; and the start page when the open session is gone.
//
// Hooks: +selected()+ the open session's id or null; +state()+ its fields
// (session_state.js); +sessions()+ / +setSessions(list)+ the page's list;
// +api+: {continueSession, startReview, archiveSession, unarchiveSession,
// deleteSession, stopSession} (data.js); +eventsLive()+ the hub's stream is open (else
// +refresh()+ fetches the list); +lists+ (lists_view.js: render);
// +select(id)+, +clearSelection()+, +showNotice(text)+, +updateInfoBar()+,
// +toast(text, action, options)+, +addCreatedSession(created)+,
// +fillOpener(created, continuedId)+ (the new link's composer; returns a draft
// from another session it displaced, or null), +restoreDraft(draft, opener)+
// (that draft back, never over newer text), +closeLiveStream()+ (the live
// stream's close, the stream left as it is) and +workerGone(id)+ the page's.
// +alert+ / +confirm+: the browser's.
// The toast after Start review: the new session, where it starts from, and
// the model warning when there is one.
export function reviewStartedText(id, created) {
  const warning = created.model_warning ? ` (${created.model_warning})` : "";
  return `Review ${created.id.slice(0, 8)} started from ${id.slice(0, 8)}'s recap; ${id.slice(0, 8)} keeps running${warning}. Invite someone to it.`;
}

export function createSessionActions({
  selected, state, sessions, setSessions, api, eventsLive, refresh, lists,
  select, clearSelection, showNotice, updateInfoBar, toast, addCreatedSession, fillOpener, restoreDraft, closeLiveStream, workerGone,
  alert = (text) => globalThis.alert(text), confirm = (text) => globalThis.confirm(text),
}) {
  // The session this tab is stopping: its stream may close before the stop
  // request returns (workerGone reads it).
  let stoppingId = null;

  // Delete a session (the info bar's button, an all-sessions card's ✕) after
  // a confirm; the list drops it without a reload. The server stops a live
  // worker first and refuses a session a terminal chi has open.
  async function confirmDelete(id) {
    const sess = sessions().find((s) => s.id === id) || { id };
    if (sess.owner === "tui") {
      alert(`Session ${id.slice(0, 8)} is open in a terminal chi; close it there first.`);
      return;
    }
    if (!confirm(deleteConfirmText(sess))) return;
    try {
      await api.deleteSession(id);
    } catch (e) {
      alert(`Could not delete session ${id.slice(0, 8)}: ${e.message}`);
      if (!eventsLive()) refresh();
      return;
    }
    setSessions(sessions().filter((s) => s.id !== id));
    if (selected() === id) clearSelection();
    lists.render();
  }

  // The open session no longer exists: back to the start page, saying why.
  function leaveGoneSession(id, why) {
    if (selected() !== id) return;
    clearSelection();
    showNotice(goneSessionNotice(id, why));
  }

  // The info bar's Stop: the open session's worker, after a confirm.
  async function stopSelected() {
    if (!selected()) return;
    if (!confirm(`Stop session ${selected()}?`)) return;
    const id = selected();
    stoppingId = id;
    try {
      await api.stopSession(id);
      if (id === selected()) stoppedWorker(id);
    } catch (e) {
      // A refusal (a terminal holds it) or a worker that won't stop: said, as
      // a failed restart is.
      toast(cantText(`stop ${id.slice(0, 8)}`, e), null, { sticky: true });
    } finally {
      stoppingId = null;
    }
    // The list hears of the stop from the hub (the stop route rescans it).
    if (!eventsLive()) refresh();
  }

  // ── Continue (session chains) ─────────────────────────────────────────────
  // Continue → starts the next link of the open session's chain (the server
  // waits up to 30 s for its recap, archives it, starts the new one with the
  // recap as a note) and opens it with the opener in the composer, not sent
  // (fillOpener: the previous link's own first message when it continues one).
  // A link continued already opens that next link; its open delegates move
  // to the new link (the toast counts them); a refusal for open delegates
  // that can't move names them, each a link.
  // One continue per session at a time (the server locks it too); another
  // session's continue may run beside it.
  const continuingIds = new Set();

  async function continueSelected() {
    if (!selected() || continuingIds.has(selected())) return;
    const id = selected();
    const short = id.slice(0, 8);
    continuingIds.add(id);
    updateInfoBar();
    try {
      const created = await api.continueSession(id);
      markArchived([id], true);
      addCreatedSession(created);
      const next = created.id;
      // A model fallback's warning stays until closed.
      const sticky = !!created.model_warning;
      if (selected() !== id) {
        toast(continuedText(id, created, { opened: false }), { label: "Open", run: () => select(next) }, { sticky });
        return;
      }
      await select(next);
      // A draft carried over from elsewhere gave way to the opener: the
      // toast brings it back, and stays until closed so it can't be lost.
      const displaced = selected() === next ? fillOpener(created, id) : null;
      const restore = displaced ? { label: "Restore draft", run: () => restoreDraft(displaced, openerText(created)) } : null;
      toast(continuedText(id, created), restore, { sticky: sticky || !!displaced });
    } catch (e) {
      const refusal = continueRefusal(e, sessions());
      if (refusal.kind === "open") {
        if (selected() === id) await select(refusal.id);
        toast(`${short} is continued already: ${selected() === refusal.id ? "opened" : "see"} ${refusal.id.slice(0, 8)}`);
      } else if (refusal.kind === "children") {
        toast(openChildrenTemplate(id, refusal.children, sessionHash), null, { sticky: true });
      } else {
        toast(`Can't continue ${short}: ${refusal.text}`, null, { sticky: true });
      }
    } finally {
      continuingIds.delete(id);
      updateInfoBar();
    }
  }

  // Start review: a review fork of the open session (its recap, not its
  // transcript; it keeps running), opened, with Invite in the toast (the new
  // session's participants chip). One per session at a time.
  // +onError(text)+: says a refusal where it was asked (the participants
  // panel), true when it did; else the toast says it.
  // @return the created session, or null (none open, one under way, refused)
  const reviewingIds = new Set();

  async function reviewSelected({ onError = null } = {}) {
    if (!selected() || reviewingIds.has(selected())) return null;
    const id = selected();
    reviewingIds.add(id);
    updateInfoBar();
    try {
      const created = await api.startReview(id);
      addCreatedSession(created);
      if (selected() === id) await select(created.id);
      // After the toast's own click is done: the panel would take it as a
      // click outside and close.
      const openPanel = () => globalThis.document?.querySelector("#infoText .participants-chip")?.click();
      const invite = { label: "Invite", run: () => setTimeout(openPanel, 0) };
      toast(reviewStartedText(id, created), selected() === created.id ? invite : { label: "Open", run: () => select(created.id) },
            { sticky: !!created.model_warning });
      return created;
    } catch (e) {
      const text = `Can't start a review of ${id.slice(0, 8)}: ${e.message}`;
      if (!onError?.(text)) toast(text, null, { sticky: true });
      return null;
    } finally {
      reviewingIds.delete(id);
      updateInfoBar();
    }
  }

  // ── Archive ───────────────────────────────────────────────────────────────
  // Archive hides a session (and its delegates) from the strip and the list,
  // kept for good; "include archived" in all sessions finds it. No confirm:
  // the toast's Undo takes it back. Archiving the open session stays on it
  // (the button flips to unarchive); its worker was stopped by the server.

  function selectedArchived() {
    return !!sessions().find((s) => s.id === selected())?.archived;
  }

  // The ids in the server's answer flip here at once; the hub's events
  // follow with the same.
  function markArchived(ids, archived) {
    const set = new Set(ids);
    setSessions(sessions().map((s) => (set.has(s.id) ? { ...s, archived } : s)));
  }

  // The open session's worker was stopped from here (the stop button, an
  // archive): don't wait for its stream to notice.
  function stoppedWorker(id) {
    closeLiveStream();
    state().status = "stopped";
    workerGone(id);
  }

  // One archive / unarchive request, the core the info bar, a card's button
  // and a batch share. The ids in the answer flip in the list at once. When
  // the open session's worker was stopped (it, or a delegate of the archived
  // one), its stream ending is a stop, not a lost worker.
  // @return {ok: true, result} | {ok: false, error}
  async function archiveOne(id, archive) {
    // A live worker in the tree is stopped by the archive: the open
    // session's stream ending then is a stop.
    const open = selected();
    const mine = archive && open && inTree(sessions(), id, open) ? open : null;
    if (mine) stoppingId = mine;
    try {
      const result = archive ? await api.archiveSession(id) : await api.unarchiveSession(id);
      markArchived(archive ? result.archived : result.unarchived, archive);
      if (mine && mine === selected() && (result.stopped || []).includes(mine)) stoppedWorker(mine);
      return { ok: true, result };
    } catch (error) {
      return { ok: false, error };
    } finally {
      // Another call may have taken it meanwhile: clear only our own.
      if (mine && stoppingId === mine) stoppingId = null;
    }
  }

  async function setArchived(id, archive, { undo = true } = {}) {
    const short = id.slice(0, 8);
    const answer = await archiveOne(id, archive);
    if (!answer.ok) {
      alert(`Could not ${archive ? "archive" : "unarchive"} session ${short}: ${answer.error.message}`);
      return;
    }
    lists.render();
    updateInfoBar();
    if (!eventsLive()) refresh();
    const what = archive ? "Archived" : "Unarchived";
    toast(`${what} ${short}`, undo ? { label: "Undo", run: () => setArchived(id, !archive, { undo: false }) } : null);
  }

  // The info bar's Archive / Unarchive: the open session's, by its state.
  function toggleArchiveSelected() {
    if (!selected()) return;
    if (selectedArchived()) setArchived(selected(), false);
    else setArchived(selected(), true);
  }

  return {
    confirmDelete, leaveGoneSession, stopSelected, continueSelected, reviewSelected, reviewing: reviewingIds, archiveOne, setArchived, toggleArchiveSelected,
    // The sessions whose Continue is under way (the info bar's button).
    continuing: continuingIds,
    // The session this tab is stopping, or null.
    stoppingId: () => stoppingId,
  };
}
