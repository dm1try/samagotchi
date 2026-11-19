# Session lifecycle

There is no persisted lifecycle enum. A state is derived from the session file, sidecar files, locks, and the worker
link: `SessionLifecycle.read(id)` (`session_lifecycle.rb`) reads them once (`WorkerPresence` with its link looked at,
never unlinked, and `ContinueIntent.in_flight`) and names the first of its 15 states whose facts hold (Derived states).
The same session can satisfy more than one fact (archived while its worker is leaving); the precedence picks one. One
decider reads `SessionLifecycle`: `restart_session`'s precheck (Allowed operations). The others still read their own
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
| `continue.lock` and `continue.json` | `SessionContinue#with_lock` takes the exclusive lock for a continue; `ContinueIntent#hold` takes a nonblocking shared lock for readers that must exclude a continue. `ContinueIntent#write` records the successor before archive and updates the archived ids after; failed-continue cleanup removes the intent. The lock file remains until session-directory deletion. | Followed sends, schedules, chain deletion, and `ContinueIntent.in_flight` inspect the lock and intent. flock coordinates the live transition; readers reload the JSON. An intent without a held lock is a crashed continue, not an active one. |
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
| `deleting` | `owner.lock` held with kind `deleting` while the session's files go (`WorkerLink` reads it as `Starting`). Every delivery is refused (`WakePolicy`'s `:deleting`); restart refuses it (`deleting`). |
| `stopping` | A worker holds the lock and the `stopped` marker exists, whatever its link. |
| `skew` | A worker holds the lock and its sidecar speaks a newer protocol (`WorkerLink::Skew`). |
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
schedule's link resolution reads it), a stale sidecar (`WorkerLink::Stale`: a crashed worker's leftover, reads as
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
  automatic) are generated at load from `SessionInbox::WakePolicy::ROWS`, unchanged: each row's `decide` on
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
- **Literal columns** (`LITERAL`): resume (`resume_session`), restart (`restart_session`: `stop_marked` in every
  state with the stop marked: stopping, stopped, stopped_starting), stop (`stop_session`),
  archive (`archivable!`), delete (`release_for_delete!`, without a stop), sched_chain and sched_same
  (`Schedules#busy_reason`; `worker_busy` is "its worker is starting or leaving") and attach
  (`TerminalUI::LocalLink#live_worker`: `gone_stopped`, `gone_worker_newer`). They assume neutral op-local facts: not
  scratch, saved status idle, no `input/`, no question or offer, not SIGSTOPped, features restart and activity, an idle
  worker with no streams. Absent's delete and schedule cells are unreachable (a gone session is refused first).

Link resolution (`SessionInbox::Head.resolve`, `Schedules#target_of`) stays outside: the cells are the link's own.

`restart_session` is the first decider migrated to the table: its lifecycle precheck is `SessionLifecycle.read` (the
owner read through `session_owner`) and `ALLOWED[:restart]`: `owned_by_tui` raises `OwnedByTUI`, a refusal cell
raises `RestartRefused` with it as the reason (`starting`, `not_running`, `stop_marked`, `deleting`), `fallback` goes to
`restart_fallback` (skew, a stuck start) and `go` asks the live worker. Its op-local checks stay where they were: the
SIGSTOP check (`:stopped`, the worker's pid: a different condition with its own words, before the table's refusal),
the worker's `restart` feature, the Bridge's reply and the fallback's holds. The matrix still drives it, so its
column is pinned against the precheck and the op-local paths together. The other deciders don't read `ALLOWED` yet.

## Characterization matrix

`spec/session_lifecycle/matrix_spec.rb` (rows, files and drivers in `spec/support/lifecycle_matrix.rb`) writes every
combination as real files: owner/link pairs (none, stale sidecar, tui, tui with a stale sidecar, deleting, a worker
Live, Starting, stuck, Leaving, Skew, an owner of unknown kind) × stop × starting × archived, one absent session, a
continue in flight on each archived no-owner row, and a start marked after the stop on each no-owner row with both
(the order is a row fact: `StartingMarker.claim` takes over only a start at or before `stopped_at`). The owner lock's
holder, `ContinueIntent.in_flight`, `Process.spawn`, TERM/CONT, the Bridge and the restart fallback are stubbed; no
process starts. Each row checks that `SessionLifecycle.read` names the state its facts derive, then drives every
operation (one driver each, every private reach in that one file) and projects its answer into a cell. A row the
code can't make (a one-turn run's lock with a stop) is marked `reachable: false` with its note and still asserted.

Every answer must equal `ALLOWED[op][state]` (for the session hub, `SHOWN[state]`: `Web::SessionSummary.build`'s
status and bridge_up, its `SessionRow`'s live), or be named by exactly one `KNOWN_DIFFERENCES` entry (op, a `when`
over the row, a plain reason); an entry that names no mismatch fails as stale. The entries are the findings for the
owner, not fixed: stop-first schedule and attach checks under a one-turn run's, a deleter's or an unknown owner's lock;
chain mode's starting check before any one-turn-run check; a start marked after the stop holding a resume off;
`wake_for_report` reporting a worker's `:live` as `:owned`; the hub's bridge_up, live and status overlay. (Restart
never reading the stop and `busy_reason`'s live branch falling through to the starting check were fixed: their
entries went stale and were removed.) The delivery columns are
generated from `WakePolicy::ROWS`, so for deliveries the matrix proves the states are drawn right (decide is a function
of the state), not what WakePolicy does; the literal columns and `SHOWN` are goldens.

