// The open session's stream event handlers (GET /stream's typed events, by
// type); renderSessionView replays a snapshot through them too. Split out
// of app.js; no markup of its own: the page passes its views and hooks.
//
// Everything that changes while the page runs is read through deps at the
// event, never captured at creation: the open session (selected()), its
// fields (state(): resetSessionState replaces the object), the page's
// capabilities, the composer's text. A session switch mid-stream is handled
// as before: the handlers act on whatever is open when the event comes.
//
// deps:
//   selected()            the open session's id, or null
//   state()               the open session's fields (session_state.js)
//   clientId              this tab's id (own prompts and commands)
//   capabilities()        the page's capabilities (card.js shownElsewhere)
//   historyEl             the history element (keepFollowing, the failed-turn redraw)
//   liveTurn, turnDom, shownTexts, questionCards, contextChips,
//   llmContextControl, thinkingControl,
//   reasoningHistoryControl                 the page's views
//   sentIds, earlyRestores                  restore.js's bookkeeping
//   stream: {takeGuess(), restart()}        the stream was opened from a
//                         guess (takeGuess: whether, and forget it); restart:
//                         close the stream and resync
//   composer: {empty(), refill(text), setChips(chips)}
//   getSession(id, opts)  data.js
//   resync(), updateInfoBar(), applyPromptOps(data), showSteers(steers),
//   markRecapStale(), setTurnRunning(running), setLiveStatus(status),
//   endTurnView(kind, endText, opts), appendChunk(text), readTurnEnd(),
//   applyFinalMarkdown(messages), refreshTimingFromSession(),
//   makeUserBubble(prompt, opts), addEndBubble(text), commandBubble(id),
//   addCommandBubble(view), addNoteBubble(note), findInTurnRoots(selector),
//   setUsedMemories(names), showRecap(text), showGuardrailWarning(text, label),
//   showHookNotice(data), onInitEvent(type, data), upsertCard(card),
//   refreshCardBodies(), syncModelPick()   the page's hooks

import { routeChunk } from "./chunk_router.js";
import { extractCtxPct, generationTokens } from "./ctx.js";
import { failedTurnText } from "./format.js";
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

