import {
  listSessions,
  createSession,
  getSession,
  sendTurn,
  cancelTurn,
  stopSession,
  deleteSession,
  sendAnswer,
  dismissQuestion,
  sendCommand,
  openStream,
  openEvents,
  createIdleSession,
  uploadImage,
} from "./data.js";
import { chipName, chipsHtml, imageFiles, restoredChips, thumbsHtml, turnRefs, turnText } from "./images.js";
import { escapeHtml, messageBodyHtml, noteHtml, normalize, userBodyHtml, ownerBadge, previewForCard, relativeTime, firstMessageOf, failedTurnText, modelLabel, deleteConfirmText, recapLabel, canStopSession, goneSessionNotice, withLiveStatus, withoutWorker, recapPlace } from "./format.js";
import { chatHistoryHtml, createChatView } from "./chat_view.js";
import { createTurnView, turnHistoryHtml } from "./turn_view.js";
import { annotationSource, appendQuote, quoteBlock } from "./annotations.js";
import { COPY_SOURCE_ATTR, copySourceAttr, copyText, installCopy } from "./copy.js";
import { routeChunk } from "./chunk_router.js";
import { extractCtxPct } from "./ctx.js";
import { approvalAllowed, approvalView, isApproval, resultText } from "./question_card.js";
import { gripFloor, promptHeight } from "./composer_size.js";
import { ALL_SESSIONS_HASH, sessionHash, sessionIdFromHash } from "./route.js";
import { allScopeHref, cardFolder, projectScopeHref, scopeDir } from "./scope.js";
import { shouldFollowScroll, keepFollowing } from "./scroll.js";
import { stripColumns, stripShowParts } from "./strip.js";
import { applySessionEvent, sortedByUpdated } from "./sessions_list.js";
import {
  appendAboveLiveTiming, cancelLineText, elapsedSince, formatDuration, normalizeTiming, turnTimingText,
} from "./timing.js";
import { clientLabel, commandView, continueLine, isCommandLine, isOwn, newClientId, promptOps, reminderText, restoreAction, snapshotEvents, turnOutput, workerGoneText } from "./turn_events.js";

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
const createAltBtn = $("#createAltBtn");
const composeHintEl = $("#composeHint");
const actionMenuBtn = $("#actionMenuBtn");
const actionMenu = $("#actionMenu");

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
// The per-turn view (web.turn_view, or ?view=turn|chat): one block per turn
// with its steps (turn_view.js), instead of a row of bubbles (chat_view.js).
const turnView = document.body.dataset.turnView === "1";
// The running turn's DOM: the streaming bubbles, the thinking block and the
// activity panel, or the turn block.
const turnDom = (turnView ? createTurnView : createChatView)({
  historyEl,
  appendToHistory: (el) => appendToHistory(el),
  isNearBottom: () => isNearBottom(),
  sawText: (k) => seenContent.add(k),
  sessionId: () => selected,
});
let currentFirstPreview = "";
let currentUsedMemories = [];
// The session's --memory and --mute lists (from the session card; shown in
// the info bar's tooltip).
let currentPreloadedMemories = [];
let currentMutedMemories = [];
let currentCtxPct = null;
// Window the kernel resolved for the running generation (:generation_started).
let currentCtxWindow = null;
let currentStatus = "";
let currentModel = "";
// What the worker's server said it served for a model name: [served, asked].
let currentServed = null;
let currentDir = "";
// Who holds the selected session: "worker" (shared), "tui" (a plain terminal
// chi; sending would be refused) or null.
let currentOwner = null;
let currentTiming = normalizeTiming();
let turnRunning = false;
let liveTurnTimingEl = null;
let timingInterval = null;
// Live ask_user_question card, keyed by pending question id. Re-rendered from
// pending_question on session select so a reload mid-question restores it.
let questionCardEl = null;
let pendingQuestion = null;
// The continue offer's card while the offer is pending.
let continueCardEl = null;

// This tab's id in the session's events: tells its own prompts from the
// ones other clients (an attached TUI, another tab, reminders) sent.
const clientId = newClientId();
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
      allSessions = applySessionEvent(allSessions, "snapshot", data);
      render();
      const sess = allSessions.find((s) => s.id === selected);
      if (sess) followSelectedSession(sess);
    },
    session: (data) => {
      allSessions = applySessionEvent(allSessions, "session", data);
      render();
      if (data.session && data.session.id === selected) followSelectedSession(data.session);
    },
    session_gone: (data) => {
      const next = applySessionEvent(allSessions, "session_gone", data);
      if (next !== allSessions) {
        allSessions = next;
        render();
      }
      leaveGoneSession(data.id, "deleted");
    },
  }, {
    dir: scope.dir,
    onError: () => {
      eventsControl = null;
      refresh();
    },
  });
}

// The selected session's card changed: its owner and, without a live
// stream, its status show in the info bar; a worker whose bridge is up
// (a turn another client sent woke one, or a replacement after a kill)
// gets the stream attached through one resync.
function followSelectedSession(sess) {
  currentOwner = sess.owner || null;
  const streaming = !!(streamControl && streamControl.live);
  if (!streaming) currentStatus = sess.status;
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
  const allLink = `<a class="scope-all" href="${escapeHtml(allScopeHref(location.hash, scope.dir))}" title="Sessions of every project">all</a>`;
  if (scopeError) {
    el.innerHTML = `<span class="scope-name error" title="${escapeHtml(scopeError)}">folder not found</span>${allLink}`;
  } else if (scope.projectName) {
    el.innerHTML = `<span class="scope-name" title="Sessions of ${escapeHtml(scope.projectDir)}">${escapeHtml(scope.projectName)}</span>${allLink}`;
  } else {
    const where = scope.dir || scope.serverDir;
    const backLink = scope.backName
      ? `<a class="scope-all scope-back" href="${escapeHtml(projectScopeHref(scope.backDir, location.hash))}" title="Sessions of ${escapeHtml(scope.backName)} only">← ${escapeHtml(scope.backName)}</a>`
      : "";
    el.innerHTML = `<span class="scope-name" title="Sessions of every project">all projects</span>${backLink}${where ? `<span class="scope-where" title="New chats start in ${escapeHtml(where)}">new chat in<span class="path"><bdi>${escapeHtml(where)}</bdi></span></span>` : ""}`;
  }
  el.hidden = false;
  document.title = scope.projectName ? `Chi · ${scope.projectName}` : "Chi";
  // The links follow the hash (an open session, the all-sessions view).
  el.querySelector(".scope-all:not(.scope-back)")?.addEventListener("click", (e) => {
    e.currentTarget.href = allScopeHref(location.hash, scope.dir);
  });
  el.querySelector(".scope-back")?.addEventListener("click", (e) => {
    e.currentTarget.href = projectScopeHref(scope.backDir, location.hash);
  });
}

