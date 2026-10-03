import {
  listSessions,
  getSession,
  sendTurn,
  cancelTurn,
  stopSession,
  restartSession,
  deleteSession,
  archiveSession,
  unarchiveSession,
  sendCommand,
  openStream,
  openEvents,
  createIdleSession,
  uploadImage,
  listModels,
  fetchHistory,
} from "./data.js";
import { MODEL_KEY } from "./model_pick.js";
import { emptySessionState } from "./session_state.js";
import { createModelPicker } from "./model_picker.js";
import { chipName, chipsHtml, imageFiles, restoredChips, thumbsHtml, turnRefs, turnText } from "./images.js";
import { escapeHtml, noteHtml, normalize, steerRowHtml, userBodyHtml, ownerBadge, previewForCard, relativeTime, failedTurnText, modelLabel, deleteConfirmText, recapLabel, canStopSession, goneSessionNotice, withLiveStatus, withoutWorker, recapPlace, delegatedBy } from "./format.js";
import { EMPTY_ANSWER_CLASS, createTurnView, turnHistoryHtml } from "./turn_view.js";
import { createStageView } from "./stage_view.js";
import { appendQuote } from "./annotations.js";
import { parsePresets } from "./annotate_presets.js";
import { createAnnotateBar } from "./annotate_bar.js";
import { COPY_SOURCE_ATTR, copySource, copyText, installCopy, showsAnswer } from "./copy.js";
import { routeChunk } from "./chunk_router.js";
import { extractCtxPct, savedCtxPct, cardCtxText, generationTokens, lastSpeedText, speedText, tokensTipText } from "./ctx.js";
import { createQuestionCards } from "./question_cards.js";
import { cardClass, cardInnerHtml, cardPlace, isCard, isNoticeCard, noticeInnerHtml, splitSnapshotCards, turnNoticePlace } from "./card.js";
import { gripFloor, promptHeight } from "./composer_size.js";
import { createCommandList } from "./command_list.js";
import { createPromptHistory } from "./prompt_history.js";
import { ALL_SESSIONS_HASH, sessionHash, sessionIdFromHash } from "./route.js";
import { allScopeHref, cardFolder, projectScopeHref, scopeDir } from "./scope.js";
import { shouldFollowScroll, keepFollowing } from "./scroll.js";
import { SHORT_WINDOW_QUERY, stripAutoHidden, stripColumns, stripShowParts } from "./strip.js";
import { applySessionEvent, heldOrder, listedSessions, sortedByUpdated, waitingBadge, waitingFirst, waitingSearchText, withChildrenAfterParents } from "./sessions_list.js";
import { createNotifications } from "./notifications.js";
import { restartConfirmText, versionNotice, workerBadge } from "./update_notice.js";
import {
  appendAboveLiveTiming, cancelLineText, elapsedSince, formatDuration, mergeTiming, normalizeTiming, turnTimingText,
} from "./timing.js";
import { DONE_MS, applyInitEvent, dropDone, initRowHtml, newInitTasks, seedInitTasks } from "./init_row.js";
import { clientLabel, commandView, displayWait, dropEarlyRestores, emptyAnswerLine, emptyRetryLine, hookNoticeLabel, initWaitLine, isOwn, sessionCommandLine, keepEarlyRestore, newClientId, noticeLine, promptOps, reminderText, restoreAction, composerAfterAck, restoreOnAck, retryStatusLine, snapshotEvents, startPageReplyOrHint, turnOutput, unknownCommandHint, webLocalReply, workerGoneText } from "./turn_events.js";

const $ = (s) => document.querySelector(s);
const topStripEl = $("#topStrip");
const allListEl = $("#allList");
const historyEl = $("#history");
const emptyEl = $("#empty");
const composerEl = $("#composer");
const infoBarEl = $("#infoBar");
const firstPeekEl = $("#firstPeek");
const infoTextEl = $("#infoText");
const markdownWarningEl = $("#markdownWarning");
const promptEl = $("#prompt");
const actionBtn = $("#actionBtn");
const cancelBtn = $("#cancelBtn");
const modelPickEl = $("#modelPick");
const composeHintEl = $("#composeHint");

let selected = null;
let streamControl = null;
// The session list's stream (GET /api/events); null while the page falls
// back to fetching (a chi web without a hub).
let eventsControl = null;
// resync() calls in flight, and whether a worker came up for the selected
// session while one ran (its bridge_up event): the tail runs once more.
let resyncsInFlight = 0;
let resyncAgain = false;
let allSessions = [];
let seenContent = new Set();
// The page's view of a turn (web.view, or ?view=stage|turn): the running
// turn pinned above the composer (the stage, stage_view.js), or one block
// per turn with its steps in the history (turn_view.js).
const view = ["stage", "turn"].includes(document.body.dataset.view) ? document.body.dataset.view : "stage";
// The running turn's DOM: the turn block, or the stage (the turn block in
// its cloud).
const viewArgs = {
  historyEl,
  appendToHistory: (el) => appendToHistory(el),
  isNearBottom: () => isNearBottom(),
  sawText: (k) => seenContent.add(k),
  sessionId: () => selected,
};
const turnDom = view === "stage"
  ? createStageView({ ...viewArgs, isNearBottom: () => atHistoryEnd(), dockEl: $("#dock"), centerEl: $("#center"), composerEl })
  : createTurnView(viewArgs);
// Where a running turn's rows can be: the history, and the stage while it
// holds a turn (lookups by id, copy, annotate, card actions).
function turnRoots() {
  return turnDom.root ? [historyEl, turnDom.root] : [historyEl];
}
function findInTurnRoots(selector) {
  return turnRoots().flatMap((root) => [...root.querySelectorAll(selector)]);
}
// The open session's fields (session_state.js); resetSessionState() starts
// them over.
let current = emptySessionState();
let turnRunning = false;
let liveTurnTimingEl = null;
// The running turn's id (turn_started's turn_id, the id of its timing
// record), so a turn-end re-read finishes that turn's line with that
// turn's record, whatever started since.
let liveTurnId = null;
// The turns this page saw end: the records of its last full render, +1 at
// each turn's end, never fewer than a merge brought. The live line numbers
// the next one, so a turn queued behind another reads its own number while
// the other's re-read is still out.
let turnsEnded = 0;
// What the running turn waits on, after its live timing line: a provider
// retry (generation_retrying) or plugins' setup (plugin_init_wait); "" when
// it streams again.
let liveTurnNote = "";
let timingInterval = null;

// This tab's id in the session's events: tells its own prompts from the
// ones other clients (an attached TUI, another tab, reminders) sent.
const clientId = newClientId();
// The question and continue cards in the history (question_cards.js).
const questionCards = createQuestionCards({
  sessionId: () => selected,
  clientId,
  place: (card) => appendToHistory(card),
  isNearBottom: () => isNearBottom(),
  scrollToEnd: () => { historyEl.scrollTop = historyEl.scrollHeight; },
  removeHintIfEmpty: () => removeHintIfEmpty(),
});
// The event id (or, from an older worker, the event_seq) the selected session
// was rendered at (null: no live worker then), where a stream opened later
// has to start.
let selectSeq = null;
// The last input_merged had an origin with no bubble: its merged text
// (pending_input_merged) gets one.
let unmatchedMerge = false;
// The enqueued_ids this page sent (from the /turn acks): only these come back
// into the composer when their turn fails.
const sentIds = new Set();
// Own prompt_restored events that came before their /turn ack, by
// enqueued_id: the ack puts that prompt back instead of clearing it.
const earlyRestores = new Map();
// The last turn_failed's line, shown again after prompt_restored's resync.
let lastFailedText = null;

// The page's scope (scope.js): ?dir= is the folder a project view came
// from (new chats start there); the server names its project, if any.
const scope = {
  dir: scopeDir(location.search),
  projectName: document.body.dataset.projectName || null,
  projectDir: document.body.dataset.projectDir || "",
  serverDir: document.body.dataset.serverDir || "",
  // The all view's way back to a project view (?from=, or chi web's own).
  backName: document.body.dataset.backName || null,
  backDir: document.body.dataset.backDir || "",
};
// The server refused ?dir (a folder deleted since the link was made).
let scopeError = null;

// The list by fetching: the fallback when there is no events stream (a
// chi web without a hub, or ?dir the server refused: the 400 is read here).
async function refresh() {
  try {
    allSessions = await listSessions("updated_at", "desc", { dir: scope.dir });
  } catch (e) {
    if (e.status !== 400 || !scope.dir) throw e;
    scopeError = e.message;
    allSessions = [];
    renderScope();
  }
  render();
}

// The list as a projection of the hub's events: a snapshot on every
// (re)connect, then upserts and removals. The selected session's owner and
// worker follow its events (a new worker's bridge_up reconnects the stream).
function openSessionEvents() {
  eventsControl = openEvents({
    snapshot: (data) => {
      noticeVersions(data);
      notifications.noticeSessions("snapshot", data);
      allSessions = applySessionEvent(allSessions, "snapshot", data);
      render();
      const sess = allSessions.find((s) => s.id === selected);
      if (sess) followSelectedSession(sess);
    },
    session: (data) => {
      notifications.noticeSessions("session", data);
      allSessions = applySessionEvent(allSessions, "session", data);
      render();
      if (data.session && data.session.id === selected) followSelectedSession(data.session);
    },
    session_gone: (data) => {
      notifications.noticeSessions("session_gone", data);
      const next = applySessionEvent(allSessions, "session_gone", data);
      if (next !== allSessions) {
        allSessions = next;
        render();
      }
      leaveGoneSession(data.id, "deleted");
    },
    chi: (data) => noticeVersions(data),
  }, {
    dir: scope.dir,
    onError: () => {
      eventsControl = null;
      refresh();
    },
  });
}

// Which chi serves this page now and which is the newest installed (the
// events snapshot, and `chi` frames when that changes). A toast says when
// chi web was upgraded while this tab stayed open (offering the reload,
// never forcing it) or when a newer chi is installed than chi web runs.
// Once per notice per tab: every reconnect's snapshot says it again.
const versions = { served: null, installed: null };
// The session whose Restart is under way (its button says so).
let restartingId = null;
const versionNoticesShown = new Set();
function noticeVersions(data) {
  if (typeof data.version === "string") versions.served = data.version;
  versions.installed = typeof data.installed === "string" ? data.installed : null;
  const notice = versionNotice({ loaded: document.body.dataset.version, served: versions.served,
                                 installed: versions.installed, shown: versionNoticesShown });
  updateInfoBar(); // the worker badge compares with the newest installed
  if (!notice) return;
  versionNoticesShown.add(notice.key);
  showToast(notice.text, notice.reload ? { label: "Reload", run: () => location.reload() } : null, { sticky: true });
}

// The selected session's card changed: its owner and, without a live
// stream, its status show in the info bar; a worker whose bridge is up
// (a turn another client sent woke one, or a replacement after a kill)
// gets the stream attached through one resync.
function followSelectedSession(sess) {
  current.owner = sess.owner || null;
  current.workerVersion = sess.worker_version || null;
  current.workerFeatures = Array.isArray(sess.worker_features) ? sess.worker_features : [];
  const streaming = !!(streamControl && streamControl.live);
  if (!streaming) current.status = sess.status;
  updateInfoBar();
  if (!sess.bridge_up || streaming) return;
  if (resyncsInFlight > 0) resyncAgain = true;
  else resync();
}

// The header's scope chip: "<project> · all" in a project view (all links
// to the same place without ?dir); "all projects" otherwise, with where a
// new chat starts on the start page.
function renderScope() {
  const el = $("#scope");
  const allLink = `<a class="scope-all" href="${escapeHtml(allScopeHref(location.hash, scope.dir, location.search))}" title="Sessions of every project">all</a>`;
  if (scopeError) {
    el.innerHTML = `<span class="scope-name error" title="${escapeHtml(scopeError)}">folder not found</span>${allLink}`;
  } else if (scope.projectName) {
    el.innerHTML = `<span class="scope-name" title="Sessions of ${escapeHtml(scope.projectDir)}">${escapeHtml(scope.projectName)}</span>${allLink}`;
  } else {
    const where = scope.dir || scope.serverDir;
    const backLink = scope.backName
      ? `<a class="scope-all scope-back" href="${escapeHtml(projectScopeHref(scope.backDir, location.hash, location.search))}" title="Sessions of ${escapeHtml(scope.backName)} only">← ${escapeHtml(scope.backName)}</a>`
      : "";
    el.innerHTML = `<span class="scope-name" title="Sessions of every project">all projects</span>${backLink}${where ? `<span class="scope-where" title="New chats start in ${escapeHtml(where)}">new chat in<span class="path"><bdi>${escapeHtml(where)}</bdi></span></span>` : ""}`;
  }
  el.hidden = false;
  notifications.setBaseTitle(scope.projectName ? `Chi · ${scope.projectName}` : "Chi");
  // The links follow the hash (an open session, the all-sessions view).
  el.querySelector(".scope-all:not(.scope-back)")?.addEventListener("click", (e) => {
    e.currentTarget.href = allScopeHref(location.hash, scope.dir, location.search);
  });
  el.querySelector(".scope-back")?.addEventListener("click", (e) => {
    e.currentTarget.href = projectScopeHref(scope.backDir, location.hash, location.search);
  });
}

