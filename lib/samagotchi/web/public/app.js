import {
  listSessions,
  getSession,
  sendTurn,
  cancelTurn,
  stopSession,
  sessionHolds,
  stopSessionHolds,
  restartSession,
  deleteSession,
  archiveSession,
  unarchiveSession,
  sendCommand,
  openStream,
  openEvents,
  createIdleSession,
  continueSession,
  startReview,
  uploadImage,
  listModels,
  fetchHistory,
  listContext,
  listParticipants, inviteParticipant, revokeParticipant, setParticipantCap,
  getContext,
  detachContext,
  addContext,
  renderText,
  getWorkingSet,
  updateChi,
  restartWorkers,
  restartWeb,
  onAuthLost,
} from "./data.js";
import { authProbe, createAuthLost } from "./auth_lost.js";
import { REPLACE_SESSION_TEXT, fragmentCode, tradeFragmentCode } from "./token_fragment.js";
import { createContextChips } from "./context_chips.js";
import { createLlmContextControl } from "./llm_context_chip.js";
import { createParticipantsControl } from "./participants_panel.js";
import { createThinkingControl } from "./thinking_chip.js";
import { createReasoningHistoryControl } from "./reasoning_history_chip.js";
import { renderInfoBar } from "./info_bar.js";
import { sessionBar, workerBadgeFor } from "./info_bar_model.js";
import { createShownTexts } from "./shown_texts.js";
import { emptySessionState, sessionStateFrom } from "./session_state.js";
import { thumbsTemplate } from "./images.js";
import { normalize, failedTurnText, cantText, withLiveStatus, withoutWorker } from "./format.js";
import { createTurnView, turnHistoryNodes } from "./turn_view.js";
import { elementOf, emptyAnswerTemplate } from "./turn_html.js";
import { createBubbles, hintEl, outputBubbleTemplate } from "./bubbles.js";
import { createCardsPlace } from "./cards_place.js";
import { createStageView } from "./stage_view.js";
import { createWorkingSet, groupItems } from "./working_set_view.js";
import { turnGroups } from "./timing.js";
import { createGapClock, lastActivity } from "./time_gaps.js";
import { createMarkdownPlace } from "./markdown_place.js";
import { openerFill, openTitle, restoredComposer } from "./chains.js";
import { createTaskStopper } from "./task_stop.js";
import { createSystemOneWrongAction } from "./system_one_wrong.js";
import { appendQuote } from "./annotations.js";
import { applyComposerText, applyRowTemplate, fetchApply } from "./review_apply.js";
import { authorBadge, nameUnnamedBadges } from "./participant_names.js";
import { parsePresets } from "./annotate_presets.js";
import { createAnnotateBar } from "./annotate_bar.js";
import { actionLine, annotationActions, composerWithAction } from "./annotate_actions.js";
import { copyText, installCopy } from "./copy.js";
import { createQuestionCards } from "./question_cards.js";
import { splitSnapshotCards } from "./card.js";
import { PROMPT_LINE_PX, PROMPT_MIN_PX } from "./composer_size.js";
import { mountComposer } from "./composer_mount.js";
import { readStored, writeStored } from "./storage.js";
import { createCommandList } from "./command_list.js";
import { ALL_SESSIONS_HASH, sessionHash, sessionIdFromHash } from "./route.js";
import { scopeDir, scopeTemplate } from "./scope.js";
import { html, render } from "./vendor/lit-html.js";
import { shouldFollowScroll } from "./scroll.js";
import { SHORT_WINDOW_QUERY, stripAutoHidden } from "./strip.js";
import { createStripGrip } from "./strip_grip.js";
import { waitingOn } from "./notify.js";
import { applySessionEvent, sortedByUpdated } from "./sessions_list.js";
import { createNotifications } from "./notifications.js";
import { renameShown, tabTitle, topBarTitle } from "./session_title.js";
import { mergeVersionState, restartConfirmText, versionNotice } from "./update_notice.js";
import {
  appendAboveLiveTiming, mergeTiming, normalizeTiming,
} from "./timing.js";
import { createLiveTurn } from "./live_turn.js";
import { answerRefsOf, applyFinalAnswer, pairAnswerRefs, setAnswerRefs } from "./answer_refs.js";
import { installRefClicks } from "./refs.js";
import { linkRefs, touchedFiles } from "./ref_scan.js";
import { DONE_MS, applyInitEvent, dropDone, fadeDone, initRowTemplate, newInitTasks, seedInitTasks } from "./init_row.js";
import { newClientId, resyncRetry, snapshotEvents, streamDropEnd } from "./turn_events.js";
import { applyConfirm, keptCommandBubbles, restoreCommandBubbles } from "./commands.js";
import { createComposerCommands } from "./composer.js";
import { createStreamHandlers } from "./stream_handlers.js";
import { createListsView } from "./lists_view.js";
import { createDeliveryControl, QUEUE_NEEDS_WORKER } from "./delivery_line.js";
import { liveSlots } from "./stage_model.js";
import { currentGen } from "./turn_model.js";
import { toolName } from "./activity.js";
import { createDockReserve } from "./dock_reserve.js";
import { createToasts } from "./toasts.js";
import { createUnqueue } from "./unqueue.js";
import { createStartPage } from "./start_page.js";
import { createSessionActions } from "./session_actions.js";
import { createStopSheet } from "./stop_sheet.js";
import { createUpdateSheet } from "./update_sheet.js";
import { createRename } from "./session_rename.js";
import { createSendTurn } from "./send_turn.js";
import { createMarkdownTip } from "./markdown_tip.js";

