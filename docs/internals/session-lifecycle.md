# Session lifecycle

There is no persisted lifecycle enum. A decision derives a state from the session file, sidecar files, locks, and the
worker link it observes; the same session can satisfy more than one label (for example, archived while its worker is
leaving). The session file layout and user-facing session behavior are in [Sessions](../sessions.md); the Worker and
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

These are reader/decision labels, not stored values:

| Label | Facts that produce it |
|---|---|
| absent | No session file; a leftover sidecar directory may still exist. |
| starting | A fresh `starting` marker names a live starter, usually before a worker has the owner lock. |
| booting | A worker holds `owner.lock`, but has not published its matching Bridge sidecar (`WorkerLink::Starting`). |
| live | A worker holds `owner.lock` and its sidecar matches the owner (`WorkerLink::Live`). |
| leaving | The worker's Bridge is closed but its owner lock remains held; `leaving_at` bounds its last work. |
| idle with no worker | The session exists, has no owner and no fresh start, and its saved turn status is idle. |
| stopped | The `stopped` marker exists; a worker may still be shutting down. |
| archived | `archived` has `archived_at`; this can overlap a worker's shutdown. |
| continuing | `continue.json` names a successor and `continue.lock` is held. |
| deleting | `owner.lock` is held with kind `deleting` while session files are removed. |
| one-shot owned | `owner.lock` is held with kind `tui`; this is an in-process one-turn host, not a worker. |
| crashed leftovers | No owner lock remains, but a stale Bridge sidecar, checkpoint, `.processing` file, or unlocked continue intent can remain. |

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
| Empty-session discard races a send. | `WorkerBoot#discard_left_session` (`worker_boot.rb`): it rechecks emptiness after releasing the worker lock, then deletes. A send during the deletion lock can be accepted to `input/` and then removed with the directory; one after removal fails because the session is gone. | Unit spec: deliver at deletion-lock acquisition and pin the accepted-but-removed input. |
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
5. Recheck lock order, crash cleanup, and the existing file-format/compatibility specs before changing runtime behavior.