// The strip, its count and the hidden strip's pill leave archived sessions
// out; the all view shows them with "include archived". allSessions keeps
// them all (parent chips, the open session).
function shownSessions() {
  return listedSessions(allSessions, false);
}

function allViewSessions() {
  return listedSessions(allSessions, $("#includeArchived").checked);
}

function filteredSessions(list) {
  const q = $("#filter").value.trim().toLowerCase();
  if (!q) return list;
  return list.filter(
    (s) =>
      previewForCard(s).toLowerCase().includes(q) ||
      (s.first_preview || "").toLowerCase().includes(q) ||
      s.short_id.toLowerCase().includes(q) ||
      s.id.toLowerCase().includes(q) ||
      s.status.toLowerCase().includes(q) ||
      waitingSearchText(s).includes(q),
  );
}

// A card: the first message as its title, then status, how long ago, owner
// and memories. The id is in the tooltip (and the search) only. A session
// that waits on the user (a question, an approval, a card with actions)
// wears the warning colour and says what for.
// deletable: the all-sessions view's cards get a delete button.
function cardHtml(s, { deletable = false } = {}) {
  const ts = s.updated_at || s.created_at || "";
  const tip = `${s.id} · updated ${ts} · ${s.status}`;
  const preview = escapeHtml(previewForCard(s));
  const memTitle = s.used_memory_names && s.used_memory_names.length ? `mem: ${s.used_memory_names.join(", ")}` : "";
  const ago = relativeTime(ts);
  const timeHtml = ago ? `<span class="time" title="${escapeHtml(new Date(ts).toLocaleString())}">${escapeHtml(ago)}</span>` : "";
  const folder = cardFolder(s.working_directory, scope.projectName);
  const folderHtml = folder ? `<span class="folder" title="${escapeHtml(s.working_directory)}">${escapeHtml(folder)}</span>` : "";
  const archivedHtml = s.archived ? `<span class="archived-badge" title="Archived: hidden from the lists, kept for good">archived</span>` : "";
  const ctx = cardCtxText(s.ctx_pct);
  const ctxHtml = ctx ? `<span class="ctx" title="${escapeHtml(tokensTipText(s.tokens))}">${escapeHtml(ctx)}</span>` : "";
  const waiting = waitingBadge(s);
  const waitingHtml = waiting ? `<span class="attn attn-${waiting.kind}" title="${escapeHtml(waiting.title)}">${escapeHtml(waiting.text)}</span>` : "";
  const dotWord = waiting ? waiting.title : s.status;
  return `<div class="card${s.archived ? " archived" : ""}${waiting ? " waiting" : ""}" data-id="${s.id}" title="${escapeHtml(tip)}${memTitle ? ` · ${escapeHtml(memTitle)}` : ""}"><div class="preview">${preview}</div>${s.recap ? `<div class="recap" title="${escapeHtml(s.recap)}">${escapeHtml(s.recap)}</div>` : ""}<div class="meta"><span class="status dot ${escapeHtml(s.status)}${waiting ? " waiting" : ""}" title="${escapeHtml(dotWord)}" aria-label="${escapeHtml(dotWord)}"></span>${waitingHtml}${timeHtml}${ctxHtml}${folderHtml}${parentChipHtml(s)}${ownerBadgeHtml(s)}${archivedHtml}${s.used_memory_names && s.used_memory_names.length ? `<span title="${escapeHtml(s.used_memory_names.join(", "))}">mem ${s.used_memory_names.length}</span>` : ""}</div>${deletable ? `<button type="button" class="card-del" data-del="${escapeHtml(s.id)}" title="Delete session" aria-label="Delete session ${escapeHtml(s.short_id)}">\u2715</button>` : ""}</div>`;
}

// A delegated session's `↳ <parent>` chip; the parent's preview is the tooltip.
function parentChipHtml(s) {
  const chip = delegatedBy(s.parent_id, allSessions.find((x) => x.id === s.parent_id) || null);
  return chip ? `<span class="parent" title="${escapeHtml(chip.title)}">${escapeHtml(chip.text)}</span>` : "";
}

function ownerBadgeHtml(s) {
  const badge = ownerBadge(s.owner, s.id);
  return badge ? `<span class="owner ${badge.kind}" title="${escapeHtml(badge.title)}">${escapeHtml(badge.text)}</span>` : "";
}

// The strip's card count follows the window: more cards on wide screens
// (each capped at 440 px) instead of 3 stretched ones. main's 16 px padding
// sits on both sides; measuring main works while the strip is hidden too.
let stripCols = 3;
function fitStripColumns() {
  stripCols = stripColumns(topStripEl.parentElement.clientWidth - 32);
  topStripEl.style.setProperty("--strip-cols", stripCols);
}

// The order a list draws its cards in: the sessions that wait on the user
// first (waitingFirst), back to their place once answered. Never under the
// pointer, though: while it is over the list the order last drawn holds,
// and its leaving draws the list again.
const drawnOrder = new Map(); // list element → ids in the order last drawn
const heldLists = new Set(); // lists drawn in a held order
const canHover = globalThis.matchMedia?.("(hover: hover)").matches ?? false;
function listOrder(el, list) {
  const next = waitingFirst(list);
  const held = canHover && el.matches(":hover") ? drawnOrder.get(el) : null;
  const ordered = held ? heldOrder(held, next) : next;
  if (held && ordered.some((s, i) => s !== next[i])) heldLists.add(el);
  else heldLists.delete(el);
  drawnOrder.set(el, ordered.map((s) => s.id));
  return ordered;
}

function stripSessions() {
  return listOrder(topStripEl, shownSessions()).slice(0, stripCols);
}

function render() {
  fitStripColumns();
  renderTop(stripSessions());
  if (allViewOpen()) renderAll();
}

let stripResizeTimer = null;
window.addEventListener("resize", () => {
  clearTimeout(stripResizeTimer);
  stripResizeTimer = setTimeout(() => {
    const before = stripCols;
    fitStripColumns();
    if (stripCols !== before && allSessions.length) renderTop(stripSessions());
  }, 150);
});

function bindCards(container, onPick) {
  container.querySelectorAll(".card[data-id]").forEach((el) => {
    el.addEventListener("click", (e) => {
      const del = e.target.closest(".card-del");
      if (del) {
        e.stopPropagation();
        confirmDelete(del.dataset.del);
        return;
      }
      onPick(el.dataset.id);
    });
    if (selected && el.dataset.id === selected) el.classList.add("active");
  });
}

// The latest sessions (as many as fit), then the way to all of them.
function renderTop(sessions) {
  topStripEl.classList.remove("loading");
  renderStripShow();
  if (scopeError) {
    topStripEl.innerHTML = `<div class="hint scope-error">${escapeHtml(scopeError)} · <a href="${escapeHtml(allScopeHref("", null, location.search))}">show every session</a></div>`;
    return;
  }
  // Only archived sessions: no cards, but the tile stays, the way to them.
  if (!allSessions.length) {
    topStripEl.innerHTML = "";
    return;
  }
  const n = shownSessions().length;
  const count = n || allSessions.length === n
    ? `${n} ${n === 1 ? "session" : "sessions"}`
    : `${allSessions.length - n} archived`;
  const tile = `<div class="strip-side"><button type="button" class="card" id="allTile" title="All sessions, with search">All sessions →<span class="count">${count}</span></button><button type="button" class="strip-toggle" id="stripHide" title="Hide the latest sessions">hide ▴</button></div>`;
  topStripEl.innerHTML = sessions.map((s) => cardHtml(s)).join("") + tile;
  bindCards(topStripEl, select);
  $("#allTile").addEventListener("click", openAllView);
  $("#stripHide").addEventListener("click", () => setStripHidden(true));
}

// The hidden strip's pill: "▾ 5 sessions · ● 1 live · ● 1 waiting",
// following the list.
function renderStripShow() {
  const { count, live, waiting } = stripShowParts(shownSessions());
  const liveHtml = live ? ` · <span class="live"><span class="live-dot" aria-hidden="true"></span>${escapeHtml(live)}</span>` : "";
  const waitingHtml = waiting ? ` · <span class="waiting"><span class="waiting-dot" aria-hidden="true"></span>${escapeHtml(waiting)}</span>` : "";
  $("#stripShow").innerHTML = `<span class="pill-arrow" aria-hidden="true">\u25BE</span> ${escapeHtml(count)}${liveHtml}${waitingHtml}`;
}

// A delegated session sits right after its parent: applied on every
// render, since a hub snapshot hands the list back in the server's order.
function renderAll() {
  const listed = allViewSessions();
  const sessions = listOrder(allListEl, withChildrenAfterParents(filteredSessions(listed)));
  $("#count").textContent = sessions.length === listed.length
    ? `${listed.length}`
    : `${sessions.length} / ${listed.length}`;
  if (!sessions.length) {
    allListEl.innerHTML = `<div class="hint">${listed.length ? "No session matches." : "No sessions yet."}</div>`;
    return;
  }
  allListEl.innerHTML = sessions.map((s) => cardHtml(s, { deletable: true })).join("");
  bindCards(allListEl, (id) => { leaveAllView(sessionHash(id)); select(id); });
}

// Delete a session (the info bar's button, an all-sessions card's ✕) after
// a confirm; the list drops it without a reload. The server stops a live
// worker first and refuses a session a terminal chi has open.
async function confirmDelete(id) {
  const sess = allSessions.find((s) => s.id === id) || { id };
  if (sess.owner === "tui") {
    alert(`Session ${id.slice(0, 8)} is open in a terminal chi; close it there first.`);
    return;
  }
  if (!confirm(deleteConfirmText(sess))) return;
  try {
    await deleteSession(id);
  } catch (e) {
    alert(`Could not delete session ${id.slice(0, 8)}: ${e.message}`);
    if (!eventsControl) refresh();
    return;
  }
  allSessions = allSessions.filter((s) => s.id !== id);
  if (selected === id) clearSelection();
  render();
}

// All sessions: its own view at #/sessions, so the browser's back button
// leaves it. Opened from the page, it closes with history.back().
let allViewPushed = false;
function allViewOpen() {
  return location.hash === ALL_SESSIONS_HASH;
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
    leaveAllView(sessionHash(selected));
  }
}
// Leave all sessions for a place of our own (a picked session, a new chat):
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
function selectFromHash() {
  const id = sessionIdFromHash(location.hash);
  if (id && id !== selected) select(id);
}
function applyView() {
  const open = allViewOpen();
  if (!open) {
    allViewPushed = false;
    topStripEl.scrollLeft = 0; // a phone's strip scrolls sideways to the tile
  }
  document.body.classList.toggle("all-view", open);
  if (open) {
    // The list is live; only its order can lag (upserts keep cards in
    // place), so the all view opens in the server's order.
    allSessions = sortedByUpdated(allSessions);
    renderAll();
    if (!eventsControl) refresh();
    $("#filter").select();
  }
}
window.addEventListener("hashchange", () => {
  applyView();
  selectFromHash();
});
$("#allBack").addEventListener("click", closeAllView);

// A phone's composer fits a few words and has no Shift+Enter: the short
// placeholder there.
const narrowScreen = window.matchMedia("(max-width: 600px)");
narrowScreen.addEventListener("change", () => updateComposerMode());
function setPlaceholder(long, short) {
  promptEl.placeholder = narrowScreen.matches ? short : long;
}

// The key hint under the composer (shown while it has focus).
const SEND_HINT = "Enter to send · Shift+Enter for a newline · ↑ history";

// While a turn runs, Send still sends: the prompt merges into the turn at
// its next step (steering). Cancel is its own button then.
function updateComposerMode() {
  document.body.classList.toggle("has-session", !!selected);
  if (selected) modelPicker.close();
  const running = turnRunning && !!selected;
  cancelBtn.style.display = running ? "" : "none";
  if (running) {
    setPlaceholder("Running… a message now steers this turn (Enter to send)", "Running… a message steers it");
    composeHintEl.textContent = SEND_HINT;
    actionBtn.textContent = "Send";
    emptyEl.classList.add("hidden");
    return;
  }
  if (!selected) {
    setPlaceholder("Ask chi anything…", "Ask chi anything…");
    composeHintEl.textContent = "Enter to start · Shift+Enter for a newline";
    actionBtn.textContent = "Start";
    actionBtn.disabled = false;
    emptyEl.classList.remove("hidden");
    historyEl.innerHTML = "";
    updateInfoBar();
  } else if (current.owner === "tui") {
    setPlaceholder("A terminal chi owns this session and doesn't share it — run it with chi --shared to send from here", "A terminal chi owns this session");
    composeHintEl.textContent = "";
    actionBtn.textContent = "Send";
    actionBtn.disabled = true;
    emptyEl.classList.add("hidden");
  } else {
    setPlaceholder("Message chi…", "Message chi…");
    composeHintEl.textContent = SEND_HINT;
    actionBtn.textContent = "Send";
    actionBtn.disabled = false;
    emptyEl.classList.add("hidden");
  }
}

