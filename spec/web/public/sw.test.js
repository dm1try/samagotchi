import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const SOURCE = readFileSync(new URL("../../../lib/samagotchi/web/public/sw.js", import.meta.url), "utf8");

const plain = (value) => JSON.parse(JSON.stringify(value));

// sw.js in a vm context with a fake service worker scope: its registration
// (notifications shown, closed), clients (windows) and navigator (badge).
function loadWorker({ windows = [] } = {}) {
  const listeners = {};
  const shown = [];
  const log = [];
  const registration = {
    showNotification: async (title, opts) => { shown.push({ title, ...plain(opts), closed: false }); },
    getNotifications: async ({ tag }) => shown.filter((n) => n.tag === tag && !n.closed)
      .map((n) => ({ close: () => { n.closed = true; log.push(["close", tag]); } })),
  };
  const clients = {
    matchAll: async (opts) => { log.push(["matchAll", plain(opts)]); return windows; },
    openWindow: async (url) => { log.push(["openWindow", url]); },
    claim: async () => { log.push(["claim"]); },
  };
  const self = {
    registration,
    navigator: {
      setAppBadge: async (n) => log.push(["badge", n]),
      clearAppBadge: async () => log.push(["badge", 0]),
    },
    skipWaiting: () => log.push(["skipWaiting"]),
    addEventListener: (type, fn) => { listeners[type] = fn; },
  };
  // Objects made in the vm have its prototypes: the fakes keep plain copies.
  vm.runInNewContext(SOURCE, { self, clients });
  const fire = async (type, event) => {
    let done = Promise.resolve();
    listeners[type]({ ...event, waitUntil: (p) => { done = p; } });
    await done;
  };
  const push = (payload) => fire("push", { data: { json: () => payload } });
  return { listeners, shown, log, fire, push };
}

test("a show push shows the notification with its tag and url, and sets the badge", async () => {
  const w = loadWorker();
  await w.push({ v: 1, kind: "show", tag: "s1:q1", title: "fix the build", body: "needs approval", url: "/#/s/s1", badge: 2 });
  assert.equal(w.shown.length, 1);
  assert.deepEqual(w.shown[0], { title: "fix the build", body: "needs approval", tag: "s1:q1", icon: "/icons/chi-192.png",
    data: { url: "/#/s/s1" }, closed: false });
  assert.deepEqual(w.log, [["badge", 2]]);
});

test("a close push closes that tag's notifications only, shows nothing, and sets the badge", async () => {
  const w = loadWorker();
  await w.push({ v: 1, kind: "show", tag: "a:q1", title: "a", body: "x", url: "/#/s/a", badge: 1 });
  await w.push({ v: 1, kind: "show", tag: "a:q1", title: "a", body: "x", url: "/#/s/a", badge: 1 });
  await w.push({ v: 1, kind: "show", tag: "b:q2", title: "b", body: "x", url: "/#/s/b", badge: 2 });
  w.log.length = 0;
  await w.push({ v: 1, kind: "close", tags: ["a:q1"], badge: 1 });
  assert.deepEqual(w.shown.map((n) => [n.tag, n.closed]), [["a:q1", true], ["a:q1", true], ["b:q2", false]]);
  assert.deepEqual(w.log, [["close", "a:q1"], ["close", "a:q1"], ["badge", 1]]);
  await w.push({ v: 1, kind: "close", tags: ["b:q2"], badge: 0 });
  assert.deepEqual(w.log.at(-1), ["badge", 0]);
});

test("a push it can't read, or of another version, does nothing", async () => {
  const w = loadWorker();
  await w.fire("push", { data: { json: () => { throw new Error("not JSON"); } } });
  await w.fire("push", { data: null });
  await w.push({ v: 2, kind: "show", title: "x" });
  assert.deepEqual([w.shown, w.log], [[], []]);
});

test("a tap focuses the app's window and navigates it to the session", async () => {
  const win = { log: [], focus: async () => win.log.push("focus"), navigate: async (url) => win.log.push(["navigate", url]) };
  const w = loadWorker({ windows: [win] });
  let closed = false;
  await w.fire("notificationclick", { notification: { data: { url: "/#/s/s1" }, close: () => { closed = true; } } });
  assert.equal(closed, true);
  assert.deepEqual(w.log, [["matchAll", { type: "window", includeUncontrolled: true }]]);
  assert.deepEqual(win.log, ["focus", ["navigate", "/#/s/s1"]]);
});

test("a tap with no window opens one, and only at a path of chi web's", async () => {
  const w = loadWorker();
  await w.fire("notificationclick", { notification: { data: { url: "/#/s/s1" }, close() {} } });
  await w.fire("notificationclick", { notification: { data: { url: "https://evil.example/" }, close() {} } });
  await w.fire("notificationclick", { notification: { data: { url: "//evil.example/" }, close() {} } });
  await w.fire("notificationclick", { notification: { data: { url: "/\\evil.example/" }, close() {} } });
  assert.deepEqual(w.log.filter((e) => e[0] === "openWindow"),
    [["openWindow", "/#/s/s1"], ["openWindow", "/"], ["openWindow", "/"], ["openWindow", "/"]]);
});

test("install skips waiting and activate claims the clients; no fetch handler", async () => {
  const w = loadWorker();
  w.listeners.install({});
  await w.fire("activate", {});
  assert.deepEqual(w.log, [["skipWaiting"], ["claim"]]);
  assert.equal(w.listeners.fetch, undefined);
});
