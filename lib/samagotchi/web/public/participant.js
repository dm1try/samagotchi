// The participant page (participant.html): a participant's review of one
// session, or the owner's participant view of it (/?as=participant#s=<id>,
// no composer). Everything comes through chi web's participant filter:
// GET /api/sessions/:id/review (the data) and the filtered stream; the
// page re-reads its data at every turn boundary and draws the turn in
// progress from the stream in between. A participant's comment is
// POST …/turn (text only); their queued ones come back with Dequeue.
import {
  authorColor, authorLabel, toolLine, toolsSummary, refusalText, endedText, streamURL, reloads, liveFrom, applyLive,
  liveText, withToolSteps, pickSubject, subjectBody, subjectsKey, narrowView, retryDelay, retries,
} from "./participant_model.js";

const $ = (id) => document.getElementById(id);
const body = document.body.dataset;
const ownerView = body.viewer === "owner";
const sessionId = body.session || new URLSearchParams(location.hash.slice(1)).get("s") || "";
const phone = window.matchMedia("(max-width: 640px)");

let data = null;
let live = null;
let source = null;
let reloadTimer = null;
let retryTimer = null;
// Reads of the review that failed in a row (the retry's backoff), and the
// latest read asked for (an older one answering after it is dropped).
let failures = 0;
let loadSeq = 0;
let ended = false;
// The Plan view: the subject picked, what it last drew, and which view a
// narrow screen shows (the thread first).
let subjectPath = null;
let planDrawn = null;
let wantedView = "thread";

function el(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
}

// A request's answer; a network failure is status 0 (the page says it
// can't reach the session), never a throw.
async function api(path, options = {}) {
  let res;
  try {
    res = await fetch(path, { credentials: "same-origin", ...options });
  } catch {
    return { status: 0, ok: false, body: null };
  }
  let json = null;
  try { json = await res.json(); } catch { json = null; }
  if (res.status === 401) showEnded(json);
  return { status: res.status, ok: res.ok, body: json };
}

function showEnded(json) {
  if (ended) return;
  ended = true;
  source?.close();
  for (const id of ["head", "main", "dock", "plan"]) $(id).hidden = true;
  $("endedText").textContent = endedText(json);
  $("ended").hidden = false;
  document.title = "chi · review link ended";
}

// Reads the review data, draws it and streams from it. One that can't be
// read (unreachable, a 5xx) keeps what the page shows, says it is
// retrying, and reads again with a backoff.
async function load() {
  if (!sessionId) return showEnded(null);
  const seq = ++loadSeq;
  const { ok, status, body: json } = await api(`/api/sessions/${encodeURIComponent(sessionId)}/review`);
  if (ended || seq !== loadSeq) return;
  if (!ok) {
    $("head").hidden = false;
    if (!data) $("title").textContent = "Review";
    $("offline").hidden = !retries(status);
    if (retries(status)) {
      scheduleRetry(retryDelay(failures++));
    } else {
      $("note").textContent = status === 404 ? "This session is gone." : `The review couldn't be read (HTTP ${status}).`;
    }
    return;
  }
  failures = 0;
  $("offline").hidden = true;
  data = json;
  live = liveFrom(data.current_turn);
  render();
  // The live turn is the data's now: the events after its cursor come
  // again from there (the open stream may have delivered some of them to
  // the live turn just replaced). With no cursor (no worker) an open
  // stream stays.
  if (data.last_event_id || !source || source.readyState === EventSource.CLOSED) connect();
}

function scheduleRetry(delay) {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(load, delay);
}

function scheduleReload() {
  clearTimeout(reloadTimer);
  reloadTimer = setTimeout(load, 120);
}

// The stream from the review data's cursor; a closed or refused stream is
// opened again from fresh data (a worker may have started or restarted).
function connect() {
  if (ended || !data) return;
  clearTimeout(retryTimer);
  source?.close();
  source = new EventSource(streamURL(sessionId, data.last_event_id, { owner: ownerView }));
  source.onmessage = () => {};
  const onEvent = (event) => {
    let parsed;
    try { parsed = JSON.parse(event.data); } catch { return; }
    if (reloads(parsed.type)) return scheduleReload();
    const next = applyLive(live, parsed);
    if (next !== live) {
      live = next;
      renderLive();
    }
  };
  for (const type of ["generation_chunk", "generation_retrying", "tool_call_started", "tool_call_completed",
    "turn_started", "turn_completed", "turn_canceled", "turn_failed", "turn_enqueued", "turn_dequeued", "input_merged",
    "question_requested", "question_answered", "question_cancelled", "continue_offered", "continue_resolved",
    "snapshot", "reset"]) {
    source.addEventListener(type, onEvent);
  }
  source.onerror = () => {
    if (source.readyState !== EventSource.CLOSED) return;
    scheduleRetry(retryDelay(failures));
  };
}

