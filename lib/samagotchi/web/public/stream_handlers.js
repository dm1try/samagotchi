// The open session's stream event handlers (GET /stream's typed events, by
// type); renderSessionView replays a snapshot through them too. Split out
// of app.js; no markup of its own: the page passes its views and hooks.
//
// Everything that changes while the page runs is read through deps at the
// event, never captured at creation: the open session (selected()), its
// fields (store.current: app.js forgetSession replaces the object), the page's
// capabilities, the composer's text. A session switch mid-stream is handled
// as before: the handlers act on whatever is open when the event comes.
//
// deps:
//   selected()            the open session's id, or null
//   store                 the page's session store (session_store.js): the
//                         open session's fields are read as store.current
//                         and written with store.update, one patch per handler
//                         (or one batch); a write redraws what reads it (the
//                         bar, a chip's popover), so no handler calls a redraw
//   clientId              this tab's id (own prompts and commands)
//   capabilities()        the page's capabilities (card.js shownElsewhere)
//   historyEl             the history element (keepFollowing, the failed-turn redraw)
//   liveTurn, turnDom, shownTexts, questionCards, contextChips  the page's views
//   workingSet            the stage view's working set (web.working_set),
//                         null when off
//   participantsControl   the owner's participants panel (participants_panel.js),
//                         null for none
//   sentIds, earlyRestores                  restore.js's bookkeeping
//   stream: {takeGuess(), restart()}        the stream was opened from a
//                         guess (takeGuess: whether, and forget it); restart:
//                         close the stream and resync
//   composer: {empty(), refill(text), setChips(chips)}
//   restoreVerify(anchor) a restored Verify turn's claim, armed again for its resend
//   restoreRevise(anchor) a restored Revise turn's draft ({turn_id}), its chip back
//   getSession(id, opts)  data.js
//   resync(), applyPromptOps(data), showSteers(steers),
//   markRecapStale(), setTurnRunning(running), setLiveStatus(status),
//   endTurnView(kind, endText, opts), appendChunk(text), readTurnEnd(),
//   applyFinalMarkdown(messages), refreshTimingFromSession(),
//   makeUserBubble(prompt, opts), addEndBubble(text), commandBubble(id),
//   addCommandBubble(view), addNoteBubble(note), findInTurnRoots(selector),
//   setUsedMemories(names), showRecap(text), showGuardrailWarning(text, label),
//   showHookNotice(data), onInitEvent(type, data), upsertCard(card),
//   refreshCardBodies(), syncModelPick()   the page's hooks
//   gapClock              the page's last activity (time_gaps.js
//                         createGapClock; renderHistory seeds it)
//   addTimeGap(text, {before})              a gap's divider (bubbles.js)

import { routeChunk } from "./chunk_router.js";
import { extractCtxPct, generationTokens } from "./ctx.js";
import { failedTurnText, fullTime } from "./format.js";
import { cancelLineText } from "./timing.js";
import { keepFollowing } from "./scroll.js";
import { shownElsewhere } from "./card.js";
import { restoredChips } from "./images.js";
import {
  clientLabel, displayWait, emptyRetryLine, initWaitLine, isOwn, llmContextNotice, reminderText, replaysDrawnTurn,
  retryStatusLine, steerCutLine, turnOutput,
} from "./turn_events.js";
import { commandView, drawCommandBubble, historyHasCommandBubble } from "./commands.js";
import { keepEarlyRestore, restoreAction } from "./restore.js";
import { PAIR, setBadgeMode } from "./participant_names.js";
import { isParticipantAuthor } from "./participant_model.js";
import { stillOn } from "./latest.js";

