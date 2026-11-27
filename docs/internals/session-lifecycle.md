# Session lifecycle

There is no persisted lifecycle enum. A state is derived from the session file, sidecar files, locks, and the worker
link: `SessionLifecycle.read(id)` (`session_lifecycle.rb`) reads them once (`WorkerPresence` with its link looked at,
never unlinked, and `ContinueIntent.in_flight`) and names the first of its 15 states whose facts hold (Derived states).
The same session can satisfy more than one fact (archived while its worker is leaving); the precedence picks one. Two
deciders read `SessionLifecycle`: `restart_session`'s precheck and a schedule's busy check (`Schedules#busy_cell`;
Allowed operations). The others still read their own
subset of the facts in their own order, and what each answers per state is `ALLOWED` (Allowed operations), pinned by
the characterization matrix. The session file layout and user-facing session behavior are in [Sessions](../sessions.md); the Worker and
SessionManager boundaries are in [Architecture](../architecture.md) and [Engine internals](engine.md).

## Facts and markers

| Fact | Writer and removal | Cross-process readers and how they see change |
|---|---|---|
| `<id>.json` `status` | `Session#save` writes the session snapshot; the owner is the normal writer. `Session#load` overlays `stopped` as `stopped` without rewriting the file. | `SessionRow` and `SessionAccess::Local` read saved turn status; stop cancellation, restart fallback, and archive refusal also use it as a busy hint. Readers reload the file; the hub refreshes rows on its tick. It is turn state, not proof of liveness. |
| `starting` (`{pid, at}`) | `SpawnPart#spawn_session` marks before the first session file; `#spawn_worker_for_session` marks around `Process.spawn`; `#claim_start` claims with `StartingMarker.claim`. Failures clear it; `Worker#start` clears it after acquiring `owner.lock`. A stale/dead marker is taken over after 60 seconds or when its pid is gone. | `WorkerPresence`, resume, archive, delete, and retention read it directly; `WorkerPresence` checks age and pid. The session hub also refreshes presence. The atomic hard-link claim arbitrates competing starters; there is no event notification. |
| `owner.lock` and `leaving_at` | `OwnerLock.acquire` creates the file, takes its exclusive flock, and writes `{pid, kind, started_at}`; `OwnerLock#mark_leaving` adds `leaving_at` and `leave_wait`; `#release` unlocks and closes but leaves the file. Deletion removes it with the session directory. | `OwnerLock.owner` probes the kernel flock, then reads the record. The kernel releases the lock on process death; the record alone does not establish ownership. Presence and `WorkerLink` decisions probe it; hub presence refreshes poll it. `leaving_at` marks a worker that closed its Bridge but still holds the lock for leave work. |
| `bridge.json` | `Bridge#write_sidecar` publishes the worker endpoint; `Bridge#remove_sidecar` removes its own sidecar when stopping. A crash can leave it behind. | `WorkerLink.resolve` combines the sidecar with `owner.lock` and pid; a sidecar alone is stale. Readers waiting for a worker poll `WorkerLink.resolve`; a stale unlink rechecks the owner and removes only the unchanged file. Live clients see worker events over Bridge SSE. |
| In-memory exit claim | `Worker#exit_request` uses `WorkerExitClaim#claim`, `#accept`, `#release` and `#forget`; `#stopped!` records the last stop-all. It dies with that Worker. | Only that worker's threads read it; the Bridge's `/exit` and the loop coordinate through the Engine event lock, not a cross-process file. |
| `stopped` | `SessionManager#stop_session` calls `Session.mark_stopped`; `SpawnPart#resume` and delivery's `#start_for_send` clear it with `Session.clear_stopped` when starting for a person. Session-directory deletion removes it. | `WorkerPresence`, the worker startup/signal paths, and `Session#load` check the marker. It is read from disk on a decision (and on the hub refresh); no worker event is required. Its timestamp is compared with `starting.at` so a stop cancels an older start, not a later resume. |
| `archived` | `ArchiveStore.archive` is called by `SessionManager#archive_session`; `ArchiveStore.unarchive` is called by `#unarchive_session`, `SessionContinue#undo_failed_continue`, and the chain-delete undo/revival paths. Session-directory deletion removes it. | Lists, chain resolution, delivery, schedules, retention, and `WorkerPresence` call `ArchiveStore.archived?` against the file; changes are seen by the next read or list refresh. |
| `continue.lock` and `continue.json` | `SessionTransition` is the only code that flocks `continue.lock`: a continue takes it exclusively after its recap, for the previous link and the new link's reserved id at once (`SessionContinue#with_lock`: `exclusive`, `LOCK_WAIT` 10 s a try, then `Refused :transition_busy`), a user's link or chain delete takes it exclusively for its whole run (`SessionChain::Delete`, kind `delete`, `LOCK_WAIT` 10 s), the schedule prune, the retention sweep and a leaving worker's empty or scratch delete try it once (kind `delete`), crash repair tries it once (`try_exclusive`), an exclusive holder records its kind in the file while it holds it (`holder`, which `Busy.held` reads), arrivals and readers that must exclude a continue take a nonblocking shared hold (`shared`: each `WakePolicy` row's `hold`, taken in the seats), and previews probe it (`held?`). `ContinueIntent#write` records the successor before archive and updates the archived ids after; failed-continue cleanup removes the intent. The lock file remains until session-directory deletion; a continue that ends before its new link is saved removes that link's reserved folder, and the previous link's lock when the link was deleted meanwhile (`SessionTransition.forget`). | Every `:shared` delivery (sends, every turn sender, pushes, peer says), peer pairs, context adds/removes/pushes, invites, schedules, the delete preview, `SessionLifecycle.read` (`transitioning`) and `ContinueIntent.in_flight` (through `SessionChain::Successor`) inspect the lock and intent. flock coordinates the live transition; readers reload the JSON. An intent without a held lock is a crashed continue, not an active one; so is one whose successor is neither saved nor held (a continue holds both). |
| `parent.json` | `Session#reparent` writes the override when `ChildMove` moves a child. Session-directory deletion removes it. | `ChildReports` resolves the current parent when routing a ring; the worker reads the override when loading its parent. Readers reload the file; it is not an event stream. |
| `reminders.json` | `Worker::LeavePart#carry_reminders` writes it for an asked restart, or removes it when stopped/no successor; stop, archive, and a stopped restart also remove it. `ReminderCarry#take` reads and removes it at worker start. | Only the next worker restores it into its Engine. It is a one-shot hand-off, not polled state; the session id, 120-second window, and stop marker are checked before restore. |
| Pending `input/`, `children/`, and `notes/` | `SessionInbox.write_input`, `#write_ring`, and `#write_note` write the files. A worker claims input and notes by atomic rename to `.processing`, then removes or settles them; rings are consumed by `ChildReports`. Session-directory deletion removes all three. | The worker checks input around turns and on its idle loop; rings and notes are checked by worker wake/absorption paths. The file is the durable queue; Bridge SSE can announce a live turn, but the worker's file scan is the fallback and recovery path. |
| Turn checkpoint and pending question | `TurnCheckpoint` writes the running turn overlay at iteration boundaries and clears it at settlement/end; `QuestionDesk` updates `Session#pending_question`, persisted by `Session#save` and cleared on answer/settlement. | The next worker settles a checkpoint on startup instead of replaying the dead turn. Session readers and Bridge snapshots read the pending question; answers go through the live Bridge when present. These are session data, not liveness locks. |
| `scratch` | `SpawnPart#spawn_session` saves the flag in the session file. There is no separate marker; terminal/worker cleanup deletes the scratch session. | Inbox wake policy and worker boot read the session field. Scratch sessions are not resumed by ordinary delivery; their worker is removed when its terminal leaves. |

