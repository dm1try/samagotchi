import { htmlOf, markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  createPushDevices, deviceRows, sheetModel, sheetTemplate, staleText,
} from "../../../lib/samagotchi/web/public/push_devices.js";

const NOW = Date.parse("2026-10-25T12:00:00Z");
const iso = (ms) => new Date(ms).toISOString();
const device = (over = {}) => ({
  id: "9f8e7d6c", label: "iPad · 2026-10-20", origin: "https://s.example", created_at: iso(NOW - 5 * 864e5),
  last_ok_at: iso(NOW - 2 * 864e5), last_error: null, prefs: { done: true }, this: false, ...over,
});
const mine = device({ id: "a1b2c3d4", label: "iPhone · 2026-10-24", last_ok_at: iso(NOW - 4 * 60e3), prefs: { done: false }, this: true });
const info = (devices = [device(), mine], stale = 0) => ({ enabled: true, public_key: "K", origin: "https://s.example", devices, stale });

test("push devices: rows put this device first, with the last delivery, error and done", () => {
  const rows = deviceRows(info([device({ last_error: "500", last_ok_at: null }), mine]), NOW);
  assert.deepEqual(rows.map((r) => [r.id, r.this, r.last, r.error, r.done]), [
    ["a1b2c3d4", true, "last delivery 4 min ago", "", false],
    ["9f8e7d6c", false, "no delivery yet", "last error 500", true],
  ]);
  assert.deepEqual(deviceRows(null, NOW), []);
});

test("push devices: the stale ones are one line, none for zero", () => {
  assert.equal(staleText(0), "");
  assert.equal(staleText(undefined), "");
  assert.match(staleText(1), /^1 more device from an earlier address, never sent to/);
  assert.match(staleText(3), /^3 more devices/);
});

test("push devices: the sheet shows this device's switch (never Remove), Remove and done for the others, never an endpoint", () => {
  const markup = markupOf(sheetTemplate(sheetModel({ state: "on", info: info([device(), mine], 2), now: NOW })));
  const div = document.createElement("div");
  div.innerHTML = markup;
  const rows = [...div.querySelectorAll(".pd-row")];
  assert.deepEqual(rows.map((r) => r.dataset.id), ["a1b2c3d4", "9f8e7d6c"]);
  assert.ok(rows[0].querySelector(".pd-tag").textContent.includes("this device"));
  assert.ok(rows[0].querySelector('[data-pd="this"]'));
  assert.equal(rows[0].querySelector('[data-pd="remove"]'), null);
  assert.equal(rows[1].querySelector('[data-pd="this"]'), null);
  assert.equal(rows[1].querySelector('[data-pd="remove"]').dataset.id, "9f8e7d6c");
  assert.equal(rows.map((r) => r.querySelectorAll('[data-pd="done"]').length).join(), "1,1");
  assert.match(div.textContent, /2 more devices from an earlier address/);
  assert.doesNotMatch(markup, /web\.push\.apple\.com|p256dh/);
});

test("push devices: off, this device's row says so and has no done switch; denied disables the switch", () => {
  const off = sheetModel({ state: "off", info: info([device()]), now: NOW });
  assert.equal(off.on, false);
  assert.equal(off.thisRow.label, "This device");
  const div = document.createElement("div");
  div.innerHTML = markupOf(sheetTemplate(off));
  const first = div.querySelector(".pd-row");
  assert.equal(first.querySelector('[data-pd="done"]'), null);
  assert.match(first.textContent, /off: nothing is pushed here/);
  const denied = sheetModel({ state: "denied", info: info([]), now: NOW });
  assert.ok(denied.denied);
  assert.match(denied.thisRow.last, /blocked/);
});

// The sheet at a real bell (happy-dom): its api calls and redraws.
function sheetAt({ state = "on", answers = info(), toggleThis = async () => null, refuse = null } = {}) {
  const button = document.createElement("button");
  button.id = "notifyBtn";
  document.body.appendChild(button);
  const calls = [];
  const api = async (method, path, body) => {
    calls.push([method, path, body]);
    if (method === refuse) throw new Error("HTTP 500");
    return method === "GET" ? answers : null;
  };
  const sheet = createPushDevices({ button, api, state: () => state, toggleThis, now: () => NOW,
    endpoint: async () => "https://web.push.apple.com/QGthis", doc: document, win: window });
  const tick = () => new Promise((r) => setTimeout(r, 0));
  return { sheet, calls, button, tick, done: () => { sheet.pop.remove(); button.remove(); } };
}

