import test from "node:test";
import assert from "node:assert/strict";
import { NOTIFY_KEY, PUSH_DEVICE_KEY, SW_UPDATE_MS, createNotifications } from "../../../lib/samagotchi/web/public/notifications.js";

// A fake page: a document whose visibility and focus the test sets, a
// window, a bell, localStorage and the Notification API.
function fakePage({ front = false, permission = "granted", wanted = true, notification = true } = {}) {
  const listeners = {};
  const on = (target) => (type, fn) => { (listeners[`${target}:${type}`] ||= []).push(fn); };
  const fire = (key) => (listeners[key] || []).forEach((fn) => fn());
  const doc = {
    title: "",
    visibilityState: front ? "visible" : "hidden",
    focused: front,
    hasFocus() { return this.focused; },
    addEventListener: on("doc"),
  };
  const win = { isSecureContext: true, location: { hash: "" }, focus() { win.focused = true; }, addEventListener: on("win") };
  const attrs = {};
  const button = {
    hidden: false, dataset: {}, title: "",
    setAttribute(k, v) { attrs[k] = v; },
    addEventListener: on("button"),
  };
  const store = new Map(wanted ? [[NOTIFY_KEY, "1"]] : []);
  const storage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, v) };
  const shown = [];
  function NotificationApi(title, opts) {
    this.title = title;
    this.opts = opts;
    this.closed = false;
    this.close = () => { this.closed = true; };
    shown.push(this);
  }
  NotificationApi.permission = permission;
  NotificationApi.requestPermission = async () => NotificationApi.permission;
  const page = createNotifications({
    button, doc, win, storage: () => storage, channel: null,
    NotificationApi: notification ? NotificationApi : undefined,
  });
  return { page, doc, win, button, attrs, store, shown, fire, NotificationApi };
}

const session = (extra = {}) => ({ id: "s1", first_preview: "fix the build", pending_question: null, last_turn: null, ...extra });
const asking = session({ pending_question: { id: "q1", kind: "question" } });

test("a question while the tab is behind badges the title and notifies, tagged by its key", () => {
  const { page, doc, shown } = fakePage();
  page.setBaseTitle("Chi · proj");
  page.noticeSessions("snapshot", { sessions: [session()] });
  assert.equal(doc.title, "Chi · proj");
  page.noticeSessions("session", { session: asking });
  assert.equal(doc.title, "(1) Chi · proj");
  assert.equal(shown.length, 1);
  assert.equal(shown[0].title, "fix the build");
  assert.deepEqual(shown[0].opts, { body: "needs an answer", tag: "s1:q1" });
});

test("clicking the notification opens its session", () => {
  const { page, win, shown } = fakePage();
  page.noticeSessions("snapshot", { sessions: [session()] });
  page.noticeSessions("session", { session: asking });
  shown[0].onclick();
  assert.equal(win.location.hash, "#/s/s1");
  assert.equal(win.focused, true);
  assert.equal(shown[0].closed, true);
});

test("the tab in front neither badges nor notifies", () => {
  const { page, doc, shown } = fakePage({ front: true });
  page.setBaseTitle("Chi");
  page.noticeSessions("snapshot", { sessions: [session()] });
  page.noticeSessions("session", { session: asking });
  assert.equal(doc.title, "Chi");
  assert.equal(shown.length, 0);
});

test("the bell off: the title still counts, no OS notification", () => {
  const { page, doc, shown, button } = fakePage({ wanted: false });
  assert.equal(button.dataset.state, "off");
  page.noticeSessions("snapshot", { sessions: [session()] });
  page.noticeSessions("session", { session: asking });
  assert.equal(doc.title, "(1) Chi");
  assert.equal(shown.length, 0);
});

test("an answered question leaves the badge", () => {
  const { page, doc } = fakePage();
  page.noticeSessions("snapshot", { sessions: [session()] });
  page.noticeSessions("session", { session: asking });
  page.noticeSessions("session", { session: session() });
  assert.equal(doc.title, "Chi");
});

test("the page turning visible clears the badge", () => {
  const { page, doc, fire } = fakePage();
  page.noticeSessions("snapshot", { sessions: [session()] });
  page.noticeSessions("session", { session: asking });
  fire("doc:visibilitychange");
  assert.equal(doc.title, "(1) Chi", "still hidden: kept");
  doc.visibilityState = "visible";
  fire("doc:visibilitychange");
  assert.equal(doc.title, "Chi");
});

