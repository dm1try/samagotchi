// A level chip in the session bar and its popover: the level the next turn
// runs at ("think low", "reasoning all"; "· session" when the session set
// its own) and a form with a level select that runs the setting's command
// in the session's worker (the reply shows in the conversation, like a
// typed one). The summary is the setting's SettingExplained#summary
// ({level, source, own}: the worker's snapshot, a command_ran, or the
// server's own reading of the session file).
//
// A config names the setting (thinking_chip.js, reasoning_history_chip.js):
//   name     the popover's heading ("Thinking")
//   prefix   the chip's word ("think")
//   command  the command ("/thinking")
//   levels   the settable levels (the select's options after "follow")
//   anchor   the chip's selector (its data attribute: each config's
//            chipTemplate draws it; clicks are delegated on the same
//            element as the other chips')
//   formClass, popoverClass, nowClass   the form's, popover's and "Now:"
//            line's own classes
//   when(fresh)   the form's note on when it applies (fresh: the start
//            page's new session, thinking only)
//
// The start page's new session (kind NEW_SESSION) has a thinking chip only
// (thinking_chip.js keeps its choice): the form shows the model's level and
// takes a choice for the next create.

import { createChipPopover } from "./chip_popover.js";
import { NEW_SESSION, SESSION } from "./llm_context_chip.js";
import { html, render } from "./vendor/lit-html.js";

export const DEFAULT = "default";

// The chip: its text, tooltip and whether the session (or the new session)
// set its own; null without a summary (an older worker, or a host the
// setting means nothing on).
export function chipModel(cfg, summary, { kind = SESSION } = {}) {
  if (!summary || !summary.level) return null;
  const own = !!summary.own;
  const what = kind === NEW_SESSION ? "the new session" : "this session";
  const from = own ? what : summary.source || "the model's own";
  const title = `${cfg.name}: ${summary.level} (${from}). Click to change it for ${what}.`;
  return { text: `${cfg.prefix} ${summary.level}${own ? ` · ${kind}` : ""}`, title, own };
}

// The command line for a select value ("default" unsets the session's own),
// with --yes: picking a level in the form is the choice, and the form
// names the cost (CacheConfirm asks nothing then); null when it is what
// the form opened with.
export function commandLine(cfg, level, initial = null) {
  if (initial !== null && level === initial) return null;
  return `${cfg.command} ${level} --yes`;
}

// "Now: low (session)", "Now: default (the model's own)".
export function nowText(summary) {
  return `Now: ${summary.level} (${summary.source || "the model's own"})`;
}

const option = (value, label, chosen) => html`<option value=${value} ?selected=${value === chosen}>${label}</option>`;

// The popover's form (a lit-html template). For the new session (kind
// NEW_SESSION), +summary+ is the model's and +choice+ the level the form
// shows; +now+ is the summary its "Now:" line reads (refresh passes a
// newer one, the rest stays as the form opened).
export function formTemplate(cfg, summary, { running = false, kind = SESSION, choice = null, now = summary } = {}) {
  const fresh = kind === NEW_SESSION;
  const chosen = (fresh ? choice : summary.own) || DEFAULT;
  const follow = summary.own && !fresh ? "follow the model" : `follow the model (${summary.level})`;
  return html`<form class=${`${cfg.formClass} llmctx-form`}><div class="ctx-pop-head"><strong>${cfg.name}</strong
    ><span class="ctx-pop-kind">${fresh ? NEW_SESSION : "this session"}</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    ><div class=${`ctx-pop-meta ${cfg.nowClass}`}>${nowText(now)}</div
    ><label class="llmctx-field"><span>Level</span><span class="select-wrap"><select name="level">${option(DEFAULT, follow, chosen)}${
      cfg.levels.map((level) => option(level, level, chosen))}</select></span></label
    ><div class="ctx-pop-meta">${cfg.when(fresh)}${running ? " A turn is running: it applies after this turn." : ""}</div
    ><div class="ctx-pop-actions"><button type="submit" class="llmctx-set">Set</button></div></form>`;
}

// The chip's popover (chip_popover.js' shell), as createLlmContextControl's:
// el is where the chip is drawn (clicks are delegated: #infoText,
// info_bar.js); summary(): the open session's summary; session(): its id;
// running(): a turn runs; run(line): sends the command. The start page's
// (kind NEW_SESSION): summary() is the picked model's, choice() the pending
// level and choose(next) takes a Set's (null for "follow the model"). id
// and anchor (the chip's selector, by default its data attribute) keep it
// apart from the other controls on the same element (the anchor defaults
// to the config's).
export function createLevelControl({ cfg, el, summary, session = () => null, running = () => false, run,
                                     kind = SESSION, choice = () => null, choose = null,
                                     id, anchor = cfg.anchor,
                                     doc = document, win = window }) {
  const fresh = kind === NEW_SESSION;
  let initial = null;
  // What the open form was drawn from: the model's or session's summary
  // and the form's options.
  let shown = null;
  const draw = (now) => render(formTemplate(cfg, shown.data, { ...shown.opts, now }), shell.pop);

  // A refresh (a newer summary): an open form keeps the user's pick; only
  // "Now:" follows (the same template again: lit writes that line alone).
  function show(data, opening) {
    if (opening) {
      initial = (fresh ? choice() : data.own) || DEFAULT;
      shown = { data, opts: { running: running(), kind, choice: choice() } };
    }
    draw(data);
  }

  function submit(form) {
    const level = form.elements.level.value;
    const was = initial;
    shell.close();
    if (fresh) return choose(level === DEFAULT ? null : level);
    const line = commandLine(cfg, level, was);
    if (line) run(line);
  }

  const shell = createChipPopover({
    id, className: `ctx-popover ${cfg.popoverClass}`, width: 320, el, anchor, summary, session, show,
    onClose: () => { initial = null; shown = null; }, onSubmit: submit, doc, win,
  });

  return { close: shell.close, refresh: shell.refresh, get open() { return shell.isOpen(); } };
}
