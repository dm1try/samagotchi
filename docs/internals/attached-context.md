# Attached context: the mechanism

For an agent changing the layer. What a user sees and configures (the commands, the note wording, the wake rules,
the judge's thresholds, the log and the report) is in [../context.md](../context.md); this page is how the code
gets a source's text into the prompt, and what each class owns. Not to be confused with `ContextStatus` /
`ContextUsage` / `ContextWindow` ([context-telemetry.md](context-telemetry.md): token counts) or the LLM context
strategies ([llm-context-forget.md](llm-context-forget.md)).

## From a source to the prompt

```
source (command | push | URL provider)          ContextSources: <name>.json + <name>.snapshot.json
   │ ContextPoller (worker thread) runs a command source via ContextFetch;
   │ chi context push / refresh write the snapshot from another process
   ▼
snapshot (text, revision, serial, summary, wake_serial, hint)
   │ Worker#pass, between turns: WorkerInbound#absorb_context
   ▼
ContextAbsorber#pending → Batch of Deliveries (one note per source that is new / changed / failing / gone)
   │ Engine#add_context_note: a tail system message (kind "note", ContextNote), announced as :context_added
   │ session saved, then ContextAbsorber#commit writes subscriptions.json
   ▼
the next request: the note sits after the history; the model reads the text with the context_read tool
```

Three rules hold the shape:

- **Never the stable prefix.** A note is a tail system message, appended between turns (never mid-turn, never
  before a session's first turn: `conversation_started?`, or `before_turn:` when a prompt is about to run). The
  system prompt carries only the standing line that explains `[CONTEXT NOTE …]`. History stays append-only
  ([prompt-caching.md](prompt-caching.md)). Only the pointer (name, why, hint, summary) is in the note; the text is
  read on demand by `Tools::ContextRead`, which reads snapshots only and never runs a command.
- **Deliver at least once, record after save.** `absorb_context` adds the notes, saves the session, and only then
  `commit`s the subscriptions. A crash in between re-delivers, and `Engine#add_context_note` skips a `note_id` the
  conversation already holds. Ids are deterministic: `ctx-<name>-<serial>-<revision[0,12]>` (the serial makes A, B, A
  three notes), `ctx-<name>-error-<error_since digits>`, `ctx-<name>-detached-<seen[0,12]>`.
- **Polling is not activity.** The poller and the absorb never hold a worker up (`WorkerIdleExit`).

## ContextSources

The store (`context_sources.rb`), one root `<state dir>/context/`, apart from the session folders; its header
comment is the file map and [../context.md](../context.md#storage) lists it for users.

- **Records** (`Data`/value objects): `Source` (definition; `cmd` nil = pushed; `movable` nil derives from
  `push?`), `Snapshot` (last good text, `revision` = SHA-256 of the text, `serial` counting revisions, `error` and
  `error_since`, `wake_serial` = the newest revision that asked to wake, `fetched_at` last success, `checked_at` last
  try), `Subscription` (what one session has had: `seen`/`seen_serial`, `read`, `error_seen`, `wakes_at`),
  `Candidate`, `Left`, `Moved`/`Stayed`.
- **Locations.** A `Location` is a folder of sources: a project's (`projects/<project_key>/`, shared by the
  project's workers) or a session's (`sessions/<id>/`, which also holds `subscriptions.json`, the `muted/` and
  `declined/` markers, `candidates/`, `left.json`). `ContextSources.attached(session_id, project_root:)` is what a
  session sees: its own, then the project's it doesn't shadow. Names are `NAME_RE`; `subscriptions` and `left` are
  reserved (`RESERVED_NAMES`) because their files share the folder.
- **Writes are file replaces** (`AtomicFile`). `Location#locked(name)` takes `<name>.lock`, the lock a fetch holds
  for its whole command; `record_text` and `record_error` run under it, and `remove` leaves the lock file so a fetch
  still running finds its source gone (`ContextFetch` then writes nothing). Removing a *session* source leaves a
  `declined/<name>` marker (hint inside), which is what stops an auto-attach from bringing it back.
- **The output contract** is `ContextSources.parse_output` (JSON object with a string `text` is
  `{text, summary, wake, hint}`; anything else is all text; empty or over `TEXT_MAX_BYTES` is `Invalid`), the same for
  a command's stdout and a push. `ContextProviders` resolves a URL to a command source from an installed bundle's
  manifest `context_providers:` (read from its provenance, so the CLI and chi web resolve without loading plugins);
  `{url}` is filled at attach, `{bundle_dir}` and `{ruby}` when the command runs.
- **Protected.** The root is a `ProtectedPaths` entry: the file tools cannot write it, because a source's command
  runs later outside the guardrails gate with the worker's environment ([../context.md](../context.md#safety)).

## ContextPoller and ContextFetch

`ContextPoller` is one thread in a worker (`Worker` starts it, `on_change: -> { @waker.wake }`). Every
`TICK_SECONDS` (5) it walks `ContextSources.attached`, skips pushed and muted sources, and runs each command source
whose last try (`checked_at`, so a failing source isn't re-run every tick) is older than its interval (`--every`,
else `context.every_seconds`, floored at `MIN_EVERY_SECONDS` 30). Its first pass uses the floor as the interval, so a
woken worker's first absorb says what changed while it was away. It calls `on_change` only for `:new` and `:error`.

`ContextFetch.fetch` runs one source: `sh -c` in its own process group (a timeout, the output cap or the caller's
cancel kills the group), cwd the session's folder (a project source: the project root, `project_cwd`), stdin closed,
`SAMAGOTCHI_CONTEXT_NAME` and `SAMAGOTCHI_CONTEXT_PREVIOUS` in the env. A non-blocking `flock` on `<name>.lock` is
the arbiter between workers and the CLI: the loser gets `:busy`, and `fresh_within` is checked again under the lock,
so a project source shared by several workers is fetched once per interval. The `Outcome` status says what happened
(`:new :same :error :busy :fresh :cancelled :gone`); a cancelled fetch records nothing (a leaving worker isn't the
source failing). `chi context refresh` and the candidates' first fetch use the same entry.

A pushed source has no poller. `chi context push` writes the snapshot from its own process; the worker finds it
through `ContextAbsorber#store_signature` (names and mtimes of the files in the two folders, `subscriptions.json`
left out so the worker's own write is not a change), compared on each pass.

## ContextAbsorber

Pure decision, no I/O of its own beyond the store. `pending` returns `nil` when the signature hasn't moved since the
last `commit`, else a `Batch` of `Delivery` values (`name`, `note`, `subscription`, `wake_note`, `peer`, `agreed`):

| State of source vs the session's `Subscription` | Delivery |
|---|---|
| has text, `seen` nil | *Attached* note |
| `seen != revision` | *Updated* note, `changes = serial - seen_serial` |
| error newer than `error_seen` | *Couldn't refresh*, once per run of failures |
| subscription with no source left | *Detached* if the session was told of it, else dropped quietly |
| no text yet | nothing |

A muted source is skipped. Notes name the source as third-party text; the exact wording lives in the class constants
(`WAKE_LAST_LINE`, `PEER_WAKE_LINE`, `PEER_AGREED_LINE` were tuned in spikes: change one only with an eval).

**Wake notes.** A delivery also carries a `wake_note` (the same note with the wake last line) when its source asked
(`snapshot.wake_serial > sub.seen_serial`, so an earlier asking revision still counts) or, for a first text, only a
session's own pushed source (`first_text_wakes?`). Whether it *runs* is the worker's, not the absorber's:
`WorkerInbound#context_wake_for` applies `context.wake`, `WorkerWakes#context_open?` (no continue offer, not paused,
under `session.max_wakes`, past the start grace), and the per-source `CONTEXT_WAKE_WINDOW` (600 s, from
`Subscription#wakes_at`); `Worker#pass` calls it only with nothing queued and no exit requested. A failed or
stopped wake turn is rolled back (`unmark_wake`) to a plain note.

**Peers.** `PeerSources` (the peer bundles' in-process declaration, `chi.peer_source`) marks a pushed session source
as a peer's answers; `peer_label` then needs `context.peer_turns` > 0. A peer delivery has no 10-minute window; its
budget is `WorkerWakes#peer_open?` (reset only by typed input), and an answer whose summary ends in `VERDICT OK`
(`peer_agrees?`) wakes once with the closing line, counted toward `session.max_wakes` only.

## Candidates

`ContextCandidates` holds a session's proposed sources (`Candidate`, from `ctx.context.propose`, stored under
`candidates/<name>.json` and written once). **Status is derived, never stored**: *attached* while a source of its
name (or whose hint is its URL) is attached, *declined* while the declined marker names it, else *proposed*.

- **Mention.** `mention_in` / `pattern_for` implement the user-facing rules (whole tokens, `#N` ≥ 10 or after
  "PR", branch names ≥ 6 chars with `/ - _`, exact URLs, fenced code blanked). Only `OwnerPrompt` texts count
  (`owner_texts`), so a participant's message, a steer, a note or a reminder never attaches anything; a review
  session skips all of it.
- **Where it runs.** `before_turn` (from `Worker#run_prompt` before the absorb, and the REPL's turn start): attach
  each proposed candidate the owner's prompts so far mention (`attach` writes a session `Source` through
  `source_for`: a URL resolves through `ContextProviders`, else the candidate's own `cmd`), then `first_fetch` them
  together within `FIRST_FETCH_SECONDS` (10) so the note lands in this turn; cut short, the fetch records nothing and
  the poller tries soon. `after_propose` does the same for a late proposal. The REPL has no absorber running, so
  `deliver_notes` runs one.
- Forks and continues take no candidates.

## ContextJudge and ContextCandidateChoice

`ContextJudge` is System 1's "is this session's work about the candidate?" ([../guardrails.md](../guardrails.md#system-1-experimental)).
It builds a small neutral state per ask (`state(job)`: the candidate's title and describe, `conversation` = the first
substantive owner prompt and the latest, each bounded at `PROMPT_MAX`, and for a delegate child the parent's attached
titles), two constant `noul` questions (`about`, `task`: constant so the host's prefix cache holds and nothing a
plugin wrote is read as instructions), and `ask` writes a `judged` line. Never the branch, the checkout or the
source's why. `task_p < TASK_MIN` (0.5) leaves the candidate unjudged; `due?` decides asks from the log's `judged`
lines (never twice at one owner-prompt count; one re-ask after `reask_after_turns`; then done). No answer writes
nothing, so the next owner prompt asks again.

The driver is the Engine, not the judge: `Engine#start_context_judge` (an owner turn's start; skipped for participants,
review sessions and a Continue) and `judge_late_candidates` (a proposal after the prompts) call `context_judge_pass`.
It first logs status changes (`ContextCandidatesLog.look`), returns at `mode: off`, builds the due `Job`s, and hands
them to `SideJudgments` (`:context` kind: one thread, one batch per session at a time). On the model's own local
server (`system_one_shares_local_host?`) the pass is held in `@context_judge_after_turn` and started after the turn
(before the prompt warm-up, which waits for it); any other host is asked at once.

`ContextCandidateChoice.after_judged` acts on `fields["would"]` in `on` mode only: *attach* → `judge_attach` (a
session source with `JUDGE_WHY`, no probability in the model-visible why), *offer* → one card (`offer_card`, buttons
`/context attach NAME` and `/context decline NAME`, guarded by a `carded` log line). It re-checks that the candidate
is still proposed, since the user may have chosen while it was asked. Cards are shown through the Engine's
`context_choice` lambda, which holds them while a turn runs (`@context_cards_after_turn`). `choose` is the
`/context attach|decline` command's body (`SessionCommands`), shared by the card's buttons; it refuses in a review
session. An attach only writes the session folder: its note comes with the next between-turn delivery, never into a
running turn.

`ContextCandidatesLog` is `context_candidates.jsonl` beside the sessions folder (a `SideJudgments.log`: 0600, one
line under a lock, the oldest half dropped past 5 MB; written in every mode). `statuses` replays the lines;
`look` appends `by: "user"` lines for changes it sees (the user's own `chi context add`, a chip's ×); the kinds and the
report are in [../context.md](../context.md#the-log-and-the-report). `ContextReportCommand` is its only reader besides
`due?` and `carded?`.

## ContextMove and left.json

Movable context is the only code path that copies sources between sessions. `ContextMove.call` runs from
`SessionManager.spawn_session`'s `before_spawn` (a continue: `SessionContinue`; a plugin fork:
`Plugin::Sessions#fork` with `seed:` = the fork's messages), after the new session and its first note are saved and
**before its worker starts**, so the first absorb sees the sources. It calls `ContextSources.move`, then writes a
second note into the new session (`NOTE_SOURCE` "attached context", named by time so it sorts after the first). Best
effort: a failure is logged (`context_move_failed`) and the session starts without.

`ContextSources.move(from:, to:, mode:, seed:)` copies, by plain read (never `Location#locked`: a fetch holds it for
its whole command), each source for which `Source#movable?` is true: the source file, its snapshot, and a
`Subscription`; plus every `declined/` and `muted/` marker (the user's choices). Never `candidates/`, lock files, or a
source the new session already has. The subscription's content is what makes the first note right: a continue's says
nothing was seen (so the *Attached* note comes) at the snapshot's serial (so an old wake doesn't wake); a fork's is
what its seed last had, found from the newest note about the source (`seed_note`, via the `note_id` shape above), so
a source that changed since gets an *Updated* note.

`Moved` carries `moved` names and `stayed` (`Stayed`: name, `why` `:pushed` or `:not_movable`). Its `note_text` is the
second note; `words` is the few words `chi send --new --continues` prints; `to_h` / `from_h` are chi web's
`moved_context` answer (an older chi web sends none: `from_h(nil)` is nil).

**left.json.** For a *continue* the stayed sources are also written to the new link's `sessions/<id>/left.json`
(`Left`: `name`, `hint`, `from`; the hint is the snapshot's, since a pushed source's hint is where a peer's re-pair
pushes). `ctx.context.left_behind` reads it (`Plugin::AttachedContext#left_behind`) and `ctx.continues` names the
previous link. `Plugin::Peer#pair_again` uses both: from its quiet init task it posts one `moved` message to the
inbox left behind and records a marker under the bundle's `sessions/<id>/`, so it runs once. `Left#peer` /
`PEER_NAME` exist only to word the second note (a peer's inbox and outbox are one group: "chi asks Claude to pair
again" vs "Codex pairs again when it next answers"); `PeerSources` decides what a peer is. A fork writes no
`left.json`.

The refusal side: a push into a session that has been continued is refused with the next link's id
(`context_continued`, chi web 410, `chi context push` exit 1), from `SessionAccess` (`session_access.rb`) and chi web's push route (`web/session_access_routes.rb`).

## Gates and config

| Where | Gate |
|---|---|
| Absorb at all | the conversation has started (`conversation_started?`), or `before_turn: true`; the session isn't stopped on disk |
| A wake turn | `context.wake`; `WorkerWakes#context_open?`; `CONTEXT_WAKE_WINDOW`; nothing queued and no exit requested; peer: `context.peer_turns`, `peer_open?` |
| Mention attach | `OwnerPrompt.turn?` (owner author, not a review session) |
| Judge | `context.candidates.mode` `audit`/`on` (default `off`); a System 1 client configured; not a participant's turn, review session, scratch session or Continue |
| Command source defined by the agent | `chi-context-cmd` guardrails rule asks, always; a parent agent can't approve it for a child |
| Writes to the store | `ProtectedPaths` denies the file tools |

Keys, all in [../configuration.md](../configuration.md): `context.every_seconds`, `context.wake`,
`context.peer_turns`, `session.max_wakes`, `context.candidates.{mode,threshold,offer_threshold,reask_after_turns}`.

## Data files

| File | Written by | Read by |
|---|---|---|
| `context/{projects/<key>,sessions/<id>}/<name>.json` | `chi context add`, a provider, a plugin (`ctx.context.attach`), `ContextCandidates.attach`, `ContextMove` | poller, absorber, `context_read`, chi web |
| `<name>.snapshot.json` | `ContextFetch`, `chi context push`, `ContextMove` | absorber, `context_read`, chi web chips |
| `<name>.lock` | `ContextFetch` / `Location#locked` | same |
| `sessions/<id>/subscriptions.json` | the worker (`commit`, `context_read`) only | absorber, chi web (unread dot) |
| `sessions/<id>/{muted,declined}/<name>` | `chi context mute`, a removal, `ContextMove` | poller, absorber, candidates |
| `sessions/<id>/candidates/<name>.json` | `ctx.context.propose` | candidates, judge, `/context` |
| `sessions/<id>/left.json` | `ContextMove` (continue) | `ctx.context.left_behind` |
| `context_candidates.jsonl` (beside `sessions/`) | `ContextCandidatesLog` | judge (`due?`), choice (`carded?`), `chi context report` |

Specs: `spec/context_*_spec.rb`; a store under test uses an isolated `XDG_STATE_HOME`.
