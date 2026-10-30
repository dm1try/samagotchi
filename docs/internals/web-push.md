# Web Push (internals)

chi web pushes to the owner's phone when a session needs them, for what the tab notifies for: an approval, a
question, a step-limit question, a card with actions, a failed turn, a recorded Verify verdict, and (per device,
off by default) a done one. The
phone runs chi web as a Home Screen app (iOS 16.4+), its bell subscribes the device, and chi web, the only sender,
pushes through the device's push service (Apple's `web.push.apple.com`). The user side is in
[configuration.md](../configuration.md#phone-notifications-web-push). This page is how it is built (P1, P2a and P2b of the
plan: P2b is the devices sheet and `chi web push`).

```
SessionHub ──emit──▶ Notifier#call(event) ──Queue──▶ sender thread
                         Attention rules               hold 3 s → still open? a page in front? the cap?
                                                       Crypto.encrypt + VAPID → Client#deliver(endpoint)
                                                       201 ok · 404/410 drop the device · 403 BadJwtToken stop + log
                                                       429/5xx one retry · handled keys → sent.json
                     page ──POST /api/push/presence──▶ Presence (in front, touched < 2 min)
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
  endpoint's SHA-256: the only name of a device outside the store. `Sub#public_h` (id, label, origin, the dates,
  `last_error`, `prefs: {done:}`) and `#inspect` never carry the endpoint or the keys; neither do the log lines.
  `prefs` is `{"done": false}` until `Store#set_prefs(id, done:, origin:)` (the PATCH route) sets it; `Sub#done?`.
  `Store#remove_device(id, origin:)` removes by short id only on that origin (nil: any; the DELETE route, `chi web
  push rm`); `#subscriptions!` is `#subscriptions` that raises `Corrupt` instead of reading none (the CLI says so).
- `sent.json`: `{"version": 1, "keys": {KEY: iso time}}`, the attention keys already handled (a device took the
  show, or it was skipped while a page was in front, or capped), written by `Store#mark_sent` under `store.lock`,
  keys older than a day (`SENT_KEEP`) pruned on each write. `Store#sent_keys` reads it; one that doesn't read is
  logged once (`push_sent_corrupt`) and read as none, and the next write replaces it (it only spares a restart's
  repeat). It is in `check_permissions!`'s list.

