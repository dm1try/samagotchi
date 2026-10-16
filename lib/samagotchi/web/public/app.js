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
  continueSession,
  uploadImage,
  listModels,
  fetchHistory,
  listContext,
  getContext,
  detachContext,
  addContext,
} from "./data.js";
import { createContextChips } from "./context_chips.js";
import {
  chipModel as llmContextChipModel, choiceWords, createLlmContextControl, NEW_CHAT,
  withChoice,
} from "./llm_context_chip.js";
import {
  chipModel as thinkingChipModel, createThinkingControl,
  withChoice as withThinkingChoice,
} from "./thinking_chip.js";
import { createReasoningHistoryControl } from "./reasoning_history_chip.js";
import { renderInfoBar } from "./info_bar.js";
import { sessionBar, workerBadgeFor } from "./info_bar_model.js";
import { createShownTexts } from "./shown_texts.js";
import { MODEL_KEY } from "./model_pick.js";
import { emptySessionState, sessionStateFrom } from "./session_state.js";
import { createModelPicker } from "./model_picker.js";
import { chipName, chipsTemplate, imageFiles, restoredChips, thumbsTemplate, turnRefs, turnText, uploadChips } from "./images.js";
import { normalize, firstPreview, failedTurnText, deleteConfirmText, goneSessionNotice, cantText, withLiveStatus, withoutWorker } from "./format.js";
import { createTurnView, turnHistoryNodes } from "./turn_view.js";
import { elementOf, emptyAnswerTemplate } from "./turn_html.js";
import { createBubbles, hintEl, outputBubbleTemplate, setBubbleDelivery } from "./bubbles.js";
import { createCardsPlace } from "./cards_place.js";
import { createStageView, FOLD_MS } from "./stage_view.js";
import { reducedMotion, STAGE_GAP } from "./stage_frame.js";
import { chainNeighbours, continueRefusal, continuedText, freshLink, openChildrenTemplate, openerText, openTitle } from "./chains.js";
import { createTaskStopper } from "./task_stop.js";
import { appendQuote } from "./annotations.js";
import { parsePresets } from "./annotate_presets.js";
import { createAnnotateBar } from "./annotate_bar.js";
import { actionLine, annotationActions, composerWithAction } from "./annotate_actions.js";
import { copyText, installCopy } from "./copy.js";
import { createQuestionCards } from "./question_cards.js";
import { splitSnapshotCards } from "./card.js";
import { PROMPT_LINE_PX, PROMPT_MIN_PX, gripFloor, promptHeight } from "./composer_size.js";
import { createCommandList } from "./command_list.js";
import { createPromptHistory } from "./prompt_history.js";
import { ALL_SESSIONS_HASH, sessionHash, sessionIdFromHash } from "./route.js";
import { scopeDir, scopeTemplate } from "./scope.js";
import { html, nothing, render } from "./vendor/lit-html.js";
import { easeScrollTo, FOLLOW_MS, shouldFollowScroll } from "./scroll.js";
import { SHORT_WINDOW_QUERY, stripAutoHidden } from "./strip.js";
import { applySessionEvent, inTree, sortedByUpdated } from "./sessions_list.js";
import { createNotifications } from "./notifications.js";
import { tabTitle, topBarTitle } from "./session_title.js";
import { restartConfirmText, versionNotice } from "./update_notice.js";
import {
  appendAboveLiveTiming, mergeTiming, normalizeTiming,
} from "./timing.js";
import { createLiveTurn } from "./live_turn.js";
import { applyFinalAnswer, pairAnswerRefs } from "./answer_refs.js";
import { installRefClicks } from "./refs.js";
import { linkRefs, touchedFiles } from "./ref_scan.js";
import { DONE_MS, applyInitEvent, dropDone, fadeDone, initRowTemplate, newInitTasks, seedInitTasks } from "./init_row.js";
import { newClientId, snapshotEvents, workerGoneText } from "./turn_events.js";
import { applyConfirm, keptCommandBubbles, restoreCommandBubbles } from "./commands.js";
import { createComposerCommands, routeComposerLine, routeSessionLine } from "./composer.js";
import { composerAfterAck, dropEarlyRestores, restoreOnAck } from "./restore.js";
import { createStreamHandlers } from "./stream_handlers.js";
import { createListsView } from "./lists_view.js";
import { createDeliveryControl, QUEUE_NEEDS_WORKER } from "./delivery_line.js";
import { liveSlots } from "./stage_model.js";
import { currentGen } from "./turn_model.js";
import { toolName } from "./activity.js";
import { toastBottom } from "./toast_place.js";