export function createStreamHandlers(deps) {
  const {
    selected, state, clientId, capabilities, historyEl,
    liveTurn, turnDom, shownTexts, questionCards, contextChips, llmContextControl, thinkingControl, reasoningHistoryControl,
    sentIds, earlyRestores, stream, composer, getSession,
    resync, updateInfoBar, applyPromptOps, showSteers, markRecapStale, setTurnRunning, setLiveStatus, endTurnView,
    appendChunk, readTurnEnd, applyFinalMarkdown, refreshTimingFromSession, makeUserBubble, addEndBubble,
    commandBubble, addCommandBubble, addNoteBubble, findInTurnRoots, setUsedMemories, showRecap,
    showGuardrailWarning, showHookNotice, onInitEvent, upsertCard, refreshCardBodies, syncModelPick,
  } = deps;

  return {
    generation_chunk: (data) => {
      // Route the chunk's bytes to the text bubble and the thinking block (see
      // chunk_router.js). Raw `content` is only a fallback for an older server.
      const { text, thinking } = routeChunk(data);
      liveTurn.timing.setNote("");
      turnDom.chunk({ text, thinking, iteration: data.iteration ?? null, now: data.replayed ? null : Date.now() });
      const current = state();
      const pct = extractCtxPct(data, current.ctxWindow, current.llmContext?.budget_tokens);
      if (pct !== null && !Number.isNaN(pct)) {
        current.ctxPct = pct;
        updateInfoBar();
      }
    },
    generation_started: (data) => {
      if (data?.context_window_tokens) {
        const current = state();
        current.ctxWindow = data.context_window_tokens;
        current.ctxWindowSource = data.context_window_source || null;
      }
      liveTurn.timing.setNote("");
      // The step's clock (the composer's delivery line): the page's own at a
      // live start; a replay's comes from the snapshot's generation age,
      // which a live start makes stale.
      if (!data?.replayed) liveTurn.serverGen = null;
      turnDom.generationStarted(data || {}, data?.replayed ? null : Date.now());
    },
    generation_completed: (data) => {
      liveTurn.timing.setNote("");
      const current = state();
      if (data?.served_model) current.served = [data.served_model, data.requested_model, data.served_expected_by || null];
      // The generation's speed and the session's token totals, from the server.
      current.timing.tokens = generationTokens(current.timing.tokens, data);
      // The rows per model, the server's whole list (the open one with this
      // generation in); an event without them (a replay, an older worker)
      // keeps the page's.
      if (Array.isArray(data?.model_segments)) current.timing.modelSegments = data.model_segments;
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
      if (stream.takeGuess()) {
        // A replay of a turn the render drew: re-read and stream from there.
        if (replaysDrawnTurn(data, state().timing.turnRecords)) {
          stream.restart();
          return;
        }
      }
      // A finished turn still in the stage goes first: the start op looks
      // for a queued prompt among its rows.
      turnDom.handOff?.({ immediate: true });
      markRecapStale();
      shownTexts.turnStarted();
      const promptBubble = applyPromptOps(data);
      liveTurn.cutAfter = data.cut_after ?? null;
      liveTurn.serverGen = null;
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
    // An after_turn hook presented the answer (AnswerDisplay) or attached
    // refs to it (AnswerRefs: refs, a count; display null when only refs):
    // it comes after turn_completed, so re-read the answer once that read
    // is done: the session's open then, so a switch meanwhile leaves the
    // other session's answers alone.
    answer_display: async (data) => {
      const id = selected();
      try {
        await liveTurn.endRead;
        if (!id || id !== selected() || (!data.display && !data.refs)) return;
        const d = await getSession(id, { tail: true, recent: true });
        if (id !== selected()) return;
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
      const { refill, label, images: restoredImages } = restoreAction(data, { myId: clientId, sentIds, composerEmpty: composer.empty() });
      if (refill) composer.refill(refill);
      if (restoredImages?.length) composer.setChips(restoredChips(selected(), restoredImages));
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
      if (view.modelName && view.modelName !== state().model) {
        state().model = view.modelName;
        state().served = null;
        updateInfoBar();
      }
      // A fresh link's picker shows the model the worker kept, a refused
      // /model too (its pick set the button before the answer).
      if (view.modelName) syncModelPick?.();
      // /llm-context changed what the next turn runs under.
      if (data.llm_context) {
        state().llmContext = data.llm_context;
        updateInfoBar();
        llmContextControl.refresh();
      }
      // /thinking (or /model) changed the level the next turn runs at.
      if (data.thinking) {
        state().thinking = data.thinking;
        updateInfoBar();
        thinkingControl.refresh();
      }
      // /reasoning-history (or /model) changed it; null: the model now runs
      // on a native host, which ignores it (the chip goes).
      if ("reasoning_history" in data) {
        state().reasoningHistory = data.reasoning_history || null;
        updateInfoBar();
        reasoningHistoryControl.refresh();
      }
      // /toolkit changed what the next turn declares; null: full (no chip).
      if ("toolkit" in data) {
        state().toolkit = data.toolkit || null;
        updateInfoBar();
      }
      if (view.resync) await resync();
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
      // A card's action waits for its command_ran: shown only if it answers.
      if ((data.anytime || data.waits) && !data.card && !commandBubble(data.command_id)) addCommandBubble(commandView(data, clientId));
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
      const current = state();
      // After /model (Engine#announce_switched_context!): the new model's
      // window, and usage null when it didn't resolve (the % clears, "ctx ?").
      // Only that event carries the key: a null drops the old model's window,
      // so the chunks before the next window count no % against it.
      if (data && "context_window_tokens" in data) {
        current.ctxWindow = data.context_window_tokens || null;
        current.ctxWindowSource = data.context_window_tokens ? data.context_window_source || null : null;
      }
      if (data && "usage" in data && data.usage === null) {
        current.ctxPct = null;
        updateInfoBar();
        return;
      }
      const pct = extractCtxPct(data, current.ctxWindow, current.llmContext?.budget_tokens);
      if (pct !== null) {
        current.ctxPct = pct;
        updateInfoBar();
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
      // A plugin put the session on another toolkit (ctx.use_toolkit).
      if ("toolkit" in data) {
        state().toolkit = data.toolkit || null;
        updateInfoBar();
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
