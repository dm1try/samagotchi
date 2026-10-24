// Web Push, the page's pure parts (notifications.js drives them): whether
// this page can get pushes, and subscribing this device with chi web's key
// and telling chi web (POST /api/push/subscriptions), or the reverse. Only
// the Home Screen app subscribes (iOS gives push to a standalone app only;
// a browser tab keeps the in-tab notifications). See
// docs/internals/web-push.md.

// A standalone app with a service worker and PushManager, on a secure
// context (chi web's https public URL; the LAN's plain http has none).
// @param win the window (isSecureContext, PushManager, matchMedia)
// @param nav the navigator (serviceWorker, standalone on iOS)
export function pushSupported({ win, nav }) {
  if (!win || !nav || win.isSecureContext !== true) return false;
  if (!nav.serviceWorker || typeof win.PushManager !== "function") return false;
  let standalone = nav.standalone === true;
  try {
    if (!standalone && typeof win.matchMedia === "function") standalone = win.matchMedia("(display-mode: standalone)").matches === true;
  } catch (_) {}
  return standalone;
}

// base64url (padded or not) → bytes: applicationServerKey's form.
export function urlBase64ToBytes(text) {
  const b64 = String(text).replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  const raw = atob(padded);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

function sameBytes(a, b) {
  if (!a || !b) return false;
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  return x.length === y.length && x.every((v, i) => v === y[i]);
}

// Subscribes this device with chi web's key (a subscription made with
// another key, an older vapid.pem's, is dropped first: the push service
// would refuse chi web's token for it) and posts it.
// @param reg the service worker's registration
// @param key chi web's public key (GET /api/push's public_key)
// @param post (subscriptionJson) => Promise of chi web's answer ({id, label})
// @return {subscription, answer}
export async function subscribe({ reg, key, post }) {
  const want = urlBase64ToBytes(key);
  let sub = await reg.pushManager.getSubscription();
  if (sub && !sameBytes(sub.options?.applicationServerKey, want)) {
    await sub.unsubscribe();
    sub = null;
  }
  if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: want });
  const answer = await post(typeof sub.toJSON === "function" ? sub.toJSON() : sub);
  return { subscription: sub, answer };
}

// Unsubscribes this device and tells chi web to forget it.
// @param del (endpoint) => Promise
// @return whether there was a subscription
export async function unsubscribe({ reg, del }) {
  const sub = await reg.pushManager.getSubscription();
  if (!sub) return false;
  const endpoint = sub.endpoint;
  await sub.unsubscribe();
  await del(endpoint);
  return true;
}
