import {
  listSessions,
  getSession,
  sendTurn,
  stopTurn,
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
  renderText,
  getWorkingSet,
  updateChi,
  restartWorkers,
  restartWeb,
  onAuthLost,
  api,
} from "./data.js";
import { authProbe, createAuthLost } from "./auth_lost.js";
import { REPLACE_SESSION_TEXT, fragmentCode, tradeFragmentCode } from "./token_fragment.js";
import { createContextChips } from "./context_chips.js";
import { createParticipantsControl } from "./participants_panel.js";
import { createSettingsControl } from "./settings_chip.js";
import { renderInfoBar } from "./info_bar.js";
import { createMoreSheet } from "./more_sheet.js";
import { createBarFold } from "./bar_fold.js";
import { barItemKeys, sessionBar } from "./info_bar_model.js";
import { createShownTexts } from "./shown_texts.js";
import { emptySessionState } from "./session_state.js";
import { sessionFieldsFrom } from "./session_payload.js";
import { createSessionStore } from "./session_store.js";
import { createFeatureGates } from "./feature_gates.js";
import { stillOn } from "./latest.js";
import { normalize, cantText } from "./format.js";
import { turnHistoryNodes } from "./turn_block.js";
import { elementOf } from "./turn_html.js";
import { createBubbles } from "./bubbles.js";
import { createCardsPlace } from "./cards_place.js";
import { createStageView } from "./stage_view.js";
import { createReloadCheck } from "./reload_check.js";
import { createWorkingSet } from "./working_set_view.js";
import { createObjectives } from "./objectives_wiring.js";
import { createGapClock } from "./time_gaps.js";
import { createMarkdownPlace } from "./markdown_place.js";
import { openerFill, openTitle, restoredComposer } from "./chains.js";
import { createTaskStopper } from "./task_stop.js";
import { createSystemOneWrongAction } from "./system_one_wrong.js";
import { appendQuote } from "./annotations.js";
import { applyComposerText, applyRowTemplate, fetchApply } from "./review_apply.js";
import { nameVerdictCards } from "./verdict_card.js";
import { redrawFresh } from "./verdict_fresh.js";
import { authorBadge, nameUnnamedBadges } from "./participant_names.js";
import { parsePresets } from "./annotate_presets.js";
import { createAnnotateBar } from "./annotate_bar.js";
import { VERIFY_PRESET, VERIFY_UNAVAILABLE, verifyWorkerUnavailable, withVerify } from "./verify_preset.js";
import { actionLine, annotationActions, composerWithAction } from "./annotate_actions.js";
import { createBlockHost } from "./block_host.js";
import { createWidgetDrawer } from "./inline_widgets.js";
import { copyText, installCopy } from "./copy.js";
import { installAnswerFold, sweepAnswerFolds } from "./answer_fold.js";
import { installDetailsMotion } from "./details_motion.js";
import { answerLabel, installReviseStacks, reviseChipTemplate, reviseWorkerUnavailable } from "./revise_stack.js";
import { createQuestionCards } from "./question_cards.js";
import { PROMPT_LINE_PX, PROMPT_MIN_PX } from "./composer_size.js";
import { mountComposer } from "./composer_mount.js";
import { createCommandList } from "./command_list.js";
import { ALL_SESSIONS_HASH, sessionHash } from "./route.js";
import { hashIntent } from "./hash_intent.js";
import { claimFromHash } from "./claim_link.js";
import { createOwnerClaim } from "./owner_claim.js";
import { createOwnerVerify } from "./owner_verify.js";
import { scopeDir, scopeTemplate } from "./scope.js";
import { createProjectPicker } from "./project_picker.js";
import { render } from "./vendor/lit-html.js";
import { shouldFollowScroll } from "./scroll.js";
import { createStripHidden } from "./strip_hidden.js";
import { waitingOn } from "./notify.js";
import { applySessionEvent, sortedByUpdated } from "./sessions_list.js";
import { createNotifications } from "./notifications.js";
import { renameShown, tabTitle, topBarTitle } from "./session_title.js";
import {
  appendAboveLiveTiming, mergeTiming, normalizeTiming,
} from "./timing.js";
import { createLiveTurn } from "./live_turn.js";
import { answerRefsOf, applyFinalAnswer, pairAnswerRefs, setAnswerRefs } from "./answer_refs.js";
import { installRefClicks } from "./refs.js";
import { linkRefs, touchedFiles } from "./ref_scan.js";
import { DONE_MS, applyInitEvent, dropDone, fadeDone, initRowTemplate, newInitTasks } from "./init_row.js";
import { newClientId } from "./turn_events.js";
import { applyConfirm } from "./commands.js";
import { createComposerCommands } from "./composer.js";
import { createStreamHandlers } from "./stream_handlers.js";
import { createListsView } from "./lists_view.js";
import { createDeliveryControl, QUEUE_NEEDS_WORKER } from "./delivery_line.js";
import { createComposerMode } from "./composer_mode.js";
import { liveSlots } from "./stage_model.js";
import { currentGen } from "./turn_model.js";
import { toolName } from "./activity.js";
import { createDockReserve } from "./dock_reserve.js";
import { createToasts } from "./toasts.js";
import { createUnqueue } from "./unqueue.js";
import { createStartPage } from "./start_page.js";
import { createSessionActions } from "./session_actions.js";
import { createStopSheet } from "./stop_sheet.js";
import { createVersionNotices } from "./version_notices.js";
import { createRename } from "./session_rename.js";
import { createSendTurn } from "./send_turn.js";
import { createSessionSync } from "./session_sync.js";
import { createSessionView } from "./session_view.js";
import { createMarkdownTip } from "./markdown_tip.js";
import { withoutStaleParams } from "./stale_params.js";

// A link's #code= (behind an auth proxy): traded for the cookie before
// anything else runs; the page reloads without it.
// This page has a session already: the trade would replace it (a link
// someone sent to swap this browser's session for theirs), so ask first.
if (fragmentCode(globalThis.location?.hash)
    && await tradeFragmentCode({ ask: () => globalThis.confirm(REPLACE_SESSION_TEXT) })) await new Promise(() => {});
