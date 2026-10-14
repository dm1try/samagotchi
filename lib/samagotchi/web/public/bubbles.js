// The history's bubbles, the open session's lines between its turns' rows:
// the placeholder hint, output chunks, end lines, the prompt bubbles (every
// client's, by enqueued_id), the idle recap, guardrail warnings, hooks'
// notices, plugins' steers, command and note bubbles. The markup is lit
// (turn_html.js elementOf); createBubbles puts them in the history.
import { html, nothing } from "./vendor/lit-html.js";
import { normalize, recapLabel, recapPlace } from "./format.js";
import { BADGES, elementOf, noteBubbleTemplate, stateBadgeTemplate, steerRowTemplate, userBubbleTemplate } from "./turn_html.js";
import { thumbsTemplate } from "./images.js";
import { appendAboveLiveTiming, STOPPED_LINE_CLASS } from "./timing.js";
import { keepFollowing } from "./scroll.js";
import { hookNoticeLabel, isReportClient, promptOps } from "./turn_events.js";
import { drawCommandBubble } from "./commands.js";

// A prompt that started a turn: not a line steered into a running one.
export const TURN_PROMPT = ".bubble.user:not(.steered)";

// The history's turn prompts, oldest first (what turns_since counts).
export function turnPromptBubbles(historyEl) {
  return [...historyEl.querySelectorAll(`:scope > ${TURN_PROMPT}`)];
}

// The history's one line while it has nothing else (loading, an error,
// no output yet).
export function hintTemplate(text) {
  return html`<div class="hint">${text}</div>`;
}
export function hintEl(text) {
  return elementOf(hintTemplate(text));
}

// A piece of output text (a chunk, an older session's plain history item).
export function outputBubbleTemplate(text) {
  return html`<div class="bubble output">${String(text)}</div>`;
}

// +stopped+: a stop someone chose (a cancel, the session's stop), drawn in
// the stopped style (timing.js STOPPED_LINE_CLASS); else a failure's line.
export function endBubbleTemplate(text, { stopped = false } = {}) {
  return html`<div class=${stopped ? STOPPED_LINE_CLASS : "bubble cancel"}>${text}</div>`;
}

// The idle recap, open; a stale one (+turnsSince+ > 0) says it is earlier.
export function recapTemplate(text, turnsSince = 0) {
  return html`<details class=${turnsSince > 0 ? "bubble recap stale" : "bubble recap"} open><summary>${recapLabel(turnsSince)}</summary><div class="recap-body">${text}</div></details>`;
}

// A guardrail hook or rule file that failed to load (once per worker), or
// a bundle's plugin (+label+ "plugins").
export function guardrailWarningTemplate(text, label = "guardrails") {
  return html`<div class="bubble guardrail-warning">${`${label}: ${text}`}</div>`;
}

// A hook's line to the user (event[:notify]), in the warning colour for
// level warn; +cls+ adds a kind's class (llm_context_edited's). +bubble+:
// one of the history's own, else a row of a turn's step.
export function hookNoticeTemplate({ line, level = null, cls = null, title = null }, { bubble = true } = {}) {
  const klass = (bubble ? "bubble hook-notice" : "hook-notice") + (level === "warn" ? " warn" : "") + (cls ? ` ${cls}` : "");
  return html`<div class=${klass} title=${title || nothing}>${line}</div>`;
}

// A hook notice's line: its own (a snapshot's notice), else "<hook>: text".
export function hookNoticeLine(data) {
  return data.line || `${hookNoticeLabel(data.hook)}: ${data.text || ""}`;
}

// A prompt bubble's state badge (queued, steered, failed) and class; none
// for any other state (a started turn's prompt).
export function setBubbleState(bubble, state) {
  bubble.classList.remove("queued", "steered", "failed");
  bubble.querySelector(".state-badge")?.remove();
  if (!BADGES[state]) {
    delete bubble.dataset.userState;
    return;
  }
  bubble.classList.add(state);
  bubble.dataset.userState = state;
  bubble.append(elementOf(stateBadgeTemplate(state, bubble.dataset.delivery || null)));
}

// A bubble's delivery changed (the ack's cut: off goes in at the next
// step; a queue to a turn that ended meanwhile is just the next turn): its
// badge follows.
export function setBubbleDelivery(bubble, delivery) {
  if ((bubble.dataset.delivery || null) === (delivery || null)) return;
  if (delivery) bubble.dataset.delivery = delivery;
  else delete bubble.dataset.delivery;
  if (bubble.dataset.userState) setBubbleState(bubble, bubble.dataset.userState);
}