`Store#add` checks what `pushManager.subscribe` gave, one message per refusal (the route answers it as 400
`invalid_subscription`): an endpoint and both keys; https on port 443 without userinfo, at most 2048 bytes; a host in
`Store::PUSH_SERVICES` (Apple, Google's FCM, Mozilla, `*.notify.windows.com`; a `services:` seam for specs, not
config): chi web POSTs to that URL, so it never takes an arbitrary host; `p256dh` a 65-byte uncompressed point
on P-256 (built as `Crypto.ec_public` builds it), `auth` 16 bytes. The same endpoint again replaces the old entry.
`replaces:` (the device's id from its last subscribe, which the page keeps) drops that entry on this origin too,
before the `MAX_SUBS` cap is counted, and yields it (the route logs `push_replaced`); its own endpoint is never
dropped that way, and an unknown id is ignored.
That is how a subscription iOS revoked silently (Apple keeps answering 201, so `:gone` never comes) leaves the store:
the user turns the bell off and on, the page has no live subscription to delete, and the new one replaces it. Every write is a read-change-write under
`store.lock` (chi web's request threads and the sender thread both write). A `subscriptions.json` that doesn't read
lists no device and is never written over. `Store#check_permissions!` uses `Web::PrivateFiles.check!`, the check the
grants use, worded with what the folder holds; `Server.launch` runs it (`Push.preflight!`, with the contact and the
key) before any tunnel goes up, and a refusal is one `Error:` line, exit 1.

Each subscription keeps the public origin it was made on; the Notifier sends only to this run's. A renamed machine or
tailnet leaves the old ones stale (never sent to: a tap would open an origin that no longer serves chi).

## The client (`web/push/client.rb`)

`Client#deliver(sub, payload, ttl:, urgency:)` encrypts the payload's JSON, POSTs it over TLS (open 5 s, read 10 s,
no redirects, no retry of its own) with `Content-Encoding: aes128gcm`, `TTL`, `Urgency` and the VAPID header, and
answers a `Client::Result`: `:ok` (200/201/202), `:gone` (404/410: the device dropped it), `:bad_jwt` (403 with
`BadJwtToken`), `:failed` (anything else; a connection error as its class name or `timeout`, never its message;
any other error too, so a key off the curve on disk fails that device alone, never the Notifier's flush or the test
push).
A 429 or 5xx also carries `retry_after`: its `Retry-After` delta-seconds up to `RETRY_MAX` 60, else (missing, an
HTTP date) `RETRY_DEFAULT` 10; nil for anything else, a connection error too (it may have been delivered). The
transport is injectable: `spec/web/push/client_spec.rb` runs a fake push service (WEBrick, plain http through the
injected transport) that decrypts each body with the device's key and checks the headers and the JWT.

## The payload and the service worker

The service worker is the only reader of the payload (JSON, at most `Notifier::OPEN_LIMIT`, 3000 bytes, with
`open`; one aes128gcm record leaves 3993 bytes of plaintext under Web Push's 4096: 86 header, 1 delimiter, 16 tag):

- `{"v":1,"kind":"show","tag":KEY,"title":…,"body":…,"url":URL,"badge":N,"open":[KEY…]}`: a waiting
  reason's (approval, question, continue, card) TTL 12 h (`SHOW_TTL`), `Urgency: high`; a failed or done turn's
  TTL 10 min (`EVENT_TTL`), `Urgency: normal`; an available chi update uses a 24 h TTL (`UPDATE_TTL`) and
  `Urgency: normal`. `open` only while the whole list fits the limit; the test push
  (`chi:test`) has neither `open` nor `badge`. URL (`Notifier.session_url`) is the session in its own project's
  view, `/?dir=<project root>#/s/<id>` (the folder URL-encoded, its slashes kept), or `/?scope=all#/s/<id>` for a
  session in no repo: never the bare `/`, which is chi web's start project (except the update show, which names no
  session: `/`).

`badge` and `open` are the waiting keys still open in the Notifier's summaries (`Attention.open_keys`: a pending
question of any reason, a hook's and a continue's too, not relayed, and a card with actions; never a failed or done
turn), so an approval pushed by an earlier chi web run still counts after a restart. `public/sw.js` is a classic script (module service workers on iOS are unverified) at scope `/`. Every push
event ends in `showNotification`: a payload that isn't a readable v1 show (no data, bad JSON, another `v`, a stale
`close` from an older chi web, any other kind) shows a fallback (`chi` / "open chi", tag `chi:other`, url `/`), and a
show iOS refuses is shown once more without its icon and data. A show calls `showNotification(title, {body, tag,
icon, data: {url}})` first; then, when `open` is an array, closes every `getNotifications()` whose tag is a waiting
key (`WAITING_TAG`: a question's `"<sid>:<qid>"` or a card's `"<sid>:card:<cid>"`, never `chi:*` nor a failed or
done turn's `"<sid>:<ended_at>"`, whose time has colons), isn't the new one and isn't in `open` (after the show: closing before it
fails on iOS; errors are swallowed); then `setAppBadge(badge)` when `badge` is a number. A tap focuses the app's first window and navigates it to the url, else opens one (only a path of chi web's); `install`
skips waiting, `activate` claims the clients. A Home Screen app can stay open for days, and the browser checks for
a newer `sw.js` only on `register()` and on navigations: so when the page comes back in front (`backInFront` in
`notifications.js`) it calls `reg.update()` (errors swallowed), at most once per `SW_UPDATE_MS` (an hour; counted
from the register, which has just checked), with the bell on or off, never without push. No fetch handler and no caching: chi web has no offline mode, and a
fetch handler would change how the page loads. `spec/web/public/sw.test.js` runs it in a `vm` with a fake worker
scope.

