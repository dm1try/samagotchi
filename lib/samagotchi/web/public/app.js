import {
  listSessions,
  createSession,
  getSession,
  sendTurn,
  cancelTurn,
  stopSession,
  deleteSession,
  sendAnswer,
  dismissQuestion,
  sendCommand,
  openStream,
  watchForWorker,
  createIdleSession,
  uploadImage,
} from "./data.js";
import { chipName, chipsHtml, imageFiles, restoredChips, thumbsHtml, turnRefs, turnText } from "./images.js";
import { escapeHtml, messageBodyHtml, noteHtml, normalize, userBodyHtml, ownerBadge, previewForCard, firstMessageOf, failedTurnText, modelLabel, deleteConfirmText } from "./format.js";
import { newActivity, addStarted, addCompleted, finalizeActivity, activityCount } from "./activity.js";
import { annotationSource, appendQuote, quoteBlock } from "./annotations.js";
import { routeChunk } from "./chunk_router.js";
import { extractCtxPct } from "./ctx.js";
import { approvalAllowed, approvalView, isApproval, resultText } from "./question_card.js";
import { ALL_SESSIONS_HASH, sessionHash, sessionIdFromHash } from "./route.js";
import { shouldFollowScroll } from "./scroll.js";
import {
  appendAboveLiveTiming, elapsedSince, formatDuration, normalizeTiming, timedTurnIndexes, turnRecordAt,
} from "./timing.js";
import { clientLabel, commandView, continueLine, isCommandLine, isOwn, newClientId, promptOps, reminderText, restoreAction, snapshotEvents, turnOutput } from "./turn_events.js";

const $ = (s) => document.querySelector(s);
const topStripEl = $("#topStrip");
const allListEl = $("#allList");
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
// Polls the selected session while it has no live stream (see
// startWorkerWatch).
let workerWatch = null;
let allSessions = [];
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
// What the worker's server said it served for a model name: [served, asked].
let currentServed = null;
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
// The continue offer's card while the offer is pending.
let continueCardEl = null;

// This tab's id in the session's events: tells its own prompts from the
// ones other clients (an attached TUI, another tab, reminders) sent.
const clientId = newClientId();
// The event id (or, from an older worker, the event_seq) the selected session
// was rendered at (null: no live worker then), where a stream opened later
// has to start.
let selectSeq = null;
// The last input_merged had an origin with no bubble: its merged text
// (pending_input_merged) gets one.
let unmatchedMerge = false;
// The enqueued_ids this page sent (from the /turn acks): only these come back
// into the composer when their turn fails.
const sentIds = new Set();
// The last turn_failed's line, shown again after prompt_restored's resync.
let lastFailedText = null;

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

// deletable: the all-sessions view's cards get a delete button.
function cardHtml(s, { deletable = false } = {}) {
  const ts = s.updated_at || s.created_at || "";
  const tip = `${s.id} · updated ${ts} · ${s.status}`;
  const preview = escapeHtml(previewForCard(s));
  const memTitle = s.used_memory_names && s.used_memory_names.length ? `mem: ${s.used_memory_names.join(", ")}` : "";
  return `<div class="card" data-id="${s.id}" title="${escapeHtml(tip)}${memTitle ? ` · ${escapeHtml(memTitle)}` : ""}"><div class="id">${escapeHtml(s.short_id)}</div><div class="preview">${preview}</div><div class="meta"><span class="status ${escapeHtml(s.status)}">${escapeHtml(s.status)}</span>${ownerBadgeHtml(s)}${s.used_memory_names && s.used_memory_names.length ? `<span title="${escapeHtml(s.used_memory_names.join(", "))}">mem ${s.used_memory_names.length}</span>` : ""}</div>${deletable ? `<button type="button" class="card-del" data-del="${escapeHtml(s.id)}" title="Delete session" aria-label="Delete session ${escapeHtml(s.short_id)}">\u2715</button>` : ""}</div>`;
}

function ownerBadgeHtml(s) {
  const badge = ownerBadge(s.owner, s.id);
  return badge ? `<span class="owner ${badge.kind}" title="${escapeHtml(badge.title)}">${escapeHtml(badge.text)}</span>` : "";
}

function render() {
  renderTop(allSessions.slice(0, 3));
  if (allViewOpen()) renderAll();
}