const $ = (s) => document.querySelector(s);
const topStripEl = $("#topStrip");
const allListEl = $("#allList");
const historyEl = $("#history");
const emptyEl = $("#empty");
const composerEl = $("#composer");
// The open session's title in the top bar, when no strip card in sight
// shows it; the tab's base ("Chi · <project>"), set by renderScope.
const sessionTitleEl = $("#sessionTitle");
let tabBase = null;
let tabShown = null;
const infoTextEl = $("#infoText");
// The open session's attached context, in its own row of the session bar
// (updateInfoBar redraws #infoText every tick; the chips keep their popover).
const contextChips = createContextChips({
  el: $("#contextChips"),
  api: { list: listContext, show: getContext, detach: detachContext, add: addContext },
  toast: (text) => showToast(text),
});
// The open session's LLM context chip in the info bar, and its popover:
// /llm-context runs in the session's worker.
const llmContextControl = createLlmContextControl({
  el: infoTextEl,
  summary: () => (selected ? current.llmContext : null),
  session: () => selected,
  running: () => liveTurn.running,
  run: (line) => runSessionCommand(line),
});
// The start page's LLM context chip, beside the model picker: the picked
// model's values, and a choice for the next new chat only (sent with its
// create, then dropped; never remembered: a reload or opening a session
// drops it too, a failed create keeps it).
const llmContextNewEl = $("#llmContextNew");
let newChatLlmContext = null;
const newChatLlmSummary = () => (selected || modelPickEl.hidden ? null : modelPicker.chosenRow()?.llm_context || null);
const llmContextNewControl = createLlmContextControl({
  el: llmContextNewEl,
  summary: newChatLlmSummary,
  kind: NEW_CHAT,
  choice: () => newChatLlmContext,
  choose: (next) => {
    newChatLlmContext = next;
    renderNewChatLlmContext();
    promptEl.focus();
  },
  id: "llmContextNewPopover",
  anchor: "#llmContextNew",
});
// The open session's thinking chip, beside the llm ctx one: /thinking runs
// in the session's worker.
const thinkingControl = createThinkingControl({
  el: infoTextEl,
  summary: () => (selected ? current.thinking : null),
  session: () => selected,
  running: () => liveTurn.running,
  run: (line) => runSessionCommand(line),
});
// The open session's reasoning history chip, after the thinking one (a
// chat host's only): /reasoning-history runs in the session's worker.
const reasoningHistoryControl = createReasoningHistoryControl({
  el: infoTextEl,
  summary: () => (selected ? current.reasoningHistory : null),
  session: () => selected,
  running: () => liveTurn.running,
  run: (line) => runSessionCommand(line),
});
// The start page's thinking chip: the picked model's level, and a level
// for the next new chat only (sent with its create, then dropped).
const thinkingNewEl = $("#thinkingNew");
let newChatThinking = null;
const newChatThinkingSummary = () => (selected || modelPickEl.hidden ? null : modelPicker.chosenRow()?.thinking || null);
const thinkingNewControl = createThinkingControl({
  el: thinkingNewEl,
  summary: newChatThinkingSummary,
  kind: NEW_CHAT,
  choice: () => newChatThinking,
  choose: (next) => {
    newChatThinking = next;
    renderNewChatThinking();
    promptEl.focus();
  },
  id: "thinkingNewPopover",
  anchor: "#thinkingNew",
});
function renderNewChatThinking() {
  const chip = thinkingChipModel(withThinkingChoice(newChatThinkingSummary(), newChatThinking), { kind: NEW_CHAT });
  thinkingNewEl.hidden = !chip;
  if (!chip) return thinkingNewControl.close();
  thinkingNewEl.textContent = chip.text;
  thinkingNewEl.title = chip.title;
  thinkingNewEl.classList.toggle("own", chip.own);
}
// Hidden without the model's values (the list not in, an older server).
function renderNewChatLlmContext() {
  const chip = llmContextChipModel(withChoice(newChatLlmSummary(), newChatLlmContext), { kind: NEW_CHAT });
  llmContextNewEl.hidden = !chip;
  if (!chip) return llmContextNewControl.close();
  llmContextNewEl.textContent = chip.text;
  llmContextNewEl.title = chip.title;
  llmContextNewEl.classList.toggle("own", chip.own);
}
const markdownWarningEl = $("#markdownWarning");
// What the page renders that a notice may stand in for (the server's
// Web::Capabilities, next to markdown_warning); a notice it names isn't
// drawn (shownElsewhere). An older server sends none: every notice shows.
// And what this viewer can do (editor: open a path in this machine's
// editor; per request), with the editor's URL template (editor_url) next
// to it: refs.js's actions read both (pageViewer).
let pageCapabilities = {};
let pageEditorUrl = null;
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

// The composer's delivery line while the open session's turn runs
// (delivery_line.js): where a message typed now goes in, and the cut and
// queue links.
const deliveryControl = createDeliveryControl({
  el: $("#deliveryLine"),
  read: () => {
    const turn = turnDom.current?.().turn || null;
    const running = turn ? turn.gens.flatMap((g) => g.tools).reverse().find((r) => r.status === "running") : null;
    return {
      phase: turnDom.phase?.() || liveSlots(turn).phase,
      gen: turn ? currentGen(turn) : null,
      tool: running ? { name: toolName(running), startedAt: running.startedAt ?? null } : null,
      cutAfter: liveTurn.cutAfter,
      serverGen: liveTurn.serverGen,
      canQueue: current.workerFeatures.includes("delivery"),
      model: current.model,
    };
  },
  composerEmpty: () => !promptEl.value.trim() && !chips.length,
  send: (delivery) => handleSendTurn({ delivery }),
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
  askingText: () => turnDom.askingText(),
});
// The history's bubbles (bubbles.js): output, end lines, every client's
// prompts, the recap, warnings and notices, command and note bubbles.
const bubbles = createBubbles({
  historyEl,
  appendToHistory: (el) => appendToHistory(el),
  isNearBottom: () => isNearBottom(),
  turnDom,
  findInTurnRoots: (selector) => findInTurnRoots(selector),
  shownTexts,
  liveTurn,
  selected: () => selected,
  clientId,
});
const {
  removeHintIfEmpty, appendChunk, addEndBubble, makeUserBubble, bubbleById, applyPromptOps, showRecap, markRecapStale,
  showGuardrailWarning, showSteers, showHookNotice, addCommandBubble, commandBubble, addNoteBubble,
} = bubbles;
// The plugin cards and a snapshot's notices in the history (cards_place.js).
const cards = createCardsPlace({
  historyEl,
  turnDom,
  findInTurnRoots: (selector) => findInTurnRoots(selector),
  selected: () => selected,
  clientId,
  questionCards,
  bubbles,
  followWokenWorker: () => followWokenWorker(),
});
const { upsertCard, placeSnapshotCards, refreshCardBodies } = cards;
turnRoots().forEach((root) => root.addEventListener("click", cards.onCardAction));
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
  lists.render();
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
      lists.render();
      const sess = allSessions.find((s) => s.id === selected);
      if (sess) followSelectedSession(sess);
    },
    session: (data) => {
      notifications.noticeSessions("session", data);
      allSessions = applySessionEvent(allSessions, "session", data);
      lists.render();
      if (data.session && data.session.id === selected) followSelectedSession(data.session);
      // Its children chip; its chain's ← → links (a link that continues it, its previous one).
      else if (selected && (data.session?.parent_id === selected || data.session?.continues === selected
                            || (data.session?.id && data.session.id === current.continues))) updateInfoBar();
    },
    session_gone: (data) => {
      notifications.noticeSessions("session_gone", data);
      lists.forget(data.id);
      const next = applySessionEvent(allSessions, "session_gone", data);
      if (next !== allSessions) {
        allSessions = next;
        lists.render();
        if (selected) updateInfoBar(); // a deleted child leaves the children chip, a deleted chain link its ← → link
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
// The sessions whose Restart is under way (their button says so): one
// session's restart never blocks another's.
const restartingIds = new Set();
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
  render(scopeTemplate(scope, { error: scopeError, where: () => ({ hash: location.hash, search: location.search }) }), el);
  el.hidden = false;
  // The tab: "<session title> · Chi · <project>" (updateSessionTitle).
  tabBase = scope.projectName ? `Chi · ${scope.projectName}` : "Chi";
  updateSessionTitle();
}

// The session lists (lists_view.js): the strip, all sessions, their cards,
// select mode, the family and chain popovers.
const lists = createListsView({
  doc: document,
  win: window,
  topStripEl,
  allListEl,
  sessions: () => allSessions,
  selected: () => selected,
  scope,
  scopeError: () => scopeError,
  eventsLive: () => !!eventsControl,
  refresh: () => refresh(),
  select: (id) => select(id),
  confirmDelete: (id) => confirmDelete(id),
  setArchived: (id, archive) => setArchived(id, archive),
  archiveOne: (id, archive) => archiveOne(id, archive),
  updateInfoBar: () => updateInfoBar(),
  updateSessionTitle: () => updateSessionTitle(),
  showToast: (text, action) => showToast(text, action),
  allViewOpen: () => allViewOpen(),
  openAllView: () => openAllView(),
  leaveAllView: (hash) => leaveAllView(hash),
  setStripHidden: (hidden) => setStripHidden(hidden),
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
  lists.render();
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
    if (lists.selecting.on && !lists.selecting.running) lists.leaveSelect();
    topStripEl.scrollLeft = 0; // a phone's strip scrolls sideways to the tile
  }
  document.body.classList.toggle("all-view", open);
  updateSessionTitle();
  // Its chip was in the list just hidden (the strip, or all sessions).
  lists.chainPop.close();
  if (open) {
    lists.familyPop.close(); // the strip is hidden in the all view
    // The list is live; only its order can lag (upserts keep cards in
    // place), so the all view opens in the server's order.
    allSessions = sortedByUpdated(allSessions);
    lists.renderAll();
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
    // Back on the start page: its remembered model, not the last link's.
    if (!hadSession) restoreStartPick();
    fitPrompt();
    placeToast();
  }
  syncModelPick();
  if (selected) {
    llmContextNewControl.close();
    // The start page's choice was for a new chat: opening a session drops it.
    if (newChatLlmContext) {
      newChatLlmContext = null;
      renderNewChatLlmContext();
    }
    thinkingNewControl.close();
    if (newChatThinking) {
      newChatThinking = null;
      renderNewChatThinking();
    }
  }
  const running = liveTurn.running && !!selected;
  cancelBtn.style.display = running ? "" : "none";
  syncDeliveryLine();
  if (running) {
    setPlaceholder("Running… a message goes in at the next step · Enter to send · Alt+Enter queues", "Steer the turn…");
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
    historyEl.replaceChildren();
    updateInfoBar();
  } else if (current.owner === "tui") {
    setPlaceholder("A terminal chi owns this session · run it with chi --shared to send from here", "A terminal chi owns this session");
    composeHintEl.textContent = "";
    actionBtn.textContent = "Send";
    actionBtn.disabled = true;
    emptyEl.classList.add("hidden");
  } else {
    // The keys are in the delivery line's row above.
    setPlaceholder("Message chi…", "Message chi…");
    composeHintEl.textContent = SEND_HINT;
    actionBtn.textContent = "Send";
    actionBtn.disabled = false;
    emptyEl.classList.add("hidden");
  }
}

// The delivery line's row in a session (delivery_line.js): the key hint
// while idle, where a message goes in while the turn runs.
function syncDeliveryLine() {
  // A terminal owns the session: the composer is off, so is its row.
  if (!selected || current.owner === "tui") deliveryControl.show("off");
  else deliveryControl.show(liveTurn.running && current.owner !== "tui" ? "running" : "idle");
}

function setTurnRunning(running) {
  liveTurn.running = !!running;
  // A fresh link's picker goes now, not at the timing re-read after the turn.
  if (running && selected) current.turnStarted = true;
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
    lists.render();
  }
  updateInfoBar();
}

