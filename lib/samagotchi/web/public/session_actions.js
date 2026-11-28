import { continueRefusal, continuedText, openChildrenTemplate, openerText } from "./chains.js";
import { cantText, goneSessionNotice } from "./format.js";
import { tasksStoppedSuffix } from "./running_tasks.js";
import { sessionHash } from "./route.js";
import { inTree } from "./sessions_list.js";
import { stillOn } from "./latest.js";
import { listAfterDelete, runDeleteFlow } from "./delete_sheet.js";
import { deleteToast } from "./removal_sheet_model.js";

// What the page does to a whole session (used by app.js): Continue, Archive
// and Unarchive, Delete and Stop, from the info bar's buttons, a card's or a
// batch; and the start page when the open session is gone.
//
// Hooks: +selected()+ the open session's id or null; +store+ the page's
// session store (session_store.js: Stop's status; touch("infoBar") for the
// continue in-flight set, which it doesn't hold); +sessions()+ /
// +setSessions(list)+ the page's list (the store's: a new list redraws the
// lists and the bar);
// +api+: {continueSession, archiveSession, unarchiveSession,
// deleteSession, deleteChain, deletePlan, stopSession, sessionHolds,
// stopSessionHolds} (data.js);
// +eventsLive()+ the hub's stream is open (else
// +refresh()+ fetches the list);
// +select(id)+, +clearSelection()+, +showNotice(text)+,
// +toast(text, action, options)+, +addCreatedSession(created)+,
// +fillOpener(created, continuedId)+ (the new link's composer; returns a draft
// from another session it displaced, or null), +restoreDraft(draft, opener)+
// (that draft back, never over newer text), +closeLiveStream()+ (the live
// stream's close, the stream left as it is) and +workerGone(id)+ the page's;
// +moveDraft(from, to)+ / +dropDraft(id)+ the composer's drafts (drafts.js:
// a gone session's goes to the start page's, a deleted one's is forgotten;
// none passed, an older cached app.js: left as they are).
// +confirm+: the browser's (Stop's, when nothing else runs).
export function createSessionActions({
  selected, store, sessions, setSessions, api, eventsLive, refresh,
  select, clearSelection, showNotice, toast, addCreatedSession, fillOpener, restoreDraft, closeLiveStream, workerGone,
  moveDraft = null, dropDraft = null,
  confirm = (text) => globalThis.confirm(text),
  // The Stop sheet (stop_sheet.js): +open(id, holds)+ shows it and answers
  // true; nothing to stop (or no sheet wired) is false, and Stop is the
  // confirm.
  stopSheet = { open: () => false },
  // The delete sheet's shell (delete_sheet.js createDeleteSheet):
  // +host(anchor, id)+ draws a delete's or an archive's sheet at it.
  deleteSheet = null,
  // The page's document: where a card's control and ⋯ are found.
  doc = globalThis.document,
}) {
  // The ids of +id+'s chain in the page's list (its links, by continues).
  function chainOf(id) {
    const list = sessions();
    const ids = new Set([id]);
    for (let grew = true; grew;) {
      grew = false;
      for (const s of list) {
        if (ids.has(s.id) && s.continues && !ids.has(s.continues)) { ids.add(s.continues); grew = true; }
        if (s.continues && ids.has(s.continues) && !ids.has(s.id)) { ids.add(s.id); grew = true; }
      }
    }
    return ids;
  }

  // The session this tab is stopping: its stream may close before the stop
  // request returns (workerGone reads it).
  let stoppingId = null;
  // The sessions a delete from this tab is taking (filled when its request
  // starts): the hub's session_gone may come before its answer, and their
  // drafts are dropped, not moved to the start page's.
  const deleting = new Set();

  // Delete a session (the ⋯ More panel's Delete, an all-sessions card's ✕):
  // the delete sheet (delete_sheet.js) says what goes, what is stopped first
  // and what stays, from the server's plan; in the More panel's place
  // (deleteIn), at the card's ✕ (+anchor+), else at ⋯. A refusal the plan
  // carries (a terminal's one-turn run, a schedule) is the sheet's Can't
  // delete. The list drops what went without a reload.
  function confirmDelete(id, { anchor = null } = {}) {
    const sess = sessions().find((s) => s.id === id) || { id };
    const at = anchor || doc?.querySelector("#infoMoreBtn");
    if (!deleteSheet || !api.deletePlan || !at) return;
    startDeleteFlow(id, sess, deleteSheet.host(at, id));
  }

  // The More panel's Delete: it always takes +host+ (the panel turns into
  // the sheet), so no second popover opens inside More's click.
  function deleteIn(id, host) {
    if (!id || !api.deletePlan) return false;
    startDeleteFlow(id, sessions().find((s) => s.id === id) || { id }, host);
    return true;
  }

  function startDeleteFlow(id, sess, host) {
    // What this delete takes: the session, and for a chain the open link
    // too when it is one of it (the plan names no ids).
    const taking = new Set();
    const take = (ids) => ids.forEach((x) => { if (x) { taking.add(x); deleting.add(x); } });
    const over = () => taking.forEach((x) => deleting.delete(x));
    const flowApi = {
      ...api,
      deleteSession: (sid, opts) => { take([sid]); return api.deleteSession(sid, opts); },
      deleteChain: (sid, opts) => { take([sid, chainOf(sid).has(selected()) ? selected() : null]); return api.deleteChain(sid, opts); },
    };
    const flow = runDeleteFlow({
      id, session: sess, host, api: flowApi, sessions,
      done: (which, result, plan) => {
        afterDelete(id, which, result, plan);
        over();
      },
      failed: (error) => {
        over();
        notShown(host, `delete ${id.slice(0, 8)}`, error);
        if (!eventsLive()) refresh();
      },
    });
    host.wire(flow);
  }

  // A delete or archive that didn't happen, when its sheet no longer shows
  // why (an older cached delete_sheet.js closes it first): a sticky toast.
  function notShown(host, what, error) {
    if (!host.live || host.live()) return;
    toast(cantText(what, error), null, { sticky: true });
  }

  function afterDelete(id, which, result, plan) {
    setSessions(listAfterDelete(sessions(), result));
    const gone = new Set(result.deleted || [id]);
    if (gone.has(selected())) clearSelection();
    // After the start page opened: the swap saved the deleted one's draft last.
    gone.forEach((x) => dropDraft?.(x));
    if (!eventsLive()) refresh();
    const { text, back, sticky = false } = deleteToast(which, result, plan, id);
    toast(text, back ? { label: `Open ${back.slice(0, 8)}`, run: () => select(back) } : null, { sticky });
  }

  // The open session no longer exists: back to the start page, saying why.
  function leaveGoneSession(id, why) {
    if (selected() !== id) return;
    // Its draft isn't lost with it: it goes to the start page's (under what
    // is there). A delete from this tab drops it instead (afterDelete).
    if (!deleting.has(id)) moveDraft?.(id, "");
    clearSelection();
    showNotice(goneSessionNotice(id, why));
  }

  // The info bar's Stop: the open session's worker. It first asks the worker
  // what still runs that the user can stop (GET …/holds); when there is
  // something, the sheet (stop_sheet.js) asks what to do with it; when there
  // is nothing, or no worker to ask, it is today's confirm and one tap.
  // +stopHolds+ is the sheet's "Stop all": the worker's stop-all step, then
  // the stop. A delegate or a background task outlives the worker either way
  // (docs/sessions.md, "Stopping a worker"), which is why the sheet says so.
  // One Stop per session at a time (as continuingIds): a second tap while the
  // holds read (or the stop) is under way would be a second confirm.
  const stopAsks = new Set();

  async function stopSelected(id = selected(), options = {}) {
    if (!id || stopAsks.has(id)) return;
    stopAsks.add(id);
    try {
      await stopOne(id, options);
    } finally {
      stopAsks.delete(id);
    }
  }

  async function stopOne(id, { stopHolds = false }) {
    if (!stopHolds) {
      let holds = [];
      try {
        const answer = await api.sessionHolds(id);
        holds = answer?.holds || [];
      } catch {
        holds = []; // a worker that can't say, or none: stop as before
      }
      if (stopSheet.open(id, holds)) return;
      if (!confirm(`Stop session ${id}?`)) return;
    }

    // Stop all: the worker stops what it can first. A failure is said and
    // doesn't hold the stop: the session goes either way, and the sheet's
    // other button is exactly that.
    if (stopHolds) {
      try {
        await api.stopSessionHolds(id);
      } catch (e) {
        toast(`${cantText("stop what the session runs", e)} — stopping the session anyway`, null, { sticky: true });
      }
    }

    stoppingId = id;
    try {
      await api.stopSession(id);
      if (id === selected()) stoppedWorker(id);
    } catch (e) {
      if (e?.code === "stop_held") {
        // A continue, a delete or an archive holds it: the server's words say
        // what to do; a continue's new link is the one to open (and stop).
        const next = e.body?.successor_id;
        const words = String(e.message);
        toast(words.charAt(0).toUpperCase() + words.slice(1),
              next ? { label: `Open ${next.slice(0, 8)}`, run: () => select(next) } : null, { sticky: true });
      } else {
        // A refusal (a terminal holds it) or a worker that won't stop: said, as
        // a failed restart is.
        toast(cantText(`stop ${id.slice(0, 8)}`, e), null, { sticky: true });
      }
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
    store.touch("infoBar");
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
      store.touch("infoBar");
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
    store.setStatus("stopped", "stop");
    workerGone(id);
  }

  // One archive / unarchive request, the core the info bar, a card's button
  // and a batch share. The ids in the answer flip in the list at once. When
  // the open session's worker was stopped (it, or a delegate of the archived
  // one), its stream ending is a stop, not a lost worker.
  // +stopTasks+: the archive stops the background tasks the tree started
  // first, only +tasks+ (the ids the sheet named) when given (else a session
  // whose tasks still run is refused: 409 tasks_running; a batch passes
  // nothing, and skips it with that reason).
  // @return {ok: true, result} | {ok: false, error}
  async function archiveOne(id, archive, { stopTasks = false, tasks = null } = {}) {
    // A live worker in the tree is stopped by the archive: the open
    // session's stream ending then is a stop.
    const open = selected();
    const mine = archive && open && inTree(sessions(), id, open) ? open : null;
    if (mine) stoppingId = mine;
    try {
      const result = archive
        ? await api.archiveSession(id, ...(stopTasks ? [{ stopTasks: true, ...(tasks ? { tasks } : {}) }] : []))
        : await api.unarchiveSession(id);
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

  // No confirm: one tap and the toast's Undo. Unless the archive can't
  // happen as it is (a 409): background tasks the tree started still run
  // (tasks_running) opens the sheet in Archive's words, whose button archives
  // stopping the tasks it named; any other refusal is its Can't archive. The
  // sheet is at the control tapped: +anchor+ (⋯ for the open session's), else
  // the card's archive button, found by the session's id. Undo only
  // unarchives: stopped tasks stay stopped.
  // A sheet opened since for another session (a card's ✕ while the archive
  // was out) keeps its place: the refusal is a sticky toast instead
  // (latest.js stillOn on the shell's session).
  async function setArchived(id, archive, { undo = true, anchor = null } = {}) {
    const sheetSame = deleteSheet?.openFor ? stillOn(() => deleteSheet.openFor()) : () => true;
    const answer = await archiveOne(id, archive);
    if (!answer.ok) {
      const taken = !sheetSame() && deleteSheet.openFor() !== id;
      const at = archive && deleteSheet && !taken ? anchor || archiveAnchor(id) : null;
      if (at) askArchive(id, answer.error, at, undo);
      else {
        toast(cantText(`${archive ? "archive" : "unarchive"} ${id.slice(0, 8)}`, answer.error), null, { sticky: true });
        if (!eventsLive()) refresh();
      }
      return;
    }
    archived(id, archive, answer.result, undo);
  }

  // markArchived's list redrew the lists and the bar already.
  function archived(id, archive, result, undo) {
    if (!eventsLive()) refresh();
    const what = archive ? "Archived" : "Unarchived";
    toast(`${what} ${id.slice(0, 8)}${archive ? tasksStoppedSuffix(result) : ""}`,
          undo ? { label: "Undo", run: () => setArchived(id, !archive, { undo: false }) } : null);
  }

  // A card's archive button for +id+ that has a box (the strip's, the list's
  // or the all-sessions view's), else ⋯.
  function archiveAnchor(id) {
    const cards = [...(doc?.querySelectorAll(`[data-arch="${id}"]`) || [])];
    return cards.find((el) => el.getClientRects?.().length) || doc?.querySelector("#infoMoreBtn") || null;
  }

  function askArchive(id, error, at, undo) {
    const host = deleteSheet.host(at, id);
    host.wire(runDeleteFlow({
      id, session: sessions().find((s) => s.id === id) || { id }, host, sessions,
      archive: { refusal: error },
      api: {
        archive: async (sid, opts) => {
          const answer = await archiveOne(sid, true, opts);
          if (!answer.ok) throw answer.error;
          return answer.result;
        },
      },
      done: (_which, result) => archived(id, true, result, undo),
      failed: (failure) => notShown(host, `archive ${id.slice(0, 8)}`, failure),
    }));
  }

  // The info bar's Archive / Unarchive: the open session's, by its state.
  function toggleArchiveSelected() {
    if (!selected()) return;
    if (selectedArchived()) setArchived(selected(), false);
    else setArchived(selected(), true, { anchor: doc?.querySelector("#infoMoreBtn") || null });
  }

  return {
    confirmDelete, deleteIn, leaveGoneSession, stopSelected, continueSelected, archiveOne, setArchived, toggleArchiveSelected,
    // The sessions whose Continue is under way (the info bar's button).
    continuing: continuingIds,
    // The session this tab is stopping, or null.
    stoppingId: () => stoppingId,
  };
}
