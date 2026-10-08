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
  listContext,
  getContext,
  detachContext,
  addContext,
} from "./data.js";
import { createContextChips } from "./context_chips.js";
import { chipHtml as llmContextChipHtml, createLlmContextControl } from "./llm_context_chip.js";
import { renderStable } from "./stable_html.js";
import { createShownTexts } from "./shown_texts.js";
import { MODEL_KEY } from "./model_pick.js";
import { emptySessionState } from "./session_state.js";
import { createModelPicker } from "./model_picker.js";
import { chipName, chipsHtml, imageFiles, restoredChips, thumbsHtml, turnRefs, turnText } from "./images.js";
import { escapeHtml, memChipText, memChipTitle, noteHtml, normalize, steerRowHtml, ownerBadge, previewForCard, relativeTime, failedTurnText, modelLabel, deleteConfirmText, recapLabel, canStopSession, goneSessionNotice, withLiveStatus, withoutWorker, recapPlace, delegatedBy, childrenSummary, promptNotesChip } from "./format.js";
import { createTurnView, turnHistoryHtml } from "./turn_view.js";
import { BADGES, emptyAnswerHtml, htmlElement, stateBadgeHtml, userBubbleHtml } from "./turn_html.js";
import { createStageView } from "./stage_view.js";
import { createFamilyPop, familyChipHtml, familyRowsHtml } from "./families_view.js";
import { createTaskStopper } from "./task_stop.js";
import { appendQuote } from "./annotations.js";
import { parsePresets } from "./annotate_presets.js";
import { createAnnotateBar } from "./annotate_bar.js";
import { COPY_SOURCE_ATTR, copySource, copyText, installCopy, showsAnswer } from "./copy.js";
import { routeChunk } from "./chunk_router.js";
import { extractCtxPct, savedCtxPct, cardCtxText, generationTokens, lastSpeedText, speedText, tokensTipText } from "./ctx.js";
import { createQuestionCards } from "./question_cards.js";
import { cardClass, cardInnerHtml, cardPlace, isCard, isNoticeCard, noticeInnerHtml, shownElsewhere, splitSnapshotCards, turnNoticePlace } from "./card.js";
import { PROMPT_LINE_PX, PROMPT_MIN_PX, gripFloor, promptHeight } from "./composer_size.js";
import { createCommandList } from "./command_list.js";
import { createPromptHistory } from "./prompt_history.js";
import { ALL_SESSIONS_HASH, sessionHash, sessionIdFromHash } from "./route.js";
import { allScopeHref, cardFolder, projectScopeHref, scopeDir } from "./scope.js";
import { shouldFollowScroll, keepFollowing } from "./scroll.js";
import { SHORT_WINDOW_QUERY, stripAutoHidden, stripColumns, stripShowParts } from "./strip.js";
import { applySessionEvent, batchCounts, batchTargets, batchToastText, families, familyId, familyOpen, familyWaits, filterFamilies, flattenFamilies, heldOrder, inTree, rangeIds, runBatch, listedSessions, sortedByUpdated, stoppedBadge, waitingBadge, waitingFirst, waitingSearchText } from "./sessions_list.js";
import { createNotifications } from "./notifications.js";
import { restartConfirmText, versionNotice, workerBadge } from "./update_notice.js";
import {
  appendAboveLiveTiming, cancelLineText, elapsedSince, formatDuration, mergeTiming, normalizeTiming, STOPPED_LINE_CLASS,
} from "./timing.js";
import { createLiveTurn } from "./live_turn.js";
import { DONE_MS, applyInitEvent, dropDone, initRowHtml, newInitTasks, seedInitTasks } from "./init_row.js";
import { clientLabel, commandView, isReportClient, displayWait, dropEarlyRestores, emptyRetryLine, hookNoticeLabel, initWaitLine, isOwn, sessionCommandLine, keepEarlyRestore, newClientId, noticeLine, promptOps, reminderText, restoreAction, composerAfterAck, restoreOnAck, replaysDrawnTurn, retryStatusLine, snapshotEvents, steerCutLine, startPageReplyOrHint, turnOutput, unknownCommandHint, webLocalReply, workerGoneText } from "./turn_events.js";