// A link's #code= (behind an auth proxy): traded for the cookie before
// anything else runs; the page reloads without it.
// This page has a session already: the trade would replace it (a link
// someone sent to swap this browser's session for theirs), so ask first.
if (fragmentCode(globalThis.location?.hash)
    && await tradeFragmentCode({ ask: () => globalThis.confirm(REPLACE_SESSION_TEXT) })) await new Promise(() => {});
// Signed out (the proxy's session or chi's token): a banner, or one reload.
const authLost = createAuthLost();
onAuthLost(authLost);

const $ = (s) => document.querySelector(s);
const topStripEl = $("#topStrip");
const allListEl = $("#allList");
const historyEl = $("#history");
const emptyEl = $("#empty");
const composerEl = $("#composer");
// The open session's title in the top bar, when no strip card in sight
// shows it; the tab's base ("Chi · <project>"), set by renderScope.
const sessionTitleEl = $("#sessionTitle");
const sessionTitleRowEl = $("#sessionTitleRow");
const titleRenameBtn = $("#titleRenameBtn");
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
// The open session's participants chip in the info bar, and its panel
// (Invite, revoke, caps, the participant view).
const participantsControl = createParticipantsControl({
  el: infoTextEl,
  session: () => selected,
  api: { list: listParticipants, invite: inviteParticipant, revoke: revokeParticipant, cap: setParticipantCap },
  startReview: (opts) => sessionActions.reviewSelected(opts),
  reviewing: () => sessionActions.reviewing.has(selected),
  // An older prompt drawn before the list came says "a participant": named now.
  onNames: () => nameUnnamedBadges(document),
  onChange: () => updateInfoBar(),
  toast: (text, action, options) => showToast(text, action, options),
});
// The start page's model picker and its LLM context and thinking chips
// (start_page.js); a fresh chain link's picker too.
const startPage = createStartPage({
  pickEl: $("#modelPick"),
  panelEl: $("#modelPanel"),
  searchEl: $("#modelSearch"),
  listEl: $("#modelList"),
  composerEl: $("#composer"),
  centerEl: $("#center"),
  llmContextEl: $("#llmContextNew"),
  thinkingEl: $("#thinkingNew"),
  reviewEl: $("#reviewNew"),
  selected: () => selected,
  state: () => current,
  running: () => liveTurn.running,
  sessions: () => allSessions,
  run: (line) => runSessionCommand(line),
  focusPrompt: () => focusPrompt(),
  toast: (text) => showToast(text),
  listModels,
});
const markdownWarningEl = $("#markdownWarning");
// While web.markdown is off: how to turn it on, until dismissed here.
const markdownTip = createMarkdownTip($("#markdownTip"));
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
const attachBtn = $("#attachBtn");
const attachInput = $("#attachInput");
const infoCancelBtn = $("#infoCancelBtn");
const composeHintEl = $("#composeHint");

let selected = null;
// The session the composer's text was last written in ("" the start page,
// undefined unknown): the composer is one for every session, and continue →
// keeps only a draft of its own (fillOpener).
let draftFrom;
// Record that the composer's text was written now, in session +id+ (default
// the open one). Every write of text into the composer comes through here.
function noteDraft(id) {
  draftFrom = id ?? selected ?? "";
}
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
const markdownPlace = createMarkdownPlace({
  capabilities: () => pageCapabilities,
  renderText,
  roots: () => turnRoots(),
  touchedFiles,
  currentDir: () => current.dir,
  linkRefs,
  applyFinalAnswer,
  findInTurnRoots: (selector) => findInTurnRoots(selector),
  normalize,
  pairAnswerRefs,
  setAnswerRefs,
  answerRefsOf,
});
const { renderMarkdown, pairRefsIn, linkRefsIn, applyFinalMarkdown, linkTextRefs } = markdownPlace;
// The stage view's working set (web.working_set, or ?working_set=1|0):
// what each turn brought into context, in a rail in the stage, a footprint
// under each finished turn and a "set N" chip in the mem chip's place
// (working_set_view.js). The turn view ignores it.
const workingSet = view === "stage" && document.body.dataset.workingSet === "1"
  ? createWorkingSet({
    historyEl, stageRoot: () => turnDom.root, state: () => current, session: () => selected, infoEl: infoTextEl,
    onChange: () => updateInfoBar(), getWorkingSet,
    // A drop or undrop from the list: the session's command, as typed.
    sendLine: (line) => (selected ? sendCommand(selected, line, { clientId }) : null),
  })
  : null;