`SessionStores` registers cross-version sidecar ownership and removal with the session directory. The lists above focus on
the lifecycle facts; deletion takes the session's `owner.lock` as `deleting`, rechecks `starting`, then removes the JSON
and entire sidecar directory.

## Derived states

`SessionLifecycle::STATES`, in precedence order (the first whose facts hold wins), as `Reading.derive` names them from a
`WorkerPresence` read with its link (`SessionLifecycle::Reading`: `state`, `presence` (also `facts`), `continuing`).
These are reader labels, not stored values:

| State | Facts that produce it |
|---|---|
| `absent` | No session file; a leftover sidecar directory may still exist (its facts are ignored). |
| `tui_owned` | `owner.lock` held with kind `tui` (a one-shot `chi -p --non-interactive` owns it): an in-process one-turn host, not a worker. Wins over a stop, a start, an archive. |
| `deleting` | `owner.lock` held with kind `deleting` while the session's files go (`WorkerLink` reads it as `Starting`). Every delivery is refused (`WakePolicy`'s `:deleting`); restart refuses it (`deleting`); a schedule skips it ("the session is being deleted"). |
| `stopping` | A worker holds the lock and the `stopped` marker exists, whatever its link. |
| `skew` | A worker holds the lock and its sidecar speaks a newer protocol (`WorkerLink::Skew`); a schedule skips it with Skew's short words. |
| `leaving` | The worker closed its Bridge and still holds the lock (`leaving_at`, `WorkerLink::Leaving`). |
| `booting_stuck` | A worker has held the lock past `WorkerLink::START_LIMIT` without its sidecar (`Starting`, stuck). |
| `booting` | A worker holds the lock without its matching sidecar yet (`Starting`); also an owner of unknown kind (a lock record still blank after `OWNER_READ_ATTEMPTS`). |
| `live` | A worker holds the lock and its sidecar matches it (`WorkerLink::Live`). |
| `stopped_starting` | No owner; the `stopped` marker and a fresh `starting` marker (archived or not). |
| `stopped` | No owner; the `stopped` marker (archived or not). |
| `archived_starting` | No owner, no stop; `archived` and a fresh `starting` marker. |
| `starting` | No owner, no stop, not archived; a fresh `starting` marker names a live starter. |
| `archived` | No owner, no stop, no start; `archived` has `archived_at`. |
| `idle` | The session exists with none of the above. |

The compound states exist because the deciders disagree on precedence: owner first (WakePolicy, resume, archive,
delete) or stop first (a schedule's busy check, a terminal's attach); WakePolicy reads archived before starting. Facts
that are not states: `continuing` (`continue.json` names a successor and `continue.lock` is held: only a send's and a
schedule's link resolution reads it), `transitioning` (`continue.lock` held by anyone: `SessionTransition.held?`;
any state can be held, so it is a fact beside the state, and `SessionLifecycle::TRANSITIONING` holds its cells), a stale sidecar (`WorkerLink::Stale`: a crashed worker's leftover, reads as
the no-owner state), and the other crashed leftovers (a checkpoint, a `.processing` file, an unlocked continue intent).
`SessionLifecycle::CANONICAL` holds the fewest facts per state, each deriving back to it; `stopping` is a worker whose
Bridge answers, with a stop, and `stopped_starting` a start marked before the stop.

A read costs what `WorkerPresence.read(link: :look)` costs plus a `continue.json` stat: idle about 8 probes and one
flock, no JSON (~20–50 µs); a live worker adds the owner record and `bridge.json` (~0.1–0.2 ms); a continue in flight a
lock probe and its JSON. The worst case is `OwnerLock.owner`'s blank-record retry (0.1 s).

