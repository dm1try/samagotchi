# Web Push (internals)

chi web pushes to the owner's phone when a session waits on an approval or a question: the phone runs chi web as a
Home Screen app (iOS 16.4+), its bell subscribes the device, and chi web, the only sender, pushes through the
device's push service (Apple's `web.push.apple.com`). The user side is in
[configuration.md](../configuration.md#phone-notifications-web-push). This page is how it is built (P1 of the plan:
approvals and questions; the step-limit question, cards, failed and done turns, presence and the device list come
later).

```
SessionHub ──emit──▶ Notifier#call(event) ──Queue──▶ sender thread
                         Attention rules               hold 3 s → still open?
                                                       Crypto.encrypt + VAPID → Client#deliver(endpoint)
                                                       201 ok · 404/410 drop the device · 403 BadJwtToken stop + log
service worker ◀── Apple (web.push.apple.com) ◀──────── {v, kind: show, tag, title, body, url, badge, open?}
```

**Every push chi sends shows a notification.** WebKit removes a subscription after 3 pushes that show no
notification ("Enforce silent push quota", WebKit commit 108ccb44), and Apple keeps answering 201 for it (Apple
Developer Forums 719990), so chi can't see it happen. The user check of 2026-10-24 lost its subscription this way:
7 question pushes and 6 close pushes in ~6 min, then a question push and a test push both answered 201 and never
showed. So there is no close push and no badge-only push: answered notifications leave the lock screen through the
next show's `open` list (the service worker) or when the app opens (the page).

## The crypto (`web/push/crypto.rb`)

OpenSSL only, no gem (the `web-push` gem would bring `jwt` and the `openssl` gem for ~60 lines); it runs on Ruby 3.3's
openssl gem (`KDF.hkdf`, `PKey::EC#derive`, `to_octet_string`). Base64url is `pack("m0")` (`base64` is no default
gem from Ruby 3.4).

