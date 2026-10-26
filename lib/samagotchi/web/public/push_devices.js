// The Home Screen app's notifications sheet (Web Push; notifications.js
// opens it from the bell when chi web pushes): this device's switch (the
// bell's subscribe / unsubscribe), then every device chi web pushes to from
// this origin (GET /api/push's devices): its label, "this device", the last
// delivery and the last error, a "Long turns done" switch (PATCH
// /api/push/subscriptions/ID {prefs: {done}}), Remove for another device
// (DELETE /api/push/subscriptions/ID), and the stale ones (another origin's,
// never sent to) as one line. A phone gets it as a bottom sheet, a wider
// window as a popover at the bell (chip_popover.js), small enough to need
// no scrolling for a few devices.
//
// This device's row has the switch and never Remove: turning it off is the
// bell turned off (the page forgets its device id), so the page's state and
// chi web's store stay one. A device iOS revoked silently still shows a
// recent delivery (Apple keeps answering 201): the list can't tell; switch
// it off and on there.
//
// Pure templates and models, plus createPushDevices (the injected api and
// the popover shell), so the specs run them under node --test.

import { html, nothing, render } from "./vendor/lit-html.js";
import { createChipPopover } from "./chip_popover.js";
import { relativeTime } from "./format.js";

export const DEVICE_PATH = "/api/push/subscriptions";

// The rows GET /api/push's +info+ gives, this device first.
// @return [{id, label, this, last, error, done}]
export function deviceRows(info, now) {
  const devices = Array.isArray(info?.devices) ? info.devices : [];
  const rows = devices.map((d) => ({
    id: String(d.id || ""),
    label: d.label || d.id || "device",
    this: d.this === true,
    last: d.last_ok_at ? `last delivery ${relativeTime(d.last_ok_at, now)}` : "no delivery yet",
    error: d.last_error ? `last error ${d.last_error}` : "",
    done: d.prefs?.done === true,
  }));
  return [...rows.filter((r) => r.this), ...rows.filter((r) => !r.this)];
}

// "2 more devices from an earlier address, never sent to" (another origin's:
// a renamed machine or tailnet), "" for none.
export function staleText(count) {
  const n = Number(count) || 0;
  if (n <= 0) return "";
  return `${n === 1 ? "1 more device" : `${n} more devices`} from an earlier address, never sent to (chi web push rm)`;
}

// What the sheet draws: +state+ the bell's ("on" | "off" | "denied"),
// +info+ GET /api/push's answer (null before the first), +busy+ a change
// in flight, +error+ the last one's failure.
export function sheetModel({ state, info, busy = false, error = "", now = Date.now() }) {
  const rows = deviceRows(info, now);
  const mine = rows.find((r) => r.this) || null;
  const thisRow = mine || {
    id: "", label: "This device", this: true, done: false, error: "",
    last: state === "denied" ? "notifications are blocked for this app in the phone's settings" : "off: nothing is pushed here",
  };
  return {
    on: state === "on" && !!mine,
    denied: state === "denied",
    busy,
    error,
    thisRow,
    others: rows.filter((r) => !r.this),
    stale: staleText(info?.stale),
    loading: !info,
  };
}

const doneSwitch = (row, busy) => html`<label class="pd-done"><span>Long turns done (10 s or more)</span
  ><input type="checkbox" class="pd-switch" role="switch" data-pd="done" data-id=${row.id} .checked=${row.done}
    ?disabled=${busy}></label>`;

function rowTemplate(row, model) {
  const mine = row.this;
  const subscribed = !mine || model.on;
  return html`<li class=${`pd-row${mine ? " this" : ""}`} data-id=${row.id || nothing}>
    <div class="pd-who"><b>${row.label}</b>${mine ? html`<span class="pd-tag">this device</span>` : nothing}</div>
    <div class="pd-act">${mine
      ? html`<input type="checkbox" class="pd-switch" role="switch" data-pd="this" aria-label="Notifications to this device"
          .checked=${model.on} ?disabled=${model.busy || model.denied}>`
      : html`<button type="button" class="pd-remove" data-pd="remove" data-id=${row.id} ?disabled=${model.busy}>Remove</button>`}</div>
    <div class="pd-meta">${row.last}${row.error ? html` · <span class="pd-error">${row.error}</span>` : nothing}</div>
    ${subscribed ? doneSwitch(row, model.busy) : nothing}
  </li>`;
}