document.body.classList.toggle("working-set", !!workingSet);
const turnDom = view === "stage"
  ? createStageView({
    ...viewArgs, isNearBottom: () => atHistoryEnd(), dockEl: $("#dock"), centerEl: $("#center"),
    renderMarkdown, linkRefs: linkRefsIn, workingSet,
  })
  : createTurnView(viewArgs);
// The history's bottom reserve and the toast's place follow the composer
// card and the stage floating over the history (dock_reserve.js).
const { placeToast } = createDockReserve({
  dockEl: $("#dock"),
  centerEl: $("#center"),
  stageEl: view === "stage" ? turnDom.root : null,
  historyEl,
  toastEl: $("#toast"),
  modelPanelEl: $("#modelPanel"),
  atHistoryEnd,
});
// Where a running turn's rows can be: the history, and the stage while it
// holds a turn (lookups by id, copy, annotate, card actions).
function turnRoots() {
  return turnDom.root ? [historyEl, turnDom.root] : [historyEl];
}
const systemOneWrongAction = createSystemOneWrongAction({ sessionId: () => selected });
turnRoots().forEach((root) => root.addEventListener("click", systemOneWrongAction));
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
      participantTurn: !!liveTurn.participantTurn,
    };
  },
  composerEmpty: () => !composer.hasDraft(),
  send: (delivery) => handleSendTurn({ delivery }),
  session: () => selected,
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
  renderMarkdown,
  linkRefs: linkRefsIn,
  pairRefs: pairRefsIn,
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
  showGuardrailWarning, showSteers, showHookNotice, addCommandBubble, commandBubble, addNoteBubble, addTimeGap,
} = bubbles;
// The open session's last activity, for the live gap dividers
// (time_gaps.js): renderHistory seeds it, the stream moves it.
const gapClock = createGapClock();
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
// from (new sessions start there), else on a bare page chi web's start
// folder (data-scope-dir); the server names its project, if any.
const scope = {
  dir: scopeDir(location.search) || document.body.dataset.scopeDir || null,
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
      if (updateSheet.reconnected(data.version)) showToast(`chi web reconnected on chi ${data.version}`);
      if (data.chi_update) updateFrame(data.chi_update, { snapshot: true });
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
    chi_update: (data) => updateFrame(data),
  }, {
    dir: scope.dir,
    onError: () => {
      eventsControl = null;
      refresh();
    },
    // The browser gave up after frames: signed out (the proxy's sign-in
    // page answered the reconnect), or chi web went away for a while.
    onClosed: () => {
      eventsControl = null;
      authProbe().then((state) => {
        if (state === "lost") authLost("events");
        else setTimeout(openSessionEvents, EVENTS_REOPEN_MS);
      });
    },
  });
}

const EVENTS_REOPEN_MS = 3000;

// The chi versions carried by each event snapshot and `chi` frame. A toast
// says when chi web was upgraded, a newer one is installed, or an aged one
// is available to update to.
// Once per notice per tab: every reconnect's snapshot says it again.
const versions = { served: null, installed: null };
// The sessions whose Restart is under way (their button says so): one
// session's restart never blocks another's.
const restartingIds = new Set();
// An available release's notice is once per version per browser, not per
// tab: chi web says it in every snapshot until the owner updates.
const AVAILABLE_SHOWN_KEY = "chi_update_available_shown";
const versionNoticesShown = new Set();
const availableShown = readStored(AVAILABLE_SHOWN_KEY);
if (availableShown) versionNoticesShown.add(`available:${availableShown}`);
let versionToast = null;

function noticeVersions(data) {
  Object.assign(versions, mergeVersionState(versions, data));
  const notice = versionNotice({ loaded: document.body.dataset.version, served: versions.served,
                                 installed: versions.installed, available: versions.available,
                                 updateBlocked: versions.updateBlocked, shown: versionNoticesShown });
  updateInfoBar(); // the worker badge compares with the newest installed
  if (!notice) return;
  versionNoticesShown.add(notice.key);
  if (notice.key.startsWith("available:")) writeStored(AVAILABLE_SHOWN_KEY, notice.key.slice("available:".length));
  const text = notice.releaseUrl
    ? html`${notice.text} <a href=${notice.releaseUrl} target="_blank" rel="noopener noreferrer">RubyGems</a>`
    : notice.text;
  const action = notice.reload
    ? { label: "Reload", run: () => location.reload() }
    : notice.updateVersion
      ? { label: "Update", run: () => updateSheet.install(notice.updateVersion) }
      : notice.actions
        ? notice.actions.map((name) => ({
          label: name === "restartWorkers" ? "Restart workers" : "Restart chi web",
          run: () => (name === "restartWorkers" ? updateSheet.restartWorkers() : updateSheet.restartWeb()),
        }))
    : notice.command
      ? { label: "Copy", run: () => copyUpdateCommand(notice.command) }
      : null;
  // One version toast at a time: a newer notice (Reload after a restart)
  // supersedes the one before it.
  toasts.dismiss(versionToast);
  versionToast = toasts.show(text, action, { sticky: true });
}