// Plugins' slow setup still running in the open session's worker (chi.init),
// over the composer; a done line fades (init_row.js).
const initRowEl = $("#initRow");
const initTasks = newInitTasks();
function renderInitRow() {
  render(initRowTemplate(initTasks), initRowEl);
  initRowEl.hidden = initTasks.size === 0;
}
function onInitEvent(type, data) {
  const done = applyInitEvent(initTasks, type, data);
  renderInitRow();
  if (!done) return;
  const session = selected;
  setTimeout(() => {
    if (session !== selected) return;
    fadeDone(initTasks, done);
    renderInitRow();
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
  lists.paintActive();
  resetSessionState();
  contextChips.clear();
  liveTurn.forget();
  setTurnRunning(false);
  closeStream();
  setMarkdownWarning(null);
  setCapabilities(null, null);
  updateComposerMode();
  updateInfoBar();
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
  lists.paintActive();
  historyEl.replaceChildren(hintEl("Loading…"));
  emptyEl.classList.add("hidden");
  closeStream();
  resetSessionState();
  resetTurnView();
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
      if (id === selected) historyEl.replaceChildren(hintEl(`Error: ${e.message}`));
      return;
    }
    if (id !== selected) return;
    const kept = keptCommandBubbles(historyEl, id);
    resetTurnView();
    renderSessionView(data, { kept });
    // Preview is read-only: a worker is woken only by POST /turn, so attach
    // only when a live bridge exists.
    current.streamSeq = typeof data.last_event_seq === "number" ? (data.last_event_id || data.last_event_seq) : null;
    if (current.streamSeq !== null) startStream(id, current.streamSeq);
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
function renderSessionView(data, { kept = [] } = {}) {
  setMarkdownWarning(data.markdown_warning);
  setCapabilities(data.capabilities, data.editor_url);
  // The saved fill (when there is one) goes in here too, so a reloaded or
  // stopped session shows it before its next turn (a running turn's replay
  // below streams over it).
  Object.assign(current, sessionStateFrom(data));
  liveTurn.timing.ended = current.timing.turnRecords.length;
  const activeTurnId = current.timing.activeTurn?.id || null;
  llmContextControl.refresh();
  thinkingControl.refresh();
  reasoningHistoryControl.refresh();
  if (data.messages && data.messages.length) renderHistory(data.messages);
  else renderHistory(data.history || []);
  restoreCommandBubbles(historyEl, kept);
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
    queued_commands: data.queued_commands,
    started_at: current.timing.activeTurn?.started_at,
  });
  // Marked replayed: a call's duration isn't timed from the replay's clock.
  replay.forEach((event) => streamHandlers[event.type]?.({ ...event, replayed: true }));
  // A join mid-generation: the worker's word on it clocks the delivery line.
  const gen = data.current_turn?.generation;
  liveTurn.serverGen = gen ? { ...gen, at: Date.now() } : null;
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
  updateComposerMode();
}