The manifest, `sw.js` and the icons are `App::GATE_FREE_PATHS` (exact paths, still after the Host, cross-site and
frame checks): Chrome fetches a manifest without credentials, and none of them holds a secret. The icons are
rendered from `favicon.svg` by `script/render-icons` (Playwright's Chromium), full bleed and opaque (iOS fills
transparency with black).

## The Notifier (`web/push/notifier.rb`) and its rules (`web/push/attention.rb`)

`Push::Attention` is the server's port of `web/public/notify.js`, so a push and the tab's notification ring for the
same thing under the same key. **One set of rules for both sides**: `spec/fixtures/attention_cases.json` holds the
cases (`attention`: `{name, prev, next, attention: {reason, key, hold_ms}|null, closed}` in the summary's JSON;
`open_keys`: `{name, by_id, open}`), and `spec/web/push/attention_cases_spec.rb` (the summary's key types: symbols at
the top and in `pending_question` / `pending_card`, strings in `last_turn`), `notify.test.js` (`attentionFor`,
`closedKeys`) and `push.test.js` (`openPushKeys`) run every row. A change to either side adds its row there.

- `Attention.for(prev, next)`, in notify.js's order:
  1. a new `pending_question` id: none if it is `relayed_to` already (absent when nil: the summary compacts it);
     else its **reason** (notify.js `questionReason`: `approval`, `continue`, anything else incl. `hook` is a
     question), key `"<sid>:<qid>"`. A delegated child's (`parent_id`) approval or hook question holds `RELAY_HOLD`
     3.5 s (notify.js `RELAY_HOLD_MS`): its parent may relay it.
  2. a new `pending_card` id: `card`, key `"<sid>:card:<cid>"`.
  3. a top-level turn whose `last_turn["ended_at"]` changed (a delegated child's is its parent's to report):
     a newly recorded verdict is `verdict`, keyed by `"<sid>:<check_turn_id>"`; otherwise `failed`, or `done` when
     `completed` and `seconds` ≥ `DONE_MIN_SECONDS` 10 or its origin is in `UNWATCHED_ORIGINS`
     (`delegate_report`, `context`, `task`), keyed by `"<sid>:<ended_at>"`. A verdict wins over the done/no-event
     rule, including for a short turn. A reminder turn follows the same rules (no reminder event of its own).
- `WAITING` (approval, question, continue, card) are the reasons that stay open until answered: badged, in `open`,
  cleaned up, and pushed only while still open. A failed, done or verdict turn has nothing to answer.
- `Attention.closed_keys(prev, next)`: the question answered, replaced, newly relayed; the card resolved or
  replaced; both when the session is gone.
- `Attention.text(summary, reason)`: notify.js `attentionText`'s words: the session's name as its card has it
  (title, auto title, the recap's first sentence, first preview, last prompt — the same order `format.js cardName`
  uses) clipped to 61, and "needs approval" / "needs an answer" / "hit its step limit" / "needs you" / "turn
  failed" / "done in N s" (`last_turn["seconds"]` rounded) / "<who>: <icon> <verdict> — <reason>" (reason clipped
  to 120 characters). A verdict names its participant from the session's participant sidecar, or says "You" for the
  owner; only verdicts use that push copy, never the full reply. Never the question or the command.

`Notifier#call(event)` is a `SessionHub` sink. **The hub calls it under its Monitor**, from the tick thread and also
from chi web's request threads (`SessionHub#touch`, from the stop/archive/delete routes), so it only enqueues: a push
is a 0.5 s https call. `emit` already rescues a raising sink. The sink keeps the last summary per session and turns
each `session` / `session_gone` event into a `Show` (with its text) or a `Close` (it was answered anywhere) on a
Queue. A `chi` event marked `update_notice` becomes a `chi:update:<version>` show for the bare page; the checker
sets that marker only for a newly selected version not already in its persistent `notified` list. It uses the same
Presence skip and hourly CAP as session shows, and the 24-hour TTL lets an offline phone receive it later.
With `update.auto: install` (and an install that is not blocked) that marker is ignored: the page says the release
installs by itself, and the phone hears the result instead.