function bindCards(container, onPick) {
  container.querySelectorAll(".card[data-id]").forEach((el) => {
    el.addEventListener("click", (e) => {
      const del = e.target.closest(".card-del");
      if (del) {
        e.stopPropagation();
        confirmDelete(del.dataset.del);
        return;
      }
      onPick(el.dataset.id);
    });
    if (selected && el.dataset.id === selected) el.classList.add("active");
  });
}

// The 3 latest sessions, then the way to all of them.
function renderTop(sessions) {
  topStripEl.classList.remove("loading");
  if (!sessions.length) {
    topStripEl.innerHTML = "";
    return;
  }
  const count = `${allSessions.length} ${allSessions.length === 1 ? "session" : "sessions"}`;
  const tile = `<div class="strip-side"><button type="button" class="card" id="allTile" title="All sessions, with search (/)">All sessions →<span class="count">${count}</span></button><button type="button" class="strip-toggle" id="stripHide" title="Hide the latest sessions">hide ▴</button></div>`;
  topStripEl.innerHTML = sessions.map(cardHtml).join("") + tile;
  bindCards(topStripEl, select);
  $("#allTile").addEventListener("click", openAllView);
  $("#stripHide").addEventListener("click", () => setStripHidden(true));
}

function renderAll() {
  const sessions = filteredSessions();
  $("#count").textContent = sessions.length === allSessions.length
    ? `${allSessions.length}`
    : `${sessions.length} / ${allSessions.length}`;
  if (!sessions.length) {
    allListEl.innerHTML = `<div class="hint">${allSessions.length ? "No session matches." : "No sessions yet."}</div>`;
    return;
  }
  allListEl.innerHTML = sessions.map((s) => cardHtml(s, { deletable: true })).join("");
  bindCards(allListEl, (id) => { leaveAllView(sessionHash(id)); select(id); });
}

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
    refresh();
    return;
  }
  allSessions = allSessions.filter((s) => s.id !== id);
  if (selected === id) clearSelection();
  render();
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
    topStripEl.scrollLeft = 0; // a phone's strip scrolls sideways to the tile
  }
  document.body.classList.toggle("all-view", open);
  if (open) {
    renderAll();
    refresh();
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

// While a turn runs, Send still sends: the prompt merges into the turn at
// its next step (steering). Cancel is its own button then.
function updateComposerMode() {
  document.body.classList.toggle("has-session", !!selected);
  const running = turnRunning && !!selected;
  cancelBtn.style.display = running ? "" : "none";
  if (running) {
    setPlaceholder("Running… a message now steers this turn (Enter to send)", "Running… a message steers it");
    actionBtn.textContent = "Send";
    createAltBtn.style.display = "none";
    actionMenuBtn.style.display = "none";
    actionMenu.classList.remove("visible");
    emptyEl.classList.add("hidden");
    return;
  }
  if (!selected) {
    setPlaceholder("New session prompt — press Enter to create (Shift+Enter for newline)", "New session prompt");
    actionBtn.textContent = "Create";
    actionBtn.disabled = false;
    createAltBtn.style.display = "none";
    actionMenuBtn.style.display = "none";
    actionMenu.classList.remove("visible");
    emptyEl.classList.remove("hidden");
    historyEl.innerHTML = "";
    updateInfoBar();
  } else if (currentOwner === "tui") {
    setPlaceholder("A terminal chi owns this session and doesn't share it — run it with chi --shared to send from here", "A terminal chi owns this session");
    actionBtn.textContent = "Send";
    actionBtn.disabled = true;
    createAltBtn.style.display = "inline-block";
    createAltBtn.textContent = "Create new";
    actionMenuBtn.style.display = "none";
    emptyEl.classList.add("hidden");
  } else {
    setPlaceholder("Send a message… (Enter to send, Shift+Enter for newline)", "Send a message…");
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
  setSessionHash(null);
  document.querySelectorAll(".card").forEach((el) => el.classList.remove("active"));
  currentFirstPreview = "";
  currentUsedMemories = [];
  currentCtxPct = null;
  currentCtxWindow = null;
  currentStatus = "";
  currentModel = "";
  currentServed = null;
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
  setSessionHash(id);
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
  currentServed = null;
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
  continueCardEl = null;
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
  selectSeq = typeof data.last_event_seq === "number" ? (data.last_event_id || data.last_event_seq) : null;
  if (selectSeq !== null) startStream(id, selectSeq);
  else startWorkerWatch(id);
}

// No worker: a turn or command another client sends wakes one, and only a
// stream would show it. Poll until a worker is live, then render and stream
// from it.
function startWorkerWatch(id) {
  stopWorkerWatch();
  workerWatch = watchForWorker(id, {
    onLive: () => {
      workerWatch = null;
      if (id === selected && !streamControl?.live) resync();
    },
  });
}

function stopWorkerWatch() {
  if (workerWatch) workerWatch.stop();
  workerWatch = null;
}

// A session view: its messages, then the turn in progress and the queued
// prompts (a live worker's snapshot) replayed through the stream handlers,
// then a pending question.
function renderSessionView(data) {
  const s = data.session;
  setMarkdownWarning(data.markdown_warning);
  currentStatus = s.status;
  currentModel = s.model_name;
  currentServed = s.served_model ? [s.served_model, s.served_model_for] : null;
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
  // A guardrail file that failed to load, announced before this page joined.
  showGuardrailWarning(data.guardrail_warning);
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
  // A turn ran out of iterations and waits for a yes or no.
  if (data.continue_offer) renderContinueCard(data.continue_offer);
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
    const timedTurns = timedTurnIndexes(items);
    historyEl.innerHTML = items
      .map((m, i) => {
        if (m.role === "note") return `<div class="bubble note">${noteHtml(m)}</div>`;
        const turnIndex = timedTurns[i];
        const cls = m.role === "user" ? "user" : "output";
        const { body, renderedMarkdown } = messageBodyHtml(m);
        const markdown = renderedMarkdown ? " markdown" : "";
        const record = turnIndex === null ? null : turnRecordAt(currentTiming, turnIndex);
        const timingHtml = record && formatDuration(record.duration_ms)
          ? `<div class="turn-timing">turn ${turnIndex + 1} · ${escapeHtml(formatDuration(record.duration_ms))}</div>`
          : "";
        // A user bubble is a flex row (label, text, badge): its text sits in
        // one block so quotes stack instead of lining up side by side.
        const inner = m.role === "user" ? `<div class="user-message">${body}${thumbsHtml(selected, m.images)}</div>` : body;
        return `<div class="bubble ${cls}${markdown}">${inner}${timingHtml}</div>`;
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
  appendToHistory(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

function ensureStreamingBubble() {
  if (streamingBubble) return streamingBubble;
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  streamingBubble = document.createElement("div");
  streamingBubble.className = "bubble output streaming";
  streamingBubble.textContent = "";
  appendToHistory(streamingBubble);
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
    appendToHistory(details);
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
  appendToHistory(div);
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

const BADGES = { queued: "queued", steered: "steered", failed: "failed" };

function makeUserBubble(prompt, { state = null, label = null, enqueuedId = null, own = false, images = null } = {}) {
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
  const message = document.createElement("div");
  message.className = "user-message";
  message.innerHTML = userBodyHtml(prompt) + thumbsHtml(selected, images);
  div.appendChild(message);
  setBubbleState(div, state);
  const follow = isNearBottom();
  appendToHistory(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
  return div;
}

function setBubbleState(bubble, state) {
  bubble.classList.remove("queued", "steered", "failed");
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
      makeUserBubble(op.prompt, { state: op.state, label: op.label, enqueuedId: op.enqueuedId, images: op.images });
    } else if (op.op === "tag") {
      if (bubbleById(op.enqueuedId)) continue;
      const echo = untaggedOwnBubble(op.prompt);
      if (echo) echo.dataset.enqueuedId = op.enqueuedId;
      // Re-rendered from a snapshot: the echo is gone, the prompt still queued.
      else makeUserBubble(op.prompt, { state: "queued", own: true, enqueuedId: op.enqueuedId, images: op.images });
    } else if (op.op === "start") {
      const bubble = bubbleById(op.enqueuedId) || untaggedOwnBubble(op.prompt);
      // A resync (a new worker woken by this page's send) re-rendered the
      // history and took the echo with it: draw the prompt again.
      if (!bubble) makeUserBubble(op.prompt, { own: true, enqueuedId: op.enqueuedId, images: op.images });
      else {
        if (op.enqueuedId) bubble.dataset.enqueuedId = op.enqueuedId;
        setBubbleState(bubble, null);
      }
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
  appendToHistory(details);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

// A guardrail hook or rule file that failed to load (once per worker).
function showGuardrailWarning(text) {
  if (!text) return;
  const el = document.createElement("div");
  el.className = "bubble guardrail-warning";
  el.textContent = `guardrails: ${text}`;
  const follow = isNearBottom();
  appendToHistory(el);
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
  // The image a tool read, live only (the reloaded history has no tool rows).
  if (row.images?.length && !el.querySelector(".thumbs")) el.insertAdjacentHTML("beforeend", thumbsHtml(selected, row.images));
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

// The info bar's "copy chi --attach": the full id, which the page shows
// only short; "copied ✓" for 2 s.
let attachCopiedAt = 0;
infoTextEl.addEventListener("click", async (e) => {
  if (!e.target.closest(".copy-attach") || !selected) return;
  if (!(await copyText(`chi --attach ${selected}`))) return;
  attachCopiedAt = Date.now();
  updateInfoBar();
  setTimeout(updateInfoBar, 2000);
});

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch (_) {
    // No Clipboard API (an insecure origin): the old way.
    const area = document.createElement("textarea");
    area.value = text;
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand("copy");
    area.remove();
    return ok;
  }
}

function updateInfoBar() {
  const stopBtn = document.getElementById("infoStopBtn");
  const deleteBtn = document.getElementById("infoDeleteBtn");
  if (deleteBtn) deleteBtn.style.display = selected ? "" : "none";
  if (!selected) {
    infoTextEl.innerHTML = `<div class="idle">No session selected — pick one above, or type a prompt to start a new session.</div><div class="idle"><small>Sessions are stored in <code>${escapeHtml(document.body.dataset.sessionsDir || "")}</code></small></div>`;
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
  const label = modelLabel(currentModel, ...(currentServed || []));
  const attachCmd = `chi --attach ${selected}`;
  const copied = Date.now() - attachCopiedAt < 2000;
  const copyHtml = `<button type="button" class="copy-attach" title="Copy &quot;${escapeHtml(attachCmd)}&quot; to attach a terminal">${copied ? "copied ✓" : "copy chi --attach"}</button>`;
  const metaHtml = `<div class="meta"><span class="id" title="${escapeHtml(selected)}">${escapeHtml(idShort)}</span>${copyHtml}<span class="${statusClass}">${escapeHtml(currentStatus||"")}</span><span class="model${label.mismatch ? " served-mismatch" : ""}" title="${escapeHtml(label.title)}">${escapeHtml(label.text)}</span><span class="dir" title="${escapeHtml(currentDir||"")}">${escapeHtml((currentDir||"").slice(0,48))}</span>${ctxText ? `<span class="model">${escapeHtml(ctxText)}</span>` : ""}${timingText ? `<span class="model">${escapeHtml(timingText)}</span>` : ""}</div>`;
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

function appendToHistory(el) {
  appendAboveLiveTiming(historyEl, el, liveTurnTimingEl);
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

function startStream(id, fromSeq) {
  stopWorkerWatch();
  if (streamControl) {
    streamControl.close();
    streamControl = null;
  }
  streamControl = openStream(id, fromSeq, streamHandlers, {
    // The stream dropped or never opened: the worker left (idle exit, stop,
    // crash) or is starting. Its cursor means nothing to the next worker
    // (event_seq starts over), so re-read the session once one is live.
    onStreamClosed: () => {
      streamControl = null;
      if (id === selected) startWorkerWatch(id);
    },
    onStreamError: () => {
      streamControl = null;
      if (id === selected) startWorkerWatch(id);
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
  generation_completed: (data) => {
    if (data?.served_model) {
      currentServed = [data.served_model, data.requested_model];
      updateInfoBar();
    }
    finalizeStreaming();
  },
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
  // The turn raised (e.g. the model server stayed unreachable). The worker
  // stays up: it rolls the turn back and hands the prompt back
  // (prompt_restored), and the prompts queued behind it run as usual.
  turn_failed: (data) => {
    endTurnView();
    setLiveStatus("idle");
    lastFailedText = failedTurnText(data);
    addEndBubble(lastFailedText);
  },
  // The rolled-back turn left the session: render it from the server again,
  // then show the prompt once more, marked failed (with why). This tab's own
  // prompt goes back into an empty composer.
  prompt_restored: async (data) => {
    const { refill, label, images: restoredImages } = restoreAction(data, { myId: clientId, sentIds, composerEmpty: !promptEl.value.trim() && !chips.length });
    if (refill) promptEl.value = refill;
    if (restoredImages?.length) setChips(restoredChips(selected, restoredImages));
    const failedText = lastFailedText;
    lastFailedText = null;
    await resync();
    // Not an echo waiting for its turn_enqueued: it keeps its enqueued_id, so
    // a resend's echo isn't matched to it.
    makeUserBubble(data.prompt || "", { state: "failed", label, enqueuedId: data.origin?.enqueued_id || `failed:${Date.now()}`, images: data.images });
    if (failedText) addEndBubble(failedText);
  },
  // A session command ran in the worker (any client's). One that changed
  // the conversation (!rollback, !cmd, a continue answered no) re-reads it.
  command_ran: async (data) => {
    const view = commandView(data, clientId);
    if (view.modelName && view.modelName !== currentModel) {
      currentModel = view.modelName;
      currentServed = null;
      updateInfoBar();
    }
    if (view.resync) await resync();
    addCommandBubble(view);
  },
  // Due reminders went into the turn (a reminder turn has no prompt bubble).
  reminder_injected: (data) => addCommandBubble({ label: null, line: reminderText(data), text: "" }),
  // A context note joined the conversation (between turns; no turn runs).
  context_added: (data) => addNoteBubble({ label: data.label, content: data.text || "" }),
  continue_offered: (data) => renderContinueCard(data),
  continue_resolved: (data) => resolveContinueCard(data),
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
  guardrail_warning: (data) => showGuardrailWarning(data.message),
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

  const approval = approvalView(pq);
  const card = document.createElement("div");
  card.className = approval ? "bubble question approval" : "bubble question";
  card.dataset.qid = pq.id;

  if (pq.header) {
    const head = document.createElement("div");
    head.className = "question-header";
    head.textContent = pq.header;
    card.appendChild(head);
  }

  if (approval) {
    card.appendChild(renderApprovalDetails(approval));
  } else {
    const q = document.createElement("div");
    q.className = "question-text";
    q.textContent = pq.question || "";
    card.appendChild(q);
  }

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
    freeformInput.placeholder = approval ? "Reason for the model (with Deny, or alone to deny)…" : "Other…";
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

  // Leaves the question unanswered, like an empty answer in the terminal.
  // The card closes on the question_cancelled every client gets.
  // For an approval, dismissing denies the call.
  const dismiss = document.createElement("button");
  dismiss.className = "question-dismiss ghost";
  dismiss.textContent = approval ? "Deny" : "Dismiss";
  dismiss.addEventListener("click", () => {
    err.classList.add("hidden");
    submit.disabled = true;
    dismiss.disabled = true;
    dismissQuestion(selected, pq.id).catch((e) => {
      submit.disabled = false;
      dismiss.disabled = false;
      err.textContent = /503|not_live/.test(e.message)
        ? "Session is not running — restart it to answer."
        : e.message;
      err.classList.remove("hidden");
    });
  });
  card.appendChild(dismiss);

  appendToHistory(card);
  questionCardEl = card;
  if (isNearBottom()) historyEl.scrollTop = historyEl.scrollHeight;
}

// The tool, the command (or paths) as code, where and why.
function renderApprovalDetails(view) {
  const box = document.createElement("div");
  box.className = "approval-details";
  const tool = document.createElement("div");
  tool.className = "approval-tool";
  tool.textContent = view.tool;
  box.appendChild(tool);
  const what = document.createElement("pre");
  what.className = view.isCommand ? "approval-what command" : "approval-what paths";
  const code = document.createElement("code");
  code.textContent = view.what;
  what.appendChild(code);
  box.appendChild(what);
  for (const [cls, label, text] of [["approval-where", "in", view.where], ["approval-why", "why", view.why]]) {
    if (!text) continue;
    const row = document.createElement("div");
    row.className = cls;
    const b = document.createElement("span");
    b.className = "approval-label";
    b.textContent = `${label} `;
    row.appendChild(b);
    row.appendChild(document.createTextNode(text));
    box.appendChild(row);
  }
  return box;
}

function resolveQuestionCard(id, { answer = null, cancelled = false, reason = "" } = {}) {
  if (!questionCardEl) return;
  if (id && pendingQuestion && String(pendingQuestion.id) !== String(id)) return;

  const note = document.createElement("div");
  note.className = "question-result";
  note.textContent = resultText(pendingQuestion, { answer, cancelled, reason });
  if (cancelled) {
    questionCardEl.classList.add("cancelled");
  } else {
    questionCardEl.classList.add("answered");
    if (approvalAllowed(pendingQuestion, answer) === false) questionCardEl.classList.add("denied");
    markQuestionSelection(answer && Array.isArray(answer.selected) ? answer.selected : []);
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
  stopWorkerWatch();
  if (streamControl) {
    streamControl.close();
    streamControl = null;
  }
}

async function handleCreate() {
  // A first message with images: an idle session, then the turn into it.
  if (chips.length) return handleSendTurn();
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
  if (!selected && !chips.length) return handleCreate();
  if (currentOwner === "tui") return;
  const prompt = turnText(promptEl.value, chips);
  if (!prompt) return;
  if (!chips.length && isCommandLine(prompt)) return handleSendCommand(prompt);
  if (!selected) {
    actionBtn.disabled = true;
    try {
      const s = await createIdleSession();
      await refresh();
      await select(s.id);
    } catch (e) {
      alert(e.message);
      return;
    } finally {
      actionBtn.disabled = false;
    }
  }
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  const sending = chips.slice();
  const echo = makeUserBubble(prompt, { state: "queued", own: true, images: sending });
  historyEl.scrollTop = historyEl.scrollHeight;
  if (!currentFirstPreview || currentFirstPreview==="—") {
    currentFirstPreview = normalize(prompt).slice(0,80) + (normalize(prompt).length>80?"…":"");
    updateInfoBar();
    updateFirstPeek();
  }
  actionBtn.disabled = true;
  try {
    for (const chip of sending) {
      if (!chip.ref) chip.ref = await uploadImage(selected, chip.file, chip.name);
    }
    const ack = await sendTurn(selected, prompt, { clientId, images: turnRefs(sending) });
    promptEl.value = "";
    clearChips();
    // Its turn_enqueued usually tagged the echo already; the ack covers a
    // worker that wasn't live (no turn_enqueued then).
    if (ack?.enqueued_id) sentIds.add(ack.enqueued_id);
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
    // The chips stay (uploaded ones keep their ref) for another try.
    if (/images_unsupported|bad_image|too_large|restart it/.test(e.message)) {
      alert(e.message);
      return;
    }
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

// /model, !ls, /continue no … run in the session's worker; every client
// shows the command_ran, this one too.
async function handleSendCommand(line) {
  actionBtn.disabled = true;
  try {
    await sendCommand(selected, line, { clientId });
    promptEl.value = "";
    // The command woke the worker: follow its stream if none is open.
    if (!streamControl?.live) startStream(selected, selectSeq ?? 0);
  } catch (e) {
    if (/owned_by_tui|409/.test(e.message)) {
      currentOwner = "tui";
      updateComposerMode();
      return;
    }
    addCommandBubble({ label: null, line, text: e.message, failed: true });
  } finally {
    actionBtn.disabled = currentOwner === "tui";
    promptEl.focus();
  }
}

function addCommandBubble({ label, line, text, busy = false, failed = false }) {
  removeHintIfEmpty();
  const div = document.createElement("div");
  div.className = "bubble command" + (busy ? " busy" : "") + (failed ? " failed" : "");
  const head = document.createElement("div");
  head.className = "command-line";
  head.textContent = label ? `${label}> ${line}` : line;
  div.appendChild(head);
  if (text) {
    const body = document.createElement("pre");
    body.className = "command-output";
    body.textContent = text;
    div.appendChild(body);
  }
  const follow = isNearBottom();
  appendToHistory(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

function addNoteBubble(note) {
  removeHintIfEmpty();
  const div = document.createElement("div");
  div.className = "bubble note";
  div.innerHTML = noteHtml(note);
  const follow = isNearBottom();
  appendToHistory(div);
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

// ── continue card ──────────────────────────────────────────────────────────
// A turn ran out of iterations: continue it, drop it, or drop it saying why
// (the terminal's continue prompt). Answers go as /continue commands; the
// card closes on the continue_resolved every client gets.

const CONTINUE_DECISIONS = {
  resume: "Continued",
  abort: "Not continued",
  abort_with_reason: "Not continued (reason noted)",
  dropped: "Dropped: a new prompt came",
};

function renderContinueCard(offer) {
  if (continueCardEl?.isConnected) return;
  removeHintIfEmpty();
  const card = document.createElement("div");
  card.className = "bubble continue";
  const text = document.createElement("div");
  text.className = "continue-text";
  text.textContent = "The turn ran out of iterations. Continue it?";
  card.appendChild(text);
  const task = offer?.context?.original_prompt;
  if (task) {
    const ctx = document.createElement("div");
    ctx.className = "continue-context";
    ctx.textContent = task;
    card.appendChild(ctx);
  }
  const err = document.createElement("div");
  err.className = "question-error hidden";
  const answer = (line) => {
    err.classList.add("hidden");
    card.querySelectorAll("button, input").forEach((el) => { el.disabled = true; });
    sendCommand(selected, line, { clientId }).catch((e) => {
      card.querySelectorAll("button, input").forEach((el) => { el.disabled = false; });
      err.textContent = e.message;
      err.classList.remove("hidden");
    });
  };
  const yes = document.createElement("button");
  yes.className = "continue-yes";
  yes.textContent = "Yes";
  yes.addEventListener("click", () => answer(continueLine("yes")));
  const no = document.createElement("button");
  no.className = "continue-no ghost";
  no.textContent = "No";
  no.addEventListener("click", () => answer(continueLine("no")));
  const reason = document.createElement("input");
  reason.type = "text";
  reason.className = "continue-reason";
  reason.placeholder = "Why not? (the model reads it)";
  const noBecause = document.createElement("button");
  noBecause.className = "continue-no-reason ghost";
  noBecause.textContent = "No, because…";
  noBecause.addEventListener("click", () => {
    if (!reason.value.trim()) return reason.focus();
    answer(continueLine("no", reason.value));
  });
  const row = document.createElement("div");
  row.className = "continue-actions";
  [yes, no, reason, noBecause].forEach((el) => row.appendChild(el));
  card.appendChild(row);
  card.appendChild(err);
  const follow = isNearBottom();
  appendToHistory(card);
  continueCardEl = card;
  if (follow) historyEl.scrollTop = historyEl.scrollHeight;
}

function resolveContinueCard(data) {
  const card = continueCardEl;
  continueCardEl = null;
  if (!card) return;
  card.classList.add("resolved");
  card.querySelectorAll("button, input").forEach((el) => { el.disabled = true; });
  const note = document.createElement("div");
  note.className = "question-result";
  const who = isOwn(data.client_id, clientId) ? "" : ` (${clientLabel(data.client_id) || "another client"})`;
  note.textContent = (CONTINUE_DECISIONS[data.decision] || data.decision || "Answered") + who;
  card.appendChild(note);
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
if (_refreshBtn) _refreshBtn.addEventListener("click", () => { refresh(); updateComposerMode(); });
// The chi logo: back to the empty start, where the composer makes a new
// session (from all sessions too).
$("#newBtn").addEventListener("click", () => {
  if (allViewOpen()) leaveAllView("");
  clearSelection();
});
actionBtn.addEventListener("click", () => {
  if (!selected) handleCreate();
  else handleSendTurn();
});

// ── Images: paste or drop into the composer, chips until sent ─────────────
const chipsEl = $("#chips");
const lightboxEl = $("#lightbox");
let chips = [];

function renderChips() {
  chipsEl.innerHTML = chipsHtml(chips);
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
historyEl.addEventListener("click", (e) => {
  const img = e.target.closest("img.thumb");
  if (!img) return;
  lightboxEl.querySelector("img").src = img.src;
  lightboxEl.hidden = false;
});
lightboxEl.addEventListener("click", () => { lightboxEl.hidden = true; });
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !lightboxEl.hidden) lightboxEl.hidden = true;
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
$("#infoDeleteBtn").addEventListener("click", () => {
  if (selected) confirmDelete(selected);
});

// ── Annotate ───────────────────────────────────────────────────────────────
// Selecting text in an answer, thinking, a tool row or an own message shows
// "Annotate"; it appends the quote (with where it came from) to the
// composer. The button lives outside #history, which is re-rendered whole.
// The selection is read when it changes: a live bubble rewrites its text
// every frame, which would collapse it by the time the button is clicked.

const annotateBtn = document.createElement("button");
annotateBtn.id = "annotateBtn";
annotateBtn.type = "button";
annotateBtn.textContent = "Annotate";
annotateBtn.hidden = true;
document.body.appendChild(annotateBtn);
let pendingQuote = null;

function hideAnnotate() {
  pendingQuote = null;
  annotateBtn.hidden = true;
}

function updateAnnotate() {
  const sel = window.getSelection();
  if (!selected || currentOwner === "tui" || !sel || sel.isCollapsed || !sel.rangeCount) return hideAnnotate();
  const range = sel.getRangeAt(0);
  if (!historyEl.contains(range.startContainer)) return hideAnnotate();
  const source = annotationSource(range.startContainer);
  // A running turn's thinking is rewritten every frame.
  if (!source || (turnRunning && thinkingEl?.contains(source.root))) return hideAnnotate();
  // Clip to where the selection starts: one tool row, one bubble.
  const clipped = range.cloneRange();
  if (!source.root.contains(range.endContainer)) clipped.setEnd(source.root, source.root.childNodes.length);
  const block = quoteBlock(clipped.toString(), source);
  if (!block) return hideAnnotate();
  pendingQuote = block;
  const rects = clipped.getClientRects();
  const rect = rects.length ? rects[rects.length - 1] : clipped.getBoundingClientRect();
  annotateBtn.hidden = false;
  const top = Math.min(rect.bottom + 6, window.innerHeight - annotateBtn.offsetHeight - 8);
  const left = Math.min(Math.max(rect.right - annotateBtn.offsetWidth, 8), window.innerWidth - annotateBtn.offsetWidth - 8);
  annotateBtn.style.top = `${Math.max(top, 8)}px`;
  annotateBtn.style.left = `${left}px`;
}

let annotateRaf = false;
function scheduleAnnotate() {
  if (annotateRaf) return;
  annotateRaf = true;
  requestAnimationFrame(() => { annotateRaf = false; updateAnnotate(); });
}
document.addEventListener("selectionchange", scheduleAnnotate);
historyEl.addEventListener("scroll", scheduleAnnotate);
window.addEventListener("resize", scheduleAnnotate);
// Keep the selection when the button is pressed.
annotateBtn.addEventListener("mousedown", (e) => e.preventDefault());
annotateBtn.addEventListener("click", () => {
  if (!pendingQuote) return;
  promptEl.value = appendQuote(promptEl.value, pendingQuote);
  window.getSelection()?.removeAllRanges();
  hideAnnotate();
  promptEl.focus();
  promptEl.setSelectionRange(promptEl.value.length, promptEl.value.length);
  promptEl.scrollTop = promptEl.scrollHeight;
});

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
function setStripHidden(hidden) {
  try { localStorage.setItem("chi_strip_hidden", hidden ? "1" : "0"); } catch (_) {}
  document.body.classList.toggle("strip-hidden", hidden);
}
setStripHidden(stripHiddenSaved());
$("#stripShow").addEventListener("click", () => setStripHidden(false));
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && actionMenu.classList.contains("visible")) actionMenu.classList.remove("visible");
});

$("#filter").addEventListener("input", renderAll);
// "/" anywhere but a text field opens all sessions at the search; Esc leaves.
document.addEventListener("keydown", (e) => {
  const typing = e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA";
  if (e.key === "/" && !typing && !e.metaKey && !e.ctrlKey && !e.altKey) {
    e.preventDefault();
    openAllView();
  } else if (e.key === "Escape" && allViewOpen()) {
    closeAllView();
  }
});
applyView();

updateInfoBar();
updateComposerMode();
refresh();
selectFromHash();