function renderHistory(items) {
  if (!items.length) {
    historyEl.replaceChildren(hintEl("No output yet. Send a message."));
    return;
  }
  if (typeof items[0] === "object" && items[0].role) {
    historyEl.replaceChildren(turnHistoryNodes(items, current.timing, { thumbs: (images) => thumbsTemplate(selected, images) }));
    linkTextRefs();
  } else {
    historyEl.replaceChildren(...items.map((c) => elementOf(outputBubbleTemplate(c))));
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

// Both from one payload, together; the body's has-editor class follows.
function setCapabilities(capabilities, editorUrl) {
  pageCapabilities = capabilities && typeof capabilities === "object" ? capabilities : {};
  pageEditorUrl = pageCapabilities.editor === true && typeof editorUrl === "string" && editorUrl ? editorUrl : null;
  document.body.classList.toggle("has-editor", pageEditorUrl !== null);
}

// What this viewer can do with a ref (refs.js REF_ACTIONS).
function pageViewer() {
  return { editor: pageCapabilities.editor === true, editorUrl: pageEditorUrl };
}

// Refs anywhere on the page (a tool row's file, its diff lines, an
// answer's path:line): one listener set; "Copy path" says so in a toast.
installRefClicks(document.body, pageViewer, {
  copy: async (text) => showToast((await copyText(text)) ? "Path copied" : "Couldn't copy the path"),
});

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
      setCapabilities(d.capabilities, d.editor_url);
      if (Array.isArray(d.messages)) applyFinalMarkdown(d.messages);
      updateInfoBar();
      const sess = allSessions.find(s=>s.id===selected);
      if (sess) {
        sess.used_memory_names = current.usedMemories.slice();
        sess.status = current.status;
      }
      lists.render();
      lists.paintActive();
    }
  } catch(_){}
}

// The turn's answer as its rendered markdown and with its plugin refs,
// once it is final (the turn-end read, an answer_display re-read:
// answer_refs.js applyFinalAnswer); then the refs.
function applyFinalMarkdown(messages) {
  applyFinalAnswer(messages, findInTurnRoots(".bubble.output"), normalize);
  linkTextRefs();
}

// The refs on the answers' and closed steps' texts, on this page: first
// each answer's own (a plugin's, answer_refs.js), then the `path:line`
// refs that name a file the session's rows (and cards) touched
// (ref_scan.js), which leave a plugin's alone. Not mid-stream: at a
// turn's end and after a reload's render. A ref already made stays as it
// is.
function linkTextRefs() {
  const roots = turnRoots();
  const touched = touchedFiles(roots);
  for (const root of roots) {
    for (const el of root.querySelectorAll(".bubble.output")) pairAnswerRefs(el);
  }
  if (!touched.size) return;
  for (const root of roots) {
    for (const el of root.querySelectorAll(".bubble.output, .gen:not(.live) > .gen-text")) linkRefs(el, touched, current.dir);
  }
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
  const endNote = emptyAnswer ? elementOf(emptyAnswerTemplate(emptyAnswer)) : null;
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

// The info bar's "copy chi --attach": the full id, which the page shows
// only short; "copied ✓" for 2 s (current.attachCopiedAt: that session's).
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
  const id = selected;
  if (!(await copyText(`chi --attach ${id}`)) || id !== selected) return;
  current.attachCopiedAt = Date.now();
  updateInfoBar();
  setTimeout(updateInfoBar, 2000);
});

// The open session's worker badge (info_bar_model.js workerBadgeFor).
function currentWorkerBadge() {
  return workerBadgeFor(selected, current, versions);
}

// Restart: the session moves to a new worker on the newest chi; the page
// follows it (its bridge_up), the composer's draft stays as it is.
async function restartWorker() {
  const badge = currentWorkerBadge();
  if (!badge || !badge.restart || restartingIds.has(selected)) return;
  if (!confirm(restartConfirmText(current.workerVersion, badge.newest))) return;
  const id = selected;
  restartingIds.add(id);
  updateInfoBar();
  try {
    const result = await restartSession(id);
    showToast(result.version ? `Restarted on chi ${result.version}` : "Restarting: the new worker is starting");
  } catch (e) {
    showToast(cantText("restart", e), null, { sticky: true });
  } finally {
    restartingIds.delete(id);
    updateInfoBar();
  }
}

// The session bar (info_bar_model.js sessionBar): its buttons, and the
// info line rendered by info_bar.js.
function updateInfoBar() {
  const { buttons, bar } = sessionBar({
    id: selected, state: current, sessions: allSessions, versions, cardTitle: (s) => lists.cardTitle(s),
    continuing: continuingIds, restarting: restartingIds, streaming: !!streamControl, running: liveTurn.running,
    now: Date.now(),
  });
  const stopBtn = document.getElementById("infoStopBtn");
  const deleteBtn = document.getElementById("infoDeleteBtn");
  const archiveBtn = document.getElementById("infoArchiveBtn");
  const continueBtn = document.getElementById("infoContinueBtn");
  if (continueBtn) {
    continueBtn.style.display = buttons.continue.shown ? "" : "none";
    continueBtn.disabled = buttons.continue.disabled;
    continueBtn.textContent = buttons.continue.text;
  }
  if (deleteBtn) deleteBtn.style.display = buttons.delete.shown ? "" : "none";
  if (archiveBtn) {
    archiveBtn.style.display = buttons.archive.shown ? "" : "none";
    archiveBtn.textContent = buttons.archive.text;
    archiveBtn.classList.toggle("archived", buttons.archive.archived);
    archiveBtn.title = buttons.archive.title;
  }
  if (stopBtn) stopBtn.style.display = buttons.stop.shown ? "" : "none";
  // No session: the start page hides the info bar (the storage path is on
  // #/sessions). The session clock ticks every second while a turn runs:
  // lit writes its text alone, the bar's other nodes (a tooltip, a button
  // mid-press) stay.
  renderInfoBar(infoTextEl, bar);
  updateSessionTitle();
  // A fresh link's picker follows what the bar follows: its model, its
  // owner, a next link continued from elsewhere.
  syncModelPick();
}

// The open session's title, once on screen (session_title.js): its strip
// card says it when the strip is shown and has one; else the top bar. The
// browser tab names it too. It follows the card's (openTitle): a chain link
// reads its card's title (cardTitle), whatever opener it was sent.
function updateSessionTitle() {
  const shown = selected ? lists.sessionsById().get(selected) : null;
  const first = current.firstPreview || "";
  const raw = !selected ? "" : openTitle({ shown, first, cardTitle: (s) => lists.cardTitle(s) });
  const title = raw === "\u2014" ? "" : raw; // "—": no first message yet
  const text = topBarTitle({
    title,
    cardShown: !!topStripEl.querySelector(".card.active"),
    stripHidden: document.body.classList.contains("strip-hidden"),
    allView: allViewOpen(),
  });
  if (sessionTitleEl.textContent !== text) sessionTitleEl.textContent = text;
  if (sessionTitleEl.hidden !== !text) sessionTitleEl.hidden = !text;
  const tip = text ? title : "";
  if (sessionTitleEl.title !== tip) sessionTitleEl.title = tip;
  const tab = tabBase === null ? null : tabTitle({ title, base: tabBase });
  if (tab !== null && tab !== tabShown) {
    tabShown = tab;
    notifications.setBaseTitle(tab);
  }
}