**The automatic update's shows.** `Web::AutoUpdate` says how a run went with `SessionHub#publish_notice`, a
`chi_notice` hub event (`{kind, version, …notes}`): not a `chi_update` frame, which is the page's (it would repeat
in a reconnect's snapshot and toast), and not kept. The Notifier turns it into a show with reason `update` (24 h TTL,
`Urgency: normal`, counted in CAP, skipped with the key marked handled while a page is in front, shown for the bare
page `/`), once per key in its process (`@updates_seen`; AutoUpdate's own record in `update_check.json` keeps a run
from saying it twice across restarts). The key's `chi:` prefix keeps sw.js from treating it as a waiting key:

| `kind` | key | title / body |
|---|---|---|
| `installed` (`update.restart: never`) | `chi:installed:<X>` | "chi X is installed" / "chi web and its sessions switch over when you restart them." + kept edits |
| `failed` | `chi:update_failed:<X>` | "chi X didn't install" (or "installed with a problem" when the gem row was fine) / the first failed row's status, "Open chi web for details." |
| `updated` | `chi:updated:<X>` | "chi updated to X" / "chi web and 3 sessions restarted; 1 restarts when idle." + kept edits |
| `restart_failed` | `chi:restart_failed:<X>` | "chi X is installed; chi web didn't restart" / why (a failed `--version` preflight, no wrapper), "Restart chi web in its terminal." |

`updated` is sent by the **restarted** chi web (its AutoUpdate finds the run at `phase: web`): the exec ends the
old process, and `Notifier#stop` does not flush the shows still in their hold, so a push queued just before it would
be lost. Sending from the new process also proves it came up.

**Seeding**: `Notifier#start(hub)` subscribes with `snapshot: true` and takes the summaries as the seed, so what is
open already never pushes. The hub's projection is empty before its first scan, so `Server.start` runs `hub.scan`
once after the `chi` line's subscribe and before `notifier.start(hub)`, then `hub.start`. Events that reach the sink
before the seed is in (they are newer than the snapshot) are applied after it.

