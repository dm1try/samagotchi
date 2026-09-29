// The chat view of a running turn: one streaming answer bubble per
// generation, one thinking block per turn (above the first bubble) and one
// activity panel per turn (at the first tool call). This module owns that
// per-turn DOM; app.js's stream handlers call it and keep the rest (prompt
// bubbles, cards, the timing line, the session state). turn_view.js offers
// the same interface with a different placement; app.js picks one at boot.
//
// deps: historyEl, appendToHistory(el) (above the live timing line),
// isNearBottom(), sawText(normalizedText) (the turn output dedupe),
// sessionId() (image thumbs of a tool row).
import { newActivity, addStarted, addCompleted, finalizeActivity, activityCount, toolName } from "./activity.js";
import { copySourceAttr } from "./copy.js";
import { escapeHtml, leadTrimmed, messageBodyHtml, noteHtml, normalize, steerRowHtml } from "./format.js";
import { thumbsHtml } from "./images.js";
import { shouldFollowScroll } from "./scroll.js";
import { tallyText } from "./tally.js";
import { cancelLineHtml, formatDuration, timedTurnIndexes, turnRecordAt, turnTimingText } from "./timing.js";

// A row's status (live, or a saved tool record's on reload): running,
// error, stopped (a task_wait the user's Stop ended), else ok ("done").
export function activityStatusClass(status) {
  if (status === "running") return "running";
  if (status === "error") return "error";
  if (status === "stopped") return "stopped";
  return "ok";
}

export function activityStatusLabel(status) {
  if (status === "running") return "running";
  if (status === "error") return "error";
  if (status === "stopped") return "stopped";
  return "done";
}

