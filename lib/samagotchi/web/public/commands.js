// Session commands in the web: which composer lines are commands, the
// page's own replies, how a command_ran shows (pure, no DOM), and the
// command bubbles this page draws and keeps across a resync (DOM, plain
// nodes: no lit, so the modules that import this one need no DOM to load).
// Split out of turn_events.js and app.js.

import { clientLabel, isOwn } from "./turn_events.js";
import { anchorInsertIndex, commandAnchor, isShellCommandLine, keepsCommandBubble } from "./kept_commands.js";

// Whether a composer line in an open session is one of its commands
// (+commands+: the session GET's listing), as the terminals decide
// (Commands::Registry#lookup): a "!" line with something after the "!", or
// a listed name alone or followed by a space; a terminal's own (/stats,
// /exit) too, which the page answers itself (webLocalReply). An unknown
// "/word" (a path, a typo) goes to the model as a prompt, as in a terminal.
export function sessionCommandLine(text, commands) {
  const line = String(text || "").trim();
  if (/^!\s*\S/.test(line)) return true;
  if (!line.startsWith("/")) return false;
  if (webLocalReply(line)) return true;
  return (Array.isArray(commands) ? commands : [])
    .some((c) => c && typeof c.name === "string" && (line === c.name || line.startsWith(`${c.name} `)));
}

// /cut TEXT and /queue TEXT: the UIs' own words for a delivery (listed
// for Tab and /help, never run as commands; ComposerRoute::STEER_CHOICE
// (spec/fixtures/composer_routes.json): the word, then any whitespace and the text). During a
// turn /cut TEXT is the text sent as a cut (POST /turn, delivery "cut"),
// as chi send --cut does, and /queue TEXT the text queued to run as a turn
// of its own after this one (delivery "queue"; a worker that can't queue
// refuses it, and the page shows the refusal's detail). With no running
// turn both are the text as a normal turn. The bare word gets the usage
// line.
// @return {{send: string, delivery?: string} | {reply: string} | null}
//   null: not a delivery line
export const STEER_CHOICE_USAGE = "(/cut and /queue need a message: /cut TEXT, /queue TEXT)";
const STEER_CHOICE = /^\/(cut|queue)(?:\s+([\s\S]*))?$/;

export function steerChoiceRoute(text, { running = false } = {}) {
  const match = STEER_CHOICE.exec(String(text || "").trim());
  if (!match) return null;
  const message = (match[2] || "").trim();
  if (!message) return { reply: STEER_CHOICE_USAGE };
  if (!running) return { send: message };
  return { send: message, delivery: match[1] };
}

// A line that is one word: a slash and a name, no spaces, no second slash
// (Commands::Registry#unknown_command_word?). `/modle` is one; `/foo bar`
// and `/usr/bin/env` are not (they are prompts).
const UNKNOWN_COMMAND_WORD = /^\/[A-Za-z][A-Za-z0-9_-]*$/;

// The hint for a command word no command answers (a typo like `/modle`),
// or null when the line is not one: `Unknown command /modle. Did you mean
// /model? /help lists the commands.` The "Did you mean" part needs a close
// name among the session's commands and the page's own (webLocalReply).
export function unknownCommandHint(text, commands) {
  const line = String(text || "").trim();
  if (!UNKNOWN_COMMAND_WORD.test(line)) return null;
  if (sessionCommandLine(line, commands)) return null;
  const names = (Array.isArray(commands) ? commands : [])
    .map((c) => (c && typeof c.name === "string" ? c.name : null))
    .filter(Boolean)
    .concat(Object.keys(WEB_LOCAL_REPLIES));
  const close = closestName(line, names);
  return `Unknown command ${line}. ${close ? `Did you mean ${close}? ` : ""}/help lists the commands.`;
}

// The closest name within an optimal string alignment distance of 2, or
// null. Ties go to the first in the list.
function closestName(line, names) {
  let best = null;
  let bestDistance = 3;
  for (const name of names) {
    const distance = osaDistance(line, name);
    if (distance < bestDistance) {
      best = name;
      bestDistance = distance;
    }
  }
  return best;
}

