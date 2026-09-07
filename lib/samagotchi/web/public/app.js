import {
  listSessions,
  createSession,
  getSession,
  sendTurn,
  cancelTurn,
  stopSession,
  openStream,
} from "./data.js";
import { escapeHtml, normalize, previewForCard, firstMessageOf } from "./format.js";

const $ = (s) => document.querySelector(s);
const topStripEl = $("#topStrip");
const gridListEl = $("#gridList");
const historyEl = $("#history");
const emptyEl = $("#empty");
const composerEl = $("#composer");
const infoBarEl = $("#infoBar");
const firstPeekEl = $("#firstPeek");
const infoTextEl = $("#infoText");
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
let turnRunning = false;

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
    topStripEl.style.display = "none";
    return;
  }
  topStripEl.style.display = "grid";
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
    infoBarEl.classList.remove("visible");
    emptyEl.classList.remove("hidden");
    historyEl.innerHTML = "";
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
  setTurnRunning(false);
  closeStream();
  updateComposerMode();
  updateFirstPeek();
  promptEl.focus();
}

async function select(id) {
  selected = id;
  document.querySelectorAll(".card").forEach((el) =>
    el.classList.toggle("active", el.dataset.id === id),
  );
  setTurnRunning(false);
  infoBarEl.classList.add("visible");
  historyEl.innerHTML = `<div class="hint">Loading…</div>`;
  emptyEl.classList.add("hidden");
  closeStream();
  currentFirstPreview = "";
  currentUsedMemories = [];
  currentCtxPct = null;
  currentStatus = "";
  currentModel = "";
  currentDir = "";
  updateFirstPeek();
  updateInfoBar();
  updateComposerMode();
  try {
    const data = await getSession(id);
    const s = data.session;
    currentStatus = s.status;
    currentModel = s.model_name;
    currentDir = s.working_directory;
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
    updateInfoBar();
    updateFirstPeek();
    updateComposerMode();
    infoBarEl.classList.add("visible");
    seedSeenFromDom();
    startStream(id, data.last_event_seq);
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

function updateInfoBar() {
  if (!selected) return;
  const idShort = selected.slice(0,8);
  const memText = currentUsedMemories.length ? currentUsedMemories.join(", ") : "—";
  const ctxText = currentCtxPct !== null ? `ctx ${Math.round(currentCtxPct)}%` : "";
  const statusClass = currentStatus ? `status ${escapeHtml(currentStatus)}` : "status";
  const metaHtml = `<div class="meta"><span class="id">${escapeHtml(idShort)}</span><span class="${statusClass}">${escapeHtml(currentStatus||"")}</span><span class="model" title="${escapeHtml(currentModel||"")}">${escapeHtml((currentModel||"").slice(0,40))}</span><span class="dir" title="${escapeHtml(currentDir||"")}">${escapeHtml((currentDir||"").slice(0,48))}</span>${ctxText ? `<span class="model">${escapeHtml(ctxText)}</span>` : ""}</div>`;
  const previewHtml = `<div class="preview-line"><span class="preview">${escapeHtml(currentFirstPreview || "—")}</span> · <span class="mem" title="${escapeHtml(currentUsedMemories.join(", "))}">mem: ${escapeHtml(memText)}</span></div>`;
  infoTextEl.innerHTML = metaHtml + previewHtml;
  infoTextEl.title = `memories: ${currentUsedMemories.join(", ") || "—"}`;
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
      const c = data.content || data.text || data.payload?.content || "";
      if (typeof c === "string" && c) appendToken(c);
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
    turn_started: (data) => {
      setTurnRunning(true);
      streamingBuffer = "";
      ensureStreamingBubble();
      if (data.prompt) streamingBubble.textContent = "…";
    },
    turn_completed: async (data) => {
      setTurnRunning(false);
      finalizeStreaming();
      const out = data.result ? data.result.output || "" : data.content || data.output || "";
      if (typeof out === "string" && out.trim()) appendChunk(out.trim());
      if (selected) {
        try {
          const d = await getSession(selected);
          if (d.session) {
            if (Array.isArray(d.session.used_memory_names)) currentUsedMemories = d.session.used_memory_names;
            if (d.session.status) currentStatus = d.session.status;
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
      addCancelBubble(data.cancellation_reason || "");
    },
    tool_call_started: (data) => {
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
    tool_call_completed: (data) => addToolBubble(data),
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
    reset: async (data) => {
      if (!selected) return;
      const seq = data && data.session_state_snapshot ? data.session_state_snapshot.event_seq : null;
      if (typeof seq === "number" && seq === fromSeq) return;
      closeStream();
      const d2 = await getSession(selected).catch(() => null);
      if (!d2) return;
      if (d2.session) {
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
  userDiv.className = "bubble user";
  userDiv.textContent = prompt;
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

updateComposerMode();
refresh();