test("the bell: its state, and a click toggles the stored choice", async () => {
  const { button, attrs, store, fire } = fakePage();
  assert.equal(button.dataset.state, "on");
  assert.equal(attrs["aria-pressed"], "true");
  assert.equal(button.hidden, false);
  fire("button:click");
  await new Promise((r) => setImmediate(r));
  assert.equal(store.get(NOTIFY_KEY), "0");
  assert.equal(button.dataset.state, "off");
  assert.equal(attrs["aria-pressed"], "false");
});

test("the bell is hidden without the Notification API, blocked when denied", () => {
  assert.equal(fakePage({ notification: false }).button.hidden, true);
  const denied = fakePage({ permission: "denied" }).button;
  assert.equal(denied.dataset.state, "denied");
  assert.match(denied.title, /blocked/);
});

test("a fetched list (no hub: the refresh fallback) notifies as the hub's snapshots do (4.12)", () => {
  const { page, doc, shown } = fakePage();
  page.noticeList([session()]);
  assert.equal(shown.length, 0, "the first list only seeds");
  page.noticeList([asking]);
  assert.equal(doc.title, "(1) Chi");
  assert.deepEqual(shown.map((n) => n.opts.tag), ["s1:q1"]);
  page.noticeList([session()]);
  assert.equal(doc.title, "Chi", "answered: the badge goes");
});

// ── The Home Screen app: Web Push ─────────────────────────────────────────
// A standalone app (push.js pushSupported) with a service worker whose
// pushManager the test holds, and chi web's push routes as a fake api.
// +tags+ are the notifications already on the device (its getNotifications);
// +device+ logs what the page did to them and to the app's badge.
function fakeApp({ enabled = true, subscribed = false, known = subscribed, permission = "default", grant = "granted", failPost = null,
  tags = [], scoped = false, visible = false, saved = {}, throwingStorage = false, failUpdate = false } = {}) {
  const calls = [];
  const device = [];
  const delivered = tags.map((tag) => ({ tag, closed: false }));
  let current = subscribed ? fakeSub("https://web.push.apple.com/have") : null;
  function fakeSub(endpoint, key = new Uint8Array([1, 2, 3])) {
    return {
      endpoint,
      options: { applicationServerKey: key.buffer },
      unsubscribe: async () => { calls.push(["unsubscribe", endpoint]); current = null; return true; },
      toJSON: () => ({ endpoint, keys: { p256dh: "P", auth: "A" } }),
    };
  }
  const reg = {
    update: async () => { calls.push(["update"]); if (failUpdate) throw new Error("offline"); },
    getNotifications: async () => delivered.filter((n) => !n.closed)
      .map((n) => ({ tag: n.tag, close: () => { n.closed = true; device.push(["close", n.tag]); } })),
    pushManager: {
      getSubscription: async () => current,
      subscribe: async (opts) => { calls.push(["subscribe", [...opts.applicationServerKey]]); current = fakeSub("https://web.push.apple.com/new"); return current; },
    },
  };
  const nav = {
    serviceWorker: { register: async (url, opts) => { calls.push(["register", url, opts.scope]); return reg; } },
    setAppBadge: async (n) => { device.push(["badge", n]); },
    clearAppBadge: async () => { device.push(["badge", 0]); },
  };
  const api = async (method, path, body) => {
    calls.push([method, path, body]);
    if (method === "GET") return { enabled, public_key: enabled ? "AQID" : null, origin: "https://s.example", this: known ? { id: "abcd1234", label: "iPhone" } : null };
    if (method === "POST" && path === "/api/push/subscriptions" && failPost) throw new Error(failPost);
    return method === "POST" && path === "/api/push/subscriptions" ? { id: "abcd1234", label: "iPhone" } : null;
  };
  const listeners = {};
  const on = (target) => (type, fn) => { (listeners[`${target}:${type}`] ||= []).push(fn); };
  const doc = { title: "", visibilityState: visible ? "visible" : "hidden", hasFocus: () => false, addEventListener: on("doc") };
  const win = {
    isSecureContext: true, location: { hash: "" }, PushManager: function PushManager() {},
    matchMedia: () => ({ matches: true }), focus() {}, addEventListener: on("win"),
  };
  const button = { hidden: false, dataset: {}, title: "", setAttribute() {}, addEventListener: on("button") };
  const shown = [];
  function NotificationApi(title, opts) { shown.push({ title, opts }); this.close = () => {}; }
  NotificationApi.permission = permission;
  NotificationApi.requestPermission = async () => { calls.push(["requestPermission"]); NotificationApi.permission = grant; return grant; };
  // localStorage: the bell's in-tab choice on, and +saved+.
  const kept = new Map([[NOTIFY_KEY, "1"], ...Object.entries(saved)]);
  const storage = () => {
    if (throwingStorage) throw new Error("SecurityError");
    return { getItem: (k) => (kept.has(k) ? kept.get(k) : null), setItem: (k, v) => kept.set(k, String(v)), removeItem: (k) => kept.delete(k) };
  };
  const clock = { ms: 1_000_000 };
  const page = createNotifications({ button, doc, win, nav, api, storage, channel: null, NotificationApi, scoped, now: () => clock.ms });
  const tap = async () => { for (const fn of listeners["button:click"]) await fn(); };
  const fire = (key) => (listeners[key] || []).forEach((fn) => fn());
  const synced = async () => { await page.syncing(); };
  return { page, button, calls, shown, doc, tap, NotificationApi, device, delivered, fire, synced, kept, clock,
    revoke: () => { current = null; } };
}