// Optimal string alignment distance: Levenshtein, with an adjacent
// transposition counting as 1 (so `/modle` is 1 from `/model`, as Ruby's
// DidYouMean reads it).
function osaDistance(a, b) {
  const rows = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 0; j <= b.length; j += 1) rows[0][j] = j;
  for (let i = 1; i <= a.length; i += 1) {
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      rows[i][j] = Math.min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        rows[i][j] = Math.min(rows[i][j], rows[i - 2][j - 2] + 1);
      }
    }
  }
  return rows[a.length][b.length];
}

// The terminal's own commands (a button in the web, or none yet): the
// reply the page shows itself (they never go to the worker, which doesn't
// know them), or null.
const WEB_LOCAL_REPLIES = {
  "/archive": "/archive: use the archive button in the session bar",
  "/detach": "/detach: a terminal's command; close the tab to leave, the worker keeps running",
  "/exit": "/exit: close the tab to leave; stop in the session bar stops the worker",
  "/quit": "/quit: close the tab to leave; stop in the session bar stops the worker",
  "/recap": "/recap: not in the web yet; a recap shows here by itself when you come back to an idle session, and /recap in a terminal (chi --attach) makes one now",
  "/stats": "/stats: not in the web yet; each turn shows its time, the session bar the context use and speed (hover ctx for tokens and cost), and /stats in a terminal (chi --attach) has the rest",
};

export function webLocalReply(text) {
  const name = String(text || "").trim().split(/\s+/)[0].toLowerCase();
  return WEB_LOCAL_REPLIES[name] || null;
}

// The start page's first message when the page answers it itself
// (webLocalReply: /stats, /exit …): shown there, with no session made just
// to hold the reply. With images it is a message, as in a session.
export function startPageReply(text, { images = 0 } = {}) {
  return images ? null : webLocalReply(text);
}

// The start page's reply to a first message that needs no session at all
// (2.29): its own command's reply (startPageReply), or the hint for a
// command word no command answers (a typo like /modle) — the hint the page
// shows in a session too, as a command bubble. Decided before the session
// is created, so a first /stats or /modle leaves none behind. A null here
// means the message goes to a session (a prompt, or anything with images).
export function startPageReplyOrHint(text, { commands = [], images = 0 } = {}) {
  if (images) return null;
  return startPageReply(text) || unknownCommandHint(text, commands);
}

// The continue card's answers, as the terminal's continue prompt reads them.
export function continueLine(choice, reason = "") {
  const why = String(reason || "").trim();
  if (choice === "no" && why) return `/continue no, ${why}`;
  return `/continue ${choice}`;
}

// How to show a command_ran: `label` names another client (null for this
// tab's own), `resync` says the conversation changed (!rollback, !cmd, a
// continue answered no) and must be read again. An anytime command's
// (`anytime`, D8) bubble is drawn at its command_queued, before the cards
// it shows; its command_ran fills that bubble in (`commandId`). So is a
// command queued for after the running turn (`queued`): its command_queued
// (waits: "turn_end") draws it `waiting`, saying so, until it ran or was
// dropped (styled as failed). A change that restarts the prompt cache asks
// first (CacheConfirm): `confirm` is the line that applies it, and this
// tab's own bubble (`own`) gets an Apply button that sends it.
export const QUEUED_TEXT = "queued: runs after this turn";
export const APPLY_TEXT = "Apply (restarts the cache)";

export function commandView(event, myId) {
  const own = isOwn(event.client_id, myId);
  const waiting = event.waits === "turn_end";
  return {
    own,
    label: own ? null : clientLabel(event.client_id),
    line: event.line || "",
    text: event.output || (waiting ? QUEUED_TEXT : ""),
    busy: event.status === "busy",
    failed: event.status === "error" || event.status === "dropped",
    resync: (event.changed || []).includes("messages"),
    modelName: event.model_name || null,
    anytime: event.anytime === true,
    queued: waiting || event.queued === true,
    waiting,
    commandId: event.command_id || null,
    confirm: typeof event.confirm?.line === "string" ? event.confirm.line : null,
    // A card's action (Nudge…): no bubble unless it says something back.
    hidden: event.card === true && !event.output && event.status !== "error",
  };
}

