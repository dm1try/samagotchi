import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const SOURCE = readFileSync(new URL("../../../lib/samagotchi/web/public/sw.js", import.meta.url), "utf8");

const plain = (value) => JSON.parse(JSON.stringify(value));

// sw.js in a vm context with a fake service worker scope: its registration
// (notifications shown, closed), clients (windows) and navigator (badge).
// +refuse+ rejects that many showNotification calls first; +listFails+
// makes getNotifications throw.
function loadWorker({ windows = [], refuse = 0, listFails = false } = {}) {
  const listeners = {};
  const shown = [];
  const log = [];
  let refusals = refuse;
  const registration = {
    showNotification: async (title, opts) => {
      if (refusals > 0) { refusals -= 1; throw new Error("refused"); }
      shown.push({ title, ...plain(opts), closed: false });
    },
    getNotifications: async (filter = {}) => {
      if (listFails) throw new Error("no list");
      return shown.filter((n) => (filter.tag === undefined || n.tag === filter.tag) && !n.closed)
        .map((n) => ({ tag: n.tag, close: () => { n.closed = true; log.push(["close", n.tag]); } }));
    },
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

const show = (tag, extra = {}) => ({ v: 1, kind: "show", tag, title: tag, body: "x", url: `/#/s/${tag}`, ...extra });

test("a show with open shows first, then closes the answered ones, keeping the listed, chi's own and the new one", async () => {
  const w = loadWorker();
  await w.push(show("a:q1"));
  await w.push(show("b:q2"));
  await w.push({ v: 1, kind: "show", tag: "chi:test", title: "chi", body: "test notification", url: "/" });
  w.log.length = 0;
  await w.push(show("c:q3", { open: ["b:q2", "c:q3"], badge: 2 }));
  assert.deepEqual(w.shown.map((n) => [n.tag, n.closed]),
    [["a:q1", true], ["b:q2", false], ["chi:test", false], ["c:q3", false]]);
  assert.deepEqual(w.log, [["close", "a:q1"], ["badge", 2]]);
});

test("a show without open closes nothing; one without badge leaves the badge alone", async () => {
  const w = loadWorker();
  await w.push(show("a:q1"));
  await w.push(show("b:q2"));
  assert.deepEqual(w.shown.map((n) => n.closed), [false, false]);
  assert.deepEqual(w.log, []);
});

test("a cleanup that throws still leaves the show shown and the badge set", async () => {
  const w = loadWorker({ listFails: true });
  await w.push(show("a:q1", { open: ["a:q1"], badge: 1 }));
  assert.deepEqual(w.shown.map((n) => n.tag), ["a:q1"]);
  assert.deepEqual(w.log, [["badge", 1]]);
});

test("a show iOS refuses is shown again without the icon and data", async () => {
  const w = loadWorker({ refuse: 1 });
  await w.push(show("a:q1"));
  assert.deepEqual(w.shown, [{ title: "a:q1", body: "x", tag: "a:q1", closed: false }]);
});

test("every push shows something: an unreadable one, another version, a close or an unknown kind shows the fallback", async () => {
  const w = loadWorker();
  await w.fire("push", { data: { json: () => { throw new Error("not JSON"); } } });
  await w.fire("push", { data: null });
  await w.push({ v: 2, kind: "show", title: "x" });
  await w.push({ v: 1, kind: "close", tags: ["a:q1"], badge: 0 });
  await w.push({ v: 1, kind: "badge", badge: 3 });
  assert.equal(w.shown.length, 5);
  for (const n of w.shown) {
    assert.deepEqual(n, { title: "chi", body: "open chi", tag: "chi:other", icon: "/icons/chi-192.png", data: { url: "/" }, closed: false });
  }
  assert.deepEqual(w.log, []);
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
