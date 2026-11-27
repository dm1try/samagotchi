# Schedules (`chi schedule`)

A **schedule** is a prompt with a clock. It lives in one file on this machine, not in a
worker's memory, so it outlives every session, every restart and every crash:
`~/.local/state/samagotchi/schedules.json` (next to `sessions/`, written with
`AtomicFile`, every change a read-modify-write under `schedules.lock`, so cron and
chi web's hub can never lose an update to each other). A **tick** — cron, systemd,
launchd, `chi schedule tick`, or chi web's hub when `schedule.auto_tick` is on —
walks the entries whose `next_due` has passed and runs the ones that are not busy.
The top-level `last_tick_at` records the last acquired, non-dry-run tick.

The file is versioned: each entry member is required or declares the format
version and default that introduced it. Rewrites preserve unknown keys and
entries missing required members; those entries are warned about and ignored by
`list` and `tick`, never erased. A write never lowers the file's version.

Each entry carries `id`, an optional `title`, `anchor` (the session it was made
against, never rewritten: the chain's root and the id you remember), `head` (the
chain's current link, re-anchored after every firing: the link a chain continue
made, or the session a `same` turn was queued into), `mode`,
`prompt`, `recurrence`, `catch_up`, `keep_links`, `max_failures`, `max_skips`,
`next_due` (UTC ISO), `last_fired`, `last_result`, `failures`, `skips`,
`enabled` and `condition` (your `--if CMD`, [Conditions](#conditions---if); `null` for
none).

<a id="reminder-vs-schedule"></a>## Reminder or schedule?

`register_reminder` and `chi schedule` are separate on purpose; which one you want
depends on whether the worker has to be running.

| | `register_reminder` | `chi schedule` |
|---|---|---|
| Where it lives | the worker's `Engine` (`ReminderStore`), in memory | `<state dir>/schedules.json`, durable |
| Who fires it | `IdleReminders`, inside a live idle worker | `chi schedule tick`, run by cron/systemd (or the hub when opted in) |
| Needs a worker | yes — and a reminder *holds* the worker up | no — it wakes one when none runs |
| Survives a stop, a crash, an archive | only the short asked-restart hand-off (`ReminderCarry`, 2 min) | yes, until cancelled |
| Longest interval | 1440 minutes | unlimited (`every`, `weekday`, `date`) |
| What it produces | a turn in the same session | a new chain link, or a queued turn in the same session |

A schedule turn carries `client_id: "system:schedule:<id>"` in both modes (a chain
link's first turn through `Session#first_turn_client_id`, which `Schedules#fire_chain`
passes to `SessionContinue.run`), so `ClientId.origin` says `schedule` and the terminal
and the web label it as such rather than as something you typed. For the same reason a
schedule's prompt is never a session command: a `/word` prompt reaches the model as
text, and one that starts with `!` is refused by `chi schedule add` and `schedule_task`
([guardrails.md, Who may run a session command](guardrails.md#who-may-run-a-session-command)).
An entry stored with one before that fails when it fires (toward its `max_failures`),
before anything is started or delivered. A chi web
(or cron tick) still running an older chi starts chain links without the origin, so
restart it after updating. Like `register_reminder`, the schedule tools are owner-voiced:
a participant's turn is denied them ([guardrails.md](guardrails.md)).

## The two modes

- **chain** (the default) runs the prompt as the **next link of the session's chain**:
  the head is archived, a new link is created with the carry note
  ([sessions.md, Session chains](sessions.md#session-chains)), and `head` moves to it.
  This is the "same routine, fresh context" case: a daily coordinator that starts each
  day with the recap of the last one instead of a 40-link transcript.
- **same** queues the prompt as a turn **in the session itself**
  (`SessionManager.deliver_turn`, `Delivery::QUEUE`), waking a worker when none runs.
  It prunes nothing, and it never archives anything. Like chain mode, it follows
  `head` through the chain: once the session is continued — by a chain schedule or
  by a `chi send --continues` — the turn goes to the new link, not to the archived
  anchor the schedule was made against.
  Both modes resolve the **chain's end** (`SessionChain::Links#latest`), not the
  first live link a `chi send` takes: a chain firing can only continue the end, and
  an archived end (a chain you retired) fails the firing instead of being brought
  back as a send would.

A `scratch` session is refused at `add`: it is deleted when its terminal leaves.
A prompt is checked at `add` too — non-empty and at most 16 KiB
(`SessionInbox::NOTE_MAX_BYTES`); a blank one would archive a link and start an
idle session for nothing.

## Recurrence

One kind per schedule:

| Kind | Written as | How the next due is computed |
|---|---|---|
| `every` | `--every 45m` / `2h` / `1d` | interval arithmetic from the firing — `next_due = fired_at + interval` |
| `weekday` | `--weekday 1 --time 09:00` (1=Mon … 7=Sun) | the next such wall-clock moment in the machine's local zone, strictly after now (today counts if the time is still ahead), stored as UTC |
| `date` | `--date 2026-11-20` or `--date 2026-11-20T09:00` | one local moment; after it fires the entry is disabled |

**The DST caveat.** `every` is interval math in UTC, so an `every 1d` schedule
drifts by an hour across a DST fold: fired Monday 09:00, its next due is Tuesday
09:00 UTC, which is a different hour on the wall clock after the change. For a
schedule at a *time of day*, use `--weekday` (or `--date`): those build the moment
with `Time.local` for the candidate date, so `Mon 09:00` stays 09:00 local across
the fold. If a local moment does not exist (a spring-forward gap), it fires at the
next valid minute. Schedules use the machine's local clock; there are no named
time zones.

`catch_up` says what an overdue entry does when the tick arrives after its moment:

- `once` (default): fire once now, then reschedule normally.
- `none`: fire only when the tick is near the moment. "Missed" — `last_result:
  "missed"` and the entry moves to its next occurrence — is a **whole cycle**, not
  a late tick: it happens only when the occurrence *after* the one it missed is
  already past, which is what the file looks like when the machine was asleep
  across the interval. A `Mon 09:00` schedule ticked at 09:20 fires; the same
  entry first seen the following Monday is missed and moves to the Monday after.
  A `date` one-off has no next occurrence to compare with, so it is never missed:
  it fires late, once.

## The busy check

A cron tick cannot read a worker's memory, so the tick has two paths. What the
session's lifecycle state answers (deleting, stopped, a worker starting, leaving or
on a newer chi) comes from the lifecycle table (`SessionLifecycle::ALLOWED`,
[internals](internals/session-lifecycle.md)); the Bridge ask and the file checks
below are the busy check's own.

**Being deleted** (a deleter holds the owner lock) comes before a stop marker.
The skip is "the session is being deleted", and the next tick finds the session
gone.

**Stopped by its owner** (`chi sessions stop`, the web's Stop: the stop marker,
`WorkerPresence#stop_marked?`) comes next, in both modes: a skip ("the session is
stopped; only its owner's message starts it again"), never a restart. A stop that
lands between the check and a same-mode firing is the same skip: `deliver_turn`
refuses a schedule's wake of a stopped session (a schedule is no person,
`ClientId.wake_kind`).

**No live worker** (the usual case for a weekly schedule): the files say what can
be known — the saved status is not `running` (and not inside the starting grace),
`input/` is empty, no step-limit question is open, and, for chain mode, no worker
is being started for it (the `<id>/starting` marker every spawn writes: another
ticker's firing that just continued the chain; its archive refuses it too, a
skip). Nothing else can be busy.

**A live worker**: ask it, over the new Bridge route
`GET /session/:id/activity` (`Worker#activity_snapshot`, the same signals
`WorkerIdleExit#hold` reads): `{turn_running, input_pending, awaiting_continue,
open_streams, reminders, tasks_holding}`. It is in `Bridge::FEATURES`, so a worker
from an older chi has no such route, and any non-200 from it is read as "older":
the tick says to restart that worker.

- `turn_running`, `input_pending` or `awaiting_continue` ⇒ busy, in both modes.
- `open_streams` (a terminal attached, or a web tab open on the session) counts
  **only for chain mode**: a chain firing archives the session and stops its
  worker, which would cut off the person looking at it. A queued turn into an open
  session is fine, so `same` mode ignores streams.
- **An older worker is itself a busy signal for chain mode.** Its 404 must not fall
  back to the file checks: those cannot see an open tab, so the firing would
  archive under someone's terminal. The tick skips it with "its worker is too old
  to ask: `chi sessions restart ID`" — chi's usual rule for an older worker:
  refuse with a restart, never silently degrade. `same` mode, which only queues a
  turn, may use the file checks.
- A worker whose chi is newer than the ticker's (its Bridge speaks a newer
  protocol) can't be asked. The skip is "its worker runs a newer chi: restart chi
  web or update this chi", in both modes.

A `chi send --wait` or a parent's `delegate` wait is **not** busy: `ReplyWait::Poll`
reads the session files and `GET /session/:id/state`, never `open_stream`, so a
coordinator waiting on its own child does not block that child's chain.

Schedules never hold a worker up: unlike reminders, they are not in
`WorkerIdleExit#hold` (FR14) — the whole point is that the worker may be gone and
the tick wakes it.

## Skip, not failure

A firing that cannot run now is a **skip**: nothing happens, `skips += 1`,
`last_result: "skipped"`, and `next_due` goes back to the occurrence this tick tried
(the tick advances the clock before acting and keeps that moment as `due_was`, so the
next tick tries it again — a weekly schedule skipped on its Monday is retried at that
Monday, not a week later). A failure restores it the same way. A `date` entry is the
exception: advancing it spends it, so it comes back at that same moment.
Skips
are the refusals that mean "not this moment": `ArchiveRefused` with `busy`, `queued`
or `offer`, or `busy_child`/`queued_child`/`offer_child` (a chain's own running
delegate refuses the archive, since `archivable!` walks the whole descendant tree),
`SessionContinue::Refused(:continued)` (a human continued it while we were
resolving), `:open_children` and `:transition_busy` (another continue of the
chain's end held its transition lock past the continue's 10 s on each of its tries), and a
same-mode turn its target's transition lock refused (`transition_busy`, or `link_continued` naming a
continue's new link: the turn's own hold, nothing written).
So is an archived target that a continue is still
making the next link of (`session 3f9a1c2e is being continued as 7b2d41aa-…; retry at the next tick`): a
person's `chi send --new --continues` or web `continue →` archives the link before
its successor is saved, and a tick in that moment sees an archived end
(`ContinueIntent.in_flight`: the intent written, its lock held). It is checked before
the busy check, in both modes, and again by a same-mode firing's own look at the
files; the next tick's walk reaches the new link. A continue that ended between the
tick's listing and that look (its successor saved, its intent gone) is no failure
either: the firing walks again on a fresh listing, checks the new link as the tick
would, and queues its turn there. A stale intent (no continue holds
its lock: a crash, repaired by the next continue or list) is not in flight, so that
target still fails `archived`.

Anything else is a **failure** (`failures += 1`): a gone or archived target (an archived end of the chain: you retired it, and a schedule never brings it back),
`SessionContinue::Refused(:folder_gone)`, `SessionManager::DeleteRefused`,
`ModelProfile::MissingModel`, `OwnedByTUI`, `Session::NotFound`, and anything a
spawn throws (`Errno::ENOSPC` included — `run_locked` re-raises it after undoing
the move, so it is never mistaken for a skip). A `DeleteRefused(:worker_running)`
hit while pruning stops the pruning for that firing, is logged, and is not a
schedule failure.

`skips >= max_skips` (default 12) or `failures >= max_failures` (default 3)
disables the entry and `chi schedule list` says why. **Any successful firing resets
both counters**, so twelve skips spread over months do not kill a healthy weekly
schedule. `list` prints the skip budget as a time window — 12 skips at a 5 minute
tick is about an hour of patience, which is what the count really measures.
`chi schedule enable` resets both counters too: a schedule turned back on gets its
whole budget again, not one skip.

`chi schedule show ID` ends with the entry's last 20 outcomes, newest first, one
line each in local time: `fired`, `skipped`, `failed`, `missed`, your `enabled` and
`disabled`, a `chi schedule edit`'s `edited` (naming the fields), with the reason and
the session it acted on (a skip or
failure that used up the budget says `disabled: <reason>`). `list --format json` has
them as each entry's `history` (and an unpushed turn-off as `disabled_notice`).

`list --format json` gives each entry every stored field (with any key a newer chi
added), then `recurrence_words`, `skip_window`, and what a reader would otherwise work
out: `name` (the title, or the start of the prompt in quotes, as `list` names it),
`state` (`on`, `firing` while a firing is in flight, `off`) and `off_reason`, why an
off one is off: `owner` (your `disable`), `skips` or `failures` (a budget used up),
and for a `date` one-off its last outcome in the history: `done` (it fired),
`failures` (it failed) or `missed`; `off` when none of these says (an older file's
spent one-off). These come last, so a stored key of the same name never hides them
(`ScheduleDisplay.json`).

`chi schedule edit ID` changes a schedule in place (its title, prompt, recurrence,
catch-up or budgets; [CLI](cli.md#durable-schedules-chi-schedule)) and keeps its id,
session, mode, counters and history. A new recurrence starts its clock at the edit, as
an `add`'s does, and waits for a firing in flight to settle; a spent `date` one-off
stays disabled after an edit until you `enable` it.

A recurring schedule the owner has disabled stays off when an in-flight skip or
failure is recorded. A `date` one-off is the exception: a skip or failure puts its
moment back and re-enables it. `run-now` still tries a disabled schedule, but a
refusal records its result without moving the skip or failure counters.

The tick line that disabled an entry ends `(disabled)` (`chi schedule tick`,
`run-now`), and `tick --format json` gives that outcome `"disabled": true`
(`Schedules::Outcome#disabled`). When any tick — chi web's own (`schedule.auto_tick`),
a cron `chi schedule tick` or a `chi schedule run-now` — disables a recurring schedule
by its budget, the phone gets one notification
([Phone notifications](configuration.md#phone-notifications-web-push)): "Schedule
disabled: Heartbeat", "skipped 12 times: <the last reason>" and the `chi schedule
enable <id>` that turns it back on; a tap opens its session. The tick leaves a notice
on the entry in `schedules.json` (`disabled_notice`) and a running chi web pushes it:
right after its own tick, and within `schedule.tick_interval_minutes` for another
ticker's, with `schedule.auto_tick` off too (a look that finds a tick holding the lock
tries again at the next scan, not an interval later). Only chi web pushes, so with no chi web
running the notice waits for one; a notice more than a day old, or one whose schedule
you enabled again, is dropped unpushed, and `chi schedule enable` clears it. It shows
even with a chi web page in front and waits a day for a phone that is offline. Two chi
webs on one state dir push it once. Nothing notifies for a `--dry-run`, your own
`chi schedule disable`, or a `date` one-off (spent when it fires; one that then fails
stays disabled with the failure in `chi schedule list`).

An accepted delivery is **pending**, not fired: `schedules.json` records its
session and turn id, and the next tick follows that turn's own outcome, even if a
later turn has replaced `last_turn`. A completed turn is a success; a failed or
canceled turn counts toward `max_failures`, with its reason in `chi schedule list`
and `show`. A question does not time out with the 40-second firing step: the turn
stays pending until its hard limit, derived from the schedule interval (at least
10 minutes and at most 6 hours). If no outcome is known by then, it counts as a
failure with reason `no outcome`. Failed, canceled and expired turns are not
re-fired; `next_due` remains at the next occurrence. The turn's outcome is read
from its files by `TurnOutcome.for` (`turn_outcome.rb`: its reply, its settled turn and
the words); `Schedules#resolve_pending` keeps the order: the reply, the question, the turn, expiry.

A chain holds at most `schedule.max_per_session` enabled schedules (default 10) and
the machine `schedule.max_total` (default 50); `schedule_task` and `chi schedule add`
refuse past them, naming the key. A schedule the chain already has — the same prompt
and recurrence, or the same title — is refused too, naming its id, so a routine that
tells each of its links to "make sure the Monday audit is scheduled" cannot multiply
itself. `schedule_task`, `list_schedules` and `cancel_schedule` see only schedules of
the calling session's chain (`all: true` steps outside it); `chi schedule list` is
always the machine-wide view. An entry that doesn't read (`list` counts it, "chi schedule
cancel ID removes one") is cancelled by its exact id with `chi schedule cancel ID`, and by
`cancel_schedule` when its stored `anchor` or `head` is a link of the chain; one with
neither (its chain can't be told) only with `all: true`. An id, prefix or title that matches more than one entry
is refused with exit 2, naming the matches.

The tick's lock covers the file only, never the action: the clock advances before
the work starts — for `every` and `weekday` to the next occurrence, for a `date`
one-off to none — so a tick killed mid-continue cannot fire the same entry twice.
If a later tick finds a firing older than 70 seconds without an accepted turn, it
counts an `interrupted` failure (a chain firing's continue can wait 30 s for the
recap, 10 s for the transition lock on each of its three tries, 5 s for the
archive). This 70-second limit covers only the firing
step, not an accepted turn or its pending question. The action may already have
taken effect before the process died, so that occurrence is not replayed; a
`date` one-off stays disabled with the failure visible, and recurring schedules
keep their advanced clock. An accepted turn is tracked separately until its own
outcome is known or its hard limit is reached.
And a `chi schedule add` from a terminal never waits on an archive or a recap wait. Chain mode targets `last:<head>`, so `SessionContinue.run`'s
own retry loop follows a continue a human made between our resolve and its lock
instead of racing it.

## Conditions (`--if`)

`chi schedule add … --if CMD` (and `chi schedule edit ID --if CMD`, `--no-if` to drop
it) gates a schedule on a shell command: at each due tick chi runs CMD first, and the
firing happens only when CMD says it is needed. A heartbeat, say, a chain firing every
few minutes, can ask "is there anything to do?" first, so that most ticks cost no model
turn.

```
chi schedule add --session ab12 --every 5m -m "Check in" --if "$HOME/.local/bin/anything-to-do"
```

What the exit status means:

| CMD | the tick |
|---|---|
| exits 0 | goes on as without a condition: the busy check, then the firing |
| exits 1 to 125 | **not needed**: `next_due` moves to the next occurrence, `last_result` is `not needed: exit N: <its first line of stdout, else its last of stderr>`, the tick prints `not-needed`; nothing else changes (no skip or failure counted, no history row, the chain's one firing per tick left to its other schedules) |
| exits 126 or 127 (not executable, not found), dies by a signal, runs past `schedule.condition_timeout_seconds` (default 30, at most 300), prints more than 1 MiB, or can't start (the session's folder is gone) | a **failure** (`condition: <why>`), counted toward `max_failures` like any other, the occurrence kept for the next tick: a broken condition turns the schedule off after 3 ticks (about 15 minutes at a 5 minute tick), with the phone notification. Failures reset only when the schedule fires (or you enable it): a gate that seldom says yes adds up errors that come days apart, and three of them turn it off |

The order, per due schedule with a condition: its target resolves (a gone or archived
one fails as without a condition), then `catch_up: none` a whole cycle late is
`missed`, then the condition's answer, then the busy check. So a busy target spends no
skip on an occurrence that wasn't needed.

How it runs: `sh -c CMD` in the target session's folder, in its own process group
(a timeout kills the whole group), stdin closed, with the ticker's environment
scrubbed of Ruby's and Bundler's variables (`SpawnEnv`), plus
`SAMAGOTCHI_SCHEDULE_ID`, `SAMAGOTCHI_SCHEDULE_TITLE` and `SAMAGOTCHI_SCHEDULE_SESSION`
(the session it acts on) and never `SAMAGOTCHI_PARENT_SESSION`. Treat the title (and the
session id) as untrusted input in a gate script: the model may change a schedule's title
(`chi schedule edit --title` isn't owner-only), so quote it and never `eval` it. It gets the ticker's
environment: cron's PATH is thin, so name commands by absolute path, and the project's
mise tools aren't set up (wrap CMD in `mise exec --` when it needs them). It inherits
what the ticker's environment holds, secrets included. Each due condition runs once, in
turn, before the tick takes the schedule lock (a slow CMD never holds `chi schedule
add` or a firing's record up), and the tick's clock moves on by the time they took.
When the lock is taken, an answer counts only for the condition, the `next_due` and the
failure count it ran for (so two tickers count one occurrence's error once): an edit, a run-now or another ticker in between leaves the schedule as it is
and the next tick asks again. So CMD should be cheap, read-only and safe to run twice
(cron and chi web ticking at once may both run it). A schedule whose target is busy
runs CMD at every tick until it fires.

`chi schedule run-now` fires without asking CMD; `tick --dry-run` doesn't run it
(`would fire  every 5m · if CMD (not run)`). `chi schedule show` has it as `if: CMD
(set from the CLI <time>; timeout 30 s; run-now skips it)`, `list` adds ` if: CMD`, and
`list --format json` gives `condition` as `{cmd, by, set_at}`. A `--date` one-off takes
none (it fires once; edit it to `--every` or `--weekday` first); one that has one anyway
(an older chi's `edit --date`) fails each tick, "conditions don't apply to a one-off",
without running CMD, until its budget turns it off.

**Only you set one.** CMD runs unattended and outside the
[guardrails](guardrails.md), so a condition is the owner's alone:
- `chi schedule … --if` / `--no-if` inside a chi session (any agent's shell:
  `SAMAGOTCHI_PARENT_SESSION` is set) exits 2: "a schedule's condition is set only
  from your own terminal";
- the `schedule_task` tool has no condition (and `list_schedules` only shows it);
- with the guardrails bundle, a shell command that runs `chi schedule add|edit … --if`
  asks you every time (`chi-schedule-if`: no parent agent and no System 1 may allow
  it), and `schedules.json` is a protected path: chi's file tools can't write it
  (`chi-schedules`), and a shell command naming it asks (`shell-touches-chi`).
These are an accident guard, not a sandbox (chi's guardrails are for a model you trust
not to try): the in-session refusal and the user-only rule stop an accidental or casual
set, not a determined evasion. A command that unsets the session marker (`env -u
SAMAGOTCHI_PARENT_SESSION`) and spells the flag so the rule's text doesn't see it (quoting
or a backslash inside `--if`, a variable) gets through, as it does for `chi context add
--cmd`; so does a script that edits the file without naming it. A page script runs
without the session markers too ([pages.md](pages.md): a page is code you trust), so a
model-written page that runs `chi schedule … --if` sets one when you open it. Keep CMD itself out of the model's reach too: a gate script
inside a project the model edits is one it can change, and the tick then runs what the
model wrote. `add` and `edit --if` warn when CMD's first word is a relative path (it
resolves in the session's folder) or a script inside the session's folder or any git
work tree: "warning: the model can edit this script; keep a gate outside your projects
(an absolute path, e.g. under ~/.local/bin)". It is a warning, not a refusal; a command
on PATH (`test -f …`, `gh …`) gets none.

**Every ticker must be new enough.** A chi of 0.189.0 or older (0.189.0 shipped without them) doesn't know
conditions and would fire such a schedule unasked, so chi stores a schedule with a
condition with `next_due: null` and the real time under `condition_next_due`: an older
chi never finds it due (it reads it, lists it with no next time, keeps its sessions
from retention, and enables, disables and cancels it), and a newer one reads the real
time back. `add` and `edit --if` say so: "every chi that ticks (chi web, cron) must be
newer than 0.189.0; an older one leaves this schedule alone". After updating chi,
restart chi web and point cron at the new chi, or the schedule waits. One leak remains:
an older chi's `run-now`, or its `edit` of the recurrence, writes a real `next_due`,
and an older ticker then fires the schedule unconditionally until a newer chi writes
the file again (one tick in a mixed setup). A condition set by anything but the CLI
(`by` other than `cli`, a later chi's) fails closed: counted as a failure, never run.

## Keeping the chain short

`keep_links` (default `schedule.default_keep_links`, `0` keeps all) is how many
chain links stay behind the head. After a successful chain firing — and after the
result is recorded under the lock, so a prune that raises midway cannot lose the
new `head` — the walk goes backwards from `head` and every link older than the
window is deleted **together with its delegated children** (`SessionManager.delete_tree_ids`): the
whole subtree only when every session in it is archived and no worker owns any of
it, deepest child first and the link last, oldest link first. The delete itself is
`SessionManager.delete_ids` (the prune keeps its own checks and log tags): each id
through `delete_session`, and System 1's saved runs and the candidate log purged once
per link's batch, not once per session. Each link goes under the transition
locks of it and the link after it (`SessionTransition`, one try, kind `delete`).
**A link that can't go now holds the prune there**: one not archived (brought back
by hand), one whose subtree holds a schedule's anchor, head or target (another
enabled schedule anchored inside the chain, as `schedule_task` from a link does), a
live worker or an unarchived descendant in its subtree, or its or the next link's
transition lock held (a send, a continue, a delete). The prune stops below it: that
link and every newer one stay, and nothing is deleted around it. The entry records
where it waits (`prune_waiting` in schedules.json: link, reason, since when; no
history row), `chi schedule list` adds `pruning held at <id>` to the row and `show` a
line `pruning held at <id>: <reason>  (since …)`, the log says `prune_waiting` once
per link (not every tick), and every tick tries again, not only after a firing; once
it gets past, the record goes. A schedule anchored inside the chain holds it until
that schedule is cancelled. Pruning a link alone would leave its finished
delegates archived forever with a dangling `parent_id`: archiving a session archives
its descendants, and archived sessions are outside the retention sweep
([sessions.md](sessions.md)), so the delegate pile is the bulk of the archived
count. The `anchor` is never pruned: it is the chain's root, the id the user and
the coordinator remember, and `last:<anchor>` must keep resolving. Once the
anchor's successor is gone, nothing continues the anchor; the chain walks for
`last:`, `chi send` and notes cross that gap to the entry's `head`
(`SessionChain::Links#anchor_forward`, [sessions.md](sessions.md), *Session chains*
→ Which link), so the anchor stays the chain's address. A link a previous prune
already deleted is skipped, so each later firing prunes the next link behind the
window.

What a schedule protects (its anchor, its head and its resolved target, while it is
enabled) the retention sweep keeps and a delete refuses: schedules are
`SessionProtection`'s one protector (`Schedules::ProtectionPart`, [sessions.md](sessions.md)). It reads
`schedules.json` strictly: a file that is there but doesn't read (not JSON, a `schedules` member that isn't a list, a
file chi can't open) makes the sweep delete nothing that round (`retention_skipped`, retried at the next sweep
interval) and every delete refused, "schedules.json is unreadable (…): fix or remove it before deleting sessions". One
schedule that doesn't read does the same in its own words, "schedule entry <id> in schedules.json is unreadable
(lacks prompt): chi schedule cancel <id>, or fix the file, before deleting sessions": `chi schedule cancel <id>` removes
such a record by its id (`list` doesn't show it). The tick keeps its own rule (it refuses a file that isn't JSON and
skips a schedule that doesn't read).

Schedule prune leaves the deleted links' background tasks running: a later link
may still use a server started by an earlier link in the same project. Continue
does not yet transfer task ownership.

The oldest kept link still has `continues` naming a link that is gone. The walks
follow `continues` forward, so nothing breaks; the web's `↩ #N of M` chip counts
from the surviving root (pruning renumbers the links) and says "earlier links
pruned" instead of linking to a deleted session.

If a link to prune still has a worker (`DeleteRefused(:worker_running)`), pruning
stops there for this firing and is retried at the next one.

Retention keeps the stored `anchor` and `head`, as well as the resolved target,
of every enabled schedule. Deleting a protected session (a schedule's target,
anchor or head: a deleted head would make the schedule fall back to an archived
link and lose the links after it) is refused—even with
`chi sessions delete --force`—until the schedule is cancelled with
`chi schedule cancel ID`; a disabled schedule does not protect its sessions.
Deleting a whole chain (`--chain`) is refused while any enabled schedule is on it.

## Running the tick

`chi schedule tick` is quiet and safe to run often; it is this machine only
(`chi --remote studio schedule list` exits 2), so point cron at the chi of this
machine (cron runs with a thin PATH, so name the binary rather than a shell
function):

```
# crontab -e on the machine
*/5 * * * * /Users/you/.local/share/mise/installs/ruby/global/bin/chi schedule tick >> /Users/you/.local/state/samagotchi/schedule-tick.log 2>&1
```

Run it from systemd or launchd instead if you prefer a timer: the command is the
same, `chi schedule tick`, and the lock makes overlapping runs harmless — the
second one exits 0 with "no schedules due (another tick holds the lock)".
`--dry-run` prints what would fire and changes nothing; `--format json` is the seam
for scripts; a page script reads the schedules in chi itself instead
(`runtime.schedules`, [pages.md](pages.md#reading-chis-data-runtime)). `chi schedule run-now` reserves the entry
under the same lock before starting its action, so it cannot race a tick into a
duplicate firing.

A tick fires **one entry per chain**: of the due entries of one chain, the one due
earliest (`next_due`, then id) fires and the rest are skipped — "the chain just
fired; retry at the next tick" — with `skips += 1` and `next_due` left at the
occurrence they tried, so the chain's entries take turns instead of the first one
added winning every tick. A second chain
firing in the same pass would continue the link the first one just made and archive
it before its prompt ever ran: that link has no worker lock yet and the tick's
listing predates it, so the busy check cannot see it. `same` entries are unaffected:
they queue a turn, they do not archive.

`schedule.auto_tick: true` makes chi web's hub tick on
`schedule.tick_interval_minutes` (default 5) as well, sharing the same lock, so
cron and the hub can coexist without firing twice. The hub runs its tick outside
the session scan loop and allows only one hub tick at a time, so a firing waiting
on a worker does not stall session updates. It is off by default: cron or systemd
is the documented driver. When it is off and no tick has run within twice
the configured interval, `chi schedule add`, `chi schedule list` and `schedule_task`
warn to turn `schedule.auto_tick` on or run `chi schedule tick` from cron; `--dry-run`
and lock-held attempts do not refresh `last_tick_at`.

## The Schedules page

`chi bundle install schedules` adds a **Schedules** page to chi web (`#/p/schedules`,
under the `pages` pill; `chi page run schedules` in a terminal) from the shipped
schedules bundle ([bundles.md](bundles.md#the-schedules-bundle)). It shows how many
schedules there are and in which state, with the tick warning when nothing ticks; each
schedule that is off and why ("turned off by you", "skipped 12 times (≈1 h at a 5 min
tick): busy", "failed 3 times: …", "one-off, done") with the `chi schedule enable ID`
that turns it back on (for a spent one-off, which has no next time, a `chi schedule
edit ID --date …` first); each entry of `schedules.json` that can't be read with the
`chi schedule cancel ID` that removes it; a table of every schedule (its If column the `--if` command; on and firing
first by next due, those with none last, then off; times in this machine's zone) and the recent runs, newest
first. It is read-only: ask chi, or use `chi schedule`, to change one. What it shows is
as of its last run: Refresh to update. A `schedules.json` that isn't JSON fails the
run with the store's own words, and the last good result stays.

See [cli.md](cli.md) for the subcommands and flags, and
[configuration.md](configuration.md) for the `schedule.*` settings.