function filteredSessions() {
  const q = $("#filter").value.trim().toLowerCase();
  if (!q) return allSessions;
  return allSessions.filter(
    (s) =>
      previewForCard(s).toLowerCase().includes(q) ||
      (s.first_preview || "").toLowerCase().includes(q) ||
      s.short_id.toLowerCase().includes(q) ||
      s.id.toLowerCase().includes(q) ||
      s.status.toLowerCase().includes(q),
  );
}

// A card: the first message as its title, then status, how long ago, owner
// and memories. The id is in the tooltip (and the search) only.
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
  return `<div class="card" data-id="${s.id}" title="${escapeHtml(tip)}${memTitle ? ` · ${escapeHtml(memTitle)}` : ""}"><div class="preview">${preview}</div>${s.recap ? `<div class="recap" title="${escapeHtml(s.recap)}">${escapeHtml(s.recap)}</div>` : ""}<div class="meta"><span class="status dot ${escapeHtml(s.status)}" title="${escapeHtml(s.status)}" aria-label="${escapeHtml(s.status)}"></span>${timeHtml}${folderHtml}${ownerBadgeHtml(s)}${s.used_memory_names && s.used_memory_names.length ? `<span title="${escapeHtml(s.used_memory_names.join(", "))}">mem ${s.used_memory_names.length}</span>` : ""}</div>${deletable ? `<button type="button" class="card-del" data-del="${escapeHtml(s.id)}" title="Delete session" aria-label="Delete session ${escapeHtml(s.short_id)}">\u2715</button>` : ""}</div>`;
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

function render() {
  fitStripColumns();
  renderTop(allSessions.slice(0, stripCols));
  if (allViewOpen()) renderAll();
}