## Allowed operations

`SessionLifecycle::ALLOWED` (`session_lifecycle/allowed.rb`) is `{op => {state => cell}}`: every operation in every
state. A cell is `:go`, `:wait` or the decider's own refusal reason; `SessionLifecycle.verdict(op, cell)` reads it as
`:go`, `:wait` or `:refused` (resume's `live` and `starting` wait, restart's `fallback` goes).

- **Delivery columns** (send, note, push, ring, fresh_verdict, leave, schedule, plugin, delegate, participant,
  agent, automatic) are generated at load from `SessionInbox::WakePolicy::ROWS`, unchanged: each row's `decide` on
  `CANONICAL[state]` (a worker asked for, no scratch file), `:start`/`:live` as go, `:starting`/`:stopped`/
  `:archived`/`:none` as wait, `:gone`/`:owned`/`:deleting` as themselves. `:off` and `:scratch` are op-local.
  `deleting` refuses every kind: `WakePolicy#refusal` before the write (nothing written), `#decide` after it (a
  delete that took the lock between the two). What each kind does then: a turn delivery (`deliver_turn`, any sender)
  answers 409 `DeliverResult::DELETING` ("the session is being deleted") and after its write takes its file back
  (`SessionInbox.withdraw`; a file a worker claimed meanwhile stays delivered), also when the session went while it
  wrote (and a folder the write made again goes); a note is a gone session's (`Session::NotFound`, its note taken
  back); a ring, a push and a fresh verdict are refused before their write as for a gone parent (a push records to
  its source's folder as for a gone session), and `wake_for_report` answers `:deleting`; a leave's respawn drops
  (`why: deleting`).
- **While a transition holds the lock** (`SessionLifecycle::TRANSITIONING`, read by `allowed(op, state,
  transitioning: true)`): every delivery whose row holds `:shared` is `:busy` in every state (refused before its own
  checks, nothing written; `:continued` instead when the holder is a continue naming its new link, a resolution fact
  as `continuing` is); a `:none` row answers its state's cell. Generated from the rows' `hold`; the literal
  operations read no transition lock yet.
- **Literal columns** (`LITERAL`): resume (`resume_session`), restart (`restart_session`: `stop_marked` in every
  state with the stop marked: stopping, stopped, stopped_starting), stop (`stop_session`),
  archive (`archivable!`), delete (`release_for_delete!`, without a stop), sched_chain and sched_same
  (`Schedules#busy_reason`; `worker_busy` is "its worker is starting or leaving", `deleting` the delivery's "the
  session is being deleted", `worker_newer` `WorkerLink::Skew#short_message`) and attach
  (`TerminalUI::LocalLink#live_worker`: `gone_stopped`, `gone_worker_newer`). They assume neutral op-local facts: not
  scratch, saved status idle, no `input/`, no question or offer, not SIGSTOPped, features restart and activity, an idle
  worker with no streams. Absent's delete and schedule cells are unreachable (a gone session is refused first).

Link resolution (`SessionInbox::Head.resolve`, `Schedules#target_of`) stays outside: the cells are the link's own.

The running-tasks check of a user's delete and archive (`SessionManager::RunningTasks`, `tasks_running`) is op-local,
not an `ALLOWED` cell: it reads the transcript and each `task.json`, not the lifecycle's facts, and runs after the
lifecycle refusals (`refuse_protected!`, `archivable!`), before the worker is stopped.

`restart_session` is the first decider migrated to the table: its lifecycle precheck is `SessionLifecycle.read` (the
owner read through `session_owner`) and `ALLOWED[:restart]`: `owned_by_tui` raises `OwnedByTUI`, a refusal cell
raises `RestartRefused` with it as the reason (`starting`, `not_running`, `stop_marked`, `deleting`), `fallback` goes to
`restart_fallback` (skew, a stuck start) and `go` asks the live worker. Its op-local checks stay where they were: the
SIGSTOP check (`:stopped`, the worker's pid: a different condition with its own words, before the table's refusal),
the worker's `restart` feature, the Bridge's reply and the fallback's holds. The matrix still drives it, so its
column is pinned against the precheck and the op-local paths together.

A schedule's busy check (`Schedules#busy_reason`, `schedules/busy_part.rb`) is the second: it reads `WorkerPresence`
as before (the owner through `session_owner`, the link looked at), derives the state with `Reading.derive` on that
presence with `exists: true` (the target resolved already, and a delete mid-way, its JSON gone under the deleting
lock, must read `deleting`, not `absent`; no `ContinueIntent` read), and `#busy_cell` takes `ALLOWED[:sched_chain]`
or `[:sched_same]` for it. Two op-local overrides keep today's order, each named by its `KNOWN_DIFFERENCES` entries: the
stop marker before the owner (any cell but `deleting` becomes `stopped`: F1, and an unknown owner's stop), and chain
mode's starting check with no one-turn-run check (a fresh starting marker without a worker's lock makes `go`
`worker_busy`: F1b). A skip cell's words are `BUSY_WORDS` (`worker_newer` is Skew's own). On `go`, a live worker
is asked through its Bridge (`#live_busy_reason`: `/activity`, an old chi, the three activity signals, chain mode's
open streams) and any other session goes to the file checks (`#file_busy_reason`): those stay op-local, as restart's
SIGSTOP, features and Bridge reply do. The other deciders don't read `ALLOWED` yet.

## Characterization matrix

`spec/session_lifecycle/matrix_spec.rb` (rows, files and drivers in `spec/support/lifecycle_matrix.rb`) writes every
combination as real files: owner/link pairs (none, stale sidecar, tui, tui with a stale sidecar, deleting, a worker
Live, Starting, stuck, Leaving, Skew, an owner of unknown kind) × stop × starting × archived, one absent session, a
continue in flight on each archived no-owner row, and a start marked after the stop on each no-owner row with both
(the order is a row fact: `StartingMarker.claim` takes over only a start at or before `stopped_at`), and four rows
(idle, archived, stopped, a live worker's) with the transition lock held for real by another thread
(`transitioning`): their deliveries go through the seats (`SessionInbox.deliver`, `deliver_turn`) and must answer
`TRANSITIONING`'s busy for a `:shared` row, the state's cell for a `:none` one. The owner lock's
holder, `ContinueIntent.in_flight`, `Process.spawn`, TERM/CONT, the Bridge and the restart fallback are stubbed; no
process starts. Each row checks that `SessionLifecycle.read` names the state its facts derive, then drives every
operation (one driver each, every private reach in that one file) and projects its answer into a cell. A row the
code can't make (a one-turn run's lock with a stop) is marked `reachable: false` with its note and still asserted.

Every answer must equal `ALLOWED[op][state]` (for the session hub, `SHOWN[state]`: `Web::SessionSummary.build`'s
status and bridge_up, its `SessionRow`'s live), or be named by exactly one `KNOWN_DIFFERENCES` entry (op, a `when`
over the row, a plain reason); an entry that names no mismatch fails as stale. The entries are the findings for the
owner, not fixed: stop-first schedule checks under a one-turn run's or an unknown owner's lock (`#busy_cell`'s stop override), and attach's under a
one-turn run's, a deleter's or an unknown owner's; chain mode's starting check before any one-turn-run check (`#busy_cell`'s F1b override); a start
marked after the stop holding a resume off;
`wake_for_report` reporting a worker's `:live` as `:owned`; the hub's bridge_up, live and status overlay. (Restart
never reading the stop, the restart and schedule reading a deleter as starting, the schedule's Skew words, and
`busy_reason`'s live branch falling through to the starting check were fixed: their entries went stale and were
removed.) The delivery columns are
generated from `WakePolicy::ROWS`, so for deliveries the matrix proves the states are drawn right (decide is a function
of the state), not what WakePolicy does; the literal columns and `SHOWN` are goldens.

## Locks and crash repair

`owner.lock` is the single-owner boundary for an Engine; its flock is released by process death. A starting claim uses
an atomic link rather than a long-held lock. A continue holds its exclusive `continue.lock` (and its new link's) from after the recap to the end;
a user's delete holds them exclusively for its whole run, and the prune, the retention sweep and a leaving worker's
delete for each removal ("Deletes, the prune and retention"); shared holds protect every `:shared` arrival (the seats,
"Arrivals declare their hold"). Every delete takes its transition locks before the `owner.lock` deletion locks. Inside a worker, the lock order is Engine event lock, then
`WorkerExitClaim`'s mutex. Session saves serialize through their per-session save lock. These locks protect separate
facts; there is no global lifecycle lock or atomic snapshot across all markers.

A worker that crashes exits 1 and is not respawned just because input is queued. A later delivery may start a new
worker; under its owner lock, startup settles a turn checkpoint and stale running status rather than replaying the
dead turn. Interrupted continue intents are repaired separately by session listing/the web hub or before another
continue (`SessionContinue.repair_interrupted`), not by worker startup.

### The transition lock (`SessionTransition`)

`continue.lock` is a session's transition lock, and `SessionTransition` (`session_transition.rb`) is the only code
in lib that flocks or probes it (`spec/session_transition_lock_spec.rb`). The file keeps its name: an older chi's
continue, followed send and delete honour it.

- `exclusive(ids, kind:, state_dir:, deadline:)` takes each id's lock in sorted order, creating a missing folder;
  `deadline: nil` blocks (no caller since the continue took a deadline), seconds retry until then (`0`: one try)
  and raise `SessionTransition::Busy`, which owns its refusal text and names the id. Ids taken before a busy one are
  let go. While it holds a lock it writes its `kind` into the file (cleared on release, never from a lock another
  holds; `try_exclusive` too).
- `holder(id, state_dir:)` is that kind (`:continue`, `:delete`), read only behind a failed shared try: a shared
  holder (a send), an older chi's continue, a raw flock and a crash's leftover name none. `Busy.held(id, state_dir:)`
  is the one place that says who holds a lock: a delete is "being deleted" whatever else is on disk; else a continue
  in flight (`ContinueIntent.in_flight`) is "being continued as <new id>" (`SessionChain::Continued`'s words), a
  continue before its intent "being continued", anything else "busy with another change" (each "; try again in a
  moment"). `exclusive`'s own Busy, the seats' busy refusal (`deliver_turn`), the continue's `transition_busy`
  (its detail, which `--remote` reads back), `ContextSources.changing`, `Participants.invite`, the delete's refusal
  (`DeleteRefused.held`) and the delete preview take their words from it; a delete holding the lock makes the seats
  name no successor (`Hold.under`). The peer say/pair and the context push answer a status, `:busy`, whose words
  are the plain ones.
- `try_exclusive(id, …)` is one try that creates no folder, crash repair's (`repair_intent`): a lock this thread
  holds counts as taken, so a repair reached inside a continue never undoes it.
- `shared(id, state_dir:)` is a non-blocking shared hold (an invalid id is `false`; the lock file is created, the
  folder only for a session whose file is there: a deleted session's folder is never made again, nothing is held and
  the caller's own gone refusal follows; a lock file it made for a session gone by the block's end is taken back),
  around every arrival's check and write (the seats, below), a peer say's, a peer pair's and a context push's
  continued check and write (`SessionAccess::Local#moved_on`), a context add or remove (`ContextSources.changing`),
  and an invite (`Participants.invite`). A caller that can't write the session folder
  (a peer's chi behind the mailbox door) holds an existing lock file read-only, and holds nothing when there is none
  (no transition holds a file that isn't there; one starting after it is not held off).
- `held?(id, state_dir:)` is a kernel probe (`in_flight`, `DeletePreview`, `holder`): it creates nothing and ignores the
  registry, so it answers the same inside this thread's own hold.
- `forget(id, state_dir:)` takes back the lock file `exclusive` left for a session with no session file (one try
  EX|NB; held, or this thread's, it stays) and its folder when that empties it.

**Order:** transition locks (several ids sorted) before any `owner.lock`. A taker that holds an `owner.lock` (a worker:
a delegate follow-up, an ask, a plugin's send, a ring, its own objectives note) only ever takes a transition lock
shared and non-blocking, so no owner-then-transition path waits. **Token per thread:** an exclusive hold is
the current thread's (`Thread#thread_variable_*`, not per process: chi web is multi-threaded, and not fiber-local);
that thread passes through `exclusive` and `shared` of a held id without touching the file (a second flock on the
held descriptor, or a dup, would convert it). Work handed to another thread doesn't carry the hold: it takes it again
or is refused. Before the registry, a shared hold inside a continue's own lock was refused; nothing a continue runs
under its lock takes one of its own id or reaches `follow_guard`, `Delete.link` or `Delete.chain`
(`spec/session_continue_spec.rb` records any). **No fork while held:** a forked child keeps the flock; workers
start through `Process.spawn`, whose descriptors are close-on-exec.

**A continue's hold** (`SessionContinue.run` → `continue_once`, `spec/session_continue_spec.rb` "the transition
lock"). Unlocked: the refusals known before anything changes (`check!`, `archivable!`) and the recap wait (up to
`RECAP_WAIT` 30 s), so a send during the wait goes in (the archive then refuses it as before) and a delete may take the
link (its exclusive hold then makes the continue's wait for the lock end busy, "being deleted"). Then one `exclusive([previous, reserved successor id])`, sorted, `LOCK_WAIT` (10 s) a try: under it the previous
link is loaded and `check!`ed again (continued meanwhile → `Refused :continued`; deleted → not found; the delegate
plan made again), then the intent, the archive (`archive_session` → `stop_session`, nested), the new link's spawn and
carry (notes, peers, context, objectives, `ChildMove` notes and rings), or the undo (`return_rings`,
`NoteMove.give_back`, unarchive, `wake_for_rings` → `wake_for_report` → `resume_session`, `discard_failed_link`'s
stop and delete of the new link). All of it runs on the continue's thread under its token: a shared hold or a nested
exclusive of either id passes through, so no step refuses itself (`exclusive` skips held ids). Busy: a plain id is
refused `:transition_busy` (`SessionTransition::Busy.held`'s words naming the holder, a 409 of that name from chi
web; a schedule's chain firing counts it a skip, `Schedules::SKIP_REASONS`); a `last:<id>` continue with tries left
resolves again and waits again, so a second firing of the same chain follows the first one's new link. Any sender's turn
that meets the hold is refused naming the successor from the intent (`follow_guard`, "Arrivals declare their hold"
below: `SessionChain::Successor.in_flight`), else `transition_busy`; so are a peer say, a peer pair and a context push into the link's own source
(`:continued` with `in_flight`), or `:busy` in `SessionTransition::Busy`'s words when the holder names none. Who
continues a link is one answer, `SessionChain::Successor.of(id, state_dir:, in_flight:)` (`via` `:next`, `:anchor`
or `:in_flight`), and the refusal one wording, `SessionChain::Continued` ("session X was continued as Y", "is being
continued as" in flight), each site adding only what to do next. The new link's worker starts inside the hold, in its own process: its boot writes into its
own session (`ChildMove.adopt`, `NoteMove.adoption`, its objectives notes) take no transition hold, and must not (they
would be refused by the continue's exclusive). The reserved folder (`exclusive` makes it) goes whatever way a continue
ends before the new link is saved, with any note left there given back to the previous link; crash repair drops a
crashed continue's the same way. `Schedules::FIRING_TIMEOUT` (70 s) covers the recap, a lock wait per try and the
archive.

### Deletes, the prune and retention

- **A user's delete** (`SessionChain::Delete.link` / `.chain`, from `delete_session` with the chain keywords and
  `delete_chain`: the CLI, chi web, `/exit --delete`) takes `exclusive(ids, kind: :delete, deadline:)` of every
  session it takes or brings back (a link: it, the previous link it would revive, its delegates that go; a chain:
  every link and their delegates), only ids still on disk (a gone one's folder is never made again), sorted, within
  `LOCK_WAIT` (10 s) from the start. The plan is made (a chain's checks run) again under them; ids it adds then (late)
  are a nested `exclusive` with the time left (held ids pass through). The stop (`release_for_delete!` →
  `stop_session`), the task stop, the owner locks (`locked`, kind deleting), the removal, the undo
  (`undo_deleted_link`) and the revival all run under the token. A lock not taken in time is
  `DeleteRefused.held(busy)`: `:continuing` when a continue holds it, else `:transition_held` (chi web's 409 of that
  name, which `--remote` reads back as `DeleteRefused`), Busy's words either way. A continue holding one of the ids
  when the delete looks refuses it at once (`:continuing`, no wait: its end would change what the delete takes), and a
  link continued while the delete waited for the locks is refused `:continuing` naming the new link rather than
  deleted as a middle link. `refuse_continuing:` no longer
  changes anything inside: either keyword takes `Delete.link`, which always refuses a held lock.
- **The schedule prune** (`Schedules::PrunePart`) takes `exclusive([link, next link], kind: :delete, deadline: 0)` per
  link, oldest first, and checks the link's hold (`prune_hold`: archived, a protector, a worker, an open descendant)
  before and again under it. Busy or a hold stops the prune below the link: never skipped past. The entry records it
  (`extra["prune_waiting"]`, `PrunePart.waiting`; `chi schedule list`/`show`), the log says `prune_waiting` once per
  link, and every tick tries a waiting entry again (`prunes_due`). The deletes inside are plain (`delete_ids`).
- **The retention sweep** (`SessionRetention.apply`, `prune_orphan_dirs`) and **a leaving worker's delete**
  (`WorkerBoot#discard_left_session`, `#delete_left_scratch`, after the worker let go of its owner lock) take
  `exclusive([id], kind: :delete, deadline: 0)` around the removal: held → kept (the sweep's `kept`; the worker's
  `kept_session` / `scratch_kept`), and a later sweep takes it.
- The automatic deletes inside a transition (a continue's `discard_failed_link`) and `delete_resolved` /
  `remove_files` themselves take no transition lock: the callers above hold it, so a continue's undo never refuses
  itself.

### Arrivals declare their hold

Every `SessionInbox::WakePolicy::ROWS` row names `hold:` (a required keyword: a row without it doesn't load), pinned
by `spec/session_lifecycle/allowed_spec.rb`. The hold is taken once, in the three seats, by `SessionInbox::Hold.under`:
`Dispatch.deliver` (around the refusal check, the write and the wake), `Dispatch.wake` (around the wake) and
`SessionManager.deliver_turn` (`follow_guard`, around all of the delivery: the resume, the Bridge's wait and post, the
file and the second liveness check). Not in `resume_session` / `start_for_inbox`: a continue's undo reaches them on its
own token. A seat met by a held lock refuses, nothing written: a continue naming its new link (`Successor.in_flight`,
else a saved one) → `:continued` / 409 `link_continued` with `successor_id`; else `:busy` / 409 `transition_busy`
(`DeliverResult::BUSY`, `SessionTransition::Busy`'s words). chi send, an ask and the Exchange under them retry busy as
they follow a continue (`Exchange#relocate busy:`: the same link again, within `CONTINUING_WAIT`); a same-mode schedule
firing counts it a skip; the web composer, a delegate follow-up, a plugin's send and a participant's turn report it.

| Row / arrival | Hold | Why |
|---|---|---|
| send, push, peer, schedule, plugin, delegate, participant, agent, automatic | `:shared` | A turn or a push landing in a link being continued would be un-archived beside the new link or never read. |
| note (chi note, `send_note`, a broadcast, objectives) | `:none` | `NoteMove` moves a note written during a continue, the new link adopts one after (`NoteMove.adoption`), a failed continue gives them back; the new link's boot writes its own inside the continue's hold. |
| ring | `:none` | `ChildReports` rings once, no retry; `ChildMove` moves rings (`return_rings` gives them back); a continue's undo wakes for them on its own token. |
| fresh_verdict | `:none` | `VerifyFresh.forward` writes once, no retry; the verdict is for the card in the parent it names, continued or not; it starts no worker. |
| leave (respawn) | `:none` | After the worker's own release, spanning two processes (outside the lock); a refusal would drop a restart or queued input's start with no retry; a continue stops the worker first and the stop wins. |
| context add / remove (`Local#context_add`/`#context_remove`, chi web's URL add and detach) | shared | `ContextSources.changing`: a continue copies the session's own sources. Refused `ContextSources::Held` (423 `context_busy`). |
| context push, peer say, peer pair | shared | Phase 1 (`Local#moved_on`); the say's delivery seat holds again (shared beside shared). |
| invite (`Participants.invite`) | shared | A continue archives the link and ends its grants; refused `Grants::Invalid` with Busy's words. |
| revoke, peer unpair | none | Removals: a continue ends every grant at the archive, and the new link's pairing is the peer's to make (`Plugin::Peer#tell_moved`); refusing them would only make the owner retry. |
| `Local#answer` / `#dismiss`, cancel (cut), the attached TUI's `post_turn`, `Bridge#enqueue_turn` (the input fallback) | worker-side | Bridge-only: the live worker's own session (a continue's archive stops that worker and `archivable!` refuses it busy or queued). Over `--remote` the TUI's turn is chi web's turn route, `deliver_turn`'s seat. |
| The new link's boot (`ChildMove.adopt`, `NoteMove.adoption`, its objectives notes) | worker-side, none | Runs inside its creator's exclusive hold of the new link: a hold there would be refused until the continue ends. |

The raw `SessionInbox.write_*` sites are pinned with their hold in `spec/session_lifecycle_writers_spec.rb`. An older
chi's (0.190.x) worker or chi web takes no hold: its arrivals go in as before, and the tolerance paths stay
(`archivable!` refusing queued/busy, `NoteMove`, `ChildMove`'s movers).

## Open windows

These are documented race boundaries, not promises of an atomic lifecycle transition:

| Window | Code comment / current behavior | Pin |
|---|---|---|
| A ring wake decides to start, then a stop lands before resume. | `SpawnPart#wake_for_report` (`session_manager/spawn.rb`): `resume_session` can clear that stop and start; the check and resume are not one transaction. | Unit spec: stop in the start callback and assert the worker is started and the marker cleared. |
| Empty-session discard races a delivery (closed for turns and notes). | `WorkerBoot#discard_left_session` (`worker_boot.rb`) checks emptiness after releasing the worker lock and again under the deletion lock (`delete_session`'s `still:`): a send or note that went in before the lock keeps the session. One that reads the session during the lock is refused (`DeliverResult::DELETING`, a note as gone); one that read it before the lock and wrote after it reads it again after its write and takes its file back (`SessionInbox.withdraw`), so no turn or note is reported delivered and then removed. No new lock for that: the write-then-reread and the recheck under the existing deletion lock close it (the discard also tries the session's transition lock once, kind `delete`: a send or a transition holding it keeps the session). What remains: a ring or fresh verdict that read the session before the lock and wrote after it is not taken back: it goes with the directory, or stays for the next worker if the delete gives up; neither is reported to a person. | `run_session_loop_spec.rb`: a send at deletion-lock acquisition is refused; one just before the lock keeps the session. `delivery_spec.rb` / `note_delivery_spec.rb`: the lock (or the removal) between the check and the write, deterministic through the bridge / writer seam. |
| Stop reads an owner pid, then sends TERM. | `LifecyclePart#stop_session` (`session_manager/lifecycle.rb`): the pid can be reused between the owner read and `Process.kill`; protecting that requires a real pid-reuse scenario. | No unit pin: pid reuse/process signaling is not reliably representable without real processes. |
| Saved `status` is used as a lifecycle hint. | `LifecyclePart#restart_fallback_holds` and `RemovalPart#archive_refusal` (`session_manager/lifecycle.rb`, `session_manager/removal.rb`) use saved `running` status as a busy hint; status is not a lock or proof that a worker is alive. | Unit spec: pin fallback refusal from saved status without a live Bridge. |
| Stop/start ordering depends on wall-clock `at`. | `SpawnPart#claim_start` and `StartingMarker#claim` (`session_manager/spawn.rb`, `starting_marker.rb`) compare `starting.at` with `Session.stopped_at`; same-time starts are treated as before the stop. Clock adjustments across processes are not serialized. | Unit spec: pin the inclusive `at <= over_before` takeover boundary. |
| A delete stops a session's background tasks. | `RemovalPart#remove_session_files` (`session_manager/removal.rb`): with `running_tasks:` a stop, `RunningTasks.stop!` runs under the DELETING owner lock, after the `StartingMarker.fresh?` re-check and `still`, for up to ~4 s; meanwhile a send, a schedule or a resume is refused as deleting. With `REFUSE` the same seat lists the final file again and refuses a task started since the op's check (`worker_stopped` set when the op stopped the worker; `stopped_worker` names whose). `SessionChain::Delete` lists a whole batch (a link and its D7 delegates) once under the batch's locks, before any of it goes (`refuse_tasks!`), and its removals then skip the per-id re-check (`RunningTasks.after_check`), so no refusal comes after part of the batch went. A chain with `--stop-tasks` stops link by link inside each `locked(batch)`, serially: up to ~4.5 s per link, N links N times that, with that batch's locks held; a link refused part-way keeps its tasks running. A stop that outlives the join's deadline (`unconfirmed`) is reported as not stopped and may still finish after the files are gone (its thread goes on writing the record under the session's working directory, not the session dir). | `removal_spec.rb` (a worker's `OwnerLock.acquire` during the stop fails; the re-check refuses a new task), `session_chain/delete_spec.rb` (link by link, part-way; a task started after the up-front check keeps the link, its delegate and the chain whole). |
| An archive stops a session's background tasks without a lock. | `RemovalPart#archive_session`: the stop runs after the tree's workers were stopped and waited for (`stop_session(wait:)`), before the marker; a worker that outlives the wait records the stop itself from the `stop_requested_by` flag on disk (`record_exit_status` / `correct_finished_record`). A task started after the listing isn't stopped: archive already refuses `busy` up front. | `removal_spec.rb` (the stop sees no owner left). |
| A peer say, peer pair or context push during a continue (closed, N1). | Before: `Local#peer_say` checked `continued_as` (archived with a saved successor) and posted through `SessionInbox.deliver(:peer)`, a pinned row that skips Head's in-flight look and `follow_guard`; between the archive and the new link's save a say went into the old mailbox after `PeerContinue` had read it, and was never read (its line said "it reads this if you reopen it"). Now each takes `SessionTransition.shared` across the continued check and the write (`Local#moved_on`), never across the Bridge feature probe or the receipt wait: a continue holding the lock refuses it `:continued` naming its new link (in flight), else `:busy`. A say that holds the lock first goes in and the continue's carry takes it. | `session_access_local_spec.rb` "while a transition holds the session's lock" (say, pair, push refused naming the successor, Busy without one, mailbox and source unchanged); `session_continue_spec.rb` "refuses a peer say during the transition" (a real continue, the say made between its archive and the new link's save). |
| A send between a continue's exclusive hold and its archive marker (closed). | Before: `follow_guard` held only for a followed send to an archived link, so a send (any sender) to a link a continue held but had not archived yet went in, and the archive then refused the continue as busy or queued. Now every `:shared` row's delivery takes the hold in its seat: refused naming the new link (`link_continued`), else `transition_busy`. | `spec/session_inbox/hold_spec.rb` (each sender busy under a really held lock; a send to a link not archived yet refused naming the new link); the matrix's transitioning rows. |
| A frozen worker's Bridge post under a send's hold. | `deliver_turn` holds the session's lock shared across the Bridge's post (up to `BridgeClient::READ_TIMEOUT` 30 s for a worker that doesn't answer); a continue of that session waits `LOCK_WAIT` per try and is refused `transition_busy`. | No unit pin: a frozen worker's post is a timing case. |
| A delete or a send during a continue's recap. | `SessionContinue.continue_once` waits for the recap before it takes the transition lock: in that window a link delete and the delete preview no longer see a continue (`:continuing`): the delete may take the link's lock exclusively, and the continue's lock wait then ends busy ("being deleted"); a followed send to the link goes in. Under the lock the continue checks the link again: deleted → not found (its folder not brought back), continued by another → `Refused :continued`, a turn queued → the archive's refusal. | `session_continue_spec.rb` "the transition lock": the lock not held during the recap, a send then accepted, a link deleted or continued during the recap refused under the lock. |
| The new link's worker boots inside the continue's hold. | `SessionContinue.spawn_continuation` spawns it while the continue holds the new link's transition lock exclusively; its boot writes (`Worker#start` → `ChildMove.adopt`, `WorkerInbound` → `NoteMove.adoption`, its objectives notes through the note row, `:none`) take no transition hold. A hold added on that path would be refused until the continue ends (drop the new link's hold before the spawn instead). A send or a peer pair to the new link from outside is `transition_busy` until the continue lets go (milliseconds after the spawn): the senders retry. | `session_continue_spec.rb`: the boot's adoption on another thread makes no `SessionTransition` call, adopts the note, and a note through `NoteDelivery` goes in. |
| An unpair or a revoke during a continue. | `:none` (above): an unpair of the old link while the new worker's `tell_moved` re-pairs the peer may leave the peer paired with the new link. | No pin (declared). |
| Sends to a session a delete holds (open, by design). | `SessionChain::Delete` holds the transition locks from before its stop to the end: a send, a push, a peer say or a context change to the link, its previous link or a delegate that goes is refused `transition_busy` "being deleted" for the stop (up to the delete's wait, 10 s from the CLI), the task stop (about 4 s a link) and the removal; a chain delete holds every link's for the whole chain (N links × stop + tasks: minutes for a long chain with `--stop-tasks`). chi send and an ask retry within their wait; the web composer, a delegate, a plugin and a participant report it. Before, those sends went in and the delete stopped or removed them. | `session_chain/delete_spec.rb` "under the transition locks" (a send during the stop refused as being deleted, both locks the delete's). |
| A delete meets a send's or another change's hold (closed). | Before: `Delete.link`, `hold_all` took `SH\|NB`, so a continue was refused but another delete, a prune or the retention sweep could run beside it, and a send held nothing off. Now a user's delete waits up to `LOCK_WAIT` for the locks exclusively, then refuses (`continuing` / `transition_held`, the holder named); the prune, the sweep and a leaving worker's delete try once and keep the session. | `session_chain/delete_spec.rb` (a short shared hold waited out, a long one refused, a held delegate refuses), `session_retention_spec.rb`, `session_discardable_spec.rb` (held → kept). |
| A prune at a link it can't delete (closed: visible, never skipped). | Before: a link another enabled schedule protects (its anchor inside the chain, a stale head) was refused `prune_stopped` at every firing, after the link's delegates were already deleted, and the chain grew silently. Now the hold is checked before anything in the subtree goes and the prune stops there with a record (`prune_waiting`, list/show) and one log line; a held transition lock on the link or the next does the same, and every tick retries. Still open: the chain grows behind such a link until the other schedule is cancelled (re-linking the chain around it is held, D6). | `schedules_spec.rb` "a prune held at a link" (held link: kept with every later link, resumed next tick; next link held; the mid-chain schedule: one log, list/show lines, nothing deleted around it, gone after cancel). |
| Several methods write or remove the same marker. | The definitions/callers in `session.rb`, `starting_marker.rb`, `archive_store.rb`, `bridge.rb`, and `reminder_carry.rb` are the source of truth; these APIs have multiple call sites. | `spec/session_lifecycle_writers_spec.rb` pins the call-site allow-lists; it does not claim their operations are one transaction. |

## Adding a transition

1. Name the fact being changed and its on-disk format; add cross-version handling to `SessionStores` when applicable.
2. Put the write/removal in its owning module and add the call site, with its reason, to
   `spec/session_lifecycle_writers_spec.rb`.
3. Identify every decider that reads the fact and how it observes the change (lock probe, direct read, poll, or SSE).
4. If the change touches an open window above, extend its pin in the corresponding unit spec; don't hide a race with a
   sleep or a process-wide integration test.
5. A new arrival (a `WakePolicy` row, a delivery outside the seats) declares its hold: `hold: :shared` (the seat
   takes it) or `hold: :none` with its reason; a raw `SessionInbox.write_*` site is listed with its hold in
   `spec/session_lifecycle_writers_spec.rb`; one outside the inbox that changes what a transition carries takes
   `SessionTransition.shared` around its check and write (see "Arrivals declare their hold").
6. If the fact changes a state, update `SessionLifecycle::STATES`/`Reading.derive` and `CANONICAL`, then the
   `ALLOWED` cells (the literal ones by hand; the delivery ones follow `WakePolicy::ROWS`) and the matrix's rows; a
   decider that answers otherwise is a `KNOWN_DIFFERENCES` entry with its reason, never a silent cell change.
7. A new multi-step transition takes `SessionTransition.exclusive` with its own `kind` (add its words to
   `Busy::WORDS` so `Busy.held` names it), with a deadline, before any `owner.lock`; an automatic one tries once
   (`deadline: 0`) and leaves the session for later.
8. Recheck lock order, crash cleanup, and the existing file-format/compatibility specs before changing runtime behavior.
   A transition that must exclude a continue or an arrival takes the transition lock through `SessionTransition`,
   never its own flock of `continue.lock`.
