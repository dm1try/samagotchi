// Notifications (notify.js has the rules; this is the page's side): when a
// session needs the user (a question, an approval, a failed turn, a long
// turn done) and this tab is not in front, an OS notification (the bell
// turns them on) and a count in the title (always). One tag per event, so
// several tabs show one, and none while another chi tab is in front with it
// (notify.js, Several tabs).
//
// In the Home Screen app (push.js pushSupported) the bell means "push to
// this device" instead (Web Push): chi web pushes what needs the user (an
// approval, a question, a step-limit continue, a card, a failed turn) to it
// while the app is closed. chi web without push (no https public URL)
// leaves the bell as it is in a tab. With the bell on, the app also tidies
// the device (syncDevice): it closes the pushed notifications whose
// question or card isn't open any more and sets the app's badge, as chi
// web sends no close push (WebKit's silent-push quota).
//
// Every page, in a tab or the app, also tells chi web whether the user is
// at it (POST /api/push/presence, reportPresence): chi web pushes nothing
// while one is in front, as the user is looking (the iPhone's service
// worker can't see the app in front, so chi web decides).
//
// The browser parts come in as deps (globals by default) so the specs can
// drive it without a DOM.

import { sessionHash } from "./route.js";
import {
  NOTIFY_CHANNEL, attentionText, createNotifyGate, initialAttentionState, notifyState as bellState, randomTabId,
  trackAttention,
} from "./notify.js";
import {
  isWaitingTag, openPushKeys, pushSupported, subscribe as pushSubscribe, unsubscribe as pushUnsubscribe,
} from "./push.js";

export const NOTIFY_KEY = "chi_notify";
// The device id chi web gave this app's subscription (POST subscribe's
// answer): the next subscribe sends it as replaces, so a subscription iOS
// revoked silently (its push service keeps answering 201) leaves the store.
export const PUSH_DEVICE_KEY = "chi_push_device";
// A long-lived Home Screen app checks for a new sw.js at most this often
// when it comes back in front (reg.update()).
export const SW_UPDATE_MS = 60 * 60 * 1000;
// Presence: a page in front reports this often (chi web counts a report
// 45 s), and is in front only if touched this recently (a tab left focused
// on a screen nobody watches stops quieting the phone).
export const PRESENCE_PATH = "/api/push/presence";
export const PRESENCE_EVERY_MS = 30 * 1000;
export const TOUCH_FRESH_MS = 2 * 60 * 1000;

const NOTIFY_TITLES = {
  on: "Notifications on: a session that needs you while this tab is in the background. Click to turn off",
  off: "Notify me when a session needs me while this tab is in the background",
  denied: "Notifications are blocked for this site in the browser's settings",
};

const PUSH_TITLES = {
  on: "Notifications to this phone: on (a session that needs you or failed, also while the app is closed). Tap to turn off",
  off: "Notify this phone when a session needs you or a turn fails, also while the app is closed",
  denied: "Notifications are blocked for this app in the phone's settings",
};

// fetch's JSON, or an Error with chi web's detail.
async function defaultApi(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: body === undefined ? {} : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = res.status === 204 ? null : await res.json().catch(() => null);
  if (!res.ok) throw new Error(data?.detail || `HTTP ${res.status}`);
  return data;
}

// How a presence report goes: a beacon when the page is leaving (it
// outlives the page; same origin, so the cookie goes), else the api's
// fetch. Errors swallowed: a lost report only means a push or a quiet one.
// @return (body, leaving) => void
export function presenceSender({ nav, api, BlobApi = globalThis.Blob }) {
  return (body, leaving) => {
    if (leaving && typeof nav?.sendBeacon === "function" && typeof BlobApi === "function") {
      try {
        if (nav.sendBeacon(PRESENCE_PATH, new BlobApi([JSON.stringify(body)], { type: "application/json" }))) return;
      } catch (_) {}
    }
    try { api("POST", PRESENCE_PATH, body)?.catch?.(() => {}); } catch (_) {}
  };
}

function defaultChannel() {
  try {
    if (typeof globalThis.BroadcastChannel === "function") return new BroadcastChannel(NOTIFY_CHANNEL);
  } catch (_) {}
  return null;
}

