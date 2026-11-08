# Schedules (`chi schedule`)

A **schedule** is a prompt with a clock. It lives in one file on this machine, not in a
worker's memory, so it outlives every session, every restart and every crash:
`~/.local/state/samagotchi/schedules.json` (next to `sessions/`, written with
`AtomicFile`, every change a read-modify-write under `schedules.lock`, so cron and
chi web's hub can never lose an update to each other). A **tick** — cron, systemd,
launchd, `chi schedule tick`, or chi web's hub when `schedule.auto_tick` is on —
walks the entries whose `next_due` has passed and runs the ones that are not busy.

Each entry carries `id`, an optional `title`, `anchor` (the session it was made
against, never rewritten: the chain's root and the id you remember), `head` (the
chain's current link, re-anchored after every firing: the link a chain continue
made, or the session a `same` turn was queued into), `mode`,
`prompt`, `recurrence`, `catch_up`, `keep_links`, `max_failures`, `max_skips`,
`next_due` (UTC ISO), `last_fired`, `last_result`, `failures`, `skips` and
`enabled`.

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

A schedule turn carries `client_id: "system:schedule:<id>"`, so `ClientId.origin`
says `schedule` and the terminal and the web label it as such rather than as
something you typed. Like `register_reminder`, the schedule tools are owner-voiced:
a participant's review or pair turn is denied them ([guardrails.md](guardrails.md)).

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

A cron tick cannot read a worker's memory, so the tick has two paths.

**No live worker** (the usual case for a weekly schedule): the files say what can
be known — the saved status is not `running` (and not inside the starting grace),
`input/` is empty, no step-limit question is open. Nothing else can be busy.

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
resolving) and `:open_children`.

Anything else is a **failure** (`failures += 1`): a gone or archived target,
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

A chain holds at most `schedule.max_per_session` enabled schedules (default 10) and
the machine `schedule.max_total` (default 50); `schedule_task` and `chi schedule add`
refuse past them, naming the key. A schedule the chain already has — the same prompt
and recurrence, or the same title — is refused too, naming its id, so a routine that
tells each of its links to "make sure the Monday audit is scheduled" cannot multiply
itself. `schedule_task`, `list_schedules` and `cancel_schedule` see only schedules of
the calling session's chain (`all: true` steps outside it); `chi schedule list` is
always the machine-wide view. An id, prefix or title that matches more than one entry
is refused with exit 2, naming the matches.

The tick's lock covers the file only, never the action: the clock advances before
the work starts — for `every` and `weekday` to the next occurrence, for a `date`
one-off to none — so a tick killed mid-continue cannot fire the same entry twice.
`firing_since` is what `chi schedule show` prints; the advanced clock is the guard.
And a `chi schedule add` from a terminal never waits on an archive or a recap wait. Chain mode targets `last:<head>`, so `SessionContinue.run`'s
own retry loop follows a continue a human made between our resolve and its lock
instead of racing it.

## Keeping the chain short

`keep_links` (default `schedule.default_keep_links`, `0` keeps all) is how many
chain links stay behind the head. After a successful chain firing — and after the
result is recorded under the lock, so a prune that raises midway cannot lose the
new `head` — the walk goes backwards from `head` and every link older than the
window is deleted **together with its delegated children** (`descendant_ids`): the
whole subtree only when every session in it is archived and no worker owns any of
it, deepest child first and the link last, oldest link first. A subtree with a live
worker or an unarchived descendant is left whole and retried at the next firing. Pruning a link alone would leave its finished
delegates archived forever with a dangling `parent_id`: archiving a session archives
its descendants, and archived sessions are outside the retention sweep
([sessions.md](sessions.md)), so the delegate pile is the bulk of the archived
count. The `anchor` is never pruned: it is the chain's root, the id the user and
the coordinator remember, and `last:<anchor>` must keep resolving.

The oldest kept link still has `continues` naming a link that is gone. The walks
follow `continues` forward, so nothing breaks; the web's `↩ #N of M` chip counts
from the surviving root (pruning renumbers the links) and says "earlier links
pruned" instead of linking to a deleted session.

If a link to prune still has a worker (`DeleteRefused(:worker_running)`), pruning
stops there for this firing and is retried at the next one.

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
for scripts and for a future web UI.

A tick fires **one entry per chain**: of the due entries of one chain, the first
fires and the rest are skipped — "the chain just fired; retry at the next tick" —
with `skips += 1` and `next_due` left at the occurrence they tried. A second chain
firing in the same pass would continue the link the first one just made and archive
it before its prompt ever ran: that link has no worker lock yet and the tick's
listing predates it, so the busy check cannot see it. `same` entries are unaffected:
they queue a turn, they do not archive.

`schedule.auto_tick: true` makes chi web's hub tick on
`schedule.tick_interval_minutes` (default 5) as well, sharing the same lock, so
cron and the hub can coexist without firing twice. It is off by default: cron or
systemd is the documented driver.

See [cli.md](cli.md) for the subcommands and flags, and
[configuration.md](configuration.md) for the `schedule.*` settings.