test("in the Home Screen app the bell subscribes this device: permission from the tap, chi web's key, a test push", async () => {
  const app = fakeApp();
  await app.page.pushReady;
  assert.equal(app.button.dataset.state, "off");
  assert.match(app.button.title, /^Notify this phone/);
  assert.deepEqual(app.calls.slice(0, 2), [["register", "/sw.js", "/"], ["GET", "/api/push", undefined]]);

  app.calls.length = 0;
  await app.tap();
  assert.deepEqual(app.calls, [
    ["requestPermission"],
    ["subscribe", [1, 2, 3]],
    ["POST", "/api/push/subscriptions", { subscription: { endpoint: "https://web.push.apple.com/new", keys: { p256dh: "P", auth: "A" } } }],
    ["POST", "/api/push/test", { endpoint: "https://web.push.apple.com/new" }],
  ]);
  assert.equal(app.button.dataset.state, "on");
  assert.match(app.button.title, /^Notifications to this phone: on/);
});

test("a device chi web already has is on; a tap unsubscribes it and tells chi web", async () => {
  const app = fakeApp({ subscribed: true, permission: "granted" });
  await app.page.pushReady;
  assert.deepEqual(app.calls[1], ["GET", `/api/push?endpoint=${encodeURIComponent("https://web.push.apple.com/have")}`, undefined]);
  assert.equal(app.button.dataset.state, "on");
  app.calls.length = 0;
  await app.tap();
  assert.deepEqual(app.calls, [["unsubscribe", "https://web.push.apple.com/have"],
    ["DELETE", "/api/push/subscriptions", { endpoint: "https://web.push.apple.com/have" }]]);
  assert.equal(app.button.dataset.state, "off");
});

test("a subscription chi web doesn't have (another origin, a reset store) shows off and subscribes again", async () => {
  const app = fakeApp({ subscribed: true, known: false, permission: "granted" });
  await app.page.pushReady;
  assert.equal(app.button.dataset.state, "off");
  await app.tap();
  assert.equal(app.button.dataset.state, "on");
  assert.ok(app.calls.some((c) => c[1] === "/api/push/subscriptions" && c[0] === "POST"));
});

test("permission refused leaves it off; blocked shows denied", async () => {
  const refused = fakeApp({ grant: "denied" });
  await refused.page.pushReady;
  await refused.tap();
  assert.equal(refused.button.dataset.state, "denied");
  assert.equal(refused.calls.filter((c) => c[0] === "subscribe").length, 0);
});

test("a refusal from chi web is said on the bell, which stays off", async () => {
  const app = fakeApp({ permission: "granted", failPost: "chi web only pushes to the browsers' push services, not x" });
  await app.page.pushReady;
  await app.tap();
  assert.equal(app.button.dataset.state, "off");
  assert.match(app.button.title, /failed: chi web only pushes/);
});

test("chi web without push (no https public URL): the bell is the in-tab one", async () => {
  const app = fakeApp({ enabled: false, permission: "granted" });
  await app.page.pushReady;
  assert.match(app.button.title, /while this tab is in the background/);
  assert.equal(app.calls.filter((c) => c[0] === "subscribe").length, 0);
});