export function createStreamHandlers(deps) {
  const {
    selected, store, clientId, capabilities, historyEl,
    liveTurn, turnDom, shownTexts, questionCards, contextChips,
    workingSet = null, participantsControl = null, sentIds, earlyRestores, stream, composer, getSession,
    resync, applyPromptOps, showSteers, markRecapStale, setTurnRunning, setLiveStatus, endTurnView,
    appendChunk, readTurnEnd, applyFinalMarkdown, refreshTimingFromSession, makeUserBubble, addEndBubble,
    commandBubble, addCommandBubble, addNoteBubble, findInTurnRoots, setUsedMemories, showRecap,
    showGuardrailWarning, showHookNotice, onInitEvent, upsertCard, refreshCardBodies, syncModelPick,
    gapClock = null, addTimeGap = () => null,
  } = deps;
  // Activity starts (a turn, a reminder, a note) at +time+ (the event's;
  // none: now): a gap's divider above +before+ (else at the end) when a
  // quiet stretch passed since the last activity.
  function gapBefore(time, before = null) {
    const text = gapClock?.start(time);
    if (text) addTimeGap(text, { before });
  }
  // Activity ended (a turn's end): the next gap counts from now.
  const activityEnded = () => gapClock?.end(null);

  return {
    generation_chunk: (data) => {
      // Route the chunk's bytes to the text bubble and the thinking block (see
      // chunk_router.js).
      const { text, thinking } = routeChunk(data);
      liveTurn.timing.setNote("");
      turnDom.chunk({ text, thinking, iteration: data.iteration ?? null, now: data.replayed ? null : Date.now() });
      const current = store.current;
      const pct = extractCtxPct(data, current.ctxWindow, current.llmContext?.budget_tokens);
      // A chunk with the same % redraws nothing (the store compares).
      if (pct !== null && !Number.isNaN(pct)) store.update({ current: { ctxPct: pct } });
    },
    generation_started: (data) => {
      // The request after a /model's unresolved window started: whatever it
      // brings, the ctx tooltip no longer waits for it (ctxBarTip).
      // A changed value redraws the bar (the store), an unchanged one not.
      const patch = { ctxUnknownAfterSwitch: false };
      if (data?.context_window_tokens) {
        patch.ctxWindow = data.context_window_tokens;
        patch.ctxWindowSource = data.context_window_source || null;
      }
      store.update({ current: patch });
      liveTurn.timing.setNote("");
      // The step's clock (the composer's delivery line): the page's own at a
      // live start; a replay's comes from the snapshot's generation age,
      // which a live start makes stale.
      if (!data?.replayed) liveTurn.serverGen = null;
      turnDom.generationStarted(data || {}, data?.replayed ? null : Date.now());
    },
    generation_completed: (data) => {
      liveTurn.timing.setNote("");
      const current = store.current;
      // The generation's speed and the session's token totals, from the
      // server; the rows per model, the server's whole list (the open one
      // with this generation in). An event without them (a replay, an older
      // worker) keeps the page's: the timing object stays, no redraw.
      const patch = {};
      const tokens = generationTokens(current.timing.tokens, data);
      const segments = Array.isArray(data?.model_segments) ? data.model_segments : null;
      if (tokens !== current.timing.tokens || segments) {
        patch.timing = { ...current.timing, tokens, ...(segments ? { modelSegments: segments } : {}) };
      }
      if (data?.served_model) patch.served = [data.served_model, data.requested_model, data.served_expected_by || null];
      store.update({ current: patch });
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
    // A queued message taken back before it ran (the × here or in another
    // tab, /unqueue in a terminal): its bubble goes, in every tab.
    turn_dequeued: (data) => applyPromptOps(data),
    turn_started: (data) => keepFollowing(historyEl, () => {
      if (stream.takeGuess()) {
        // A replay of a turn the render drew: re-read and stream from there.
        if (replaysDrawnTurn(data, store.current.timing.turnRecords)) {
          stream.restart();
          return;
        }
      }
      // A finished turn still in the stage goes first: the start op looks
      // for a queued prompt among its rows.
      turnDom.handOff({ immediate: true });
      markRecapStale();
      shownTexts.turnStarted();
      const promptBubble = applyPromptOps(data);
      // The turn's wall time (a replay's: its start): the divider above its
      // prompt, or where the turn goes when it has none; its bubble's hover.
      const startedAt = data.at || data.started_at || null;
      gapBefore(startedAt, promptBubble);
      const when = fullTime(startedAt);
      if (when && promptBubble?.setAttribute && !promptBubble.title) promptBubble.title = when;
      liveTurn.cutAfter = data.cut_after ?? null;
      liveTurn.serverGen = null;
      // A participant's review turn: its id and author, for Apply at its end
      // (turn_completed names neither). A pair turn acted itself: no Apply.
      const author = data.author || data.origin?.author;
      const participant = isParticipantAuthor(author);
      const pair = data.participant_mode === PAIR;
      liveTurn.review = participant && data.turn_id && !pair ? { turn_id: data.turn_id, author, author_name: data.author_name } : null;
      // Its prompt drawn while queued takes the turn's mode now.
      if (data.participant_mode) setBadgeMode(promptBubble, data.participant_mode);
      // The owner's input queues behind it (the composer's delivery line).
      liveTurn.participantTurn = participant;
      // One redraw of the composer, the bar and the lists, before
      // keepFollowing's scroll.
      store.batch(() => {
        setTurnRunning(true);
        setLiveStatus("running");
      });
      liveTurn.timing.detach();
      turnDom.turnStarted({ ...data, promptBubble });
      liveTurn.timing.start(data.started_at, data.turn_id || null);
    }),
    turn_completed: async (data) => {
      // The turn's id: the event names it (an older worker names
      // none: its turn_started did).
      const turnId = data.turn_id || liveTurn.timing.turnId || null;
      activityEnded();
      // A participant's turn: their spend and turns in the panel moved.
      if (data.origin?.author) participantsControl?.reload();
      endTurnView("completed", null, { emptyAnswer: data.turn_summary?.empty_answer || null });
      const out = turnOutput(data);
      if (out) appendChunk(out);
      if (data.verdict) deps.placeVerdict?.(data.verdict);
      // A Revise turn that revised: its prompt takes the stamp, as a reload
      // draws it, and the stack folds (revise_stack.js follows the DOM).
      if (data.revises?.turn_id && turnId) {
        for (const prompt of findInTurnRoots(".bubble.user[data-turn-id]")) {
          if (prompt.dataset.turnId === turnId) prompt.dataset.revises = data.revises.turn_id;
        }
      }
      // after_turn hooks are running and may present the answer: its
      // answer_display (display: null when they didn't) comes next. A worker
      // that dies before it never sends one: workerGone releases the wait, and
      // displayWait's timeout ends it whatever happens (4.14).
      const display = data.display_pending ? displayWait() : null;
      if (display) liveTurn.displayPending = display;
      liveTurn.endRead = readTurnEnd();
      await liveTurn.endRead;
      // The stage's answer is settled now that the rendered markdown is in
      // it (or the re-read failed), and the display if one was coming, so
      // the hand-off never moves it before its links swap in.
      if (display) await display.promise;
      turnDom.answerReady();
      // A participant's review turn: Apply under its reply, as a reload shows it.
      const review = liveTurn.review;
      liveTurn.review = null;
      if (review && !data.turn_summary?.empty_answer) deps.placeApply?.(review);
    },
    // An after_turn hook presented the answer (AnswerDisplay) or attached
    // refs to it (AnswerRefs: refs, a count; display null when only refs):
    // it comes after turn_completed, so re-read the answer once that read
    // is done: the session's open then, so a switch meanwhile leaves the
    // other session's answers alone.
    answer_display: async (data) => {
      const id = selected();
      const still = stillOn(selected, id);
      try {
        await liveTurn.endRead;
        if (!id || !still() || (!data.display && !data.refs)) return;
        const d = await getSession(id, { tail: true, recent: true });
        if (!still()) return;
        if (Array.isArray(d.messages)) applyFinalMarkdown(d.messages);
      } catch (_) {
      } finally {
        liveTurn.releaseDisplay();
      }
    },
    turn_canceled: (data) => {
      activityEnded();
      endTurnView("canceled", cancelLineText(data.cancellation_reason || "", data.cancelled_by), { stopped: true });
      setLiveStatus("idle");
      refreshTimingFromSession();
    },
    // The turn raised (e.g. the model server stayed unreachable). The worker
    // stays up: it rolls the turn back and hands the prompt back
    // (prompt_restored), and the prompts queued behind it run as usual. A turn
    // that got to tool steps stays as it is (kept_steps; no prompt_restored).
    turn_failed: (data) => {
      activityEnded();
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
      const id = selected();
      keepEarlyRestore(data, earlyRestores, { myId: clientId, sentIds });
      const { refill, label, images: restoredImages, verify, revises } = restoreAction(data, { myId: clientId, sentIds, composerEmpty: composer.empty() });
      if (refill) composer.refill(refill);
      if (refill && verify) deps.restoreVerify?.(verify);
      // A Revise turn's draft too: its chip comes back with the text.
      if (refill && revises) deps.restoreRevise?.(revises);
      if (restoredImages?.length) composer.setChips(restoredChips(selected(), restoredImages));
      const failedText = liveTurn.failedText;
      liveTurn.failedText = null;
      await resync();
      // Another session was opened during the re-read: its history isn't
      // this one's (the re-read drew nothing either).
      if (selected() !== id) return;
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
      const id = selected();
      // A queued /working-set line is no longer pending (the list's pill).
      workingSet?.commandRan(data);
      const view = commandView(data, clientId);
      // What the command changed, in one patch: the bar and the chips'
      // popovers redraw once (the store; the working set's list follows
      // /llm-context: workingSetStrategy).
      const patch = {};
      if (view.modelName && view.modelName !== store.current.model) Object.assign(patch, { model: view.modelName, served: null });
      // /llm-context changed what the next turn runs under.
      if (data.llm_context) patch.llmContext = data.llm_context;
      // /thinking (or /model) changed the level the next turn runs at.
      if (data.thinking) patch.thinking = data.thinking;
      // /reasoning-history (or /model) changed it; null: the model now runs
      // on a native host, which ignores it (the chip goes).
      if ("reasoning_history" in data) patch.reasoningHistory = data.reasoning_history || null;
      // /toolkit changed what the next turn declares; null: full (no chip).
      if ("toolkit" in data) patch.toolkit = data.toolkit || null;
      store.update({ current: patch });
      // A fresh link's picker shows the model the worker kept, a refused
      // /model too (its pick set the button before the answer): an event (D9).
      if (view.modelName) syncModelPick?.();
      if (view.resync) {
        await resync();
        // Another session was opened during the re-read: the bubble isn't its.
        if (selected() !== id) return;
      }
      // A card's action that isn't anytime (the step-limit question's
      // /continue) has no bubble: nothing to remove. An anytime or queued
      // one's bubble was drawn at its command_queued: filled in here. One
      // queued for after the turn ran after it: its bubble moves from among
      // the turn's rows to after its answer and timing line.
      const queued = view.anytime || view.queued ? commandBubble(view.commandId) : null;
      if (view.hidden) queued?.remove();
      else if (queued && view.queued && !view.anytime) {
        queued.remove();
        addCommandBubble(view);
      } else if (queued) drawCommandBubble(queued, view);
      // A command that changed the conversation (!cmd): the redrawn history
      // ends with its command bubble already (the saved "!(…)\n<output>"
      // message renders as one) — no second bubble, or the output shows twice.
      else if (view.resync && historyHasCommandBubble(findInTurnRoots(".bubble.command"), view.line)) { /* drawn by the resync */ }
      else addCommandBubble(view);
      // This tab's command refused as busy (a plugin's command mid-turn): the
      // composer was cleared when it went; its line comes back to send later.
      if (view.own && view.busy && composer.empty()) composer.refill(view.line);
    },
    // An anytime command (/help, a plugin's /btw) runs at once, beside a
    // turn: its bubble goes here, so the cards it shows come after it. One
    // queued for after the turn (/model X mid-turn) shows waiting here.
    command_queued: (data) => {
      // A /working-set line queued for after the turn: pending in the list.
      workingSet?.commandQueued(data);
      // A card's action waits for its command_ran: shown only if it answers.
      if ((data.anytime || data.waits) && !data.card && !commandBubble(data.command_id)) addCommandBubble(commandView(data, clientId));
    },
    // Due reminders went into the turn (a reminder turn has no prompt bubble).
    reminder_injected: (data) => {
      gapBefore(data.at);
      addCommandBubble({ label: null, line: reminderText(data), text: "", at: data.at });
    },
    // A context note joined the conversation (between turns; no turn runs).
    // A note is activity of its own: it starts nothing, so it ends there too.
    context_added: (data) => {
      const at = data.at || data.created_at || null;
      gapBefore(at);
      addNoteBubble({ label: data.label, content: data.text || "", at });
      // An attached context source's note: its chip changed.
      if (data.context_source) contextChips.refresh();
    },
    // Someone joined, left or was revoked (the worker's ParticipantsWatch):
    // the owner's chip and panel read the list again.
    participants_changed: () => participantsControl?.reload(),
    // A Verify fresh child's verdict, taken onto its card by the worker.
    verdict_recorded: (data) => deps.placeVerdict?.(data.verdict),
    continue_offered: (data) => questionCards.renderContinue(data),
    continue_resolved: (data) => questionCards.resolveContinue(data),
    tool_call_started: (data) => turnDom.toolStarted(data),
    tool_call_completed: (data) => turnDom.toolCompleted(data),
    // The engine's list, after every memory read and at a turn's end.
    used_memories_updated: (data) => {
      if (Array.isArray(data.used_memory_names)) setUsedMemories(data.used_memory_names);
    },
    // The server's working set (WorkingSet), at a request and at turn end;
    // ignored with web.working_set off.
    working_set_updated: (data) => { workingSet?.update({ items: data.items, at: data.at, ...(data.adds ? { adds: data.adds } : {}) }); },
    context_status: (data) => {
      const current = store.current;
      const patch = {};
      // After /model (Engine#announce_switched_context!): the new model's
      // window, and usage null when it didn't resolve (the % clears, "ctx ?").
      // Only that event carries the key: a null drops the old model's window,
      // so the chunks before the next window count no % against it.
      if (data && "context_window_tokens" in data) {
        patch.ctxWindow = data.context_window_tokens || null;
        patch.ctxWindowSource = data.context_window_tokens ? data.context_window_source || null : null;
        // The ctx tooltip's "until the next request" (ctxBarTip).
        patch.ctxUnknownAfterSwitch = !data.context_window_tokens;
      }
      if (data && "usage" in data && data.usage === null) {
        store.update({ current: { ...patch, ctxPct: null } });
        return;
      }
      const ctxWindow = "ctxWindow" in patch ? patch.ctxWindow : current.ctxWindow;
      const pct = extractCtxPct(data, ctxWindow, current.llmContext?.budget_tokens);
      if (pct !== null) patch.ctxPct = pct;
      store.update({ current: patch });
    },
    question_requested: (data) => {
      const pq = data.pending_question;
      if (!pq || !pq.id) return;
      // A plugin's refs on the reply that asks: on its step before the card
      // draws the asking slot.
      if (pq.refs) turnDom.questionRefs(pq.refs);
      questionCards.renderQuestion(pq);
    },
    question_answered: (data) => {
      questionCards.resolveQuestion(data.id, { answer: data.answer });
    },
    // A delegate's question relayed to its parent's card, or no longer.
    question_relay: (data) => questionCards.markRelayed(data.id, data.relayed_to),
    question_cancelled: (data) => {
      questionCards.resolveQuestion(data.id, { cancelled: true, reason: data.reason });
    },
    // A side request (the recap, /btw, a plugin's ctx.ask_model) counted:
    // the server's whole side block, for the ctx tooltip's line at once.
    side_usage: (data) => {
      if (!data?.side || typeof data.side !== "object") return;
      store.update({ current: { timing: { ...store.current.timing, side: data.side } } });
    },
    // One collected just as a turn started describes the chat before it.
    recap_ready: (data) => {
      // After the turn it covers, never above it.
      turnDom.handOff({ immediate: true });
      if (!liveTurn.running) showRecap(data.recap, 0, data.created_at || null);
    },
    guardrail_warning: (data) => showGuardrailWarning(data.message, data.label || "guardrails"),
    // A notice during a turn is a row of its current step. One the page
    // shows elsewhere (a hook's links in the rendered answer) isn't drawn,
    // not even in the stage trail; a joined turn's notices come here too.
    hook_notice: (data) => {
      // A plugin put the session on another toolkit (ctx.use_toolkit).
      if ("toolkit" in data) {
        store.update({ current: { toolkit: data.toolkit || null } });
      }
      if (shownElsewhere(data, capabilities())) return;
      if (!turnDom.notice(data)) showHookNotice(data);
    },
    // The loop asks again after an empty answer: a row of the empty step
    // (a reload puts it back from the snapshot's cards).
    empty_answer_retry: (data) => { turnDom.notice({ line: emptyRetryLine(data) }); },
    steer_cut: (data) => { turnDom.notice({ line: steerCutLine(data), cls: "steer-cut" }); },
    // A batch of LLM context edits the server applied: a ✂ row of the
    // current step, its hover listing the outputs.
    llm_context_edited: (data) => { turnDom.notice(llmContextNotice(data)); },
    // The provider is asked again after an error, or the turn waits for
    // plugins' setup: a note on the live timing line until it streams.
    generation_retrying: (data) => {
      // A dropped stream's step asked again: what it streamed is void.
      if (data?.restarted) turnDom.generationRestarted(data);
      liveTurn.timing.setNote(retryStatusLine(data));
    },
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
}