function render() {
  const viewer = data.viewer || {};
  const session = data.session || {};
  document.title = ownerView ? `chi · participant view · ${session.title}` : `chi · ${viewer.name}'s review`;
  const title = $("title");
  title.replaceChildren(ownerView ? "Participant view" : `${viewer.name}'s review`, el("span", "p-sub", ` · ${session.title}`));
  title.title = session.title || "";
  const status = $("status");
  const waiting = data.waiting_for_owner;
  status.textContent = waiting ? "waiting for the owner" : (session.status || "");
  status.className = `p-status ${waiting ? "waiting" : session.status === "running" ? "running" : ""}`;
  $("people").replaceChildren(...(data.participants || []).map((p) => {
    const chip = el("span", "p-person");
    chip.style.setProperty("--author-color", authorColor(`p:${p.id}`));
    chip.append(el("span", "p-dot"), `${p.name}${p.kind === "agent" ? " (agent)" : ""}`);
    return chip;
  }));
  $("viewBanner").hidden = !ownerView;
  $("note").textContent = ownerView ? "" : "You can comment and ask; the model answers in a turn that can only read. The owner sees everything.";
  $("head").hidden = false;
  $("main").hidden = false;
  renderPlan();
  renderThread();
  renderDock();
}

// The review's subjects: beside the thread on a wide screen, behind the
// Plan | Thread toggle on a narrow one; drawn again only when they changed.
function renderPlan() {
  const subjects = data.subjects || [];
  document.body.classList.toggle("has-plan", subjects.length > 0);
  $("plan").hidden = subjects.length === 0;
  setView(wantedView);
  if (!subjects.length) return;
  const subject = pickSubject(subjects, subjectPath);
  const key = `${subject.path}\n${subjectsKey(subjects)}`;
  if (key === planDrawn) return;
  const scrolled = subject.path === subjectPath ? $("planScroll").scrollTop : 0;
  subjectPath = subject.path;
  planDrawn = key;
  const files = $("planFiles");
  files.hidden = subjects.length < 2;
  files.replaceChildren(...subjects.map((s) => {
    const button = el("button", "", s.path.split("/").pop());
    button.type = "button";
    button.title = s.path;
    button.setAttribute("aria-pressed", String(s.path === subject.path));
    button.addEventListener("click", () => {
      subjectPath = s.path;
      planDrawn = null;
      renderPlan();
    });
    return button;
  }));
  $("planPath").textContent = subject.path;
  const doc = $("planDoc");
  const shown = subjectBody(subject);
  doc.className = `p-doc${shown.kind === "html" ? "" : " plain"}`;
  // The server's rendered markdown (MarkdownRenderer: raw HTML escaped,
  // sanitised) of the redacted text; else the text itself.
  if (shown.kind === "html") doc.innerHTML = shown.html;
  else doc.textContent = shown.text;
  if (shown.note) doc.prepend(el("div", "p-plan-note", shown.note));
  $("planScroll").scrollTop = scrolled;
}

// A narrow screen's view: "plan" or "thread" (body.view-*; the wide
// layout shows both and ignores it).
function setView(view) {
  wantedView = view;
  const shown = narrowView(view, data?.subjects);
  document.body.classList.toggle("view-plan", shown === "plan");
  document.body.classList.toggle("view-thread", shown === "thread");
  $("segPlan").setAttribute("aria-selected", String(shown === "plan"));
  $("segThread").setAttribute("aria-selected", String(shown === "thread"));
}

function messageNode(message) {
  const user = message.role === "user";
  const node = el("div", `p-msg ${user ? "user" : "reply"}${message.mine ? " mine" : ""}`);
  if (user) {
    node.style.setProperty("--author-color", authorColor(message.author));
    const who = el("div", "p-who");
    who.append(el("b", "", authorLabel(message)));
    if (message.merged) who.append(el("span", "p-tag", "added mid-turn"));
    if (message.author) who.append(el("span", "p-tag", "review"));
    node.append(who);
    const text = message.content + (message.images ? `\n[${message.images} image${message.images > 1 ? "s" : ""}]` : "");
    node.append(el("div", "p-bubble", text));
    return node;
  }
  if (message.tools?.length) node.append(toolsNode(message.tools));
  if (message.content?.trim()) {
    const bubble = el("div", "p-bubble");
    // The server's rendered markdown (MarkdownRenderer, sanitised, from
    // the filtered text); the text itself without it.
    if (message.html) bubble.innerHTML = message.html;
    else {
      bubble.classList.add("plain");
      bubble.textContent = message.content;
    }
    node.append(bubble);
  }
  return node;
}

function toolsNode(rows) {
  if (rows.length === 1) {
    const row = rows[0];
    return el("div", `p-tools p-tool-one${row.status === "error" ? " error" : row.status === "running" ? " running" : ""}`, `↳ ${toolLine(row)}`);
  }
  const details = el("details", "p-tools");
  details.open = !phone.matches && rows.length <= 4;
  details.append(el("summary", "", `${rows.length} tool${rows.length > 1 ? "s" : ""}: ${toolsSummary(rows)}`));
  const list = el("ul");
  for (const row of rows) list.append(el("li", row.status === "error" ? "error" : row.status === "running" ? "running" : "", toolLine(row)));
  details.append(list);
  return details;
}