function setTurnRunning(running) {
  turnRunning = !!running;
  updateComposerMode();
  updateInfoBar();
}

// Session status is turn state (idle/running): follow the live stream in the
// info bar and the session's card without a refetch.
function setLiveStatus(status) {
  current.status = status;
  const i = allSessions.findIndex((s) => s.id === selected);
  if (i >= 0) {
    // Its card gets the new dot and time; it keeps its place until the next
    // snapshot or the all view re-sorts (no card jumping under the pointer;
    // a session event replaces it in place too, see sessions_list.js).
    allSessions[i] = withLiveStatus(allSessions[i], status);
    render();
  }
  updateInfoBar();
}

// Plugins' slow setup still running in the open session's worker (chi.init),
// over the composer; a done line fades (init_row.js).
const initRowEl = $("#initRow");
const initTasks = newInitTasks();
function renderInitRow() {
  initRowEl.innerHTML = initRowHtml(initTasks);
  initRowEl.hidden = initTasks.size === 0;
}
function onInitEvent(type, data) {
  const done = applyInitEvent(initTasks, type, data);
  renderInitRow();
  if (!done) return;
  const session = selected;
  setTimeout(() => {
    if (session !== selected) return;
    initRowEl.querySelector(`.init-task.done[data-id="${CSS.escape(done)}"]`)?.classList.add("fading");
    setTimeout(() => {
      if (session !== selected) return;
      dropDone(initTasks, done);
      renderInitRow();
    }, 400);
  }, DONE_MS);
}

// Forget what the info bar, composer and command list knew about the open
// session; select() and clearSelection() both start from here, so a field
// the previous session set (its "delegated by" parent, its commands) never
// shows for the next one.
function resetSessionState() {
  current = emptySessionState();
  commandList.close();
}

function clearSelection() {
  selected = null;
  seedInitTasks(initTasks, []);
  renderInitRow();
  setSessionHash(null);
  document.querySelectorAll(".card").forEach((el) => el.classList.remove("active"));
  resetSessionState();
  clearTimingInterval();
  liveTurnTimingEl = null;
  liveTurnId = null;
  setTurnRunning(false);
  closeStream();
  setMarkdownWarning(null);
  updateComposerMode();
  updateInfoBar();
  updateFirstPeek();
  promptEl.focus();
}

// A short line on the start page (the open session went away); gone at the
// next session or keystroke.
const noticeEl = $("#notice");
function showNotice(text) {
  noticeEl.textContent = text;
  noticeEl.hidden = false;
}
function clearNotice() {
  noticeEl.hidden = true;
  noticeEl.textContent = "";
}
promptEl.addEventListener("input", clearNotice);

// The open session no longer exists: back to the start page, saying why.
function leaveGoneSession(id, why) {
  if (selected !== id) return;
  clearSelection();
  showNotice(goneSessionNotice(id, why));
}

async function select(id) {
  clearNotice();
  selected = id;
  setSessionHash(id);
  document.querySelectorAll(".card").forEach((el) =>
    el.classList.toggle("active", el.dataset.id === id),
  );
  historyEl.innerHTML = `<div class="hint">Loading…</div>`;
  emptyEl.classList.add("hidden");
  closeStream();
  resetSessionState();
  resetTurnView();
  updateFirstPeek();
  updateInfoBar();
  updateComposerMode();
  await resync();
  promptEl.focus();
}

// Clear everything that belongs to one turn's rendering.
function resetTurnView() {
  closeStream();
  clearTimingInterval();
  liveTurnTimingEl = null;
  liveTurnId = null;
  questionCards.removeQuestion();
  questionCards.forgetContinue();
  unmatchedMerge = false;
  setTurnRunning(false);
  releaseDisplayWait();
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
  const id = selected;
  if (!id) return;
  resyncsInFlight += 1;
  let data;
  try {
    try {
      data = await getSession(id, { parts: true });
    } catch (e) {
      if (e.status === 404) return leaveGoneSession(id, "not_found");
      if (id === selected) historyEl.innerHTML = `<div class="hint">Error: ${escapeHtml(e.message)}</div>`;
      return;
    }
    if (id !== selected) return;
    releaseDisplayWait();
    resetTurnView();
    renderSessionView(data);
    // Preview is read-only: a worker is woken only by POST /turn, so attach
    // only when a live bridge exists.
    selectSeq = typeof data.last_event_seq === "number" ? (data.last_event_id || data.last_event_seq) : null;
    if (selectSeq !== null) startStream(id, selectSeq);
    else if (endText) addEndBubble(endText);
  } finally {
    resyncsInFlight -= 1;
    if (resyncsInFlight === 0 && resyncAgain) {
      resyncAgain = false;
      if (id === selected && !(streamControl && streamControl.live)) resync();
    }
  }
}

// A session view: its messages, then the turn in progress and the queued
// prompts (a live worker's snapshot) replayed through the stream handlers,
// then a pending question.
function renderSessionView(data) {
  const s = data.session;
  setMarkdownWarning(data.markdown_warning);
  current.status = s.status;
  current.model = s.model_name;
  current.served = s.served_model ? [s.served_model, s.served_model_for] : null;
  current.dir = s.working_directory;
  current.owner = s.owner || null;
  current.timing = normalizeTiming(data.timing);
  turnsEnded = current.timing.turnRecords.length;
  const activeTurnId = current.timing.activeTurn?.id || null;
  // The saved fill, so a reloaded or stopped session shows it before its
  // next turn (a running turn's replay below streams over it).
  const savedPct = savedCtxPct(data.timing?.context);
  if (savedPct !== null) current.ctxPct = savedPct;
  if (data.timing?.context?.window_tokens) current.ctxWindow = data.timing.context.window_tokens;
  current.firstPreview = s.first_preview || previewForCard(s);
  current.usedMemories = s.used_memory_names || [];
  current.preloadedMemories = s.preloaded_memory_names || [];
  current.mutedMemories = s.muted_memory_names || [];
  current.parentId = s.parent_id || null;
  current.commands = Array.isArray(data.commands) ? data.commands : [];
  if (data.messages && data.messages.length) {
    const first = data.messages.find((m) => m.role === "user");
    if (first && first.content) current.firstPreview = normalize(first.content).slice(0,80) + (normalize(first.content).length>80?"…":"");
    renderHistory(data.messages);
  } else {
    renderHistory(data.history || []);
    if (!current.firstPreview && data.history && data.history.length) {
      const txt = normalize(String(data.history[0]||"")).slice(0,80);
      if(txt) current.firstPreview = txt;
    }
  }
  // A failed turn's prompt went back to the user: shown after the
  // conversation, marked failed, as it was live (prompt_restored).
  if (data.failed_turn) {
    makeUserBubble(data.failed_turn.prompt, { state: "failed" }).dataset.failedTurn = "1";
    addEndBubble(failedTurnText(data.failed_turn));
  }
  seedSeenFromDom();
  seedInitTasks(initTasks, data.init_tasks);
  renderInitRow();
  // A guardrail file that failed to load, announced before this page
  // joined: where it came (the snapshot's cards), else at the end.
  const loadWarned = (label) => (data.cards || []).some((c) => c?.type === "guardrail_warning" && (c.label || "guardrails") === label);
  if (!loadWarned("guardrails")) showGuardrailWarning(data.guardrail_warning);
  if (!loadWarned("plugins")) showGuardrailWarning(data.plugin_warning, "plugins");
  // The recap saved with the session (also a stopped one's), else a live
  // worker's from before saved_recap existed.
  if (data.saved_recap) showRecap(data.saved_recap.text, data.saved_recap.turns_since);
  else showRecap(data.recap);
  // A live worker's last cards and between-turns notices, where they
  // arrived; the running turn's go into its step once it is drawn.
  const snapshotCards = splitSnapshotCards(data.cards);
  placeSnapshotCards(snapshotCards.placed);
  const replay = snapshotEvents({
    current_turn: data.current_turn,
    queued: data.queued,
    started_at: current.timing.activeTurn?.started_at,
  });
  replay.forEach((event) => streamHandlers[event.type]?.(event));
  if (!data.current_turn) {
    setTurnRunning(current.status === "running");
    if (turnRunning && current.timing.activeTurn?.started_at) startLiveTurnTiming(current.timing.activeTurn.started_at, activeTurnId);
  } else if (turnRunning) {
    // The replayed turn_started carries no id: the running turn's record's.
    liveTurnId = activeTurnId;
  }
  turnDom.flush();
  snapshotCards.current.forEach((card) => upsertCard(card));
  snapshotCards.during.forEach((card) => upsertCard(card));
  // A question the worker is blocked on (also after a reload).
  if (data.pending_question && data.pending_question.id && data.pending_question.status === "pending") {
    questionCards.renderQuestion(data.pending_question);
    // The turn's replay drew it as asked; the snapshot knows whether it is
    // relayed to the parent now.
    questionCards.markRelayed(data.pending_question.id, data.pending_question.relayed_to || null);
  }
  // A turn ran out of iterations and waits for a yes or no.
  if (data.continue_offer) questionCards.renderContinue(data.continue_offer);
  updateInfoBar();
  updateFirstPeek();
  updateComposerMode();
}

function renderHistory(items) {
  if (!items.length) {
    historyEl.innerHTML = `<div class="hint">No output yet. Send a message.</div>`;
    return;
  }
  if (typeof items[0] === "object" && items[0].role) {
    historyEl.innerHTML = turnHistoryHtml(items, current.timing, { thumbs: (images) => thumbsHtml(selected, images) });
  } else {
    historyEl.innerHTML = items.map((c) => `<div class="bubble output">${escapeHtml(c)}</div>`).join("");
  }
  historyEl.scrollTop = historyEl.scrollHeight;
}

function setMarkdownWarning(warning) {
  if (!warning) {
    markdownWarningEl.hidden = true;
    markdownWarningEl.textContent = "";
    return;
  }
  markdownWarningEl.textContent = warning;
  markdownWarningEl.hidden = false;
}

// The turn-end re-read (turn_completed): the final answer's rendered
// markdown, the status and the timing. Kept as turnEndRead, so an
// answer_display re-read waits for it.
let turnEndRead = Promise.resolve();
// The wait of a turn_completed with display_pending for its answer_display
// (turn_events.js displayWait). The worker may die in between and never send
// one, so workerGone (through resetTurnView) and a re-render release it as
// well as its own timeout: it must never hold the turn's answer forever.
let displayPending = null;

function releaseDisplayWait() {
  displayPending?.finish();
  displayPending = null;
}

async function readTurnEnd() {
  if (!selected) return;
  const id = selected;
  // The line and the turn this read is for, before the await: a turn
  // queued behind this one may start (a new live line) before it lands.
  const line = { el: liveTurnTimingEl, turnId: liveTurnId };
  try {
    const d = await getSession(id, { tail: true, recent: true, turnId: line.turnId });
    if (id !== selected) return;
    if (d.session) {
      if (Array.isArray(d.session.used_memory_names)) current.usedMemories = d.session.used_memory_names;
      if (d.session.status) current.status = d.session.status;
      if (!(await mergeTurnTiming(id, d.timing))) return;
      finishTurnLine(line);
      setMarkdownWarning(d.markdown_warning);
      if (Array.isArray(d.messages)) applyFinalMarkdown(d.messages);
      updateInfoBar();
      const sess = allSessions.find(s=>s.id===selected);
      if (sess) {
        sess.used_memory_names = current.usedMemories.slice();
        sess.status = current.status;
      }
      render();
      document.querySelectorAll(".card").forEach(el=>el.classList.toggle("active", el.dataset.id===selected));
    }
  } catch(_){}
}

function applyFinalMarkdown(messages) {
  const message = [...messages].reverse().find(
    (item) => item?.role === "assistant" && typeof item.html === "string",
  );
  if (!message) return;

  const bubble = findInTurnRoots(".bubble.output")
    .reverse()
    .find((item) => showsAnswer(item, message, normalize));
  if (!bubble) return;

  bubble.classList.add("markdown");
  bubble.setAttribute(COPY_SOURCE_ATTR, copySource(message));
  bubble.innerHTML = message.html;
}

function seedSeenFromDom() {
  seenContent = new Set();
  findInTurnRoots(".bubble").forEach((b) => {
    const k = normalize(b.textContent);
    if (k) seenContent.add(k);
  });
}