// The sheet's content (a lit-html template).
export function sheetTemplate(model) {
  return html`<div class="ctx-pop-head"><strong>Notifications</strong><span class="ctx-pop-kind">devices</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div
    ><ul class="pd-list">${rowTemplate(model.thisRow, model)}${model.others.map((row) => rowTemplate(row, model))}</ul
    >${model.loading ? html`<div class="pd-note">Loading the devices…</div>` : nothing
    }${model.stale ? html`<div class="pd-note">${model.stale}</div>` : nothing
    }${model.error ? html`<div class="pd-note pd-error" role="alert">${model.error}</div>` : nothing
    }<div class="pd-note">Approvals, questions, step limits, cards and failed turns; quiet while a chi web page is in front.</div>`;
}

// Puts every switch in +pop+ back to +model+: lit skips a .checked binding
// whose value is the one it last set, so a switch the app then refused
// (iOS's Don't Allow, a failed PATCH) would keep its clicked state.
export function syncSwitches(pop, model) {
  const rows = [model.thisRow, ...model.others];
  for (const input of pop.querySelectorAll("input[data-pd]")) {
    if (input.dataset.pd === "this") input.checked = model.on;
    else if (input.dataset.pd === "done") input.checked = rows.some((r) => r.id === input.dataset.id && r.done);
  }
}

// The sheet at the bell. +state+() the bell's state; +endpoint+() this
// device's push endpoint (a Promise; null without a subscription);
// +toggleThis+() the bell's subscribe / unsubscribe (resolves to its
// failure's message, or null); +api+ chi web's JSON (notifications.js's).
// @return {toggle(), refresh(), isOpen(), pop}
export function createPushDevices({ button, api, state, endpoint, toggleThis, now = () => Date.now(),
                                    doc = globalThis.document, win = globalThis.window }) {
  let info = null;
  let busy = false;
  let error = "";
  // Each load's turn: an older answer that arrives late is dropped.
  let loads = 0;

  const paint = () => {
    const model = sheetModel({ state: state(), info, busy, error, now: now() });
    render(sheetTemplate(model), shell.pop);
    syncSwitches(shell.pop, model);
  };
  const draw = () => { if (shell.isOpen()) paint(); };

  const shell = createChipPopover({
    id: "pushDevices", className: "ctx-popover push-devices", width: 340, el: doc.createElement("span"),
    anchor: "#notifyBtn", openers: "#notifyBtn", summary: () => ({}), sheet: true, label: "Notifications", doc, win,
    show: () => paint(),
    onClose: () => { error = ""; },
  });

  async function load() {
    const turn = ++loads;
    try {
      const at = await endpoint();
      const answer = await api("GET", `/api/push${at ? `?endpoint=${encodeURIComponent(at)}` : ""}`);
      if (turn !== loads) return;
      info = answer;
    } catch (e) {
      if (turn !== loads) return;
      error = `Can't read the devices: ${e?.message || e}`;
    }
    draw();
    shell.replace();
  }

  // One change at a time; the list is read again after it.
  async function change(run) {
    if (busy) return;
    busy = true;
    error = "";
    draw();
    try {
      error = (await run()) || "";
    } catch (e) {
      error = e?.message || String(e);
    } finally {
      busy = false;
    }
    await load();
  }

  shell.pop.addEventListener("change", (e) => {
    const input = e.target.closest?.("[data-pd]");
    if (!input) return;
    if (input.dataset.pd === "this") change(toggleThis);
    else if (input.dataset.pd === "done") {
      const id = input.dataset.id;
      const done = input.checked;
      change(() => api("PATCH", `${DEVICE_PATH}/${encodeURIComponent(id)}`, { prefs: { done } }).then(() => null));
    }
  });
  shell.pop.addEventListener("click", (e) => {
    const remove = e.target.closest?.('[data-pd="remove"]');
    if (!remove) return;
    const id = remove.dataset.id;
    change(() => api("DELETE", `${DEVICE_PATH}/${encodeURIComponent(id)}`).then(() => null));
  });

  return {
    pop: shell.pop,
    isOpen: shell.isOpen,
    // The bell's tap: open (drawn from what is known, then read again) or close.
    toggle() {
      if (shell.isOpen()) return shell.close();
      shell.open(button);
      return load();
    },
    // The bell's state changed elsewhere: redraw an open sheet.
    refresh: draw,
    // Read the devices again (specs await it).
    load,
  };
}