export function createChatView({ historyEl, appendToHistory, isNearBottom, sawText, sessionId }) {
  let streamingBubble = null;
  let streamingBuffer = "";
  let rafPending = false;
  let activityModel = null;
  let activityEl = null;
  let activityElBody = null;
  const activityRowEls = new Map();
  // One live "thinking" block per turn (Claude-like); streams :generation_chunk
  // `thinking` deltas and auto-collapses on turn_completed.
  let thinkingEl = null;
  let thinkingBodyEl = null;
  let thinkingBuffer = "";

  function removeHint() {
    const hint = historyEl.querySelector(".hint");
    if (hint) hint.remove();
  }

  function ensureStreamingBubble() {
    if (streamingBubble) return streamingBubble;
    removeHint();
    streamingBubble = document.createElement("div");
    streamingBubble.className = "bubble output streaming";
    streamingBubble.textContent = "";
    appendToHistory(streamingBubble);
    return streamingBubble;
  }

  function flush() {
    rafPending = false;
    // Runs every animation frame while streaming — must not yank a user who
    // scrolled up to read; only follow when they were already near the bottom.
    const follow = isNearBottom();
    // An empty buffer keeps the "…" placeholder.
    if (streamingBubble && streamingBuffer) {
      streamingBubble.textContent = streamingBuffer;
    }
    if (thinkingBodyEl) {
      // The capped thinking box follows its own tail the same way, unless the
      // user scrolled up inside it.
      const followThinking = shouldFollowScroll(thinkingBodyEl, 24);
      thinkingBodyEl.textContent = thinkingBuffer;
      if (followThinking) thinkingBodyEl.scrollTop = thinkingBodyEl.scrollHeight;
    }
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
  }

  function scheduleFlush() {
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(flush);
  }

  function appendToken(content) {
    if (!content) return;
    // Leading whitespace right after a closed think/tool_call block (or at the
    // start of the stream) would otherwise render as an empty first line in
    // the pre-wrap bubble. Trim it only at the start of a bubble so mid-bubble
    // paragraph spacing is preserved.
    if (streamingBuffer === "") content = content.replace(/^[ \t\r\n]+/, "");
    if (!content) return;
    streamingBuffer += content;
    ensureStreamingBubble();
    scheduleFlush();
  }

  // ── Per-turn live thinking block ─────────────────────────────────────────
  // Routed from :generation_chunk `thinking`. One <details> per turn; accumulates
  // across the turn's generations and collapses on turn completion.

  function ensureThinkingEl() {
    if (thinkingEl) return thinkingEl;
    removeHint();
    const details = document.createElement("details");
    details.className = "bubble thinking";
    details.open = true;
    const summary = document.createElement("summary");
    summary.textContent = "thinking";
    details.appendChild(summary);
    const body = document.createElement("div");
    body.className = "thinking-body";
    details.appendChild(body);
    thinkingEl = details;
    thinkingBodyEl = body;
    // Prefer Claude-like ordering: thinking above the streaming answer bubble.
    if (streamingBubble && streamingBubble.parentNode === historyEl) {
      historyEl.insertBefore(details, streamingBubble);
    } else {
      appendToHistory(details);
    }
    return details;
  }

  function appendThinking(content) {
    // The box starts at the first visible character, not the "\n" after <think>.
    const piece = leadTrimmed(thinkingBuffer, content);
    if (!piece) return;
    thinkingBuffer += piece;
    ensureThinkingEl();
    scheduleFlush();
  }

  function finalizeThinkingEl() {
    if (thinkingBodyEl) thinkingBodyEl.textContent = thinkingBuffer.replace(/[ \t\r\n]+$/, "");
    if (thinkingEl) thinkingEl.open = false;
    thinkingBuffer = "";
  }

  function resetThinkingState() {
    thinkingEl = null;
    thinkingBodyEl = null;
    thinkingBuffer = "";
  }

  function finalizeStreaming() {
    if (streamingBubble) {
      const k = normalize(streamingBuffer);
      // The text lands in the bubble on the next animation frame; a generation
      // can end before one runs (a burst of frames, a hidden tab), so write it
      // here too or the bubble keeps its "…" placeholder.
      if (k) {
        streamingBubble.textContent = streamingBuffer;
        sawText(k);
      }
      else streamingBubble.remove(); // drop text-less bubbles (thinking/tool-only generations, "…" placeholder)
      streamingBubble.classList.remove("streaming");
      streamingBubble = null;
    }
    streamingBuffer = "";
    rafPending = false;
  }

  // ── Per-turn tool/memory activity panel ──────────────────────────────────
  // One collapsible <details> per turn; each :tool_call_started/completed upserts
  // a row (keyed by iteration:call_index) that transitions running -> ok/error.
  // Memory reads/writes flow through the same tool_call events, so they show here too.

  function ensureActivityEl() {
    if (activityEl) return activityEl;
    removeHint();
    const details = document.createElement("details");
    details.className = "bubble activity";
    details.open = true;
    const summary = document.createElement("summary");
    summary.textContent = "activity";
    details.appendChild(summary);
    const body = document.createElement("div");
    body.className = "activity-body";
    details.appendChild(body);
    activityEl = details;
    activityElBody = body;
    appendToHistory(details);
    return details;
  }

  function renderActivityRow(row) {
    const el = document.createElement("div");
    el.className = "activity-row";
    el.dataset.key = row.key;
    const statusEl = document.createElement("span");
    statusEl.className = "activity-status";
    const toolEl = document.createElement("span");
    toolEl.className = "activity-tool";
    toolEl.textContent = toolName(row);
    const paramsEl = document.createElement("span");
    paramsEl.className = "activity-params";
    const outEl = document.createElement("div");
    outEl.className = "activity-output";
    outEl.style.display = "none";
    el.appendChild(statusEl);
    el.appendChild(toolEl);
    el.appendChild(paramsEl);
    el.appendChild(outEl);
    activityRowEls.set(row.key, el);
    const follow = isNearBottom();
    (activityElBody || ensureActivityEl().querySelector(".activity-body")).appendChild(el);
    updateActivityRowEl(row);
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
  }

  function updateActivityRowEl(row) {
    const el = activityRowEls.get(row.key);
    if (!el) return;
    fillActivityRow(el, row, sessionId());
  }

  function updateActivitySummary() {
    if (!activityEl) return;
    const summary = activityEl.querySelector("summary");
    if (!summary) return;
    // From the 3rd call: "activity · 12 tool calls (2 failed) · execute ×7 · …" (the rows show the last call).
    const tally = tallyText(activityModel?.rows, { last: false });
    summary.textContent = tally ? `activity · ${tally}` : `activity (${activityCount(activityModel)})`;
  }

  function finalizeActivityEl() {
    if (activityModel) finalizeActivity(activityModel);
    if (activityEl) activityEl.open = false;
  }

  function resetActivityState() {
    activityModel = null;
    activityEl = null;
    activityElBody = null;
    activityRowEls.clear();
  }

  function toolEvent(data, add) {
    const model = activityModel || (activityModel = newActivity());
    ensureActivityEl();
    const row = add(model, data);
    if (!activityRowEls.has(row.key)) renderActivityRow(row);
    else updateActivityRowEl(row);
    updateActivitySummary();
  }

  return {
    turnStarted(data) {
      resetActivityState();
      resetThinkingState();
      streamingBuffer = "";
      ensureStreamingBubble();
      if (data.prompt) streamingBubble.textContent = "…";
    },
    generationStarted() {
      // A generation left open (a join mid-way) ends where the next begins.
      finalizeStreaming();
      ensureStreamingBubble();
    },
    chunk({ text, thinking }) {
      if (text) appendToken(text);
      if (thinking) appendThinking(thinking);
    },
    generationCompleted() {
      finalizeStreaming();
    },
    toolStarted(data) {
      toolEvent(data, (model, event) => addStarted(model, event).row);
    },
    toolCompleted(data) {
      toolEvent(data, addCompleted);
    },
    // Everything a turn's end (completed, canceled, failed) closes.
    turnEnded() {
      finalizeStreaming();
      finalizeActivityEl();
      finalizeThinkingEl();
    },
    // A hook's notice stays the page's bubble in this view.
    notice() {
      return false;
    },
    // So is a plugin's steer.
    steer() {
      return false;
    },
    // So is a card.
    card() {
      return false;
    },
    flush,
    // The element is rewritten every frame while the turn runs (annotate
    // skips it).
    containsLive(el) {
      return !!thinkingEl?.contains(el);
    },
    reset() {
      streamingBubble = null;
      streamingBuffer = "";
      rafPending = false;
      resetActivityState();
      resetThinkingState();
    },
  };
}