// A query parameter the page no longer reads (?view=, the removed turn
// view's) leaves the address bar, so the next bookmark is clean.
const staleFree = withoutStaleParams(location.search);
if (staleFree !== null) history.replaceState(null, "", location.pathname + staleFree + location.hash);
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
  api: { list: listContext, show: getContext, detach: detachContext },
  toast: (text) => showToast(text),
});
// The open session's ⚙ chip in the info bar, and its panel (thinking,
// reasoning history, LLM context): a pick runs its command in the session's
// worker.
const settingsControl = createSettingsControl({
  el: infoTextEl,
  summaries: () => (store.selected ? { thinking: store.current.thinking, reasoningHistory: store.current.reasoningHistory,
                                       llmContext: store.current.llmContext } : null),
  session: () => store.selected,
  running: () => liveTurn.running,
  run: (line) => runSessionCommand(line),
});
// ⋯ on the info bar, and its menu: the chips and buttons the row has no room for.
const moreSheet = createMoreSheet({ el: $("#infoBar"), button: $("#infoMoreBtn"), session: () => store.selected, hash: sessionHash });
// The bar's fold (bar_fold.js): one row, what doesn't fit folded into ⋯. A
// resize, the fonts or a zoom refolds it by itself: ⋯ follows on the redraw.
const barFold = createBarFold({ barEl: $("#infoBar"), keysFor: barItemKeys, onChange: () => store.touch("infoBar") });
// The open session's participants chip in the info bar, and its panel
// (Invite, revoke, caps, the participant view).
const participantsControl = createParticipantsControl({
  el: infoTextEl,
  session: () => store.selected,
  api: { list: listParticipants, invite: inviteParticipant, revoke: revokeParticipant, cap: setParticipantCap },
  startReview: (opts) => sessionActions.reviewSelected(opts),
  reviewing: () => sessionActions.reviewing.has(store.selected),
  // An older prompt drawn before the list came says "a participant": named now.
  onNames: () => {
    nameUnnamedBadges(document);
    nameVerdictCards(historyEl, (author) => {
      const badge = authorBadge(author);
      return badge && !badge.unnamed ? badge.name : null;
    });
  },
  onChange: () => store.touch("infoBar"),
  toast: (text, action, options) => showToast(text, action, options),
});
// The start page's model picker, its ⚙ panel and 🧰 list with the override chips
// (start_page.js); a fresh chain link's picker too.
const startPage = createStartPage({
  pickEl: $("#modelPick"),
  panelEl: $("#modelPanel"),
  searchEl: $("#modelSearch"),
  listEl: $("#modelList"),
  composerEl: $("#composer"),
  centerEl: $("#center"),
  settingsEl: $("#settingsNew"),
  llmContextEl: $("#llmContextNew"),
  thinkingEl: $("#thinkingNew"),
  reviewEl: $("#reviewNew"),
  toolkitBtnEl: $("#toolkitBtn"),
  toolkitEl: $("#toolkitNew"),
  selected: () => store.selected,
  state: () => store.current,
  running: () => liveTurn.running,
  sessions: () => store.sessions,
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
const attachBtn = $("#attachBtn");
const attachInput = $("#attachInput");
const composeHintEl = $("#composeHint");

// The open session (store.selected), its fields (store.current: session_state.js;
// forgetSession() starts them over) and every card (store.sessions, the hub's
// projection): session_store.js. Read store.current fresh after every await.
// A write redraws what reads it (the redraws are registered below, before
// the page's first draw); an input the store doesn't hold calls
// store.touch(name).
const store = createSessionStore({ initial: emptySessionState() });
// The page actions the open session's worker must support (feature_gates.js),
// the store's featureGates redraw: a gate's redraw runs when its answer
// flips (a restart brings the feature, the worker goes). forgetSession and
// renderSessionView prime them: the history they draw has the answer already.
const featureGates = createFeatureGates([
  // Verify fresh on a verdict's card.
  {
    name: "verify",
    unavailable: (cur) => verifyWorkerUnavailable(cur.workerFeatures, cur.bridgeUp),
    redraw: () => redrawFresh(historyEl, ownerVerify.freshState()),
  },
  // Revise on an answer and the composer's Revising chip (revise_stack.js).
  {
    name: "revise",
    unavailable: (cur) => reviseWorkerUnavailable(cur.workerFeatures, cur.bridgeUp),
    redraw: () => redrawRevise(),
  },
]);
featureGates.prime(store.current);
// The open session's id, for the stale-answer guards (latest.js stillOn).
const openId = () => store.selected;
// The composer's armed Revise ({turn_id, label}: the answer the next
// message rewrites), shown as its chip; Verify's lifecycle (an emptied
// composer, another session, the send's ack let go of it). Set only
// through setReviseAnchor (it redraws the chip and the answers' buttons).
let pendingReviseAnchor = null;
let reviseStacks = null;
const reviseChipEl = $("#reviseChip");
const reviseUnavailable = () => reviseWorkerUnavailable(store.current.workerFeatures, store.current.bridgeUp);
function redrawRevise() {
  if (reviseChipEl) {
    render(reviseChipTemplate(pendingReviseAnchor, {
      unavailable: reviseUnavailable(),
      onClear: () => { setReviseAnchor(null); focusPrompt(); },
    }), reviseChipEl);
    reviseChipEl.hidden = !pendingReviseAnchor;
  }
  reviseStacks?.decorate();
}
function setReviseAnchor(anchor) {
  if (anchor === pendingReviseAnchor) return;
  pendingReviseAnchor = anchor;
  redrawRevise();
}
// A restored Revise turn's draft ({turn_id}): armed again, its label from
// the answer it names.
function restoreRevise(anchor) {
  if (!anchor?.turn_id) return;
  const answer = historyEl.querySelector(`.bubble.output[data-answer-turn="${CSS.escape(anchor.turn_id)}"]`);
  setReviseAnchor({ turn_id: anchor.turn_id, label: answerLabel(answer) });
}
let annotateBar = null;
// The session the composer's text was last written in ("" the start page,
// undefined unknown): the composer is one for every session, and continue →
// keeps only a draft of its own (fillOpener).
let draftFrom;
// Record that the composer's text was written now, in session +id+ (default
// the open one). Every write of text into the composer comes through here.
function noteDraft(id) {
  draftFrom = id ?? store.selected ?? "";
}
// The session list's stream (GET /api/events); null while the page falls
// back to fetching (a chi web without a hub).
let eventsControl = null;
// The running turn's texts on the page (the turn output dedupe).
const shownTexts = createShownTexts();
const markdownPlace = createMarkdownPlace({
  capabilities: () => pageCapabilities,
  renderText,
  roots: () => turnRoots(),
  touchedFiles,
  currentDir: () => store.current.dir,
  linkRefs,
  applyFinalAnswer,
  findInTurnRoots: (selector) => findInTurnRoots(selector),
  normalize,
  pairAnswerRefs,
  setAnswerRefs,
  answerRefsOf,
});
const { renderMarkdown, pairRefsIn, linkRefsIn, applyFinalMarkdown } = markdownPlace;
// The stage view's working set (web.working_set, or ?working_set=1|0):
// what each turn brought into context, in a rail in the stage, a footprint
// under each finished turn and a "set N" chip in the mem chip's place
// (working_set_view.js).
const workingSet = document.body.dataset.workingSet === "1"
  ? createWorkingSet({
    historyEl, stageRoot: () => turnDom.root, state: () => store.current, session: () => store.selected, infoEl: infoTextEl,
    onChange: () => store.touch("infoBar"), getWorkingSet,
    // A drop or undrop from the list: the session's command, as typed.
    sendLine: (line) => (store.selected ? sendCommand(store.selected, line, { clientId }) : null),
  })
  : null;
document.body.classList.toggle("working-set", !!workingSet);
// The running turn's DOM: the stage pinned above the composer
// (stage_view.js), the turn block (turn_block.js) in its cloud.
const turnDom = createStageView({
  historyEl,
  isNearBottom: () => atHistoryEnd(),
  sawText: (k) => shownTexts.saw(k),
  sessionId: () => store.selected,
  // The stop-task button on a running task_wait, for a worker that has
  // the route (its sidecar features).
  taskStop: createTaskStopper({ sessionId: () => store.selected, features: () => store.current.workerFeatures }),
  dockEl: $("#dock"),
  centerEl: $("#center"),
  renderMarkdown,
  linkRefs: linkRefsIn,
  workingSet,
  // Stop turn in its status row (disabled until the request settles).
  onCancel: () => handleCancel(),
  onHandedOff: (handed) => reloadCheck.handedOff(handed),
  // The quiet signal (stage_stall.js): the stream, what the turn waits on, a joiner's step clock.
  streamLive: () => sessionSync.streamLive(), timingNote: () => liveTurn.timing.note, serverGen: () => liveTurn.serverGen,
});
// The opt-in reload check (web.reload_check): a handed-off turn against a
// reload of it, the counts to chi web (reload_check.js).
const reloadCheck = createReloadCheck({
  enabled: () => document.body.dataset.reloadCheck === "1",
  sessionId: () => store.selected,
  running: () => liveTurn.running,
  read: (id) => getSession(id),
  render: (data) => turnHistoryNodes(data.messages || [], normalizeTiming(data.timing), historyOpts(data)),
  post: (id, body) => api(`/api/sessions/${id}/reload_check`, { method: "POST", body: JSON.stringify(body) }),
});
// The history's bottom reserve and the toast's place follow the composer
// card and the stage floating over the history (dock_reserve.js).
const { placeToast } = createDockReserve({
  dockEl: $("#dock"),
  centerEl: $("#center"),
  stageEl: turnDom.root,
  historyEl,
  toastEl: $("#toast"),
  modelPanelEl: $("#modelPanel"),
  atHistoryEnd,
});
// Where a running turn's rows can be: the history, and the stage while it
// holds a turn (lookups by id, copy, annotate, card actions).
function turnRoots() {
  return [historyEl, turnDom.root];
}
const systemOneWrongAction = createSystemOneWrongAction({ sessionId: () => store.selected });
turnRoots().forEach((root) => root.addEventListener("click", systemOneWrongAction));
function findInTurnRoots(selector) {
  return turnRoots().flatMap((root) => [...root.querySelectorAll(selector)]);
}
// The running turn as the page follows it (live_turn.js): whether one
// runs, its timing line and the turns this page saw end (live_timing.js),
// its merges' bubble flags, its turn-end reads.
const liveTurn = createLiveTurn({
  timing: () => store.current.timing,
  // The stage's status row while it holds the turn (the line moves into
  // the history with it), else the history.
  place: (el) => {
    const stageHost = turnDom.timingHost();
    (stageHost || historyEl).appendChild(el);
    return !!stageHost;
  },
  // The stage's quiet signal and tool clock tick with it (?.: a stage_view.js an open tab loaded before).
  onTick: () => { store.touch("infoBar"); turnDom.tick?.(); },
});

// The composer's delivery line while the open session's turn runs
// (delivery_line.js): where a message typed now goes in, and the cut and
// queue links.
const deliveryControl = createDeliveryControl({
  el: $("#deliveryLine"),
  read: () => {
    const turn = turnDom.current().turn || null;
    const running = turn ? turn.gens.flatMap((g) => g.tools).reverse().find((r) => r.status === "running") : null;
    return {
      phase: turnDom.phase() || liveSlots(turn).phase,
      gen: turn ? currentGen(turn) : null,
      tool: running ? { name: toolName(running), startedAt: running.startedAt ?? null } : null,
      cutAfter: liveTurn.cutAfter,
      serverGen: liveTurn.serverGen,
      canQueue: store.current.workerFeatures.includes("delivery"),
      model: store.current.model,
      participantTurn: !!liveTurn.participantTurn,
    };
  },
  composerEmpty: () => !composer.hasDraft(),
  send: (delivery) => handleSendTurn({ delivery }),
  session: () => store.selected,
});

// This tab's id in the session's events: tells its own prompts from the
// ones other clients (an attached TUI, another tab, reminders) sent.
const clientId = newClientId();
const objectives = createObjectives({
  el: $("#objectivesStrip"), historyEl, session: () => store.selected, running: () => liveTurn.running, holding: () => turnDom.holds(), commands: () => store.current.commands,
  clientId, sendCommand, sendTurn, follow: () => followWokenWorker(), toast: (...args) => showToast(...args),
});
// The question and continue cards in the history (question_cards.js).
const questionCards = createQuestionCards({
  sessionId: () => store.selected,
  clientId,
  place: (card) => appendToHistory(card),
  isNearBottom: () => isNearBottom(),
  scrollToEnd: () => { historyEl.scrollTop = historyEl.scrollHeight; },
  removeHintIfEmpty: () => removeHintIfEmpty(),
  askingText: () => turnDom.askingText(),
  renderMarkdown,
  linkRefs: linkRefsIn,
  pairRefs: pairRefsIn,
  // The bar's chip reads questionCards.pendingQuestion() (sessionWaits).
  onPending: () => store.touch("infoBar"),
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
  selected: () => store.selected,
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
  selected: () => store.selected,
  clientId,
  questionCards,
  bubbles,
  followWokenWorker: () => followWokenWorker(),
});
const { upsertCard, refreshCardBodies } = cards;
turnRoots().forEach((root) => root.addEventListener("click", cards.onCardAction));
// The open session's view (session_view.js): a read drawn, a turn's end,
// the reset for another session; and its sync with the server
// (session_sync.js): select, resync and the stream. Made before the views that
// take their functions (the session actions, the send, the stream handlers);
// the ones made later come in as getters, and each reaches the other lazily.
const sessionView = createSessionView({
  store, historyEl, getSession,
  liveTurn, turnDom, questionCards, shownTexts, objectives, featureGates, markdownTip, workingSet, gapClock,
  bubbles, cards, markdown: markdownPlace,
  capabilities: () => pageCapabilities,
  page: {
    setReviseAnchor, renderInitRow, setMarkdownWarning, setCapabilities, findInTurnRoots, appendToHistory,
    setTurnRunning, mergeTurnTiming, applySessionPayload, turnEndStatus, replaceSelectedCard,
  },
  later: {
    handlers: () => streamHandlers, composer: () => composer, ownerVerify: () => ownerVerify,
    commandList: () => commandList, initTasks: () => initTasks, resetTurnView: () => sessionSync.resetTurnView(),
  },
});
const { forgetSession, historyOpts, readTurnEnd, endTurnView } = sessionView;
const sessionSync = createSessionSync({
  store, historyEl, emptyEl, getSession, openStream,
  liveTurn, turnDom, questionCards, contextChips, participantsControl,
  view: sessionView,
  page: { clearNotice, setSessionHash, setTurnRunning, setLiveStatus, replaceCard, addEndBubble },
  later: {
    handlers: () => streamHandlers, composer: () => composer, focusPrompt: (opts) => focusPrompt(opts),
    sessionActions: () => sessionActions, ownerClaim: () => ownerClaim,
  },
});
const { select, resync, followSelectedSession, followWokenWorker, workerGone } = sessionSync;
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
// The list's first load sweeps the folded answers of sessions gone since
// (answer_fold.js), once per page.
let foldsSwept = false;
function sweepFoldsOnce() {
  if (foldsSwept) return;
  foldsSwept = true;
  sweepAnswerFolds(store.sessions, { scoped: !!scope.dir });
}

// The list by fetching: the fallback when there is no events stream (a
// chi web without a hub, or ?dir the server refused: the 400 is read here).
async function refresh() {
  try {
    store.update({ sessions: await listSessions("updated_at", "desc", { dir: scope.dir }) });
    notifications.noticeList(store.sessions);
    sweepFoldsOnce();
  } catch (e) {
    if (e.status !== 400 || !scope.dir) throw e;
    scopeError = e.message;
    store.update({ sessions: [] });
    renderScope();
  }
}

// The list as a projection of the hub's events: a snapshot on every
// (re)connect, then upserts and removals. The selected session's owner and
// worker follow its events (a new worker's bridge_up reconnects the stream).
function openSessionEvents() {
  eventsControl = openEvents({
    // The list redraws the lists and the bar (its children chip, its chain's
    // ← → links): store.update({sessions}).
    snapshot: (data) => store.batch(() => {
      versionNotices.notice(data);
      versionNotices.reconnected(data.version);
      if (data.chi_update) versionNotices.frame(data.chi_update, { snapshot: true });
      notifications.noticeSessions("snapshot", data);
      store.update({ sessions: applySessionEvent(store.sessions, "snapshot", data) });
      sweepFoldsOnce();
      const sess = store.sessions.find((s) => s.id === store.selected);
      if (sess) followSelectedSession(sess);
    }),
    session: (data) => store.batch(() => {
      notifications.noticeSessions("session", data);
      store.update({ sessions: applySessionEvent(store.sessions, "session", data) });
      if (data.session && data.session.id === store.selected) followSelectedSession(data.session);
    }),
    session_gone: (data) => {
      notifications.noticeSessions("session_gone", data);
      lists.forget(data.id);
      store.update({ sessions: applySessionEvent(store.sessions, "session_gone", data) });
      leaveGoneSession(data.id, "deleted");
    },
    chi: (data) => versionNotices.notice(data),
    chi_update: (data) => versionNotices.frame(data),
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

// The header's scope chip: "<project> · all" in a project view (all links
// to the same place without ?dir); "all projects" otherwise, with where a
// new session starts on the start page.
function renderScope() {
  const el = $("#scope");
  render(scopeTemplate(scope, { error: scopeError, where: () => ({ hash: location.hash }) }), el);
  el.hidden = false;
  // The tab: "<session title> · Chi · <project>" (updateSessionTitle).
  tabBase = scope.projectName ? `Chi · ${scope.projectName}` : "Chi";
  updateSessionTitle();
}

createProjectPicker({
  el: $("#scope"), scope, scopeError: () => scopeError, api,
});

// The session lists (lists_view.js): the strip, all sessions, their cards,
// select mode, the family and chain popovers.
const lists = createListsView({
  doc: document,
  win: window,
  topStripEl,
  allListEl,
  sessions: () => store.sessions,
  selected: () => store.selected,
  scope,
  scopeError: () => scopeError,
  eventsLive: () => !!eventsControl,
  refresh: () => refresh(),
  select: (id) => select(id),
  confirmDelete: (id) => confirmDelete(id),
  setArchived: (id, archive) => setArchived(id, archive),
  archiveOne: (id, archive) => archiveOne(id, archive),
  updateSessionTitle: () => updateSessionTitle(),
  showToast: (text, action) => showToast(text, action),
  allViewOpen: () => allViewOpen(),
  openAllView: () => openAllView(),
  closeAllView: () => closeAllView(),
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
  selected: () => store.selected,
  store,
  sessions: () => store.sessions,
  setSessions: (list) => store.update({ sessions: list }),
  api: { continueSession, startReview, archiveSession, unarchiveSession, deleteSession, stopSession,
         sessionHolds, stopSessionHolds },
  eventsLive: () => !!eventsControl,
  refresh,
  select,
  clearSelection,
  showNotice,
  toast: showToast,
  addCreatedSession,
  fillOpener,
  restoreDraft,
  closeLiveStream: () => sessionSync.closeLive(),
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
  session: () => store.selected,
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
  if (claim) ownerClaim.pending(claim);
  const intent = hashIntent(location.hash, { selected: store.selected, claim });
  if (intent.kind === "session" && intent.id !== store.selected) select(intent.id);
  else if (claim) ownerClaim.showPending();
  else if (intent.kind === "start") clearSelection();
}
// The page's claim links (owner_claim.js): one opened here, once drawn, and
// annotate's Copy link.
const ownerClaim = createOwnerClaim({
  historyEl, store, claimTarget: () => participantsControl.claimTarget(),
  toast: (...args) => showToast(...args), copyText, allViewOpen, home: document.body.dataset.home || "",
});
function applyView() {
  const open = allViewOpen();
  if (!open) {
    allViewPushed = false;
    // A running batch ends on its own and clears the picks then.
    if (lists.selecting.on && !lists.selecting.running) lists.leaveSelect();
    topStripEl.scrollLeft = 0; // a phone's strip scrolls sideways to the tile
  }
  document.body.classList.toggle("all-view", open);
  // The sessions pill is the view's button there: pressed while it is open.
  $("#stripStatus").setAttribute("aria-pressed", String(open));
  updateSessionTitle();
  // Its chip was in the list just hidden (the strip, or all sessions).
  lists.chainPop.close();
  if (open) {
    lists.familyPop.close(); // the strip is hidden in the all view
    // The list is live; only its order can lag (upserts keep cards in
    // place), so the all view opens in the server's order.
    // A new list: the lists' redraw draws the all view (lists.render).
    store.update({ sessions: sortedByUpdated(store.sessions) });
    if (!eventsControl) refresh();
    $("#filter").select();
  }
}
window.addEventListener("hashchange", () => {
  applyView();
  selectFromHash();
});

// The composer's placeholder, hint, buttons and delivery row (composer_mode.js).
const composerMode = createComposerMode({
  els: { body: document.body, prompt: promptEl, hint: composeHintEl, button: actionBtn, attach: attachBtn, empty: emptyEl,
         history: historyEl },
  store, liveTurn, startPage, deliveryControl, fitPrompt, placeToast,
});

function setTurnRunning(running) {
  // A running turn the stage held none of goes with it (runningWithoutTurn).
  if (!running) turnDom.runningWithoutTurn?.(false);
  store.batch(() => {
    liveTurn.running = !!running;
    // A fresh link's picker goes now, not at the timing re-read after the turn.
    if (running && store.selected) store.update({ current: { turnStarted: true } });
    // liveTurn.running isn't the store's: the composer, the bar and the open ⚙ panel's note read it.
    store.touch("composer");
    store.touch("infoBar");
    store.touch("settingsPanel");
  });
}

// Session status is turn state (idle/running): follow the live stream in the
// info bar and the session's card without a refetch.
function setLiveStatus(status) {
  // Its card gets the new dot and time (withLiveStatus); it keeps its place
  // until the next snapshot or the all view re-sorts (no card jumping under
  // the pointer; a session event replaces it in place too, see sessions_list.js).
  store.setStatus(status, "stream");
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
  const still = stillOn(openId);
  setTimeout(() => {
    if (!still()) return;
    fadeDone(initTasks, done);
    renderInitRow();
    setTimeout(() => {
      if (!still()) return;
      dropDone(initTasks, done);
      renderInitRow();
    }, 400);
  }, DONE_MS);
}

function clearSelection() {
  store.batch(() => {
    store.update({ selected: null });
    setSessionHash(null);
    forgetSession();
    contextChips.clear();
    participantsControl.load(null);
  });
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
// An emptied composer lets go of its Apply turn, its Verify claim and its
// Revise.
promptEl.addEventListener("input", () => {
  if (promptEl.value.trim()) return;
  deliveryControl.release();
  ownerVerify.clear();
  setReviseAnchor(null);
});

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

// Sticky-follow scroll: only auto-scroll to the bottom while the user is
// already near it; never yank them back down mid-read. Capture the decision
// BEFORE any DOM mutation that grows the content (new chunk / row / thinking
// delta), so the gap measured is the one the user was sitting at. While the
// stage holds a turn its rows go there: nothing it does moves the history.
function isNearBottom() {
  return !turnDom.holds() && atHistoryEnd();
}

function atHistoryEnd() {
  const { scrollHeight, scrollTop, clientHeight } = historyEl;
  return shouldFollowScroll({ scrollHeight, scrollTop, clientHeight });
}

infoTextEl.addEventListener("click", (e) => {
  if (e.target.closest(".worker-restart")) versionNotices.restart();
  // Pushed as openAllView does, so the view's back returns here.
  if (e.target.closest(".children-chip")) {
    e.preventDefault();
    openAllView();
  }
});
// The info bar's id: a click copies the full id, which the bar shows only short.
infoTextEl.addEventListener("click", async (e) => {
  if (!e.target.closest(".id") || !store.selected) return;
  showToast((await copyText(store.selected)) ? "Session id copied" : "Couldn't copy the session id");
});

// Apply (review_apply.js) under a participant's review turn that just
// ended live ({turn_id, author, author_name}, from its turn_started), once:
// a reload draws it from the history (turn_block.js).
function placeApply(data) {
  const badge = authorBadge(data.author, data.author_name);
  if (!badge || historyEl.querySelector(`.review-apply[data-apply-turn="${CSS.escape(data.turn_id)}"]`)) return;
  appendToHistory(elementOf(applyRowTemplate(data.turn_id, badge)));
}

// The owner's Verify (owner_verify.js): verdict cards, Verify fresh, the claim.
const ownerVerify = createOwnerVerify({
  historyEl, store, api, claim: ownerClaim, liveTurn, toast: (text) => showToast(text),
});

// Apply: the owner's Apply turn into the composer, after what is typed
// there; never sent from here.
historyEl.addEventListener("click", async (e) => {
  const button = e.target.closest(".review-apply-btn");
  if (!button || !store.selected) return;
  const id = store.selected;
  button.disabled = true;
  try {
    const text = await fetchApply(id, button.dataset.applyTurn);
    if (id === store.selected) {
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

// The session bar (info_bar_model.js sessionBar): its buttons, and the
// info line rendered by info_bar.js.
// The open session waits on the user: its card is up, or its summary says so
// (not for a question answered here: the summary is a refresh behind).
function sessionWaits() {
  const summary = waitingOn(store.sessions.find((s) => s.id === store.selected));
  return !!((summary && !questionCards.isResolved(summary.id)) || questionCards.pendingQuestion());
}
function updateInfoBar() {
  annotateBar?.refresh();
  const { buttons, bar } = sessionBar({
    id: store.selected, state: store.current, sessions: store.sessions, versions: versionNotices.versions(), cardTitle: (s) => lists.cardTitle(s),
    continuing: sessionActions.continuing, restarting: versionNotices.restarting, streaming: sessionSync.hasStream(), running: liveTurn.running, waiting: sessionWaits(),
    workingSet: workingSet ? workingSet.chip() : undefined, participants: participantsControl.chip(),
  });
  const stopBtn = document.getElementById("infoStopBtn");
  const deleteBtn = document.getElementById("infoDeleteBtn");
  const archiveBtn = document.getElementById("infoArchiveBtn");
  const continueBtn = document.getElementById("infoContinueBtn");
  if (continueBtn) {
    continueBtn.style.display = buttons.continue.shown ? "" : "none";
    continueBtn.disabled = buttons.continue.disabled;
    continueBtn.textContent = buttons.continue.text;
    // The accent on an archived session, where it is the thing to do.
    continueBtn.classList.toggle("accent", buttons.archive.archived);
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
  const { folded } = barFold.update({ bar, buttons });
  moreSheet.update({ bar, buttons, folded });
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
  const shown = store.selected ? lists.sessionsById().get(store.selected) : null;
  const first = store.current.firstPreview || "";
  const raw = !store.selected ? "" : openTitle({ shown, first, cardTitle: (s) => lists.cardTitle(s) });
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
  const renamable = !!text && renameShown(store.current.owner);
  if (titleRenameBtn.hidden !== !renamable) titleRenameBtn.hidden = !renamable;
  const tip = text ? title : "";
  if (sessionTitleEl.title !== tip) sessionTitleEl.title = tip;
  const tab = tabBase === null ? null : tabTitle({ title, base: tabBase });
  if (tab !== null && tab !== tabShown) {
    tabShown = tab;
    notifications.setBaseTitle(tab);
  }
  rename.follow(store.selected);
  rename.reposition();
}

// The stage takes a running turn's rows (its extras); else the history.
// @return true when the stage took +el+ (it scrolls it into its view itself)
function appendToHistory(el) {
  // (The stage's place first moves a turn still sliding away into the history.)
  if (turnDom.place(el)) return true;
  appendAboveLiveTiming(historyEl, el, liveTurn.timing.el);
  return false;
}

// A turn-end re-read's timing (?tail=1&recent=1: the newest turn's records
// and turn_count) merged into the page's (mergeTiming); when the merge comes
// up short, the whole timing (?timing=1). Never (re)starts live timing: a
// turn that started meanwhile keeps its line and its own active turn.
// @return false when the session changed meanwhile
async function mergeTurnTiming(id, data) {
  const keepActive = () => (liveTurn.running ? store.current.timing.activeTurn : null);
  const merged = mergeTiming(store.current.timing, data);
  store.update({ current: { timing: { ...merged.timing, activeTurn: keepActive() } } });
  if (merged.short) {
    const still = stillOn(openId, id);
    try {
      const full = await getSession(id, { timing: true });
      if (!still()) return false;
      store.update({ current: { timing: { ...normalizeTiming(full.timing), activeTurn: keepActive() } } });
    } catch (_) {
      if (!still()) return false;
    }
  }
  liveTurn.timing.ended = Math.max(liveTurn.timing.ended, store.current.timing.turnRecords.length);
  return true;
}

function setUsedMemories(names) {
  store.batch(() => {
    store.update({ current: { usedMemories: names.slice() } });
    replaceSelectedCard((sess) => ({ ...sess, used_memory_names: store.current.usedMemories.slice() }));
  });
}

// The open session's card replaced by +change(card)+'s copy, in a new list
// (replaceCard). @return whether the list has it
function replaceSelectedCard(change) {
  return replaceCard(store.selected, change);
}

// Session +id+'s card replaced by +change(card)+'s copy, in a new list
// (never changed in place: setStatus and the hub's events replace too).
// @return whether the list has it
function replaceCard(id, change) {
  const i = store.sessions.findIndex((s) => s.id === id);
  if (i < 0) return false;
  const next = store.sessions.slice();
  next[i] = change(next[i]);
  store.update({ sessions: next });
  return true;
}

// A partial re-read of the open session (readTurnEnd, the turn_canceled
// timing re-read): its named +fields+ into the store, read as a full load
// reads them (session_payload.js). Not its status: turnEndStatus. Their
// redraws follow (session_fields.js FIELDS).
function applySessionPayload(data, { fields }) {
  store.update({ current: sessionFieldsFrom(data, fields) });
}

// A turn end's re-read's status, when it carries one (the "turnEnd" rule:
// not over a turn that started meanwhile).
function turnEndStatus(data) {
  const { status } = sessionFieldsFrom(data, ["status"]);
  if (status) store.setStatus(status, "turnEnd", { running: liveTurn.running });
}

// The stream's event handlers (stream_handlers.js); renderSessionView
// replays a snapshot through them too.
const streamHandlers = createStreamHandlers({
  selected: () => store.selected,
  store,
  clientId,
  capabilities: () => pageCapabilities,
  historyEl,
  liveTurn,
  turnDom,
  shownTexts,
  questionCards,
  contextChips,
  workingSet,
  participantsControl,
  placeApply,
  placeVerdict: ownerVerify.placeVerdict,
  restoreVerify: (anchor) => ownerVerify.set(anchor),
  restoreRevise,
  sentIds,
  earlyRestores,
  stream: {
    takeGuess: () => {
      const guess = store.current.streamFromGuess;
      store.update({ current: { streamFromGuess: false } });
      return guess;
    },
    restart: () => sessionSync.restart(),
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
  resync, setTurnRunning, setLiveStatus, endTurnView, readTurnEnd, refreshTimingFromSession,
  setUsedMemories, onInitEvent, findInTurnRoots, applyFinalMarkdown,
  // bubbles.js
  applyPromptOps, showSteers, markRecapStale, appendChunk, makeUserBubble, addEndBubble, commandBubble,
  addCommandBubble, addNoteBubble, showRecap, showGuardrailWarning, showHookNotice, addTimeGap,
  gapClock,
  // cards_place.js
  upsertCard, refreshCardBodies,
  syncModelPick: startPage.commandRan,
  objectivesUpdated: (data) => objectives.update(data),
  cardActionFailed: cards.actionFailed,
});

async function refreshTimingFromSession() {
  if (!store.selected) return;
  const id = store.selected;
  const line = liveTurn.timing.capture();
  const still = stillOn(openId);
  try {
    const data = await getSession(id, { tail: true, recent: true, turnId: line.turnId });
    if (!still()) return;
    turnEndStatus(data);
    if (!(await mergeTurnTiming(id, data.timing))) return;
    liveTurn.timing.finishLine(line);
  } catch (_) {}
}

// A session this tab just created: onto the list now, as the events would
// put it (they follow, with its owner and bridge_up).
function addCreatedSession(created) {
  const { bridge_port: _port, ...session } = created;
  store.update({ sessions: applySessionEvent(store.sessions, "session", { session }) });
}

// /model, !ls … from the composer, and a control's command (the llm ctx
// and thinking chips): composer.js.
const composerCommands = createComposerCommands({
  session: () => store.selected,
  clientId,
  sendCommand,
  followWokenWorker: () => followWokenWorker(),
  refreshHistory: () => refreshHistory(),
  failed: (line, text) => addCommandBubble({ label: null, line, text, failed: true }),
  // As send_turn.js says a turn's failure after a switch.
  failedElsewhere: (line, text, id) => showToast(cantText(`run ${line} in ${id.slice(0, 8)}`, text), null, { sticky: true }),
  ownedByTui: () => {
    // The composer and the bar (its continue and stop, the title's ✎) follow.
    store.update({ current: { owner: "tui" } });
  },
  composer: {
    busy: () => { actionBtn.disabled = true; },
    text: () => promptEl.value,
    clear: () => clearComposer(),
    done: () => {
      actionBtn.disabled = store.current.owner === "tui";
      // A chip's command (the info bar) leaves a folded composer folded.
      focusPrompt({ open: false });
    },
  },
});

// The composer's send (send_turn.js): a line into the open session, or a
// new session first on the start page.
const sendTurnControl = createSendTurn({
  session: () => store.selected,
  store,
  running: () => liveTurn.running,
  clientId,
  sentIds,
  earlyRestores,
  api: { createIdleSession, uploadImage, sendTurn },
  verify: () => ownerVerify.anchor(),
  clearVerify: (anchor) => ownerVerify.clear(anchor),
  restoreVerify: (anchor) => ownerVerify.set(anchor),
  // Not while the gate refuses (the chip says so; the line goes as a plain message).
  revise: () => (reviseUnavailable() ? null : pendingReviseAnchor),
  clearRevise: (anchor) => { if (pendingReviseAnchor === anchor) setReviseAnchor(null); },
  restoreRevise,
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
  if (!store.selected || !liveTurn.running || store.current.workerFeatures.includes("delivery")) return false;
  if (!altKey && !deliveryControl.held()) return false;
  addCommandBubble({ label: null, line: promptEl.value.trim(), text: QUEUE_NEEDS_WORKER, failed: true });
  return true;
}

// The stage's Stop turn (its button stays disabled until this settles).
async function handleCancel() {
  if (!store.selected) return;
  await stopTurn(store.selected, liveTurn.timing.turnId, { resync: () => resync(), onError: (e) => alert(e.message) });
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
// queue, the info bar's drop while folded, typing anywhere.
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
    if (!store.selected) return handleSendTurn();
    if (!queueRefused(queue)) handleSendTurn(queue ? { delivery: "queue" } : {});
  },
  keyFirst: (e) => commandList.handleKey(e),
  // Esc lets go of a choice armed on the delivery line.
  escape: () => deliveryControl.disarm(),
  fold: {
    infoBarEl: $("#infoBar"),
    session: () => store.selected,
    waiting: sessionWaits,
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
  sessionId: () => store.selected,
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

// The / autocomplete (command_list.js): the session's commands while the
// composer holds one "/word".
const commandList = createCommandList({
  list: $("#commandList"),
  prompt: promptEl,
  commands: () => (store.selected && store.current.owner !== "tui" ? store.current.commands : []),
  afterPick: () => {
    noteDraft();
    fitPrompt();
  },
});

$("#infoStopBtn").addEventListener("click", () => sessionActions.stopSelected());
$("#infoDeleteBtn").addEventListener("click", () => {
  if (store.selected) confirmDelete(store.selected);
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
// chi's versions, the update sheet and the worker Restart (version_notices.js).
// After toasts: openSessionEvents, its first caller, runs at boot.
const versionNotices = createVersionNotices({
  store, toasts, dialog: $("#updateSheet"), loadedVersion: document.body.dataset.version,
  api: { updateChi, restartWorkers, restartWeb, restartSession },
});

function showToast(text, action = null, options = {}) { toasts.show(text, action, options); }

// Annotate (annotate_bar.js): a selection in the conversation offers
// "Annotate" and the presets (then the built-in Verify: verify_preset.js,
// only in an ended turn's final answer: verify_target.js), which append a
// quote to the composer, the session's plugins' pills
// (chi.annotation, annotate_actions.js), which fill the composer with their
// command line and the quote, or send it at once, and Copy link in a turn
// (owner_claim.js linkFor).
function fillComposer(text) {
  openForVisit();
  promptEl.value = text;
  noteDraft();
  fitPrompt();
  focusPrompt();
  promptEl.setSelectionRange(promptEl.value.length, promptEl.value.length);
  promptEl.scrollTop = promptEl.scrollHeight;
}

annotateBar = createAnnotateBar({
  presets: withVerify(parsePresets(document.body.dataset.annotatePresets)),
  disabledPreset: (preset) => preset === VERIFY_PRESET
    && verifyWorkerUnavailable(store.current.workerFeatures, store.current.bridgeUp) ? VERIFY_UNAVAILABLE : null,
  offeredPreset: (preset, source, range) => preset !== VERIFY_PRESET || !!ownerVerify.anchorFor({ source, range }),
  canAnnotate: () => !!store.selected && store.current.owner !== "tui",
  roots: turnRoots,
  isLive: (root) => liveTurn.running && turnDom.containsLive(root),
  onQuote: (text) => fillComposer(appendQuote(promptEl.value, text)),
  onPreset: (preset, fields) => ownerVerify.set(preset === VERIFY_PRESET ? ownerVerify.anchorFor(fields) : null),
  actions: () => annotationActions(store.current.commands),
  running: () => liveTurn.running,
  onAction: (action, fields) => {
    const line = actionLine(action, fields);
    if (action.send) runSessionCommand(line);
    else fillComposer(composerWithAction(promptEl.value, action, line));
  },
  link: ownerClaim.linkFor,
  onLink: ownerClaim.copyLink,
  dock: () => $("#dock"),
});

historyEl.addEventListener("scroll", annotateBar.schedule);
// A command bubble's Apply (CacheConfirm): sends the change's --yes line
// once; its own bubble then says what it did.
historyEl.addEventListener("click", (e) => {
  const button = e.target.closest?.("[data-confirm-line]");
  if (button) applyConfirm(button, runSessionCommand);
});
turnDom.scrollEl.addEventListener("scroll", annotateBar.schedule, true);
turnRoots().forEach((root) => installCopy(root));
// chi-ui blocks (inline_widgets.js) are a core drawer, ahead of the bundles'
// renderers; a picks' Fill reply only fills the composer.
const widgets = createWidgetDrawer({ roots: turnRoots(), composerText: () => promptEl.value, fillComposer });
createBlockHost({ roots: turnRoots(), sessionId: () => store.selected, drawers: [widgets] });
// A steps block, a thinking block and the recap open and close by hand
// with their height animated (details_motion.js), in the history and on
// the stage.
installDetailsMotion({ root: document.body, selector: ".turn-work, .bubble.thinking, .bubble.recap" });
// Long answers fold by hand (answer_fold.js), per viewer and session.
installAnswerFold({
  historyEl,
  sessionId: () => store.selected,
  projectRoot: () => store.sessions.find((s) => s.id === store.selected)?.project_root ?? null,
});
// Revise stacks (revise_stack.js): the superseded versions fold to stubs,
// the top answer gets its version chip, a final answer its Revise button.
reviseStacks = installReviseStacks({
  historyEl,
  sessionId: () => store.selected,
  projectRoot: () => store.sessions.find((s) => s.id === store.selected)?.project_root ?? null,
  running: () => (liveTurn.running ? { turnId: liveTurn.timing.turnId || null } : null),
  verifyTurn: (turnId) => (store.current.verdicts || []).some((v) => v.check_turn_id === turnId),
  unavailable: reviseUnavailable,
  armed: () => pendingReviseAnchor?.turn_id ?? null,
  onRevise: (anchor) => {
    setReviseAnchor(anchor);
    openForVisit();
    focusPrompt();
  },
});

// Notifications (notifications.js): an OS notification and a title count
// when a session needs the user while this tab is not in front. On a
// project's page the Home Screen app's device tidy-up still covers every
// project: it gets a stream of every session of its own (allEvents).
const notifications = createNotifications({
  button: $("#notifyBtn"),
  scoped: !!scope.dir,
  allEvents: (handlers, opts) => openEvents(handlers, opts),
});

// The strip hidden or shown (strip_hidden.js): its grip, the saved choice and
// the short window's rule; applied now.
createStripHidden({
  gripEl: $("#stripGrip"), body: document.body, onApply: () => updateSessionTitle(),
  closeFamilyPop: () => lists.familyPop.close(),
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
// The redraws the store runs, by name (session_store.js ORDER), after a
// write of what they read (session_fields.js FIELDS; sessions, selected) or
// a touch(). Registered here, once every piece they call exists: a write
// before it (none at load) would redraw nothing.
store.on("lists", () => lists.render());
store.on("paintActive", () => lists.paintActive());
store.on("settingsPanel", () => settingsControl.refresh());
// The working set's list offers pin only under forget.
store.on("workingSetStrategy", () => workingSet?.strategyChanged());
store.on("featureGates", () => featureGates.check(store.current));
store.on("composer", composerMode.update);
store.on("composer", () => objectives.redraw());
// The answers' Revise buttons follow liveTurn.running too (none on the
// running turn's answer), which touches the composer.
store.on("composer", () => reviseStacks.decorate());
store.on("infoBar", updateInfoBar);

applyView();

// Where sessions live: a footer line under the all-sessions list (the server fills it in).
if (document.body.dataset.sessionsDir) {
  $("#allPath code").textContent = document.body.dataset.sessionsDir;
  $("#allPath").hidden = false;
}

renderScope();
store.batch(() => {
  store.touch("composer");
  store.touch("infoBar");
});
startPage.loadModels();
// The list: the hub's stream when the browser has EventSource, else fetched.
if (typeof globalThis.EventSource === "function") openSessionEvents();
else refresh();
selectFromHash();