// Whether a command_ran that re-read the conversation (`resync`) needs its
// own bubble: the redrawn history ends with a command bubble for its line
// (a `!cmd` appends its "!(<command>)\n<output>" message, which renders as
// one), so a second bubble would show the output twice. +historyBubbles+:
// the `.bubble.command` elements in document order; +line+: the event's
// line. Only the last one counts: it is the redrawn history's end.
export function historyHasCommandBubble(historyBubbles, line) {
  const last = historyBubbles[historyBubbles.length - 1];
  return !!last && last.querySelector(":scope > .command-line")?.textContent === line;
}

// A command bubble's line and output (again, when its command_ran fills in
// an anytime command's bubble in place), and this tab's own change's Apply
// button when it asks first (a delegated click sends its line: app.js).
// Command bubbles are page-only: after a reload the button is gone, and
// the change is typed again.
export function drawCommandBubble(div, { label, line, text, busy = false, failed = false, waiting = false, commandId = null,
                                         own = false, confirm = null }) {
  div.className = "bubble command" + (busy ? " busy" : "") + (failed ? " failed" : "") + (waiting ? " queued" : "");
  if (commandId) div.dataset.commandId = commandId;
  div.replaceChildren();
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
  if (own && confirm) {
    const apply = document.createElement("button");
    apply.type = "button";
    apply.className = "command-confirm";
    apply.dataset.confirmLine = confirm;
    apply.title = confirm;
    apply.textContent = APPLY_TEXT;
    div.appendChild(apply);
  }
}

// A click on a bubble's Apply button: sends its --yes line once (the
// button is disabled at once), and enables it again when the line wasn't
// sent (+run+ resolves false or throws), so the user can try again.
export async function applyConfirm(button, run) {
  if (!button || button.disabled) return;
  button.disabled = true;
  let sent = false;
  try {
    sent = await run(button.dataset.confirmLine);
  } catch {
    sent = false;
  }
  if (!sent) button.disabled = false;
}

// The prompt and command bubbles in the history, in order, by kind
// (kept_commands.js): a prompt, a `!cmd`'s (saved, so redrawn) or another.
function historyAnchors(historyEl) {
  const els = [...historyEl.querySelectorAll(".bubble.user, .bubble.command")];
  const kinds = els.map((el) => {
    if (el.classList.contains("user")) return "user";
    const line = el.querySelector(":scope > .command-line")?.textContent;
    return !el.classList.contains("failed") && isShellCommandLine(line) ? "shell" : "other";
  });
  return { els, kinds };
}

// This session's own command bubbles (/help, /model …: drawn by this page,
// never saved) with their anchors, before a resync redraws the history.
// In-flight ones (busy, queued) are left out: the snapshot draws them again.
export function keptCommandBubbles(historyEl, id) {
  const { els, kinds } = historyAnchors(historyEl);
  return els
    .map((el, i) => ({ el, anchor: commandAnchor(kinds, i) }))
    .filter(({ el }) => el.dataset.keptFor === id && !el.classList.contains("busy") && !el.classList.contains("queued"))
    .filter(({ el }) => keepsCommandBubble(el.querySelector(":scope > .command-line")?.textContent));
}

// The kept bubbles back into the redrawn history, each after its turn.
export function restoreCommandBubbles(historyEl, kept) {
  if (!kept.length) return;
  historyEl.querySelector(".hint")?.remove();
  kept.forEach(({ el, anchor }) => {
    const { els, kinds } = historyAnchors(historyEl);
    const at = anchorInsertIndex(kinds, anchor);
    if (at < els.length) els[at].before(el);
    else historyEl.appendChild(el);
  });
}
