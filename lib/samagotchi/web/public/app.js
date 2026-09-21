import {
  listSessions,
  createSession,
  getSession,
  sendTurn,
  cancelTurn,
  stopSession,
  sendAnswer,
  openStream,
} from "./data.js";
import { escapeHtml, messageBodyHtml, normalize, previewForCard, firstMessageOf } from "./format.js";
import { newActivity, addStarted, addCompleted, finalizeActivity, activityCount } from "./activity.js";
import { routeChunk } from "./chunk_router.js";
import { shouldFollowScroll } from "./scroll.js";
import { elapsedSince, formatDuration, normalizeTiming, turnRecordAt } from "./timing.js";

const $ = (s) => document.querySelector(s);
const topStripEl = $("#topStrip");
const gridListEl = $("#gridList");
const historyEl = $("#history");
const emptyEl = $("#empty");
const composerEl = $("#composer");
const infoBarEl = $("#infoBar");
const firstPeekEl = $("#firstPeek");
const infoTextEl = $("#infoText");
const markdownWarningEl = $("#markdownWarning");
const promptEl = $("#prompt");
const actionBtn = $("#actionBtn");
const createAltBtn = $("#createAltBtn");
const actionMenuBtn = $("#actionMenuBtn");
const actionMenu = $("#actionMenu");

let selected = null;
let streamControl = null;
let allSessions = [];
let displayLimit = 6;
let streamingBubble = null;
let streamingBuffer = "";
let rafPending = false;
let seenContent = new Set();
let currentFirstPreview = "";
let currentUsedMemories = [];
let currentCtxPct = null;
let currentStatus = "";
let currentModel = "";
let currentDir = "";
let currentTiming = normalizeTiming();
let turnRunning = false;
let liveTurnTimingEl = null;
let timingInterval = null;
let activityModel = null;
let activityEl = null;
let activityElBody = null;
const activityRowEls = new Map();
// One live "thinking" block per turn (Claude-like); streams :generation_chunk
// `thinking` deltas and auto-collapses on turn_completed.
let thinkingEl = null;
let thinkingBodyEl = null;
let thinkingBuffer = "";
// Live ask_user_question card, keyed by pending question id. Re-rendered from
// pending_question on session select so a reload mid-question restores it.
let questionCardEl = null;
let pendingQuestion = null;

const MAX_STREAM_RETRIES = 8;