// @param historyEl the history
// @param appendToHistory (el) puts +el+ at the history's end (or the stage's,
//   while it holds a turn), above the live timing line
// @param isNearBottom () => whether the history follows its end
// @param turnDom the running turn's view (stage_view.js / turn_view.js)
// @param findInTurnRoots (selector) => the matching elements in the history
//   and the stage
// @param shownTexts the running turn's texts on the page (shown_texts.js)
// @param liveTurn the running turn as the page follows it (live_turn.js)
// @param selected () => the open session's id
// @param clientId this tab's id in the session's events
export function createBubbles({
  historyEl, appendToHistory, isNearBottom, turnDom, findInTurnRoots, shownTexts, liveTurn, selected, clientId,
}) {
  // Placed with the sticky follow: the decision taken before the history
  // grows. +before+: the element it goes above (a snapshot's), else the end.
  function placeFollowing(el, before = null) {
    const follow = isNearBottom();
    if (before) historyEl.insertBefore(el, before);
    else appendToHistory(el);
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
    return el;
  }

  function removeHint() {
    const hint = historyEl.querySelector(".hint");
    if (hint) hint.remove();
  }

  function removeHintIfEmpty() {
    const hint = historyEl.querySelector(".hint");
    if (!hint) return;
    // Remove the placeholder when the card will be the first content in history.
    if (!historyEl.querySelector(".bubble")) hint.remove();
  }

  function appendChunk(text) {
    if (!text) return;
    const k = normalize(text);
    if (!k || shownTexts.shows(k)) return;
    const follow = isNearBottom();
    removeHint();
    appendToHistory(elementOf(outputBubbleTemplate(text)));
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
  }

  function addEndBubble(text, { stopped = false } = {}) {
    appendToHistory(elementOf(endBubbleTemplate(text, { stopped })));
    if (!turnDom.holds?.()) historyEl.scrollTop = historyEl.scrollHeight;
  }

  // ── Prompt bubbles ───────────────────────────────────────────────────────
  // Every client's prompts, keyed by enqueued_id: queued (badge) until their
  // turn starts, or steered when merged into a running turn. This tab's own
  // prompts are echoed at send (data-own) and tagged by their turn_enqueued.

  // The bubble a reload draws (turn_html.js), with this page's own fields.
  // +delivery+: how it went into a running turn (next_step, cut, queue): its
  // queued badge says what it waits for.
  function makeUserBubble(prompt, { state = null, label = null, enqueuedId = null, own = false, images = null, delivery = null } = {}) {
    removeHint();
    const div = elementOf(userBubbleTemplate({ content: prompt }, {
      label, state, own, enqueuedId, delivery, key: normalize(prompt), thumbs: thumbsTemplate(selected(), images),
    }));
    return placeFollowing(div);
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
        const bubble = makeUserBubble(op.prompt, { state: op.state, label: op.label, enqueuedId: op.enqueuedId, images: op.images, delivery: op.delivery });
        if (op.state === "started") started = bubble;
        if (event.type === "pending_input_merged") liveTurn.wakeStart = false;
      } else if (op.op === "tag") {
        if (bubbleById(op.enqueuedId)) continue;
        const echo = untaggedOwnBubble(op.prompt);
        if (echo) {
          echo.dataset.enqueuedId = op.enqueuedId;
          if (op.delivery) setBubbleDelivery(echo, op.delivery);
        }
        // Re-rendered from a snapshot: the echo is gone, the prompt still queued.
        else makeUserBubble(op.prompt, { state: "queued", own: true, enqueuedId: op.enqueuedId, images: op.images, delivery: op.delivery });
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

  // ── Idle recap ───────────────────────────────────────────────────────────
  // A summary the worker writes after a quiet stretch or as it leaves: shown at
  // the end of the history. A turn starting leaves it in place, marked
  // earlier; only a new recap replaces it.

  function showRecap(text, turnsSince = 0) {
    if (!text) return;
    removeRecap();
    const details = elementOf(recapTemplate(text, turnsSince));
    // A stale one sits where it was written, above the turns it doesn't cover.
    // Never in the stage: a recap is between turns.
    turnDom.settleFold?.();
    const before = recapPlace(turnPromptBubbles(historyEl), turnsSince);
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

  function removeRecap() {
    historyEl.querySelectorAll(".bubble.recap").forEach((el) => el.remove());
  }

  // +before+: the element it goes above (a snapshot's), else the end.
  function showGuardrailWarning(text, label = "guardrails", { before = null } = {}) {
    if (!text) return;
    placeFollowing(elementOf(guardrailWarningTemplate(text, label)), before);
  }

  // A plugin's steers (pending_input_merged's steers): a row of the running
  // turn's step, else (no turn runs) a bubble.
  function showSteers(steers) {
    for (const steer of steers || []) {
      if (turnDom.steer(steer)) continue;
      removeHintIfEmpty();
      placeFollowing(elementOf(steerRowTemplate(steer, { bubble: true })));
    }
  }

  // "<bundle>: text", or the notice's own line.
  // +before+: the element it goes above (a snapshot's notice), else the end.
  function showHookNotice(data, { before = null } = {}) {
    removeHintIfEmpty();
    placeFollowing(elementOf(hookNoticeTemplate({ ...data, line: hookNoticeLine(data) })), before);
  }

  function addCommandBubble(view) {
    removeHintIfEmpty();
    const div = document.createElement("div");
    // Page-only: kept across a resync of this session (keptCommandBubbles).
    const id = selected();
    if (id) div.dataset.keptFor = id;
    drawCommandBubble(div, view);
    placeFollowing(div);
  }

  function commandBubble(commandId) {
    if (!commandId) return null;
    return findInTurnRoots(".bubble.command").find((el) => el.dataset.commandId === String(commandId)) || null;
  }

  function addNoteBubble(note) {
    removeHintIfEmpty();
    placeFollowing(elementOf(noteBubbleTemplate(note)));
  }

  return {
    removeHintIfEmpty, appendChunk, addEndBubble, makeUserBubble, bubbleById, applyPromptOps, showRecap,
    markRecapStale, showGuardrailWarning, showSteers, showHookNotice, addCommandBubble, commandBubble, addNoteBubble,
  };
}
