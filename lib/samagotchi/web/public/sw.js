// chi web's service worker (Web Push, docs/internals/web-push.md): shows
// what chi web pushes and opens the session on a tap. A classic script
// (module service workers on iOS are unverified), registered at scope "/"
// by notifications.js in the Home Screen app only. No fetch handler and no
// caching: chi web has no offline mode, and a fetch handler would change
// how the page loads.
//
// A push's payload (JSON, end-to-end encrypted by chi web):
//   {v: 1, kind: "show", tag, title, body, url, badge?, open?: [tag…]}
// Every push shows a notification: WebKit removes a subscription after a
// few pushes that show none (its silent-push quota), so anything else (an
// unreadable payload, another version or kind, a show iOS refuses) shows a
// fallback "open chi". There is no close push: a show's open list (the
// keys chi web still has open) lets it close the answered ones after it
// shows itself (closing before showNotification fails on iOS), and the
// page does the same when the app opens.

const ICON = "/icons/chi-192.png";
const FALLBACK = { title: "chi", body: "open chi", tag: "chi:other", url: "/" };
// push.js QUESTION_TAG: a pushed question's "<session id>:<question id>",
// never chi's own (chi:test, chi:other).
const QUESTION_TAG = /^(?!chi:)[^:]+:[^:]+$/;

function payloadOf(event) {
  try {
    return event.data ? event.data.json() : null;
  } catch (_) {
    return null;
  }
}

async function setBadge(count) {
  const nav = self.navigator;
  try {
    if (count > 0 && nav && typeof nav.setAppBadge === "function") await nav.setAppBadge(count);
    else if (nav && typeof nav.clearAppBadge === "function") await nav.clearAppBadge();
    else if (nav && typeof nav.setAppBadge === "function") await nav.setAppBadge(0);
  } catch (_) {}
}

// Only a same-origin path opens: a payload names where in chi web to go.
function pagePath(url) {
  // Not "//host" nor "/\host" (a browser reads a backslash as a slash).
  return typeof url === "string" && /^\/(?![/\\])/.test(url) && !url.includes("\\") ? url : "/";
}

// Shows it, or once more without the icon and data if that is refused.
async function show({ title, body, tag, url }) {
  try {
    await self.registration.showNotification(title, { body, tag, icon: ICON, data: { url: pagePath(url) } });
  } catch (_) {
    await self.registration.showNotification(title, { body, tag });
  }
}

// Closes the shown question notifications chi web no longer has open
// (never the new one nor chi's own). The unfiltered list only names the
// tags: on the iPhone (iOS 26, 2026-10-24) close() on a notification from
// it did nothing, while one looked up by its tag closes (the probe in
// docs/internals/web-push.md, iOS facts).
async function closeAnswered(open, keep) {
  try {
    const still = new Set(open.map(String));
    const tags = new Set();
    for (const n of await self.registration.getNotifications()) {
      if (n.tag !== keep && QUESTION_TAG.test(n.tag || "") && !still.has(n.tag)) tags.add(n.tag);
    }
    for (const tag of tags) {
      for (const n of await self.registration.getNotifications({ tag })) n.close();
    }
  } catch (_) {}
}

async function onPush(data) {
  if (!data || data.v !== 1 || data.kind !== "show") {
    await show(FALLBACK);
    return;
  }
  const tag = String(data.tag || "");
  await show({ title: String(data.title || "chi"), body: String(data.body || ""), tag, url: data.url });
  if (Array.isArray(data.open)) await closeAnswered(data.open, tag);
  if (typeof data.badge === "number") await setBadge(data.badge);
}

async function onClick(notification) {
  notification.close();
  const url = pagePath(notification.data && notification.data.url);
  const windows = await clients.matchAll({ type: "window", includeUncontrolled: true });
  const win = windows[0];
  if (win) {
    await win.focus();
    if (typeof win.navigate === "function") await win.navigate(url);
    return;
  }
  await clients.openWindow(url);
}

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(clients.claim()));
self.addEventListener("push", (event) => event.waitUntil(onPush(payloadOf(event))));
self.addEventListener("notificationclick", (event) => event.waitUntil(onClick(event.notification)));