// The stage takes a running turn's rows (its extras); else the history.
function appendToHistory(el) {
  // (The stage's place first moves a turn still sliding away into the history.)
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

function setUsedMemories(names) {
  current.usedMemories = names.slice();
  updateInfoBar();
  const sess = allSessions.find(s=>s.id===selected);
  if (sess) {
    sess.used_memory_names = current.usedMemories.slice();
    lists.render();
    lists.paintActive();
  }
}

// A turn or command just woke the session's worker: follow its stream if
// none is open, from the render's cursor. A render with none (no worker
// then) streams from 0, the start of a new worker's events; should that
// worker have been up already, turn_started says so (replaysDrawnTurn).
function followWokenWorker() {
  if (streamControl?.live) return;
  startStream(selected, current.streamSeq ?? 0);
  current.streamFromGuess = current.streamSeq === null;
}

function startStream(id, fromSeq) {
  current.streamFromGuess = false;
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
    lists.render();
  }
  updateInfoBar();
  // Once: a worker still alive with a bridge (the stream dropped, not the
  // worker: chi web restarted) reconnects right here. Otherwise the next
  // worker's bridge_up event brings the stream back (followSelectedSession).
  if (opened) resync({ endText });
  else setTimeout(() => { if (id === selected && !(streamControl && streamControl.live)) resync({ endText }); }, STREAM_RETRY_MS);
}

// The stream's event handlers (stream_handlers.js); renderSessionView
// replays a snapshot through them too.
const streamHandlers = createStreamHandlers({
  selected: () => selected,
  state: () => current,
  clientId,
  capabilities: () => pageCapabilities,
  historyEl,
  liveTurn,
  turnDom,
  shownTexts,
  questionCards,
  contextChips,
  llmContextControl,
  thinkingControl,
  reasoningHistoryControl,
  sentIds,
  earlyRestores,
  stream: {
    takeGuess: () => {
      const guess = current.streamFromGuess;
      current.streamFromGuess = false;
      return guess;
    },
    restart: () => {
      streamControl?.close();
      streamControl = null;
      resync();
    },
  },
  composer: {
    empty: () => !promptEl.value.trim() && !chips.length,
    refill: (text) => {
      promptEl.value = text;
      fitPrompt();
    },
    setChips: (list) => setChips(list),
  },
  getSession,
  resync: () => resync(),
  updateInfoBar: () => updateInfoBar(),
  applyPromptOps: (data) => applyPromptOps(data),
  showSteers: (steers) => showSteers(steers),
  markRecapStale: () => markRecapStale(),
  setTurnRunning: (running) => setTurnRunning(running),
  setLiveStatus: (status) => setLiveStatus(status),
  endTurnView: (kind, endText, opts) => endTurnView(kind, endText, opts),
  appendChunk: (text) => appendChunk(text),
  readTurnEnd: () => readTurnEnd(),
  applyFinalMarkdown: (messages) => applyFinalMarkdown(messages),
  refreshTimingFromSession: () => refreshTimingFromSession(),
  makeUserBubble: (prompt, opts) => makeUserBubble(prompt, opts),
  addEndBubble: (text) => addEndBubble(text),
  commandBubble: (id) => commandBubble(id),
  addCommandBubble: (view) => addCommandBubble(view),
  addNoteBubble: (note) => addNoteBubble(note),
  findInTurnRoots: (selector) => findInTurnRoots(selector),
  setUsedMemories: (names) => setUsedMemories(names),
  showRecap: (text) => showRecap(text),
  showGuardrailWarning: (text, label) => showGuardrailWarning(text, label),
  showHookNotice: (data) => showHookNotice(data),
  onInitEvent: (type, data) => onInitEvent(type, data),
  upsertCard: (card) => upsertCard(card),
  refreshCardBodies: () => refreshCardBodies(),
  syncModelPick: () => {
    if (pendingPick) pickRanEarly = true;
    syncModelPick();
  },
});

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
  lists.render();
}

// A first message: an idle session, then the turn (or the command) into it
// as for any later one (handleSendTurn), so a failed first turn's prompt
// comes back into the composer too (sentIds).
function handleCreate() {
  return handleSendTurn();
}

