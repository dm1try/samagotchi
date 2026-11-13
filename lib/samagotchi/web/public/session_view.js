// The open session's view (split out of app.js): forgetSession() starts the
// page over for another session, renderSessionView() draws a read of it (the
// history, the replayed turn in progress, the cards, a pending question),
// readTurnEnd() re-reads a turn's end, endTurnView() closes a turn's
// rendering. Kept in app.js's order: their DOM placements depend on it.
//
// Everything that changes while the page runs is read through deps at the
// call, never captured at creation (as stream_handlers.js): the open session
// (store.selected), its fields (store.current), the page's capabilities
// (capabilities()), the views made after this one (the getters in +later+).
//
// deps:
//   store                 the page's session store (session_store.js)
//   historyEl             the history element
//   getSession(id, opts)  data.js
//   liveTurn, turnDom, questionCards, shownTexts, objectives, featureGates, markdownTip
//                         the page's views
//   workingSet            the stage view's working set (web.working_set), null when off
//   gapClock              the page's last activity (time_gaps.js createGapClock)
//   bubbles, cards        bubbles.js, cards_place.js
//   markdown              markdown_place.js (linkTextRefs, applyFinalMarkdown)
//   capabilities()        the page's capabilities (card.js shownElsewhere, the history's cards)
//   page: {setReviseAnchor(anchor), renderInitRow(), setMarkdownWarning(warning),
//          setCapabilities(capabilities, editorUrl, viewer), findInTurnRoots(selector), appendToHistory(el),
//          setTurnRunning(running), mergeTurnTiming(id, timing), applySessionPayload(data, opts),
//          turnEndStatus(data), replaceSelectedCard(change)}  the page's hooks
//   later: {handlers(), composer(), ownerVerify(), commandList(), initTasks(), resetTurnView()}
//                         the views made after this one, and session_sync.js's resetTurnView
//
// @return {forgetSession, renderSessionView, historyOpts, readTurnEnd, endTurnView}
// Its own module: new exports go in new modules (web-frontend.md).

import { emptySessionState, sessionStateFrom } from "./session_state.js";
import { seedInitTasks } from "./init_row.js";
import { restoreCommandBubbles } from "./commands.js";
import { failedTurnText, normalize } from "./format.js";
import { splitSnapshotCards } from "./card.js";
import { turnGroups } from "./timing.js";
import { groupItems } from "./working_set_view.js";
import { thumbsTemplate } from "./images.js";
import { hintEl, outputBubbleTemplate } from "./bubbles.js";
import { turnHistoryNodes } from "./turn_block.js";
import { lastActivity } from "./time_gaps.js";
import { elementOf, emptyAnswerTemplate } from "./turn_html.js";
import { stillOn } from "./latest.js";