const $ = (s) => document.querySelector(s);
const topStripEl = $("#topStrip");
const allListEl = $("#allList");
const historyEl = $("#history");
const emptyEl = $("#empty");
const composerEl = $("#composer");
const infoBarEl = $("#infoBar");
const firstPeekEl = $("#firstPeek");
const infoTextEl = $("#infoText");
// The open session's attached context, in its own row of the session bar
// (updateInfoBar redraws #infoText every tick; the chips keep their popover).
const contextChips = createContextChips({
  el: $("#contextChips"),
  api: { list: listContext, show: getContext, detach: detachContext, add: addContext },
  escapeHtml,
  toast: (text) => showToast(text),
});
// The open session's LLM context chip in the info bar, and its popover:
// /llm-context runs in the session's worker.
const llmContextControl = createLlmContextControl({
  el: infoTextEl,
  escapeHtml,
  summary: () => (selected ? current.llmContext : null),
  session: () => selected,
  running: () => liveTurn.running,
  run: (line) => runSessionCommand(line),
});
const markdownWarningEl = $("#markdownWarning");
// What the page renders that a notice may stand in for (the server's
// Web::Capabilities, next to markdown_warning); a notice it names isn't
// drawn (shownElsewhere). An older server sends none: every notice shows.
let pageCapabilities = {};
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
// The running turn's texts on the page (the turn output dedupe).
const shownTexts = createShownTexts();
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
  sawText: (k) => shownTexts.saw(k),
  sessionId: () => selected,
  // The stop-task button on a running task_wait, for a worker that has
  // the route (its sidecar features).
  taskStop: createTaskStopper({ sessionId: () => selected, features: () => current.workerFeatures }),
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
// The running turn as the page follows it (live_turn.js): whether one
// runs, its timing line and the turns this page saw end (live_timing.js),
// its merges' bubble flags, its turn-end reads.
const liveTurn = createLiveTurn({
  timing: () => current.timing,
  // The stage's status row while it holds the turn (the line moves into
  // the history with it), else the history.
  place: (el) => {
    const stageHost = turnDom.timingHost?.() || null;
    (stageHost || historyEl).appendChild(el);
    return !!stageHost;
  },
  onTick: () => updateInfoBar(),
});

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
// The stream was opened from 0 (a wake with no cursor to go on) and no
// new turn has started on it yet: see followWokenWorker.
let streamFromGuess = false;
// The enqueued_ids this page sent (from the /turn acks): only these come back
// into the composer when their turn fails.
const sentIds = new Set();
// Own prompt_restored events that came before their /turn ack, by
// enqueued_id: the ack puts that prompt back instead of clearing it.
const earlyRestores = new Map();

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
    notifications.noticeList(allSessions);
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
      else if (selected && data.session?.parent_id === selected) updateInfoBar(); // its children chip
    },
    session_gone: (data) => {
      notifications.noticeSessions("session_gone", data);
      selecting.picked.delete(data.id);
      selecting.skipReasons.delete(data.id);
      const next = applySessionEvent(allSessions, "session_gone", data);
      if (next !== allSessions) {
        allSessions = next;
        render();
        if (selected) updateInfoBar(); // a deleted child leaves the children chip
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

function filterQuery() {
  return $("#filter").value.trim().toLowerCase();
}

// Whether a session matches the all view's search +q+ (lower case).
function matchesFilter(s, q) {
  return previewForCard(s).toLowerCase().includes(q) ||
    (s.first_preview || "").toLowerCase().includes(q) ||
    s.short_id.toLowerCase().includes(q) ||
    s.id.toLowerCase().includes(q) ||
    s.status.toLowerCase().includes(q) ||
    waitingSearchText(s).includes(q);
}

// A card: the first message as its title, then status, how long ago, owner
// and memories. The id is in the tooltip (and the search) only. A session
// that waits on the user (a question, an approval, a card with actions)
// wears the warning colour and says what for.
// deletable / archivable: the all-sessions view's cards get a delete and an
// archive (unarchive, on an archived card) button. selectable: select mode's
// checkbox instead (picked: checked), and skipReason: why a batch skipped it.
// family: the family the session heads (sessions_list.js families): with
// members, its chip (which opens their list), and the card waits when any
// member does; with rows (all sessions) an open family lists its members
// inline, the strip's opens in a popover; matchIds: a search's matching
// members.
function cardHtml(s, { deletable = false, archivable = false, selectable = false, picked = false, skipReason = null, family = null, open = false, rows = false, matchIds = null } = {}) {
  const fam = family && family.members.length ? family : null;
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
  const ctxHtml = ctx ? `<span class="ctx" title="${escapeHtml(tokensTipText(s.tokens, undefined, s.memory_index))}">${escapeHtml(ctx)}</span>` : "";
  const waiting = waitingBadge(s);
  const waitingHtml = waiting ? `<span class="attn attn-${waiting.kind}" title="${escapeHtml(waiting.title)}">${escapeHtml(waiting.text)}</span>` : "";
  // A turn a hook stopped wears its own badge, unless the session waits on
  // the user (the waiting badge wins: the stop is behind the need).
  const stopped = waiting ? null : stoppedBadge(s);
  const stoppedHtml = stopped ? `<span class="stopped-badge" title="${escapeHtml(stopped.title)}">${escapeHtml(stopped.text)}</span>` : "";
  const dotWord = waiting ? waiting.title : s.status;
  const pickHtml = selectable ? `<input type="checkbox" class="card-pick" aria-label="Select session ${escapeHtml(s.short_id)}"${picked ? " checked" : ""}>` : "";
  const skipHtml = skipReason ? `<div class="skip-reason">skipped: ${escapeHtml(skipReason)}</div>` : "";
  const familyWaiting = !!fam && familyWaits(fam);
  const kidsHtml = fam ? familyChipHtml(fam, { open }) : "";
  const rowsHtml = fam && rows && open ? familyRowsHtml(fam, { activeId: selected, matchIds, archivable: !selectable }) : "";
  const membersAttr = fam ? ` data-members="${escapeHtml(fam.members.map((m) => m.session.id).join(" "))}"` : "";
  return `<div class="card${s.archived ? " archived" : ""}${waiting || familyWaiting ? " waiting" : ""}${selectable && picked ? " picked" : ""}${fam && rows && open ? " family-open" : ""}" data-id="${s.id}"${membersAttr} title="${escapeHtml(tip)}${memTitle ? ` · ${escapeHtml(memTitle)}` : ""}"><div class="preview">${preview}</div>${s.recap ? `<div class="recap" title="${escapeHtml(s.recap)}">${escapeHtml(s.recap)}</div>` : ""}<div class="meta"><span class="status dot ${escapeHtml(s.status)}${waiting ? " waiting" : ""}" title="${escapeHtml(dotWord)}" aria-label="${escapeHtml(dotWord)}"></span>${waitingHtml}${stoppedHtml}${timeHtml}${ctxHtml}${folderHtml}${parentChipHtml(s)}${kidsHtml}${ownerBadgeHtml(s)}${archivedHtml}</div>${rowsHtml}${skipHtml}${pickHtml}${selectable ? "" : cardToolsHtml(s, { deletable, archivable })}</div>`;
}

function cardToolsHtml(s, { deletable, archivable }) {
  if (!deletable && !archivable) return "";
  const short = escapeHtml(s.short_id);
  const arch = !archivable ? "" : s.archived
    ? `<button type="button" class="card-arch" data-arch="${escapeHtml(s.id)}" title="Unarchive: back to the lists" aria-label="Unarchive session ${short}"></button>`
    : `<button type="button" class="card-arch" data-arch="${escapeHtml(s.id)}" title="Archive: hide from the lists, keep for good" aria-label="Archive session ${short}"></button>`;
  const del = deletable ? `<button type="button" class="card-del" data-del="${escapeHtml(s.id)}" title="Delete session" aria-label="Delete session ${short}">\u2715</button>` : "";
  return `<div class="card-tools">${arch}${del}</div>`;
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

// The order a list draws its cards in: +next+, what waits on the user
// first (waitingFirst), back to its place once answered. Never under the
// pointer, though: while it is over the list the order last drawn holds,
// and its leaving draws the list again. +idOf+ names a card: a session's
// id, or familyId (a card per family: its head's id). drawnOrder is the
// cards drawn, which select mode picks from.
const drawnOrder = new Map(); // list element → card ids in the order last drawn
const heldLists = new Set(); // lists drawn in a held order
const canHover = globalThis.matchMedia?.("(hover: hover)").matches ?? false;
function listOrder(el, next, idOf = (s) => s.id) {
  // The strip's popover holds it too (the pointer leaves the strip for it,
  // and a touch screen has no hover at all).
  const holding = (canHover && el.matches(":hover")) || (el === topStripEl && familyPop.isOpen());
  const held = holding ? drawnOrder.get(el) : null;
  const ordered = held ? heldOrder(held, next, idOf) : next;
  if (held && ordered.some((x, i) => idOf(x) !== idOf(next[i]))) heldLists.add(el);
  else heldLists.delete(el);
  drawnOrder.set(el, ordered.map(idOf));
  return ordered;
}

// The strip's cards: families in the list's order (a family in its
// first-listed member's place, so a hub upsert doesn't move it), waiting
// ones first, as many as fit. A family is one card.
function stripCards() {
  return listOrder(topStripEl, waitingFirst(families(shownSessions(), { order: "list" })), familyId).slice(0, stripCols);
}

// The strip's family popover (families_view.js): the open family's rows,
// under its chip.
let stripFamilies = new Map(); // head id → family, as the strip last drew it
const familyPop = createFamilyPop({
  doc: document,
  win: window,
  rowsFor: (id) => {
    const f = stripFamilies.get(id);
    return f && f.members.length ? familyRowsHtml(f, { activeId: selected }) : null;
  },
  anchorFor: (id) => [...topStripEl.querySelectorAll(".card[data-id] .family-chip")].find((chip) => chip.closest(".card").dataset.id === id) || null,
  onPick: (id) => {
    familyPop.close();
    select(id);
  },
  // A strip order held while it was open catches up (unless the pointer is
  // back over the strip: its leaving does it then).
  onClose: () => {
    if (heldLists.has(topStripEl) && !(canHover && topStripEl.matches(":hover"))) renderTop(stripCards());
  },
});
window.addEventListener("keydown", (e) => familyPop.onKeydown(e), true);
document.addEventListener("pointerdown", (e) => familyPop.onPointerDown(e), true);
document.addEventListener("scroll", () => familyPop.reposition(), true);

function render() {
  fitStripColumns();
  renderTop(stripCards());
  if (allViewOpen()) renderAll();
}

let stripResizeTimer = null;
window.addEventListener("resize", () => {
  clearTimeout(stripResizeTimer);
  stripResizeTimer = setTimeout(() => {
    const before = stripCols;
    fitStripColumns();
    if (stripCols !== before && allSessions.length) renderTop(stripCards());
    familyPop.reposition();
  }, 150);
});

// onPick: a card's click (open it, or pick it in select mode); onFamily:
// a family chip's (toggle its list); onRow: a family row's (open that
// delegate).
function bindCards(container, onPick, { onFamily = () => {}, onRow = () => {} } = {}) {
  container.querySelectorAll(".card[data-id]").forEach((el) => {
    el.addEventListener("click", (e) => {
      const chip = e.target.closest(".family-chip");
      if (chip) {
        e.stopPropagation();
        onFamily(el.dataset.id, chip, e);
        return;
      }
      const del = e.target.closest(".card-del");
      if (del) {
        e.stopPropagation();
        confirmDelete(del.dataset.del);
        return;
      }
      // Archive from the list: the view stays open, the toast has Undo.
      const arch = e.target.closest(".card-arch");
      if (arch) {
        e.stopPropagation();
        const id = arch.dataset.arch;
        setArchived(id, !allSessions.find((x) => x.id === id)?.archived);
        return;
      }
      const row = e.target.closest(".family-row[data-id]");
      if (row) {
        e.stopPropagation();
        onRow(row.dataset.id, e);
        return;
      }
      onPick(el.dataset.id, e);
    });
  });
  paintActive();
}

// The open session's marks: its card (.active), its row in a family's list
// (in a card or the strip's popover), and a quieter .contains-active on the
// card of the family it is folded into.
function paintActive() {
  document.querySelectorAll(".card[data-id]").forEach((el) => {
    el.classList.toggle("active", !!selected && el.dataset.id === selected);
    el.classList.toggle("contains-active", !!selected && (el.dataset.members || "").split(" ").includes(selected));
  });
  document.querySelectorAll(".family-row[data-id]").forEach((el) => {
    el.classList.toggle("active", !!selected && el.dataset.id === selected);
  });
}

// The latest sessions (as many as fit, a family one card), then the way
// to all of them.
function renderTop(cards) {
  topStripEl.classList.remove("loading");
  renderStripShow();
  stripFamilies = new Map(cards.map((f) => [f.head.id, f]));
  if (scopeError) {
    topStripEl.innerHTML = `<div class="hint scope-error">${escapeHtml(scopeError)} · <a href="${escapeHtml(allScopeHref("", null, location.search))}">show every session</a></div>`;
    familyPop.close();
    return;
  }
  // Only archived sessions: no cards, but the tile stays, the way to them.
  if (!allSessions.length) {
    topStripEl.innerHTML = "";
    familyPop.close();
    return;
  }
  const n = shownSessions().length;
  const count = n || allSessions.length === n
    ? `${n} ${n === 1 ? "session" : "sessions"}`
    : `${allSessions.length - n} archived`;
  const tile = `<div class="strip-side"><button type="button" class="card" id="allTile" title="All sessions, with search">All sessions →<span class="count">${count}</span></button><button type="button" class="strip-toggle" id="stripHide" title="Hide the latest sessions">hide ▴</button></div>`;
  topStripEl.innerHTML = cards.map((f) => cardHtml(f.head, { family: f, open: familyPop.openHead() === f.head.id })).join("") + tile;
  bindCards(topStripEl, select, {
    onFamily: (id, _chip, e) => {
      familyPop.toggle(id);
      // From the keyboard (Enter / Space: no pointer, detail 0) the focus
      // goes into the popover, which sits at the end of body; Esc brings it back.
      if (e.detail === 0 && familyPop.isOpen()) $("#familyPop .fr-open")?.focus();
    },
  });
  $("#allTile").addEventListener("click", openAllView);
  $("#stripHide").addEventListener("click", () => setStripHidden(true));
  familyPop.refresh();
}

// The hidden strip's pill: "▾ 5 sessions · ● 1 live · ● 1 waiting",
// following the list: its cards (a family is one), the live and waiting
// sessions (a waiting delegate too).
function renderStripShow() {
  const shown = shownSessions();
  const { count, live, waiting } = stripShowParts(shown, { cards: families(shown).length });
  const liveHtml = live ? ` · <span class="live"><span class="live-dot" aria-hidden="true"></span>${escapeHtml(live)}</span>` : "";
  const waitingHtml = waiting ? ` · <span class="waiting"><span class="waiting-dot" aria-hidden="true"></span>${escapeHtml(waiting)}</span>` : "";
  $("#stripShow").innerHTML = `<span class="pill-arrow" aria-hidden="true">\u25BE</span> ${escapeHtml(count)}${liveHtml}${waitingHtml}`;
}

// A parent's card holds its delegates (families, by the newest member: a
// hub snapshot hands the list back in the server's order), folded unless
// one waits on the user, a search matched one or the user opened it. The
// search runs over the families, so a matching delegate brings its parent's
// card along. Select mode picks cards (a family's rows have no checkbox:
// archiving the parent takes its delegates).
const familyToggles = new Map(); // head id → open, the user's chip clicks (this page's life)
const searchToggles = new Map(); // the same while a search matched a member; a new search clears it
const drawnOpen = new Map(); // head id → open as last drawn in all sessions

function renderAll() {
  const listed = allViewSessions();
  const q = filterQuery();
  const all = families(listed);
  const shown = q ? filterFamilies(all, (s) => matchesFilter(s, q)) : all;
  const fams = listOrder(allListEl, waitingFirst(shown), familyId);
  const delegates = all.reduce((n, f) => n + f.members.length, 0);
  $("#count").textContent = fams.length === all.length
    ? `${all.length}${delegates ? ` (+${delegates} ${delegates === 1 ? "delegate" : "delegates"})` : ""}`
    : `${fams.length} / ${all.length}`;
  updateSelectBar();
  if (!fams.length) {
    drawnOpen.clear();
    allListEl.innerHTML = `<div class="hint">${listed.length ? "No session matches." : "No sessions yet."}</div>`;
    return;
  }
  // A hub event redraws the list under a checkbox or a chip the keyboard is on.
  const focused = document.activeElement?.matches?.("#allList .card-pick, #allList .family-chip")
    ? { id: document.activeElement.closest(".card")?.dataset.id, sel: document.activeElement.matches(".card-pick") ? ".card-pick" : ".family-chip" } : null;
  const opts = (s) => (selecting.on
    ? { selectable: true, picked: selecting.picked.has(s.id), skipReason: selecting.skipReasons.get(s.id) }
    : { deletable: true, archivable: true });
  drawnOpen.clear();
  allListEl.innerHTML = fams.map((f) => {
    const matched = !!f.matchIds?.size;
    const open = familyOpen(f, matched ? searchToggles : familyToggles, { matched });
    drawnOpen.set(f.head.id, open);
    return cardHtml(f.head, { ...opts(f.head), family: f, open, rows: true, matchIds: q ? f.matchIds : null });
  }).join("");
  bindCards(allListEl, (id, e) => {
    if (selecting.on) {
      togglePick(id, e);
      return;
    }
    leaveAllView(sessionHash(id));
    select(id);
  }, {
    onFamily: (headId) => {
      const matched = !!q && !!fams.find((f) => f.head.id === headId)?.matchIds?.size;
      (matched ? searchToggles : familyToggles).set(headId, !drawnOpen.get(headId));
      renderAll();
    },
    // In select mode a row does nothing: rows aren't picked.
    onRow: (id) => {
      if (selecting.on) return;
      leaveAllView(sessionHash(id));
      select(id);
    },
  });
  if (focused?.id) allListEl.querySelector(`.card[data-id="${focused.id}"] ${focused.sel}`)?.focus();
}

// ── Select mode (all sessions) ─────────────────────────────────────────────
// "Select" turns the cards into picks: a click (or Shift-click, a range in
// the drawn order) toggles one instead of opening it, and the bar acts on
// the picked ones that are shown. The picks live here, not in the DOM:
// renderAll draws the list again on every hub event.
const selecting = {
  on: false,
  picked: new Set(),
  last: null, // the last toggled id: a Shift-click's range starts there
  skipReasons: new Map(), // id → why the last batch skipped it
  running: null, // {done, total, archive} while a batch runs
};

function enterSelect() {
  selecting.on = true;
  renderAll();
}

function leaveSelect() {
  selecting.on = false;
  selecting.picked.clear();
  selecting.last = null;
  selecting.skipReasons.clear();
  if (allViewOpen()) renderAll();
  else updateSelectBar();
}

function togglePick(id, e) {
  if (selecting.running) return; // the grid reflows while a batch runs
  const order = drawnOrder.get(allListEl) || [];
  const on = !selecting.picked.has(id);
  const ids = e?.shiftKey ? rangeIds(order, selecting.last, id) : [id];
  for (const x of ids) {
    if (on) selecting.picked.add(x);
    else selecting.picked.delete(x);
    paintPick(x);
  }
  selecting.last = id;
  updateSelectBar();
}

// A card's pick state in place (no redraw: the focus stays put).
function paintPick(id) {
  const el = allListEl.querySelector(`.card[data-id="${id}"]`);
  if (!el) return;
  const on = selecting.picked.has(id);
  el.classList.toggle("picked", on);
  const box = el.querySelector(".card-pick");
  if (box) box.checked = on;
}

// The bar's numbers: picks of sessions still in the list (a snapshot can
// drop one with no session_gone), and the shown ones a batch would act on.
function selectCounts() {
  const byId = new Map(allSessions.map((s) => [s.id, s]));
  const shown = drawnOrder.get(allListEl) || [];
  const shownSet = new Set(shown);
  const live = [...selecting.picked].filter((id) => byId.has(id));
  return {
    picked: live.length,
    hidden: live.filter((id) => !shownSet.has(id)).length,
    archive: batchTargets(selecting.picked, shown, true, byId),
    unarchive: batchTargets(selecting.picked, shown, false, byId),
  };
}

function updateSelectBar() {
  $("#allView").classList.toggle("selecting", selecting.on);
  $("#selectBtn").hidden = selecting.on;
  const bar = $("#selectBar");
  bar.hidden = !selecting.on;
  if (!selecting.on) return;
  const c = selectCounts();
  const run = selecting.running;
  $("#selectCount").textContent = run
    ? `${run.archive ? "Archiving" : "Unarchiving"} ${run.done}/${run.total}\u2026`
    : `${c.picked} selected${c.hidden ? ` \u00b7 ${c.hidden} not shown` : ""}`;
  $("#batchArchiveBtn").textContent = `Archive ${c.archive.length}`;
  $("#batchArchiveBtn").disabled = !!run || !c.archive.length;
  $("#batchUnarchiveBtn").textContent = `Unarchive ${c.unarchive.length}`;
  $("#batchUnarchiveBtn").hidden = !c.unarchive.length;
  $("#batchUnarchiveBtn").disabled = !!run;
  $("#selectAllBtn").disabled = !!run;
  $("#selectDoneBtn").disabled = !!run;
}

// The batch: the picked shown ones, one request at a time in the drawn
// order (parents before their delegates), through the info bar's
// archiveOne. A refused one stays picked with the server's reason on its
// card; the end toast's Undo runs the opposite batch on the ones that went.
async function runSelectBatch(archive) {
  if (selecting.running) return;
  const byId = new Map(allSessions.map((s) => [s.id, s]));
  const ids = batchTargets(selecting.picked, drawnOrder.get(allListEl) || [], archive, byId);
  if (!ids.length) return;
  selecting.skipReasons.clear();
  const outcome = await archiveBatch(ids, archive);
  if (!outcome) return;
  if (!allViewOpen()) leaveSelect(); // left the view while it ran
  else renderAll();
  showToast(batchToastText(batchCounts(outcome, archive)), outcome.done.length ? {
    label: "Undo",
    run: async () => {
      const undone = await archiveBatch(outcome.done, !archive);
      if (!undone) return;
      if (allViewOpen()) renderAll();
      showToast(batchToastText(batchCounts(undone, !archive)));
    },
  } : null);
}

// runBatch over archiveOne, with the bar's progress; the picks and skip
// reasons follow the outcome. null when a batch already runs.
async function archiveBatch(ids, archive) {
  if (selecting.running) return null;
  selecting.running = { done: 0, total: ids.length, archive };
  updateSelectBar();
  try {
    const outcome = await runBatch(ids, async (id) => {
      const answer = await archiveOne(id, archive);
      if (answer.ok) {
        render();
        updateInfoBar();
      }
      return answer;
    }, (done) => {
      selecting.running.done = done;
      updateSelectBar();
    });
    for (const id of [...outcome.done, ...outcome.covered, ...outcome.gone]) {
      selecting.picked.delete(id);
      selecting.skipReasons.delete(id);
    }
    for (const { id, reason } of outcome.skipped) selecting.skipReasons.set(id, reason);
    return outcome;
  } finally {
    selecting.running = null;
    updateSelectBar();
    if (!eventsControl) refresh();
  }
}

$("#batchArchiveBtn").addEventListener("click", () => runSelectBatch(true));
$("#batchUnarchiveBtn").addEventListener("click", () => runSelectBatch(false));
$("#selectBtn").addEventListener("click", enterSelect);
$("#selectDoneBtn").addEventListener("click", leaveSelect);
$("#selectAllBtn").addEventListener("click", () => {
  for (const id of drawnOrder.get(allListEl) || []) {
    selecting.picked.add(id);
    paintPick(id);
  }
  updateSelectBar();
});
// A Shift-click picks a range: keep the browser from selecting the text
// between the two cards.
allListEl.addEventListener("mousedown", (e) => {
  if (selecting.on && e.shiftKey) e.preventDefault();
});

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
    // A running batch ends on its own and clears the picks then.
    if (selecting.on && !selecting.running) leaveSelect();
    topStripEl.scrollLeft = 0; // a phone's strip scrolls sideways to the tile
  }
  document.body.classList.toggle("all-view", open);
  if (open) {
    familyPop.close(); // the strip is hidden in the all view
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

// The key hint under the composer (shown while it has focus; on the start
// page only: in a session the placeholder carries it, the hint row is gone).
const SEND_HINT = "Enter to send · Shift+Enter for a newline · ↑ history";

let hadSession = false;
// While a turn runs, Send still sends: the prompt merges into the turn at
// its next step (steering). Cancel is its own button then.
function updateComposerMode() {
  // In a session the box is one line: its minimum follows the class.
  if (document.body.classList.toggle("has-session", !!selected) !== hadSession) {
    hadSession = !hadSession;
    fitPrompt();
  }
  if (selected) modelPicker.close();
  const running = liveTurn.running && !!selected;
  cancelBtn.style.display = running ? "" : "none";
  if (running) {
    setPlaceholder("Running… a message now steers this turn · Enter to send · Shift+Enter newline", "Steer the turn…");
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
    setPlaceholder("A terminal chi owns this session · run it with chi --shared to send from here", "A terminal chi owns this session");
    composeHintEl.textContent = "";
    actionBtn.textContent = "Send";
    actionBtn.disabled = true;
    emptyEl.classList.add("hidden");
  } else {
    setPlaceholder("Message chi… · Enter to send · Shift+Enter newline · ↑ history", "Message chi…");
    composeHintEl.textContent = SEND_HINT;
    actionBtn.textContent = "Send";
    actionBtn.disabled = false;
    emptyEl.classList.add("hidden");
  }
}

function setTurnRunning(running) {
  liveTurn.running = !!running;
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
  paintActive();
  resetSessionState();
  contextChips.clear();
  liveTurn.forget();
  setTurnRunning(false);
  closeStream();
  setMarkdownWarning(null);
  setCapabilities(null);
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
  paintActive();
  historyEl.innerHTML = `<div class="hint">Loading…</div>`;
  emptyEl.classList.add("hidden");
  closeStream();
  resetSessionState();
  resetTurnView();
  updateFirstPeek();
  updateInfoBar();
  contextChips.load(id);
  updateComposerMode();
  await resync();
  promptEl.focus();
}

// Clear everything that belongs to one turn's rendering.
function resetTurnView() {
  closeStream();
  // workerGone and a re-render come through here: the answer_display wait
  // goes too.
  liveTurn.forget();
  questionCards.removeQuestion();
  questionCards.forgetContinue();
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
      data = await getSession(id, { parts: true });
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
  setCapabilities(data.capabilities);
  current.status = s.status;
  current.model = s.model_name;
  current.served = s.served_model ? [s.served_model, s.served_model_for] : null;
  current.dir = s.working_directory;
  current.owner = s.owner || null;
  current.timing = normalizeTiming(data.timing);
  liveTurn.timing.ended = current.timing.turnRecords.length;
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
  current.promptNotes = Array.isArray(s.prompt_notes) ? s.prompt_notes : [];
  current.llmContext = s.llm_context || null;
  llmContextControl.refresh();
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
  const snapshotCards = splitSnapshotCards(data.cards, pageCapabilities);
  placeSnapshotCards(snapshotCards.placed);
  const replay = snapshotEvents({
    current_turn: data.current_turn,
    queued: data.queued,
    started_at: current.timing.activeTurn?.started_at,
  });
  // Marked replayed: a call's duration isn't timed from the replay's clock.
  replay.forEach((event) => streamHandlers[event.type]?.({ ...event, replayed: true }));
  if (!data.current_turn) {
    setTurnRunning(current.status === "running");
    if (liveTurn.running && current.timing.activeTurn?.started_at) liveTurn.timing.start(current.timing.activeTurn.started_at, activeTurnId);
  } else if (liveTurn.running) {
    // The replayed turn_started carries no id: the running turn's record's.
    liveTurn.timing.turnId = activeTurnId;
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

function setCapabilities(capabilities) {
  pageCapabilities = capabilities && typeof capabilities === "object" ? capabilities : {};
}

async function readTurnEnd() {
  if (!selected) return;
  const id = selected;
  // The line and the turn this read is for, before the await: a turn
  // queued behind this one may start (a new live line) before it lands.
  const line = liveTurn.timing.capture();
  try {
    const d = await getSession(id, { tail: true, recent: true, turnId: line.turnId });
    if (id !== selected) return;
    if (d.session) {
      if (Array.isArray(d.session.used_memory_names)) current.usedMemories = d.session.used_memory_names;
      // The notes chip: the first turn's build (or a /model) records them.
      if (Array.isArray(d.session.prompt_notes)) current.promptNotes = d.session.prompt_notes;
      if (d.session.status) current.status = d.session.status;
      if (!(await mergeTurnTiming(id, d.timing))) return;
      liveTurn.timing.finishLine(line);
      setMarkdownWarning(d.markdown_warning);
      setCapabilities(d.capabilities);
      if (Array.isArray(d.messages)) applyFinalMarkdown(d.messages);
      updateInfoBar();
      const sess = allSessions.find(s=>s.id===selected);
      if (sess) {
        sess.used_memory_names = current.usedMemories.slice();
        sess.status = current.status;
      }
      render();
      paintActive();
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
  shownTexts.seed(findInTurnRoots(".bubble").map((b) => normalize(b.textContent)));
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
  if (!k || shownTexts.shows(k)) return;
  const follow = isNearBottom();
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  const div = document.createElement("div");
  div.className = "bubble output";
  div.textContent = text;
  appendToHistory(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

// +stopped+: a stop someone chose (a cancel, the session's stop), drawn in
// the stopped style (timing.js STOPPED_LINE_CLASS); else a failure's line.
function addEndBubble(text, { stopped = false } = {}) {
  const div = document.createElement("div");
  div.className = stopped ? STOPPED_LINE_CLASS : "bubble cancel";
  div.textContent = text;
  appendToHistory(div);
  if (!turnDom.holds?.()) historyEl.scrollTop = historyEl.scrollHeight;
}

// Everything a turn's end (completed, canceled, failed) closes: then its
// end line (+endText+, the cancel or failed line), then the step cards that
// left the collapsed block (card.js leavesBlock), where a reload puts them.
function endTurnView(kind, endText = null, { emptyAnswer = null, stopped = false } = {}) {
  setTurnRunning(false);
  // Every ended turn has a record (completed, canceled, failed); a worker
  // gone mid-turn is re-rendered (resync), which counts again.
  if (kind !== "gone") liveTurn.timing.ended += 1;
  // A completed turn with no answer: its notice where the answer goes
  // (the turn view places it), else after the turn; before the timing.
  const endNote = emptyAnswer ? htmlElement(emptyAnswerHtml(emptyAnswer)) : null;
  const kept = turnDom.turnEnded({ kind, endNote, emptyAnswer: !!emptyAnswer }) || [];
  if (endNote && !endNote.isConnected) appendToHistory(endNote);
  liveTurn.timing.finish({ canceled: kind === "canceled" });
  if (endText) addEndBubble(endText, { stopped });
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

// The bubble a reload draws (turn_html.js), with this page's own fields.
function makeUserBubble(prompt, { state = null, label = null, enqueuedId = null, own = false, images = null } = {}) {
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  const div = htmlElement(userBubbleHtml({ content: prompt }, {
    label, state, own, enqueuedId, key: normalize(prompt), thumbs: thumbsHtml(selected, images),
  }));
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
  bubble.insertAdjacentHTML("beforeend", stateBadgeHtml(state));
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
  if (event.type === "turn_started") liveTurn.wakeStart = !!event.continue && isReportClient(event.origin?.client_id);
  const ops = promptOps(event, { myId: clientId, known: (id) => !!bubbleById(id), unmatchedMerge: liveTurn.unmatchedMerge, wakeStart: liveTurn.wakeStart });
  if (event.type === "input_merged") liveTurn.unmatchedMerge = false;
  if (event.type === "pending_input_merged") liveTurn.unmatchedMerge = false;
  let started = null;
  for (const op of ops) {
    if (op.op === "report") {
      liveTurn.unmatchedMerge = "report";
    } else if (op.op === "add") {
      const bubble = makeUserBubble(op.prompt, { state: op.state, label: op.label, enqueuedId: op.enqueuedId, images: op.images });
      if (op.state === "started") started = bubble;
      if (event.type === "pending_input_merged") liveTurn.wakeStart = false;
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
      else liveTurn.unmatchedMerge = true;
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
  keepFollowing(historyEl, () => (before ? historyEl.insertBefore(details, before) : appendAboveLiveTiming(historyEl, details, liveTurn.timing.el)));
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
      followWokenWorker();
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
  // Pushed as openAllView does, so the view's back returns here.
  if (e.target.closest(".children-chip")) {
    e.preventDefault();
    openAllView();
  }
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
    archiveBtn.classList.toggle("archived", archived);
    archiveBtn.title = archived ? "Unarchive: back to the lists" : "Archive: hide from the lists, keep for good";
  }
  if (!selected) {
    // The start page hides the info bar (the storage path is on #/sessions).
    renderStable(infoTextEl, "");
    infoTextEl.title = "";
    if (stopBtn) stopBtn.style.display = "none";
    return;
  }
  if (stopBtn) stopBtn.style.display = canStopSession({ owner: current.owner, streaming: !!streamControl }) ? "" : "none";
  const idShort = selected.slice(0,8);
  const memText = current.usedMemories.length ? current.usedMemories.join(", ") : "—";
  const ctxText = current.ctxPct !== null ? `ctx ${Math.round(current.ctxPct)}%` : "";
  const tokens = current.timing.tokens;
  const ctxTip = tokensTipText(tokens, undefined, current.timing.memoryIndex);
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
  // A parent names its delegates; the link opens all sessions.
  const kids = childrenSummary({ id: selected }, allSessions);
  // The model notes the session's prompt carried.
  const notes = promptNotesChip(current.promptNotes);
  const notesHtml = notes ? `<span class="model notes-chip" title="${escapeHtml(notes.title)}">${escapeHtml(notes.text)}</span>` : "";
  const kidsHtml = kids ? `<a class="model children-chip${kids.waitingText ? " waiting" : ""}" href="${escapeHtml(ALL_SESSIONS_HASH)}" title="${escapeHtml(`${kids.title} (all sessions)`)}">${escapeHtml(kids.text)}${kids.waitingText ? ` · <span class="kids-waiting">${escapeHtml(kids.waitingText)}</span>` : ""}</a>` : "";
  const attachCmd = `chi --attach ${selected}`;
  const copied = Date.now() - attachCopiedAt < 2000;
  const copyHtml = `<button type="button" class="copy-attach" title="Copy &quot;${escapeHtml(attachCmd)}&quot; to attach a terminal">${copied ? "copied ✓" : "copy chi --attach"}</button>`;
  const metaHtml = `<div class="meta"><span class="id" title="${escapeHtml(selected)}">${escapeHtml(idShort)}</span>${copyHtml}<span class="${statusClass}">${escapeHtml(current.status||"")}</span><span class="model${label.mismatch ? " served-mismatch" : ""}" title="${escapeHtml(label.title)}">${escapeHtml(label.text)}</span>${parentHtml}${kidsHtml}${llmContextChipHtml(current.llmContext, escapeHtml)}${notesHtml}${current.usedMemories.length ? `<span class="model mem-chip" title="${escapeHtml(memChipTitle(current.usedMemories))}">${escapeHtml(memChipText(current.usedMemories))}</span>` : ""}<span class="dir" title="${escapeHtml(current.dir||"")}"><bdi>${escapeHtml(current.dir||"")}</bdi></span>${ctxText ? `<span class="model ctx" title="${escapeHtml(ctxTip)}">${escapeHtml(ctxText)}</span>` : ""}${speedTextNow ? `<span class="model speed" title="${escapeHtml(speedTip)}">${escapeHtml(speedTextNow)}</span>` : ""}${timingText ? `<span class="model session-time"></span>` : ""}${workerBadgeHtml()}</div>`;
  const previewHtml = `<div class="preview-line"><span class="preview">${escapeHtml(current.firstPreview || "—")}</span> · <span class="mem" title="${escapeHtml(current.usedMemories.join(", "))}">mem: ${escapeHtml(memText)}</span></div>`;
  // The session clock ticks every second while a turn runs: only its text
  // changes, the bar's other nodes (a tooltip, a button mid-press) stay.
  renderStable(infoTextEl, metaHtml + previewHtml, { ".session-time": timingText });
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
  if (liveTurn.running && current.timing.startedAt) {
    return elapsedSince(current.timing.startedAt);
  }
  return current.timing.sessionDurationMs;
}

// The stage takes a running turn's rows (its extras); else the history.
function appendToHistory(el) {
  if (turnDom.place?.(el)) return;
  appendAboveLiveTiming(historyEl, el, liveTurn.timing.el);
}

// A turn-end re-read's timing (?tail=1&recent=1: the newest turn's records
// and turn_count) merged into the page's (mergeTiming); when the merge comes
// up short, the whole timing (?timing=1). Never (re)starts live timing: a
// turn that started meanwhile keeps its line and its own active turn.
// @return false when the session changed meanwhile
async function mergeTurnTiming(id, data) {
  const keepActive = () => (liveTurn.running ? current.timing.activeTurn : null);
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
  liveTurn.timing.ended = Math.max(liveTurn.timing.ended, current.timing.turnRecords.length);
  return true;
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
    paintActive();
  }
}

// A turn or command just woke the session's worker: follow its stream if
// none is open, from the render's cursor. A render with none (no worker
// then) streams from 0, the start of a new worker's events; should that
// worker have been up already, turn_started says so (replaysDrawnTurn).
function followWokenWorker() {
  if (streamControl?.live) return;
  startStream(selected, selectSeq ?? 0);
  streamFromGuess = selectSeq === null;
}

function startStream(id, fromSeq) {
  streamFromGuess = false;
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
  const endText = workerGoneText({ turnRunning: liveTurn.running, stopped });
  if (endText) {
    endTurnView("gone", endText, { stopped });
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
    liveTurn.timing.setNote("");
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
    liveTurn.timing.setNote("");
    turnDom.generationStarted(data || {});
  },
  generation_completed: (data) => {
    liveTurn.timing.setNote("");
    if (data?.served_model) current.served = [data.served_model, data.requested_model];
    // The generation's speed and the session's token totals, from the server.
    current.timing.tokens = generationTokens(current.timing.tokens, data);
    if (data?.served_model || data?.tokens) updateInfoBar();
    turnDom.generationCompleted();
  },
  // Prompts sent while a turn ran merge into it at an iteration boundary:
  // input_merged names them (their bubbles turn "steered"), then
  // pending_input_merged carries the merged text, shown only for prompts
  // this tab has no bubble for. Its `answer` (the answer the merge
  // superseded) is the TUI's line: here it streamed as that step's text.
  input_merged: (data) => applyPromptOps(data),
  pending_input_merged: (data) => {
    applyPromptOps(data);
    showSteers(data.steers);
  },
  turn_enqueued: (data) => applyPromptOps(data),
  turn_started: (data) => keepFollowing(historyEl, () => {
    if (streamFromGuess) {
      streamFromGuess = false;
      // A replay of a turn the render drew: re-read and stream from there.
      if (replaysDrawnTurn(data, current.timing.turnRecords)) {
        streamControl?.close();
        streamControl = null;
        resync();
        return;
      }
    }
    // A finished turn still in the stage goes first: the start op looks
    // for a queued prompt among its rows.
    turnDom.handOff?.({ immediate: true });
    markRecapStale();
    shownTexts.turnStarted();
    const promptBubble = applyPromptOps(data);
    setTurnRunning(true);
    setLiveStatus("running");
    liveTurn.timing.detach();
    turnDom.turnStarted({ ...data, promptBubble });
    liveTurn.timing.start(data.started_at, data.turn_id || null);
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
    if (display) liveTurn.displayPending = display;
    liveTurn.endRead = readTurnEnd();
    await liveTurn.endRead;
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
      await liveTurn.endRead;
      if (!selected || !data.display) return;
      const d = await getSession(selected, { tail: true, recent: true });
      if (Array.isArray(d.messages)) applyFinalMarkdown(d.messages);
    } catch (_) {
    } finally {
      liveTurn.releaseDisplay();
    }
  },
  turn_canceled: (data) => {
    endTurnView("canceled", cancelLineText(data.cancellation_reason || "", data.cancelled_by), { stopped: true });
    setLiveStatus("idle");
    refreshTimingFromSession();
  },
  // The turn raised (e.g. the model server stayed unreachable). The worker
  // stays up: it rolls the turn back and hands the prompt back
  // (prompt_restored), and the prompts queued behind it run as usual. A turn
  // that got to tool steps stays as it is (kept_steps; no prompt_restored).
  turn_failed: (data) => {
    const text = failedTurnText(data);
    // Only a rolled-back turn's line waits for its prompt_restored.
    liveTurn.failedText = Number.isInteger(data.kept_steps) ? null : text;
    endTurnView("failed", text);
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
    const failedText = liveTurn.failedText;
    liveTurn.failedText = null;
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
    // /llm-context changed what the next turn runs under.
    if (data.llm_context) {
      current.llmContext = data.llm_context;
      updateInfoBar();
      llmContextControl.refresh();
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
  context_added: (data) => {
    addNoteBubble({ label: data.label, content: data.text || "" });
    // An attached context source's note: its chip changed.
    if (data.context_source) contextChips.refresh();
  },
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
    if (!liveTurn.running) showRecap(data.recap);
  },
  guardrail_warning: (data) => showGuardrailWarning(data.message, data.label || "guardrails"),
  // A notice during a turn is a row of its current step. One the page
  // shows elsewhere (a hook's links in the rendered answer) isn't drawn,
  // not even in the stage trail; a joined turn's notices come here too.
  hook_notice: (data) => {
    if (shownElsewhere(data, pageCapabilities)) return;
    if (!turnDom.notice(data)) showHookNotice(data);
  },
  // The loop asks again after an empty answer: a row of the empty step
  // (a reload puts it back from the snapshot's cards).
  empty_answer_retry: (data) => { turnDom.notice({ line: emptyRetryLine(data) }); },
  steer_cut: (data) => { turnDom.notice({ line: steerCutLine(data) }); },
  // The provider is asked again after an error, or the turn waits for
  // plugins' setup: a note on the live timing line until it streams.
  generation_retrying: (data) => liveTurn.timing.setNote(retryStatusLine(data)),
  plugin_init_wait: (data) => liveTurn.timing.setNote(initWaitLine(data)),
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
  const line = liveTurn.timing.capture();
  try {
    const data = await getSession(id, { tail: true, recent: true, turnId: line.turnId });
    if (id !== selected) return;
    if (data.session?.status) current.status = data.session.status;
    if (await mergeTurnTiming(id, data.timing)) liveTurn.timing.finishLine(line);
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
      followWokenWorker();
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
    followWokenWorker();
  } catch (e) {
    echo.remove();
    // The turn never reached the worker's queue: an early restore waiting
    // for its ack is never taken back (4.13), so drop it here. The prompt
    // is still in the composer, as the echo was removed.
    dropEarlyRestores(earlyRestores);
    // The chips stay (uploaded ones keep their ref) for another try: an
    // image refused (bad_image, too_large, bad_images) says why below.
    if (e.code === "owned_by_tui") {
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
    followWokenWorker();
  } catch (e) {
    if (e.code === "owned_by_tui") {
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

// A session command from a control (the llm ctx chip), not the composer:
// its command_ran shows its line and reply, as a typed one's would.
async function runSessionCommand(line) {
  if (!selected) return;
  try {
    await sendCommand(selected, line, { clientId });
    followWokenWorker();
  } catch (e) {
    addCommandBubble({ label: null, line, text: e.message, failed: true });
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
    if (e.code !== "not_running") alert(e.message);
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

// The empty box: one line in a session, three on the start page.
function promptMinPx() {
  return document.body.classList.contains("has-session") ? PROMPT_LINE_PX : PROMPT_MIN_PX;
}

function fitPrompt() {
  const borders = promptEl.offsetHeight - promptEl.clientHeight;
  promptEl.style.height = "0px";
  const { height, scrolls } = promptHeight({ contentPx: promptEl.scrollHeight + borders, floorPx: promptFloor, viewportPx: window.innerHeight, minPx: promptMinPx() });
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
    promptFloor = gripFloor(startH + (startY - ev.clientY), window.innerHeight, promptMinPx());
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

// One archive / unarchive request, the core the info bar, a card's button
// and a batch share. The ids in the answer flip in the list at once. When
// the open session's worker was stopped (it, or a delegate of the archived
// one), its stream ending is a stop, not a lost worker.
// @return {ok: true, result} | {ok: false, error}
async function archiveOne(id, archive) {
  // A live worker in the tree is stopped by the archive: the open
  // session's stream ending then is a stop.
  const mine = archive && selected && inTree(allSessions, id, selected) ? selected : null;
  if (mine) stoppingId = mine;
  try {
    const result = archive ? await archiveSession(id) : await unarchiveSession(id);
    markArchived(archive ? result.archived : result.unarchived, archive);
    if (mine && mine === selected && (result.stopped || []).includes(mine)) {
      // Its worker is gone: don't wait for its stream to notice.
      streamControl?.close();
      current.status = "stopped";
      workerGone(mine);
    }
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
  isLive: (root) => liveTurn.running && turnDom.containsLive(root),
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
  if (hidden) familyPop.close();
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

$("#filter").addEventListener("input", () => {
  searchToggles.clear();
  renderAll();
});
// A list whose order was held under the pointer (listOrder) catches up.
topStripEl.addEventListener("pointerleave", () => {
  // Not while its family popover is open: the pointer went there (close() catches up).
  if (heldLists.has(topStripEl) && !familyPop.isOpen()) renderTop(stripCards());
});
allListEl.addEventListener("pointerleave", () => {
  if (heldLists.has(allListEl) && allViewOpen()) renderAll();
});
// Esc leaves select mode first, then the all-sessions view.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || !allViewOpen()) return;
  if (selecting.on) {
    if (!selecting.running) leaveSelect();
    return;
  }
  closeAllView();
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