The sender thread holds each show (`HOLD` 3 s, or the event's own); then a waiting one goes only while its key is
still in `Attention.open_keys` of the summaries (read under the sink's mutex at flush time), a failed or done one as
is. It goes to every subscription on this run's origin (a done turn only to those whose `prefs.done` is true), with
that list as `open` and its size as `badge`, unless:

- **a page is in front** (`Push::Presence#present?`, below): no send at all, `push_skipped reason: present` (no
  device), and the key is handled (never pushed later: the tab's notification and badge have it);
- **the cap**: `CAP` 30 shows in a rolling `CAP_WINDOW` hour, counted per show event (one to N devices is one; the
  test push isn't the Notifier's): over it, not sent, handled, and one `push_capped` warning per hour (on chi web's
  terminal too).

A close only drops a show still in its hold: it pushes nothing. **Retry**: a result with `retry_after` (a 429 or
5xx) puts that device's show in the sender's retry table (`Notifier::Retry`, per key and device, due like a hold:
the sender never sleeps, other shows go out meanwhile; `push_retry` logs it); it goes once more to that device, still
there, only while a waiting key is open (a failed or done one as is), with the open list of that moment, and isn't
counted against the cap again. A second failure is final: `push_failed` and `last_error`, as any failure. A key a
device took (first try or retry), or one skipped or capped, goes in `sent.json` (`Store#mark_sent`).

**Restart catch-up**: `Session#waiting_question` carries the question's `created_at` (`PendingQuestion#created_at`,
iso8601; the summary's `pending_question` has it, the page ignores it). `Notifier#seed` shows each seed summary's
open, not relayed question asked under `CATCH_UP` (an hour) ago whose key isn't in `sent.json` (`push_catch_up`):
asked while chi web was down or restarting, it gets the normal hold, presence and the cap. Everything else seeds as
before (cards carry no time). The first restart after P2a may push a seen, still-open question once (no `sent.json`
yet). Results: `:ok` stamps the device's
`last_ok_at`; `:gone` removes it; `:failed` keeps its code in `last_error` and logs `push_failed`; `:bad_jwt` logs
one `push_bad_jwt` warning (on chi web's terminal too) and stops all pushes until chi web restarts. Log lines carry
`device:` (the short id), `code:`, `ms:`, `kind:`: never the endpoint, keys or text. `#stop` drops pending holds and
joins with a timeout; `Server.start`'s ensure calls it. chi web's own restart (`restart_web`, `Server.reexec`) execs
without either: the shows still in their hold and the retries waiting in `@pending` / `@retries` go with the process,
unsent and not in `sent.json`. The exec'd chi web's seed brings back only what restart catch-up covers (a question
still open); a closed-meanwhile or non-question show held then is not pushed. Specs drive `#pump` with a moved clock
(`start(hub, sender: false)`), and one example runs the real thread with a client that blocks.

## The routes (`web/push_routes.rb`)

`:owner` rows in `App::ROUTES` (so `participant_gate_spec` refuses each to a participant), handlers in
`Web::PushRoutes`; `@push` is the run's `Push::Runtime` (store, client, origin), nil when push is off (no https
public URL, or `web.push.enabled: false`):

- `GET /api/push[?endpoint=E]` → `{enabled, public_key, origin, this: {id, label}|null, devices, stale}`: `devices`
  this origin's (`Sub#public_h` + `this: bool`), `stale` how many were made on another origin; off: `enabled:
  false` and no key.
- `POST /api/push/subscriptions {subscription: {endpoint, keys}, replaces?: id}` → 201 `{id, label}`; the label is
  chi's own ("iPhone · <date>", from the User-Agent's device class: iPhone, iPad, Mac, else Browser); `replaces`
  drops the device's earlier entry (`Store#add`).
- `DELETE /api/push/subscriptions {endpoint}` → 204: this device's bell turned off (`Store#remove(endpoint, origin:)`:
  only a device on this origin goes, as with the other device routes).
- `DELETE /api/push/subscriptions/ID` → 204, 404 `unknown_device` (another origin's, or not a short id); logs
  `push_removed`. The devices sheet's Remove for another device; this device's own row never uses it (its switch is
  the bell, so the page's state and the store stay one).
- `PATCH /api/push/subscriptions/ID {prefs: {done: true|false}}` → 200 the device's `Sub#public_h`; 404
  `unknown_device` (not this origin's, or not a short id: the id is a `([^/]+)` capture checked in the handler, as
  `participant_gate_spec`'s `path_for` fills only those), 400 `invalid_prefs`; logs `push_prefs`. ROUTES' first
  PATCH row.
- `POST /api/push/presence {page, front}` → 204 (also with push off: a desk tab has nothing to be told), 400
  `invalid_presence`.
- `POST /api/push/test {endpoint?}` → a test push to that device or every one on this origin, answered per device
  (`{devices: [{id, label, status, code, ms}]}`); the bell sends one after subscribing. The payload is
  `Push::TEST_PAYLOAD` (TTL `TEST_TTL`), shared with `chi web push test`.

With push off the subscription writes and the test answer 409 `push_off`.

## Presence (`web/push/presence.rb`)

"Don't push while I'm looking" is decided here, as the iPhone's service worker can't see the app in front. Every
chi web page, a desk tab or the Home Screen app (`notifications.js`, whether or not it gets pushes itself), reports
`POST /api/push/presence {page, front}`: `page` a random id per page load, `front` = visible + `hasFocus()` +
touched (pointerdown, keydown, touchstart) in the last 2 min (`TOUCH_FRESH_MS`; the load counts as a touch). It
reports on visibilitychange, window focus and blur, the first touch that brings it to the front, every 30 s
(`PRESENCE_EVERY_MS`) while front and once more when 2 min pass untouched; a hide or `pagehide` sends `front: false`
as a beacon (`presenceSender`: `navigator.sendBeacon` with a JSON Blob, same origin so the cookie goes; else the
api's fetch; errors swallowed). `Push::Presence` keeps each page's last report in memory (a Mutex; at most
`MAX_PAGES` 64, the longest unheard dropped); `present?` is any `front: true` younger than `TTL` 45 s. It is part of
`Push::Runtime` (`presence`), so the route writes and the Notifier (built in `Server.start` from the Runtime) reads
the same one. A page left in front untouched quiets the phone at most ~2 min after the last touch.

## The page (`public/push.js`, `public/notifications.js`)

`push.js` holds the pure parts: `pushSupported({win, nav})` (a secure context, `serviceWorker`, `PushManager`, and a
standalone app: `matchMedia("(display-mode: standalone)")` or iOS's `navigator.standalone`), `urlBase64ToBytes`,
`subscribe({reg, key, post})` (drops a subscription made with another key), `unsubscribe({reg, del})`. In the Home
Screen app the bell (`notifications.js`) registers `/sw.js`, asks `GET /api/push` with its subscription's endpoint,
and is "push to this phone" when chi web pushes: on while chi web has this device. A tap asks permission from the tap
(iOS asks only from a user gesture), subscribes, posts it (with `replaces`: the id chi web answered last time,
kept in localStorage as `chi_push_device`, `PUSH_DEVICE_KEY`; a storage that throws only loses the replace) and sends
a test push; a tap when on deletes, then unsubscribes (a DELETE that fails changes nothing local: the bell stays on
and says the error), and forgets the id, unless there was no subscription left to delete (revoked meanwhile): then
the id stays for the next subscribe to replace. The tab's own OS notification is left to the push there; the title
count stays. A `GET /api/push` (or `register()`) that fails at launch (chi web restarting, a phone just woken) leaves
the bell the in-tab one until the page next comes back in front (`backInFront` → `retryPush`, one at a time, no
timer); chi web answering that it doesn't push is not asked again. In a browser tab, or with chi web not pushing,
the bell is the in-tab one, unchanged (no duplicate desktop pushes).

**The devices sheet** (`public/push_devices.js`, `createPushDevices` on `chip_popover.js`'s shell: a bottom sheet
under 600 px, else a popover at the bell; made once chi web says it pushes, so a tab never gets one): in push mode
the bell's tap opens it (`toggleNotify` → `sheet.toggle()`), and it reads `GET /api/push?endpoint=` on each open.
This device's row has the switch, the bell's own `togglePush` (permission from that tap; off forgets
`PUSH_DEVICE_KEY`), never Remove; every device has a **Long turns done** switch (`PATCH …/ID {prefs: {done}}`),
another device Remove (`DELETE …/ID`); `GET`'s `stale` is one line. One change at a time, the list read again after
each; a failure is said in the sheet (and the bell's tooltip). Pure `deviceRows` / `staleText` / `sheetModel` /
`sheetTemplate` run under node (push_devices.test.js); notifications.js takes the sheet as a `devices` factory.

**`chi web push`** (`lib/samagotchi/push_command.rb`, `PushCommand`): `ls [--format json]`, `rm ID`, `test [ID]` on
this machine's `Store` directly (chi web need not run). "Stale" is another origin than
`PushCommand.current_origin`: the running chi web's (`Web::Running.live_public_url`), else `web.public_url`'s, none
marked when neither. `test` builds a `Client` per device (`Push.load_key`, `Push.contact(sub.origin)`), stamps the
delivery (`Store#mark`) and removes a `:gone` device, as the route does. bin/chi branches on `ARGV[0..1] == web
push` after the `SUBCOMMANDS` dispatch and before `RunOptions.parse` (which refuses a stray word after `web`); it is
no `SUBCOMMANDS` key (`web` is RunOptions', and the contract spec would want a TABLE/MACHINE entry). `chi --remote X
web push …` is refused before that by `SessionAccess::Dispatch` (`web` is local only).

**The device's tidy-up** (`syncDevice`, the Home Screen app with the bell on): closes the shown notifications whose
tag is a waiting key (`push.js isWaitingTag`, so `chi:test` and a failed or done turn's stay) and isn't open in the
page's `byId` (`push.js openPushKeys`: `Attention.open_keys`'s rule), and sets or clears the app
badge (`navigator.setAppBadge` / `clearAppBadge`); the bell turned off clears it. It runs once push is known, when
the page comes back in front, and after each hub frame while visible (so answering on the Mac with the app open
clears it at once), one at a time with one rerun. Never before the first snapshot (an empty `byId` would close
everything). The device's notifications are every project's, so on a project's page (`?dir=`, or the bare page on
chi web's start project: `createNotifications({scoped})`, app.js passes `!!scope.dir`) the tidy-up goes by a stream
of every session of its own (`watchAll`, through `allEvents`: data.js `openEvents` without a dir), not the page's
`/api/events?dir=` frames, which leave out the other projects' sessions. That stream is open only with the bell on
(turning it off closes it), one at a time, and one that ended is opened again when the page next comes back in front.

Accepted staleness: an approval answered elsewhere keeps its banner until the app opens (the worker's cleanup on the next push doesn't work on iOS yet: see iOS facts)
(or a swipe), and the icon badge may be too high until then; a show already handed to Apple just before its answer
can land after the page's tidy-up and stay until the next one. Unverified on iOS: `getNotifications()` and
`setAppBadge` from the page (a Window); the worker's cleanup still runs on the next push if they do nothing.

## iOS facts (the spike, 2026-10-24, on an iPhone)

- **Close by tag lookup** (the P1b phone check, 2026-10-24, iOS 26): inside a push handler, after `showNotification`,
  the unfiltered `getNotifications()` lists the shown ones with their tags, but `close()` on one from that list left
  it on the lock screen; one from `getNotifications({tag})` closed. So `sw.js`'s cleanup reads the tags from the list
  and closes through the tag lookup. Not yet known whether that is a WebKit bug (unfiltered close never probed alone). **But** on a real
  question pair (A shown, answered, B pushed ~6 s later, the new worker confirmed) A's banner still stayed: the tag
  lookup closed a banner minutes old (the probe) but not a seconds-old one. So the worker's cleanup doesn't work on iOS
  yet (cause unknown: timing, or the banner still presenting); the page's cleanup when the app opens does.
- **No replace by `tag`**: two notifications with one tag both stay, and closing same-tag ones inside the push
  handler before `showNotification` doesn't remove the older one. A separate close push that only closed
  `getNotifications({tag})` did, but it shows nothing (see the quota below), so the worker now closes after its show.
- **The service worker can't see the app in front** (`clients.matchAll` gave 0 windows with the app open) and a
  banner shows anyway: "don't push while I'm looking" has to be decided server-side, from the pages' presence (see Presence above).
- **Silent pushes**: the spike's 4 close pushes in a row didn't revoke the subscription, but that was luck or lazy
  enforcement: the user check's 6 did (WebKit's quota is 3 pushes that show nothing; see the top of this page).
- iOS sent the cookie with the manifest, `sw.js` and icon fetches, but Chrome fetches manifests without credentials:
  they are gate-free rather than relying on that.
- `navigator.setAppBadge(n)` from the service worker sets the icon's badge; a push mirrors to the Watch.
- The Home Screen app copies Safari's cookie when it is added and keeps its own jar after (400 days).