test("in the app the tab's own OS notification is left to the push; the title still counts", async () => {
  const app = fakeApp({ subscribed: true, permission: "granted" });
  await app.page.pushReady;
  app.page.noticeSessions("snapshot", { sessions: [session()] });
  app.page.noticeSessions("session", { session: asking });
  assert.equal(app.shown.length, 0);
  assert.equal(app.doc.title, "(1) Chi");
});

// ── The device's tidy-up (no close push: WebKit's silent-push quota) ─────
const approval = (id, q) => session({ id, pending_question: { id: q, kind: "approval" } });

test("the app tidies the device only after the first snapshot: closes answered question tags, keeps chi's own, sets the badge", async () => {
  const app = fakeApp({ subscribed: true, permission: "granted", tags: ["a:q1", "b:q2", "chi:test"] });
  await app.page.pushReady;
  await app.synced();
  assert.deepEqual(app.device, [], "nothing before the snapshot");

  app.doc.visibilityState = "visible";
  app.page.noticeSessions("snapshot", { sessions: [approval("b", "q2"), session({ id: "a" })] });
  await app.synced();
  assert.deepEqual(app.device, [["close", "a:q1"], ["badge", 1]]);
  assert.deepEqual(app.delivered.map((n) => n.closed), [true, false, false]);
});

test("the app's tidy-up keeps an open continue's and card's banners, closes a resolved card's, never a failed turn's", async () => {
  const failedTag = "f:2026-10-25T09:05:12.345+02:00";
  const app = fakeApp({ subscribed: true, permission: "granted", tags: ["c:c1", "k:card:k1", "g:card:k2", failedTag] });
  await app.page.pushReady;
  app.doc.visibilityState = "visible";
  app.page.noticeSessions("snapshot", { sessions: [
    session({ id: "c", pending_question: { id: "c1", kind: "continue" } }),
    session({ id: "k", pending_card: { id: "k1", bundle: "check-in" } }),
    session({ id: "g" }),
    session({ id: "f" }),
  ] });
  await app.synced();
  assert.deepEqual(app.device, [["close", "g:card:k2"], ["badge", 2]]);
});

test("the app tidies again when it comes back to the front, and after a session frame while visible", async () => {
  const app = fakeApp({ subscribed: true, permission: "granted", tags: ["a:q1", "b:q2"] });
  await app.page.pushReady;
  app.page.noticeSessions("snapshot", { sessions: [approval("a", "q1"), approval("b", "q2")] });
  await app.synced();
  assert.deepEqual(app.device, [], "hidden: no tidy on the frame");

  app.doc.visibilityState = "visible";
  app.fire("doc:visibilitychange");
  await app.synced();
  assert.deepEqual(app.device, [["badge", 2]]);

  app.device.length = 0;
  app.page.noticeSessions("session", { session: session({ id: "a" }) });
  await app.synced();
  assert.deepEqual(app.device, [["close", "a:q1"], ["badge", 1]]);
});

test("a tidy asked for while one runs runs once more after it", async () => {
  const app = fakeApp({ subscribed: true, permission: "granted", tags: ["a:q1", "b:q2"], visible: true });
  await app.page.pushReady;
  await app.synced();
  app.page.noticeSessions("snapshot", { sessions: [approval("a", "q1"), approval("b", "q2")] });
  app.page.noticeSessions("session", { session: session({ id: "a" }) });
  app.page.noticeSessions("session", { session: session({ id: "b" }) });
  await app.synced();
  assert.deepEqual(app.delivered.map((n) => n.closed), [true, true]);
  assert.deepEqual(app.device.at(-1), ["badge", 0]);
});

test("a project's page (?dir=) never tidies the device", async () => {
  const app = fakeApp({ subscribed: true, permission: "granted", tags: ["a:q1"], scoped: true, visible: true });
  await app.page.pushReady;
  app.page.noticeSessions("snapshot", { sessions: [session({ id: "b" })] });
  app.fire("doc:visibilitychange");
  await app.synced();
  assert.deepEqual(app.device, []);
});

test("with the bell off the app neither tidies nor badges; turning it off clears the badge", async () => {
  const off = fakeApp({ permission: "granted", tags: ["a:q1"], visible: true });
  await off.page.pushReady;
  off.page.noticeSessions("snapshot", { sessions: [approval("b", "q2")] });
  await off.synced();
  assert.deepEqual(off.device, []);

  const on = fakeApp({ subscribed: true, permission: "granted", visible: true });
  await on.page.pushReady;
  on.page.noticeSessions("snapshot", { sessions: [approval("b", "q2")] });
  await on.synced();
  on.device.length = 0;
  await on.tap();
  assert.deepEqual(on.device, [["badge", 0]]);
});