## Locks and crash repair

`owner.lock` is the single-owner boundary for an Engine; its flock is released by process death. A starting claim uses
an atomic link rather than a long-held lock. A continue holds its exclusive `continue.lock` across the transition;
shared holds protect followed sends and chain operations. When chain deletion nests locks, it takes the continue hold
before the `owner.lock` deletion locks. Inside a worker, the lock order is Engine event lock, then
`WorkerExitClaim`'s mutex. Session saves serialize through their per-session save lock. These locks protect separate
facts; there is no global lifecycle lock or atomic snapshot across all markers.

A worker that crashes exits 1 and is not respawned just because input is queued. A later delivery may start a new
worker; under its owner lock, startup settles a turn checkpoint and stale running status rather than replaying the
dead turn. Interrupted continue intents are repaired separately by session listing/the web hub or before another
continue (`SessionContinue.repair_interrupted`), not by worker startup.

## Open windows

These are documented race boundaries, not promises of an atomic lifecycle transition:

| Window | Code comment / current behavior | Pin |
|---|---|---|
| A ring wake decides to start, then a stop lands before resume. | `SpawnPart#wake_for_report` (`session_manager/spawn.rb`): `resume_session` can clear that stop and start; the check and resume are not one transaction. | Unit spec: stop in the start callback and assert the worker is started and the marker cleared. |
| Empty-session discard races a delivery (closed for turns and notes). | `WorkerBoot#discard_left_session` (`worker_boot.rb`) checks emptiness after releasing the worker lock and again under the deletion lock (`delete_session`'s `still:`): a send or note that went in before the lock keeps the session. One that reads the session during the lock is refused (`DeliverResult::DELETING`, a note as gone); one that read it before the lock and wrote after it reads it again after its write and takes its file back (`SessionInbox.withdraw`), so no turn or note is reported delivered and then removed. No new lock: the write-then-reread and the recheck under the existing deletion lock close it. What remains: a ring or fresh verdict that read the session before the lock and wrote after it is not taken back: it goes with the directory, or stays for the next worker if the delete gives up; neither is reported to a person. | `run_session_loop_spec.rb`: a send at deletion-lock acquisition is refused; one just before the lock keeps the session. `delivery_spec.rb` / `note_delivery_spec.rb`: the lock (or the removal) between the check and the write, deterministic through the bridge / writer seam. |
| Stop reads an owner pid, then sends TERM. | `LifecyclePart#stop_session` (`session_manager/lifecycle.rb`): the pid can be reused between the owner read and `Process.kill`; protecting that requires a real pid-reuse scenario. | No unit pin: pid reuse/process signaling is not reliably representable without real processes. |
| Saved `status` is used as a lifecycle hint. | `LifecyclePart#restart_fallback_holds` and `RemovalPart#archive_refusal` (`session_manager/lifecycle.rb`, `session_manager/removal.rb`) use saved `running` status as a busy hint; status is not a lock or proof that a worker is alive. | Unit spec: pin fallback refusal from saved status without a live Bridge. |
| Stop/start ordering depends on wall-clock `at`. | `SpawnPart#claim_start` and `StartingMarker#claim` (`session_manager/spawn.rb`, `starting_marker.rb`) compare `starting.at` with `Session.stopped_at`; same-time starts are treated as before the stop. Clock adjustments across processes are not serialized. | Unit spec: pin the inclusive `at <= over_before` takeover boundary. |
| Several methods write or remove the same marker. | The definitions/callers in `session.rb`, `starting_marker.rb`, `archive_store.rb`, `bridge.rb`, and `reminder_carry.rb` are the source of truth; these APIs have multiple call sites. | `spec/session_lifecycle_writers_spec.rb` pins the call-site allow-lists; it does not claim their operations are one transaction. |

## Adding a transition

1. Name the fact being changed and its on-disk format; add cross-version handling to `SessionStores` when applicable.
2. Put the write/removal in its owning module and add the call site, with its reason, to
   `spec/session_lifecycle_writers_spec.rb`.
3. Identify every decider that reads the fact and how it observes the change (lock probe, direct read, poll, or SSE).
4. If the change touches an open window above, extend its pin in the corresponding unit spec; don't hide a race with a
   sleep or a process-wide integration test.
5. If the fact changes a state, update `SessionLifecycle::STATES`/`Reading.derive` and `CANONICAL`, then the
   `ALLOWED` cells (the literal ones by hand; the delivery ones follow `WakePolicy::ROWS`) and the matrix's rows; a
   decider that answers otherwise is a `KNOWN_DIFFERENCES` entry with its reason, never a silent cell change.
6. Recheck lock order, crash cleanup, and the existing file-format/compatibility specs before changing runtime behavior.
