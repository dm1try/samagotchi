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
//   when()   the form's note on when it applies

import { createChipPopover } from "./chip_popover.js";
import { html, render } from "./vendor/lit-html.js";

export const DEFAULT = "default";

// The chip: its text, tooltip and whether the session set its own; null
// without a summary (an older worker, or a host the setting means nothing
// on).
export function chipModel(cfg, summary) {
  if (!summary || !summary.level) return null;
  const own = !!summary.own;
  const from = own ? "this session" : summary.source || "the model's own";
  const title = `${cfg.name}: ${summary.level} (${from}). Click to change it for this session.`;
  return { text: `${cfg.prefix} ${summary.level}${own ? " · session" : ""}`, title, own };
}

// The command line for a select value ("default" unsets the session's own),
// with --yes: picking a level in the form is the choice, and the form
// names the cost (CacheConfirm asks nothing then); null when it is what
// the form opened with.
export function commandLine(cfg, level, initial = null) {
  if (initial !== null && level === initial) return null;
  return `${cfg.command} ${level} --yes`;
}

// A settings panel row's first segment (settings_panel.js): follow the
// model, its value in brackets ("default (high)"; a model with no value of
// its own, "default" alone).
export const followSegment = (value) => ({ value: DEFAULT, label: value === DEFAULT ? DEFAULT : `${DEFAULT} (${value})`,
                                           title: `Follow the model (${value})` });

// A config's row of segments in the settings panel: the model's own level
// first (followSegment), then the config's levels; the pressed one is
// +choice+ (null: the follow segment). null without the summary's level
// (the row is hidden).
export function segments(cfg, summary, choice) {
  if (!summary?.level) return null;
  const pressed = choice || DEFAULT;
  return [followSegment(summary.level),
    ...cfg.levels.map((level) => ({ value: level, label: level }))].map((s) => ({ ...s, pressed: s.value === pressed }));
}

// "Now: low (session)", "Now: default (the model's own)".
export function nowText(summary) {
  return `Now: ${summary.level} (${summary.source || "the model's own"})`;
}

const option = (value, label, chosen) => html`<option value=${value} ?selected=${value === chosen}>${label}</option>`;

// The popover's form (a lit-html template); +now+ is the summary its "Now:"
// line reads (refresh passes a newer one, the rest stays as the form opened).
export function formTemplate(cfg, summary, { running = false, now = summary } = {}) {
  const chosen = summary.own || DEFAULT;
  const follow = summary.own ? "follow the model" : `follow the model (${summary.level})`;
  return html`<form class=${`${cfg.formClass} llmctx-form`}><div class="ctx-pop-head"><strong>${cfg.name}</strong
    ><span class="ctx-pop-kind">this session</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    ><div class=${`ctx-pop-meta ${cfg.nowClass}`}>${nowText(now)}</div
    ><label class="llmctx-field"><span>Level</span><span class="select-wrap"><select name="level">${option(DEFAULT, follow, chosen)}${
      cfg.levels.map((level) => option(level, level, chosen))}</select></span></label
    ><div class="ctx-pop-meta">${cfg.when()}${running ? " A turn is running: it applies after this turn." : ""}</div
    ><div class="ctx-pop-actions"><button type="submit" class="llmctx-set">Set</button></div></form>`;
}

// The chip's popover (chip_popover.js' shell), as createLlmContextControl's:
// el is where the chip is drawn (clicks are delegated: #infoText,
// info_bar.js); summary(): the open session's summary; session(): its id;
// running(): a turn runs; run(line): sends the command. id and anchor (the
// chip's selector, by default the config's data attribute) keep it apart
// from the other controls on the same element.
export function createLevelControl({ cfg, el, summary, session = () => null, running = () => false, run,
                                     id, anchor = cfg.anchor,
                                     doc = document, win = window }) {
  let initial = null;
  // What the open form was drawn from: the session's summary and the form's
  // options.
  let shown = null;
  const draw = (now) => render(formTemplate(cfg, shown.data, { ...shown.opts, now }), shell.pop);

  // A refresh (a newer summary): an open form keeps the user's pick; only
  // "Now:" follows (the same template again: lit writes that line alone).
  function show(data, opening) {
    if (opening) {
      initial = data.own || DEFAULT;
      shown = { data, opts: { running: running() } };
    }
    draw(data);
  }

  function submit(form) {
    const level = form.elements.level.value;
    const was = initial;
    shell.close();
    const line = commandLine(cfg, level, was);
    if (line) run(line);
  }

  const shell = createChipPopover({
    id, className: `ctx-popover ${cfg.popoverClass}`, width: 320, el, anchor, summary, session, show,
    onClose: () => { initial = null; shown = null; }, onSubmit: submit, doc, win,
  });

  return { close: shell.close, refresh: shell.refresh, get open() { return shell.isOpen(); } };
}