// @param button the bell (#notifyBtn)
// @param doc, win the page's document and window (title, visibility, focus,
//   listeners)
// @param NotificationApi the Notification constructor (undefined: none)
// @param storage () => localStorage (it can throw)
// @param channel the BroadcastChannel to the other chi tabs, or null
// @param gateOptions passed to createNotifyGate (specs: schedule, now)
// @param nav the navigator (serviceWorker; push.js pushSupported)
// @param api (method, path, body) => Promise of chi web's JSON
// @param scoped the page shows one project's sessions (?dir=): it never
//   tidies the device, as it doesn't see the others'
// @param now () => ms (the service worker update's spacing, presence's
//   touch; specs)
// @param sendPresence (body, leaving) => void (presenceSender's by default)
// @param every (fn, ms) => void, a repeating timer (presence's tick)
// @param pageId this page load's id in its presence reports
// @return {noticeSessions(type, data), noticeList(sessions), setBaseTitle(title), clearBadge()}
export function createNotifications({
  button,
  doc = globalThis.document,
  win = globalThis.window,
  NotificationApi = globalThis.Notification,
  storage = () => globalThis.localStorage,
  channel = defaultChannel(),
  gateOptions = {},
  nav = globalThis.navigator,
  api = defaultApi,
  scoped = false,
  now = () => Date.now(),
  sendPresence = presenceSender({ nav, api }),
  every = (fn, ms) => setInterval(fn, ms),
  pageId = randomTabId(),
}) {
  let attention = initialAttentionState();
  // Web Push in the Home Screen app: null until chi web says it pushes
  // ({reg, key, on}), and for good in a tab or without push.
  let push = null;
  let pushBusy = false;
  let syncing = null;
  let syncAgain = false;
  // When this page last had the browser check for a newer sw.js.
  let swCheckedAt = null;
  const badgeKeys = new Set();
  let baseTitle = "Chi";

  function setTitle() {
    doc.title = badgeKeys.size ? `(${badgeKeys.size}) ${baseTitle}` : baseTitle;
  }

  // The user is looking at this tab: visible and focused (a window behind
  // the terminal is visible but not focused).
  function tabInFront() {
    return doc.visibilityState === "visible" && doc.hasFocus();
  }

  function stored(key) {
    try { return storage().getItem(key); } catch (_) { return null; }
  }

  function store(key, value) {
    try {
      if (value == null) storage().removeItem(key);
      else storage().setItem(key, value);
    } catch (_) {}
  }

  function notifyWanted() {
    try { return storage().getItem(NOTIFY_KEY) === "1"; } catch (_) { return false; }
  }

  // "on" | "off" | "denied" | "unsupported" (notify.js)
  function notifyState() {
    if (push) {
      if (typeof NotificationApi === "function" && NotificationApi.permission === "denied") return "denied";
      return push.on ? "on" : "off";
    }
    const hasNotification = typeof NotificationApi === "function";
    return bellState({
      hasNotification,
      secureContext: win.isSecureContext !== false,
      permission: hasNotification ? NotificationApi.permission : "default",
      wanted: notifyWanted(),
    });
  }

  function renderNotifyBtn() {
    const state = notifyState();
    button.hidden = state === "unsupported";
    button.dataset.state = state;
    button.title = (push ? PUSH_TITLES : NOTIFY_TITLES)[state] || "";
    button.setAttribute("aria-pressed", state === "on" ? "true" : "false");
  }

  async function toggleNotify() {
    if (push) return togglePush();
    const state = notifyState();
    if (state === "unsupported" || state === "denied") return;
    let wanted = state !== "on";
    if (wanted && NotificationApi.permission !== "granted") {
      wanted = (await NotificationApi.requestPermission()) === "granted";
    }
    try { storage().setItem(NOTIFY_KEY, wanted ? "1" : "0"); } catch (_) {}
    renderNotifyBtn();
  }

  // This device's subscription on (permission from the tap: iOS asks only
  // from one), a test push to show it works; or off.
  async function togglePush() {
    if (pushBusy || notifyState() === "denied") return;
    pushBusy = true;
    let failed = null;
    try {
      if (push.on) {
        const had = await pushUnsubscribe({ reg: push.reg, del: (endpoint) => api("DELETE", "/api/push/subscriptions", { endpoint }) });
        // Without a subscription to delete (revoked meanwhile) the id stays
        // for the next subscribe to replace.
        if (had) store(PUSH_DEVICE_KEY, null);
        push.on = false;
        setDeviceBadge(0);
      } else if (NotificationApi.permission === "granted" || (await NotificationApi.requestPermission()) === "granted") {
        const replaces = stored(PUSH_DEVICE_KEY);
        const { subscription, answer } = await pushSubscribe({
          reg: push.reg, key: push.key,
          post: (json) => api("POST", "/api/push/subscriptions", replaces ? { subscription: json, replaces } : { subscription: json }),
        });
        if (answer?.id) store(PUSH_DEVICE_KEY, answer.id);
        push.on = true;
        api("POST", "/api/push/test", { endpoint: subscription.endpoint }).catch(() => {});
        syncDevice();
      }
    } catch (e) {
      failed = e?.message || String(e);
    } finally {
      pushBusy = false;
    }
    renderNotifyBtn();
    // Said on the bell (its tooltip); the next tap tries again.
    if (failed) button.title = `Notifications to this phone failed: ${failed}`;
  }

  // The Home Screen app: its service worker, chi web's key, and whether
  // chi web has this device. A tab, or chi web without push: the bell as is.
  async function startPush() {
    if (typeof NotificationApi !== "function" || !pushSupported({ win, nav })) return;
    try {
      const reg = await nav.serviceWorker.register("/sw.js", { scope: "/" });
      const sub = await reg.pushManager.getSubscription();
      const query = sub ? `?endpoint=${encodeURIComponent(sub.endpoint)}` : "";
      const info = await api("GET", `/api/push${query}`);
      if (!info?.enabled || !info.public_key) return;
      push = { reg, key: info.public_key, on: !!(sub && info.this) };
      // register() has just checked for a newer sw.js.
      swCheckedAt = now();
      renderNotifyBtn();
    } catch (_) {}
    syncDevice();
  }

  // A Home Screen app can stay open for days: when it comes back in front
  // it asks for a newer sw.js, at most once per SW_UPDATE_MS.
  function updateWorker() {
    if (!push || typeof push.reg?.update !== "function") return;
    const at = now();
    if (swCheckedAt !== null && at - swCheckedAt < SW_UPDATE_MS) return;
    swCheckedAt = at;
    try { push.reg.update()?.catch?.(() => {}); } catch (_) {}
  }

  function setDeviceBadge(count) {
    try {
      const done = count > 0 && typeof nav?.setAppBadge === "function" ? nav.setAppBadge(count)
        : typeof nav?.clearAppBadge === "function" ? nav.clearAppBadge() : null;
      done?.catch?.(() => {});
    } catch (_) {}
  }

  // The Home Screen app with the bell on: closes the pushed notifications
  // whose question or card isn't open (chi's own, chi:test, and a failed
  // or done turn's stay) and sets the
  // app's badge. Never before the first snapshot (an empty byId would close
  // them all) nor on a project's page (its byId lacks the others). One at a
  // time; asked again meanwhile, it runs once more after.
  function syncDevice() {
    if (!push || !push.on || scoped || !attention.seeded) return syncing;
    if (syncing) {
      syncAgain = true;
      return syncing;
    }
    syncing = (async () => {
      do {
        syncAgain = false;
        const open = new Set(openPushKeys(attention.byId));
        try {
          const shown = await push.reg.getNotifications();
          for (const n of shown || []) if (isWaitingTag(n.tag) && !open.has(n.tag)) n.close();
        } catch (_) {}
        if (push?.on) setDeviceBadge(open.size);
      } while (syncAgain);
    })().finally(() => { syncing = null; });
    return syncing;
  }

  function showNotification(session, a) {
    // The app gets chi web's pushes instead.
    if (push || notifyState() !== "on") return;
    const { title, body } = attentionText(session, a);
    try {
      const n = new NotificationApi(title, { body, tag: a.key });
      n.onclick = () => {
        win.focus();
        win.location.hash = sessionHash(a.sessionId);
        n.close();
      };
    } catch (_) {}
  }

  // Another chi tab in front has these (notify.js, Several tabs).
  function seenElsewhere(keys) {
    const size = badgeKeys.size;
    for (const key of keys) badgeKeys.delete(key);
    if (badgeKeys.size !== size) setTitle();
  }
  const notifyGate = createNotifyGate({ ...gateOptions, channel, onSeen: seenElsewhere });

  // Every hub frame goes through here before the list takes it.
  function noticeSessions(type, data) {
    const next = trackAttention(attention, type, data);
    attention = next.state;
    const size = badgeKeys.size;
    for (const key of next.closed) badgeKeys.delete(key);
    notifyGate.drop(next.closed);
    if (next.attentions.length > 0 && tabInFront()) {
      notifyGate.seenInFront(next.attentions.map((a) => a.key));
    } else {
      for (const a of next.attentions) {
        // Every tab behind badges; one of them notifies (notify.js).
        notifyGate.offer(a, (notify) => {
          if (tabInFront()) return;
          badgeKeys.add(a.key);
          setTitle();
          if (notify) showNotification(attention.byId[a.sessionId], a);
        });
      }
    }
    if (badgeKeys.size !== size) setTitle();
    if (doc.visibilityState === "visible") syncDevice();
  }

  // The user is here: the badge goes, and the other tabs drop what it had.
  function clearBadge() {
    if (badgeKeys.size === 0) return;
    notifyGate.seenInFront([...badgeKeys]);
    badgeKeys.clear();
    setTitle();
  }

  // The user is back: the page turned visible (Safari makes it visible
  // before it has focus, and a tab switch inside a focused window sends no
  // focus event), the window got focus, or they touched the page.
  function backInFront() {
    if (doc.visibilityState !== "visible") return;
    clearBadge();
    syncDevice();
    updateWorker();
  }
  // ── Presence ──────────────────────────────────────────────────────────
  // Loading the page counts as a touch.
  let touchedAt = now();
  let reportedFront = null;
  const atPage = () => tabInFront() && now() - touchedAt < TOUCH_FRESH_MS;
  function reportPresence(front = atPage(), leaving = false) {
    reportedFront = front;
    sendPresence({ page: pageId, front }, leaving);
  }
  // The first touch that brings the page to the front (after being idle,
  // or behind) says so at once; the tick has the rest.
  function touched() {
    touchedAt = now();
    if (reportedFront !== true && atPage()) reportPresence(true);
  }
  // Every 30 s while in front, and once more when it no longer is (no
  // touch for 2 min).
  every(() => { if (reportedFront || atPage()) reportPresence(); }, PRESENCE_EVERY_MS);
  doc.addEventListener("visibilitychange", () => (doc.visibilityState === "visible" ? reportPresence() : reportPresence(false, true)));
  win.addEventListener("focus", () => reportPresence());
  win.addEventListener("blur", () => reportPresence(false));
  win.addEventListener("pagehide", () => reportPresence(false, true));
  for (const type of ["pointerdown", "keydown", "touchstart"]) doc.addEventListener(type, touched, { capture: true, passive: true });
  if (atPage()) reportPresence(true);

  doc.addEventListener("visibilitychange", backInFront);
  win.addEventListener("focus", backInFront);
  doc.addEventListener("pointerdown", clearBadge, true);
  doc.addEventListener("keydown", clearBadge, true);
  button.addEventListener("click", toggleNotify);
  renderNotifyBtn();
  const pushReady = startPush();

  return {
    noticeSessions,
    // The list fetched without a hub (app.js refresh): a snapshot.
    noticeList(sessions) {
      noticeSessions("snapshot", { sessions });
    },
    // The title without the badge ("Chi · <project>").
    setBaseTitle(title) {
      baseTitle = title;
      setTitle();
    },
    clearBadge,
    // Settles once the Home Screen app's push state is known (specs).
    pushReady,
    // The device's tidy-up in flight, or null (specs await it).
    syncing: () => syncing,
  };
}