let stripResizeTimer = null;
window.addEventListener("resize", () => {
  clearTimeout(stripResizeTimer);
  stripResizeTimer = setTimeout(() => {
    const before = stripCols;
    fitStripColumns();
    if (stripCols !== before && allSessions.length) renderTop(allSessions.slice(0, stripCols));
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
    topStripEl.innerHTML = `<div class="hint scope-error">${escapeHtml(scopeError)} · <a href="${escapeHtml(allScopeHref(""))}">show every session</a></div>`;
    return;
  }
  if (!sessions.length) {
    topStripEl.innerHTML = "";
    return;
  }
  const count = `${allSessions.length} ${allSessions.length === 1 ? "session" : "sessions"}`;
  const tile = `<div class="strip-side"><button type="button" class="card" id="allTile" title="All sessions, with search">All sessions →<span class="count">${count}</span></button><button type="button" class="strip-toggle" id="stripHide" title="Hide the latest sessions">hide ▴</button></div>`;
  topStripEl.innerHTML = sessions.map((s) => cardHtml(s)).join("") + tile;
  bindCards(topStripEl, select);
  $("#allTile").addEventListener("click", openAllView);
  $("#stripHide").addEventListener("click", () => setStripHidden(true));
}

// The hidden strip's pill: "▾ 5 sessions · ● 1 live", following the list.
function renderStripShow() {
  const { count, live } = stripShowParts(allSessions);
  const liveHtml = live ? ` · <span class="live"><span class="live-dot" aria-hidden="true"></span>${escapeHtml(live)}</span>` : "";
  $("#stripShow").innerHTML = `<span class="pill-arrow" aria-hidden="true">\u25BE</span> ${escapeHtml(count)}${liveHtml}`;
}

function renderAll() {
  const sessions = filteredSessions();
  $("#count").textContent = sessions.length === allSessions.length
    ? `${allSessions.length}`
    : `${sessions.length} / ${allSessions.length}`;
  if (!sessions.length) {
    allListEl.innerHTML = `<div class="hint">${allSessions.length ? "No session matches." : "No sessions yet."}</div>`;
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
const SEND_HINT = "Enter to send · Shift+Enter for a newline";

// While a turn runs, Send still sends: the prompt merges into the turn at
// its next step (steering). Cancel is its own button then.
function updateComposerMode() {
  document.body.classList.toggle("has-session", !!selected);
  const running = turnRunning && !!selected;
  cancelBtn.style.display = running ? "" : "none";
  if (running) {
    setPlaceholder("Running… a message now steers this turn (Enter to send)", "Running… a message steers it");
    composeHintEl.textContent = SEND_HINT;
    actionBtn.textContent = "Send";
    createAltBtn.style.display = "none";
    actionMenuBtn.style.display = "none";
    actionMenu.classList.remove("visible");
    emptyEl.classList.add("hidden");
    return;
  }
  if (!selected) {
    setPlaceholder("Ask chi anything…", "Ask chi anything…");
    composeHintEl.textContent = "Enter to start · Shift+Enter for a newline";
    actionBtn.textContent = "Start";
    actionBtn.disabled = false;
    createAltBtn.style.display = "none";
    actionMenuBtn.style.display = "none";
    actionMenu.classList.remove("visible");
    emptyEl.classList.remove("hidden");
    historyEl.innerHTML = "";
    updateInfoBar();
  } else if (currentOwner === "tui") {
    setPlaceholder("A terminal chi owns this session and doesn't share it — run it with chi --shared to send from here", "A terminal chi owns this session");
    composeHintEl.textContent = "";
    actionBtn.textContent = "Send";
    actionBtn.disabled = true;
    createAltBtn.style.display = "inline-block";
    createAltBtn.textContent = "New chat";
    actionMenuBtn.style.display = "none";
    emptyEl.classList.add("hidden");
  } else {
    setPlaceholder("Message chi…", "Message chi…");
    composeHintEl.textContent = SEND_HINT;
    actionBtn.textContent = "Send";
    actionBtn.disabled = false;
    createAltBtn.style.display = "inline-block";
    createAltBtn.textContent = "New chat";
    actionMenuBtn.style.display = "inline-block";
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
  currentStatus = status;
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

function clearSelection() {
  selected = null;
  setSessionHash(null);
  document.querySelectorAll(".card").forEach((el) => el.classList.remove("active"));
  currentFirstPreview = "";
  currentUsedMemories = [];
  currentPreloadedMemories = [];
  currentMutedMemories = [];
  currentCtxPct = null;
  currentCtxWindow = null;
  currentStatus = "";
  currentModel = "";
  currentServed = null;
  currentDir = "";
  currentOwner = null;
  currentTiming = normalizeTiming();
  clearTimingInterval();
  liveTurnTimingEl = null;
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
  currentFirstPreview = "";
  currentUsedMemories = [];
  currentPreloadedMemories = [];
  currentMutedMemories = [];
  currentCtxPct = null;
  currentCtxWindow = null;
  currentStatus = "";
  currentModel = "";
  currentServed = null;
  currentDir = "";
  currentOwner = null;
  currentTiming = normalizeTiming();
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
  removeQuestionCard();
  continueCardEl = null;
  unmatchedMerge = false;
  setTurnRunning(false);
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
      data = await getSession(id, { parts: turnView });
    } catch (e) {
      if (e.status === 404) return leaveGoneSession(id, "not_found");
      if (id === selected) historyEl.innerHTML = `<div class="hint">Error: ${escapeHtml(e.message)}</div>`;
      return;
    }
    if (id !== selected) return;
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
  currentStatus = s.status;
  currentModel = s.model_name;
  currentServed = s.served_model ? [s.served_model, s.served_model_for] : null;
  currentDir = s.working_directory;
  currentOwner = s.owner || null;
  currentTiming = normalizeTiming(data.timing);
  currentFirstPreview = s.first_preview || previewForCard(s);
  currentUsedMemories = s.used_memory_names || [];
  currentPreloadedMemories = s.preloaded_memory_names || [];
  currentMutedMemories = s.muted_memory_names || [];
  if (data.messages && data.messages.length) {
    const first = data.messages.find((m) => m.role === "user");
    if (first && first.content) currentFirstPreview = normalize(first.content).slice(0,80) + (normalize(first.content).length>80?"…":"");
    renderHistory(data.messages);
  } else {
    renderHistory(data.history || []);
    if (!currentFirstPreview && data.history && data.history.length) {
      const txt = normalize(String(data.history[0]||"")).slice(0,80);
      if(txt) currentFirstPreview = txt;
    }
  }
  seedSeenFromDom();
  // A guardrail file that failed to load, announced before this page joined.
  showGuardrailWarning(data.guardrail_warning);
  // The recap saved with the session (also a stopped one's), else a live
  // worker's from before saved_recap existed.
  if (data.saved_recap) showRecap(data.saved_recap.text, data.saved_recap.turns_since);
  else showRecap(data.recap);
  const replay = snapshotEvents({
    current_turn: data.current_turn,
    queued: data.queued,
    started_at: currentTiming.activeTurn?.started_at,
  });
  replay.forEach((event) => streamHandlers[event.type]?.(event));
  if (!data.current_turn) {
    setTurnRunning(currentStatus === "running");
    if (turnRunning && currentTiming.activeTurn?.started_at) startLiveTurnTiming(currentTiming.activeTurn.started_at);
  }
  turnDom.flush();
  // A question the worker is blocked on (also after a reload).
  if (data.pending_question && data.pending_question.id && data.pending_question.status === "pending") {
    renderQuestionCard(data.pending_question);
  }
  // A turn ran out of iterations and waits for a yes or no.
  if (data.continue_offer) renderContinueCard(data.continue_offer);
  updateInfoBar();
  updateFirstPeek();
  updateComposerMode();
}

function renderHistory(items) {
  if (!items.length) {
    historyEl.innerHTML = `<div class="hint">No output yet. Send a message.</div>`;
    return;
  }
  if (typeof items[0] === "object" && items[0].role && turnView) {
    historyEl.innerHTML = turnHistoryHtml(items, currentTiming, { thumbs: (images) => thumbsHtml(selected, images) });
  } else if (typeof items[0] === "object" && items[0].role) {
    historyEl.innerHTML = chatHistoryHtml(items, currentTiming, { thumbs: (images) => thumbsHtml(selected, images) });
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

function applyFinalMarkdown(messages) {
  const message = [...messages].reverse().find(
    (item) => item?.role === "assistant" && typeof item.html === "string",
  );
  if (!message) return;

  const bubble = [...historyEl.querySelectorAll(".bubble.output")]
    .reverse()
    .find((item) => normalize(item.textContent) === normalize(message.content));
  if (!bubble) return;

  bubble.classList.add("markdown");
  bubble.setAttribute(COPY_SOURCE_ATTR, message.content);
  bubble.innerHTML = message.html;
}

function seedSeenFromDom() {
  seenContent = new Set();
  historyEl.querySelectorAll(".bubble").forEach((b) => {
    const k = normalize(b.textContent);
    if (k) seenContent.add(k);
  });
}

// Sticky-follow scroll: only auto-scroll to the bottom while the user is
// already near it; never yank them back down mid-read. Capture the decision
// BEFORE any DOM mutation that grows the content (new chunk / row / thinking
// delta), so the gap measured is the one the user was sitting at.
function isNearBottom() {
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

function addCancelBubble(reason) {
  addEndBubble(cancelLineText(reason));
}

function addEndBubble(text) {
  const div = document.createElement("div");
  div.className = "bubble cancel";
  div.textContent = text;
  appendToHistory(div);
  historyEl.scrollTop = historyEl.scrollHeight;
}

// Everything a turn's end (completed, canceled, failed) closes.
function endTurnView(kind) {
  setTurnRunning(false);
  turnDom.turnEnded({ kind });
  finishLiveTurnTiming();
  // The question dies with its turn (the worker stopped waiting).
  if (pendingQuestion) resolveQuestionCard(pendingQuestion.id, { cancelled: true, reason: "turn ended" });
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
  return [...historyEl.querySelectorAll(".bubble.user[data-enqueued-id]")].find(
    (el) => el.dataset.enqueuedId === enqueuedId,
  ) || null;
}

// This tab's oldest untagged echo, preferring one with the same text.
function untaggedOwnBubble(prompt) {
  const echoes = [...historyEl.querySelectorAll(".bubble.user[data-own]:not([data-enqueued-id])")];
  const text = normalize(prompt || "");
  return echoes.find((el) => el.dataset.userContent === text) || echoes[0] || null;
}

function applyPromptOps(event) {
  const ops = promptOps(event, { myId: clientId, known: (id) => !!bubbleById(id), unmatchedMerge });
  if (event.type === "input_merged") unmatchedMerge = false;
  if (event.type === "pending_input_merged") unmatchedMerge = false;
  for (const op of ops) {
    if (op.op === "add") {
      makeUserBubble(op.prompt, { state: op.state, label: op.label, enqueuedId: op.enqueuedId, images: op.images });
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
      if (!bubble) makeUserBubble(op.prompt, { own: true, enqueuedId: op.enqueuedId, images: op.images });
      else {
        if (op.enqueuedId) bubble.dataset.enqueuedId = op.enqueuedId;
        setBubbleState(bubble, null);
      }
    } else if (op.op === "steer") {
      const bubble = bubbleById(op.enqueuedId);
      if (bubble) setBubbleState(bubble, "steered");
      else unmatchedMerge = true;
    }
  }
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
  const before = recapPlace([...historyEl.querySelectorAll(":scope > .bubble.user")], turnsSince);
  keepFollowing(historyEl, () => (before ? historyEl.insertBefore(details, before) : appendToHistory(details)));
}

// A turn started: the recap describes the chat before it.
function markRecapStale() {
  historyEl.querySelectorAll(".bubble.recap:not(.stale)").forEach((el) => {
    el.classList.add("stale");
    const summary = el.querySelector("summary");
    if (summary) summary.textContent = recapLabel(0, true);
  });
}

// A guardrail hook or rule file that failed to load (once per worker).
function showGuardrailWarning(text) {
  if (!text) return;
  const el = document.createElement("div");
  el.className = "bubble guardrail-warning";
  el.textContent = `guardrails: ${text}`;
  const follow = isNearBottom();
  appendToHistory(el);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

function removeRecap() {
  historyEl.querySelectorAll(".bubble.recap").forEach((el) => el.remove());
}

// The info bar's "copy chi --attach": the full id, which the page shows
// only short; "copied ✓" for 2 s.
let attachCopiedAt = 0;
infoTextEl.addEventListener("click", async (e) => {
  if (!e.target.closest(".copy-attach") || !selected) return;
  if (!(await copyText(`chi --attach ${selected}`))) return;
  attachCopiedAt = Date.now();
  updateInfoBar();
  setTimeout(updateInfoBar, 2000);
});

function updateInfoBar() {
  const stopBtn = document.getElementById("infoStopBtn");
  const deleteBtn = document.getElementById("infoDeleteBtn");
  if (deleteBtn) deleteBtn.style.display = selected ? "" : "none";
  if (!selected) {
    // The start page hides the info bar (the storage path is on #/sessions).
    infoTextEl.innerHTML = "";
    infoTextEl.title = "";
    if (stopBtn) stopBtn.style.display = "none";
    return;
  }
  if (stopBtn) stopBtn.style.display = canStopSession({ owner: currentOwner, streaming: !!streamControl }) ? "" : "none";
  const idShort = selected.slice(0,8);
  const memText = currentUsedMemories.length ? currentUsedMemories.join(", ") : "—";
  const ctxText = currentCtxPct !== null ? `ctx ${Math.round(currentCtxPct)}%` : "";
  const sessionDuration = currentSessionDuration();
  const timingText = sessionDuration === null ? "" : `session ${formatDuration(sessionDuration)}`;
  const statusClass = currentStatus ? `status ${escapeHtml(currentStatus)}` : "status";
  const label = modelLabel(currentModel, ...(currentServed || []));
  const attachCmd = `chi --attach ${selected}`;
  const copied = Date.now() - attachCopiedAt < 2000;
  const copyHtml = `<button type="button" class="copy-attach" title="Copy &quot;${escapeHtml(attachCmd)}&quot; to attach a terminal">${copied ? "copied ✓" : "copy chi --attach"}</button>`;
  const metaHtml = `<div class="meta"><span class="id" title="${escapeHtml(selected)}">${escapeHtml(idShort)}</span>${copyHtml}<span class="${statusClass}">${escapeHtml(currentStatus||"")}</span><span class="model${label.mismatch ? " served-mismatch" : ""}" title="${escapeHtml(label.title)}">${escapeHtml(label.text)}</span><span class="dir" title="${escapeHtml(currentDir||"")}">${escapeHtml((currentDir||"").slice(0,48))}</span>${ctxText ? `<span class="model">${escapeHtml(ctxText)}</span>` : ""}${timingText ? `<span class="model">${escapeHtml(timingText)}</span>` : ""}</div>`;
  const previewHtml = `<div class="preview-line"><span class="preview">${escapeHtml(currentFirstPreview || "—")}</span> · <span class="mem" title="${escapeHtml(currentUsedMemories.join(", "))}">mem: ${escapeHtml(memText)}</span></div>`;
  infoTextEl.innerHTML = metaHtml + previewHtml;
  infoTextEl.title = memoriesTooltip(currentUsedMemories, currentPreloadedMemories, currentMutedMemories);
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
  if (turnRunning && currentTiming.startedAt) {
    return elapsedSince(currentTiming.startedAt);
  }
  return currentTiming.sessionDurationMs;
}

function clearTimingInterval() {
  if (timingInterval !== null) {
    clearInterval(timingInterval);
    timingInterval = null;
  }
}

let liveTurnNumber = null;

function startLiveTurnTiming(startedAt = new Date().toISOString()) {
  clearTimingInterval();
  currentTiming.activeTurn = { started_at: startedAt };
  // The turn records hold the finished turns, so this one comes next.
  liveTurnNumber = currentTiming.turnRecords.length + 1;
  liveTurnTimingEl = document.createElement("div");
  liveTurnTimingEl.className = "turn-timing live";
  historyEl.appendChild(liveTurnTimingEl);
  updateLiveTiming();
  timingInterval = setInterval(updateLiveTiming, 1000);
}

function appendToHistory(el) {
  appendAboveLiveTiming(historyEl, el, liveTurnTimingEl);
}

function updateLiveTiming() {
  const duration = elapsedSince(currentTiming.activeTurn?.started_at);
  if (liveTurnTimingEl && duration !== null) {
    liveTurnTimingEl.textContent = turnTimingText(liveTurnNumber, duration, { running: true });
  }
  updateInfoBar();
}

function finishLiveTurnTiming(record = null) {
  const duration = Number.isFinite(Number(record?.duration_ms))
    ? Number(record.duration_ms)
    : elapsedSince(currentTiming.activeTurn?.started_at);
  if (liveTurnTimingEl && duration !== null) {
    liveTurnTimingEl.classList.remove("live");
    const at = record ? currentTiming.turnRecords.indexOf(record) : -1;
    liveTurnTimingEl.textContent = turnTimingText(at >= 0 ? at + 1 : liveTurnNumber, duration);
  }
  currentTiming.activeTurn = null;
  clearTimingInterval();
  updateInfoBar();
}

function applyTiming(data) {
  currentTiming = normalizeTiming(data);
  if (turnRunning && currentTiming.activeTurn?.started_at) {
    startLiveTurnTiming(currentTiming.activeTurn.started_at);
  }
}

function updateFirstPeek() {
  if (currentCtxPct !== null && currentCtxPct > 20 && currentFirstPreview) {
    firstPeekEl.textContent = currentFirstPreview;
    firstPeekEl.classList.add("visible");
  } else {
    firstPeekEl.textContent = "";
    firstPeekEl.classList.remove("visible");
  }
}

function addUsedMemory(name) {
  const v = String(name||"").trim();
  if (!v || currentUsedMemories.includes(v)) return;
  currentUsedMemories.push(v);
  updateInfoBar();
  const sess = allSessions.find(s=>s.id===selected);
  if (sess) {
    sess.used_memory_names = sess.used_memory_names || [];
    if (!sess.used_memory_names.includes(v)) sess.used_memory_names.push(v);
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
    endTurnView("gone");
    addEndBubble(endText);
    if (!stopped) setLiveStatus("idle");
  }
  if (currentOwner === "worker") currentOwner = null;
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
    // Phase 2: route the chunk's bytes to the text bubble and the thinking
    // block (see chunk_router.js). Raw `content` is only used as a fallback
    // for pre-Phase-2 / non-enriched servers.
    const { text, thinking } = routeChunk(data);
    turnDom.chunk({ text, thinking, iteration: data.iteration ?? null });
    const pct = extractCtxPct(data, currentCtxWindow);
    if (pct !== null && !Number.isNaN(pct)) {
      currentCtxPct = pct;
      updateInfoBar();
      updateFirstPeek();
    }
  },
  generation_started: (data) => {
    if (data?.context_window_tokens) currentCtxWindow = data.context_window_tokens;
    turnDom.generationStarted(data || {});
  },
  generation_completed: (data) => {
    if (data?.served_model) {
      currentServed = [data.served_model, data.requested_model];
      updateInfoBar();
    }
    turnDom.generationCompleted();
  },
  // Prompts sent while a turn ran merge into it at an iteration boundary:
  // input_merged names them (their bubbles turn "steered"), then
  // pending_input_merged carries the merged text, shown only for prompts
  // this tab has no bubble for.
  input_merged: (data) => applyPromptOps(data),
  pending_input_merged: (data) => applyPromptOps(data),
  turn_enqueued: (data) => applyPromptOps(data),
  turn_started: (data) => keepFollowing(historyEl, () => {
    markRecapStale();
    applyPromptOps(data);
    setTurnRunning(true);
    setLiveStatus("running");
    clearTimingInterval();
    liveTurnTimingEl = null;
    turnDom.turnStarted(data);
    startLiveTurnTiming(data.started_at);
  }),
  turn_completed: async (data) => {
    endTurnView("completed");
    const out = turnOutput(data);
    if (out) appendChunk(out);
    if (selected) {
      try {
        const d = await getSession(selected, { tail: true });
        if (d.session) {
          if (Array.isArray(d.session.used_memory_names)) currentUsedMemories = d.session.used_memory_names;
          if (d.session.status) currentStatus = d.session.status;
          applyTiming(d.timing);
          finishLiveTurnTiming(currentTiming.turnRecords[currentTiming.turnRecords.length - 1]);
          setMarkdownWarning(d.markdown_warning);
          if (Array.isArray(d.messages)) applyFinalMarkdown(d.messages);
          updateInfoBar();
          const sess = allSessions.find(s=>s.id===selected);
          if (sess) {
            sess.used_memory_names = currentUsedMemories.slice();
            sess.status = currentStatus;
          }
          render();
          document.querySelectorAll(".card").forEach(el=>el.classList.toggle("active", el.dataset.id===selected));
        }
      } catch(_){}
    }
  },
  turn_canceled: (data) => {
    endTurnView("canceled");
    setLiveStatus("idle");
    addCancelBubble(data.cancellation_reason || "");
    refreshTimingFromSession();
  },
  // The turn raised (e.g. the model server stayed unreachable). The worker
  // stays up: it rolls the turn back and hands the prompt back
  // (prompt_restored), and the prompts queued behind it run as usual.
  turn_failed: (data) => {
    endTurnView("failed");
    setLiveStatus("idle");
    lastFailedText = failedTurnText(data);
    addEndBubble(lastFailedText);
  },
  // The rolled-back turn left the session: render it from the server again,
  // then show the prompt once more, marked failed (with why). This tab's own
  // prompt goes back into an empty composer.
  prompt_restored: async (data) => {
    const { refill, label, images: restoredImages } = restoreAction(data, { myId: clientId, sentIds, composerEmpty: !promptEl.value.trim() && !chips.length });
    if (refill) {
      promptEl.value = refill;
      fitPrompt();
    }
    if (restoredImages?.length) setChips(restoredChips(selected, restoredImages));
    const failedText = lastFailedText;
    lastFailedText = null;
    await resync();
    // Not an echo waiting for its turn_enqueued: it keeps its enqueued_id, so
    // a resend's echo isn't matched to it.
    makeUserBubble(data.prompt || "", { state: "failed", label, enqueuedId: data.origin?.enqueued_id || `failed:${Date.now()}`, images: data.images });
    if (failedText) addEndBubble(failedText);
  },
  // A session command ran in the worker (any client's). One that changed
  // the conversation (!rollback, !cmd, a continue answered no) re-reads it.
  command_ran: async (data) => {
    const view = commandView(data, clientId);
    if (view.modelName && view.modelName !== currentModel) {
      currentModel = view.modelName;
      currentServed = null;
      updateInfoBar();
    }
    if (view.resync) await resync();
    addCommandBubble(view);
  },
  // Due reminders went into the turn (a reminder turn has no prompt bubble).
  reminder_injected: (data) => addCommandBubble({ label: null, line: reminderText(data), text: "" }),
  // A context note joined the conversation (between turns; no turn runs).
  context_added: (data) => addNoteBubble({ label: data.label, content: data.text || "" }),
  continue_offered: (data) => renderContinueCard(data),
  continue_resolved: (data) => resolveContinueCard(data),
  tool_call_started: (data) => {
    turnDom.toolStarted(data);
    const call = data.call || {};
    let name = null;
    if (call.name === "memory_read" && call.content) {
      name = String(call.content).split(",")[0].trim();
      if (name) name = name.replace(/\.md$/,"").split("/").pop();
    } else if (call.name === "read" && call.content && /memories\/.+\.md/.test(call.content)) {
      name = String(call.content).split("/").pop().replace(/\.md$/,"");
    }
    if (name) addUsedMemory(name);
  },
  tool_call_completed: (data) => turnDom.toolCompleted(data),
  used_memories_updated: (data) => {
    if (Array.isArray(data.used_memory_names)) {
      currentUsedMemories = data.used_memory_names.slice();
      updateInfoBar();
    }
  },
  context_status: (data) => {
    const pct = data.est_pct ?? data.ctx_pct ?? extractCtxPct(data);
    if (pct !== null) {
      currentCtxPct = pct;
      updateInfoBar();
      updateFirstPeek();
    }
  },
  question_requested: (data) => {
    const pq = data.pending_question || data.pendingQuestion;
    if (pq && pq.id) renderQuestionCard(pq);
  },
  question_answered: (data) => {
    resolveQuestionCard(data.id, { answer: data.answer });
  },
  question_cancelled: (data) => {
    resolveQuestionCard(data.id, { cancelled: true, reason: data.reason });
  },
  // One collected just as a turn started describes the chat before it.
  recap_ready: (data) => { if (!turnRunning) showRecap(data.recap); },
  guardrail_warning: (data) => showGuardrailWarning(data.message),
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
  try {
    const data = await getSession(selected, { tail: true });
    if (data.session?.status) currentStatus = data.session.status;
    applyTiming(data.timing);
    finishLiveTurnTiming(currentTiming.turnRecords[currentTiming.turnRecords.length - 1]);
  } catch (_) {}
}


// ── ask_user_question card ─────────────────────────────────────────────────
// Inline card in the message history: rendered on question_requested (or from
// pending_question on session select for reload recovery), resolved/disabled
// on question_answered / question_cancelled so SSE replay and answers from
// another client converge to the same state.

function renderQuestionCard(pq) {
  if (questionCardEl && pendingQuestion && pendingQuestion.id === pq.id) return;
  removeQuestionCard();
  pendingQuestion = pq;
  removeHintIfEmpty();

  const approval = approvalView(pq);
  const card = document.createElement("div");
  card.className = approval ? "bubble question approval" : "bubble question";
  card.dataset.qid = pq.id;

  if (pq.header) {
    const head = document.createElement("div");
    head.className = "question-header";
    head.textContent = pq.header;
    card.appendChild(head);
  }

  if (approval) {
    card.appendChild(renderApprovalDetails(approval));
  } else {
    const q = document.createElement("div");
    q.className = "question-text";
    q.textContent = pq.question || "";
    card.appendChild(q);
  }

  const options = Array.isArray(pq.options) ? pq.options : [];
  if (options.length) {
    const list = document.createElement("div");
    list.className = "question-options";
    const inputType = pq.multi_select ? "checkbox" : "radio";
    options.forEach((label, i) => {
      const row = document.createElement("label");
      row.className = "question-option";
      const input = document.createElement("input");
      input.type = inputType;
      input.name = `q-${pq.id}`;
      input.value = String(label);
      input.dataset.index = String(i);
      const text = document.createElement("span");
      text.textContent = String(label);
      row.appendChild(input);
      row.appendChild(text);
      list.appendChild(row);
    });
    card.appendChild(list);
  }

  let freeformInput = null;
  if (pq.allow_freeform) {
    freeformInput = document.createElement("input");
    freeformInput.type = "text";
    freeformInput.className = "question-freeform";
    freeformInput.placeholder = approval ? "Reason for the model (with Deny, or alone to deny)…" : "Other…";
    card.appendChild(freeformInput);
  }

  const err = document.createElement("div");
  err.className = "question-error hidden";
  card.appendChild(err);

  const submit = document.createElement("button");
  submit.className = "question-submit";
  submit.textContent = "Submit";
  submit.addEventListener("click", () => {
    const chosen = Array.from(card.querySelectorAll(".question-option input:checked")).map((i) => i.value);
    const freeform = freeformInput ? freeformInput.value.trim() : "";
    if (!chosen.length && !freeform) {
      err.textContent = "Pick an option or enter a response.";
      err.classList.remove("hidden");
      return;
    }
    err.classList.add("hidden");
    submit.disabled = true;
    card.classList.add("submitting");
    sendAnswer(selected, {
      id: pq.id,
      selected: chosen,
      ...(freeform ? { freeform } : {}),
    }).catch((e) => {
      submit.disabled = false;
      card.classList.remove("submitting");
      err.textContent = /503|not_live/.test(e.message)
        ? "Session is not running — restart it to answer."
        : e.message;
      err.classList.remove("hidden");
    });
  });
  card.appendChild(submit);

  // Leaves the question unanswered, like an empty answer in the terminal.
  // The card closes on the question_cancelled every client gets.
  // For an approval, dismissing denies the call.
  const dismiss = document.createElement("button");
  dismiss.className = "question-dismiss ghost";
  dismiss.textContent = approval ? "Deny" : "Dismiss";
  dismiss.addEventListener("click", () => {
    err.classList.add("hidden");
    submit.disabled = true;
    dismiss.disabled = true;
    dismissQuestion(selected, pq.id).catch((e) => {
      submit.disabled = false;
      dismiss.disabled = false;
      err.textContent = /503|not_live/.test(e.message)
        ? "Session is not running — restart it to answer."
        : e.message;
      err.classList.remove("hidden");
    });
  });
  card.appendChild(dismiss);

  appendToHistory(card);
  questionCardEl = card;
  if (isNearBottom()) historyEl.scrollTop = historyEl.scrollHeight;
}

// The tool, the command (or paths) as code, where and why.
function renderApprovalDetails(view) {
  const box = document.createElement("div");
  box.className = "approval-details";
  const tool = document.createElement("div");
  tool.className = "approval-tool";
  tool.textContent = view.tool;
  box.appendChild(tool);
  const what = document.createElement("pre");
  what.className = view.isCommand ? "approval-what command" : "approval-what paths";
  const code = document.createElement("code");
  code.textContent = view.what;
  what.appendChild(code);
  box.appendChild(what);
  for (const [cls, label, text] of [["approval-where", "in", view.where], ["approval-why", "why", view.why]]) {
    if (!text) continue;
    const row = document.createElement("div");
    row.className = cls;
    const b = document.createElement("span");
    b.className = "approval-label";
    b.textContent = `${label} `;
    row.appendChild(b);
    row.appendChild(document.createTextNode(text));
    box.appendChild(row);
  }
  return box;
}

function resolveQuestionCard(id, { answer = null, cancelled = false, reason = "" } = {}) {
  if (!questionCardEl) return;
  if (id && pendingQuestion && String(pendingQuestion.id) !== String(id)) return;

  const note = document.createElement("div");
  note.className = "question-result";
  note.textContent = resultText(pendingQuestion, { answer, cancelled, reason });
  if (cancelled) {
    questionCardEl.classList.add("cancelled");
  } else {
    questionCardEl.classList.add("answered");
    if (approvalAllowed(pendingQuestion, answer) === false) questionCardEl.classList.add("denied");
    markQuestionSelection(answer && Array.isArray(answer.selected) ? answer.selected : []);
  }
  questionCardEl.appendChild(note);
  disableQuestionInputs();
  pendingQuestion = null;
}

function markQuestionSelection(sel) {
  if (!questionCardEl || !sel.length) return;
  questionCardEl.querySelectorAll(".question-option input").forEach((input) => {
    if (sel.includes(input.value)) {
      input.checked = true;
      input.closest(".question-option").classList.add("selected");
    }
  });
}

function disableQuestionInputs() {
  if (!questionCardEl) return;
  questionCardEl.querySelectorAll("input, button").forEach((el) => {
    el.disabled = true;
  });
}

function removeQuestionCard() {
  if (questionCardEl) {
    questionCardEl.remove();
    questionCardEl = null;
  }
  pendingQuestion = null;
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

async function handleCreate() {
  // A first message with images: an idle session, then the turn into it.
  if (chips.length) return handleSendTurn();
  const prompt = promptEl.value.trim();
  if (!prompt) return;
  actionBtn.disabled = true;
  createAltBtn.disabled = true;
  try {
    const s = await createSession(prompt, { dir: scope.dir });
    addCreatedSession(s);
    select(s.id);
    promptEl.value = "";
    fitPrompt();
  } catch (e) {
    alert(e.message);
  } finally {
    actionBtn.disabled = false;
    createAltBtn.disabled = false;
  }
}

async function handleSendTurn() {
  if (!selected && !chips.length) return handleCreate();
  if (currentOwner === "tui") return;
  const prompt = turnText(promptEl.value, chips);
  if (!prompt) return;
  if (!chips.length && isCommandLine(prompt)) return handleSendCommand(prompt);
  if (!selected) {
    actionBtn.disabled = true;
    try {
      const s = await createIdleSession({ dir: scope.dir });
      addCreatedSession(s);
      await select(s.id);
    } catch (e) {
      alert(e.message);
      return;
    } finally {
      actionBtn.disabled = false;
    }
  }
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  const sending = chips.slice();
  const echo = makeUserBubble(prompt, { state: "queued", own: true, images: sending });
  historyEl.scrollTop = historyEl.scrollHeight;
  if (!currentFirstPreview || currentFirstPreview==="—") {
    currentFirstPreview = normalize(prompt).slice(0,80) + (normalize(prompt).length>80?"…":"");
    updateInfoBar();
    updateFirstPeek();
  }
  actionBtn.disabled = true;
  try {
    for (const chip of sending) {
      if (!chip.ref) chip.ref = await uploadImage(selected, chip.file, chip.name);
    }
    const ack = await sendTurn(selected, prompt, { clientId, images: turnRefs(sending) });
    promptEl.value = "";
    fitPrompt();
    clearChips();
    // Its turn_enqueued usually tagged the echo already; the ack covers a
    // worker that wasn't live (no turn_enqueued then).
    if (ack?.enqueued_id) sentIds.add(ack.enqueued_id);
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
    // The chips stay (uploaded ones keep their ref) for another try.
    if (/images_unsupported|bad_image|too_large|restart it/.test(e.message)) {
      alert(e.message);
      return;
    }
    if (/owned_by_tui|409/.test(e.message)) {
      currentOwner = "tui";
      updateComposerMode();
      return;
    }
    alert(e.message);
  } finally {
    actionBtn.disabled = currentOwner === "tui";
    promptEl.focus();
  }
}

// /model, !ls, /continue no … run in the session's worker; every client
// shows the command_ran, this one too.
async function handleSendCommand(line) {
  actionBtn.disabled = true;
  try {
    await sendCommand(selected, line, { clientId });
    promptEl.value = "";
    fitPrompt();
    // The command woke the worker: follow its stream if none is open.
    if (!streamControl?.live) startStream(selected, selectSeq ?? 0);
  } catch (e) {
    if (/owned_by_tui|409/.test(e.message)) {
      currentOwner = "tui";
      updateComposerMode();
      return;
    }
    addCommandBubble({ label: null, line, text: e.message, failed: true });
  } finally {
    actionBtn.disabled = currentOwner === "tui";
    promptEl.focus();
  }
}

function addCommandBubble({ label, line, text, busy = false, failed = false }) {
  removeHintIfEmpty();
  const div = document.createElement("div");
  div.className = "bubble command" + (busy ? " busy" : "") + (failed ? " failed" : "");
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
  const follow = isNearBottom();
  appendToHistory(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
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

// ── continue card ──────────────────────────────────────────────────────────
// A turn ran out of iterations: continue it, drop it, or drop it saying why
// (the terminal's continue prompt). Answers go as /continue commands; the
// card closes on the continue_resolved every client gets.

const CONTINUE_DECISIONS = {
  resume: "Continued",
  abort: "Not continued",
  abort_with_reason: "Not continued (reason noted)",
  dropped: "Dropped: a new prompt came",
};

function renderContinueCard(offer) {
  if (continueCardEl?.isConnected) return;
  removeHintIfEmpty();
  const card = document.createElement("div");
  card.className = "bubble continue";
  const text = document.createElement("div");
  text.className = "continue-text";
  text.textContent = "The turn ran out of iterations. Continue it?";
  card.appendChild(text);
  const task = offer?.context?.original_prompt;
  if (task) {
    const ctx = document.createElement("div");
    ctx.className = "continue-context";
    ctx.textContent = task;
    card.appendChild(ctx);
  }
  const err = document.createElement("div");
  err.className = "question-error hidden";
  const answer = (line) => {
    err.classList.add("hidden");
    card.querySelectorAll("button, input").forEach((el) => { el.disabled = true; });
    sendCommand(selected, line, { clientId }).catch((e) => {
      card.querySelectorAll("button, input").forEach((el) => { el.disabled = false; });
      err.textContent = e.message;
      err.classList.remove("hidden");
    });
  };
  const yes = document.createElement("button");
  yes.className = "continue-yes";
  yes.textContent = "Yes";
  yes.addEventListener("click", () => answer(continueLine("yes")));
  const no = document.createElement("button");
  no.className = "continue-no ghost";
  no.textContent = "No";
  no.addEventListener("click", () => answer(continueLine("no")));
  const reason = document.createElement("input");
  reason.type = "text";
  reason.className = "continue-reason";
  reason.placeholder = "Why not? (the model reads it)";
  const noBecause = document.createElement("button");
  noBecause.className = "continue-no-reason ghost";
  noBecause.textContent = "No, because…";
  noBecause.addEventListener("click", () => {
    if (!reason.value.trim()) return reason.focus();
    answer(continueLine("no", reason.value));
  });
  const row = document.createElement("div");
  row.className = "continue-actions";
  [yes, no, reason, noBecause].forEach((el) => row.appendChild(el));
  card.appendChild(row);
  card.appendChild(err);
  const follow = isNearBottom();
  appendToHistory(card);
  continueCardEl = card;
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

function resolveContinueCard(data) {
  const card = continueCardEl;
  continueCardEl = null;
  if (!card) return;
  card.classList.add("resolved");
  card.querySelectorAll("button, input").forEach((el) => { el.disabled = true; });
  const note = document.createElement("div");
  note.className = "question-result";
  const who = isOwn(data.client_id, clientId) ? "" : ` (${clientLabel(data.client_id) || "another client"})`;
  note.textContent = (CONTINUE_DECISIONS[data.decision] || data.decision || "Answered") + who;
  card.appendChild(note);
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
$("#newBtn").addEventListener("click", () => {
  if (allViewOpen()) leaveAllView("");
  clearSelection();
});
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
  const follow = isNearBottom();
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
historyEl.addEventListener("click", (e) => {
  const img = e.target.closest("img.thumb");
  if (!img) return;
  lightboxEl.querySelector("img").src = img.src;
  lightboxEl.hidden = false;
});
lightboxEl.addEventListener("click", () => { lightboxEl.hidden = true; });
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !lightboxEl.hidden) lightboxEl.hidden = true;
});
cancelBtn.addEventListener("click", () => handleCancel());
createAltBtn.addEventListener("click", () => handleCreate());
promptEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    if (!selected) handleCreate();
    else handleSendTurn();
  }
});
actionMenuBtn.addEventListener("click", () => {
  actionMenu.classList.toggle("visible");
});
actionMenu.querySelectorAll("button").forEach(btn=>{
  btn.addEventListener("click", ()=>{
    const act = btn.dataset.action;
    actionMenu.classList.remove("visible");
    if(act==="send") handleSendTurn();
    else if(act==="create") handleCreate();
  });
});
document.addEventListener("click", (e)=>{
  if(!composerEl.contains(e.target)) actionMenu.classList.remove("visible");
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
      currentStatus = "stopped";
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

// ── Annotate ───────────────────────────────────────────────────────────────
// Selecting text in an answer, thinking, a tool row or an own message shows
// "Annotate"; it appends the quote (with where it came from) to the
// composer. The button lives outside #history, which is re-rendered whole.
// The selection is read when it changes: a live bubble rewrites its text
// every frame, which would collapse it by the time the button is clicked.

const annotateBtn = document.createElement("button");
annotateBtn.id = "annotateBtn";
annotateBtn.type = "button";
annotateBtn.textContent = "Annotate";
annotateBtn.hidden = true;
document.body.appendChild(annotateBtn);
let pendingQuote = null;

function hideAnnotate() {
  pendingQuote = null;
  annotateBtn.hidden = true;
}

function updateAnnotate() {
  const sel = window.getSelection();
  if (!selected || currentOwner === "tui" || !sel || sel.isCollapsed || !sel.rangeCount) return hideAnnotate();
  const range = sel.getRangeAt(0);
  if (!historyEl.contains(range.startContainer)) return hideAnnotate();
  const source = annotationSource(range.startContainer);
  // A running turn's thinking (and, in the turn view, its narration) is
  // rewritten every frame.
  if (!source || (turnRunning && turnDom.containsLive(source.root))) return hideAnnotate();
  // Clip to where the selection starts: one tool row, one bubble.
  const clipped = range.cloneRange();
  if (!source.root.contains(range.endContainer)) clipped.setEnd(source.root, source.root.childNodes.length);
  const block = quoteBlock(clipped.toString(), source);
  if (!block) return hideAnnotate();
  pendingQuote = block;
  const rects = clipped.getClientRects();
  const rect = rects.length ? rects[rects.length - 1] : clipped.getBoundingClientRect();
  annotateBtn.hidden = false;
  const top = Math.min(rect.bottom + 6, window.innerHeight - annotateBtn.offsetHeight - 8);
  const left = Math.min(Math.max(rect.right - annotateBtn.offsetWidth, 8), window.innerWidth - annotateBtn.offsetWidth - 8);
  annotateBtn.style.top = `${Math.max(top, 8)}px`;
  annotateBtn.style.left = `${left}px`;
  // Not over a copy button (this bubble's, one inside it, the next
  // bubble's).
  const box = annotateBtn.getBoundingClientRect();
  const bubble = source.root.closest(".bubble");
  const near = [bubble, bubble?.nextElementSibling].filter(Boolean);
  for (const btn of near.flatMap((el) => [...el.querySelectorAll(".copy-btn")])) {
    const r = btn.getBoundingClientRect();
    if (r.bottom < box.top || r.top > box.bottom || r.right < box.left || r.left > box.right) continue;
    annotateBtn.style.top = `${r.bottom + 4}px`;
    break;
  }
}

let annotateRaf = false;
function scheduleAnnotate() {
  if (annotateRaf) return;
  annotateRaf = true;
  requestAnimationFrame(() => { annotateRaf = false; updateAnnotate(); });
}
document.addEventListener("selectionchange", scheduleAnnotate);
historyEl.addEventListener("scroll", scheduleAnnotate);
window.addEventListener("resize", scheduleAnnotate);
installCopy(historyEl);
// Keep the selection when the button is pressed.
annotateBtn.addEventListener("mousedown", (e) => e.preventDefault());
annotateBtn.addEventListener("click", () => {
  if (!pendingQuote) return;
  promptEl.value = appendQuote(promptEl.value, pendingQuote);
  fitPrompt();
  window.getSelection()?.removeAllRanges();
  hideAnnotate();
  promptEl.focus();
  promptEl.setSelectionRange(promptEl.value.length, promptEl.value.length);
  promptEl.scrollTop = promptEl.scrollHeight;
});

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
function setStripHidden(hidden) {
  try { localStorage.setItem("chi_strip_hidden", hidden ? "1" : "0"); } catch (_) {}
  document.body.classList.toggle("strip-hidden", hidden);
}
setStripHidden(stripHiddenSaved());
$("#stripShow").addEventListener("click", () => setStripHidden(false));
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && actionMenu.classList.contains("visible")) actionMenu.classList.remove("visible");
});

$("#filter").addEventListener("input", renderAll);
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
// The list: the hub's stream when the browser has EventSource, else fetched.
if (typeof globalThis.EventSource === "function") openSessionEvents();
else refresh();
selectFromHash();
