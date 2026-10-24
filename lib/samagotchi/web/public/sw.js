// chi web's service worker (Web Push, docs/internals/web-push.md): shows
// what chi web pushes and opens the session on a tap. A classic script
// (module service workers on iOS are unverified), registered at scope "/"
// by notifications.js in the Home Screen app only. No fetch handler and no
// caching: chi web has no offline mode, and a fetch handler would change
// how the page loads.
//
// A push's payload (JSON, end-to-end encrypted by chi web):
//   {v: 1, kind: "show", tag, title, body, url, badge}
//   {v: 1, kind: "close", tags: [tag…], badge}
// iOS doesn't replace a notification by its tag, so an answered one is
// taken off the lock screen by its own close push, which shows nothing.

const ICON = "/icons/chi-192.png";

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
  return typeof url === "string" && url.startsWith("/") && !url.startsWith("//") ? url : "/";
}

async function onPush(data) {
  if (!data || data.v !== 1) return;
  const badge = Number(data.badge) || 0;
  if (data.kind === "close") {
    const tags = Array.isArray(data.tags) ? data.tags : [];
    for (const tag of tags) {
      const shown = await self.registration.getNotifications({ tag: String(tag) });
      for (const n of shown) n.close();
    }
    await setBadge(badge);
    return;
  }
  if (data.kind !== "show") return;
  await self.registration.showNotification(String(data.title || "chi"), {
    body: String(data.body || ""),
    tag: String(data.tag || ""),
    icon: ICON,
    data: { url: pagePath(data.url) },
  });
  await setBadge(badge);
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
