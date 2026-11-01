// The phone's session bar keeps id, status, model and ⚙ on its row; the rest
// sits behind ⋯ (#infoMoreBtn, index.html's CSS shows it at the page's phone
// width only). This is its bottom sheet, on chip_popover.js' shell as the ⚙
// panel is: a row for each chip the row folded away, one telemetry line, and
// the bar's four actions.
//
// The chips and the buttons stay where they are, display:none: a row or an
// action clicks the real one (`go:`), so its handlers, confirmations and state
// have one home (session_actions.js' Invite toast clicks the participants chip
// the same way). What a chip then opens places itself and gives focus back at
// ⋯, chip_popover.js' stand-in for an anchor with no box ([data-anchor-stand-in]).
// A chip with a tooltip and no popover (🧰, memories, model notes) unfolds its
// tooltip under the row (`info:`): a phone has no tooltips. The model has a row
// too: its chip stays on the bar but is the first to give way, cut short.
//
// app.js's updateInfoBar calls update() on every redraw (every second while a
// turn runs): lit writes only what changed, into slots that keep their place,
// so an open sheet stays current and keeps its focus. A module of its own: the
// page's modules are cached at unversioned URLs (docs/internals/web-frontend.md).

import { createChipPopover, SHEET_TALL } from "./chip_popover.js";
import { memChipText } from "./format.js";
import { CLOCK_NONE, memoriesTooltip, NEXT, PREV } from "./info_bar.js";
import { chipModel as toolkitChip } from "./toolkit_chip.js";
import { html, nothing, render } from "./vendor/lit-html.js";

// The real element each `go:` act clicks.
const TARGETS = {
  workingSet: "#infoText .ws-chip",
  participants: "#infoText .participants-chip",
  delegates: "#infoText .children-chip",
  restart: "#infoText .worker-restart",
  continue: "#infoContinueBtn",
  archive: "#infoArchiveBtn",
  stop: "#infoStopBtn",
  delete: "#infoDeleteBtn",
};

// Every row, in the sheet's order; each draws into a slot of its own.
const ROW_KEYS = ["model", "toolkit", "workingSet", "memories", "participants", "prev", "next", "parent", "delegates", "notes", "worker"];
const ACTION_KEYS = ["continue", "archive", "stop", "delete"];

const short = (id) => String(id).slice(0, 8);
const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
const capital = (text) => text.charAt(0).toUpperCase() + text.slice(1);

function toolkitRow(toolkit) {
  const chip = toolkitChip(toolkit.summary, toolkit.defaultKit);
  const kit = chip.text || toolkit.summary?.label || toolkit.summary?.name || toolkit.defaultKit || "full";
  return { key: "toolkit", label: "Toolkit", value: kit, icon: "tc-kit", info: chip.title };
}

function workingSetRow({ n, changed }) {
  const count = n ? plural(n, "item") : "empty";
  return { key: "workingSet", label: "Working set", value: changed ? `${count}, changed` : count, go: "workingSet", attention: changed ? "accent" : null };
}

function participantsRow(chip) {
  return { key: "participants", label: "Participants", value: chip.count ? chip.text : "Invite", go: "participants", attention: chip.present ? "accent" : null };
}

function delegatesRow(kids) {
  const value = kids.waitingText ? `${kids.text} · ${kids.waitingText}` : kids.text;
  return { key: "delegates", label: "Delegates", value, go: "delegates", attention: kids.waitingText ? "warn" : null };
}

// The model's title unfolds only when it says more than the row already does
// (a name cut at 40, what the server serves instead).
function modelRow({ text, title }) {
  return { key: "model", label: "Model", value: text, info: title === text ? null : title };
}

function workerRow({ badge, busy }) {
  const row = { key: "worker", label: "Worker", value: badge.text, attention: "warn" };
  return badge.restart ? { ...row, restart: { busy } } : { ...row, info: badge.title };
}

// The rows +bar+ (info_bar_model.js infoBarModel) has, each only when the
// session has its chip: {key, label, value, and how a tap acts: go (a TARGETS
// key), href, info (the text it unfolds), restart ({busy}); attention: "accent"
// or "warn" when the chip asks for a look; icon: a chip icon's class}.
export function moreRows(bar) {
  if (!bar) return [];
  const memories = bar.memories || [];
  return [
    bar.model && modelRow(bar.model),
    bar.toolkit && toolkitRow(bar.toolkit),
    bar.workingSet?.chip && workingSetRow(bar.workingSet.chip),
    !bar.workingSet && memories.length > 0
      && { key: "memories", label: "Memories", value: memChipText(memories), info: memoriesTooltip(memories, bar.preloaded, bar.muted) },
    bar.participants && participantsRow(bar.participants),
    bar.chain?.prev && { key: "prev", label: "Previous link", value: `${PREV} ${bar.chain.prev.date || short(bar.chain.prev.id)}`, href: bar.chain.prev.id },
    bar.chain?.next && { key: "next", label: "Next link", value: `${bar.chain.next.date || short(bar.chain.next.id)} ${NEXT}`, href: bar.chain.next.id },
    bar.parent && { key: "parent", label: "Delegated by", value: `↑ ${short(bar.parent.id)}`, href: bar.parent.id },
    bar.kids && delegatesRow(bar.kids),
    bar.notes && { key: "notes", label: "Model notes", value: bar.notes.text.replace(/^notes: /, ""), info: bar.notes.title },
    bar.worker?.badge && workerRow(bar.worker),
  ].filter(Boolean);
}