// +delivery+: the composer's choice for a running turn (Alt+Enter: queue;
// a delivery-line link: cut or queue); else the armed one; a typed /cut or
// /queue wins over both.
async function handleSendTurn({ delivery: chosen = null } = {}) {
  if (current.owner === "tui") return;
  // A fresh link's pick first: its /model is queued in the worker once
  // acked, and the worker runs queued commands before a turn's input.
  if (pendingPick) await pendingPick;
  let prompt = turnText(promptEl.value, chips);
  if (!prompt) return;
  const armed = deliveryControl.take();
  // An image-only send's text is its placeholders: not for ↑.
  const typed = promptEl.value.trim() !== "";
  // The composer holds the line as typed until the ack (composerAfterAck).
  const line = prompt;
  // Where the line goes (composer.js): the page's own reply, a session to
  // make first (the start page), a command, or a turn.
  let route = routeComposerLine(prompt, {
    session: !!selected, running: liveTurn.running, commands: current.commands, images: chips.length,
  });
  if (route.create) {
    actionBtn.disabled = true;
    try {
      const s = await createIdleSession({ dir: scope.dir, model: chosenModel(), preview: route.send,
                                          llm_context: choiceWords(newChatLlmContext),
                                          thinking: newChatThinking || undefined });
      // The choice was for this chat only.
      newChatLlmContext = null;
      renderNewChatLlmContext();
      newChatThinking = null;
      renderNewChatThinking();
      addCreatedSession(s);
      await select(s.id);
    } catch (e) {
      alert(e.message);
      return;
    } finally {
      actionBtn.disabled = false;
    }
    // In the new session, by its command list (select read it).
    route = routeSessionLine(route.send, { commands: current.commands, images: chips.length, delivery: route.delivery });
  }
  if (route.reply) {
    // The start page's reply is a notice: no session is made for it (2.29).
    if (selected) addCommandBubble({ label: null, line: route.line, text: route.reply });
    else showNotice(route.reply);
    clearComposer();
    return;
  }
  if (route.command) return composerCommands.send(route.command);
  prompt = route.send;
  const running = liveTurn.running && !!selected;
  const delivery = route.delivery || (running ? chosen || armed : null);
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  // Sending moves a finished turn out of the stage at once (else the echo
  // would land among its rows); into a running one it is a queued row there.
  turnDom.handOff?.({ immediate: true });
  const sending = chips.slice();
  // Into a running turn the echo says what it waits for (its delivery); a
  // line with images always waits for the turn's end (the worker queues it).
  const shownDelivery = running ? (sending.length ? "queue" : delivery || "next_step") : null;
  const echo = makeUserBubble(prompt, { state: "queued", own: true, images: sending, delivery: shownDelivery });
  if (!turnDom.holds?.()) historyEl.scrollTop = historyEl.scrollHeight;
  if (!current.firstPreview || current.firstPreview==="—") {
    current.firstPreview = firstPreview(prompt);
    updateInfoBar();
  }
  actionBtn.disabled = true;
  // The session the line goes to: the page may switch to another while an
  // image uploads or the turn is sent, and what follows stays with this one.
  const sentTo = selected;
  try {
    await uploadChips(sending, sentTo, { upload: uploadImage });
    const ack = await sendTurn(sentTo, prompt, { clientId, images: turnRefs(sending), history: typed, delivery });
    if (ack?.command_id) {
      // The worker knew it as a command (its list was newer than ours):
      // its command_ran shows it, not a prompt bubble.
      echo.remove();
      clearComposer();
      if (sentTo === selected) followWokenWorker();
      return;
    }
    if (ack?.enqueued_id) sentIds.add(ack.enqueued_id);
    // A cut the worker didn't take (no thinking-only step: cut off) goes in
    // at the next step; a queue whose turn ended meanwhile is the next turn.
    if (ack?.cut === "off" || (ack?.delivery === "next_step" && echo.dataset.delivery === "queue")) {
      setBubbleDelivery(echo, ack.cut === "off" ? "next_step" : null);
    }
    refreshHistory();
    // A turn that failed fast was restored before this ack: its prompt
    // (and images) go back into the composer, without replacing text typed
    // since (4.13). The composer still holds the text just sent: it goes.
    const restored = restoreOnAck(ack?.enqueued_id, earlyRestores, { myId: clientId, sentIds });
    promptEl.value = composerAfterAck({ sent: line, current: promptEl.value, refill: restored?.refill || "" });
    fitPrompt();
    clearChips();
    if (restored?.images?.length) setChips(restoredChips(sentTo, restored.images));
    // Its turn_enqueued usually tagged the echo already; the ack covers a
    // worker that wasn't live (no turn_enqueued then).
    if (ack?.enqueued_id && !echo.dataset.enqueuedId && !bubbleById(ack.enqueued_id)) {
      echo.dataset.enqueuedId = ack.enqueued_id;
    }
    // A live stream carries this turn already; restarting it would drop the
    // events in between. Without one, POST /turn just woke a worker: its
    // events start after the seq the session was rendered at (0 for a new
    // worker process). A switch since then opened the other session's own.
    if (sentTo === selected) followWokenWorker();
  } catch (e) {
    echo.remove();
    // The turn never reached the worker's queue: an early restore waiting
    // for its ack is never taken back (4.13), so drop it here. The prompt
    // is still in the composer, as the echo was removed.
    dropEarlyRestores(earlyRestores);
    // The chips stay (uploaded ones keep their ref, to sentTo) for another try: an
    // image refused (bad_image, too_large, bad_images) says why below.
    if (e.code === "owned_by_tui") {
      if (sentTo !== selected) return alert(e.message);
      current.owner = "tui";
      updateComposerMode();
      return;
    }
    // A stale tab sent into a session deleted meanwhile: the start page
    // says so, and the line stays in the composer.
    if (e.code === "not_found") return leaveGoneSession(sentTo, "not_found");
    // A /queue to a worker that can't queue (it would steer): its words, the text kept.
    if (e.code === "delivery_unavailable" && sentTo === selected) return addCommandBubble({ label: null, line, text: e.body?.detail || e.message, failed: true });
    alert(e.message);
  } finally {
    actionBtn.disabled = current.owner === "tui";
    promptEl.focus();
  }
}

// /model, !ls … from the composer, and a control's command (the llm ctx
// and thinking chips): composer.js.
const composerCommands = createComposerCommands({
  session: () => selected,
  clientId,
  sendCommand,
  followWokenWorker: () => followWokenWorker(),
  refreshHistory: () => refreshHistory(),
  failed: (line, text) => addCommandBubble({ label: null, line, text, failed: true }),
  // As handleSendTurn says a turn's failure after a switch.
  failedElsewhere: (line, text) => alert(`${line}: ${text}`),
  ownedByTui: () => {
    current.owner = "tui";
    updateComposerMode();
  },
  composer: {
    busy: () => { actionBtn.disabled = true; },
    clear: () => clearComposer(),
    done: () => {
      actionBtn.disabled = current.owner === "tui";
      promptEl.focus();
    },
  },
});

function runSessionCommand(line) {
  return composerCommands.run(line);
}