- `Crypto.encrypt(plaintext, p256dh:, auth:)`: RFC 8291 §3.4 on RFC 8188's aes128gcm, one record (rs 4096, the 0x02
  last-record delimiter, no padding), a fresh salt and sender key per message. `spec/web/push/crypto_spec.rb` pins
  RFC 8291 Appendix A byte for byte (the RFC's fixed sender key and salt).
- `Crypto.vapid_authorization(endpoint, key:, sub:)`: RFC 8292, `vapid t=<JWT>, k=<public key>`; the JWT is ES256
  (OpenSSL's DER signature turned into r‖s), `aud` the endpoint's origin, `exp` now + 12 h, `sub` the contact.
- `Crypto.valid_sub?`: a `mailto:` with an `@` or an `https://` URL with a host. Apple answers 403
  `{"reason":"BadJwtToken"}` for anything else (the spike: `chi@localhost`), and 201 for the public origin, which is
  the default contact (`web.push.contact` overrides it).

`spec/support/web_push_receiver.rb` is a device's side for the specs (its key pair, decryption, the JWT check), so a
spec reads what chi web sent rather than trusting it.

## The store (`web/push/store.rb`)

`$XDG_STATE_HOME/samagotchi/web-push/` (`Store.dir`: Grants' rule, next to the sessions dir), a 0700 folder with 0600
files, one per machine, never in config.yml:

- `vapid.pem`: chi web's one P-256 key, made the first time (`Store#vapid_key`). Replacing it makes every device's
  subscription useless (the push services tie it to the key): the bell's subscribe drops a subscription made with
  another key and makes a new one.
- `subscriptions.json`: `{"version": 1, "subscriptions": [{id, endpoint, keys: {p256dh, auth}, origin, label,
  created_at, last_ok_at, last_error, prefs}]}`, read as `Store::Sub` values. `id` is the first 8 hex of the
  endpoint's SHA-256: the only name of a device outside the store. `Sub#public_h` and `#inspect` never carry the
  endpoint or the keys; neither do the log lines.

`Store#add` checks what `pushManager.subscribe` gave, one message per refusal (the route answers it as 400
`invalid_subscription`): an endpoint and both keys; https on port 443 without userinfo, at most 2048 bytes; a host in
`Store::PUSH_SERVICES` (Apple, Google's FCM, Mozilla, `*.notify.windows.com`; a `services:` seam for specs, not
config): chi web POSTs to that URL, so it never takes an arbitrary host; `p256dh` a 65-byte uncompressed point,
`auth` 16 bytes. The same endpoint again replaces the old entry. Every write is a read-change-write under
`store.lock` (chi web's request threads and the sender thread both write). A `subscriptions.json` that doesn't read
lists no device and is never written over. `Store#check_permissions!` uses `Web::PrivateFiles.check!`, the check the
grants use, worded with what the folder holds; `Server.launch` runs it (`Push.preflight!`, with the contact and the
key) before any tunnel goes up, and a refusal is one `Error:` line, exit 1.

Each subscription keeps the public origin it was made on; the Notifier sends only to this run's. A renamed machine or
tailnet leaves the old ones stale (never sent to: a tap would open an origin that no longer serves chi).

## The client (`web/push/client.rb`)

`Client#deliver(sub, payload, ttl:, urgency:)` encrypts the payload's JSON, POSTs it over TLS (open 5 s, read 10 s,
no redirects, no retry) with `Content-Encoding: aes128gcm`, `TTL`, `Urgency` and the VAPID header, and answers a
`Client::Result`: `:ok` (200/201/202), `:gone` (404/410: the device dropped it), `:bad_jwt` (403 with
`BadJwtToken`), `:failed` (anything else; a connection error as its class name or `timeout`, never its message). The
transport is injectable: `spec/web/push/client_spec.rb` runs a fake push service (WEBrick, plain http through the
injected transport) that decrypts each body with the device's key and checks the headers and the JWT.

## The payload and the service worker

The service worker is the only reader of the payload (JSON, at most `Notifier::OPEN_LIMIT`, 3000 bytes, with
`open`; one aes128gcm record leaves 3993 bytes of plaintext under Web Push's 4096: 86 header, 1 delimiter, 16 tag):

- `{"v":1,"kind":"show","tag":KEY,"title":…,"body":…,"url":"/#/s/<id>","badge":N,"open":[KEY…]}`: TTL 12 h,
  `Urgency: high`. `open` only while the whole list fits the limit; the test push (`chi:test`) has neither `open`
  nor `badge`.

`badge` and `open` are the keys still open in the Notifier's summaries (`Attention.open_keys`: a pending approval
or question, a hook's too, not relayed), so an approval pushed by an earlier chi web run still counts after a
restart. `public/sw.js` is a classic script (module service workers on iOS are unverified) at scope `/`. Every push
event ends in `showNotification`: a payload that isn't a readable v1 show (no data, bad JSON, another `v`, a stale
`close` from an older chi web, any other kind) shows a fallback (`chi` / "open chi", tag `chi:other`, url `/`), and a
show iOS refuses is shown once more without its icon and data. A show calls `showNotification(title, {body, tag,
icon, data: {url}})` first; then, when `open` is an array, closes every `getNotifications()` whose tag is a
question's `"<sid>:<qid>"` (never `chi:*`), isn't the new one and isn't in `open` (after the show: closing before it
fails on iOS; errors are swallowed); then `setAppBadge(badge)` when `badge` is a number. A tap focuses the app's first window and navigates it to the url, else opens one (only a path of chi web's); `install`
skips waiting, `activate` claims the clients. No fetch handler and no caching: chi web has no offline mode, and a
fetch handler would change how the page loads. `spec/web/public/sw.test.js` runs it in a `vm` with a fake worker
scope.

The manifest, `sw.js` and the icons are `App::GATE_FREE_PATHS` (exact paths, still after the Host, cross-site and
frame checks): Chrome fetches a manifest without credentials, and none of them holds a secret. The icons are
rendered from `favicon.svg` by `script/render-icons` (Playwright's Chromium), full bleed and opaque (iOS fills
transparency with black).

## The Notifier (`web/push/notifier.rb`) and its rules (`web/push/attention.rb`)

`Push::Attention` is the server's port of `web/public/notify.js` for what P1 pushes, so a push and the tab's
notification ring for the same thing under the same key:

- `Attention.for(prev, next)`: a new `pending_question` id that isn't `relayed_to` (absent when nil: the summary
  compacts it), whose **reason** (notify.js `questionReason`: `approval`, `continue`, anything else incl. `hook` is
  a question) is approval or question. Filtering on the reason, never on `kind == "question"`, keeps hook questions.
  A delegated child's (`parent_id`) approval or hook question holds `RELAY_HOLD` 3.5 s (notify.js `RELAY_HOLD_MS`):
  its parent may relay it. The key is `"<sid>:<qid>"`.
- `Attention.closed_keys(prev, next)`: the question answered, replaced, newly relayed, or the session gone.
- `Attention.text(summary, reason)`: notify.js `attentionText`'s words: the session's title, first preview or last
  prompt clipped to 61, and "needs approval" / "needs an answer". Never the question or the command.

`Notifier#call(event)` is a `SessionHub` sink. **The hub calls it under its Monitor**, from the tick thread and also
from chi web's request threads (`SessionHub#touch`, from the stop/archive/delete routes), so it only enqueues: a push
is a 0.5 s https call. `emit` already rescues a raising sink. The sink keeps the last summary per session and turns
each `session` / `session_gone` event into a `Show` (with its text) or a `Close` (it was answered anywhere) on a
Queue.

**Seeding**: `Notifier#start(hub)` subscribes with `snapshot: true` and takes the summaries as the seed, so what is
open already never pushes. The hub's projection is empty before its first scan, so `Server.start` runs `hub.scan`
once after the `chi` line's subscribe and before `notifier.start(hub)`, then `hub.start`. Events that reach the sink
before the seed is in (they are newer than the snapshot) are applied after it.