// ⋯'s dot: what behind it asks for a look. {kind} is the strongest ("warn":
// a delegate waiting, an older worker; "accent": the working set changed, a
// participant here; null: none), {label} ⋯'s accessible name, which says why.
export function moreAttention(bar) {
  const rows = moreRows(bar).filter((row) => row.attention);
  const kind = rows.some((row) => row.attention === "warn") ? "warn" : rows.length ? "accent" : null;
  const why = rows.map((row) => `${row.label}: ${row.value}`).join(", ");
  return { kind, label: why ? `More: ${why}` : "More" };
}

// The four actions as the sheet draws them from +buttons+ (info_bar_model.js
// infoButtons), each with the rule its button has; Continue takes the accent
// on an archived session, where it is the thing to do.
export function moreActions(buttons) {
  const all = [
    buttons.continue.shown && { key: "continue", text: capital(buttons.continue.text.replace(/ →$/, "")), disabled: buttons.continue.disabled, accent: !!buttons.archive.archived },
    buttons.archive.shown && { key: "archive", text: capital(buttons.archive.text), title: buttons.archive.title },
    buttons.stop.shown && { key: "stop", text: "Stop" },
    buttons.delete.shown && { key: "delete", text: "Delete" },
  ];
  return all.filter(Boolean);
}

function rowBody(row) {
  const dot = row.attention ? html`<span class=${`more-dot ${row.attention}`} aria-hidden="true"></span>` : nothing;
  const icon = row.icon ? html`<span class=${`chip-icon ${row.icon}`} aria-hidden="true"></span>` : nothing;
  return html`<span class="more-label">${row.label}</span><span class="more-value">${dot}${icon}<span class="more-text">${row.value}</span></span>`;
}

function rowTemplate(row, { shownInfo, hash }) {
  const cls = `more-row${row.attention ? ` ${row.attention}` : ""}`;
  if (row.href) return html`<a class=${cls} href=${hash(row.href)} data-act="link">${rowBody(row)}</a>`;
  if (row.go) return html`<button type="button" class=${cls} data-act=${`go:${row.go}`}>${rowBody(row)}</button>`;
  if (row.restart) {
    return html`<div class=${cls}>${rowBody(row)}<button type="button" class="more-restart" data-act="go:restart" ?disabled=${row.restart.busy}>${row.restart.busy ? "restarting…" : "Restart"}</button></div>`;
  }
  if (!row.info) return html`<div class=${cls}>${rowBody(row)}</div>`;
  const open = shownInfo === row.key;
  return html`<button type="button" class=${cls} data-act=${`info:${row.key}`} aria-expanded=${open ? "true" : "false"}>${rowBody(row)}</button>${open ? html`<div class="more-info">${row.info}</div>` : nothing}`;
}

// The sheet for +bar+ and +buttons+. +shownInfo+: the key of the row whose
// tooltip is unfolded; +hash+: a session's id to its link.
export function moreSheetTemplate({ bar, buttons, shownInfo = null, hash }) {
  const rows = moreRows(bar);
  const actions = moreActions(buttons);
  const speed = bar.speed;
  return html`<div class="more-grip" aria-hidden="true"></div
    ><div class="more-rows">${ROW_KEYS.map((key) => {
      const row = rows.find((r) => r.key === key);
      return row ? rowTemplate(row, { shownInfo, hash }) : nothing;
    })}</div
    ><div class="more-telemetry"><span class="more-ctx" title=${bar.ctx.tip}>${bar.ctx.text}</span
      >${speed ? html`<span class="more-speed" title=${speed.tip}>${speed.text}</span>` : nothing
      }<span class="more-clock">${bar.clock || CLOCK_NONE}</span
      ><span class="more-dir" title=${bar.dir || ""}><bdi>${bar.dir || ""}</bdi></span></div
    ><div class="more-actions">${ACTION_KEYS.map((key) => {
      const act = actions.find((a) => a.key === key);
      if (!act) return nothing;
      return html`<button type="button" class=${`more-act ${key}${act.accent ? " accent" : ""}`} data-act=${`go:${key}`}
        title=${act.title || nothing} ?disabled=${!!act.disabled}>${act.text}</button>`;
    })}</div>`;
}

// ⋯'s sheet. el: where ⋯ is drawn (#infoBar); button: ⋯ itself; session(): the
// open session's id; hash: a session's id to its link (route.js sessionHash).
// @return {update({bar, buttons}), close, isOpen, pop}
export function createMoreSheet({ el, button, session = () => null, hash, doc = document, win = window }) {
  let bar = null;
  let buttons = null;
  let shownInfo = null;

  function draw() {
    render(moreSheetTemplate({ bar, buttons, shownInfo, hash }), shell.pop);
  }

  const shell = createChipPopover({
    id: "moreSheet", className: "ctx-popover more-sheet", width: 400, el, anchor: `#${button.id}`,
    summary: () => bar, session, show: () => draw(), sheet: true, sheetShare: SHEET_TALL, label: "More about this session",
    onOpen: () => shell.pop.querySelector(".more-row, .more-act")?.focus(),
    onClose: () => { shownInfo = null; },
    onAct: (act) => {
      const [what, name] = act.split(":");
      if (what === "info") {
        shownInfo = shownInfo === name ? null : name;
        return draw();
      }
      // After this click is done: it goes on to the document, where what the
      // target opens would take it as a click outside, and a link still has
      // to follow its href.
      globalThis.setTimeout(() => {
        shell.close();
        if (what === "go") doc.querySelector(TARGETS[name])?.click();
      }, 0);
    },
    doc, win,
  });

  function update(next) {
    bar = next.bar;
    buttons = next.buttons;
    const { kind, label } = moreAttention(bar);
    if (kind) button.dataset.attention = kind;
    else delete button.dataset.attention;
    button.setAttribute("aria-label", label);
    button.title = label;
    // Another session, or none, closes it; else the open sheet follows.
    shell.refresh();
  }

  return { update, close: () => shell.close(), isOpen: shell.isOpen, pop: shell.pop };
}