function clearComposer() {
  promptEl.value = "";
  fitPrompt();
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
// until the list is in, and in a session (its model is in the info bar),
// but a fresh chain link's (chains.js freshLink): there it shows the link's
// model and a pick runs /model in the link, remembered neither as this
// browser's choice nor in Recent. A host that failed is the picker's
// tooltip; a route that fails leaves the picker hidden and the server's
// default in charge. The search list itself is model_picker.js'; a pick
// sends the focus to the message box.
const START_PICK_TITLE = "The model the new chat starts on";
let startPickTitle = START_PICK_TITLE;
// The fresh link the picker shows (null: the start page, or a session it
// is hidden in), and a link pick's /model still in flight (a send waits).
let pickLinkId = null;
let pickSelected = null;
let pendingPick = null;
let pendingPickId = null;
// A command_ran came while the pick was in flight (its sync was skipped):
// the ack syncs then.
let pickRanEarly = false;
const modelPicker = createModelPicker({
  button: modelPickEl,
  panel: $("#modelPanel"),
  input: $("#modelSearch"),
  list: $("#modelList"),
  composer: $("#composer"),
  center: $("#center"),
  remember: () => !selected,
  onPick: (name) => {
    if (selected) pickForLink(name);
    else {
      renderNewChatLlmContext();
      renderNewChatThinking();
    }
    promptEl.focus();
  },
});
// A pick on a fresh link: /model in its worker (its command bubble and the
// info bar follow from command_ran); refused, the button goes back to the
// link's model, if the page is still on that link.
function pickForLink(name) {
  const id = selected;
  const run = runSessionCommand(`/model ${name}`).then((ok) => {
    const ranEarly = pendingPick === run && pickRanEarly;
    if (pendingPick === run) {
      pendingPick = null;
      pendingPickId = null;
      pickRanEarly = false;
    }
    if ((!ok || ranEarly) && selected === id) syncModelPick();
    return ok;
  });
  pendingPick = run;
  pendingPickId = id;
  pickRanEarly = false;
}
// The button's name, tooltip and label for what the page shows: a fresh
// link's model, else the start page's (whose choice stays as it is).
// Toggles the fresh-link class (the CSS shows the button in a session
// only with it); the panel closes when the link changes or stops being fresh.
function syncModelPick() {
  // The list walk only for a link that is fresh otherwise (the info bar
  // calls this every second while a turn runs).
  const fresh = !!selected && freshLink(current, { running: liveTurn.running })
    && !chainNeighbours(allSessions, selected, { continues: current.continues }).next;
  document.body.classList.toggle("fresh-link", fresh);
  const linkId = fresh ? selected : null;
  // Another session (or the start page), or the link stopped being fresh:
  // a panel left open would come back open where it no longer belongs.
  if (selected !== pickSelected || linkId !== pickLinkId) modelPicker.close();
  pickSelected = selected;
  pickLinkId = linkId;
  if (fresh) {
    // A pick in flight keeps its name until its /model is taken (its
    // command_ran syncs again then).
    if (!(pendingPick && pendingPickId === selected)) modelPicker.show(current.model);
    modelPickEl.title = "The model this link starts on";
    modelPickEl.setAttribute("aria-label", "Model this link starts on");
  } else {
    modelPickEl.title = startPickTitle;
    modelPickEl.setAttribute("aria-label", "Model for the new chat");
  }
}
// Leaving a session: the start page's remembered model again (no fetch).
function restoreStartPick() {
  let stored = null;
  try { stored = localStorage.getItem(MODEL_KEY); } catch (_) {}
  modelPicker.restore(stored);
  renderNewChatLlmContext();
  renderNewChatThinking();
}
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
  startPickTitle = payload.warning ? `${START_PICK_TITLE} · ${payload.warning}` : START_PICK_TITLE;
  modelPickEl.hidden = false;
  // A fresh link open meanwhile shows its own model again, not the stored one.
  syncModelPick();
  renderNewChatLlmContext();
  renderNewChatThinking();
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
  render(chipsTemplate(chips), chipsEl);
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
// In the stage view the stage floats above the card, out of the dock's flow
// (stage_view.js): the reserve counts it too, with its 10 px gap, while it
// shows.
const dockEl = $("#dock");
const centerEl = $("#center");
// A leaving stage (the hand-off's slide) no longer counts: the reserve eases
// down over the slide (index.html, #center.reserve-easing).
const stageEl = view === "stage" ? turnDom.root : null;
function dockReserve() {
  const shown = stageEl && !stageEl.hidden && !stageEl.classList.contains("leaving");
  return dockEl.offsetHeight + (shown ? stageEl.offsetHeight + STAGE_GAP : 0);
}
const historyEnd = () => historyEl.scrollHeight - historyEl.clientHeight;
// A reader at the end stays there when the reserve changes: at once for the
// composer card, eased for the stage (+fromStage+: it appeared, grew or
// leaves), so the history glides rather than jumps. An eased follow running
// counts as at the end.
function updateReserve({ fromStage = false } = {}) {
  const follow = atHistoryEnd() || historyEl.dataset.following !== undefined;
  const leaving = !!stageEl?.classList.contains("leaving");
  centerEl.classList.toggle("reserve-easing", leaving);
  const reserve = `${dockReserve()}px`;
  const changed = centerEl.style.getPropertyValue("--dock-h") !== reserve;
  if (changed) centerEl.style.setProperty("--dock-h", reserve);
  if (changed && follow) {
    if (fromStage) easeScrollTo(historyEl, historyEnd, { ms: leaving ? FOLD_MS : FOLLOW_MS, reduce: reducedMotion() });
    else if (historyEl.dataset.following === undefined) historyEl.scrollTop = historyEl.scrollHeight;
  }
  placeToast();
}
const dockObserver = new ResizeObserver((entries) => updateReserve({ fromStage: entries.some((e) => e.target === stageEl) }));
dockObserver.observe(dockEl);
if (stageEl) {
  dockObserver.observe(stageEl);
  // Only showing, hiding and leaving change the reserve (not the stage's
  // other classes: waiting, in-use…).
  let stageShown = "";
  new MutationObserver(() => {
    const shown = `${stageEl.hidden}|${stageEl.classList.contains("leaving")}`;
    if (shown === stageShown) return;
    stageShown = shown;
    updateReserve({ fromStage: true });
  }).observe(stageEl, { attributes: true, attributeFilter: ["class", "hidden"] });
}
window.addEventListener("resize", () => placeToast());

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
  // Esc lets go of a choice armed on the delivery line.
  if (e.key === "Escape" && deliveryControl.disarm()) {
    e.preventDefault();
    return;
  }
  // An IME's Enter picks the composition, it doesn't send.
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    if (!selected) handleCreate();
    // Alt/Option+Enter: queued for after the running turn (D6), only to a
    // worker that queues (else it would steer): the text stays, a note says why.
    else if (e.altKey && liveTurn.running && !current.workerFeatures.includes("delivery")) {
      addCommandBubble({ label: null, line: promptEl.value.trim(), text: QUEUE_NEEDS_WORKER, failed: true });
    } else handleSendTurn(e.altKey ? { delivery: "queue" } : {});
  }
});
$("#infoStopBtn").addEventListener("click", async () => {
  if (!selected) return;
  if (!confirm(`Stop session ${selected}?`)) return;
  const id = selected;
  stoppingId = id;
  try {
    await stopSession(id);
    if (id === selected) stoppedWorker(id);
  } catch (e) {
    // A refusal (a terminal holds it) or a worker that won't stop: said, as
    // a failed restart is.
    showToast(cantText(`stop ${id.slice(0, 8)}`, e), null, { sticky: true });
  } finally {
    stoppingId = null;
  }
  // The list hears of the stop from the hub (the stop route rescans it).
  if (!eventsControl) refresh();
});
$("#infoDeleteBtn").addEventListener("click", () => {
  if (selected) confirmDelete(selected);
});
$("#infoContinueBtn").addEventListener("click", () => continueSelected());
$("#infoArchiveBtn").addEventListener("click", () => {
  if (!selected) return;
  if (selectedArchived()) setArchived(selected, false);
  else setArchived(selected, true);
});

