// The Stop button's sheet (session_actions.js asks the worker first): when
// the session's worker still has things the user can stop — reminders, a
// background task that runs, a delegate with a live worker — Stop asks what
// to do with them before TERMed-ing the worker. Nothing to stop, or no worker
// to ask, is today's one tap.
//
// "Stop all" runs the worker's stop-all step (POST …/holds/stop, the same
// HoldStop#stop_all the terminal's /exit ask uses) and then today's Stop;
// "Stop session only" is today's Stop exactly, so what survives keeps running
// (docs/sessions.md, "Stopping a worker"). Reminders are listed with a note:
// they live only in the worker, so they end with the session either way.
//
// A phone gets it as a bottom sheet, a wider window as a popover at the Stop
// button (chip_popover.js). Pure model and template plus createStopSheet, so
// the specs run them under node --test.

import { html, nothing, render } from "./vendor/lit-html.js";
import { createChipPopover } from "./chip_popover.js";

// At most this many of a kind named in the sheet; the rest are one "+N more".
export const MAX_NAMED = 3;

// The Stop button the sheet opens at.
export const STOP_ANCHOR = "#infoStopBtn";

const KIND_WORDS = {
  reminders: ["reminder", "reminders"],
  background_tasks: ["background task", "background tasks"],
  delegates: ["delegate", "delegates"],
};

// One entry of a hold as the sheet writes it: the command, the reminder's
// name with its schedule, a delegate's short id and its title. A long command
// is cut short: the sheet must fit a phone without scrolling.
function itemWords(item, kind) {
  const label = String(item?.label ?? item?.id ?? "").trim();
  const detail = String(item?.detail ?? "").trim();
  const cut = label.length > 42 ? `${label.slice(0, 42)}…` : label;
  if (kind === "delegates") {
    const id = String(item?.id ?? "").slice(0, 8);
    return `${id} "${cut || "untitled"}"${detail ? ` ${detail}` : ""}`;
  }
  const name = cut || String(item?.id ?? "").slice(0, 8);
  return detail ? `${name} (${detail})` : name;
}

// What the sheet says from the worker's holds (GET …/holds): null when there
// is nothing to ask about (no sheet: Stop stays one tap), else its lines, one
// per kind, and the total.
// @return {lines: [{kind, count, word, items, more, note}], total} | null
export function stopSheetModel(holds) {
  const lines = [];
  for (const hold of Array.isArray(holds) ? holds : []) {
    const kind = String(hold?.kind ?? "");
    const items = Array.isArray(hold?.items) ? hold.items : [];
    if (!items.length) continue;

    const [singular, plural] = KIND_WORDS[kind] ?? [kind || "hold", `${kind || "holds"}s`];
    lines.push({
      kind,
      count: items.length,
      word: items.length === 1 ? singular : plural,
      items: items.slice(0, MAX_NAMED).map((item) => itemWords(item, kind)),
      more: Math.max(0, items.length - MAX_NAMED),
      note: kind === "reminders" ? "they end with the session" : "",
    });
  }
  if (!lines.length) return null;

  return { lines, total: lines.reduce((sum, line) => sum + line.count, 0) };
}

function lineTemplate(line) {
  return html`<li class="ss-line" data-kind=${line.kind}>
    <b>${line.count} ${line.word}</b>
    ${line.note ? html` <span class="ss-note">(${line.note})</span>` : nothing}
    ${line.items.length ? html` <span class="ss-items">${line.items.join(" · ")}${line.more ? html` <span class="ss-more">+${line.more} more</span>` : nothing}</span>` : nothing}
  </li>`;
}

// The sheet's content (a lit-html template).
export function stopSheetTemplate(model) {
  const things = model.total === 1 ? "1 thing" : `${model.total} things`;
  return html`<div class="ctx-pop-head"><strong>This session still has</strong
    ><span class="ctx-pop-kind">${things}</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    ><ul class="ss-lines">${model.lines.map(lineTemplate)}</ul
    ><div class="ss-acts"><button type="button" class="ss-stop-all" data-act="all">Stop all</button
      ><button type="button" class="ss-stop-only" data-act="session">Stop session only</button
      ><button type="button" class="ss-cancel" data-act="cancel">Cancel</button></div
    ><div class="ss-foot">Stopping the session ends its worker; a background task or a delegate runs on its own, so it stays.</div>`;
}

// The sheet at the Stop button. +stopAll(id)+ stops what the worker can and
// then the session; +stopSession(id)+ is today's Stop; +open(id, holds)+ shows
// it only when there is something (false otherwise, so the caller can fall
// back to the plain confirm). @return {open, close, isOpen, pop}
export function createStopSheet({ doc = globalThis.document, win = globalThis.window,
                                  anchor = STOP_ANCHOR, el = doc.createElement("span"),
                                  stopAll = () => {}, stopSession = () => {} }) {
  let model = null;
  let forId = null;

  const shell = createChipPopover({
    id: "stopSheet", className: "ctx-popover stop-sheet", width: 400, el, anchor, openers: anchor,
    summary: () => model, sheet: true, label: "Stop the session?", doc, win,
    show: (data) => render(stopSheetTemplate(data), shell.pop),
    onClose: () => { model = null; forId = null; },
    onAct: (act) => {
      const id = forId;
      if (act === "all") { shell.close(); stopAll(id); }
      else if (act === "session") { shell.close(); stopSession(id); }
      else if (act === "cancel") shell.close();
    },
  });

  function open(id, holds) {
    model = stopSheetModel(holds);
    if (!model) return false;
    forId = id;
    shell.open(doc.querySelector(anchor) ?? el);
    return true;
  }

  return { open, close: () => shell.close(), isOpen: shell.isOpen, pop: shell.pop };
}