async function refresh() {
  allSessions = await listSessions("updated_at", "desc");
  render();
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

function cardHtml(s) {
  const ts = s.updated_at || s.created_at || "";
  const tip = `${s.id} · updated ${ts} · ${s.status}`;
  const preview = escapeHtml(previewForCard(s));
  const memTitle = s.used_memory_names && s.used_memory_names.length ? `mem: ${s.used_memory_names.join(", ")}` : "";
  return `<div class="card" data-id="${s.id}" title="${escapeHtml(tip)}${memTitle ? ` · ${escapeHtml(memTitle)}` : ""}"><div class="id">${escapeHtml(s.short_id)} · ${escapeHtml(s.id.slice(0,8))}</div><div class="preview">${preview}</div><div class="meta"><span class="status ${escapeHtml(s.status)}">${escapeHtml(s.status)}</span>${s.used_memory_names && s.used_memory_names.length ? `<span title="${escapeHtml(s.used_memory_names.join(", "))}">mem ${s.used_memory_names.length}</span>` : ""}</div></div>`;
}

function render() {
  const sessions = filteredSessions();
  const topSessions = sessions.slice(0, 3);
  const rest = sessions.slice(3);
  renderTop(topSessions);
  renderGrid(rest);
  updateCount(sessions);
}

function updateCount(sessions) {
  $("#count").textContent = sessions.length
    ? `${Math.min(sessions.length, displayLimit + 3)} / ${sessions.length}`
    : "";
}

function renderTop(sessions) {
  if (!sessions.length) {
    topStripEl.innerHTML = "";
    return;
  }
  topStripEl.innerHTML = sessions.map(cardHtml).join("");
  topStripEl.querySelectorAll(".card").forEach((el) => {
    el.addEventListener("click", () => select(el.dataset.id));
    if (selected && el.dataset.id === selected) el.classList.add("active");
  });
}

function renderGrid(sessions) {
  if (!sessions.length) {
    if (!filteredSessions().length) {
      gridListEl.innerHTML = `<div class="hint">No sessions yet. Create one below.</div>`;
    } else if (filteredSessions().length <= 3) {
      gridListEl.innerHTML = `<div class="hint">No more sessions.</div>`;
    } else {
      gridListEl.innerHTML = "";
    }
    return;
  }
  const slice = sessions.slice(0, displayLimit);
  let html = slice.map(cardHtml).join("");
  if (sessions.length > displayLimit) {
    html += `<div class="hint" style="grid-column:1/-1"><button class="ghost" id="showAll">Show all (${sessions.length})</button></div>`;
  }
  gridListEl.innerHTML = html;
  gridListEl.querySelectorAll(".card").forEach((el) => {
    el.addEventListener("click", () => select(el.dataset.id));
    if (selected && el.dataset.id === selected) el.classList.add("active");
  });
  const btn = $("#showAll");
  if (btn) btn.addEventListener("click", () => { displayLimit = sessions.length; render(); });
}

function updateComposerMode() {
  if (turnRunning && selected) {
    promptEl.placeholder = "Running… press Cancel or wait";
    actionBtn.textContent = "Cancel";
    actionBtn.classList.add("cancel");
    actionBtn.style.background = "#da3633";
    createAltBtn.style.display = "none";
    actionMenuBtn.style.display = "none";
    actionMenu.classList.remove("visible");
    return;
  }
  actionBtn.classList.remove("cancel");
  actionBtn.style.background = "";
  if (!selected) {
    promptEl.placeholder = "New session prompt — press Enter to create (Shift+Enter for newline)";
    actionBtn.textContent = "Create";
    actionBtn.disabled = false;
    createAltBtn.style.display = "none";
    actionMenuBtn.style.display = "none";
    actionMenu.classList.remove("visible");
    emptyEl.classList.remove("hidden");
    historyEl.innerHTML = "";
    updateInfoBar();
  } else {
    promptEl.placeholder = "Send a message… (Enter to send, Shift+Enter for newline)";
    actionBtn.textContent = "Send";
    createAltBtn.style.display = "inline-block";
    createAltBtn.textContent = "Create new";
    actionMenuBtn.style.display = "inline-block";
    emptyEl.classList.add("hidden");
  }
}

function setTurnRunning(running) {
  turnRunning = !!running;
  updateComposerMode();
  updateInfoBar();
}

function clearSelection() {
  selected = null;
  document.querySelectorAll(".card").forEach((el) => el.classList.remove("active"));
  currentFirstPreview = "";
  currentUsedMemories = [];
  currentCtxPct = null;
  currentStatus = "";
  currentModel = "";
  currentDir = "";
  currentTiming = normalizeTiming();
  clearTimingInterval();
  liveTurnTimingEl = null;
  setTurnRunning(false);
  closeStream();
  updateComposerMode();
  updateInfoBar();
  updateFirstPeek();
  promptEl.focus();
}

async function select(id) {
  selected = id;
  document.querySelectorAll(".card").forEach((el) =>
    el.classList.toggle("active", el.dataset.id === id),
  );
  setTurnRunning(false);
  historyEl.innerHTML = `<div class="hint">Loading…</div>`;
  emptyEl.classList.add("hidden");
  closeStream();
  currentFirstPreview = "";
  currentUsedMemories = [];
  currentCtxPct = null;
  currentStatus = "";
  currentModel = "";
  currentDir = "";
  currentTiming = normalizeTiming();
  updateFirstPeek();
  updateInfoBar();
  updateComposerMode();
  try {
    const data = await getSession(id);
    const s = data.session;
    setMarkdownWarning(data.markdown_warning);
    currentStatus = s.status;
    currentModel = s.model_name;
    currentDir = s.working_directory;
    currentTiming = normalizeTiming(data.timing);
    setTurnRunning(currentStatus === "running");
    currentFirstPreview = s.first_preview || previewForCard(s);
    if (data.messages && data.messages.length) {
      const first = data.messages.find(m=>m.role==="user");
      if (first && first.content) currentFirstPreview = normalize(first.content).slice(0,80) + (normalize(first.content).length>80?"…":"");
      currentUsedMemories = s.used_memory_names || [];
      renderHistory(data.messages);
    } else {
      currentUsedMemories = s.used_memory_names || [];
      renderHistory(data.history || []);
      if (!currentFirstPreview && data.history && data.history.length) {
        const txt = normalize(String(data.history[0]||"")).slice(0,80);
        if(txt) currentFirstPreview = txt;
      }
    }
    if (data.session && data.session.used_memory_names) currentUsedMemories = data.session.used_memory_names;
    if (turnRunning && currentTiming.activeTurn?.started_at) {
      startLiveTurnTiming(currentTiming.activeTurn.started_at);
    }
    updateInfoBar();
    updateFirstPeek();
    updateComposerMode();
    seedSeenFromDom();
    // Reload recovery: if a question was pending when the page reloaded, the
    // worker is still blocked on it — re-render the interactive card.
    removeQuestionCard();
    if (data.pending_question && data.pending_question.id && data.pending_question.status === "pending") {
      renderQuestionCard(data.pending_question);
    }
    // Silence stream until first Send: preview is read-only.
    // Worker is woken by POST /turn, so only attach when a live bridge exists.
    if (typeof data.last_event_seq === "number") {
      startStream(id, data.last_event_seq);
    } else {
      closeStream();
    }
    document.querySelectorAll(".card").forEach(el=>el.classList.toggle("active", el.dataset.id===id));
    promptEl.focus();
  } catch (e) {
    historyEl.innerHTML = `<div class="hint">Error: ${escapeHtml(e.message)}</div>`;
  }
}

function renderHistory(items) {
  if (!items.length) {
    historyEl.innerHTML = `<div class="hint">No output yet. Send a message.</div>`;
    return;
  }
  if (typeof items[0] === "object" && items[0].role) {
    let turnIndex = -1;
    historyEl.innerHTML = items
      .map((m) => {
        if (m.role === "user") turnIndex += 1;
        const cls = m.role === "user" ? "user" : "output";
        const { body, renderedMarkdown } = messageBodyHtml(m);
        const markdown = renderedMarkdown ? " markdown" : "";
        const record = m.role === "assistant" ? turnRecordAt(currentTiming, turnIndex) : null;
        const timingHtml = record && formatDuration(record.duration_ms)
          ? `<div class="turn-timing">turn ${turnIndex + 1} · ${escapeHtml(formatDuration(record.duration_ms))}</div>`
          : "";
        return `<div class="bubble ${cls}${markdown}">${body}${timingHtml}</div>`;
      })
      .join("");
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
  historyEl.appendChild(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

function ensureStreamingBubble() {
  if (streamingBubble) return streamingBubble;
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  streamingBubble = document.createElement("div");
  streamingBubble.className = "bubble output streaming";
  streamingBubble.textContent = "";
  historyEl.appendChild(streamingBubble);
  return streamingBubble;
}

function flushStreaming() {
  rafPending = false;
  // Runs every animation frame while streaming — must not yank a user who
  // scrolled up to read; only follow when they were already near the bottom.
  const follow = isNearBottom();
  if (streamingBubble) {
    streamingBubble.textContent = streamingBuffer;
  }
  if (thinkingBodyEl) {
    thinkingBodyEl.textContent = thinkingBuffer;
  }
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
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
  if (!rafPending) {
    rafPending = true;
    requestAnimationFrame(flushStreaming);
  }
}

// ── Per-turn live thinking block ───────────────────────────────────────────
// Routed from :generation_chunk `thinking`. One <details> per turn; accumulates
// across the turn's generations and collapses on turn completion.

function ensureThinkingEl() {
  if (thinkingEl) return thinkingEl;
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
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
    historyEl.appendChild(details);
  }
  return details;
}

function appendThinking(content) {
  if (!content) return;
  thinkingBuffer += content;
  ensureThinkingEl();
  if (!rafPending) {
    rafPending = true;
    requestAnimationFrame(flushStreaming);
  }
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
    if (k) seenContent.add(k);
    else streamingBubble.remove(); // drop text-less bubbles (thinking/tool-only generations, "…" placeholder)
    streamingBubble.classList.remove("streaming");
    streamingBubble = null;
  }
  streamingBuffer = "";
  rafPending = false;
}

function addCancelBubble(reason) {
  const div = document.createElement("div");
  div.className = "bubble cancel";
  div.textContent = "\u2715 canceled" + (reason ? ` (${reason})` : "");
  historyEl.appendChild(div);
  historyEl.scrollTop = historyEl.scrollHeight;
}

function setUserBubbleState(content, state) {
  const normalized = normalize(content || "");
  if (!normalized) return;

  const existing = [...historyEl.querySelectorAll(".bubble.user")].reverse().find((el) => {
    const match = normalize(el.dataset.userContent || el.querySelector(".user-message")?.textContent || el.textContent || "");
    return match === normalized;
  });

  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();

  if (existing) {
    existing.dataset.userContent = normalized;
    existing.classList.remove("queued", "steered");
    existing.classList.add(state);
    existing.dataset.userState = state;

    const badge = existing.querySelector(".state-badge") || document.createElement("span");
    badge.className = "state-badge";
    badge.textContent = state === "steered" ? "steered" : "queued";

    let message = existing.querySelector(".user-message");
    if (!message) {
      message = document.createElement("span");
      message.className = "user-message";
      existing.textContent = "";
      existing.appendChild(message);
    }
    message.textContent = content;

    if (!badge.parentNode) existing.appendChild(badge);
    return;
  }

  const div = document.createElement("div");
  div.className = `bubble user ${state}`;
  div.dataset.userState = state;
  div.dataset.userContent = normalized;

  const message = document.createElement("span");
  message.className = "user-message";
  message.textContent = content;

  const badge = document.createElement("span");
  badge.className = "state-badge";
  badge.textContent = state === "steered" ? "steered" : "queued";

  div.appendChild(message);
  div.appendChild(badge);
  historyEl.appendChild(div);
  if (isNearBottom()) historyEl.scrollTop = historyEl.scrollHeight;
}

// User message injected mid-turn via the pending-input queue. We update the
// original bubble into a queued->steered state so users see the transition
// without a duplicate message being appended.
function addSteeredUserBubble(content) {
  setUserBubbleState(content, "steered");
}

// ── Per-turn tool/memory activity panel ────────────────────────────────────
// One collapsible <details> per turn; each :tool_call_started/completed upserts
// a row (keyed by iteration:call_index) that transitions running -> ok/error.
// Memory reads/writes flow through the same tool_call events, so they show here too.

function activityStatusClass(status) {
  if (status === "running") return "running";
  if (status === "error") return "error";
  return "ok";
}

function activityStatusLabel(status) {
  if (status === "running") return "running";
  if (status === "error") return "error";
  return "done";
}

function ensureActivityEl() {
  if (activityEl) return activityEl;
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
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
  historyEl.appendChild(details);
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
  toolEl.textContent = row.tool || "tool";
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
  const statusEl = el.querySelector(".activity-status");
  statusEl.className = `activity-status ${activityStatusClass(row.status)}`;
  statusEl.textContent = activityStatusLabel(row.status);
  const toolEl = el.querySelector(".activity-tool");
  if (toolEl) toolEl.textContent = row.tool || "tool";
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
}

function updateActivitySummary() {
  if (!activityEl) return;
  const summary = activityEl.querySelector("summary");
  if (summary) summary.textContent = `activity (${activityCount(activityModel)})`;
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

function updateInfoBar() {
  const stopBtn = document.getElementById("infoStopBtn");
  if (!selected) {
    infoTextEl.innerHTML = `<div class="idle">No session selected — select one above or type a prompt below to start a new session.</div><div class="idle"><small>Sessions are stored in <code>~/.local/state/samagotchi/sessions</code> · choose a session or create one via the composer</small></div>`;
    infoTextEl.title = "";
    if (stopBtn) stopBtn.style.display = "none";
    return;
  }
  if (stopBtn) stopBtn.style.display = "";
  const idShort = selected.slice(0,8);
  const memText = currentUsedMemories.length ? currentUsedMemories.join(", ") : "—";
  const ctxText = currentCtxPct !== null ? `ctx ${Math.round(currentCtxPct)}%` : "";
  const sessionDuration = currentSessionDuration();
  const timingText = sessionDuration === null ? "" : `session ${formatDuration(sessionDuration)}`;
  const statusClass = currentStatus ? `status ${escapeHtml(currentStatus)}` : "status";
  const metaHtml = `<div class="meta"><span class="id">${escapeHtml(idShort)}</span><span class="${statusClass}">${escapeHtml(currentStatus||"")}</span><span class="model" title="${escapeHtml(currentModel||"")}">${escapeHtml((currentModel||"").slice(0,40))}</span><span class="dir" title="${escapeHtml(currentDir||"")}">${escapeHtml((currentDir||"").slice(0,48))}</span>${ctxText ? `<span class="model">${escapeHtml(ctxText)}</span>` : ""}${timingText ? `<span class="model">${escapeHtml(timingText)}</span>` : ""}</div>`;
  const previewHtml = `<div class="preview-line"><span class="preview">${escapeHtml(currentFirstPreview || "—")}</span> · <span class="mem" title="${escapeHtml(currentUsedMemories.join(", "))}">mem: ${escapeHtml(memText)}</span></div>`;
  infoTextEl.innerHTML = metaHtml + previewHtml;
  infoTextEl.title = `memories: ${currentUsedMemories.join(", ") || "—"}`;
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

function startLiveTurnTiming(startedAt = new Date().toISOString()) {
  clearTimingInterval();
  currentTiming.activeTurn = { started_at: startedAt };
  liveTurnTimingEl = document.createElement("div");
  liveTurnTimingEl.className = "turn-timing live";
  historyEl.appendChild(liveTurnTimingEl);
  updateLiveTiming();
  timingInterval = setInterval(updateLiveTiming, 1000);
}

function updateLiveTiming() {
  const duration = elapsedSince(currentTiming.activeTurn?.started_at);
  if (liveTurnTimingEl && duration !== null) {
    liveTurnTimingEl.textContent = `turn running · ${formatDuration(duration)}`;
  }
  updateInfoBar();
}

function finishLiveTurnTiming(record = null) {
  const duration = Number.isFinite(Number(record?.duration_ms))
    ? Number(record.duration_ms)
    : elapsedSince(currentTiming.activeTurn?.started_at);
  if (liveTurnTimingEl && duration !== null) {
    liveTurnTimingEl.classList.remove("live");
    liveTurnTimingEl.textContent = `turn · ${formatDuration(duration)}`;
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

function extractCtxPct(data) {
  if (!data || typeof data !== "object") return null;
  if (typeof data.ctx_pct === "number") return data.ctx_pct;
  if (typeof data.est_pct === "number") return data.est_pct;
  if (typeof data.ctxPct === "number") return data.ctxPct;
  if (data.context_window_tokens && data.total_tokens) return (data.total_tokens / data.context_window_tokens)*100;
  const p = data.payload || data.timings || data.usage || data;
  if (p && typeof p.ctx_pct === "number") return p.ctx_pct;
  if (p && p.usage && typeof p.usage.total_tokens === "number" && p.n_ctx) return (p.n_past||p.usage.total_tokens)/p.n_ctx*100;
  if (typeof p.n_past === "number" && typeof p.n_ctx === "number" && p.n_ctx>0) return (p.n_past/p.n_ctx)*100;
  if (p && p.prompt_n && p.n_ctx) return (p.prompt_n/p.n_ctx)*100;
  return null;
}

function startStream(id, fromSeq, retryDelay = 2000, attempts = 0) {
  if (streamControl) {
    streamControl.close();
    streamControl = null;
  }
  streamControl = openStream(id, fromSeq, {
    generation_chunk: (data) => {
      // Phase 2: route the chunk's bytes to the text bubble and the thinking
      // block (see chunk_router.js). Raw `content` is only used as a fallback
      // for pre-Phase-2 / non-enriched servers.
      const { text, thinking } = routeChunk(data);
      if (text) appendToken(text);
      if (thinking) appendThinking(thinking);
      const pct = extractCtxPct(data) ?? extractCtxPct(data.payload) ?? extractCtxPct(data.payload?.timings);
      if (pct !== null && !Number.isNaN(pct)) {
        currentCtxPct = pct;
        updateInfoBar();
        updateFirstPeek();
      }
    },
    generation_started: () => {
      streamingBuffer = "";
      ensureStreamingBubble();
    },
    generation_completed: () => finalizeStreaming(),
    pending_input_merged: (data) => {
      // Steering message queued while the turn ran and injected at an
      // iteration boundary. The sender's own POST /turn already local-echoes
      // a user bubble, but another client (or a muted reminder path) may have
      // pushed it — render the merged message so the transcript matches what
      // the model actually saw.
      if (data.content) addSteeredUserBubble(data.content);
    },
    turn_started: (data) => {
      setTurnRunning(true);
      resetActivityState();
      clearTimingInterval();
      liveTurnTimingEl = null;
      resetThinkingState();
      streamingBuffer = "";
      ensureStreamingBubble();
      if (data.prompt) streamingBubble.textContent = "…";
      startLiveTurnTiming();
    },
    turn_completed: async (data) => {
      setTurnRunning(false);
      finalizeStreaming();
      finalizeActivityEl();
      finalizeThinkingEl();
      finishLiveTurnTiming();
      const out = data.result ? data.result.output || "" : data.content || data.output || "";
      if (typeof out === "string" && out.trim()) appendChunk(out.trim());
      if (selected) {
        try {
          const d = await getSession(selected);
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
      setTurnRunning(false);
      finalizeStreaming();
      finalizeActivityEl();
      finalizeThinkingEl();
      finishLiveTurnTiming();
      addCancelBubble(data.cancellation_reason || "");
      refreshTimingFromSession();
    },
    tool_call_started: (data) => {
      const model = activityModel || (activityModel = newActivity());
      ensureActivityEl();
      const { row } = addStarted(model, data);
      if (!activityRowEls.has(row.key)) renderActivityRow(row);
      else updateActivityRowEl(row);
      updateActivitySummary();
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
    tool_call_completed: (data) => {
      const model = activityModel || (activityModel = newActivity());
      ensureActivityEl();
      const row = addCompleted(model, data);
      if (!activityRowEls.has(row.key)) renderActivityRow(row);
      else updateActivityRowEl(row);
      updateActivitySummary();
    },
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
    reset: async (data) => {
      if (!selected) return;
      const seq = data && data.session_state_snapshot ? data.session_state_snapshot.event_seq : null;
      if (typeof seq === "number" && seq === fromSeq) return;
      closeStream();
      const d2 = await getSession(selected).catch(() => null);
      if (!d2) return;
      if (d2.session) {
        setMarkdownWarning(d2.markdown_warning);
        currentUsedMemories = d2.session.used_memory_names || currentUsedMemories;
        currentFirstPreview = d2.session.first_preview || currentFirstPreview;
        currentStatus = d2.session.status || currentStatus;
        currentModel = d2.session.model_name || currentModel;
        currentDir = d2.session.working_directory || currentDir;
        const snap = data.session_state_snapshot;
        if (snap && Array.isArray(snap.used_memory_names)) currentUsedMemories = snap.used_memory_names;
        updateInfoBar();
        updateFirstPeek();
        updateComposerMode();
      }
      if (d2.messages && d2.messages.length) renderHistory(d2.messages);
      else renderHistory(d2.history || []);
      seedSeenFromDom();
      startStream(selected, d2.last_event_seq);
    },
  }, {
    onStreamError: () => {
      streamControl = null;
      if (id !== selected) return;
      if (attempts < MAX_STREAM_RETRIES) {
        setTimeout(() => startStream(id, fromSeq, Math.min(retryDelay * 1.5, 10000), attempts + 1), retryDelay);
      } else {
        historyEl.innerHTML = `<div class="hint">Stream unavailable—the session worker may have stopped. <button class="ghost" id="streamRetry">Retry</button></div>`;
        const btn = $("#streamRetry");
        if (btn) btn.addEventListener("click", () => select(id));
      }
    },
  });
}

async function refreshTimingFromSession() {
  if (!selected) return;
  try {
    const data = await getSession(selected);
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

  const card = document.createElement("div");
  card.className = "bubble question";
  card.dataset.qid = pq.id;

  if (pq.header) {
    const head = document.createElement("div");
    head.className = "question-header";
    head.textContent = pq.header;
    card.appendChild(head);
  }

  const q = document.createElement("div");
  q.className = "question-text";
  q.textContent = pq.question || "";
  card.appendChild(q);

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
    freeformInput.placeholder = "Other…";
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

  historyEl.appendChild(card);
  questionCardEl = card;
  if (isNearBottom()) historyEl.scrollTop = historyEl.scrollHeight;
}

function resolveQuestionCard(id, { answer = null, cancelled = false, reason = "" } = {}) {
  if (!questionCardEl) return;
  if (id && pendingQuestion && String(pendingQuestion.id) !== String(id)) return;

  const note = document.createElement("div");
  note.className = "question-result";
  if (cancelled) {
    questionCardEl.classList.add("cancelled");
    note.textContent = reason ? `Cancelled (${reason})` : "Cancelled";
  } else {
    questionCardEl.classList.add("answered");
    const sel = answer && Array.isArray(answer.selected) ? answer.selected : [];
    const parts = [];
    if (sel.length) parts.push(sel.join(", "));
    if (answer && answer.freeform) parts.push(answer.freeform);
    note.textContent = parts.length ? `Answered: ${parts.join(" · ")}` : "Answered";
    markQuestionSelection(sel);
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
  streamingBubble = null;
  streamingBuffer = "";
  rafPending = false;
  resetActivityState();
  if (streamControl) {
    streamControl.close();
    streamControl = null;
  }
}

async function handleCreate() {
  const prompt = promptEl.value.trim();
  if (!prompt) return;
  actionBtn.disabled = true;
  createAltBtn.disabled = true;
  try {
    const s = await createSession(prompt);
    await refresh();
    select(s.id);
    promptEl.value = "";
  } catch (e) {
    alert(e.message);
  } finally {
    actionBtn.disabled = false;
    createAltBtn.disabled = false;
  }
}

async function handleSendTurn() {
  if (!selected) return handleCreate();
  const prompt = promptEl.value.trim();
  if (!prompt) return;
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  finalizeStreaming();
  const userDiv = document.createElement("div");
  userDiv.className = "bubble user queued";
  userDiv.dataset.userState = "queued";
  userDiv.dataset.userContent = normalize(prompt);

  const message = document.createElement("span");
  message.className = "user-message";
  message.textContent = prompt;

  const badge = document.createElement("span");
  badge.className = "state-badge";
  badge.textContent = "queued";

  userDiv.appendChild(message);
  userDiv.appendChild(badge);
  historyEl.appendChild(userDiv);
  historyEl.scrollTop = historyEl.scrollHeight;
  if (!currentFirstPreview || currentFirstPreview==="—") {
    currentFirstPreview = normalize(prompt).slice(0,80) + (normalize(prompt).length>80?"…":"");
    updateInfoBar();
    updateFirstPeek();
  }
  actionBtn.disabled = true;
  try {
    await sendTurn(selected, prompt);
    promptEl.value = "";
    // Worker was resumed by POST /turn; now attach to live SSE tail.
    try {
      const d = await getSession(selected);
      if (typeof d.last_event_seq === "number") startStream(selected, d.last_event_seq);
      else startStream(selected, 0);
    } catch (_) {
      startStream(selected, 0);
    }
  } catch (e) {
    alert(e.message);
  } finally {
    actionBtn.disabled = false;
    promptEl.focus();
  }
}

async function handleCancel() {
  if (!selected) return;
  actionBtn.disabled = true;
  try {
    await cancelTurn(selected);
  } catch (e) {
    alert(e.message);
  } finally {
    actionBtn.disabled = false;
  }
}

const _refreshBtn = $("#refresh");
if (_refreshBtn) _refreshBtn.addEventListener("click", () => { displayLimit = 6; refresh(); updateComposerMode(); });
const _newBtn = $("#newBtn");
if (_newBtn) _newBtn.addEventListener("click", () => {
  clearSelection();
});
actionBtn.addEventListener("click", () => {
  if (turnRunning && selected) handleCancel();
  else if (!selected) handleCreate();
  else handleSendTurn();
});
createAltBtn.addEventListener("click", () => handleCreate());
promptEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    if (turnRunning && selected) handleCancel();
    else if (!selected) handleCreate();
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
  await stopSession(selected);
  refresh();
});

// zen mode
const zenBtn = $("#zenBtn");
function isZen(){ try{return localStorage.getItem("chi_zen")==="1"}catch(_){return false}}
function setZen(v){
  try{localStorage.setItem("chi_zen", v?"1":"0")}catch(_){}
  document.body.classList.toggle("zen", v);
  zenBtn.textContent = v?"exit zen":"zen";
}
setZen(isZen());
zenBtn.addEventListener("click", ()=> setZen(!document.body.classList.contains("zen")));
document.addEventListener("keydown", (e)=>{
  if(e.key==="z" && !e.metaKey && !e.ctrlKey && e.target.tagName!=="INPUT" && e.target.tagName!=="TEXTAREA"){
    setZen(!document.body.classList.contains("zen"));
  }
  if(e.key==="Escape" && document.body.classList.contains("zen")){
    setZen(false);
  }
  if(e.key==="Escape" && actionMenu.classList.contains("visible")){
    actionMenu.classList.remove("visible");
  }
});

$("#filter").addEventListener("input", () => { displayLimit = 6; render(); });

updateInfoBar();
updateComposerMode();
refresh();