// One tool row's status, name, params, output and image thumbs from its
// activity row (activity.js). Shared with the turn view.
// A reloaded history in the chat view (renderHistory's object path): one
// bubble per message; each turn's timing line under its last bubble, then
// its cancel line, where the live view leaves them.
// +thumbs(images)+ draws a prompt's image thumbs.
export function chatHistoryHtml(items, timing, { thumbs }) {
  const timedTurns = timedTurnIndexes(items);
  return items
    .map((m, i) => {
      if (m.role === "note") return `<div class="bubble note">${noteHtml(m)}</div>`;
      if (m.role === "steer") return steerRowHtml({ source: m.source, text: m.content }, { bubble: true });
      const turnIndex = timedTurns[i];
      const cls = m.role === "user" ? "user" : "output";
      const { body, renderedMarkdown } = messageBodyHtml(m);
      const markdown = renderedMarkdown ? " markdown" : "";
      const record = turnIndex === null ? null : turnRecordAt(timing, turnIndex);
      const timingHtml = record && formatDuration(record.duration_ms)
        ? `<div class="turn-timing">${escapeHtml(turnTimingText(turnIndex + 1, record.duration_ms, { canceled: record.status === "canceled" }))}</div>`
        : "";
      // A canceled turn ends with its cancel line, as the live view left it.
      const cancelHtml = record ? cancelLineHtml(record, escapeHtml) : "";
      // A user bubble is a flex row (label, text, badge): its text sits in
      // one block so quotes stack instead of lining up side by side.
      const inner = m.role === "user" ? `<div class="user-message">${body}${thumbs(m.images)}</div>` : body;
      // The timing line goes after the bubble, not in it: under the answer,
      // or under the prompt of a turn canceled before any answer.
      return `<div class="bubble ${cls}${markdown}"${copySourceAttr(m, renderedMarkdown)}>${inner}</div>${timingHtml}${cancelHtml}`;
    })
    .join("");
}

export function fillActivityRow(el, row, sessionId) {
  const statusEl = el.querySelector(".activity-status");
  statusEl.className = `activity-status ${activityStatusClass(row.status)}`;
  statusEl.textContent = activityStatusLabel(row.status);
  const toolEl = el.querySelector(".activity-tool");
  if (toolEl) toolEl.textContent = toolName(row);
  const paramsEl = el.querySelector(".activity-params");
  if (paramsEl) paramsEl.textContent = row.params || "";
  const outEl = el.querySelector(".activity-output");
  if (outEl) {
    if (row.status === "running") {
      outEl.style.display = "none";
      outEl.textContent = "";
      outEl.title = "";
    } else {
      // dispatch prefixes output with "[tool]"; strip that noise for display.
      const full = (row.output || "").replace(/^\[[^\]]*\]\s*/, "");
      outEl.title = full;
      outEl.textContent = full.length > 300 ? `${full.slice(0, 300)}…` : full;
      outEl.style.display = full ? "" : "none";
    }
  }
  // The images a tool returned (the chat view's reloaded history has no tool
  // rows; the turn view's has, turn_view.js reloadRowHtml).
  if (row.images?.length && !el.querySelector(".thumbs")) el.insertAdjacentHTML("beforeend", thumbsHtml(sessionId, row.images));
}
