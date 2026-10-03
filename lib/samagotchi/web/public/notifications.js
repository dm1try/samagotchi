// Notifications (notify.js has the rules; this is the page's side): when a
// session needs the user (a question, an approval, a failed turn, a long
// turn done) and this tab is not in front, an OS notification (the bell
// turns them on) and a count in the title (always). One tag per event, so
// several tabs show one, and none while another chi tab is in front with it
// (notify.js, Several tabs).
//
// The browser parts come in as deps (globals by default) so the specs can
// drive it without a DOM.

import { sessionHash } from "./route.js";
import {
  NOTIFY_CHANNEL, attentionText, createNotifyGate, initialAttentionState, notifyState as bellState, trackAttention,
} from "./notify.js";

export const NOTIFY_KEY = "chi_notify";

const NOTIFY_TITLES = {
  on: "Notifications on: a session that needs you while this tab is in the background. Click to turn off",
  off: "Notify me when a session needs me while this tab is in the background",
  denied: "Notifications are blocked for this site in the browser's settings",
};

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
// @return {noticeSessions(type, data), noticeList(sessions), setBaseTitle(title), clearBadge()}
export function createNotifications({
  button,
  doc = globalThis.document,
  win = globalThis.window,
  NotificationApi = globalThis.Notification,
  storage = () => globalThis.localStorage,
  channel = defaultChannel(),
  gateOptions = {},
}) {
  let attention = initialAttentionState();
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

  function notifyWanted() {
    try { return storage().getItem(NOTIFY_KEY) === "1"; } catch (_) { return false; }
  }

  // "on" | "off" | "denied" | "unsupported" (notify.js)
  function notifyState() {
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
    button.title = NOTIFY_TITLES[state] || "";
    button.setAttribute("aria-pressed", state === "on" ? "true" : "false");
  }

  async function toggleNotify() {
    const state = notifyState();
    if (state === "unsupported" || state === "denied") return;
    let wanted = state !== "on";
    if (wanted && NotificationApi.permission !== "granted") {
      wanted = (await NotificationApi.requestPermission()) === "granted";
    }
    try { storage().setItem(NOTIFY_KEY, wanted ? "1" : "0"); } catch (_) {}
    renderNotifyBtn();
  }

  function showNotification(session, a) {
    if (notifyState() !== "on") return;
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
    if (doc.visibilityState === "visible") clearBadge();
  }
  doc.addEventListener("visibilitychange", backInFront);
  win.addEventListener("focus", backInFront);
  doc.addEventListener("pointerdown", clearBadge, true);
  doc.addEventListener("keydown", clearBadge, true);
  button.addEventListener("click", toggleNotify);
  renderNotifyBtn();

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
  };
}