function renderThread() {
  const thread = $("thread");
  const nodes = withToolSteps(data.messages || []).map(messageNode);
  if (data.current_turn) nodes.push(...currentTurnNodes());
  else if (data.waiting_for_owner) nodes.push(el("div", "p-waiting", "Waiting for the session's owner"));
  if (nodes.length === 0) nodes.push(el("div", "p-empty", "Nothing here yet. Comments and replies show here."));
  const main = $("main");
  const atBottom = main.scrollHeight - main.scrollTop - main.clientHeight < 80;
  thread.replaceChildren(...nodes);
  if (atBottom || !thread.dataset.drawn) main.scrollTop = main.scrollHeight;
  thread.dataset.drawn = "1";
}

// The turn in progress: its prompt (the turn's start) and the live reply.
function currentTurnNodes() {
  const turn = data.current_turn;
  const nodes = [];
  if (turn.prompt !== undefined || turn.automatic) {
    nodes.push(messageNode({ role: "user", content: turn.automatic ? "An automatic turn" : turn.prompt, author: turn.author,
      author_name: turn.author_name, mine: turn.mine, automatic: turn.automatic }));
  }
  const reply = el("div", "p-msg reply live");
  reply.id = "liveReply";
  nodes.push(reply);
  fillLive(reply);
  return nodes;
}

function fillLive(reply) {
  const parts = [];
  if (live.tools.length) parts.push(toolsNode(live.tools));
  const text = liveText(live);
  if (text) parts.push(el("div", "p-bubble plain", text));
  if (data.current_turn?.waiting_for_owner) parts.push(el("div", "p-waiting", "Waiting for the session's owner"));
  else if (!text) parts.push(el("div", "p-who", "Working…"));
  reply.replaceChildren(...parts);
}

function renderLive() {
  const reply = $("liveReply");
  if (!reply) return scheduleReload();
  const main = $("main");
  const atBottom = main.scrollHeight - main.scrollTop - main.clientHeight < 80;
  fillLive(reply);
  if (atBottom) main.scrollTop = main.scrollHeight;
}

function renderDock() {
  const viewer = data.viewer || {};
  if (ownerView) {
    $("dock").hidden = true;
    return;
  }
  $("dock").hidden = false;
  const queue = $("queue");
  const rows = (data.queued?.mine || []).map((entry) => {
    const row = el("div", "p-queued");
    row.append(el("span", "", `Queued: ${entry.prompt}`));
    const take = el("button", "small", "Take back");
    take.type = "button";
    take.addEventListener("click", () => dequeue(entry.enqueued_id, take));
    row.append(take);
    return row;
  });
  const others = data.queued?.others || 0;
  if (others) rows.push(el("div", "p-queue-note", `${others} other turn${others > 1 ? "s" : ""} waiting before yours`));
  queue.replaceChildren(...rows);
  const send = $("send");
  const comment = $("comment");
  comment.disabled = !viewer.can_comment;
  send.disabled = !viewer.can_comment;
  comment.placeholder = viewer.cap_reached ? "Your spending cap is reached: ask the owner to raise it" : "Comment or ask";
}

function showError(text) {
  const box = $("error");
  box.textContent = text || "";
  box.hidden = !text;
}

// One comment in flight at a time: Enter submits with no submitter, so the
// disabled Send button alone doesn't stop a second Enter.
let sending = false;

async function sendComment(event) {
  event.preventDefault();
  if (sending) return;
  const comment = $("comment");
  const prompt = comment.value.trim();
  if (!prompt) return;
  sending = true;
  $("send").disabled = true;
  let reply;
  try {
    reply = await api(`/api/sessions/${encodeURIComponent(sessionId)}/turn`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ prompt }),
    });
  } finally {
    sending = false;
    if (!ended) $("send").disabled = !data?.viewer?.can_comment;
  }
  const { ok, status, body: json } = reply;
  if (ended) return;
  if (ok) {
    comment.value = "";
    autosize();
    showError("");
    await load();
  } else {
    showError(refusalText(status, json));
  }
}

async function dequeue(enqueuedId, button) {
  button.disabled = true;
  const { ok, status, body: json } = await api(
    `/api/sessions/${encodeURIComponent(sessionId)}/turn/${encodeURIComponent(enqueuedId)}/dequeue`, { method: "POST" });
  if (ended) return;
  if (!ok) {
    button.disabled = false;
    showError(json?.code === "already_started" || json?.error === "already_started"
      ? "Not taken back: it already started." : refusalText(status, json));
    return;
  }
  showError("");
  load();
}

function autosize() {
  const comment = $("comment");
  comment.style.height = "auto";
  comment.style.height = `${comment.scrollHeight + 2}px`;
}

$("compose").addEventListener("submit", sendComment);
for (const button of $("viewSeg").querySelectorAll("button")) {
  button.addEventListener("click", () => {
    setView(button.dataset.view);
    if (button.dataset.view === "thread") $("main").scrollTop = $("main").scrollHeight;
  });
}
$("comment").addEventListener("input", autosize);
$("comment").addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    $("compose").requestSubmit();
  }
});

load();