function updateFrame(data, { snapshot = false } = {}) {
  const wasOpen = updateSheet.isOpen();
  if (!updateSheet.receive(data)) return;
  if (data.operation === "install" && data.state === "done" && data.version) noticeVersions({ installed: data.version });
  if (!wasOpen && data.state === "running") {
    const label = data.operation === "install" ? "Chi update" : "Worker restart";
    showToast(`${label} in progress`, { label: "View", run: () => updateSheet.view() }, { sticky: true });
  } else if (!snapshot && !wasOpen && ["done", "failed"].includes(data.state)
    && !(data.operation === "install" && data.state === "done")) {
    const label = data.operation === "install" ? "Chi update" : "Worker restart";
    showToast(`${label} ${data.state}`, { label: "View", run: () => updateSheet.view() }, { sticky: true });
  }
}

function copyUpdateCommand(command) {
  if (!navigator.clipboard?.writeText) {
    showToast(`Clipboard unavailable; run ${command}`);
    return;
  }
  navigator.clipboard.writeText(command).then(
    () => showToast(`Copied ${command}`),
    () => showToast(`Couldn't copy ${command}`),
  );
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
// new session starts on the start page.
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
  renameShown,
  onRename: () => rename.open(),
  renaming: () => rename.isOpen(),
});

// Continue, Archive, Delete and Stop, and the start page when the open
// session is gone (session_actions.js).
// The Stop sheet first (stop_sheet.js): its buttons are the two ways to stop,
// and the sheet is only shown when the worker has something the user can stop.
const stopSheet = createStopSheet({
  doc: document, win: window,
  stopAll: (id) => sessionActions.stopSelected(id, { stopHolds: true }),
  stopSession: (id) => sessionActions.stopSelected(id),
});

const sessionActions = createSessionActions({
  selected: () => selected,
  state: () => current,
  sessions: () => allSessions,
  setSessions: (list) => { allSessions = list; },
  api: { continueSession, startReview, archiveSession, unarchiveSession, deleteSession, stopSession,
         sessionHolds, stopSessionHolds },
  eventsLive: () => !!eventsControl,
  refresh,
  lists,
  select,
  clearSelection,
  showNotice,
  updateInfoBar,
  toast: showToast,
  addCreatedSession,
  fillOpener,
  restoreDraft,
  closeLiveStream: () => streamControl?.close(),
  workerGone,
  stopSheet,
});
// The title's ✎: /title through the chips' path (session_rename.js), the
// input over the title row on screen: the top bar's when it shows the
// title, else the active strip card's (updateSessionTitle decides which).
const rename = createRename({
  doc: document,
  anchor: () => {
    if (!sessionTitleRowEl.hidden) return sessionTitleRowEl;
    const row = topStripEl.querySelector(".card.active .preview-row");
    return row && row.getClientRects().length ? row : null; // not in the All sessions view's hidden strip
  },
  session: () => selected,
  titleOf: (id) => lists.sessionsById().get(id)?.title || null,
  shownTitle: () => shownTitle(),
  closePopovers: () => {
    lists.familyPop.close();
    lists.chainPop.close();
  },
  // Not from inside a strip draw (its paintActive repositions, which may
  // close): the held strip catches up after it.
  onClose: () => queueMicrotask(() => lists.catchUp()),
  run: (line) => runSessionCommand(line),
});
titleRenameBtn.addEventListener("click", () => rename.open());
document.addEventListener("scroll", () => rename.reposition(), true);
window.addEventListener("resize", () => rename.reposition());

const { confirmDelete, leaveGoneSession, continueSelected, archiveOne, setArchived } = sessionActions;

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
    if (!hadSession) startPage.restoreStartPick();
    fitPrompt();
    placeToast();
  }
  startPage.syncModelPick();
  // The start page's choice was for a new session: opening a session drops it.
  if (selected) startPage.dropChoices();
  const running = liveTurn.running && !!selected;
  cancelBtn.style.display = running ? "" : "none";
  // No images for a session a terminal owns (it takes no message from here);
  // on a phone none while a turn runs either: Stop turn needs the row's room.
  attachBtn.hidden = (!!selected && current.owner === "tui") || (running && narrowScreen.matches);
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
  participantsControl.load(null);
  liveTurn.forget();
  setTurnRunning(false);
  closeStream();
  setMarkdownWarning(null);
  markdownTip.show(null);
  setCapabilities(null, null);
  composer.newVisit();
  updateComposerMode();
  updateInfoBar();
  focusPrompt();
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
promptEl.addEventListener("input", () => noteDraft());
// An emptied composer lets go of its Apply turn.
promptEl.addEventListener("input", () => {
  if (!promptEl.value.trim()) deliveryControl.release();
});

