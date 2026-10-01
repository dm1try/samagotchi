import test from "node:test";
import assert from "node:assert/strict";
import { NOTIFY_KEY, createNotifications } from "../../../lib/samagotchi/web/public/notifications.js";

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
