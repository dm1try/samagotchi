import {
  listSessions,
  createSession,
  getSession,
  sendTurn,
  cancelTurn,
  stopSession,
  openStream,
} from "./data.js";
import { escapeHtml, normalize, previewOf } from "./format.js";

const $ = (s) => document.querySelector(s);
const listEl = $("#list");
const historyEl = $("#history");
const emptyEl = $("#empty");
const composerEl = $("#composer");
const detailHead = $("#detailHead");

let selected = null;
let streamControl = null;
let allSessions = [];
let displayLimit = 100;
let streamingBubble = null;
let streamingBuffer = "";
let rafPending = false;
let seenContent = new Set();

// How many times to re-attempt a dropped stream before giving up: bounds the
// failure noise (failed /stream requests) and ends in a visible terminal state
// instead of retrying forever when a session worker is genuinely down.
const MAX_STREAM_RETRIES = 8;

function getSort() {
  try {
    return localStorage.getItem("chi_sort") || "updated_at";
  } catch (_) {
    return "updated_at";
  }
}
function getOrder() {
  try {
    return localStorage.getItem("chi_order") || "desc";
  } catch (_) {
    return "desc";
  }
}
function setSort(v) {
  try {
    localStorage.setItem("chi_sort", v);
  } catch (_) {}
}
function setOrder(v) {
  try {
    localStorage.setItem("chi_order", v);
  } catch (_) {}
}

async function refresh() {
  allSessions = await listSessions(getSort(), getOrder());
  renderList();
}

function filteredSessions() {
  const q = $("#filter").value.trim().toLowerCase();
  if (!q) return allSessions;
  return allSessions.filter(
    (s) =>
      previewOf(s.last_prompt).toLowerCase().includes(q) ||
      s.short_id.toLowerCase().includes(q) ||
      s.id.toLowerCase().includes(q) ||
      s.status.toLowerCase().includes(q),
  );
}

function rowHtml(s) {
  const ts = s.updated_at || s.created_at || "";
  const tip = `${s.id} · updated ${ts} · ${s.status}`;
  return `<div class="row" data-id="${s.id}" title="${escapeHtml(tip)}"><div class="meta"><div class="id">${s.short_id} · ${s.id.slice(0, 8)}</div><div class="preview">${escapeHtml(previewOf(s.last_prompt) || "\u2014")}</div></div><span class="status ${escapeHtml(s.status)}">${escapeHtml(s.status)}</span></div>`;
}

function renderList() {
  const sessions = filteredSessions();
  $("#count").textContent = sessions.length
    ? `${Math.min(sessions.length, displayLimit)} / ${sessions.length}`
    : "";
  if (!sessions.length) {
    listEl.innerHTML = `<div class="hint">No sessions yet. Create one.</div>`;
    return;
  }
  const slice = sessions.slice(0, displayLimit);
  let html = slice.map(rowHtml).join("");
  if (sessions.length > displayLimit) {
    html += `<div class="hint"><button class="ghost" id="showAll">Show all (${sessions.length})</button></div>`;
  }
  listEl.innerHTML = html;
  listEl.querySelectorAll(".row").forEach((el) => {
    el.addEventListener("click", () => select(el.dataset.id));
    if (selected && el.dataset.id === selected) el.classList.add("active");
  });
  const btn = $("#showAll");
  if (btn) btn.addEventListener("click", () => { displayLimit = sessions.length; renderList(); });
}

