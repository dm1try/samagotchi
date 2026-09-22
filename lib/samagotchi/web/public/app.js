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
import { escapeHtml, messageBodyHtml, normalize, ownerBadge, previewForCard, firstMessageOf } from "./format.js";
import { newActivity, addStarted, addCompleted, finalizeActivity, activityCount } from "./activity.js";
import { routeChunk } from "./chunk_router.js";
import { extractCtxPct } from "./ctx.js";
import { shouldFollowScroll } from "./scroll.js";
import { elapsedSince, formatDuration, normalizeTiming, turnRecordAt } from "./timing.js";
import { clientLabel, isOwn, newClientId, promptOps, snapshotEvents, turnOutput } from "./turn_events.js";

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
const cancelBtn = $("#cancelBtn");
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
// Window the kernel resolved for the running generation (:generation_started).
let currentCtxWindow = null;
let currentStatus = "";
let currentModel = "";
let currentDir = "";
// Who holds the selected session: "worker" (shared), "tui" (a plain terminal
// chi; sending would be refused) or null.
let currentOwner = null;
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
// This tab's id in the session's events: tells its own prompts from the
// ones other clients (an attached TUI, another tab, reminders) sent.
const clientId = newClientId();
// The event_seq the selected session was rendered at (null: no live worker
// then), where a stream opened later has to start.
let selectSeq = null;
// The last input_merged had an origin with no bubble: its merged text
// (pending_input_merged) gets one.
let unmatchedMerge = false;

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
  return `<div class="card" data-id="${s.id}" title="${escapeHtml(tip)}${memTitle ? ` · ${escapeHtml(memTitle)}` : ""}"><div class="id">${escapeHtml(s.short_id)} · ${escapeHtml(s.id.slice(0,8))}</div><div class="preview">${preview}</div><div class="meta"><span class="status ${escapeHtml(s.status)}">${escapeHtml(s.status)}</span>${ownerBadgeHtml(s)}${s.used_memory_names && s.used_memory_names.length ? `<span title="${escapeHtml(s.used_memory_names.join(", "))}">mem ${s.used_memory_names.length}</span>` : ""}</div></div>`;
}