export function createSessionView(deps) {
  const {
    store, historyEl, getSession,
    liveTurn, turnDom, questionCards, shownTexts, objectives, featureGates, markdownTip, workingSet = null, gapClock,
    bubbles, cards, markdown, capabilities, page, later,
  } = deps;
  const { makeUserBubble, addEndBubble, showGuardrailWarning, showRecap } = bubbles;
  const { placeSnapshotCards, upsertCard } = cards;
  const { linkTextRefs, applyFinalMarkdown } = markdown;
  const {
    setReviseAnchor, renderInitRow, setMarkdownWarning, setCapabilities, findInTurnRoots, appendToHistory,
    setTurnRunning, mergeTurnTiming, applySessionPayload, turnEndStatus, replaceSelectedCard,
  } = page;
  // The open session's id, for the stale-answer guards (latest.js stillOn).
  const openId = () => store.selected;

  // Forget everything the page knew about the open session: its fields (the
  // info bar, composer, command list), the turn on view, its stream and
  // question cards, its init row, the payload's markdown warning and tip and
  // capabilities, and the composer's Verify claim and Revise (+keepVerify+:
  // the same session opened again keeps them). The one reset list select() and
  // clearSelection() share, so a field the previous session set (its
  // "delegated by" parent, its commands, its card actions) never shows for
  // the next one, also when the next one's read fails.
  function forgetSession({ keepVerify = false } = {}) {
    if (!keepVerify) later.ownerVerify().clear();
    if (!keepVerify) setReviseAnchor(null);
    store.batch(() => {
      store.replaceCurrent(emptySessionState());
      featureGates.prime(store.current);
    });
    later.commandList().close();
    later.resetTurnView();
    objectives.reset();
    seedInitTasks(later.initTasks(), []);
    renderInitRow();
    setMarkdownWarning(null);
    markdownTip.show(null);
    setCapabilities(null, null);
    later.composer().newVisit();
  }

  // A session view: its messages, then the turn in progress and the queued
  // prompts (a live worker's snapshot) replayed through the stream handlers,
  // then a pending question.
  function renderSessionView(data, { kept = [] } = {}) {
    setMarkdownWarning(data.markdown_warning);
    markdownTip.show(data.markdown_tip);
    setCapabilities(data.capabilities, data.editor_url, data.viewer);
    // The saved fill (when there is one) goes in here too, so a reloaded or
    // stopped session shows it before its next turn (a running turn's replay
    // below streams over it).
    const { status, ...fields } = sessionStateFrom(data);
    // The fields in one batch (their chips' popovers, the bar); the replay's
    // own redraws below stay where they run.
    store.batch(() => {
      store.update({ current: fields });
      store.setStatus(status, "payload");
      featureGates.prime(store.current);
    });
    liveTurn.timing.ended = store.current.timing.turnRecords.length;
    const activeTurnId = store.current.timing.activeTurn?.id || null;
    if (data.messages && data.messages.length) renderHistory(data.messages, data);
    else renderHistory(data.history || []);
    seedWorkingSet(data);
    objectives.seed(data.objectives);
    restoreCommandBubbles(historyEl, kept);
    // A failed turn's prompt went back to the user: shown after the
    // conversation, marked failed, as it was live (prompt_restored).
    const failedPrompt = data.failed_turn ? makeUserBubble(data.failed_turn.prompt, { state: "failed" }) : null;
    if (failedPrompt) {
      failedPrompt.dataset.failedTurn = "1";
      addEndBubble(failedTurnText(data.failed_turn));
    }
    seedSeenFromDom();
    seedInitTasks(later.initTasks(), data.init_tasks);
    renderInitRow();
    // A guardrail file that failed to load, announced before this page
    // joined: where it came (the snapshot's cards), else at the end.
    const loadWarned = (label) => (data.cards || []).some((c) => c?.type === "guardrail_warning" && (c.label || "guardrails") === label);
    if (!loadWarned("guardrails")) showGuardrailWarning(data.guardrail_warning);
    if (!loadWarned("plugins")) showGuardrailWarning(data.plugin_warning, "plugins");
    // A live worker's last cards and between-turns notices, where they
    // arrived; the running turn's go into its step once it is drawn.
    const snapshotCards = splitSnapshotCards(data.cards, capabilities());
    // Above a failed turn's prompt: it came after them, and it is no turn.
    placeSnapshotCards(snapshotCards.placed, { before: failedPrompt });
    // The recap saved with the session (also a stopped one's), else a live
    // worker's from before saved_recap existed. After the cards: the last
    // turn's check-in notice goes to the end, and the recap closes the page.
    const saved = data.saved_recap;
    if (saved) showRecap(saved.text, saved.turns_since, saved.created_at || null, saved.opening_id || null);
    else showRecap(data.recap);
    // chi web's unfold of the join (TurnAccumulator.join_events): the turn in
    // progress and the queue behind it as the live events that draw them.
    const replay = data.replay ?? [];
    // Marked replayed: a call's duration isn't timed from the replay's clock.
    replay.forEach((event) => later.handlers()[event.type]?.({ ...event, replayed: true }));
    // A join mid-generation: the worker's word on it clocks the delivery line.
    const gen = data.current_turn?.generation;
    liveTurn.serverGen = gen ? { ...gen, at: Date.now() } : null;
    if (!data.current_turn) {
      setTurnRunning(store.current.status === "running");
      // Running with no turn to draw: the stage's status row still holds Stop turn.
      turnDom.runningWithoutTurn?.(liveTurn.running);
      if (liveTurn.running && store.current.timing.activeTurn?.started_at) liveTurn.timing.start(store.current.timing.activeTurn.started_at, activeTurnId);
    } else if (liveTurn.running) {
      // The live line's turn: the running turn's record's (the replayed
      // turn_started carries the same id, on both unfolds).
      liveTurn.timing.turnId = activeTurnId;
    }
    turnDom.flush();
    snapshotCards.current.forEach((card) => upsertCard(card));
    snapshotCards.during.forEach((card) => upsertCard(card));
    // A question the worker is blocked on (also after a reload).
    if (data.pending_question && data.pending_question.id && data.pending_question.status === "pending") {
      // Its refs on the asking step, as question_requested puts them.
      if (data.pending_question.refs) turnDom.questionRefs(data.pending_question.refs);
      questionCards.renderQuestion(data.pending_question);
      // The turn's replay drew it as asked; the snapshot knows whether it is
      // relayed to the parent now.
      questionCards.markRelayed(data.pending_question.id, data.pending_question.relayed_to || null);
    }
    // A turn ran out of iterations and waits for a yes or no.
    if (data.continue_offer) questionCards.renderContinue(data.continue_offer);
    // A whole view drawn: the composer and the bar once more (the working
    // set's seed may change the bar's chip).
    store.batch(() => {
      store.touch("composer");
      store.touch("infoBar");
    });
  }

  // The working set's turns from a session's messages, as turnHistoryNodes
  // numbers them: the drawn ones (the running turn, which the replay draws
  // in the stage, has no drawing yet).
  function seedWorkingSet(data) {
    if (!workingSet) return;
    const items = data.messages || [];
    const groups = typeof items[0] === "object" && items[0]?.role ? turnGroups(items, store.current.timing, { drawings: data.turn_drawings }).filter((g) => g.kind === "turn") : [];
    workingSet.seed(groups.map((g, i) => {
      const text = String(items[g.user]?.content ?? "").replace(/\s+/g, " ").trim();
      return { items: groupItems(g, i), prompt: text.length > 60 ? `${text.slice(0, 59)}\u2026` : text };
    }));
  }

  // turnHistoryNodes' options for a read's +data+: its turns' drawings
  // (turn_drawing.js), cards (a drawn card's body) and the running turn's id
  // (its prompt has no drawing yet: a plain row, no miss).
  const historyOpts = (data = {}) => ({ thumbs: (images) => thumbsTemplate(store.selected, images), workingSet: !!workingSet,
    drawings: data.turn_drawings || null, cards: data.cards || null, capabilities: capabilities(),
    runningTurnId: data.current_turn?.turn_id || null });

  function renderHistory(items, data = {}) {
    gapClock.seed(null);
    if (!items.length) {
      historyEl.replaceChildren(hintEl("No output yet. Send a message."));
      return;
    }
    if (typeof items[0] === "object" && items[0].role) {
      historyEl.replaceChildren(turnHistoryNodes(items, store.current.timing, historyOpts(data)));
      later.ownerVerify().renderSaved();
      // The live dividers count from the history's last activity.
      gapClock.seed(lastActivity(turnGroups(items, store.current.timing, { drawings: data.turn_drawings }), items));
      linkTextRefs();
    } else {
      historyEl.replaceChildren(...items.map((c) => elementOf(outputBubbleTemplate(c))));
    }
    historyEl.scrollTop = historyEl.scrollHeight;
  }

  async function readTurnEnd() {
    if (!store.selected) return;
    const id = store.selected;
    // The line and the turn this read is for, before the await: a turn
    // queued behind this one may start (a new live line) before it lands.
    const line = liveTurn.timing.capture();
    const still = stillOn(openId);
    try {
      const d = await getSession(id, { tail: true, recent: true, turnId: line.turnId });
      if (!still()) return;
      if (d.session) {
        if (!(await mergeTurnTiming(id, d.timing))) return;
        liveTurn.timing.finishLine(line);
        // The rest in one batch: the bar and the lists redraw once, after the
        // answer's markdown.
        store.batch(() => {
          // The notes chip: the first turn's build (or a /model) records them.
          applySessionPayload(d, { fields: ["usedMemories", "promptNotes"] });
          turnEndStatus(d);
          setMarkdownWarning(d.markdown_warning);
          markdownTip.show(d.markdown_tip);
          setCapabilities(d.capabilities, d.editor_url);
          if (Array.isArray(d.messages)) applyFinalMarkdown(d.messages);
          // Its card, replaced (replaceSelectedCard).
          replaceSelectedCard((sess) => ({ ...sess, used_memory_names: store.current.usedMemories.slice(), status: store.current.status }));
        });
      }
    } catch (_) {
      // A failed read (the server or worker gone a moment) leaves the answer
      // as the stream drew it, plain text: the session's next load renders it.
    }
  }

  function seedSeenFromDom() {
    shownTexts.seed(findInTurnRoots(".bubble").map((b) => normalize(b.textContent)));
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
    // (the turn block places it), else after the turn; before the timing.
    const endNote = emptyAnswer ? elementOf(emptyAnswerTemplate(emptyAnswer)) : null;
    const kept = turnDom.turnEnded({ kind, endNote, emptyAnswer: !!emptyAnswer, turnId: liveTurn.timing.turnId }) || [];
    if (endNote && !endNote.isConnected) appendToHistory(endNote);
    liveTurn.timing.finish({ canceled: kind === "canceled" });
    if (endText) addEndBubble(endText, { stopped });
    if (kept.length) {
      kept.forEach((el) => appendToHistory(el));
      if (!turnDom.holds()) historyEl.scrollTop = historyEl.scrollHeight;
    }
    // The question dies with its turn (the worker stopped waiting).
    if (questionCards.pendingQuestion()) questionCards.resolveQuestion(questionCards.pendingQuestion().id, { cancelled: true, reason: "turn ended" });
  }

  return { forgetSession, renderSessionView, historyOpts, readTurnEnd, endTurnView };
}