async function select(id) {
  selected = id;
  document.querySelectorAll(".row").forEach((el) =>
    el.classList.toggle("active", el.dataset.id === id),
  );
  emptyEl.style.display = "none";
  composerEl.style.display = "flex";
  detailHead.style.display = "flex";
  historyEl.innerHTML = `<div class="hint">Loading\u2026</div>`;
  closeStream();
  try {
    const data = await getSession(id);
    const s = data.session;
    $("#detailId").textContent = s.short_id + " · " + s.id;
    $("#detailStatus").textContent = s.status;
    $("#detailStatus").className = "badge status " + s.status;
    $("#detailDir").textContent = s.working_directory;
    $("#detailModel").textContent = s.model_name;
    if (data.messages && data.messages.length) {
      renderHistory(data.messages);
    } else {
      renderHistory(data.history || []);
    }
    seedSeenFromDom();
    startStream(id, data.last_event_seq);
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
    historyEl.innerHTML = items
      .map((m) => {
        const cls = m.role === "user" ? "user" : "output";
        return `<div class="bubble ${cls}">${escapeHtml(m.content)}</div>`;
      })
      .join("");
  } else {
    historyEl.innerHTML = items.map((c) => `<div class="bubble output">${escapeHtml(c)}</div>`).join("");
  }
  historyEl.scrollTop = historyEl.scrollHeight;
}

function seedSeenFromDom() {
  seenContent = new Set();
  historyEl.querySelectorAll(".bubble").forEach((b) => {
    const k = normalize(b.textContent);
    if (k) seenContent.add(k);
  });
}

function appendChunk(text) {
  if (!text) return;
  const k = normalize(text);
  if (!k || seenContent.has(k)) return;
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  const div = document.createElement("div");
  div.className = "bubble output";
  div.textContent = text;
  historyEl.appendChild(div);
  historyEl.scrollTop = historyEl.scrollHeight;
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
  if (!streamingBubble) return;
  streamingBubble.textContent = streamingBuffer;
  historyEl.scrollTop = historyEl.scrollHeight;
}

function appendToken(content) {
  if (!content) return;
  streamingBuffer += content;
  ensureStreamingBubble();
  if (!rafPending) {
    rafPending = true;
    requestAnimationFrame(flushStreaming);
  }
}