// Sticky-follow scroll: only auto-scroll to the bottom while the user is
// already near it; never yank them back down mid-read. Capture the decision
// BEFORE any DOM mutation that grows the content (new chunk / row / thinking
// delta), so the gap measured is the one the user was sitting at. While the
// stage holds a turn its rows go there: nothing it does moves the history.
function isNearBottom() {
  return !turnDom.holds?.() && atHistoryEnd();
}

function atHistoryEnd() {
  const { scrollHeight, scrollTop, clientHeight } = historyEl;
  return shouldFollowScroll({ scrollHeight, scrollTop, clientHeight });
}

function appendChunk(text) {
  if (!text) return;
  const k = normalize(text);
  if (!k || seenContent.has(k)) return;
  const follow = isNearBottom();
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  const div = document.createElement("div");
  div.className = "bubble output";
  div.textContent = text;
  appendToHistory(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

function addEndBubble(text) {
  const div = document.createElement("div");
  div.className = "bubble cancel";
  div.textContent = text;
  appendToHistory(div);
  if (!turnDom.holds?.()) historyEl.scrollTop = historyEl.scrollHeight;
}

// The notice of a turn that ended with no answer (turn_summary.empty_answer),
// as a reload draws it (turn_view.js EMPTY_ANSWER_CLASS).
function emptyAnswerEl(emptyAnswer) {
  const el = document.createElement("div");
  el.className = EMPTY_ANSWER_CLASS;
  el.textContent = emptyAnswerLine(emptyAnswer);
  return el;
}

// Everything a turn's end (completed, canceled, failed) closes: then its
// end line (+endText+, the cancel or failed line), then the step cards that
// left the collapsed block (card.js leavesBlock), where a reload puts them.
function endTurnView(kind, endText = null, { emptyAnswer = null } = {}) {
  setTurnRunning(false);
  // Every ended turn has a record (completed, canceled, failed); a worker
  // gone mid-turn is re-rendered (resync), which counts again.
  if (kind !== "gone") turnsEnded += 1;
  // A completed turn with no answer: its notice where the answer goes
  // (the turn view places it), else after the turn; before the timing.
  const endNote = emptyAnswer ? emptyAnswerEl(emptyAnswer) : null;
  const kept = turnDom.turnEnded({ kind, endNote, emptyAnswer: !!emptyAnswer }) || [];
  if (endNote && !endNote.isConnected) appendToHistory(endNote);
  finishLiveTurnTiming(null, { canceled: kind === "canceled" });
  if (endText) addEndBubble(endText);
  if (kept.length) {
    kept.forEach((el) => appendToHistory(el));
    if (!turnDom.holds?.()) historyEl.scrollTop = historyEl.scrollHeight;
  }
  // The question dies with its turn (the worker stopped waiting).
  if (questionCards.pendingQuestion()) questionCards.resolveQuestion(questionCards.pendingQuestion().id, { cancelled: true, reason: "turn ended" });
}

// ── Prompt bubbles ─────────────────────────────────────────────────────────
// Every client's prompts, keyed by enqueued_id: queued (badge) until their
// turn starts, or steered when merged into a running turn. This tab's own
// prompts are echoed at send (data-own) and tagged by their turn_enqueued.

const BADGES = { queued: "queued", steered: "steered", failed: "failed" };

function makeUserBubble(prompt, { state = null, label = null, enqueuedId = null, own = false, images = null } = {}) {
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  const div = document.createElement("div");
  div.className = "bubble user";
  div.dataset.userContent = normalize(prompt);
  div.setAttribute(COPY_SOURCE_ATTR, prompt);
  if (own) div.dataset.own = "1";
  if (enqueuedId) div.dataset.enqueuedId = enqueuedId;
  if (label) {
    const from = document.createElement("span");
    from.className = "origin-label";
    from.textContent = label;
    div.appendChild(from);
  }
  const message = document.createElement("div");
  message.className = "user-message";
  message.innerHTML = userBodyHtml(prompt) + thumbsHtml(selected, images);
  div.appendChild(message);
  setBubbleState(div, state);
  const follow = isNearBottom();
  appendToHistory(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
  return div;
}

function setBubbleState(bubble, state) {
  bubble.classList.remove("queued", "steered", "failed");
  bubble.querySelector(".state-badge")?.remove();
  if (!BADGES[state]) {
    delete bubble.dataset.userState;
    return;
  }
  bubble.classList.add(state);
  bubble.dataset.userState = state;
  const badge = document.createElement("span");
  badge.className = "state-badge";
  badge.textContent = BADGES[state];
  bubble.appendChild(badge);
}

function bubbleById(enqueuedId) {
  if (!enqueuedId) return null;
  return findInTurnRoots(".bubble.user[data-enqueued-id]").find(
    (el) => el.dataset.enqueuedId === enqueuedId,
  ) || null;
}

// This tab's oldest untagged echo, preferring one with the same text.
function untaggedOwnBubble(prompt) {
  const echoes = findInTurnRoots(".bubble.user[data-own]:not([data-enqueued-id])");
  const text = normalize(prompt || "");
  return echoes.find((el) => el.dataset.userContent === text) || echoes[0] || null;
}

// Returns the bubble of the turn a turn_started starts (the stage takes it
// into its prompt line), else null.
function applyPromptOps(event) {
  const ops = promptOps(event, { myId: clientId, known: (id) => !!bubbleById(id), unmatchedMerge });
  if (event.type === "input_merged") unmatchedMerge = false;
  if (event.type === "pending_input_merged") unmatchedMerge = false;
  let started = null;
  for (const op of ops) {
    if (op.op === "add") {
      const bubble = makeUserBubble(op.prompt, { state: op.state, label: op.label, enqueuedId: op.enqueuedId, images: op.images });
      if (op.state === "started") started = bubble;
    } else if (op.op === "tag") {
      if (bubbleById(op.enqueuedId)) continue;
      const echo = untaggedOwnBubble(op.prompt);
      if (echo) echo.dataset.enqueuedId = op.enqueuedId;
      // Re-rendered from a snapshot: the echo is gone, the prompt still queued.
      else makeUserBubble(op.prompt, { state: "queued", own: true, enqueuedId: op.enqueuedId, images: op.images });
    } else if (op.op === "start") {
      const bubble = bubbleById(op.enqueuedId) || untaggedOwnBubble(op.prompt);
      // A resync (a new worker woken by this page's send) re-rendered the
      // history and took the echo with it: draw the prompt again.
      if (!bubble) started = makeUserBubble(op.prompt, { own: true, enqueuedId: op.enqueuedId, images: op.images });
      else {
        if (op.enqueuedId) bubble.dataset.enqueuedId = op.enqueuedId;
        setBubbleState(bubble, null);
        started = bubble;
      }
    } else if (op.op === "steer") {
      const bubble = bubbleById(op.enqueuedId);
      if (bubble) setBubbleState(bubble, "steered");
      else unmatchedMerge = true;
    }
  }
  return started;
}

// ── Idle recap ─────────────────────────────────────────────────────────────
// A summary the worker writes after a quiet stretch or as it leaves: shown at
// the end of the history. A turn starting leaves it in place, marked
// earlier; only a new recap replaces it.

function showRecap(text, turnsSince = 0) {
  if (!text) return;
  removeRecap();
  const details = document.createElement("details");
  details.className = "bubble recap";
  if (turnsSince > 0) details.classList.add("stale");
  details.open = true;
  const summary = document.createElement("summary");
  summary.textContent = recapLabel(turnsSince);
  const body = document.createElement("div");
  body.className = "recap-body";
  body.textContent = text;
  details.appendChild(summary);
  details.appendChild(body);
  // A stale one sits where it was written, above the turns it doesn't cover.
  // Never in the stage: a recap is between turns.
  const before = recapPlace(turnPromptBubbles(), turnsSince);
  keepFollowing(historyEl, () => (before ? historyEl.insertBefore(details, before) : appendAboveLiveTiming(historyEl, details, liveTurnTimingEl)));
}

// A turn started: the recap describes the chat before it.
function markRecapStale() {
  historyEl.querySelectorAll(".bubble.recap:not(.stale)").forEach((el) => {
    el.classList.add("stale");
    const summary = el.querySelector("summary");
    if (summary) summary.textContent = recapLabel(0, true);
  });
}

// A guardrail hook or rule file that failed to load (once per worker), or
// a bundle's plugin (+label+ "plugins").
// +before+: the element it goes above (a snapshot's), else the end.
function showGuardrailWarning(text, label = "guardrails", { before = null } = {}) {
  if (!text) return;
  const el = document.createElement("div");
  el.className = "bubble guardrail-warning";
  el.textContent = `${label}: ${text}`;
  const follow = isNearBottom();
  if (before) historyEl.insertBefore(el, before);
  else appendToHistory(el);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

// A hook's line to the user (event[:notify]): "<bundle>: text", in the
// warning colour for level warn.
// +before+: the element it goes above (a snapshot's notice), else the end.
// A plugin's steers (pending_input_merged's steers): a row of the running
// turn's step, else (no turn runs) a bubble.
function showSteers(steers) {
  for (const steer of steers || []) {
    if (turnDom.steer(steer)) continue;
    removeHintIfEmpty();
    const holder = document.createElement("div");
    holder.innerHTML = steerRowHtml(steer, { bubble: true });
    const follow = isNearBottom();
    appendToHistory(holder.firstChild);
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
  }
}

function showHookNotice(data, { before = null } = {}) {
  removeHintIfEmpty();
  const el = document.createElement("div");
  el.className = "bubble hook-notice" + (data.level === "warn" ? " warn" : "");
  el.textContent = data.line || `${hookNoticeLabel(data.hook)}: ${data.text || ""}`;
  const follow = isNearBottom();
  if (before) historyEl.insertBefore(el, before);
  else appendToHistory(el);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

// ── plugin cards ───────────────────────────────────────────────────────────
// A plugin's card (docs/plugins.md, Cards): a glass card between turns, or
// a row of the running turn's step. The same id updates the card in place.
// An action button runs its command line in the session (sendCommand), as
// if typed.

function cardElement(id) {
  if (!id) return null;
  return findInTurnRoots(".plugin-card").find((el) => el.dataset.cardId === String(id)) || null;
}

// A notice is a <details> (a one-line row that opens), a card a <div>: a
// card that turns into the other kind (btw's "thinking…" → its answer) is
// drawn on a new element in its place. Returns the element drawn.
function drawCard(el, card) {
  const notice = isNoticeCard(card);
  if (el.tagName !== (notice ? "DETAILS" : "DIV")) {
    const fresh = document.createElement(notice ? "details" : "div");
    el.replaceWith(fresh);
    el = fresh;
  }
  el.className = cardClass(card);
  el.dataset.cardId = card.id;
  // A running turn's own card (the stage's status waits on one that asks).
  if (card.in_turn) el.dataset.inTurn = "1";
  else delete el.dataset.inTurn;
  if (notice) {
    const open = el.open;
    el.innerHTML = noticeInnerHtml(card);
    el.open = open;
  } else if (card.body_html === undefined && el.dataset.body === String(card.body ?? "") && el.querySelector(".card-body")) {
    // The same body again from the stream: keep the rendered one.
    const body = el.querySelector(".card-body").innerHTML;
    el.innerHTML = cardInnerHtml({ ...card, body_html: body });
  } else {
    el.innerHTML = cardInnerHtml(card);
  }
  el.dataset.body = String(card.body ?? "");
  return el;
}

// Show +card+: update the one with its id where it is, else add it (a
// running turn's card as a row of its step; else before +before+ or at the
// end of the history). A running turn's card with actions asks the user
// something (check-in's Nudge / Keep going / Stop): it goes under the turn's
// block, not into a step that collapses when the next one starts.
function upsertCard(card, { before = null } = {}) {
  if (!card || !card.id) return;
  const existing = cardElement(card.id);
  if (existing) {
    const drawn = drawCard(existing, card);
    drawn.classList.add("card-updated");
    setTimeout(() => drawn.classList.remove("card-updated"), 900);
    return;
  }
  removeHintIfEmpty();
  const el = drawCard(document.createElement(isNoticeCard(card) ? "details" : "div"), card);
  const asks = (card.actions || []).some((a) => a && a.command);
  if (card.in_turn && !before && !asks && turnDom.card(el)) return;
  const follow = isNearBottom();
  if (before) historyEl.insertBefore(el, before);
  else appendToHistory(el);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

// A snapshot's cards and notices, each above the first turn after it; a
// turn's own notice where it showed live (placeTurnNotice).
function placeSnapshotCards(entries) {
  const users = turnPromptBubbles();
  for (const entry of entries) {
    const before = cardPlace(users, entry);
    if (isCard(entry)) upsertCard(entry, { before });
    else if (entry.type === "question") placeResolvedQuestion(entry, before);
    else if (entry.type === "guardrail_warning") showGuardrailWarning(entry.message, entry.label || "guardrails", { before });
    else if (entry.in_turn) placeTurnNotice(entry, before);
    else if (entry.type === "hook_notice") showHookNotice(entry, { before });
  }
}

// A finished turn's row, a hook's notice or the loop's asking again
// (+before+: the next turn's prompt, or null for the last turn): a row of
// its step, above the row of the call it came before, as live; else (a
// plain answer, a step the history doesn't have) a bubble before the
// turn's answer, or before its timing line when it has none.
function placeTurnNotice(entry, before) {
  const line = noticeLine(entry);
  const turnEls = reloadedTurnEls(before);
  const place = turnNoticePlace(entry);
  const block = turnEls.find((el) => el.matches(".turn-work"));
  const step = place && block ? block.querySelectorAll(":scope > .gen")[place.step] : null;
  if (!step) {
    showHookNotice({ ...entry, line }, { before: turnAnswerEl(turnEls) || before });
    return;
  }
  const el = document.createElement("div");
  el.className = "hook-notice" + (entry.level === "warn" ? " warn" : "");
  el.textContent = line;
  let body = step.querySelector(":scope > .activity-body");
  if (!body) {
    body = document.createElement("div");
    body.className = "activity-body";
    step.appendChild(body);
  }
  const row = [...body.children].find((r) => r.dataset.key === place.rowKey);
  body.insertBefore(el, row || null);
}

// A prompt that started a turn: not a line steered into a running one.
const TURN_PROMPT = ".bubble.user:not(.steered)";

// The history's turn prompts, oldest first (what turns_since counts).
function turnPromptBubbles() {
  return [...historyEl.querySelectorAll(`:scope > ${TURN_PROMPT}`)];
}

// The elements of the reloaded turn that ends before +before+ (the next
// turn's prompt, or null for the last turn), its prompt first.
function reloadedTurnEls(before) {
  const turnEls = [];
  for (let el = before ? before.previousElementSibling : historyEl.lastElementChild; el; el = el.previousElementSibling) {
    turnEls.unshift(el);
    if (el.matches(TURN_PROMPT)) break;
  }
  return turnEls;
}

// What goes after a reloaded turn's own rows and cards: its answer, else
// its timing line; null when it has neither.
function turnAnswerEl(turnEls) {
  return turnEls.filter((el) => el.matches(".bubble.output, .empty-answer")).pop() || turnEls.find((el) => el.matches(".turn-timing")) || null;
}

// A finished turn's question (the snapshot's cards keep it with its
// answer): the card as it was left live, resolved, before the lines the
// user sent into the turn after it (a steered bubble's data-step: the step
// that read it) and the turn's answer. A pending one is the running turn's
// (pending_question draws it).
function placeResolvedQuestion(entry, before) {
  const pq = entry.pending_question;
  if (!pq?.id || !(entry.answer || entry.cancelled)) return;
  questionCards.renderQuestion(pq);
  const card = questionCards.questionCard();
  if (!card || card.dataset.qid !== String(pq.id)) return;
  questionCards.resolveQuestion(pq.id, { answer: entry.answer || null, cancelled: !!entry.cancelled, reason: entry.reason || "" });
  const turnEls = reloadedTurnEls(before);
  const asked = Number(entry.iteration) || 1;
  const later = turnEls.find((el) => el.matches(".bubble.user.steered") && Number(el.dataset.step) > asked);
  historyEl.insertBefore(card, later || turnAnswerEl(turnEls) || before);
}

// A live card's body comes as text; the worker's snapshot (through the
// server) has it rendered. One re-read for a burst of cards.
let cardBodiesTimer = null;
function refreshCardBodies() {
  clearTimeout(cardBodiesTimer);
  const id = selected;
  cardBodiesTimer = setTimeout(async () => {
    try {
      const data = await getSession(id, { cards: true });
      if (id !== selected) return;
      for (const card of data.cards || []) {
        const el = card.type === "card" && cardElement(card.id);
        const body = el && el.querySelector(".card-body");
        if (body && typeof card.body_html === "string" && el.dataset.body === String(card.body ?? "")) body.innerHTML = card.body_html;
      }
    } catch (_) {}
  }, 150);
}

function onCardAction(e) {
  const button = e.target.closest(".plugin-card .card-action");
  if (!button || !selected) return;
  const card = button.closest(".plugin-card");
  const err = card.querySelector(".card-error");
  err.classList.add("hidden");
  button.disabled = true;
  sendCommand(selected, button.dataset.command, { clientId, card: true })
    .then(() => {
      // The command woke the worker: follow its stream if none is open.
      if (!streamControl?.live) startStream(selected, selectSeq ?? 0);
    })
    .catch((error) => {
      err.textContent = error.message;
      err.classList.remove("hidden");
    })
    .finally(() => { button.disabled = false; });
}
turnRoots().forEach((root) => root.addEventListener("click", onCardAction));

function removeRecap() {
  historyEl.querySelectorAll(".bubble.recap").forEach((el) => el.remove());
}

// The info bar's "copy chi --attach": the full id, which the page shows
// only short; "copied ✓" for 2 s.
let attachCopiedAt = 0;
infoTextEl.addEventListener("click", (e) => {
  if (e.target.closest(".worker-restart")) restartWorker();
});
infoTextEl.addEventListener("click", async (e) => {
  if (!e.target.closest(".copy-attach") || !selected) return;
  if (!(await copyText(`chi --attach ${selected}`))) return;
  attachCopiedAt = Date.now();
  updateInfoBar();
  setTimeout(updateInfoBar, 2000);
});

// The open session's worker runs an older chi than the newest installed:
// a badge, with Restart when the worker can (else the stop command).
function currentWorkerBadge() {
  if (!selected || current.owner !== "worker") return null;
  return workerBadge({ workerVersion: current.workerVersion, features: current.workerFeatures,
                       installed: versions.installed, served: versions.served, sessionId: selected });
}

function workerBadgeHtml() {
  const badge = currentWorkerBadge();
  if (!badge) return "";
  const busy = restartingId === selected;
  const button = badge.restart
    ? `<button type="button" class="worker-restart"${busy ? " disabled" : ""}>${busy ? "restarting…" : "Restart"}</button>`
    : "";
  return `<span class="worker-badge" title="${escapeHtml(badge.title)}">${escapeHtml(badge.text)}${button}</span>`;
}

// Restart: the session moves to a new worker on the newest chi; the page
// follows it (its bridge_up), the composer's draft stays as it is.
async function restartWorker() {
  const badge = currentWorkerBadge();
  if (!badge || !badge.restart || restartingId) return;
  if (!confirm(restartConfirmText(current.workerVersion, badge.newest))) return;
  const id = selected;
  restartingId = id;
  updateInfoBar();
  try {
    const result = await restartSession(id);
    showToast(result.version ? `Restarted on chi ${result.version}` : "Restarting: the new worker is starting");
  } catch (e) {
    showToast(`Can't restart: ${String(e.message).replace(/ \(\d+\)$/, "")}`, null, { sticky: true });
  } finally {
    restartingId = null;
    updateInfoBar();
  }
}

function updateInfoBar() {
  const stopBtn = document.getElementById("infoStopBtn");
  const deleteBtn = document.getElementById("infoDeleteBtn");
  const archiveBtn = document.getElementById("infoArchiveBtn");
  if (deleteBtn) deleteBtn.style.display = selected ? "" : "none";
  if (archiveBtn) {
    archiveBtn.style.display = selected ? "" : "none";
    const archived = selectedArchived();
    archiveBtn.textContent = archived ? "unarchive" : "archive";
    archiveBtn.title = archived ? "Unarchive: back to the lists" : "Archive: hide from the lists, keep for good";
  }
  if (!selected) {
    // The start page hides the info bar (the storage path is on #/sessions).
    infoTextEl.innerHTML = "";
    infoTextEl.title = "";
    if (stopBtn) stopBtn.style.display = "none";
    return;
  }
  if (stopBtn) stopBtn.style.display = canStopSession({ owner: current.owner, streaming: !!streamControl }) ? "" : "none";
  const idShort = selected.slice(0,8);
  const memText = current.usedMemories.length ? current.usedMemories.join(", ") : "—";
  const ctxText = current.ctxPct !== null ? `ctx ${Math.round(current.ctxPct)}%` : "";
  const tokens = current.timing.tokens;
  const ctxTip = tokensTipText(tokens);
  const speedTextNow = lastSpeedText(tokens);
  const avgSpeed = speedText(tokens?.avg_decode_tps, tokens?.tps_source);
  const speedTip = `Decode speed of the last generation${avgSpeed ? `; session average ${avgSpeed}` : ""}`;
  const sessionDuration = currentSessionDuration();
  const timingText = sessionDuration === null ? "" : `session ${formatDuration(sessionDuration)}`;
  const statusClass = current.status ? `status ${escapeHtml(current.status)}` : "status";
  const label = modelLabel(current.model, ...(current.served || []));
  // A delegated session names its parent, as a link to it.
  const parentChip = delegatedBy(current.parentId, allSessions.find((x) => x.id === current.parentId) || null);
  const parentHtml = parentChip ? `<a class="model parent" href="${escapeHtml(sessionHash(current.parentId))}" title="${escapeHtml(parentChip.title)}">delegated by ${escapeHtml(String(current.parentId).slice(0, 8))}</a>` : "";
  const attachCmd = `chi --attach ${selected}`;
  const copied = Date.now() - attachCopiedAt < 2000;
  const copyHtml = `<button type="button" class="copy-attach" title="Copy &quot;${escapeHtml(attachCmd)}&quot; to attach a terminal">${copied ? "copied ✓" : "copy chi --attach"}</button>`;
  const metaHtml = `<div class="meta"><span class="id" title="${escapeHtml(selected)}">${escapeHtml(idShort)}</span>${copyHtml}<span class="${statusClass}">${escapeHtml(current.status||"")}</span><span class="model${label.mismatch ? " served-mismatch" : ""}" title="${escapeHtml(label.title)}">${escapeHtml(label.text)}</span>${parentHtml}<span class="dir" title="${escapeHtml(current.dir||"")}">${escapeHtml((current.dir||"").slice(0,48))}</span>${ctxText ? `<span class="model ctx" title="${escapeHtml(ctxTip)}">${escapeHtml(ctxText)}</span>` : ""}${speedTextNow ? `<span class="model speed" title="${escapeHtml(speedTip)}">${escapeHtml(speedTextNow)}</span>` : ""}${timingText ? `<span class="model">${escapeHtml(timingText)}</span>` : ""}${workerBadgeHtml()}</div>`;
  const previewHtml = `<div class="preview-line"><span class="preview">${escapeHtml(current.firstPreview || "—")}</span> · <span class="mem" title="${escapeHtml(current.usedMemories.join(", "))}">mem: ${escapeHtml(memText)}</span></div>`;
  infoTextEl.innerHTML = metaHtml + previewHtml;
  infoTextEl.title = memoriesTooltip(current.usedMemories, current.preloadedMemories, current.mutedMemories);
}

// `memories: a, b · preloaded: c · muted: d`: the used memories always,
// the session's --memory and --mute lists only when there are any.
function memoriesTooltip(used, preloaded, muted) {
  const parts = [`memories: ${(used || []).join(", ") || "—"}`];
  if (preloaded && preloaded.length) parts.push(`preloaded: ${preloaded.join(", ")}`);
  if (muted && muted.length) parts.push(`muted: ${muted.join(", ")}`);
  return parts.join(" · ");
}

function currentSessionDuration() {
  if (turnRunning && current.timing.startedAt) {
    return elapsedSince(current.timing.startedAt);
  }
  return current.timing.sessionDurationMs;
}

function clearTimingInterval() {
  if (timingInterval !== null) {
    clearInterval(timingInterval);
    timingInterval = null;
  }
}

let liveTurnNumber = null;

function startLiveTurnTiming(startedAt = new Date().toISOString(), turnId = null) {
  clearTimingInterval();
  current.timing.activeTurn = turnId ? { id: turnId, started_at: startedAt } : { started_at: startedAt };
  liveTurnId = turnId || null;
  // The turns ended so far, so this one comes next.
  liveTurnNumber = turnsEnded + 1;
  liveTurnNote = "";
  liveTurnTimingEl = document.createElement("div");
  liveTurnTimingEl.className = "turn-timing live";
  // The stage's status row while it holds the turn: the line moves into the
  // history with it.
  (turnDom.timingHost?.() || historyEl).appendChild(liveTurnTimingEl);
  updateLiveTiming();
  timingInterval = setInterval(updateLiveTiming, 1000);
}

// The stage takes a running turn's rows (its extras); else the history.
function appendToHistory(el) {
  if (turnDom.place?.(el)) return;
  appendAboveLiveTiming(historyEl, el, liveTurnTimingEl);
}

function updateLiveTiming() {
  const duration = elapsedSince(current.timing.activeTurn?.started_at);
  if (liveTurnTimingEl && duration !== null) {
    liveTurnTimingEl.textContent = turnTimingText(liveTurnNumber, duration, { running: true }) + (liveTurnNote ? ` · ${liveTurnNote}` : "");
  }
  updateInfoBar();
}

// Set (or clear, "") what the running turn waits on.
function setLiveTurnNote(text) {
  if (liveTurnNote === text) return;
  liveTurnNote = text;
  if (current.timing.activeTurn) updateLiveTiming();
}

// A canceled turn's line says so (+canceled+, or its record's status), as
// a reload's does.
function finishLiveTurnTiming(record = null, { canceled = false } = {}) {
  const duration = Number.isFinite(Number(record?.duration_ms))
    ? Number(record.duration_ms)
    : elapsedSince(current.timing.activeTurn?.started_at);
  if (liveTurnTimingEl && duration !== null) {
    liveTurnNote = "";
    liveTurnTimingEl.classList.remove("live");
    const at = record ? current.timing.turnRecords.indexOf(record) : -1;
    liveTurnTimingEl.textContent = turnTimingText(at >= 0 ? at + 1 : liveTurnNumber, duration,
      { canceled: canceled || record?.status === "canceled" });
  }
  current.timing.activeTurn = null;
  clearTimingInterval();
  updateInfoBar();
}

// A turn-end re-read's timing (?tail=1&recent=1: the newest turn's records
// and turn_count) merged into the page's (mergeTiming); when the merge comes
// up short, the whole timing (?timing=1). Never (re)starts live timing: a
// turn that started meanwhile keeps its line and its own active turn.
// @return false when the session changed meanwhile
async function mergeTurnTiming(id, data) {
  const keepActive = () => (turnRunning ? current.timing.activeTurn : null);
  const merged = mergeTiming(current.timing, data);
  current.timing = { ...merged.timing, activeTurn: keepActive() };
  if (merged.short) {
    try {
      const full = await getSession(id, { timing: true });
      if (id !== selected) return false;
      current.timing = { ...normalizeTiming(full.timing), activeTurn: keepActive() };
    } catch (_) {
      if (id !== selected) return false;
    }
  }
  turnsEnded = Math.max(turnsEnded, current.timing.turnRecords.length);
  return true;
}

// Finish the timing line a turn-end read captured (+line+: {el, turnId})
// with that turn's record: its place in the records and its duration (a
// canceled one says so). No id (an older worker's events): the last
// record. No record: the line stays as the turn's end left it. The ticker
// stops only if that line is still the live one.
function finishTurnLine(line) {
  const records = current.timing.turnRecords;
  const record = line.turnId ? records.find((r) => r.id === line.turnId) : records[records.length - 1];
  if (line.el === liveTurnTimingEl) {
    current.timing.activeTurn = null;
    clearTimingInterval();
  }
  const duration = Number(record?.duration_ms);
  if (line.el && record && Number.isFinite(duration)) {
    line.el.classList.remove("live");
    line.el.textContent = turnTimingText(records.indexOf(record) + 1, duration, { canceled: record.status === "canceled" });
  }
  updateInfoBar();
}

function updateFirstPeek() {
  if (current.ctxPct !== null && current.ctxPct > 20 && current.firstPreview) {
    firstPeekEl.textContent = current.firstPreview;
    firstPeekEl.classList.add("visible");
  } else {
    firstPeekEl.textContent = "";
    firstPeekEl.classList.remove("visible");
  }
}

function setUsedMemories(names) {
  current.usedMemories = names.slice();
  updateInfoBar();
  const sess = allSessions.find(s=>s.id===selected);
  if (sess) {
    sess.used_memory_names = current.usedMemories.slice();
    render();
    document.querySelectorAll(".card").forEach(el=>el.classList.toggle("active", el.dataset.id===selected));
  }
}

function startStream(id, fromSeq) {
  if (streamControl) {
    streamControl.close();
    streamControl = null;
  }
  streamControl = openStream(id, fromSeq, streamHandlers, {
    // The stream dropped or never opened: the worker left (idle exit, stop,
    // crash) or is starting. Its cursor means nothing to the next worker
    // (event_seq starts over), so re-read the session once one is live.
    onStreamClosed: () => workerGone(id),
    onStreamError: () => workerGone(id, { opened: false }),
  });
  updateInfoBar();
}

// The session this tab is stopping: its stream may close before the stop
// request returns.
let stoppingId = null;

// +opened+ false: the stream never delivered a frame (the proxy answered
// 503, or the bridge refused it), so a retry waits a moment rather than
// spinning through resync → stream → error.
const STREAM_RETRY_MS = 3000;
function workerGone(id, { opened = true } = {}) {
  streamControl = null;
  if (id !== selected) return;
  // A turn that was running is over: its worker can't finish it.
  const stopped = stoppingId === id;
  const endText = workerGoneText({ turnRunning, stopped });
  if (endText) {
    endTurnView("gone", endText);
    if (!stopped) setLiveStatus("idle");
  }
  if (current.owner === "worker") current.owner = null;
  // Its card says "live" (the list's owner, or setLiveStatus's) until the
  // hub's event says otherwise: the worker is gone now, as far as this
  // tab can tell.
  const i = allSessions.findIndex((s) => s.id === id);
  if (i >= 0 && allSessions[i].owner === "worker") {
    allSessions[i] = withoutWorker(allSessions[i]);
    render();
  }
  updateInfoBar();
  // Once: a worker still alive with a bridge (the stream dropped, not the
  // worker: chi web restarted) reconnects right here. Otherwise the next
  // worker's bridge_up event brings the stream back (followSelectedSession).
  if (opened) resync({ endText });
  else setTimeout(() => { if (id === selected && !(streamControl && streamControl.live)) resync({ endText }); }, STREAM_RETRY_MS);
}

// The stream's event handlers; renderSessionView replays a snapshot through
// them too.
const streamHandlers = {
  generation_chunk: (data) => {
    // Route the chunk's bytes to the text bubble and the thinking block (see
    // chunk_router.js). Raw `content` is only a fallback for an older server.
    const { text, thinking } = routeChunk(data);
    setLiveTurnNote("");
    turnDom.chunk({ text, thinking, iteration: data.iteration ?? null });
    const pct = extractCtxPct(data, current.ctxWindow);
    if (pct !== null && !Number.isNaN(pct)) {
      current.ctxPct = pct;
      updateInfoBar();
      updateFirstPeek();
    }
  },
  generation_started: (data) => {
    if (data?.context_window_tokens) current.ctxWindow = data.context_window_tokens;
    setLiveTurnNote("");
    turnDom.generationStarted(data || {});
  },
  generation_completed: (data) => {
    setLiveTurnNote("");
    if (data?.served_model) current.served = [data.served_model, data.requested_model];
    // The generation's speed and the session's token totals, from the server.
    current.timing.tokens = generationTokens(current.timing.tokens, data);
    if (data?.served_model || data?.tokens) updateInfoBar();
    turnDom.generationCompleted();
  },
  // Prompts sent while a turn ran merge into it at an iteration boundary:
  // input_merged names them (their bubbles turn "steered"), then
  // pending_input_merged carries the merged text, shown only for prompts
  // this tab has no bubble for.
  input_merged: (data) => applyPromptOps(data),
  pending_input_merged: (data) => {
    applyPromptOps(data);
    showSteers(data.steers);
  },
  turn_enqueued: (data) => applyPromptOps(data),
  turn_started: (data) => keepFollowing(historyEl, () => {
    // A finished turn still in the stage goes first: the start op looks
    // for a queued prompt among its rows.
    turnDom.handOff?.({ immediate: true });
    markRecapStale();
    const promptBubble = applyPromptOps(data);
    setTurnRunning(true);
    setLiveStatus("running");
    clearTimingInterval();
    liveTurnTimingEl = null;
    turnDom.turnStarted({ ...data, promptBubble });
    startLiveTurnTiming(data.started_at, data.turn_id || null);
  }),
  turn_completed: async (data) => {
    endTurnView("completed", null, { emptyAnswer: data.turn_summary?.empty_answer || null });
    const out = turnOutput(data);
    if (out) appendChunk(out);
    // after_turn hooks are running and may present the answer: its
    // answer_display (display: null when they didn't) comes next. A worker
    // that dies before it never sends one: workerGone releases the wait, and
    // displayWait's timeout ends it whatever happens (4.14).
    const display = data.display_pending ? displayWait() : null;
    if (display) displayPending = display;
    turnEndRead = readTurnEnd();
    await turnEndRead;
    // The answer bubble the turn view held at its box's height pops now
    // that the rendered markdown is in it (or the re-read failed: then the
    // plain text pops), and the display if one was coming, so the links
    // never swap in after the pop. The hold reveals by itself after
    // HOLD_MS whatever comes. The stage has no hold.
    if (display) await display.promise;
    turnDom.answerReady?.();
  },
  // An after_turn hook presented the answer (AnswerDisplay): it comes after
  // turn_completed, so re-read the answer once that read is done.
  answer_display: async (data) => {
    try {
      await turnEndRead;
      if (!selected || !data.display) return;
      const d = await getSession(selected, { tail: true, recent: true });
      if (Array.isArray(d.messages)) applyFinalMarkdown(d.messages);
    } catch (_) {
    } finally {
      releaseDisplayWait();
    }
  },
  turn_canceled: (data) => {
    endTurnView("canceled", cancelLineText(data.cancellation_reason || ""));
    setLiveStatus("idle");
    refreshTimingFromSession();
  },
  // The turn raised (e.g. the model server stayed unreachable). The worker
  // stays up: it rolls the turn back and hands the prompt back
  // (prompt_restored), and the prompts queued behind it run as usual.
  turn_failed: (data) => {
    lastFailedText = failedTurnText(data);
    endTurnView("failed", lastFailedText);
    setLiveStatus("idle");
  },
  // The rolled-back turn left the session: render it from the server again,
  // then show the prompt once more, marked failed (with why). This tab's own
  // prompt goes back into an empty composer.
  prompt_restored: async (data) => {
    keepEarlyRestore(data, earlyRestores, { myId: clientId, sentIds });
    const { refill, label, images: restoredImages } = restoreAction(data, { myId: clientId, sentIds, composerEmpty: !promptEl.value.trim() && !chips.length });
    if (refill) {
      promptEl.value = refill;
      fitPrompt();
    }
    if (restoredImages?.length) setChips(restoredChips(selected, restoredImages));
    const failedText = lastFailedText;
    lastFailedText = null;
    await resync();
    // The re-render drew it from the session (failed_turn): drawn again
    // below with this event's label and images.
    const drawn = historyEl.querySelector(".bubble.user[data-failed-turn]");
    if (drawn) {
      if (drawn.nextElementSibling?.classList.contains("cancel")) drawn.nextElementSibling.remove();
      drawn.remove();
    }
    // Not an echo waiting for its turn_enqueued: it keeps its enqueued_id, so
    // a resend's echo isn't matched to it.
    makeUserBubble(data.prompt || "", { state: "failed", label, enqueuedId: data.origin?.enqueued_id || `failed:${Date.now()}`, images: data.images });
    if (failedText) addEndBubble(failedText);
  },
  // A session command ran in the worker (any client's). One that changed
  // the conversation (!rollback, !cmd, a continue answered no) re-reads it.
  command_ran: async (data) => {
    const view = commandView(data, clientId);
    if (view.modelName && view.modelName !== current.model) {
      current.model = view.modelName;
      current.served = null;
      updateInfoBar();
    }
    if (view.resync) await resync();
    // A card's action that isn't anytime (the step-limit question's
    // /continue) has no bubble: nothing to remove.
    const queued = view.anytime ? commandBubble(view.commandId) : null;
    if (view.hidden) queued?.remove();
    else if (queued) drawCommandBubble(queued, view);
    else addCommandBubble(view);
  },
  // An anytime command (/help, a plugin's /btw) runs at once, beside a
  // turn: its bubble goes here, so the cards it shows come after it.
  command_queued: (data) => {
    // A card's action waits for its command_ran: shown only if it answers.
    if (data.anytime && !data.card && !commandBubble(data.command_id)) addCommandBubble({ ...commandView(data, clientId), text: "" });
  },
  // Due reminders went into the turn (a reminder turn has no prompt bubble).
  reminder_injected: (data) => addCommandBubble({ label: null, line: reminderText(data), text: "" }),
  // A context note joined the conversation (between turns; no turn runs).
  context_added: (data) => addNoteBubble({ label: data.label, content: data.text || "" }),
  continue_offered: (data) => questionCards.renderContinue(data),
  continue_resolved: (data) => questionCards.resolveContinue(data),
  tool_call_started: (data) => turnDom.toolStarted(data),
  tool_call_completed: (data) => turnDom.toolCompleted(data),
  // The engine's list, after every memory read and at a turn's end.
  used_memories_updated: (data) => {
    if (Array.isArray(data.used_memory_names)) setUsedMemories(data.used_memory_names);
  },
  context_status: (data) => {
    const pct = extractCtxPct(data, current.ctxWindow);
    if (pct !== null) {
      current.ctxPct = pct;
      updateInfoBar();
      updateFirstPeek();
    }
  },
  question_requested: (data) => {
    const pq = data.pending_question;
    if (pq && pq.id) questionCards.renderQuestion(pq);
  },
  question_answered: (data) => {
    questionCards.resolveQuestion(data.id, { answer: data.answer });
  },
  // A delegate's question relayed to its parent's card, or no longer.
  question_relay: (data) => questionCards.markRelayed(data.id, data.relayed_to),
  question_cancelled: (data) => {
    questionCards.resolveQuestion(data.id, { cancelled: true, reason: data.reason });
  },
  // One collected just as a turn started describes the chat before it.
  recap_ready: (data) => {
    // After the turn it covers, never above it.
    turnDom.handOff?.({ immediate: true });
    if (!turnRunning) showRecap(data.recap);
  },
  guardrail_warning: (data) => showGuardrailWarning(data.message, data.label || "guardrails"),
  // A notice during a turn is a row of its current step.
  hook_notice: (data) => { if (!turnDom.notice(data)) showHookNotice(data); },
  // The loop asks again after an empty answer: a row of the empty step
  // (a reload puts it back from the snapshot's cards).
  empty_answer_retry: (data) => { turnDom.notice({ line: emptyRetryLine(data) }); },
  // The provider is asked again after an error, or the turn waits for
  // plugins' setup: a note on the live timing line until it streams.
  generation_retrying: (data) => setLiveTurnNote(retryStatusLine(data)),
  plugin_init_wait: (data) => setLiveTurnNote(initWaitLine(data)),
  plugin_init_started: (data) => onInitEvent("plugin_init_started", data),
  plugin_init_finished: (data) => onInitEvent("plugin_init_finished", data),
  // A plugin's card, or a new version of one (the same id).
  card: (data) => {
    upsertCard(data);
    if (data.body) refreshCardBodies();
  },
  // The stream's cursor could not be replayed: render from scratch.
  reset: () => resync(),
  // Synthetic (snapshotEvents): a prompt merged into the turn in progress.
  merged_input: (data) => {
    const origin = (data.origins || [])[0] || {};
    const own = isOwn(origin.client_id, clientId);
    makeUserBubble(data.content, {
      state: "steered", own, enqueuedId: origin.enqueued_id || null, label: own ? null : clientLabel(origin.client_id),
    });
  },
};

async function refreshTimingFromSession() {
  if (!selected) return;
  const id = selected;
  const line = { el: liveTurnTimingEl, turnId: liveTurnId };
  try {
    const data = await getSession(id, { tail: true, recent: true, turnId: line.turnId });
    if (id !== selected) return;
    if (data.session?.status) current.status = data.session.status;
    if (await mergeTurnTiming(id, data.timing)) finishTurnLine(line);
  } catch (_) {}
}


function removeHintIfEmpty() {
  const hint = historyEl.querySelector(".hint");
  if (!hint) return;
  // Remove the placeholder when the card will be the first content in history.
  if (!historyEl.querySelector(".bubble")) hint.remove();
}
function closeStream() {
  turnDom.reset();
  if (streamControl) {
    streamControl.close();
    streamControl = null;
  }
}

// A session this tab just created: onto the list now, as the events would
// put it (they follow, with its owner and bridge_up).
function addCreatedSession(created) {
  const { bridge_port: _port, ...session } = created;
  allSessions = applySessionEvent(allSessions, "session", { session });
  render();
}

// A first message: an idle session, then the turn (or the command) into it
// as for any later one (handleSendTurn), so a failed first turn's prompt
// comes back into the composer too (sentIds).
function handleCreate() {
  return handleSendTurn();
}

async function handleSendTurn() {
  if (current.owner === "tui") return;
  const prompt = turnText(promptEl.value, chips);
  if (!prompt) return;
  // An image-only send's text is its placeholders: not for ↑.
  const typed = promptEl.value.trim() !== "";
  if (!selected) {
    // The start page's own reply (a web-local command) or the hint for a
    // typo: neither needs a session, so none is made for it (2.29).
    const local = startPageReplyOrHint(prompt, { commands: current.commands, images: chips.length });
    if (local) {
      promptEl.value = "";
      fitPrompt();
      showNotice(local);
      return;
    }
    actionBtn.disabled = true;
    try {
      const s = await createIdleSession({ dir: scope.dir, model: chosenModel(), preview: prompt });
      addCreatedSession(s);
      await select(s.id);
    } catch (e) {
      alert(e.message);
      return;
    } finally {
      actionBtn.disabled = false;
    }
  }
  // A session command by the session's list (the new one's too: select
  // read it); an unknown /word is a prompt, as in a terminal — but a typo
  // of a command (/modle) gets the hint, not a turn.
  if (!chips.length && sessionCommandLine(prompt, current.commands)) return handleSendCommand(prompt);
  if (!chips.length) {
    const typo = unknownCommandHint(prompt, current.commands);
    if (typo) {
      addCommandBubble({ label: null, line: prompt, text: typo });
      promptEl.value = "";
      fitPrompt();
      return;
    }
  }
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  // Sending moves a finished turn out of the stage at once (else the echo
  // would land among its rows); into a running one it is a queued row there.
  turnDom.handOff?.({ immediate: true });
  const sending = chips.slice();
  const echo = makeUserBubble(prompt, { state: "queued", own: true, images: sending });
  if (!turnDom.holds?.()) historyEl.scrollTop = historyEl.scrollHeight;
  if (!current.firstPreview || current.firstPreview==="—") {
    current.firstPreview = normalize(prompt).slice(0,80) + (normalize(prompt).length>80?"…":"");
    updateInfoBar();
    updateFirstPeek();
  }
  actionBtn.disabled = true;
  try {
    for (const chip of sending) {
      if (!chip.ref) chip.ref = await uploadImage(selected, chip.file, chip.name);
    }
    const ack = await sendTurn(selected, prompt, { clientId, images: turnRefs(sending), history: typed });
    if (ack?.command_id) {
      // The worker knew it as a command (its list was newer than ours):
      // its command_ran shows it, not a prompt bubble.
      echo.remove();
      promptEl.value = "";
      fitPrompt();
      if (!streamControl?.live) startStream(selected, selectSeq ?? 0);
      return;
    }
    if (ack?.enqueued_id) sentIds.add(ack.enqueued_id);
    refreshHistory();
    // A turn that failed fast was restored before this ack: its prompt
    // (and images) go back into the composer, without replacing text typed
    // since (4.13). The composer still holds the text just sent: it goes.
    const restored = restoreOnAck(ack?.enqueued_id, earlyRestores, { myId: clientId, sentIds });
    promptEl.value = composerAfterAck({ sent: prompt, current: promptEl.value, refill: restored?.refill || "" });
    fitPrompt();
    clearChips();
    if (restored?.images?.length) setChips(restoredChips(selected, restored.images));
    // Its turn_enqueued usually tagged the echo already; the ack covers a
    // worker that wasn't live (no turn_enqueued then).
    if (ack?.enqueued_id && !echo.dataset.enqueuedId && !bubbleById(ack.enqueued_id)) {
      echo.dataset.enqueuedId = ack.enqueued_id;
    }
    // A live stream carries this turn already; restarting it would drop the
    // events in between. Without one, POST /turn just woke a worker: its
    // events start after the seq the session was rendered at (0 for a new
    // worker process).
    if (!streamControl?.live) startStream(selected, selectSeq ?? 0);
  } catch (e) {
    echo.remove();
    // The turn never reached the worker's queue: an early restore waiting
    // for its ack is never taken back (4.13), so drop it here. The prompt
    // is still in the composer, as the echo was removed.
    dropEarlyRestores(earlyRestores);
    // The chips stay (uploaded ones keep their ref) for another try.
    if (/bad_image|too_large/.test(e.message)) {
      alert(e.message);
      return;
    }
    if (/owned_by_tui|409/.test(e.message)) {
      current.owner = "tui";
      updateComposerMode();
      return;
    }
    alert(e.message);
  } finally {
    actionBtn.disabled = current.owner === "tui";
    promptEl.focus();
  }
}

// /model, !ls, /continue no … run in the session's worker; every client
// shows the command_ran, this one too.
async function handleSendCommand(line) {
  const local = webLocalReply(line);
  if (local) {
    addCommandBubble({ label: null, line, text: local });
    promptEl.value = "";
    fitPrompt();
    return;
  }
  actionBtn.disabled = true;
  try {
    await sendCommand(selected, line, { clientId });
    promptEl.value = "";
    fitPrompt();
    refreshHistory();
    // The command woke the worker: follow its stream if none is open.
    if (!streamControl?.live) startStream(selected, selectSeq ?? 0);
  } catch (e) {
    if (/owned_by_tui|409/.test(e.message)) {
      current.owner = "tui";
      updateComposerMode();
      return;
    }
    addCommandBubble({ label: null, line, text: e.message, failed: true });
  } finally {
    actionBtn.disabled = current.owner === "tui";
    promptEl.focus();
  }
}

function addCommandBubble(view) {
  removeHintIfEmpty();
  const div = document.createElement("div");
  drawCommandBubble(div, view);
  const follow = isNearBottom();
  appendToHistory(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

// A command bubble's line and output (again, when its command_ran fills in
// an anytime command's bubble in place).
function drawCommandBubble(div, { label, line, text, busy = false, failed = false, commandId = null }) {
  div.className = "bubble command" + (busy ? " busy" : "") + (failed ? " failed" : "");
  if (commandId) div.dataset.commandId = commandId;
  div.replaceChildren();
  const head = document.createElement("div");
  head.className = "command-line";
  head.textContent = label ? `${label}> ${line}` : line;
  div.appendChild(head);
  if (text) {
    const body = document.createElement("pre");
    body.className = "command-output";
    body.textContent = text;
    div.appendChild(body);
  }
}

function commandBubble(commandId) {
  if (!commandId) return null;
  return findInTurnRoots(".bubble.command").find((el) => el.dataset.commandId === String(commandId)) || null;
}

function addNoteBubble(note) {
  removeHintIfEmpty();
  const div = document.createElement("div");
  div.className = "bubble note";
  div.innerHTML = noteHtml(note);
  const follow = isNearBottom();
  appendToHistory(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

async function handleCancel() {
  if (!selected) return;
  cancelBtn.disabled = true;
  try {
    await cancelTurn(selected);
  } catch (e) {
    // The turn ended meanwhile: nothing left to cancel.
    if (!/not_running|409/.test(e.message)) alert(e.message);
  } finally {
    cancelBtn.disabled = false;
  }
}

// The chi logo: back to the empty start, where the composer makes a new
// session (from all sessions too).
// The typed draft stays in the composer: paste in a session, then + new chat
// starts from it (with the model picker). clearSelection leaves #prompt alone.
$("#newBtn").addEventListener("click", () => {
  if (allViewOpen()) leaveAllView("");
  clearSelection();
  loadModels();
});

// ── The start page's model picker ──────────────────────────────────────────
// The hosts' models from GET /api/models, the choice this browser made last
// preselected while it is still offered (else the server's default). Hidden
// until the list is in, and in a session (its model is in the info bar). A
// host that failed is the picker's tooltip; a route that fails leaves the
// picker hidden and the server's default in charge. The search list itself
// is model_picker.js'; a pick sends the focus to the message box.
const modelPicker = createModelPicker({
  button: modelPickEl,
  panel: $("#modelPanel"),
  input: $("#modelSearch"),
  list: $("#modelList"),
  composer: $("#composer"),
  center: $("#center"),
  onPick: () => promptEl.focus(),
});
async function loadModels() {
  let payload;
  try {
    payload = await listModels();
  } catch (_) {
    return;
  }
  let stored = null;
  try { stored = localStorage.getItem(MODEL_KEY); } catch (_) {}
  if (!modelPicker.setModels(payload, stored)) return;
  modelPickEl.title = payload.warning ? `The model the new chat starts on · ${payload.warning}` : "The model the new chat starts on";
  modelPickEl.hidden = false;
}
// The picker's choice for a create request; nothing (the server's default)
// while the list is not in.
function chosenModel() {
  return modelPickEl.hidden ? undefined : modelPicker.chosen() || undefined;
}
actionBtn.addEventListener("click", () => {
  if (!selected) handleCreate();
  else handleSendTurn();
});

// ── Images: paste or drop into the composer, chips until sent ─────────────
const chipsEl = $("#chips");
const lightboxEl = $("#lightbox");
let chips = [];

function renderChips() {
  chipsEl.innerHTML = chipsHtml(chips);
  chipsEl.hidden = !chips.length;
}

function setChips(list) {
  for (const c of chips) if (c.file && c.src) URL.revokeObjectURL(c.src);
  chips = list;
  renderChips();
}

function clearChips() {
  setChips([]);
}

function addImageFiles(files) {
  if (!files.length) return false;
  for (const file of files) chips.push({ file, name: chipName(file, chips.length), src: URL.createObjectURL(file) });
  renderChips();
  promptEl.focus();
  return true;
}

chipsEl.addEventListener("click", (e) => {
  const btn = e.target.closest(".chip-remove");
  if (!btn) return;
  const [chip] = chips.splice(Number(btn.dataset.index), 1);
  if (chip?.file && chip.src) URL.revokeObjectURL(chip.src);
  renderChips();
});
// ── Composer height: grows with the text; the top-edge grip sets a floor ───
const GRIP_KEY = "chi_composer_floor";
let promptFloor = null;
try { promptFloor = Number(localStorage.getItem(GRIP_KEY)) || null; } catch (_) {}

function fitPrompt() {
  const borders = promptEl.offsetHeight - promptEl.clientHeight;
  promptEl.style.height = "0px";
  const { height, scrolls } = promptHeight({ contentPx: promptEl.scrollHeight + borders, floorPx: promptFloor, viewportPx: window.innerHeight });
  promptEl.style.height = `${height}px`;
  promptEl.style.overflowY = scrolls ? "auto" : "hidden";
}

const composeGrip = $("#composeGrip");
composeGrip.addEventListener("pointerdown", (e) => {
  e.preventDefault();
  composeGrip.setPointerCapture(e.pointerId);
  composeGrip.classList.add("dragging");
  const startY = e.clientY;
  const startH = promptEl.offsetHeight;
  const move = (ev) => {
    promptFloor = gripFloor(startH + (startY - ev.clientY), window.innerHeight);
    fitPrompt();
  };
  const up = () => {
    composeGrip.classList.remove("dragging");
    composeGrip.removeEventListener("pointermove", move);
    composeGrip.removeEventListener("pointerup", up);
    composeGrip.removeEventListener("pointercancel", up);
    try { localStorage.setItem(GRIP_KEY, String(promptFloor || "")); } catch (_) {}
  };
  composeGrip.addEventListener("pointermove", move);
  composeGrip.addEventListener("pointerup", up);
  composeGrip.addEventListener("pointercancel", up);
});
composeGrip.addEventListener("dblclick", () => {
  promptFloor = null;
  try { localStorage.removeItem(GRIP_KEY); } catch (_) {}
  fitPrompt();
});
promptEl.addEventListener("input", fitPrompt);
window.addEventListener("resize", fitPrompt);
fitPrompt();

// The card floats over the history: keep the history's bottom padding at the
// card's height, and stay pinned to the end if the reader was there, since the
// card grows (text, chips, Cancel, a wrapping footer) under a reader at the end.
const dockEl = $("#dock");
const centerEl = $("#center");
new ResizeObserver(() => {
  // The stage's height too: a reader at the end stays there.
  const follow = atHistoryEnd();
  centerEl.style.setProperty("--dock-h", `${dockEl.offsetHeight}px`);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}).observe(dockEl);

promptEl.addEventListener("paste", (e) => {
  const files = imageFiles(e.clipboardData);
  // Text pasted along with an image still lands in the textarea.
  if (addImageFiles(files) && !e.clipboardData.getData("text/plain")) e.preventDefault();
});
composerEl.addEventListener("dragover", (e) => {
  if (![...(e.dataTransfer?.types || [])].includes("Files")) return;
  e.preventDefault();
  composerEl.classList.add("dropping");
});
composerEl.addEventListener("dragleave", () => composerEl.classList.remove("dropping"));
composerEl.addEventListener("drop", (e) => {
  composerEl.classList.remove("dropping");
  const files = imageFiles(e.dataTransfer);
  if (!files.length) return;
  e.preventDefault();
  addImageFiles(files);
});
turnRoots().forEach((root) => root.addEventListener("click", (e) => {
  const img = e.target.closest("img.thumb");
  if (!img) return;
  lightboxEl.querySelector("img").src = img.src;
  lightboxEl.hidden = false;
}));
lightboxEl.addEventListener("click", () => { lightboxEl.hidden = true; });
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !lightboxEl.hidden) lightboxEl.hidden = true;
});
cancelBtn.addEventListener("click", () => handleCancel());
// The / autocomplete (command_list.js): the session's commands while the
// composer holds one "/word".
const commandList = createCommandList({
  list: $("#commandList"),
  prompt: promptEl,
  commands: () => (selected && current.owner !== "tui" ? current.commands : []),
  afterPick: () => fitPrompt(),
});

// ↑/↓: the prompt history shared with the TUI (prompt_history.js), from a
// copy fetched on focus and after each send (keydown can't wait for one).
const promptHistory = createPromptHistory();
function refreshHistory() {
  fetchHistory().then((entries) => promptHistory.setEntries(entries), () => {});
}
promptEl.addEventListener("focus", refreshHistory);
function historyKey(e) {
  if (e.isComposing || e.shiftKey || e.altKey || e.ctrlKey || e.metaKey) return false;
  const step = e.key === "ArrowUp" ? promptHistory.up : e.key === "ArrowDown" ? promptHistory.down : null;
  const recalled = step?.({ value: promptEl.value, start: promptEl.selectionStart, end: promptEl.selectionEnd });
  if (!recalled) return false;
  e.preventDefault();
  promptEl.value = recalled.value;
  promptEl.setSelectionRange(recalled.caret, recalled.caret);
  fitPrompt();
  return true;
}

promptEl.addEventListener("keydown", (e) => {
  if (commandList.handleKey(e)) return;
  if (historyKey(e)) return;
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    if (!selected) handleCreate();
    else handleSendTurn();
  }
});
$("#infoStopBtn").addEventListener("click", async () => {
  if (!selected) return;
  if (!confirm(`Stop session ${selected}?`)) return;
  const id = selected;
  stoppingId = id;
  try {
    await stopSession(id);
    if (id === selected) {
      // The worker is gone: don't wait for its stream to notice.
      streamControl?.close();
      current.status = "stopped";
      workerGone(id);
    }
  } finally {
    stoppingId = null;
  }
  // The list hears of the stop from the hub (the stop route rescans it).
  if (!eventsControl) refresh();
});
$("#infoDeleteBtn").addEventListener("click", () => {
  if (selected) confirmDelete(selected);
});
$("#infoArchiveBtn").addEventListener("click", () => {
  if (!selected) return;
  if (selectedArchived()) setArchived(selected, false);
  else setArchived(selected, true);
});

// ── Archive ────────────────────────────────────────────────────────────────
// Archive hides a session (and its delegates) from the strip and the list,
// kept for good; "include archived" in all sessions finds it. No confirm:
// the toast's Undo takes it back. Archiving the open session stays on it
// (the button flips to unarchive); its worker was stopped by the server.

function selectedArchived() {
  return !!allSessions.find((s) => s.id === selected)?.archived;
}

// The ids in the server's answer flip here at once; the hub's events
// follow with the same.
function markArchived(ids, archived) {
  const set = new Set(ids);
  allSessions = allSessions.map((s) => (set.has(s.id) ? { ...s, archived } : s));
}

async function setArchived(id, archive, { undo = true } = {}) {
  const short = id.slice(0, 8);
  let result;
  // A live worker is stopped by the archive: its stream ending is a stop.
  if (archive) stoppingId = id;
  try {
    result = archive ? await archiveSession(id) : await unarchiveSession(id);
    markArchived(archive ? result.archived : result.unarchived, archive);
    if (archive && id === selected && (result.stopped || []).includes(id)) {
      // Its worker is gone: don't wait for its stream to notice.
      streamControl?.close();
      current.status = "stopped";
      workerGone(id);
    }
  } catch (e) {
    alert(`Could not ${archive ? "archive" : "unarchive"} session ${short}: ${e.message}`);
    return;
  } finally {
    if (archive) stoppingId = null;
  }
  render();
  updateInfoBar();
  if (!eventsControl) refresh();
  const what = archive ? "Archived" : "Unarchived";
  showToast(`${what} ${short}`, undo ? { label: "Undo", run: () => setArchived(id, !archive, { undo: false }) } : null);
}

// sticky: stays until its action or its ✕ (else gone after 6 s).
let toastTimer = null;
function showToast(text, action = null, { sticky = false } = {}) {
  const el = $("#toast");
  el.innerHTML = `<span>${escapeHtml(text)}</span>${action ? `<button type="button" class="toast-action">${escapeHtml(action.label)}</button>` : ""}` +
    (sticky ? `<button type="button" class="toast-close" title="Dismiss" aria-label="Dismiss">✕</button>` : "");
  el.hidden = false;
  el.querySelector(".toast-action")?.addEventListener("click", () => {
    el.hidden = true;
    action.run();
  });
  el.querySelector(".toast-close")?.addEventListener("click", () => { el.hidden = true; });
  clearTimeout(toastTimer);
  if (!sticky) toastTimer = setTimeout(() => { el.hidden = true; }, 6000);
}

$("#includeArchived").addEventListener("change", () => {
  if (allViewOpen()) renderAll();
});

// Annotate (annotate_bar.js): a selection in the conversation offers
// "Annotate" and the presets, which append a quote to the composer.
const annotateBar = createAnnotateBar({
  presets: parsePresets(document.body.dataset.annotatePresets),
  canAnnotate: () => !!selected && current.owner !== "tui",
  roots: turnRoots,
  isLive: (root) => turnRunning && turnDom.containsLive(root),
  onQuote: (text) => {
    promptEl.value = appendQuote(promptEl.value, text);
    fitPrompt();
    promptEl.focus();
    promptEl.setSelectionRange(promptEl.value.length, promptEl.value.length);
    promptEl.scrollTop = promptEl.scrollHeight;
  },
});
historyEl.addEventListener("scroll", annotateBar.schedule);
turnDom.scrollEl?.addEventListener("scroll", annotateBar.schedule, true);
turnRoots().forEach((root) => installCopy(root));

// Notifications (notifications.js): an OS notification and a title count
// when a session needs the user while this tab is not in front.
const notifications = createNotifications({ button: $("#notifyBtn") });

// The latest-sessions strip can be hidden for more chat room; the choice
// stays per browser (it replaced zen mode, so a zen user starts hidden).
function stripHiddenSaved() {
  try {
    const saved = localStorage.getItem("chi_strip_hidden");
    return saved === null ? localStorage.getItem("chi_zen") === "1" : saved === "1";
  } catch (_) {
    return false;
  }
}
// A short window hides the strip by itself, so the stage keeps room for a
// card that waits (its question and choices); the sessions pill brings it
// back until the window is tall again. Not saved: the saved choice is the
// user's own hide ▴ / show.
const shortWindow = window.matchMedia(SHORT_WINDOW_QUERY);
let stripShownWhileShort = false;
function applyStripHidden() {
  document.body.classList.toggle("strip-hidden", stripAutoHidden({
    saved: stripHiddenSaved(), short: shortWindow.matches, shownWhileShort: stripShownWhileShort,
  }));
}
function setStripHidden(hidden) {
  try { localStorage.setItem("chi_strip_hidden", hidden ? "1" : "0"); } catch (_) {}
  stripShownWhileShort = !hidden && shortWindow.matches;
  applyStripHidden();
}
applyStripHidden();
shortWindow.addEventListener("change", () => {
  if (!shortWindow.matches) stripShownWhileShort = false;
  applyStripHidden();
});
$("#stripShow").addEventListener("click", () => setStripHidden(false));
$("#stripHideTop").addEventListener("click", () => setStripHidden(true));

$("#filter").addEventListener("input", renderAll);
// A list whose order was held under the pointer (listOrder) catches up.
topStripEl.addEventListener("pointerleave", () => {
  if (heldLists.has(topStripEl)) renderTop(stripSessions());
});
allListEl.addEventListener("pointerleave", () => {
  if (heldLists.has(allListEl) && allViewOpen()) renderAll();
});
// Esc leaves the all-sessions view.
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && allViewOpen()) closeAllView();
});
applyView();

// Where sessions live: under the all-sessions search (the server fills it in).
if (document.body.dataset.sessionsDir) {
  $("#allPath code").textContent = document.body.dataset.sessionsDir;
  $("#allPath").hidden = false;
}

renderScope();
updateInfoBar();
updateComposerMode();
loadModels();
// The list: the hub's stream when the browser has EventSource, else fetched.
if (typeof globalThis.EventSource === "function") openSessionEvents();
else refresh();
selectFromHash();