async function select(id) {
  clearNotice();
  selected = id;
  setSessionHash(id);
  lists.paintActive();
  historyEl.replaceChildren(hintEl("Loading…"));
  emptyEl.classList.add("hidden");
  closeStream();
  resyncAttempts = 0; // this session has its own re-read budget
  resetSessionState();
  resetTurnView();
  composer.newVisit();
  updateInfoBar();
  contextChips.load(id);
  participantsControl.load(id);
  updateComposerMode();
  await resync();
  // A folded composer stays folded: typing on the page opens it.
  focusPrompt({ open: false });
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

// A re-read that failed (the phone still offline, chi web a moment): try it
// again, backing off, and stop when the tries run out. The turn view is left
// alone meanwhile: a worker that still owns the turn keeps showing it running,
// and the hub's next event for the session is the fallback once the tries end.
const RESYNC_RETRIES = 3;
let resyncAttempts = 0;

function retryResync(id, { endText = null } = {}) {
  if (id !== selected) return;
  const { attempt, delayMs } = resyncRetry({ attempts: resyncAttempts, max: RESYNC_RETRIES, baseMs: STREAM_RETRY_MS });
  if (delayMs === null) return;
  resyncAttempts = attempt;
  setTimeout(() => {
    if (id !== selected || (streamControl && streamControl.live)) return;
    resync({ endText });
  }, delayMs);
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
      if (id === selected) {
        historyEl.replaceChildren(hintEl(`Error: ${e.message}`));
        retryResync(id, { endText });
      }
      return;
    }
    resyncAttempts = 0;
    if (id !== selected) return;
    // An archived session opens folded: decided once per visit, from its
    // first answer (the list may not hold it yet, or ever under ?dir).
    composer.decideVisit(data.session?.archived);
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
  markdownTip.show(data.markdown_tip);
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
  seedWorkingSet(data);
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
  if (data.saved_recap) showRecap(data.saved_recap.text, data.saved_recap.turns_since, data.saved_recap.created_at || null);
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
    // Its refs on the asking step, as question_requested puts them.
    if (data.pending_question.refs) turnDom.questionRefs?.(data.pending_question.refs);
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

// The working set's turns from a session's messages, as turnHistoryNodes
// numbers them; the running turn (the replay draws it in the stage) isn't
// one of them yet.
function seedWorkingSet(data) {
  if (!workingSet) return;
  const items = data.messages || [];
  const groups = typeof items[0] === "object" && items[0]?.role ? turnGroups(items, current.timing).filter((g) => g.kind === "turn") : [];
  if (data.current_turn && groups.length) groups.pop();
  workingSet.seed(groups.map((g, i) => {
    const text = String(items[g.user]?.content ?? "").replace(/\s+/g, " ").trim();
    return { items: groupItems(g, i), prompt: text.length > 60 ? `${text.slice(0, 59)}\u2026` : text };
  }));
}

function renderHistory(items) {
  gapClock.seed(null);
  if (!items.length) {
    historyEl.replaceChildren(hintEl("No output yet. Send a message."));
    return;
  }
  if (typeof items[0] === "object" && items[0].role) {
    historyEl.replaceChildren(turnHistoryNodes(items, current.timing, { thumbs: (images) => thumbsTemplate(selected, images), workingSet: !!workingSet }));
    // The live dividers count from the history's last activity.
    gapClock.seed(lastActivity(turnGroups(items, current.timing), items));
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
      markdownTip.show(d.markdown_tip);
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
  } catch (_) {
    // A failed read (the server or worker gone a moment) leaves the answer
    // as the stream drew it, plain text: the session's next load renders it.
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

// Apply (review_apply.js) under a participant's review turn that just
// ended live ({turn_id, author, author_name}, from its turn_started), once:
// a reload draws it from the history (turn_view.js).
function placeApply(data) {
  const badge = authorBadge(data.author, data.author_name);
  if (!badge || historyEl.querySelector(`.review-apply[data-apply-turn="${CSS.escape(data.turn_id)}"]`)) return;
  appendToHistory(elementOf(applyRowTemplate(data.turn_id, badge)));
}

// Apply: the owner's Apply turn into the composer, after what is typed
// there; never sent from here.
historyEl.addEventListener("click", async (e) => {
  const button = e.target.closest(".review-apply-btn");
  if (!button || !selected) return;
  const id = selected;
  button.disabled = true;
  try {
    const text = await fetchApply(id, button.dataset.applyTurn);
    if (id === selected) {
      fillComposer(applyComposerText(promptEl.value, text));
      // The owner's own turn: queued after a running one, never steered in.
      deliveryControl.hold();
    }
  } catch (err) {
    showToast(err.message);
  } finally {
    button.disabled = false;
  }
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
    continuing: sessionActions.continuing, restarting: restartingIds, streaming: !!streamControl, running: liveTurn.running,
    now: Date.now(), workingSet: workingSet ? workingSet.chip() : undefined, participants: participantsControl.chip(),
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
  drawFoldControls();
  // No session: the start page hides the info bar (the storage path is on
  // #/sessions). The session clock ticks every second while a turn runs:
  // lit writes its text alone, the bar's other nodes (a tooltip, a button
  // mid-press) stay.
  renderInfoBar(infoTextEl, bar);
  updateSessionTitle();
  // A fresh link's picker follows what the bar follows: its model, its
  // owner, a next link continued from elsewhere.
  startPage.syncModelPick();
}

// The open session's title, once on screen (session_title.js): its strip
// card says it when the strip is shown and has one; else the top bar. The
// browser tab names it too. It follows the card's (openTitle): a chain link
// reads its card's title (cardTitle), whatever opener it was sent.
function shownTitle() {
  const shown = selected ? lists.sessionsById().get(selected) : null;
  const first = current.firstPreview || "";
  const raw = !selected ? "" : openTitle({ shown, first, cardTitle: (s) => lists.cardTitle(s) });
  return raw === "\u2014" ? "" : raw; // "—": no first message yet
}
// The top bar's ✎ follows it (not a plain terminal's session), and an open
// rename input follows the title row on screen (or closes, none showing).
function updateSessionTitle() {
  const title = shownTitle();
  const text = topBarTitle({
    title,
    cardShown: !!topStripEl.querySelector(".card.active"),
    stripHidden: document.body.classList.contains("strip-hidden"),
    allView: allViewOpen(),
  });
  if (sessionTitleEl.textContent !== text) sessionTitleEl.textContent = text;
  if (sessionTitleRowEl.hidden !== !text) sessionTitleRowEl.hidden = !text;
  const renamable = !!text && renameShown(current.owner);
  if (titleRenameBtn.hidden !== !renamable) titleRenameBtn.hidden = !renamable;
  const tip = text ? title : "";
  if (sessionTitleEl.title !== tip) sessionTitleEl.title = tip;
  const tab = tabBase === null ? null : tabTitle({ title, base: tabBase });
  if (tab !== null && tab !== tabShown) {
    tabShown = tab;
    notifications.setBaseTitle(tab);
  }
  rename.follow(selected);
  rename.reposition();
}

// The stage takes a running turn's rows (its extras); else the history.
// @return true when the stage took +el+ (it scrolls it into its view itself)
function appendToHistory(el) {
  // (The stage's place first moves a turn still sliding away into the history.)
  if (turnDom.place?.(el)) return true;
  appendAboveLiveTiming(historyEl, el, liveTurn.timing.el);
  return false;
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

// +opened+ false: the stream never delivered a frame (the proxy answered
// 503, or the bridge refused it), so a retry waits a moment rather than
// spinning through resync → stream → error.
const STREAM_RETRY_MS = 3000;
function workerGone(id, { opened = true } = {}) {
  streamControl = null;
  if (id !== selected) return;
  // A turn that was running is over only when the worker really left: a
  // stream that merely dropped (no stop, it was open) waits for the re-read.
  const stopped = sessionActions.stoppingId() === id;
  const { endNow, endText } = streamDropEnd({ turnRunning: liveTurn.running, stopped, opened });
  if (endNow) {
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
  workingSet,
  participantsControl,
  placeApply,
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
    empty: () => !composer.hasDraft(),
    refill: (text) => {
      // A failed turn's line back: seen, so the composer opens (this visit).
      openForVisit();
      promptEl.value = text;
      noteDraft();
      fitPrompt();
    },
    setChips,
  },
  getSession,
  // The page's hooks, passed as they are: function declarations (hoisted)
  // and the views' methods bound above.
  resync, updateInfoBar, setTurnRunning, setLiveStatus, endTurnView, readTurnEnd, refreshTimingFromSession,
  setUsedMemories, onInitEvent, findInTurnRoots, applyFinalMarkdown,
  // bubbles.js
  applyPromptOps, showSteers, markRecapStale, appendChunk, makeUserBubble, addEndBubble, commandBubble,
  addCommandBubble, addNoteBubble, showRecap, showGuardrailWarning, showHookNotice, addTimeGap,
  gapClock,
  // cards_place.js
  upsertCard, refreshCardBodies,
  syncModelPick: startPage.commandRan,
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

// /model, !ls … from the composer, and a control's command (the llm ctx
// and thinking chips): composer.js.
const composerCommands = createComposerCommands({
  session: () => selected,
  clientId,
  sendCommand,
  followWokenWorker: () => followWokenWorker(),
  refreshHistory: () => refreshHistory(),
  failed: (line, text) => addCommandBubble({ label: null, line, text, failed: true }),
  // As send_turn.js says a turn's failure after a switch.
  failedElsewhere: (line, text, id) => showToast(cantText(`run ${line} in ${id.slice(0, 8)}`, text), null, { sticky: true }),
  ownedByTui: () => {
    current.owner = "tui";
    updateComposerMode();
  },
  composer: {
    busy: () => { actionBtn.disabled = true; },
    text: () => promptEl.value,
    clear: () => clearComposer(),
    done: () => {
      actionBtn.disabled = current.owner === "tui";
      // A chip's command (the info bar) leaves a folded composer folded.
      focusPrompt({ open: false });
    },
  },
});

// The composer's send (send_turn.js): a line into the open session, or a
// new session first on the start page.
const sendTurnControl = createSendTurn({
  session: () => selected,
  state: () => current,
  running: () => liveTurn.running,
  clientId,
  sentIds,
  earlyRestores,
  api: { createIdleSession, uploadImage, sendTurn },
  dir: scope.dir,
  startPage,
  takeDelivery: () => deliveryControl.take(),
  composer: {
    el: promptEl,
    button: actionBtn,
    chips: () => composer.chips(),
    setChips,
    fit: fitPrompt,
    clear: clearComposer,
    openForVisit: () => openForVisit(),
    focus: () => focusPrompt(),
    noteDraft,
  },
  historyEl,
  turnDom,
  makeUserBubble,
  bubbleById,
  addCommandBubble,
  addCreatedSession,
  select,
  showNotice,
  updateInfoBar,
  updateComposerMode,
  followWokenWorker,
  refreshHistory,
  leaveGoneSession,
  runCommand: (command) => composerCommands.send(command),
  toast: showToast,
});
// +delivery+: the composer's choice for a running turn (Alt+Enter: queue;
// a delivery-line link: cut or queue); else the armed one.
function handleSendTurn({ delivery = null } = {}) {
  return sendTurnControl.send({ delivery });
}

function runSessionCommand(line) {
  return composerCommands.run(line);
}

function clearComposer() {
  promptEl.value = "";
  deliveryControl.release();
  fitPrompt();
}

// A queue (Alt+Enter, or an Apply turn's Enter) to a worker that can't
// queue (it would steer): not sent, the text kept, a note says why.
function queueRefused(altKey) {
  if (!selected || !liveTurn.running || current.workerFeatures.includes("delivery")) return false;
  if (!altKey && !deliveryControl.held()) return false;
  addCommandBubble({ label: null, line: promptEl.value.trim(), text: QUEUE_NEEDS_WORKER, failed: true });
  return true;
}

async function handleCancel() {
  if (!selected) return;
  cancelBtn.disabled = true;
  infoCancelBtn.disabled = true;
  try {
    await cancelTurn(selected);
  } catch (e) {
    // The turn ended meanwhile: nothing left to cancel.
    if (e.code !== "not_running") alert(e.message);
  } finally {
    cancelBtn.disabled = false;
    infoCancelBtn.disabled = false;
  }
}

// The chi logo: back to the empty start, where the composer makes a new
// session (from all sessions too).
// The typed draft stays in the composer: paste in a session, then + new session
// starts from it (with the model picker). clearSelection leaves #prompt alone.
$("#newBtn").addEventListener("click", () => {
  if (allViewOpen()) leaveAllView("");
  clearSelection();
  startPage.loadModels({ asked: true });
});

const lightboxEl = $("#lightbox");

// The empty box: one line in a session, three on the start page.
function promptMinPx() {
  return document.body.classList.contains("has-session") ? PROMPT_LINE_PX : PROMPT_MIN_PX;
}

// The composer (composer_mount.js): the box, its height, image chips, grip
// and fold, ↑/↓ history and keys. The owner's parts come in as hooks: the
// draft's origin (noteDraft), the / list's keys, the delivery line's Esc and
// queue, the info bar's Stop turn and drop while folded, typing anywhere.
const composer = mountComposer({
  els: {
    composer: composerEl, prompt: promptEl, button: actionBtn, chips: $("#chips"), attachBtn, attachInput,
    grip: $("#composeGrip"),
  },
  minPx: promptMinPx,
  toast: (text) => showToast(text),
  onWrite: () => noteDraft(),
  // ↑/↓: the prompt history shared with the TUI.
  loadHistory: fetchHistory,
  // Alt/Option+Enter: queued for after the running turn (D6), only to a
  // worker that queues (else it would steer): the text stays, a note says why.
  send: ({ queue }) => {
    if (!selected) return handleSendTurn();
    if (!queueRefused(queue)) handleSendTurn(queue ? { delivery: "queue" } : {});
  },
  keyFirst: (e) => commandList.handleKey(e),
  // Esc lets go of a choice armed on the delivery line.
  escape: () => deliveryControl.disarm(),
  fold: {
    infoCancelBtn,
    infoBarEl: $("#infoBar"),
    session: () => selected,
    waiting: () => !!(waitingOn(allSessions.find((s) => s.id === selected)) || questionCards.pendingQuestion()),
    turnRunning: () => liveTurn.running,
    allViewOpen,
    lightboxOpen: () => !lightboxEl.hidden,
  },
});
// Bound here, not hoisted: no top-level code above this line may call them.
const { openForVisit, focusPrompt, drawFoldControls } = composer;
// Hoisted, for the hooks above that name them (called once the page runs).
function fitPrompt() {
  composer.fit();
}
function setChips(list) {
  composer.setChips(list);
}
function refreshHistory() {
  composer.refreshHistory();
}

// The × on a message queued for after the turn takes it back (unqueue.js).
const unqueue = createUnqueue({
  sessionId: () => selected,
  clientId,
  toast: (text, action, options) => showToast(text, action, options),
  copy: (text) => copyText(text),
  // Edit: the removed text back into an empty composer (never over a draft).
  putBack: (text) => {
    if (composer.hasDraft()) return false;
    openForVisit();
    promptEl.value = text;
    noteDraft();
    fitPrompt();
    promptEl.focus();
    return true;
  },
});
turnRoots().forEach((root) => root.addEventListener("click", (e) => { unqueue.onClick(e); }));
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
infoCancelBtn.addEventListener("click", () => handleCancel());

// The / autocomplete (command_list.js): the session's commands while the
// composer holds one "/word".
const commandList = createCommandList({
  list: $("#commandList"),
  prompt: promptEl,
  commands: () => (selected && current.owner !== "tui" ? current.commands : []),
  afterPick: () => {
    noteDraft();
    fitPrompt();
  },
});

$("#infoStopBtn").addEventListener("click", () => sessionActions.stopSelected());
$("#infoDeleteBtn").addEventListener("click", () => {
  if (selected) confirmDelete(selected);
});
$("#infoContinueBtn").addEventListener("click", () => continueSelected());
$("#infoArchiveBtn").addEventListener("click", () => sessionActions.toggleArchiveSelected());

// The new link's composer: the opener (openerText: the previous link's own,
// else the constant). A draft written in this session (or the new link, or
// of unknown origin) stays instead; one carried over from another session or
// the start page gives way to the opener and is returned, for the toast's
// Restore draft (chains.js openerFill). +created+: the continue's 201;
// +continuedId+: the session continued.
// @return the displaced draft's text, or null
function fillOpener(created, continuedId) {
  const { value, displaced } = openerFill({
    text: promptEl.value, hasChips: composer.chips().length > 0, draftFrom, continuedId, linkId: created.id, created,
  });
  if (value === null) return null;
  openForVisit();
  promptEl.value = value;
  noteDraft(created.id);
  fitPrompt();
  focusPrompt();
  promptEl.setSelectionRange(promptEl.value.length, promptEl.value.length);
  return displaced;
}

// Restore draft (the continue toast's): +draft+ back into the composer,
// over the untouched +opener+ or an empty one, else after what is there
// (chains.js restoredComposer); in whatever session is open now.
function restoreDraft(draft, opener) {
  fillComposer(restoredComposer({ current: promptEl.value, opener, draft }));
}

const toasts = createToasts({ el: $("#toast"), onChange: placeToast });
const updateSheet = createUpdateSheet({
  dialog: $("#updateSheet"),
  update: updateChi,
  restartWorkers,
  restartWeb,
});

function showToast(text, action = null, options = {}) { toasts.show(text, action, options); }

// Annotate (annotate_bar.js): a selection in the conversation offers
// "Annotate" and the presets, which append a quote to the composer, and the
// session's plugins' pills (chi.annotation, annotate_actions.js), which fill
// the composer with their command line and the quote, or send it at once.
function fillComposer(text) {
  openForVisit();
  promptEl.value = text;
  noteDraft();
  fitPrompt();
  focusPrompt();
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
  dock: () => $("#dock"),
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
// when a session needs the user while this tab is not in front. On a
// project's page the Home Screen app's device tidy-up still covers every
// project: it gets a stream of every session of its own (allEvents).
const notifications = createNotifications({
  button: $("#notifyBtn"),
  scoped: !!scope.dir,
  allEvents: (handlers, opts) => openEvents(handlers, opts),
});

// The latest-sessions strip can be hidden for more chat room; the choice
// stays per browser (it replaced zen mode, so a zen user starts hidden).
function stripHiddenSaved() {
  const saved = readStored("chi_strip_hidden");
  return saved === null ? readStored("chi_zen") === "1" : saved === "1";
}
// A short window hides the strip by itself, so the stage keeps room for a
// card that waits (its question and choices); the grip brings it back
// until the window is tall again. Not saved: the saved choice is the
// user's own hide or show.
const shortWindow = window.matchMedia(SHORT_WINDOW_QUERY);
let stripShownWhileShort = false;
// The strip's grip (strip_grip.js): the handle on the edge between the strip
// and the chat. It is given the hidden state and the toggle; it speaks its own
// title and aria-expanded, refreshed below after every change.
const stripGripRefresh = createStripGrip({
  gripEl: $("#stripGrip"),
  isHidden: () => document.body.classList.contains("strip-hidden"),
  setHidden: (hidden) => setStripHidden(hidden),
});
function applyStripHidden() {
  document.body.classList.toggle("strip-hidden", stripAutoHidden({
    saved: stripHiddenSaved(), short: shortWindow.matches, shownWhileShort: stripShownWhileShort,
  }));
  stripGripRefresh();
  updateSessionTitle();
}
function setStripHidden(hidden) {
  if (hidden) lists.familyPop.close();
  writeStored("chi_strip_hidden", hidden ? "1" : "0");
  stripShownWhileShort = !hidden && shortWindow.matches;
  applyStripHidden();
}
applyStripHidden();
shortWindow.addEventListener("change", () => {
  if (!shortWindow.matches) stripShownWhileShort = false;
  applyStripHidden();
});

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
startPage.loadModels();
// The list: the hub's stream when the browser has EventSource, else fetched.
if (typeof globalThis.EventSource === "function") openSessionEvents();
else refresh();
selectFromHash();