function finalizeStreaming() {
  if (streamingBubble) {
    const k = normalize(streamingBuffer);
    if (k) seenContent.add(k);
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

function addToolBubble(data) {
  const act = data.activity || {};
  const line = `tool> ${act.action || data.tool || "tool"}: ${act.status || "ok"}`;
  const div = document.createElement("div");
  div.className = "bubble tool";
  div.textContent = line;
  historyEl.appendChild(div);
  historyEl.scrollTop = historyEl.scrollHeight;
}

function startStream(id, fromSeq, retryDelay = 2000, attempts = 0) {
  if (streamControl) {
    streamControl.close();
    streamControl = null;
  }
  streamControl = openStream(id, fromSeq, {
    generation_chunk: (data) => {
      const c = data.content || data.text || "";
      if (typeof c === "string" && c) appendToken(c);
    },
    generation_started: () => {
      streamingBuffer = "";
      ensureStreamingBubble();
    },
    generation_completed: () => finalizeStreaming(),
    turn_started: (data) => {
      streamingBuffer = "";
      ensureStreamingBubble();
      if (data.prompt) streamingBubble.textContent = "\u2026";
    },
    turn_completed: (data) => {
      finalizeStreaming();
      const out = data.result ? data.result.output || "" : data.content || data.output || "";
      if (typeof out === "string" && out.trim()) appendChunk(out.trim());
    },
    turn_canceled: (data) => {
      finalizeStreaming();
      addCancelBubble(data.cancellation_reason || "");
    },
    tool_call_completed: (data) => addToolBubble(data),
    reset: async (data) => {
      // Ring overflow / stale replay window: server dropped our cursor. Re-sync
      // by re-fetching the session snapshot, then resume streaming live. Guard:
      // ignore a reset that carries the very cursor we are already streaming
      // from (nothing new to fetch) — otherwise caught-up reconnects loop.
      if (!selected) return;
      const seq = data && data.session_state_snapshot ? data.session_state_snapshot.event_seq : null;
      if (typeof seq === "number" && seq === fromSeq) return;
      closeStream();
      const data2 = await getSession(selected).catch(() => null);
      if (!data2) return;
      if (data2.messages && data2.messages.length) renderHistory(data2.messages);
      seedSeenFromDom();
      startStream(selected, data2.last_event_seq);
    },
  }, {
    onStreamError: () => {
      // Stream connection died before any event: bridge not ready yet on a
      // resume, or the proxy dropped it. EventSource was closed by data.js —
      // retry with backoff a bounded number of times, then surface a visible
      // terminal error instead of retrying forever.
      streamControl = null;
      if (id !== selected) return;
      if (attempts < MAX_STREAM_RETRIES) {
        setTimeout(() => startStream(id, fromSeq, Math.min(retryDelay * 1.5, 10000), attempts + 1), retryDelay);
      } else {
        historyEl.innerHTML = `<div class="hint">Stream unavailable\u2014the session worker may have stopped. <button class="ghost" id="streamRetry">Retry</button></div>`;
        const btn = $("#streamRetry");
        if (btn) btn.addEventListener("click", () => select(id));
      }
    },
  });
}

function closeStream() {
  streamingBubble = null;
  streamingBuffer = "";
  rafPending = false;
  if (streamControl) {
    streamControl.close();
    streamControl = null;
  }
}

async function handleCreate() {
  const prompt = $("#newPrompt").value.trim();
  if (!prompt) return;
  $("#create").disabled = true;
  try {
    const s = await createSession(prompt);
    await refresh();
    select(s.id);
    $("#newPrompt").value = "";
  } catch (e) {
    alert(e.message);
  } finally {
    $("#create").disabled = false;
  }
}

async function handleSendTurn() {
  if (!selected) return;
  const ta = $("#prompt");
  const prompt = ta.value.trim();
  if (!prompt) return;
  const hint = historyEl.querySelector(".hint");
  if (hint) hint.remove();
  finalizeStreaming();
  const userDiv = document.createElement("div");
  userDiv.className = "bubble user";
  userDiv.textContent = prompt;
  historyEl.appendChild(userDiv);
  historyEl.scrollTop = historyEl.scrollHeight;
  $("#send").disabled = true;
  try {
    await sendTurn(selected, prompt);
    ta.value = "";
  } catch (e) {
    alert(e.message);
  } finally {
    $("#send").disabled = false;
    ta.focus();
  }
}

$("#refresh").addEventListener("click", () => { displayLimit = 100; refresh(); });
$("#create").addEventListener("click", handleCreate);
$("#newPrompt").addEventListener("keydown", (e) => { if (e.key === "Enter") handleCreate(); });
$("#newBtn").addEventListener("click", () => $("#newPrompt").focus());
$("#send").addEventListener("click", handleSendTurn);
$("#prompt").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    handleSendTurn();
  }
});
$("#stopBtn").addEventListener("click", async () => {
  if (!selected) return;
  if (!confirm(`Stop session ${selected}?`)) return;
  await stopSession(selected);
  refresh();
});
$("#cancelBtn").addEventListener("click", async () => {
  if (!selected) return;
  $("#cancelBtn").disabled = true;
  try {
    await cancelTurn(selected);
  } catch (e) {
    alert(e.message);
  } finally {
    $("#cancelBtn").disabled = false;
  }
});

(() => {
  const sortSel = $("#sortSel");
  const orderBtn = $("#orderBtn");
  const filterEl = $("#filter");
  sortSel.value = getSort();
  function updateOrderBtn() {
    const o = getOrder();
    orderBtn.textContent = o === "desc" ? "\u2193 Desc" : "\u2191 Asc";
  }
  updateOrderBtn();
  sortSel.addEventListener("change", () => { setSort(sortSel.value); displayLimit = 100; refresh(); });
  orderBtn.addEventListener("click", () => {
    const nxt = getOrder() === "desc" ? "asc" : "desc";
    setOrder(nxt);
    updateOrderBtn();
    displayLimit = 100;
    refresh();
  });
  filterEl.addEventListener("input", () => { displayLimit = 100; renderList(); });
})();

refresh();