// ── The device id: a subscription iOS revoked silently leaves the store ──
test("the app keeps the device id chi web gave and sends it as replaces on the next subscribe", async () => {
  const app = fakeApp({ permission: "granted" });
  await app.page.pushReady;
  await app.tap();
  assert.equal(app.kept.get(PUSH_DEVICE_KEY), "abcd1234");

  const again = fakeApp({ permission: "granted", saved: { [PUSH_DEVICE_KEY]: "dead0001" } });
  await again.page.pushReady;
  await again.tap();
  const post = again.calls.find((c) => c[0] === "POST" && c[1] === "/api/push/subscriptions");
  assert.equal(post[2].replaces, "dead0001");
  assert.equal(again.kept.get(PUSH_DEVICE_KEY), "abcd1234");
});

test("turning the bell off forgets the device id; with no subscription left to delete it is kept", async () => {
  const app = fakeApp({ subscribed: true, permission: "granted", saved: { [PUSH_DEVICE_KEY]: "abcd1234" } });
  await app.page.pushReady;
  await app.tap();
  assert.equal(app.kept.has(PUSH_DEVICE_KEY), false);

  const revoked = fakeApp({ subscribed: true, permission: "granted", saved: { [PUSH_DEVICE_KEY]: "abcd1234" } });
  await revoked.page.pushReady;
  revoked.revoke(); // iOS dropped the subscription while the app was on
  revoked.calls.length = 0;
  await revoked.tap();
  assert.deepEqual(revoked.calls, [], "nothing to unsubscribe or delete");
  assert.equal(revoked.button.dataset.state, "off");
  assert.equal(revoked.kept.get(PUSH_DEVICE_KEY), "abcd1234");
});

test("a storage that throws: the bell still subscribes, without replaces", async () => {
  const app = fakeApp({ permission: "granted", throwingStorage: true });
  await app.page.pushReady;
  await app.tap();
  assert.equal(app.button.dataset.state, "on");
  const post = app.calls.find((c) => c[0] === "POST" && c[1] === "/api/push/subscriptions");
  assert.equal("replaces" in post[2], false);
});

// ── A long-lived Home Screen app picks up a new sw.js ─────────────────────
const updates = (app) => app.calls.filter((c) => c[0] === "update").length;

test("coming back to the front asks for a newer service worker, at most once per SW_UPDATE_MS", async () => {
  const app = fakeApp({ subscribed: true, permission: "granted", visible: true });
  await app.page.pushReady;
  app.fire("doc:visibilitychange");
  assert.equal(updates(app), 0, "register() has just checked");

  app.clock.ms += SW_UPDATE_MS;
  app.fire("doc:visibilitychange");
  app.fire("win:focus");
  assert.equal(updates(app), 1);

  app.clock.ms += SW_UPDATE_MS - 1;
  app.fire("doc:visibilitychange");
  assert.equal(updates(app), 1);
  app.clock.ms += 1;
  app.doc.visibilityState = "hidden";
  app.fire("doc:visibilitychange");
  assert.equal(updates(app), 1, "hidden: not back in front");
  app.doc.visibilityState = "visible";
  app.fire("doc:visibilitychange");
  assert.equal(updates(app), 2);
});

test("the update is asked whether the bell is on or off, never without push, and a failing one is swallowed", async () => {
  const off = fakeApp({ permission: "granted", visible: true });
  await off.page.pushReady;
  off.clock.ms += SW_UPDATE_MS;
  off.fire("doc:visibilitychange");
  assert.equal(updates(off), 1);

  const none = fakeApp({ enabled: false, permission: "granted", visible: true });
  await none.page.pushReady;
  none.clock.ms += SW_UPDATE_MS;
  none.fire("doc:visibilitychange");
  assert.equal(updates(none), 0);

  const failing = fakeApp({ subscribed: true, permission: "granted", visible: true, failUpdate: true });
  await failing.page.pushReady;
  failing.clock.ms += SW_UPDATE_MS;
  failing.fire("doc:visibilitychange");
  await new Promise((r) => setImmediate(r));
  assert.equal(updates(failing), 1);
});