test("push devices: the bell's tap opens it and reads the devices with this device's endpoint; a second closes it", async () => {
  const s = sheetAt();
  await s.sheet.toggle();
  assert.ok(s.sheet.isOpen());
  assert.deepEqual(s.calls, [["GET", `/api/push?endpoint=${encodeURIComponent("https://web.push.apple.com/QGthis")}`, undefined]]);
  assert.equal(s.sheet.pop.querySelectorAll(".pd-row").length, 2);
  s.sheet.toggle();
  assert.equal(s.sheet.isOpen(), false);
  s.done();
});

test("push devices: the done switch PATCHes the device, Remove DELETEs it by id, each then reads the list again", async () => {
  const s = sheetAt();
  await s.sheet.toggle();
  s.calls.length = 0;
  const done = s.sheet.pop.querySelector('.pd-row[data-id="9f8e7d6c"] [data-pd="done"]');
  done.checked = false;
  done.dispatchEvent(new window.Event("change", { bubbles: true }));
  await s.tick(); await s.tick();
  assert.deepEqual(s.calls[0], ["PATCH", "/api/push/subscriptions/9f8e7d6c", { prefs: { done: false } }]);
  assert.equal(s.calls[1][0], "GET");
  s.calls.length = 0;
  s.sheet.pop.querySelector('[data-pd="remove"]').click();
  await s.tick(); await s.tick();
  assert.deepEqual(s.calls[0], ["DELETE", "/api/push/subscriptions/9f8e7d6c", undefined]);
  assert.equal(s.calls[1][0], "GET");
  assert.ok(s.sheet.isOpen(), "a click in the sheet keeps it open");
  s.done();
});

test("push devices: this device's switch is the bell's toggle (never the id route); its failure shows in the sheet", async () => {
  let toggled = 0;
  const s = sheetAt({ toggleThis: async () => { toggled += 1; return "Notifications to this phone failed: nope"; } });
  await s.sheet.toggle();
  s.calls.length = 0;
  const sw = s.sheet.pop.querySelector('[data-pd="this"]');
  sw.checked = false;
  sw.dispatchEvent(new window.Event("change", { bubbles: true }));
  await s.tick(); await s.tick();
  assert.equal(toggled, 1);
  assert.ok(s.calls.every((c) => c[0] === "GET"), JSON.stringify(s.calls));
  assert.match(htmlOf(s.sheet.pop), /failed: nope/);
  s.done();
});

test("push devices: a switch the app refuses goes back to the model (the same model redrawn)", async () => {
  // iOS's Don't Allow: the bell stays off, the sheet redraws with the same off model.
  const off = sheetAt({ state: "off", answers: info([device()]), toggleThis: async () => null });
  await off.sheet.toggle();
  const sw = off.sheet.pop.querySelector('[data-pd="this"]');
  sw.checked = true;
  sw.dispatchEvent(new window.Event("change", { bubbles: true }));
  await off.tick(); await off.tick();
  assert.equal(off.sheet.pop.querySelector('[data-pd="this"]').checked, false);
  off.done();

  // A failed PATCH: the server keeps done on, so the switch shows it on again.
  const s = sheetAt({ refuse: "PATCH" });
  await s.sheet.toggle();
  const done = s.sheet.pop.querySelector('.pd-row[data-id="9f8e7d6c"] [data-pd="done"]');
  done.checked = false;
  done.dispatchEvent(new window.Event("change", { bubbles: true }));
  await s.tick(); await s.tick();
  assert.equal(s.sheet.pop.querySelector('.pd-row[data-id="9f8e7d6c"] [data-pd="done"]').checked, true);
  assert.match(htmlOf(s.sheet.pop), /HTTP 500/);
  s.done();
});