The sender thread holds each show (`HOLD` 3 s, or the event's own), then pushes it only while its key is still in
`Attention.open_keys` of the summaries (read under the sink's mutex at flush time), to every subscription on this
run's origin, with that list as `open` and its size as `badge`. A close only drops a show still in its hold: it
pushes nothing. Results: `:ok` stamps the device's
`last_ok_at`; `:gone` removes it; `:failed` keeps its code in `last_error` and logs `push_failed`; `:bad_jwt` logs
one `push_bad_jwt` warning (on chi web's terminal too) and stops all pushes until chi web restarts. Log lines carry
`device:` (the short id), `code:`, `ms:`, `kind:`: never the endpoint, keys or text. `#stop` drops pending holds and
joins with a timeout; `Server.start`'s ensure calls it. Specs drive `#pump` with a moved clock
(`start(hub, sender: false)`), and one example runs the real thread with a client that blocks.

## The routes (`web/push_routes.rb`)

`:owner` rows in `App::ROUTES` (so `participant_gate_spec` refuses each to a participant), handlers in
`Web::PushRoutes`; `@push` is the run's `Push::Runtime` (store, client, origin), nil when push is off (no https
public URL, or `web.push.enabled: false`):

- `GET /api/push[?endpoint=E]` → `{enabled, public_key, origin, this: {id, label}|null}`; off: `enabled: false` and
  no key.
- `POST /api/push/subscriptions {subscription: {endpoint, keys}}` → 201 `{id, label}`; the label is chi's own
  ("iPhone · <date>", from the User-Agent's device class: iPhone, iPad, Mac, else Browser).
- `DELETE /api/push/subscriptions {endpoint}` → 204.
- `POST /api/push/test {endpoint?}` → a test push to that device or every one on this origin, answered per device
  (`{devices: [{id, label, status, code, ms}]}`); the bell sends one after subscribing.

With push off the three writes answer 409 `push_off`.

## The page (`public/push.js`, `public/notifications.js`)

`push.js` holds the pure parts: `pushSupported({win, nav})` (a secure context, `serviceWorker`, `PushManager`, and a
standalone app: `matchMedia("(display-mode: standalone)")` or iOS's `navigator.standalone`), `urlBase64ToBytes`,
`subscribe({reg, key, post})` (drops a subscription made with another key), `unsubscribe({reg, del})`. In the Home
Screen app the bell (`notifications.js`) registers `/sw.js`, asks `GET /api/push` with its subscription's endpoint,
and is "push to this phone" when chi web pushes: on while chi web has this device. A tap asks permission from the tap
(iOS asks only from a user gesture), subscribes, posts it and sends a test push; a tap when on unsubscribes and
deletes. The tab's own OS notification is left to the push there; the title count stays. In a browser tab, or with
chi web not pushing, the bell is the in-tab one, unchanged (no duplicate desktop pushes).

**The device's tidy-up** (`syncDevice`, the Home Screen app with the bell on): closes the shown notifications whose
tag is a question's (`push.js isQuestionTag`, so `chi:test` stays) and isn't open in the page's `byId`
(`push.js openPushKeys`: `Attention.open_keys`'s rule, with notify.js's `questionReason`), and sets or clears the app
badge (`navigator.setAppBadge` / `clearAppBadge`); the bell turned off clears it. It runs once push is known, when
the page comes back in front, and after each hub frame while visible (so answering on the Mac with the app open
clears it at once), one at a time with one rerun. Never before the first snapshot (an empty `byId` would close
everything) and never on a project's page (`createNotifications({scoped})`, app.js passes `!!scope.dir`: its
`/api/events?dir=` leaves out the other projects' sessions).

Accepted staleness: an approval answered elsewhere keeps its banner until the app opens or the next push arrives
(or a swipe), and the icon badge may be too high until then; a show already handed to Apple just before its answer
can land after the page's tidy-up and stay until the next one. Unverified on iOS: `getNotifications()` and
`setAppBadge` from the page (a Window); the worker's cleanup still runs on the next push if they do nothing.

## iOS facts (the spike, 2026-10-24, on an iPhone)

- **No replace by `tag`**: two notifications with one tag both stay, and closing same-tag ones inside the push
  handler before `showNotification` doesn't remove the older one. A separate close push that only closed
  `getNotifications({tag})` did, but it shows nothing (see the quota below), so the worker now closes after its show.
- **The service worker can't see the app in front** (`clients.matchAll` gave 0 windows with the app open) and a
  banner shows anyway: "don't push while I'm looking" has to be decided server-side, from the pages' presence (P2).
- **Silent pushes**: the spike's 4 close pushes in a row didn't revoke the subscription, but that was luck or lazy
  enforcement: the user check's 6 did (WebKit's quota is 3 pushes that show nothing; see the top of this page).
- iOS sent the cookie with the manifest, `sw.js` and icon fetches, but Chrome fetches manifests without credentials:
  they are gate-free rather than relying on that.
- `navigator.setAppBadge(n)` from the service worker sets the icon's badge; a push mirrors to the Watch.
- The Home Screen app copies Safari's cookie when it is added and keeps its own jar after (400 days).
