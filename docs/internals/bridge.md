# The Bridge

The Bridge (`lib/samagotchi/bridge.rb`, `Samagotchi::Bridge`) is a session worker's only live client transport: a
localhost HTTP server in the worker's process, next to the `Engine` it reads and drives. chi web and the attached
terminal are its clients; no browser reaches it. [architecture.md](../architecture.md) places it among the layers;
this page is the surface: what it keeps, how a client joins and catches up, and every route.

Bridge Engine calls are listed with their reasons in `Bridge::ENGINE_CALLS`; add each new Engine call there.

## What a Bridge keeps

`Bridge#start` binds a port (OS-assigned, `127.0.0.1`), then subscribes four persistent observers to the Engine
(`Engine#subscribe`, the thread-safe fan-out whose events all carry a monotonic `event_seq`). Each is cheap and
rescues its own errors: an observer must never break the running turn.

| Piece | File (`bridge/`) | Holds |
|-------|------------------|-------|
| `RingBuffer` | `ring_buffer.rb` | The last `ring_capacity` (256) raw events by `event_seq`, in memory, for a reconnect's replay. The capture observer feeds it. |
| `TurnAccumulator` | `turn_accumulator.rb` | The turn in progress, folded from events. |
| `CardStore` | `card_store.rb` | The last cards and notices, saved in `cards.json`, each anchored to its turn. |
| `TurnDrawings` | `turn_drawings.rb` | Each finished turn as live drew it (`turn_drawings.jsonl`): written by the accumulator's `on_turn_end` hook, read by chi web's show. |
| `CardPlaces` | `card_places.rb` | Pure: where `CardStore`'s entries sit in the messages the page draws (`turns_since`, and the `opening_id` stamp). |
| `PendingCard` | `pending_card.rb` | `pending_card.json` `{id:, bundle:}`: the running turn's open card with actions (check-in's Nudge), written and removed with that card, so chi web's hub, which watches files and not workers, can notify. |

Per connection there is an `SSEWriter` (with a `BoundedQueue`); `ClientEvent` and `EventId` are pure helpers. The
Bridge also owns its **epoch** (`SecureRandom.hex(4)`: `event_seq` starts over in each worker, so the epoch says
whose seq a cursor is) and its **secret**; both are published in `bridge.json` (`WorkerSidecar`) with the port.

## TurnAccumulator

