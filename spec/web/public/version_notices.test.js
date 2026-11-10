// The owner page's chi versions (version_notices.js) over stand-in toasts,
// storage and api: one version toast at a time, an available release once
// per browser, Copy without a clipboard, the worker Restart's guard and
// confirm. The notices' words are update_notice.js' (update_notice.test.js).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { AVAILABLE_SHOWN_KEY, createVersionNotices } from "../../../lib/samagotchi/web/public/version_notices.js";
import { createSessionStore } from "../../../lib/samagotchi/web/public/session_store.js";

function harness({ stored = {}, confirms = true, clipboard = null, restartSession = async () => ({ version: "0.20.0" }),
                  current = {} } = {}) {
  const store = createSessionStore({ initial: { owner: "worker", workerVersion: "0.18.0", workerCompat: "restart_suggested",
                                               workerFeatures: ["restart"], ...current } });
  store.update({ selected: "s1aaaaaaaa" });
  const touches = [];
  store.on("infoBar", () => touches.push("infoBar"));
  const shown = [];
  const dismissed = [];
  let nextId = 0;
  const toasts = {
    show: (text, action = null, options = {}) => { shown.push({ text, action, options, id: ++nextId }); return nextId; },
    dismiss: (id) => dismissed.push(id),
  };
  const storage = { ...stored };
  const confirms_ = [];
  const restarts = [];
  const notices = createVersionNotices({
    store,
    toasts,
    dialog: document.createElement("dialog"),
    loadedVersion: "0.18.0",
    api: {
      updateChi: async () => ({}), restartWorkers: async () => ({}), restartWeb: async () => ({}),
      restartSession: async (id) => { restarts.push(id); return restartSession(id); },
    },
    confirm: (text) => { confirms_.push(text); return confirms; },
    reload: () => shown.push("reload"),
    clipboard: () => clipboard,
    storage: { read: (key) => storage[key] ?? null, write: (key, value) => { storage[key] = value; } },
  });
  return { notices, store, touches, shown, dismissed, storage, confirms: confirms_, restarts };
}

test("a newer notice supersedes the version toast before it: one at a time, sticky", () => {
  const h = harness();
  h.notices.notice({ version: "0.18.0", installed: "0.19.0" });
  h.notices.notice({ version: "0.19.0" });
  assert.equal(h.shown.length, 2);
  assert.deepEqual(h.dismissed, [null, 1]);
  assert.deepEqual(h.shown.map((t) => t.options), [{ sticky: true }, { sticky: true }]);
  assert.deepEqual(h.shown[0].action.map((a) => a.label), ["Restart workers", "Restart chi web"]);
  assert.equal(h.shown[1].action.label, "Reload");
  // The same snapshot again (a reconnect) says nothing new; the bar still redraws.
  h.notices.notice({ version: "0.19.0" });
  assert.equal(h.shown.length, 2);
  assert.equal(h.touches.length, 3);
});

test("an available release is shown once per browser: storage remembers it", () => {
  const h = harness();
  h.notices.notice({ version: "0.18.0", available: "0.19.0" });
  assert.equal(h.shown.length, 1);
  assert.equal(h.shown[0].action.label, "Update");
  assert.equal(h.storage[AVAILABLE_SHOWN_KEY], "0.19.0");

  const again = harness({ stored: { [AVAILABLE_SHOWN_KEY]: "0.19.0" } });
  again.notices.notice({ version: "0.18.0", available: "0.19.0" });
  assert.equal(again.shown.length, 0);
  again.notices.notice({ version: "0.18.0", available: "0.20.0" });
  assert.equal(again.shown.length, 1);
});

test("Copy without a clipboard names the command to run", async () => {
  const h = harness();
  h.notices.notice({ version: "0.18.0", available: "0.19.0", update_blocked: "checkout" });
  assert.equal(h.shown[0].action.label, "Copy");
  h.shown[0].action.run();
  assert.equal(h.shown.at(-1).text, "Clipboard unavailable; run git pull");

  const written = [];
  const withBoard = harness({ clipboard: { writeText: async (text) => { written.push(text); } } });
  withBoard.notices.notice({ version: "0.18.0", available: "0.19.0", update_blocked: "checkout" });
  withBoard.shown[0].action.run();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(written, ["git pull"]);
  assert.equal(withBoard.shown.at(-1).text, "Copied git pull");
});

test("versions() is the merged state the info bar reads", () => {
  const h = harness();
  h.notices.notice({ version: "0.18.0", installed: "0.19.0" });
  assert.equal(h.notices.versions().installed, "0.19.0");
  assert.equal(h.notices.versions().served, "0.18.0");
});

test("Restart asks first, marks the session restarting while it runs, and says how it went", async () => {
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  const slow = harness({ restartSession: () => held });
  slow.notices.notice({ version: "0.18.0", installed: "0.19.0" });
  const running = slow.notices.restart();
  assert.equal(slow.confirms.length, 1);
  assert.ok(slow.notices.restarting.has("s1aaaaaaaa"));
  // A second Restart while one is under way does nothing.
  await slow.notices.restart();
  assert.equal(slow.confirms.length, 1);
  assert.deepEqual(slow.restarts, ["s1aaaaaaaa"]);
  release({ version: "0.19.0" });
  await running;
  assert.equal(slow.notices.restarting.has("s1aaaaaaaa"), false);
  assert.equal(slow.shown.at(-1).text, "Restarted on chi 0.19.0");

  const refused = harness({ confirms: false });
  refused.notices.notice({ version: "0.18.0", installed: "0.19.0" });
  await refused.notices.restart();
  assert.deepEqual(refused.restarts, []);
});

test("Restart: no badge, or a worker that can't restart itself, asks nothing", async () => {
  const none = harness();
  await none.notices.restart();
  assert.deepEqual(none.confirms, []);
  const old = harness({ current: { workerFeatures: [] } });
  old.notices.notice({ version: "0.18.0", installed: "0.19.0" });
  await old.notices.restart();
  assert.deepEqual(old.confirms, []);
});

test("a failed Restart is a sticky toast", async () => {
  const h = harness({ restartSession: async () => { throw Object.assign(new Error("worker busy"), { status: 409 }); } });
  h.notices.notice({ version: "0.18.0", installed: "0.19.0" });
  await h.notices.restart();
  assert.deepEqual(h.shown.at(-1).options, { sticky: true });
  assert.match(h.shown.at(-1).text, /worker busy/);
  assert.equal(h.notices.restarting.size, 0);
});