// ── Continue (session chains) ───────────────────────────────────────────────
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
  if (!selected || continuingIds.has(selected)) return;
  const id = selected;
  const short = id.slice(0, 8);
  continuingIds.add(id);
  updateInfoBar();
  try {
    const created = await continueSession(id);
    markArchived([id], true);
    addCreatedSession(created);
    const next = created.id;
    // A model fallback's warning stays until closed.
    const sticky = !!created.model_warning;
    if (selected !== id) {
      showToast(continuedText(id, created, { opened: false }), { label: "Open", run: () => select(next) }, { sticky });
      return;
    }
    await select(next);
    if (selected === next) fillOpener(created);
    showToast(continuedText(id, created), null, { sticky });
  } catch (e) {
    const refusal = continueRefusal(e, allSessions);
    if (refusal.kind === "open") {
      if (selected === id) await select(refusal.id);
      showToast(`${short} is continued already: ${selected === refusal.id ? "opened" : "see"} ${refusal.id.slice(0, 8)}`);
    } else if (refusal.kind === "children") {
      showToast(openChildrenTemplate(id, refusal.children, sessionHash), null, { sticky: true });
    } else {
      showToast(`Can't continue ${short}: ${refusal.text}`, null, { sticky: true });
    }
  } finally {
    continuingIds.delete(id);
    updateInfoBar();
  }
}

// The new link's composer: the opener (openerText: the previous link's own,
// else the constant), unless a draft is there (it stays). +created+: the
// continue's 201.
function fillOpener(created) {
  if (promptEl.value.trim() || chips.length) return;
  promptEl.value = openerText(created);
  fitPrompt();
  promptEl.focus();
  promptEl.setSelectionRange(promptEl.value.length, promptEl.value.length);
}

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
// The open session's worker was stopped from here (the stop button, an
// archive): don't wait for its stream to notice.
function stoppedWorker(id) {
  streamControl?.close();
  current.status = "stopped";
  workerGone(id);
}

// @return {ok: true, result} | {ok: false, error}
async function archiveOne(id, archive) {
  // A live worker in the tree is stopped by the archive: the open
  // session's stream ending then is a stop.
  const mine = archive && selected && inTree(allSessions, id, selected) ? selected : null;
  if (mine) stoppingId = mine;
  try {
    const result = archive ? await archiveSession(id) : await unarchiveSession(id);
    markArchived(archive ? result.archived : result.unarchived, archive);
    if (mine && mine === selected && (result.stopped || []).includes(mine)) stoppedWorker(mine);
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
  if (!eventsControl) refresh();
  const what = archive ? "Archived" : "Unarchived";
  showToast(`${what} ${short}`, undo ? { label: "Undo", run: () => setArchived(id, !archive, { undo: false }) } : null);
}

// The toast sits above the session's composer card (measured: it grows with
// a wrapping footer or a taller box), so it never covers the card's
// controls, and above the stage while it shows and a fresh link's open
// model panel (toast_place.js); with no card in sight (the start page, all
// sessions) the CSS's 24 px from the bottom.
function placeToast() {
  const dock = document.getElementById("dock");
  const r = dock.getBoundingClientRect();
  const shownTop = (el) => {
    const box = el && !el.hidden ? el.getBoundingClientRect() : null;
    return box && box.height > 0 ? box.top : null;
  };
  const px = toastBottom({
    inSession: document.body.classList.contains("has-session") && r.height > 0,
    viewportHeight: window.innerHeight,
    dockTop: r.top,
    tops: [shownTop(document.getElementById("turnStage")), shownTop(document.getElementById("modelPanel"))],
    toastHeight: document.getElementById("toast").offsetHeight,
  });
  const bottom = px === null ? "" : `${px}px`;
  const root = document.documentElement.style;
  if (root.getPropertyValue("--toast-bottom") !== bottom) {
    if (bottom) root.setProperty("--toast-bottom", bottom);
    else root.removeProperty("--toast-bottom");
  }
}
// The model panel opening, closing or changing height (its list filters).
new ResizeObserver(() => placeToast()).observe(document.getElementById("modelPanel"));

// sticky: stays until its action or its ✕ (else gone after 6 s). +text+:
// words, or a template (chains.js openChildrenTemplate: a link in it, a
// delegate a continue waits for, opens that session and hides the toast).
let toastTimer = null;
function showToast(text, action = null, { sticky = false } = {}) {
  const el = $("#toast");
  const hide = () => { el.hidden = true; };
  render(html`<span @click=${(e) => { if (e.target.closest?.("a[href]")) hide(); }}>${text}</span>${action
    ? html`<button type="button" class="toast-action" @click=${() => { hide(); action.run(); }}>${action.label}</button>`
    : nothing}${sticky ? html`<button type="button" class="toast-close" title="Dismiss" aria-label="Dismiss" @click=${hide}>✕</button>` : nothing}`, el);
  el.hidden = false;
  placeToast();
  clearTimeout(toastTimer);
  if (!sticky) toastTimer = setTimeout(hide, 6000);
}

// Annotate (annotate_bar.js): a selection in the conversation offers
// "Annotate" and the presets, which append a quote to the composer, and the
// session's plugins' pills (chi.annotation, annotate_actions.js), which fill
// the composer with their command line and the quote, or send it at once.
function fillComposer(text) {
  promptEl.value = text;
  fitPrompt();
  promptEl.focus();
  promptEl.setSelectionRange(promptEl.value.length, promptEl.value.length);
  promptEl.scrollTop = promptEl.scrollHeight;
}

const annotateBar = createAnnotateBar({
  presets: parsePresets(document.body.dataset.annotatePresets),
  canAnnotate: () => !!selected && current.owner !== "tui",
  roots: turnRoots,
  isLive: (root) => liveTurn.running && turnDom.containsLive(root),
  onQuote: (text) => fillComposer(appendQuote(promptEl.value, text)),
  actions: () => annotationActions(current.commands),
  running: () => liveTurn.running,
  onAction: (action, fields) => {
    const line = actionLine(action, fields);
    if (action.send) runSessionCommand(line);
    else fillComposer(composerWithAction(promptEl.value, action, line));
  },
});
historyEl.addEventListener("scroll", annotateBar.schedule);
// A command bubble's Apply (CacheConfirm): sends the change's --yes line
// once; its own bubble then says what it did.
historyEl.addEventListener("click", (e) => {
  const button = e.target.closest?.("[data-confirm-line]");
  if (button) applyConfirm(button, runSessionCommand);
});
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
  updateSessionTitle();
}
function setStripHidden(hidden) {
  if (hidden) lists.familyPop.close();
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

// Esc leaves select mode first, then the all-sessions view.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || !allViewOpen()) return;
  if (lists.selecting.on) {
    if (!lists.selecting.running) lists.leaveSelect();
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