A joining UI must draw a turn already half done, and the ring may have dropped its early events. The accumulator
folds the event log into one hash, `current_turn`: the prompt, `turn_id`, origin, `at`, and ordered `parts`
(generation, thinking, text, tool, input, steer, reminder, notice, card), plus `pending_question`. A tool part keeps its
row fields (`ToolRowFields`), its `tool_id`, its output cut head-and-tail at `ToolOutputCut::WEB_PREVIEW_CHARS` so a
joined row is the row a reload draws, `elapsed_ms` while it runs (the accumulator times running calls itself, `clock:`)
and, once finished, the event's `duration_ms` (its own clock only for an older worker's event that has none). A
`notice` part holds the event of a row that is neither text nor a tool call (`TurnNotice::FIELDS`: a hook's notice,
the "asking again" row, a steer's cut, a ✂ row, a question and its answer), so a join replays it through the handler
that drew it live. A `card` part is a card the turn showed in its step (`in_turn`), its latest version in its first
one's place; `replay_events` and `join_events` skip it (a running turn's join takes its cards from CardStore), and
only `replay_events(turn, cards: true)` (a finished turn's drawing) replays it as its `card` event.

At the terminal event, before clearing, the accumulator hands a deep copy of the turn and the end event to its
`on_turn_end:` hook (the Bridge's `TurnDrawings#append`). The hook runs under the accumulator's mutex and the
observer lock, so it never calls back in; an error is logged (`turn_end_hook_failed`) and the fold goes on.

The turn is cleared on its terminal event (`Events::TURN_END`), the same event that brings its messages into the
session, so a snapshot shows a turn in exactly one of the two places. Beside the turn it keeps what a snapshot also
needs and the messages lag: `queued` turns (`:turn_enqueued` until started, merged or dequeued), `queued_commands`,
the idle `recap` (until a turn starts), a pending `continue_offer`, and the running turn's `working_set`.
Between turns it also carries `idle_working_set`, built as the worker's next-turn announcement would be (including
pending `adds`); it is absent while a turn runs or if the build fails.

Three other users: `replay_events(turn)` turns a `current_turn` back into the live events that would have drawn it
(the attached TUI's join); `join_events` is the page's unfold of the same turn plus the queue behind it (its
`turn_started` also carries `at`, `cut_after` and every author key, then a `turn_enqueued` per queued prompt and a
`command_queued` per waiting command), which chi web's `GET /api/sessions/:id` sends as `replay` from the worker's
snapshot (`from_wire` symbolizes it), so any worker's snapshot gives the page the same events
(`spec/shared/turn_snapshot.json` pins it); `messages_of` gives a
plugin's `ctx.messages` the turn so far (`Engine#running_turn_messages`); `participant_turn?` tells `POST /turn` that
a participant's review turn runs, so the owner's input queues behind it.

## TurnDrawings

A reload or a reconnect draws every finished turn from a drawing, never rebuilt into rows from its saved messages:
the accumulator's final fold of the turn (its parts in order, in-turn cards included) and the end event's display
keys (`TurnDrawings::END_KEYS`), one JSON line per turn in `<session dir>/turn_drawings.jsonl`
(`{v: 1, turn_id, kind, from, to, from_digest, to_digest, drawing, end}`, `TurnDrawings::Line`). A turn live wrote
no line for (an older worker's, one from before drawings, a dropped one) gets one made from its messages at read
(`TurnDrawings::Synth`, below), so the page and the TUI have one way to draw a turn.

- **The range comes from the Engine.** The end event's `kept_from`/`kept_to` (`Engine#end_turn`) name the turn's own
  messages, `kept[from...to]`. No range (an older worker, a turn that kept nothing) or an empty one writes no line:
  the turn is made from its messages at read.
- **Validity.** A line holds while the messages reach `to` and `messages[from]` and `messages[to - 1]` digest as the
  line says (`TurnDrawings.digest`: role, content and time, one canonical form for the live symbol-keyed messages
  and the saved, scrubbed ones). A rollback, a rolled-back failure or a prompt handed back drops it. Of overlapping
  valid lines (a rollback, then a re-run that said the same) and of one turn id's lines, the newest wins
  (`TurnDrawings.valid`).
- **Writing.** The accumulator calls `TurnDrawings#append` at the end event, inside the observer delivery, so the
  line is on disk before a stream writer (subscribed later) gets the end frame. That departs from SessionObserver's
  "enqueue-only" note, as CardStore's save does: one append per turn end. It writes `"\n"` first when the file's last
  byte isn't one (a torn line from a crash), then the line in one write; a failure is logged (`turn_drawing_failed`).
  A part's output is the accumulator's cut (`WEB_PREVIEW_CHARS`); a diff is the one the saved `tool_diffs` have
  (`TextDiff`'s cut); images are refs. The writer is the session's owner under `OwnerLock`: its worker's Bridge, or a
  `-p X --non-interactive` one-shot, whose `TerminalUI#run_one_shot_turn` tees its events to an accumulator with the
  same hook. A fork's child starts with its parent's lines that hold against its seed (`TurnDrawings.carry`, in
  `Plugin::Sessions#fork`'s `before_spawn`, before the child's worker exists: same indices, same digests; a range
  whose end the image copy changed is dropped and made from its messages at read). A seed without the system head (a
  plugin's `ctx.messages`) is checked as the child's messages will be once its first turn puts the head back: the
  lines keep the parent's indices, so until that turn they don't hold and their turns are made from the messages.
- **Reading.** `TurnDrawings.read(dir)` skips an unknown `v`, a torn or broken line and one missing a field, and is
  cached by the file's path, size and mtime. `#last` is the newest line this worker wrote or started from.
  `TurnDrawings.cover(lines, messages, timing:, entries:, skip_turn_id:, session_id:, cwd:)` is what a show draws
  finished turns from (pure): `valid`'s lines, and for each `TurnRanges` range none overlaps (the running turn's
  left out), a line `Synth.memoized` makes from its messages, the timing's records and CardStore's entries. A range a
  kept line overlaps only in part (a Continue's steps, which `TurnRanges` reads as the turn before's, with only one
  of the two lined: drawings that start partway through a session) is split at the lines' bounds and the rest made:
  a part with the turn's opening keeps its id and record, one without is `<id>~<from>` (no record, no entries), so no
  turn item is left without a line. A made range whose id a kept line has (a failed turn's kept steps, then its
  re-run under that id) is renamed `<id>~<from>`, so no two lines share an id; it gets no record, so no timing line
  (the two runs' records share the id: `Synth::LOSSES` `repeated_turn_id`). `TurnRanges.of(messages)` (`bridge/turn_ranges.rb`) reads a session's turns
  back from its messages as the Engine cuts them (`kept_from…kept_to`: the reminders before an opening start a turn; a
  note after it, a `!cmd`'s record and a wake's note stay outside), with a display id for a turn with none
  (`m<from>-<digest8>`) or a repeated one (`<id>~<from>`); `TurnRanges.records` pairs each with its turn record by id,
  else by place among the openings, as `timing.js turnGroups` does (`spec/shared/turn_ranges.json` holds the cases both
  suites read).
- **Made from the messages.** `TurnDrawings::Synth` (`bridge/turn_drawings/synth.rb`; chi web's show, `cover`) makes
  a turn's line from its saved messages, for a `TurnRanges` range no live line covers: the events live would have
  emitted (`turn_started`, the reminders, each step's thinking, text and calls with `MessageParts`' fields and the
  output as `preview:`, steers and merged lines, the end from the turn record), folded by a fresh `TurnAccumulator`,
  so every drawing comes from the one fold. The turn's tool records give each row's status and duration (by tool, in
  call order), and CardStore's entries of the turn (`of_turn`) go in at the step they name (`iteration`, `calls`; an
  in-turn card keeps them too): its cards, hook notices, retries (a retried step is drawn empty), steer cuts, ✂ rows
  and questions. A made-up id (`m…`, `…~<from>`) stays off the end's `turn_id` (no Revise); the end carries the
  record's `record_id`. `Synth::LOSSES` lists what it can't have (a prompt's origin, a merged line's senders, a
  retried step's thinking, evicted CardStore entries, untimed rows, …; `events_drift_spec` makes each `:row` event
  synthesized or listed; a repeated id's later range and a Continue's steps read as its turn's are declared too).
  The fold raises what it can't fold (`TurnAccumulator.new(raise_errors: true)`), and `safe_line` never raises: a
  minimal line (opening, end kind, no parts, `turn_synth_failed`, once), else a constant one (`constant`: the range and
  a completed end); `memoized` keeps lines per range (key: session, range, every message's digest in it, the turn's
  records and its entries without CardStore's listing fields) in a process-wide LRU of `MEMO_BYTES`.
- **The snapshot.** `Bridge#snapshot` (the snapshot and reset frames, `GET /snapshot`) adds `last_turn_drawing:
  {drawing, end}`: the line of the last prompt's turn (the last user message that opens a turn, the one the TUI draws),
  the newest for that turn id that holds against the snapshot's messages (`#last`, else the file's, `TurnDrawings.read`),
  not unfolded, when that turn is the last one (`TurnRanges`: a note after it doesn't hide it). It is absent otherwise:
  a later turn with no prompt (a reminder's, a Continue's: a join would draw the prompt's rows, then the later turn's
  answer without its rows), no prompt with a turn id, a rollback, a line of another version, one over the 1 MB a
  restart reads back (`TurnDrawings.sendable?`). An attaching TUI unfolds it (`TerminalUI::JoinReplay`, `TurnAccumulator.replay_events`) and draws
  that turn's rows through its `EventRenderer`, as a running turn's join does, then the end event's cancel or failure
  line, else the saved answer. Without it (an older worker, a line over 1 MB, a turn from before drawings) the TUI
  makes that turn's line itself: `TurnRanges.of` over the snapshot's messages finds the prompt's range, and
  `Synth.safe_line` draws it with the link's saved records (`LocalLink`, or `RemoteLink#saved_turn_record` /
  `#saved_tool_records` through chi web for `--remote`) and the snapshot's cards, through the same renderer. Nothing
  rebuilds rows from the messages any more. `chi --remote` attaches through chi web's stream proxy,
  which relays an owner's frames byte for byte, the field included. A participant never gets it: its stream's snapshot
  is bare (`ParticipantView`). The snapshot also carries `objectives`, this worker's `Engine#objectives_view` computed
  with the same messages as its `:objectives_updated` event; the key is present (`nil` when there is no list), but is
  omitted if reading the view fails so chi web can use its file view. An older worker sends no key. An older TUI
  ignores the drawing field; an older worker sends none.
- **The show.** chi web's full read (`GET /api/sessions/:id`, whatever its query: a tab from before 0.157 still sends
  `?parts=1`) draws every finished turn from a line: `SessionShow#drawn_lines` is `TurnDrawings.cover` over the file,
  the show's timing records and its cards (CardStore's list, live or saved), the running turn (`current_turn`'s id)
  left out. A file that can't be read gives no lines, so every turn is made from its messages; should the cover
  itself fail (`turn_drawings_uncovered`), no item is stamped and the page draws each as a plain row (its fallback,
  web-frontend.md). `MessageDisplay#messages_for_display(drawings:)` stamps each display item of a kind a drawing
  draws (the opening, steps, steers, merged lines, the empty answer) in a line's range with `drawn: <turn_id>`; the
  items carry no `parts` (a step's ✂ marks come as `marks: {tool_id => edit}`, read from its parts only for a step
  whose outputs carry one; a text-less step stays as an empty item), and the show sends `turn_drawings: {turn_id =>
  {events, end}}`: `TurnAccumulator.replay_events(drawing, cards: true)`, the one unfold, in Ruby. A context note in
  a range and a `!cmd`'s record are not stamped. CardStore lists an in-turn entry's turn as `of_turn`, so the page
  leaves a drawn turn's own rows and cards to its drawing (`cards_place.js`). Every supported worker (0.161.0 and
  later) lists `TurnDrawings::FEATURE` in its sidecar; the show no longer asks. The stamps walk the lines with one
  cursor and the unfold reads a Set of stamped ids, so a long session's show is linear in its turns; a made-up line
  is memoized per range (`Synth.memoized`), so a show after a turn end makes no old turn again. What each step did
  as message parts (`MessageParts`, `parts: true`) is the participant review's only (`ParticipantReview`, frozen on
  its message model).
- **Compat.** An older worker writes nothing, a continue (a note, no turns) and a review fork copy no drawings, and
  an older chi's fork or one-shot wrote none: their turns are made from their messages. A `/btw keep` child forked
  before its first turn (saved without its system head) draws its turns made from its messages, without CardStore
  rows, until that turn puts the head back and its carried lines hold (`Synth::LOSSES` `fork_before_first_turn`;
  `Plugin::Sessions#fork`'s seed is left as it is). A tab opened before 0.157 asks `?parts=1`, gets no parts and
  draws those turns without their steps until it reloads. The lines a fork carries and a
  one-shot writes are plain `v: 1` lines, which an older chi web draws as any. An older chi web never opens the file and draws them as it
  did. A made-up line's end has no `turn_id` for a made-up id and names its record (`record_id`), which a 0.157+ page
  reads as any drawn turn's (an older page ignores `record_id` and finds no record for such a turn: no timing line;
  it also keys such a turn's answer by the made id, `data-answer-turn`, until a reload: only a turn saved before turn
  ids or a repeated id's, never a wake turn, which has its own id).
  `release:bump`'s compat corpus has a session with a line (`compat-drawn`) and one without; `readers_spec` checks
  every turn of both is stamped.

## CardStore

The cards a plugin or the Engine shows (`Engine#show_card`), hook notices, load warnings (`:guardrail_warning`),
the "asking again" and steer-cut rows, ✂ rows and questions (with how they were answered), for a UI that joins later:
`snapshot[:cards]` and `GET /tail`'s `cards`.

- **Anchored to its turn.** The store keeps a **turn log**, every id it saw at `:turn_started`, oldest first. An entry
  holds `turn_id`: the running turn's, else the log's last (nil before any); a load warning, which the Engine announces
  inside the first turn, takes the one before it. `list(messages:)` computes `turns_since` from the messages the page draws
  (`CardPlaces`, the snapshot's own list; a stopped session's file for `.saved`): the turn openings (`Steer.turn_opening?`, as
  the page's `TURN_PROMPT` and the recap count) after the last one whose id is in the log at or before the entry's, else from
  the first one whose id is later in the log, else 0. The log only orders; the messages count. So a turn with no opening (a
  reminder, a Continue, a failed or rolled-back one, a prompt stopped before the model) moves nothing, a wake's note does, and
  an opening with no turn id (`/continue no`'s reason, which carries an `opening_id` of its own instead, `TurnFlow#abort_continue!`)
  counts as on the page. KernelLoop's Qwen recovery line (kind `recovery`, `Steer.recovery?`) is a row of its turn, no opening:
  the page draws nothing for it (`MessageDisplay`), as live. Nothing orders such an opening
  against an entry, so the store reads the session's messages (its `messages:` lambda) when an entry is shown between turns, and
  at the turn's end for what a running turn showed that isn't its own: `past_idless` is how many of them, right after the opening
  it counts from, the entry already came after, and they don't count for it. A `!rollback` usually only shortens that run, and the count
  is capped at the run still there, so a stale number doesn't eat a later turn. It can also move an entry's counting point back to a
  run the entry never recorded (T1, `/continue no, too slow`, a card, a held T2 stopped, a second card, `!rollback`: the second card,
  anchored to T2, now counts from T1 and reads above the reason and the first card). That rare inversion is accepted. A turn's own rows don't read it: they count such a line, which sits below them. `current` is a card of the running turn. A card that
  comes mid-turn but isn't the turn's (an anytime command's, such as `/btw`) goes after that turn (`during`), and so does a
  between-turns notice. A card with an earlier card's id replaces it in place and keeps its anchor. A `list` with no messages
  (`?cards=1`'s bodies, `chi bundle try`'s trace) has no `turns_since` and no `opening_id`.
- **The stamp.** Next to `turns_since`, an entry lists `opening_id` (`CardPlaces#opening_of`, one `Steer.opening_stamp` rule with the recap's): the id of the opening its count
  reaches, the one it comes after: a prompt's `turn_id` (a wake note's too), or `/continue no`'s reason line's `opening_id`. It is
  resolved at `list` time from the same anchor (an entry's own turn often has no bubble: a Continue, a failed or rolled-back turn),
  so the stamp and the count always name one place, and the page finds it by the bubble (`card_stamps.js`: `data-turn-id`, or `data-opening-id` on a wake's note or a reason line), not by counting
  bubbles. An entry shown after reason lines also saves which one it came after (`after_opening`, beside `past_idless`): read
  first while that line is still in the run, so a later release can drop the count. No stamp (the page counts `turns_since`) for
  an entry before every opening, after a line an older chi wrote with no id, or from a version 1 file (`base_since`). A rollback
  keeps today's rule: a rolled-back turn's cards name the opening before it.
  The saved recap carries the same stamp: `saved_recap`'s `opening_id` (`RecapPlace.opening_id`, the id of the last
  opening its `covered` messages hold, read at read time, so `recap.json` is unchanged), which the page places it after
  (`recap_stamp.js`); an older worker's `saved_recap` has none, and the page counts `turns_since`.
- **A turn that leaves nothing** is read, not told: an in-turn entry not `current` whose turn has no opening in the messages
  (a `!rollback`, a failed turn with nothing kept, a prompt stopped before the model) lists as a between-turns entry at its
  place, a card without its actions and a hook's notice without its step; its other rows, having no step to sit in, aren't
  listed. Nothing in the entry changes. A kept Continue or reminder turn never has an opening, so its entries are `continued`
  and stay rows of the turn before; a failed one loses the mark at its end. The page draws a failed prompt at the history's
  end, so an entry pushed idle after it lists `after_failed` (the store's saved `failed_turn`) and goes below it, until the
  next turn starts.
- **A command's card.** `SessionCommands#run` wraps its dispatch in `Engine#running_command`, so a card shown on that thread
  carries `command:` (the event's field, `show_card` adds it). The store keeps the first show's (a replacement keeps it, even
  none) and lists `label: "from /short"`, never `command`. The page draws it after a reload, where the command's line is gone.
- **Caps.** `CAPACITY` (20) each for notices, ✂ rows (`LLM_CONTEXT_TYPES`) and cards, so one burst cannot push out
  another kind. An open question (an approval too) is never pushed out.
- **Saved.** With a `path` (`cards.json` in the session's folder) the store rewrites the file after each event in
  `SAVED_ON`, and a later worker's store starts from it, so a turn's cards outlive the worker; `CardStore.saved(dir, messages:)`
  is what chi web reads for a session no worker runs. The file is `{version: 2, turn_log:, entries:}`. The log is pruned at
  a turn's start and end and at an idle show (a running turn's rows reuse the start's, as finding it walks the messages) to start at the opening the earliest anchor counts from (all of it while an entry has none, or for a store with no
  `messages:`), so a restart reads an entry as the live store did; an old card therefore keeps it whole. `seed` drops an entry
  whose `turn_id`, `after_opening`, `base_since` or `past_idless` isn't an id or a non-negative integer. A file 0.154.0 wrote
  (no `after_opening`) lists the same stamps, from its counts; an older chi reading this one keeps `after_opening` (it seeds
  entries whole) and lists it, unused. Load warnings
  are the worker's own (each start announces them) and an unanswered question waits for no one: neither is saved or seeded. An
  entry from an earlier worker lists with `earlier: true`; one shown during a turn comes back **without its actions** (their
  turn no longer runs), while a between-turns card keeps its buttons.
- **Version 1.** A file from before the log (top-level `turns`, each entry its own, maybe `running`) keeps its places, drift
  included: `seed` turns each count into `base_since`, new openings add to it, and such an entry never reads as having left
  nothing (no id to check). The next save writes version 2 with `base_since` kept. `SessionManager.cards_empty?` reads both.
- **An older chi on a version 2 file.** Its `seed` wants an integer `turns`, finds none, and starts with no entries. A chi web not
  yet restarted only reads: it lists no cards for that session until restarted, and the file stays whole. An older **writer** does
  damage: at its first saved event, `:turn_started`, it writes `{"version":1,"turns":0,"running":true,"entries":[]}` over the file
  (`{"version":1,"turns":1,"entries":[]}` after that first turn), so that session's cards go, and with them the answered approvals
  `chi guardrails replay` reads. A plain upgrade doesn't reach this: a worker already running seeded before and keeps its own version 1
  file, and a spawn runs the newest chi installed (`SessionManager.worker_command`), unless that activation raises LoadError: the boot
  line then falls back to the spawner's or the home's pinned version, which can be older. Otherwise it takes an older process starting
  on a session a newer one wrote: a downgrade, a chi home whose newest chi is older (`home_older_than_spawner`), or a `bin/chi`
  from an older gem or checkout on the same state dir. Nothing on this side stops
  it: an older chi can't be changed, and having it read the file would mean writing fake `turns` counters into every file.
- **A killed turn needs nothing special.** `TurnCheckpoint` keeps a running turn's prompt in the session file, with its id from
  the start (`Worker#run_engine_turn` settles it first), so it counts as any opening. A `--non-interactive` one-shot keeps no running turn in the
  session, so a kill takes the prompt along and there's nothing to count.

## SSEWriter

One per `GET /session/:id/stream` connection, and itself that connection's observer: `Engine#emit_event` calls
`#call` on the turn's thread, so it only pushes onto a `BoundedQueue` (when full, the oldest entry goes and an
overflow flag is set). The connection's own thread (`#serve!`) drains the queue onto the socket, so a slow client
cannot stall a turn or another subscriber. An event holding bytes JSON can't take goes out scrubbed
(`SSEWriter#frame_json`, `LLM::Utf8Scrub`): a raise there would end this stream, and every later one for as long as the
ring holds the event. `serve!` orders a join so that nothing is missed or doubled:

1. subscribe the live queue first;
2. capture `event_count` (the snapshot seq);
3. replay the ring's events in `(from_seq, snapshot]`;
4. drain the queue for `seq > snapshot`; a per-connection high-water mark drops what step 3 already wrote.

`?snapshot=1` replaces 2-3: subscribe and `Bridge#snapshot_frame` happen as one step with the event log held
(`Engine#synchronize_events`), the client gets one `snapshot` frame, and live events follow from the next seq.

A **`reset`** frame (the same content, numbered with its own seq) is written when a cursor cannot be replayed: it is
from another epoch, ahead of the engine (a restarted worker), behind the ring's window (a cursor at `oldest - 1` has
seen everything before the window and replays), or the queue overflowed since the last drain. A cold connect (no
cursor) is behind the window too once the ring has evicted an event (`RingBuffer#dropped?`: a replay would start mid-turn), so
it gets the `reset`; on a ring that never evicted (its first seq can be above 1: events before the Bridge started) it
replays the whole window. The clients re-sync on a `reset` and
reconnect with the snapshot's own id, which is inside the window (the web `resync`, the TUI's `follow`). Replay state is in memory per worker; there is no durable resume.

Each frame is `id: <seq>-<epoch>` (`EventId`: the seq first so a reader that takes it as a number still gets the
seq), `event: <type>`, `data: <json>`. A `: ping` goes out after `heartbeat_interval` (15 s) of silence. A watcher
thread reads the socket for EOF so a hang-up is noticed at once, not at the next write, and `Bridge#open_streams_except`
(used by `POST /exit`) stops counting that stream.

**ClientEvent.** Every event is projected on its way out, live and replayed alike (`ClientEvent.project`, pure: the
event hash is shared by every observer and is never mutated). `generation_chunk` loses `payload` and `content` and
gains `counts`; `tool_call_started` loses `call`; `turn_completed` loses `result`; everything else, `event_seq`
included, passes through. `?raw=1` skips the projection (debugging). Add a field to the wire only here, when a client
needs it.

## Routes and reads

The route list, the wire shapes, the browser/proxy refusals and the secret, as the Bridge answers them. Every route
goes through `Bridge#dispatch`.

The Bridge exposes:


- `GET  /session/:id/stream` — SSE stream of engine + kernel events, each with an
  `id: <event_seq>-<epoch>` cursor (the epoch is drawn per worker's Bridge, since `event_seq` starts
  over in each worker; snapshots and `/state` carry it as `event_id`); resume via `Last-Event-ID` /
  `?from_seq=` (a plain `event_seq` is still accepted); a `: ping` heartbeat keeps idle proxies alive;
  too-old reconnects, and cursors from another worker's epoch, receive a `reset` marker carrying
  `session_state_snapshot`. `?snapshot=1` joins with a snapshot frame instead of a replay;
  `?client_id=` names whose stream it is (`Bridge#open_streams_except`, used by `POST /exit`; `Bridge#open_streams_of`,
  by a scratch worker, which counts only `tui:` streams: a web tab's, through chi web, names none).
  Each event goes out as clients get it (`Bridge::ClientEvent.project`, in `SSEWriter#write_event`, live
  and replayed alike); `generation_chunk`, `tool_call_started` and `turn_completed` are projected to the
  contracts below. The ring retains raw events for replay and `?raw=1`.
  `?raw=1` writes events as the engine emitted them, for debugging on the worker's port: `chi web`'s
  `/api/sessions/:id/stream` never passes it on (`Web::App#stream_query`).
  An attached terminal's stream (`EventStream` with `rediscover:`) looks for the session's live
  worker whenever it drops: a new one (a restart) is followed from its snapshot, and the terminal
  sends its requests there (`worker_changed`); it gives up after ~12 s, or at once when the session
  was stopped.

  **Adding an event type.** Assign every emitted type a lifetime in `Events::CLASSIFICATION`
  (`row`, `state`, `transient` or `internal`); keep stream frames and synthetic replay types in
  `Events::STREAM_FRAMES` and `Events::SYNTHETIC`. `spec/events_drift_spec.rb` checks event coverage
  and names the live web/TUI handlers; for rows it also checks the reload owner (`TurnAccumulator`
  or `CardStore`) and TUI join replay. Follow any documented exception there when a row reloads
  through session messages or a fallback path instead.

  The wire chunk (the contract; the engine's own event keeps the provider's `payload` and the raw `content`):

  ```
  event: generation_chunk
  data: {"type":"generation_chunk","iteration":2,"text":"…","thinking":"",
         "tool_call":true,                                   // only when set
         "counts":{"prompt_tokens":489,"completion_tokens":12,
                   "total_tokens":501,"context_window_tokens":32768},  // only when the server reported counts
         "event_seq":812}
  ```

  A `tool_call_started` frame keeps its row fields but omits the model's `call`:

  ```
  event: tool_call_started
  data: {"type":"tool_call_started","iteration":2,"call_index":1,"tool":"write",
         "params":"path=notes.txt","event_seq":812}
  ```

  Both tool events carry the run's `tool_id` (`ToolIds`, the id its output is saved under in the session's
  `tool_ids`, handed out before the batch runs), and `tool_call_completed` carries `duration_ms`: the call's time from
  the `tool_call_started` emit to its own, less an approval's `waited_ms`, rounded first (SessionMetrics' tool record
  definition). It is the one duration every UI shows: the web's live row, the tool record a reload draws, the attached
  terminal's line; each keeps its own clock only for an older worker's event without it. A long output's
  `tool_call_completed` also carries `preview`: `ToolOutputCut.preview` of the capped output at `WEB_PREVIEW_CHARS`
  (a `read`'s head, any other tool's head and tail), the text a reload's row has from the saved output
  (`MessageParts#tool_part`; spec/tool_preview_parity_spec.rb pins the two). The web row and the accumulator's part
  take it; the TUI keeps `output`.

  An end event (`turn_completed`, `turn_canceled`, `turn_failed`) of a turn that kept messages carries `kept_from` and
  `kept_to`: the turn's own messages are `messages[kept_from...kept_to]` of the session it leaves (`Engine#end_turn`;
  `kept_from` is the conversation's size under the system head the turn may have added, before its reminders and
  prompt). Small integers on the event only, never on a message; no client draws them (`Bridge::TurnDrawings` reads
  them). An older worker's end event has neither.

  A `turn_completed` frame omits `result`; `turn_summary.output` carries the answer:

  ```
  event: turn_completed
  data: {"type":"turn_completed","turn_summary":{"output":"Done."},
         "display_pending":false,"event_seq":813}
  ```

  `counts` is `ContextUsage.normalize` of the provider's payload without `ctx_pct` (normalize computes it
  without the session's LLM context budget; a client counts `total_tokens` against the window or budget, as
  `ContextStatus#generation_done` does for the TUI) and with its nil keys left out: cumulative for the
  request, a missing key means unknown (never 0), `prompt_tokens` includes cached tokens, and
  `context_window_tokens` is there only when the payload reported a window itself (llama.cpp's `/completion`
  doesn't: the client uses `generation_started`'s). Unknown provider fields never cross; a field is added here
  when a client needs it, never as a catch-all bag. Details: [internals/context-telemetry.md](context-telemetry.md).
- `POST /session/:id/turn` — fire-and-forget turn creation; returns `202` with an `enqueued_id`
  (body: `{session_id, prompt, enqueued_id?}`; the optional id is a client-made UUID, generated by
  the Bridge when absent or invalid). `BridgeClient#post_turn` supplies one when its caller does not,
  including the attached TUI. The turn still goes through the worker's file-IPC input path — the
  Bridge never calls `run_turn` across the HTTP boundary. Repeating an id already accepted by this
  worker with the same prompt returns the original `202` acknowledgement, including its delivery and
  cut outcome, and does not enqueue another turn; a different prompt with that id is refused with
  `409 enqueued_id_conflict`. An input file with an already accepted id is consumed without running.
  The worker keeps a bounded recent history of accepted ids.
  For N-1 compatibility, an older worker ignores the optional field and generates its own id; an older
  client sends none, so this Bridge generates one. Only the bridge's own session: another id, in the
  path or the body's `session_id`, is `404 unknown_session`. Inspect results through the read surface,
  not the turn response.
  An optional `deadline` (epoch seconds; `BridgeClient` sends 5/6 of its read timeout ahead) makes
  a request read after it (a worker frozen by sleep or SIGSTOP) answer `408 deadline_passed` and
  not run: a client that timed out has said the message was not sent. `/answer`,
  `/question/dismiss`, `/command`, `/turn/dequeue` and `/exit` take the same `deadline` (a command is
  checked with the event log held, as a turn is), and the Bridge logs `turn_expired`, `answer_expired`,
  `dismiss_expired`, `command_expired`, `dequeue_expired` or `exit_expired`. The web app answers either
  kind of timeout with `504 worker_timeout` ("… so the command was not run"). `/cancel` and `/recap` take none.
  The web relays answer, dismiss, command and cancel the same way (`App#relay`): a 408 or a read
  timeout is `504 worker_timeout`; a Bridge 404 for a route an older worker lacks is
  `501 not_supported` with the restart hint; a Bridge `404 unknown_session`, no bridge or a
  refused connection is `503 not_live`.
- `POST /session/:id/cancel` — cancel the running turn; `202`, or `409 not_running` when none runs. The optional
  `turn_id` names the turn the Stop means (the web page and the TUI send the one they show): `TurnState#cancel!` compares
  it to the running turn's id under its lock, and another turn running is `409 turn_mismatch`, nothing cancelled, so a
  Stop pressed as a turn ends can't cancel the queued next one. No `turn_id` (an older client) cancels whichever runs.
- `POST /session/:id/recap` — `/recap` in an attached TUI: `200 {enabled, saved, request,
  min_user_turns}` (`{enabled: false, session_off}` without recaps; `session_off` when the session's own
  `/recap off` turned it off); a new recap is asked for at once and
  arrives as `:recap_ready`. Answers mid-turn too.
- `POST /session/:id/answer` — answer the pending question; `200`, `409` when another client
  answered first or it is gone, `400` for an invalid selection. With `client_id: "cli:answer"`
  (`chi answer`, a parent agent) the answer is checked by `Guardrails::ParentPolicy` in
  `QuestionDesk#answer`: the question carries each option's effect (`effects`, set by its asker:
  `Approval.payload`, `ContinueOffer`, `Relay.card`; derived for an untagged one) and `user_only`,
  and an option beyond the worker's `guardrails.parent_answers` (tightened by the session's own
  `parent_answers`: `ParentPolicy.for_session`) is `403 parent_answer_refused` (with its `reason`),
  the question still open. `chi answer` makes the same check first, from the session file.
- `POST /session/:id/question/dismiss` — leave the question unanswered (an approval: denied);
  `200`, or `409` when it is no longer pending.
- `POST /session/:id/guardrails/wrong` — `{id}`: label this session's System 1 auto-allow as
  one it should have asked about; `200`, `404` for an unknown judgment, `409` if already labelled.
- `POST /session/:id/holds/stop` — stop those holds without the worker leaving; `200 {status: "stopped",
  session_id, stopped}` or `501 holds_unavailable`.
- `POST /session/:id/tasks/stop` — `{task_id}`: stop a background task as the user
  (`TaskRuntime.stop_task by: "user"`, the web's stop-task button on a running `task_wait`;
  web route `POST /api/sessions/:id/tasks/:task_id/stop`). Only a task this conversation's
  `task_create` started, or an `execute` handed over as a task at its limit (`TaskRuntime.created_ids_in` on the
  saved messages, or the running turn's accumulator); answers once the
  task is gone: `200 {status, stop_reason, task_id}`, `404 task_not_found`, `409 not_running`.
  The worker names it in its sidecar features (`task_stop`).
- `POST /session/:id/turn/dequeue` — `{enqueued_id, client_id?, deadline?}`: take back a queued message
  (one that waits for the running turn's end: `--queue`, Alt+Enter, `/queue TEXT`, or a message
  with images) before a turn takes it (web route `POST /api/sessions/:id/turn/:enqueued_id/dequeue`,
  the × on a queued bubble; `/unqueue` in the attached TUI). Under the event log, like its enqueue:
  `SessionInbox.take_queued_input` writes a tombstone (`input/removed/<enqueued_id>`, for `ReplyWait`'s
  `turn:`), claims the file as the drain does (one rename wins; a lost claim takes the tombstone back),
  deletes it, and the Bridge announces `:turn_dequeued`. `200 {status: "removed", enqueued_id, prompt}`, `409 already_started`
  (a turn took it), `409 not_queued` (a next-step message: a drain may merge it any moment), `404
  unknown_enqueued_id`. It never wakes the worker. The worker names it in its sidecar features (`unqueue`).
  A worker's start prunes the `input/removed/` and `input/settled/` tombstones and the drain's merge records
  (`input/merged/<enqueued_id>` = `{into, at}`, written by `Worker#pending_input_drain` before it deletes a file it
  merges; their own directory, which a 0.156 waiter never reads) older than a week
  (`SessionInbox::TOMBSTONE_MAX_AGE`, log `tombstones_pruned`); otherwise they go with the session dir.
- `POST /session/:id/relay` — the approval relay, on a delegated child's worker
  (`{action, relay_id, question_id}`): `opened` / `closed` (with a `reason`) set or clear the
  pending question's `relayed_to` mark (`QuestionDesk#annotate`, `:question_relay`); `answered`
  makes the child ask its parent's Bridge for the answer (`RelayVerifier`) and take it only for
  this child and the question pending now. `200`, `409` no longer pending, `403` a parent agent's
  pick beyond the child's own `guardrails.parent_answers` and session `parent_answers` (`parent_answer_refused`; the
  relay card in the parent was held to the parent's), `422 relay_unverified` (the question
  stays open).
- `POST /session/:id/relay/status` — on a parent's worker, `{relay_id}`: what its `RelayDesk`
  (memory only) holds for that relay (`child_id`, `child_question_id`, `state`, `answer`, `by`);
  `404` for an unknown id. A POST with a body because routes match exact paths.
- `POST /session/:id/command` — a session command (`/model`, `/models`, `!rollback`, `!cmd`,
  `/continue`) for the worker loop; `202` with a `command_id` its `:command_ran` names, `400` when
  the line isn't one. A `:command_ran`'s `output` is the command's, up to `Worker::COMMAND_OUTPUT_LIMIT` (64 KiB of chars; past it
  the text ends with a `[cut: N of M chars: …]` line, which the UIs print as they print the rest). It carries `thinking`, `reasoning_history` and `llm_context`
  (the summaries the next turn runs under) when the command changed them or the model, and
  `confirm: {line, text}` when a `/thinking` or `/reasoning-history` change from a `web:` or `tui:`
  client asks first (`CacheConfirm`; nothing changed, `line` applies it).
- `POST /session/:id/exit` — ask the worker to exit now (`{client_id:, delete?, restart?, deadline?}`; `delete`:
  `/exit --delete`, no recap written; `restart: true`: hand the session to a new worker on the newest chi
  installed, `200 {status: "restarting"}`; an empty session's `exiting` carries `discard: true`). The worker checks with
  the event log held (`WorkerIdleExit#hold_for_request`): `200 {status: "exiting"}` and it leaves
  like an idle exit, or `409 {status: "held", reason:}` with `turn_running`, `input_queued`,
  `continue_offered`, `client_connected` (a stream not named by the asker), `reminders`,
  `background_tasks` (with `tasks: [{id, command}]`: the running tasks a finish wake watches), `starting`, or
  `leaving_exit` / `leaving_delete` / `leaving_restart` when another client's exit of another kind is already taken
  (`Worker#claim_exit`, claimed before a stop-all; the words are `WorkerIdleExit::LEAVING_WORDS`). A second exit of
  the kind already taken is answered `200` as that one.
- `GET  /session/:id/state` — `session_state_snapshot` (JSON), read under the event lock so its `event_seq`/`event_id` match the state.
- `GET  /session/:id/stats` — `Engine#stats_snapshot` for attached `/stats`: the metrics, with the context window and prompt profile asked from the server before the first turn.
- `GET  /session/:id/activity` — `Worker#activity_snapshot`: `{session_id, turn_running, input_pending, awaiting_continue, open_streams, reminders, tasks_holding}` — what a `chi schedule tick` asks a live worker before it fires (the tick runs out of process and cannot read a worker's memory). Read-only and small (under 300 bytes). `501 activity_unavailable` when this Bridge was built without an `on_activity:` step; the worker advertises it in `Bridge::FEATURES` (`activity`). See [scheduling.md](../scheduling.md).
- `GET  /session/:id/holds` — the reminders, watched tasks and delegate children the user can stop;
  `200 {session_id, holds}` or `501 holds_unavailable`.
- `GET  /session/:id/snapshot` — the snapshot frame's content as one request (the web server renders
  the messages itself, then streams from its `event_seq`). Read by the web's full show
  (`GET /api/sessions/:id`) and `ctx.sessions.read` (`Plugin::Sessions#read`), which unwraps
  `snapshot`; the Bridge reply is `{snapshot:, session_state_snapshot:}`. `snapshot.objectives` is the worker's
  objectives view, including the running conversation; it is present as `nil` when the worker has no list and omitted
  if reading the view fails so chi web can use its file view. `snapshot.idle_working_set` is the worker's next-turn
  working set between turns (including pending adds), omitted while a turn runs or if building it fails.
- `GET  /session/:id/tail` — the page's light re-read (`Bridge#tail_frame`): `session_state_snapshot`,
  `working_directory` (the session's folder, which the web checks the answer's file refs against),
  `answer` (the last message a UI shows as an answer, `AnswerTail`: the one message, copied alone),
  `cards` (`CardStore#list`; a card an earlier worker showed during a turn comes back read-only, with no
  actions: its turn no longer runs), `event_seq`, `event_id`, all taken in one event-log hold; no message
  list, so it costs the same however long the session is. `?turn_id=` answers that turn's answer
  (an unknown or missing id: the newest); the only route that reads its query.
- No browser: only chi's own clients talk to a Bridge. A request with an `Origin` header, a `Sec-Fetch-Site`
  other than `none`, or a `Host` that isn't loopback (a DNS-rebound page) is `403 cross_origin`
  (`Bridge#browser_request?`, before any route); there is no CORS and no `OPTIONS` route. The browser reaches a
  worker only through `chi web`. A request carrying any trace a proxy adds (`ProxyTrace`: `X-Forwarded-*`,
  `Forwarded`, `X-Real-IP`, `X-Auth-Request-*`, `Cf-*`…, underscore twins too) is `403 proxied`
  (`Bridge#proxied_request?`): an auth proxy that forwards every local port and adds such a header doesn't reach a
  worker.
- **The secret.** Every request, on every route (the stream, the reads such as `state` and `stats`, the writes, and
  an unknown path), names the Bridge's secret in `X-Chi-Bridge`; one without it, or with another one, is
  `403 bridge_secret` with one session-specific message (`BridgeSecret.refused`): "session ID's worker refused
  this chi's request (it didn't name its secret): a chi web or terminal started before chi was updated can't
  reach it; restart chi web, re-attach with `chi --attach ID`, or restart the worker with `chi sessions restart
  ID`." `chi sessions restart` can also recover when the worker cannot be asked: TERM + resume if disk shows no
  running turn, pending question or approval, queued input, or running background task. The check is after the
  browser and proxy checks and before any route (`Bridge#secret_ok?`,
  `OpenSSL.secure_compare`). No route is left open: what the reads show is the session itself. Only a request that
  got past it counts as client activity, so a refused one (an older chi web's polls) never holds the idle exit. Each Bridge makes its own (`SecureRandom.hex(32)`, 64 hex
  characters) when it starts and writes it to `bridge.json`, which is 0600 from the moment it exists
  (`AtomicFile` creates the temporary file with that mode, then renames it), so only this machine's user can read
  it: a forward that adds no proxy header, or another local account, reaches the port but not a session. Clients get
  it only from the sidecar: `WorkerLink.client`/`.await` and `BridgeClient.for_sidecar` take the port and the secret from the
  same read (chi web makes its client from the sidecar for every request, the attached terminal again on a
  `worker_changed`), so a respawned worker's new one is used and nothing passes a port by hand. A worker from before
  the secret writes none and asks for none; a chi web or attached terminal from before it sends none, so a worker
  the newer chi started refuses it until it is restarted. A client tells that refusal from a route's own 403
  (`BridgeClient::Response#secret_refused?`) and shows the one message: chi web's relays answer 502 `bridge_secret`,
  `chi answer` and a parent's approval relay say it instead of "refused", and an event stream ends with reason
  `bridge_secret` once rediscovery finds no newer worker (the attached terminal's closing line), never retrying in
  silence; chi web's stream proxy answers 502 `bridge_secret`, never passing the refusal on as frames. The secret is never logged (a refusal logs
  `secret_refused` with the path, at most once a minute), never in an event, a reply, `/api/info` or a session
  file, and `WorkerSidecar`, `BridgeClient` and `Bridge` leave it out of `#inspect`.

The metrics in `/state`, `/snapshot`, `/stats` and the SSE `snapshot`/`reset` frames
(`SessionMetrics#snapshot`) carry the session's totals and only the recent timing records: the
newest turn the worker finished and any it hasn't saved yet (at most 20 turns), with their tool
calls and the running turn's finished ones. The full history is the session's `analytics.json`,
which `SessionMetrics#persist` rewrites after each turn; the web server merges the two by id.
The totals' `tokens` block adds the cached, cache-write and reasoning sums, the reported cost (`cost_sum`) and the
estimated one (`cost_estimate_sum`, from `hosts.<name>.models` prices; 0 for none), the decode time and tokens
behind the average speed (`avg_decode_tps`) and the last speeds (`last_decode_tps`,
`last_prefill_tps`, `tps_source`: `server` or `estimate`). `model_segments` (always present) splits those sums
by model after a `/model` switch: one row per run of consecutive turns on one model (`SessionMetrics::ModelSegment`,
keyed on the turn records' `model_ref`), in order, with its turns, token and cost sums, speeds and the switch's prefill
(`prefill_tokens`, `prefill_cost_estimate`: the sums of its turn records' `switch_prefill_tokens` and
`switch_prefill_cost_estimate`, [sessions.md](../sessions.md)); `[]` with one model, the oldest rows folded into one (`folded_segments`)
past 6; a running turn counts in its model's row (`ended_at` null). The rows add up to `tokens`. They are derived from
the records, never read back. Each `generation_completed` event
carries the generation's `speed` (`{decode_tps, source}`, null without one), its own prompt-cache
counts (`prompt_tokens`, `cached_tokens`, `cache_write_tokens`: null when the server reported no writes) and
those running `tokens` and `model_segments`: the Engine closes the generation in `SessionMetrics#finish_generation` before relaying
it, so the web's info bar updates per generation without parsing chunk payloads.
Side requests (the idle recap, a plugin's `ctx.ask_model` such as `/btw`) are counted apart, in a `side` block
(only when there were any; `SessionMetrics::SideTotals`: requests, token sums, `cost_sum` null until reported,
`cost_estimate_sum` from the target host's price, `by_kind`): `IdleClient` hands each reply's usage to its
`on_usage:` callback, `Engine#note_side_usage`, which folds it (`SessionMetrics#add_side`) and announces
`:side_usage` (`kind`, the whole `side` block) under the event lock, so the blocks arrive in fold order, then saves
`analytics.json` between turns (a running turn's end saves it). `tokens`, `model_segments` and the turn records
stay the turns' only. `SessionMetrics#persist` is serialized (its own mutex, taken before the metrics one), so two
threads' saves land in snapshot order.
A bundle's `ctx.cost` reads the same sums (`SessionMetrics#cost`, a frozen `SessionMetrics::Cost`): the `tokens`
block's `cost_sum` and `cost_estimate_sum` with the running turn's finished generations folded in, plus the `side`
block's, so it counts what earlier workers spent too ([plugins.md](../plugins.md)). Its `ctx.usage` reads the work
(`SessionMetrics#usage`, a frozen `SessionMetrics::Usage`): the snapshot's `turns`, `tool_calls_total` /
`tool_calls_by_tool` and `iterations_total`, and `active_ms`, the generations' `gen_ms` plus the finished tool
records' `duration_ms` (tallied per tool as they are counted; `ask_user_question`'s, a wait on the user, left out).

The page's frequent reads of `GET /api/sessions/:id` stay light too:
- `?tail=1&recent=1` (each turn's end, a cancel, an answer display): `{tail, session: {id, status,
  used_memory_names}, messages: [the answer, with its display and display_refs (re-read on an `answer_display` with a display or refs)], markdown_warning, timing}`, from the worker's `/tail`
  alone (no session file parsed, no `analytics.json`); `timing` carries the worker's recent records
  and `turn_count` (finished turns). The page merges the records by id (`timing.js mergeTiming`) and
  finishes the ended turn's own line by its `turn_id` (sent as `&turn_id=`, which also picks that
  turn's answer). A tail read's timing is always the newest turn's; `recent=1` is accepted and not needed.
  The page binds an answer's `display_refs` to its bubble (`answer_refs.js`: on a reload's render and on this
  read's re-render) and pairs them with the bubble's links and text before the `path:line` scan. A question's
  refs (`pending_question.refs`, `:question_asked`) pair the same way (`markdown_place.js` `linkRefsIn`/`pairRefsIn`):
  `question_requested` (or a snapshot's pending question) keeps them on the asking step's gen
  (`turn_model.js` `questionRefs`) before the card draws, so the lead-in bubble (`stage_opened.js`, its refs from
  `turn_model.js askingRefs`) pairs them on its raw draw and again after its markdown swap; the card pairs its
  question text and its kept reply (`question_cards.js`); the step's closed `.gen-text` takes them
  (`turn_block.js`; on a reload its `data-answer-at`, the message's `display_refs`) and `linkTextRefs` pairs it at
  the turn's end and after a reload. A closed step's text is markdown too with `web.markdown` on: a reload's
  from its message's `html` (`turn_block.js` `textTemplate`), a live turn's from `POST /api/render` on its step's
  first open after the turn's end (`markdown_place.js` `renderStepTexts`, which pairs its refs again after the
  swap); the text as written stays on it as `data-copy-source` (`stepText`, a reloaded card's kept reply). A file ref outside the
  session's folder is dropped, as a reload drops it: the folder `/tail` names, else (an older worker) the hub's
  session list entry's, else (refs to check, no hub entry) the session file's; with no folder known at all, every
  file ref is dropped rather than shown unchecked.
  A plugin tool's row refs (`refs`, `RowRefs`) ride its tool events and, on a reload, its part (saved as
  `tool_refs`); `turn_block.js` binds them to the row's title (`refs.js bindRowRefs`: the first on the title,
  the others in its menu).
- `?timing=1`: the whole timing (`analytics.json` merged with the worker's `/state`) and
  `turn_count`, when the page's merge came up short.
- `?cards=1`: the cards, from `/tail`; the session file is only stat'ed for the 404.

The stage view's working set (`web.working_set`) has its own read, `GET /api/sessions/:id/working_set`: the
`WorkingSet` projection (`{items, at, running}`: each file, memory and URL live, stale or forgotten, with its tokens)
of the worker's `/snapshot` messages, else the session file, under the session's LLM context strategy; while a turn
runs, the snapshot's `working_set` (the running turn's last event, which the messages lag) when it has one. Its live form
is the `:working_set_updated` event, which always wins over a GET's answer it overtook. The page overlays it on the
set it builds from its tool rows ([internals/working-set.md](working-set.md)).

A worker without `/tail` (an older chi; `404 not_found`) is read through `/snapshot` in the same
shape; any other failure (no worker, a 500, a timeout) reads the disk, trimmed to the newest
turn's records.

**Recorded per release.** `rake release:bump` records this Bridge's replies to `GET state`, `snapshot` (idle and
mid-turn) and `tail` in the compat corpus (`spec/compat/X.Y.Z/wire/`, [testing.md](../testing.md#compatibility-corpus)),
and the next release's clients read them (`spec/compat/wire_readers_spec.rb`). Change these replies additively: a key
renamed or moved fails that spec against the previous release's worker, which a newer chi web or terminal still talks
to until it is restarted.

Every route goes through `Bridge#dispatch`: an id other than the bridge's own session is
`404 unknown_session`, and a handler that raises answers `500 bridge_error` (logged as
`handler_failed`) rather than dropping the connection.

The per-session port is OS-assigned (bound to `0`) and published to a `bridge.json` sidecar
for client discovery, with the Bridge's secret (see above).

**Worker link.** Every client asks `WorkerLink` (`worker_link.rb`) whether a session's worker can be reached, never
reading `bridge.json` or probing a port itself: `WorkerLink.resolve(session_dir, unlink:, owner:)` answers a typed
outcome. The rule is the owner lock plus the sidecar's `pid`; there is no port probe (a port can be reused by another
session's Bridge, a free lock is the kernel's proof the worker died). In order: no lock holder, or a one-shot's (kind `"tui"`): a
sidecar is `Stale(:lock_free)` (removed with `unlink: true`, only if it is still the file that was read and the lock,
read again just before, is still free: a worker that took it meanwhile is resolved as that worker), else `None`;
a holder with no kind yet: `Starting`; a leaving worker: `Leaving` (marked before its Bridge stops, on every way out:
`Worker#teardown` marks it too, with `TEARDOWN_LEAVE_WAIT`); a worker whose sidecar names no port or another
pid than the holder's (a worker that has not written its own yet): `Starting`, `stuck` once it has held the lock
past `START_LIMIT` (30 s) with none; a sidecar whose `protocol` is newer than `WorkerLink::PROTOCOL`: `Skew` (a
newer worker; never driven, `wake` answers 409 `worker_newer`); else `Live` (its sidecar; `#client` makes the one
`BridgeClient`). A sidecar with no `pid` is an older worker's: the lock alone says it is live. `owner:` is the
holder as the caller already read it (nil: free), so one read serves a summary and its status. `WorkerLink.client` is
the Live's client or nil; `WorkerLink.await` polls for a new worker's Live (an `until:` check tells a restart's
successor from the old worker); chi web's `App#worker_link` / `#await_worker_link` wrap them. The Bridge writes
`pid` and `protocol` with its port and removes its sidecar on stop only when the file still carries its epoch.

`chi web`'s `GET /api/sessions/:id/stream` proxies this bridge
(503 `not_live` for no worker, a leaving or stuck worker, or an unreachable Bridge; 502 `worker_newer` for skew and
`bridge_error` / `bridge_secret` for a refused Bridge; 200 only after the Bridge answers; full history of any session
is served by `GET /api/sessions/:id/output`). It opens the Bridge before answering and gives the one opened socket to
`App#proxy_stream_body` / `ProxyStreamBody`, which closes it when the body or hijacked client ends. The owner's stream
is a byte pipe; the body gives it the request's frame filter (`App#stream_filter`: nil for the owner; for a participant, and the owner's participant view
`?as=participant`, a `Web::ParticipantStreamFilter`, which cuts the Bridge's chunks into frames and writes each again
from `Web::ParticipantView.event`'s allowlist, dropping every other event; only `from_seq` and `snapshot` reach the
Bridge; [internals/participants.md](participants.md#what-a-participant-sees)). Resume/ring-buffer state is **in-memory**, per worker: a cursor from
an earlier worker gets the `reset` snapshot, not a replay.
