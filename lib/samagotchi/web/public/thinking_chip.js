// The session bar's thinking chip: the level the next turn runs at ("think
// low"; "· session" when the session set its own), and a popover with a
// level select that runs /thinking in the session's worker (the command's
// reply shows in the conversation, like a typed one). The level and where
// it came from are the session's thinking (Thinking::Explained#summary:
// {level, source, own}; the worker's snapshot, a command_ran, or the
// server's own reading of the session file).
//
// The start page has one too (kind "new chat"): it shows the picked
// model's level (GET /api/models' thinking) and keeps a choice for the
// next create only (POST /api/sessions' thinking), never remembered:
// nothing is sent unless the user sets one.

import { NEW_CHAT, SESSION, popoverPlace } from "./llm_context_chip.js";

export const LEVELS = ["off", "low", "medium", "high"];
const DEFAULT = "default";

// The new chat's choice (a level, or null) laid over the model's summary:
// what the chip shows. The model's own summary without a choice.
export function withChoice(summary, choice) {
  if (!summary || !choice) return summary;
  return { ...summary, level: choice, source: SESSION, own: choice };
}

// The chip: its text, tooltip and whether the session (or the new chat)
// set its own; null without a summary (an older worker). The default with
// nothing set anywhere shows too ("think default"): the chip is where the
// level is set.
export function chipModel(summary, { kind = SESSION } = {}) {
  if (!summary || !summary.level) return null;
  const own = !!summary.own;
  const what = kind === NEW_CHAT ? "the new chat" : "this session";
  const from = own ? what : summary.source || "the model's own";
  const title = `Thinking: ${summary.level} (${from}). Click to change it for ${what}.`;
  return { text: `think ${summary.level}${own ? ` · ${kind}` : ""}`, title, own };
}

export function chipHtml(summary, escapeHtml) {
  const chip = chipModel(summary);
  if (!chip) return "";
  return `<button type="button" class="model think-chip${chip.own ? " own" : ""}" title="${escapeHtml(chip.title)}" ` +
    `data-think-chip aria-haspopup="dialog">${escapeHtml(chip.text)}</button>`;
}

// The /thinking line for a select value ("default" unsets the session's
// own); null when it is what the form opened with.
export function commandLine(level, initial = null) {
  if (initial !== null && level === initial) return null;
  return `/thinking ${level}`;
}

function option(value, label, chosen, escapeHtml) {
  return `<option value="${escapeHtml(value)}"${value === chosen ? " selected" : ""}>${escapeHtml(label)}</option>`;
}

// "Now: low (session)", "Now: default (the model's own)".
export function nowText(summary) {
  return `Now: ${summary.level} (${summary.source || "the model's own"})`;
}

// The popover's form. For the new chat (kind NEW_CHAT), +summary+ is the
// model's and +choice+ the level the form shows.
export function formHtml(summary, escapeHtml, { running = false, kind = SESSION, choice = null } = {}) {
  const fresh = kind === NEW_CHAT;
  const chosen = (fresh ? choice : summary.own) || DEFAULT;
  const follow = summary.own && !fresh ? "follow the model" : `follow the model (${summary.level})`;
  const when = fresh ? "For the new chat's first turn on; not remembered for the next one."
    : "From the next turn's start. On Gemma the whole prompt is read again; a hosted API may restart its cache.";
  return `<form class="think-form llmctx-form"><div class="ctx-pop-head"><strong>Thinking</strong>` +
    `<span class="ctx-pop-kind">${fresh ? NEW_CHAT : "this session"}</span>` +
    `<button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>` +
    `<div class="ctx-pop-meta think-now">${escapeHtml(nowText(summary))}</div>` +
    `<label class="llmctx-field"><span>Level</span><select name="level">` +
    option(DEFAULT, follow, chosen, escapeHtml) +
    LEVELS.map((level) => option(level, level, chosen, escapeHtml)).join("") + `</select></label>` +
    `<div class="ctx-pop-meta">${when}${running ? " A turn is running: it applies after this turn." : ""}</div>` +
    `<div class="ctx-pop-actions"><button type="submit" class="llmctx-set">Set</button></div></form>`;
}

// The chip's popover, as createLlmContextControl's: el is where the chip
// is drawn (clicks are delegated: #infoText is redrawn every tick);
// summary(): the open session's thinking; session(): its id; running():
// a turn runs; run(line): sends the command. The start page's (kind
// NEW_CHAT): summary() is the picked model's, choice() the pending level
// and choose(next) takes a Set's (null for "follow the model"). id and
// anchor (the chip's selector) keep it apart from the llm ctx control on
// the same element.
export function createThinkingControl({ el, escapeHtml, summary, session = () => null, running = () => false, run,
                                        kind = SESSION, choice = () => null, choose = null,
                                        id = "thinkingPopover", anchor: anchorSel = "[data-think-chip]",
                                        doc = document, win = window }) {
  const fresh = kind === NEW_CHAT;
  const pop = doc.createElement("div");
  pop.id = id;
  pop.className = "ctx-popover think-popover";
  pop.setAttribute("role", "dialog");
  pop.hidden = true;
  doc.body.appendChild(pop);
  let initial = null;
  let openFor = null;

  function place(anchor) {
    const width = Math.min(320, win.innerWidth - 32);
    pop.style.width = `${width}px`;
    pop.style.maxHeight = "";
    const at = popoverPlace(anchor.getBoundingClientRect(), { width, height: pop.offsetHeight,
                                                              innerWidth: win.innerWidth, innerHeight: win.innerHeight });
    pop.style.left = `${at.left}px`;
    pop.style.top = at.top === undefined ? "" : `${at.top}px`;
    pop.style.bottom = at.bottom === undefined ? "" : `${at.bottom}px`;
    if (at.maxHeight !== undefined) pop.style.maxHeight = `${at.maxHeight}px`;
  }

  function open(anchor) {
    const data = summary();
    if (!data) return;
    initial = (fresh ? choice() : data.own) || DEFAULT;
    openFor = session();
    pop.innerHTML = formHtml(data, escapeHtml, { running: running(), kind, choice: choice() });
    pop.hidden = false;
    place(anchor);
  }

  function close() {
    pop.hidden = true;
    initial = null;
    openFor = null;
  }

  function isOpen() { return !pop.hidden; }

  // A new summary: an open form keeps the user's pick; only "Now:" follows.
  function refresh() {
    if (!isOpen()) return;
    const data = summary();
    if (!data || session() !== openFor) return close();
    const now = pop.querySelector(".think-now");
    if (now) now.textContent = nowText(data);
  }

  el.addEventListener("click", (e) => {
    const anchor = e.target.closest(anchorSel);
    if (!anchor) return;
    e.stopPropagation();
    if (isOpen()) close();
    else open(anchor);
  });
  pop.addEventListener("submit", (e) => {
    e.preventDefault();
    const level = e.target.elements.level.value;
    const was = initial;
    close();
    if (fresh) return choose(level === DEFAULT ? null : level);
    const line = commandLine(level, was);
    if (line) run(line);
  });
  pop.addEventListener("click", (e) => {
    if (e.target.closest("[data-act]")?.dataset.act === "close") close();
  });
  doc.addEventListener("click", (e) => {
    if (isOpen() && !pop.contains(e.target) && !e.target.closest?.(anchorSel)) close();
  });
  doc.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && isOpen()) close();
  });

  return { close, refresh, get open() { return isOpen(); } };
}