function ownerBadgeHtml(s) {
  const badge = ownerBadge(s.owner, s.id);
  return badge ? `<span class="owner ${badge.kind}" title="${escapeHtml(badge.title)}">${escapeHtml(badge.text)}</span>` : "";
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

// While a turn runs, Send still sends: the prompt merges into the turn at
// its next step (steering). Cancel is its own button then.
function updateComposerMode() {
  const running = turnRunning && !!selected;
  cancelBtn.style.display = running ? "" : "none";
  if (running) {
    promptEl.placeholder = "Running… a message now steers this turn (Enter to send)";
    actionBtn.textContent = "Send";
    createAltBtn.style.display = "none";
    actionMenuBtn.style.display = "none";
    actionMenu.classList.remove("visible");
    emptyEl.classList.add("hidden");
    return;
  }
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
  } else if (currentOwner === "tui") {
    promptEl.placeholder = "A terminal chi owns this session and doesn't share it — run it with chi --shared to send from here";
    actionBtn.textContent = "Send";
    actionBtn.disabled = true;
    createAltBtn.style.display = "inline-block";
    createAltBtn.textContent = "Create new";
    actionMenuBtn.style.display = "none";
    emptyEl.classList.add("hidden");
  } else {
    promptEl.placeholder = "Send a message… (Enter to send, Shift+Enter for newline)";
    actionBtn.textContent = "Send";
    actionBtn.disabled = false;
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

// Session status is turn state (idle/running): follow the live stream in the
// info bar and the session's card without a refetch.
function setLiveStatus(status) {
  currentStatus = status;
  const sess = allSessions.find((s) => s.id === selected);
  if (sess) sess.status = status;
  const badge = selected && document.querySelector(`.card[data-id="${selected}"] .status`);
  if (badge) {
    badge.className = `status ${status}`;
    badge.textContent = status;
  }
  updateInfoBar();
}

function clearSelection() {
  selected = null;
  document.querySelectorAll(".card").forEach((el) => el.classList.remove("active"));
  currentFirstPreview = "";
  currentUsedMemories = [];
  currentCtxPct = null;
  currentCtxWindow = null;
  currentStatus = "";
  currentModel = "";
  currentDir = "";
  currentOwner = null;
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
  historyEl.innerHTML = `<div class="hint">Loading…</div>`;
  emptyEl.classList.add("hidden");
  closeStream();
  currentFirstPreview = "";
  currentUsedMemories = [];
  currentCtxPct = null;
  currentCtxWindow = null;
  currentStatus = "";
  currentModel = "";
  currentDir = "";
  currentOwner = null;
  currentTiming = normalizeTiming();
  resetTurnView();
  updateFirstPeek();
  updateInfoBar();
  updateComposerMode();
  await resync();
  promptEl.focus();
}

// Clear everything that belongs to one turn's rendering.
function resetTurnView() {
  closeStream();
  resetActivityState();
  resetThinkingState();
  clearTimingInterval();
  liveTurnTimingEl = null;
  removeQuestionCard();
  unmatchedMerge = false;
  setTurnRunning(false);
}

// (Re)render the selected session from the server and stream on from the
// event_seq that render covers. Used on select and when the stream resets
// (its cursor could not be replayed).
async function resync() {
  const id = selected;
  if (!id) return;
  let data;
  try {
    data = await getSession(id);
  } catch (e) {
    if (id === selected) historyEl.innerHTML = `<div class="hint">Error: ${escapeHtml(e.message)}</div>`;
    return;
  }
  if (id !== selected) return;
  resetTurnView();
  renderSessionView(data);
  // Preview is read-only: a worker is woken only by POST /turn, so attach
  // only when a live bridge exists.
  selectSeq = typeof data.last_event_seq === "number" ? data.last_event_seq : null;
  if (selectSeq !== null) startStream(id, selectSeq);
}

// A session view: its messages, then the turn in progress and the queued
// prompts (a live worker's snapshot) replayed through the stream handlers,
// then a pending question.
function renderSessionView(data) {
  const s = data.session;
  setMarkdownWarning(data.markdown_warning);
  currentStatus = s.status;
  currentModel = s.model_name;
  currentDir = s.working_directory;
  currentOwner = s.owner || null;
  currentTiming = normalizeTiming(data.timing);
  currentFirstPreview = s.first_preview || previewForCard(s);
  currentUsedMemories = s.used_memory_names || [];
  if (data.messages && data.messages.length) {
    const first = data.messages.find((m) => m.role === "user");
    if (first && first.content) currentFirstPreview = normalize(first.content).slice(0,80) + (normalize(first.content).length>80?"…":"");
    renderHistory(data.messages);
  } else {
    renderHistory(data.history || []);
    if (!currentFirstPreview && data.history && data.history.length) {
      const txt = normalize(String(data.history[0]||"")).slice(0,80);
      if(txt) currentFirstPreview = txt;
    }
  }
  seedSeenFromDom();
  showRecap(data.recap);
  const replay = snapshotEvents({
    current_turn: data.current_turn,
    queued: data.queued,
    started_at: currentTiming.activeTurn?.started_at,
  });
  replay.forEach((event) => streamHandlers[event.type]?.(event));
  if (!data.current_turn) {
    setTurnRunning(currentStatus === "running");
    if (turnRunning && currentTiming.activeTurn?.started_at) startLiveTurnTiming(currentTiming.activeTurn.started_at);
  }
  flushStreaming();
  // A question the worker is blocked on (also after a reload).
  if (data.pending_question && data.pending_question.id && data.pending_question.status === "pending") {
    renderQuestionCard(data.pending_question);
  }
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
  // An empty buffer keeps the "…" placeholder.
  if (streamingBubble && streamingBuffer) {
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
    // The text lands in the bubble on the next animation frame; a generation
    // can end before one runs (a burst of frames, a hidden tab), so write it
    // here too or the bubble keeps its "…" placeholder.
    if (k) {
      streamingBubble.textContent = streamingBuffer;
      seenContent.add(k);
    }
    else streamingBubble.remove(); // drop text-less bubbles (thinking/tool-only generations, "…" placeholder)
    streamingBubble.classList.remove("streaming");
    streamingBubble = null;
  }
  streamingBuffer = "";
  rafPending = false;
}

function addCancelBubble(reason) {
  addEndBubble("\u2715 canceled" + (reason ? ` (${reason})` : ""));
}

function addEndBubble(text) {
  const div = document.createElement("div");
  div.className = "bubble cancel";
  div.textContent = text;
  historyEl.appendChild(div);
  historyEl.scrollTop = historyEl.scrollHeight;
}

// Everything a turn's end (completed, canceled, failed) closes.
function endTurnView() {
  setTurnRunning(false);
  finalizeStreaming();
  finalizeActivityEl();
  finalizeThinkingEl();
  finishLiveTurnTiming();
  // The question dies with its turn (the worker stopped waiting).
  if (pendingQuestion) resolveQuestionCard(pendingQuestion.id, { cancelled: true, reason: "turn ended" });
}

// ── Prompt bubbles ─────────────────────────────────────────────────────────
// Every client's prompts, keyed by enqueued_id: queued (badge) until their
// turn starts, or steered when merged into a running turn. This tab's own
// prompts are echoed at send (data-own) and tagged by their turn_enqueued.

const BADGES = { queued: "queued", steered: "steered" };

function makeUserBubble(prompt, { state = null, label = null, enqueuedId = null, own = false } = {}) {
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  const div = document.createElement("div");
  div.className = "bubble user";
  div.dataset.userContent = normalize(prompt);
  if (own) div.dataset.own = "1";
  if (enqueuedId) div.dataset.enqueuedId = enqueuedId;
  if (label) {
    const from = document.createElement("span");
    from.className = "origin-label";
    from.textContent = label;
    div.appendChild(from);
  }
  const message = document.createElement("span");
  message.className = "user-message";
  message.textContent = prompt;
  div.appendChild(message);
  setBubbleState(div, state);
  const follow = isNearBottom();
  historyEl.appendChild(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
  return div;
}

function setBubbleState(bubble, state) {
  bubble.classList.remove("queued", "steered");
  bubble.querySelector(".state-badge")?.remove();
  if (!BADGES[state]) {
    delete bubble.dataset.userState;
    return;
  }
  bubble.classList.add(state);
  bubble.dataset.userState = state;
  const badge = document.createElement("span");
  badge.className = "state-badge";
  badge.textContent = BADGES[state];
  bubble.appendChild(badge);
}

function bubbleById(enqueuedId) {
  if (!enqueuedId) return null;
  return [...historyEl.querySelectorAll(".bubble.user[data-enqueued-id]")].find(
    (el) => el.dataset.enqueuedId === enqueuedId,
  ) || null;
}

// This tab's oldest untagged echo, preferring one with the same text.
function untaggedOwnBubble(prompt) {
  const echoes = [...historyEl.querySelectorAll(".bubble.user[data-own]:not([data-enqueued-id])")];
  const text = normalize(prompt || "");
  return echoes.find((el) => el.dataset.userContent === text) || echoes[0] || null;
}

function applyPromptOps(event) {
  const ops = promptOps(event, { myId: clientId, known: (id) => !!bubbleById(id), unmatchedMerge });
  if (event.type === "input_merged") unmatchedMerge = false;
  if (event.type === "pending_input_merged") unmatchedMerge = false;
  for (const op of ops) {
    if (op.op === "add") {
      makeUserBubble(op.prompt, { state: op.state, label: op.label, enqueuedId: op.enqueuedId });
    } else if (op.op === "tag") {
      if (bubbleById(op.enqueuedId)) continue;
      const echo = untaggedOwnBubble(op.prompt);
      if (echo) echo.dataset.enqueuedId = op.enqueuedId;
      // Re-rendered from a snapshot: the echo is gone, the prompt still queued.
      else makeUserBubble(op.prompt, { state: "queued", own: true, enqueuedId: op.enqueuedId });
    } else if (op.op === "start") {
      const bubble = bubbleById(op.enqueuedId) || untaggedOwnBubble(op.prompt);
      if (!bubble) continue;
      if (op.enqueuedId) bubble.dataset.enqueuedId = op.enqueuedId;
      setBubbleState(bubble, null);
    } else if (op.op === "steer") {
      const bubble = bubbleById(op.enqueuedId);
      if (bubble) setBubbleState(bubble, "steered");
      else unmatchedMerge = true;
    }
  }
}

// ── Idle recap ─────────────────────────────────────────────────────────────
// A summary the worker writes after a quiet stretch (when `recap:` is
// configured): shown at the end of the history until the next turn starts.

function showRecap(text) {
  removeRecap();
  if (!text) return;
  const details = document.createElement("details");
  details.className = "bubble recap";
  details.open = true;
  const summary = document.createElement("summary");
  summary.textContent = "recap";
  const body = document.createElement("div");
  body.className = "recap-body";
  body.textContent = text;
  details.appendChild(summary);
  details.appendChild(body);
  const follow = isNearBottom();
  historyEl.appendChild(details);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

function removeRecap() {
  historyEl.querySelectorAll(".bubble.recap").forEach((el) => el.remove());
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

function startStream(id, fromSeq, retryDelay = 2000, attempts = 0) {
  if (streamControl) {
    streamControl.close();
    streamControl = null;
  }
  streamControl = openStream(id, fromSeq, streamHandlers, {
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

// The stream's event handlers; renderSessionView replays a snapshot through
// them too.
const streamHandlers = {
  generation_chunk: (data) => {
    // Phase 2: route the chunk's bytes to the text bubble and the thinking
    // block (see chunk_router.js). Raw `content` is only used as a fallback
    // for pre-Phase-2 / non-enriched servers.
    const { text, thinking } = routeChunk(data);
    if (text) appendToken(text);
    if (thinking) appendThinking(thinking);
    const pct = extractCtxPct(data, currentCtxWindow);
    if (pct !== null && !Number.isNaN(pct)) {
      currentCtxPct = pct;
      updateInfoBar();
      updateFirstPeek();
    }
  },
  generation_started: (data) => {
    if (data?.context_window_tokens) currentCtxWindow = data.context_window_tokens;
    // A generation left open (a join mid-way) ends where the next begins.
    finalizeStreaming();
    ensureStreamingBubble();
  },
  generation_completed: () => finalizeStreaming(),
  // Prompts sent while a turn ran merge into it at an iteration boundary:
  // input_merged names them (their bubbles turn "steered"), then
  // pending_input_merged carries the merged text, shown only for prompts
  // this tab has no bubble for.
  input_merged: (data) => applyPromptOps(data),
  pending_input_merged: (data) => applyPromptOps(data),
  turn_enqueued: (data) => applyPromptOps(data),
  turn_started: (data) => {
    removeRecap();
    applyPromptOps(data);
    setTurnRunning(true);
    setLiveStatus("running");
    resetActivityState();
    clearTimingInterval();
    liveTurnTimingEl = null;
    resetThinkingState();
    streamingBuffer = "";
    ensureStreamingBubble();
    if (data.prompt) streamingBubble.textContent = "…";
    startLiveTurnTiming(data.started_at);
  },
  turn_completed: async (data) => {
    endTurnView();
    const out = turnOutput(data);
    if (out) appendChunk(out);
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
    endTurnView();
    setLiveStatus("idle");
    addCancelBubble(data.cancellation_reason || "");
    refreshTimingFromSession();
  },
  // The turn raised (e.g. the model server stayed unreachable); its worker
  // exits right after, so drop the stream: the next send wakes a new worker,
  // whose events start from seq 0.
  turn_failed: (data) => {
    endTurnView();
    setLiveStatus("idle");
    addEndBubble(`\u2715 turn failed: ${data.message || "error"}${data.error_class ? ` (${data.error_class})` : ""}`);
    closeStream();
    selectSeq = null;
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
  recap_ready: (data) => showRecap(data.recap),
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
  if (currentOwner === "tui") return;
  const prompt = promptEl.value.trim();
  if (!prompt) return;
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  const echo = makeUserBubble(prompt, { state: "queued", own: true });
  historyEl.scrollTop = historyEl.scrollHeight;
  if (!currentFirstPreview || currentFirstPreview==="—") {
    currentFirstPreview = normalize(prompt).slice(0,80) + (normalize(prompt).length>80?"…":"");
    updateInfoBar();
    updateFirstPeek();
  }
  actionBtn.disabled = true;
  try {
    const ack = await sendTurn(selected, prompt, { clientId });
    promptEl.value = "";
    // Its turn_enqueued usually tagged the echo already; the ack covers a
    // worker that wasn't live (no turn_enqueued then).
    if (ack?.enqueued_id && !echo.dataset.enqueuedId && !bubbleById(ack.enqueued_id)) {
      echo.dataset.enqueuedId = ack.enqueued_id;
    }
    // A live stream carries this turn already; restarting it would drop the
    // events in between. Without one, POST /turn just woke a worker: its
    // events start after the seq the session was rendered at (0 for a new
    // worker process).
    if (!streamControl?.live) startStream(selected, selectSeq ?? 0);
  } catch (e) {
    echo.remove();
    if (/owned_by_tui|409/.test(e.message)) {
      currentOwner = "tui";
      updateComposerMode();
      return;
    }
    alert(e.message);
  } finally {
    actionBtn.disabled = currentOwner === "tui";
    promptEl.focus();
  }
}

async function handleCancel() {
  if (!selected) return;
  cancelBtn.disabled = true;
  try {
    await cancelTurn(selected);
  } catch (e) {
    // The turn ended meanwhile: nothing left to cancel.
    if (!/not_running|409/.test(e.message)) alert(e.message);
  } finally {
    cancelBtn.disabled = false;
  }
}

const _refreshBtn = $("#refresh");
if (_refreshBtn) _refreshBtn.addEventListener("click", () => { displayLimit = 6; refresh(); updateComposerMode(); });
const _newBtn = $("#newBtn");
if (_newBtn) _newBtn.addEventListener("click", () => {
  clearSelection();
});
actionBtn.addEventListener("click", () => {
  if (!selected) handleCreate();
  else handleSendTurn();
});
cancelBtn.addEventListener("click", () => handleCancel());
createAltBtn.addEventListener("click", () => handleCreate());
promptEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    if (!selected) handleCreate();
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
