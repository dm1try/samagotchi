# The working set: what the model really has

The stage view's working set (`web.working_set`, [cli.md](../cli.md#the-working-set)) shows the files, memories
and URLs a session's tool runs brought into the model's context, and model notes carried in the system prompt as
`prompt` rows. The page builds the set itself from its tool rows
(`working_set.js`, phase 1). The server says what the model still has of each item: **live**, **stale** (a file
changed since the model last saw it) or **forgotten** (nothing of it is still sent), and its size in tokens. This
page covers the server's side and how the page overlays it.

## Stamps: `tool_stamps`

`ToolRunner#run` stamps an ok `read`, `edit` or `write` (`result[:activity][:status] == "ok"`) with its file right
after the call: `ToolRun#stamp`, `{path:, mtime_ns:, size:}`. The path is the one `FileRef.for` gives (the call's
path against the session's folder, `File.expand_path`, no realpath). A stat that fails, or that isn't a file's (a
directory), gives no stamp; nor does any other tool.

An ok `memory_read` is stamped differently: `Tools::MemoryRead.call` returns a `Tools::MemoryRead::Result`, a String
with `reads` besides it - per name read, the file that answered and the model overlay appended to it, if any (KernelLoop
hands those to the runner as `result[:memory_reads]`). Its stamp is
`{memories: {name => {path:, mtime_ns:, size:, overlay: {…}, requested_scope:, model_key:, fallback_model_key:,
project_dir:}}}`, one entry per name, with no `mtime_ns` at its top. The request fields let the working set resolve
the name and overlay again with the same scope and model keys; an older path-only stamp keeps its original behavior.
That is compat N-1 in both directions: a reader that only knows file stamps (`WorkingSet.stamp_of` needs a top-level
`mtime_ns`) sees nothing in it, and a session saved before memory stamps has no stamp at all - either way its memories
are never stale. The working set marks a read stale if a different scope or overlay would answer now, or if the
stamped files changed; this includes a project memory appearing after an unscoped read fell back to system.
A `read`, `edit` or `write` of a memory's file is still a file item: the page has no memory row for that path, so
counting it as the memory comes with the page builds that map it too.

Both `ToolResponse` shapes save the stamps as `tool_stamps`, one per run, read by the run's place
(`ToolIds::Ref#run`):
- `ToolResponse.joined` (the native loop's batch entry): `runs.map(&:stamp)`, only when one is non-nil, like
  `tool_refs`.
- `ToolResponse.single` (the chat loop's entry for one call): `[stamp]`, a one-stamp array like its `tool_ids`.

`tool_stamps` is in `ToolResponse::SAVED_KEYS`, so `ChatLoop#plain` keeps it and no prompt or wire ever renders it
(the exclusion specs: `spec/llm/chat_loop_spec.rb` "a file run's stamp", `spec/kernel_loop_spec.rb`). After a
reload the stamp hashes have string keys; the projection reads both. A session saved before the stamps has none, so
its files are never stale.

The model's own successful `edit` or `write` stamps the file after it ran, so it never makes the file stale. Anything
else that changes it does: a later `execute` (`sed`, `git checkout`), the user's editor, another session. A failed
edit that changed the file anyway leaves the earlier stamp, so the file shows stale. On a filesystem with 1 s mtimes a
same-size edit in the same second goes unseen (APFS keeps nanoseconds).

A memory item follows chi's own changes too (`WorkingSet.build` passes the runs it already walked to
`WorkingSet::OwnChanges.from_runs`: no second walk; built only when a memory item needs it). A memory whose latest run
is a `memory_read` and whose stamped files differ stays `live` when every file that differs (the entry, its overlay)
holds chi's own later change: an `edit` or `write` of the file (its stamp), or a `memory_write` (by content, since
`memory_write` leaves no stamp). That is the heartbeat case, a memory read once and then edited all session. It runs
only after `memory_differs`' early answers: a name that now resolves to another file or overlay (a project `x` chi
wrote now shadowing the read's system `x`) or is gone stays `stale`, conservative. A memory whose latest run is a
`memory_write` is `stale` when the file it wrote (`<scope dir>/<name>.md`: system from `root`, project from the item's
read stamp's `project_dir`; a project memory only written has none and stays `live`) no longer holds chi's latest own
change of it (the write's content, or a later `edit`/`write` of the file by its stamp): one you edit after chi's write. A remove, an overlay write or a description-only write keeps today's `live`. Only a path
`MemoryGuard.memory_paths?` lets through is read: a stamp's file outside the memories folder counts as no own change
(stale, as before), never read. Cost in the worker: once any memory item's latest run is a `memory_write` (so every step
after a session's first one) or a memory item is found stale, one pass over the runs already in memory, testing the tool
name before anything else (about 0.1 ms at 350 runs on the Studio; testing `failed?` first, which copies each output,
cost about 1.5 ms); a stat per memory item already found stale, a `File.binread` per memory item whose latest run is a
`memory_write`.

## The projection: `WorkingSet.build`

`Samagotchi::WorkingSet.build(conversation, cwd:, strategy:, stat: File.method(:stat), pins: [])` (`lib/samagotchi/working_set.rb`)
is pure and returns a `WorkingSet::Snapshot` (`items`, `at`: the conversation's size in entries, the web's ordering
key). Each `WorkingSet::Item` is `kind` (`file`, `memory`, `url`), `key`, `state` (`live`, `stale`, `forgotten`,
`dropped`), `tokens`, `ops`, `count`,
`first_id` (the first run's ToolIds id), `pinned` (the session's `working_set_pins` name it, whatever the
strategy: the page shows the mark only under forget, so a switch shows it at once), `has_drop` (any of its content
outputs holds the user's applied drop, whatever the state: an undrop has something to take back) and, for a memory,
`scope`: the scope its latest `memory_read` answered from (the memory stamp's file, as `MemoryPart#scope` reads it;
`memory_item_scope`, no text read), in `to_h` only when known (nil for a memory only written, or read before memory
stamps). Cost: one field per memory item, from the stamp lookup the stale check makes anyway. Known limit: the set
has one item per memory name, so a session that read both a project `x` and a system `x` has one item carrying the
latest read's scope. The Engine's event and the GET
both pass the session's pins.

**Runs.** It pairs the runs twice with `LLMContextStale.paired_runs`: once on the stored conversation, once on what
`LLMContextView.new(strategy:).messages(conversation)` sends (stubs keep their `[name]` lead, so they still pair).
The two are matched by `ref.id`. The calls are the dispatched ones (`Tools::BuiltinCalls.build`), so aliases resolve
as the loops resolve them. A run that doesn't pair (a "ran as:" corrected call, an output holding the run separator)
is left out. So is a failed run (`LLMContextStale`'s rule: an `Error` after the `[name]` lead; a denied call's
`Error:` too) and an interrupted one (`ToolResponse.interrupted_text?`).

**Items** follow the page's `rowEntries`:
- `read`, `edit` and `write` give a file, keyed by its `FileRef` path; `read` adds op `read`, `edit` and `write`
  add op `edit`.
- `memory_read` gives one memory per name (`Tools::MemoryRead.parse_names`; an empty name, the index listing, gives
  none). A partial read ("a,b" where b is missing: the found bodies, then `Error: memory not found: b`) keeps the
  found names only, and its tokens are split evenly among them. The names come off that line alone
  (`WorkingSet::MISSING`): an orphaned-folder hint may follow it on the next line.
- `memory_write` gives the memory `call[:path]`, op `write`. A `remove: true` write stays in the set.
- `web_fetch` gives the URL with its whitespace collapsed.

**Tokens and forgotten.** Only content outputs (`read`, `memory_read`, `web_fetch`) carry tokens and decide
forgotten. Their tokens are the sent text's length over `TokenUsage::CHARS_PER_TOKEN`, so a stub costs what the stub
costs and kept lines count themselves. An image read counts its text only. `edit`, `write` and `memory_write`
outputs are short confirmations whose content sits in the call's arguments, which no strategy cuts: they add ops
and stamps, never tokens, and they never make an item forgotten.

An item is **forgotten** when it has content outputs and none of them is still sent under the session's *current*
strategy. A content output is still sent when:
- its sent text equals the stored one, or the stored one with the forget layer's `[#id] ` after its lead;
- no applied edit of a layer the strategy runs is saved on it (a staged edit doesn't count; an edit saved under a
  strategy the session has since left, such as `/llm-context strategy none`, isn't sent, so the output is live
  again);
- it is a forget that keeps lines (`forget_outputs keep:`);
- it is a stale stub an edit made ("superseded by a later edit", `llm_context.stale_edits`): the model wrote the
  file, so what it has of it is current.

A stale stub of an old read that a newer read superseded never strikes the file: the newer read is still sent. A file
only edited or written is never forgotten.

**Dropped** is a forgotten item whose content outputs all hold the user's applied `:drop` (the user's layer, sent
under every strategy: [llm-context-forget.md](llm-context-forget.md)), so it is dropped under any strategy and after
a switch. An item with one output dropped and another forgotten by the model is forgotten. Under none with no drop
saved the build doesn't pair the sent conversation at all (the view returns the stored Array). Such a mixed item
(one output dropped, another stubbed by the stale layer, or still sent) has `has_drop`: the listing says `part
dropped` and the page offers its undrop.

**Stale** is a file item whose latest run left a stamp, and whose file now differs from that stamp in mtime or size,
or is gone. A memory item goes the same way: the entry's file differs from the stamped one, or the model overlay
stamped with it does, or either is gone. No stamp, live. A forgotten item stays forgotten whatever its file did.

**An item's outputs.** `WorkingSet.outputs_of(conversation, kind:, key:, strategy:, cwd:)` answers an item's
content outputs (`WorkingSet::Output`: `id`, the tool_response entry's `index`, `derived` for a legacy entry's id,
`sent`, the rule above, and `shared_with`, the other names a `memory_read` of several holds there) in conversation order. It walks the runs exactly as `build` does (one shared
`all_touches`), so what acts on an item's outputs and the projection never disagree: an item is forgotten exactly
when it has outputs and none is `sent`. An edit-only item, a failed run's file or an unknown key has none; a
`memory_read` of several names is an output of each name.

**Cost.** Two `paired_runs` walks, one view build, a stat per file item and one per memory stamp. A 500-message
session builds in about 10 ms on an M5 Ultra and 75 ms on a CI runner; `spec/working_set_spec.rb` only guards
against a blow-up (< 400 ms).

## Delivery

**The event.** The Engine emits `{type: :working_set_updated, items:, at:}` (and `adds:` while the user's adds are
pending: [Steering: add and unadd](#steering-add-and-unadd)) (`Engine#emit_working_set`, `EventFanout`'s):
- after each `:generation_started`, in `build_stream_event_handler` (`EventFanout`), from the running turn's
  conversation (`Engine#live_conversation`, read on the turn's thread) under the turn's strategy
  (`TurnContext#settings`' `llm_context`; `EventFanout#working_set_llm_context`: the running turn's, the last turn's
  until it has its own). Both loops start a generation after `LLMContextApply.apply!`, so the set is
  what that request sends;
- once in `Engine#end_turn`, after `replace_session_messages` and before the end event, from the kept messages (the
  turn-end apply has run by then);
- between turns, from `Engine#announce_working_set` (the session's messages, under the event lock; after a
  `/working-set` op, after a `rollback_to`, and after an `/llm-context` change: the states are the next turn's strategy's): announced
  (`working_set_updated` is in `SessionObserver::ANNOUNCEABLE_EVENTS`; held after a command's `command_ran` inside
  `holding_announcements`), under the *next* turn's strategy (`SessionModelSettings#turn_llm_context`, as the
  turn-end warm-up reads it; `TurnSettings` keeps the last turn's, stale after `/llm-context` or `/model`). While a
  turn runs, the strategy is always the turn's.

It is emitted only when the set (its items and adds) differs from the last one emitted for the session (kept per
session id), and never while the set is empty (no items, no adds), so a tool-free turn on a fresh session emits nothing. One exception: when the last one had
items and the set is empty now (a rollback removed the tool calls), one empty event goes out, so the page drops the
stale items; it is remembered, so the next empty request sends none. `Engine#rollback_to` between turns (`!rollback`,
a canceled continue's restore, a failed turn's) announces the set at once (`announce_working_set`), so an emptied or
smaller set reaches the page then, not at the next request. It goes out whatever the web's flag;
the Bridge (`ClientEvent.project`) passes it on unchanged, and the attached TUI ignores it.

**The route.** `GET /api/sessions/:id/working_set` (`Web::WorkingSetRoutes#handle_working_set`, mixed into App) answers the snapshot's `to_h`
and `running`. With a live worker it builds from the worker's snapshot messages (as `handle_show` (`Web::SessionShow`) reads them, keys
symbolized) and the worker's `llm_context` summary. Without one it builds from the session file and its saved chip
(`SessionSetting::LLM_CONTEXT`); both through `working_set_source` (a `WorkingSetRoutes::Source`), which the item's
timeline route builds from too (Timeline, below). The folder is the session's `working_directory`. `running` is true when the
snapshot has a turn in progress (`current_turn`). Between turns, a newer worker's `idle_working_set` is used directly;
an older worker without that key still gets the file-build fallback.

**The GET while a turn runs.** A worker's snapshot messages are the session's, not the running turn's, so they lag
its events. The snapshot also carries `working_set`: the running turn's last `:working_set_updated` (`{items, at}`),
which the Bridge's `TurnAccumulator#working_set` folds from the event log. It is cleared at `:turn_started` and at
the turn's end, so it is nil between turns and before the turn emitted one. While a turn runs and it is set, the GET
answers it as is (no build, no stat): a page opened mid-turn gets the running turn's set at once, and its `at` is the
event's, so the page takes it (below). Before the turn's first event the turn's set is still the session's (the
Engine emits only a set that differs from the last one), and the GET builds from the messages as between turns; so
does one from an older worker without the field, its answer then behind the turn's events, which the page keeps.

**An item's timeline while a turn runs** (`GET …/working_set/item`, [Timeline](#timeline-what-the-model-has-of-one-item))
is the running turn's as of its last step, the moment the rows are from. At every `:generation_started`, on the turn's
thread and before the event goes out, `EventFanout#keep_turn_view` keeps a `TurnView`: a shallow copy of the running
turn's conversation (`conversation.map(&:dup)`, a new Array and each entry Hash dup'ed, strings shared), its size
(`at`), the set's strategy, the session's folder and the turn's id. Every step, not only when the set changed (an edit
or a forget changes what the model has without changing the rows). A copy, because the turn's thread writes entries in
place (`LLMContextEdit.store`'s `:edits`) while a Bridge thread reads; shallow is enough because every in-turn writer
changes top-level keys only (`LLMContextEdit.store`/`.remove`, the forget store, ChatLoop's `:interrupted`; KernelLoop
appends or pops; `spec/engine_working_set_spec.rb` pins it). Cost: about 0.02 ms and 32 KB for 200 entries, 0.03 ms and
82 KB for 500, one copy kept. `EventFanout#turn_view` hands it out only while its turn id is the running turn's (the
guard `Engine#live_conversation` uses), so a view left from another turn is never read; `Engine#end_turn` also drops
it (`EventFanout#drop_turn_view`) under the event lock as it puts the kept messages in place, before its
`:working_set_updated` and before the turn has ended, so no answer in that gap is the running view. `Engine#working_set_view` is
the conversation the set is built from now (that view, else a copy of the session's messages: a starting turn shares
their entries and writes them in place), read by `Engine#working_set_item`
(the Bridge's `GET working_set/item`, feature `working_set_item`: chi web asks a worker with it for just the item and an
older worker for its snapshot, as the route below says) and by `/working-set`'s listing (mid-turn the copy holds the
sent note, so no op is pending). The answer carries `at`, `running` and, mid-turn, `turn_id`. The page asks again only
when the open item's server signature changed (its `count`, `ops`, `tokens`, `state`, `has_drop`, `pinned`; a re-read
raises `count`), at the peek's refresh on an event and the reader's `onServer`; it drops an answer with a lower `at`
only within one running turn (`at` can go down at a turn's end, which keeps less). The peek asks `latest=1`
(`Timeline#peek_h`: only the events `peekOf` picks and the per-op `counts`); the reader the whole timeline.

## Steering: drop and undrop

`/working-set drop KEY…` and `undrop KEY…` (`WorkingSetCommand`, `SessionCommands#working_set`; the web's list posts
the same lines on `POST /api/sessions/:id/command`) act on the session's messages between turns: the line is
`mid_turn: :queue`, so one sent while a turn runs waits for its end (bare `/working-set`, the listing, is
`:anytime`). `WorkingSetSteer` does the work on a copy (`Engine#clone_messages`, then `LLMContextEdit.store`'s new
edits Hashes), which `Engine#replace_messages` puts in place; the session is saved, the rollback window closes
(`TurnFlow#note_conversation_changed`, as `!cmd`), the result says `changed: [:messages]` (the web reads the
conversation again) and `Engine#announce_working_set` re-emits the set, held behind the command's `command_ran`.

- **The outputs** are `WorkingSet.outputs_of` the item under the strategy the set is built under
  (`Engine#working_set_strategy`): the ones still `sent` get an applied `:drop` (`by: "user"`), the edit each held
  before kept in its `was:`. A drop's view is the user's layer ([llm-context-forget.md](llm-context-forget.md)).
  The reply weighs the batch (`LLMContextApply.weigh`: what it frees, the tail the server reads again).
- **undrop** takes the item's drops off and puts each `was:` back. Free when the drop never reached a request (its
  op is still in the pending note), else the reply says the tail.
- **Refusals** live on one exception, `WorkingSetSteer::Refused` (its `reason` and words): not in the working set;
  nothing to drop (only edited or written; only a legacy entry's derived ids; none of it sent now); already
  dropped; not dropped. `forget_outputs` uses the same words for a dropped output ("dropped by the user"): the
  model can neither forget nor restore it. A `memory_read` of several names is one output of each: dropping one
  name drops that read for the others too (an op acts on the output whole). `WorkingSet::Output#shared_with` names the
  others an output holds and `Done#shared_with` the ones an op took along; the reply says them.
- **The note**: the ops since the last turn are one tail system message, `kind: working_set` (in
  `Prompt::ESCAPED_KINDS`), its ops in `working_set_ops`. It is pending while only system messages follow it
  (`WorkingSetSteer.pending_note_index`); a later op joins it, and an inverse op (an undrop of a pending drop) takes
  both off, the note too when nothing is left. A turn that sends it makes it history; the next op starts a new one.

The projection shows a dropped item as `dropped` (below), the GET and the event alike.

## Steering: pin and unpin

`/working-set pin KEY…` and `unpin KEY…` run the same way (`mid_turn: :queue`, `WorkingSetCommand`), but a pin is
the session's, not an edit: `Session#working_set_pins` (a `WorkingSetPin` per item, `{kind, key}` as the projection
names it), a `SessionSetup` field, so a respawn (the file), a continue (`SessionSetup.of`) and a plugin's fork
(`host.setup`) keep it; a delegate child starts without. It changes nothing sent, so no cache break.

- **What it guards**: the model's `forget_outputs` (`LLMContextForget`, the `pinned:` callable `KernelLoop` hands it:
  `WorkingSet.pinned_ids` of the pins, the projection's pairing, so later reads of the item are covered). See
  [llm-context-forget.md](llm-context-forget.md). Not stale's stubs: a superseded read's newer read is sent.
- **`WorkingSetSteer.pin`** refuses an item not in the set and one already pinned (an edit-only item may be pinned:
  its later reads are covered). Pin and drop exclude each other: `drop` (given the pins) refuses a pinned item
  (`unpin_first`); `pin` takes a pending drop off first (an `undrop`, free, in `Done#undone`) and refuses a sent one
  (`undrop_first`). **`unpin`** asks only the pins (a rollback may have taken the item out of the set). The command
  puts the new list in place (`WorkingSetSteer.pinning`) and saves the session.
- **The note**: a pin or an unpin joins the turn-start note only when the strategy the set is built under has the
  forget layer (the model has no `forget_outputs` otherwise), or to cancel the inverse op the note lists. The reply's
  `changed` is `[:working_set_pins]`, plus `:messages` when the note (or a pending drop) changed; the rollback window
  closes only for `:messages`. Either way `Engine#announce_working_set` re-emits the set.
- **The projection**: `WorkingSet.build(…, pins:)` sets each item's `pinned`, whatever the strategy; the page shows it
  only under forget (below).

## Steering: add and unadd

`/working-set add KEY…` and `unadd KEY…` run the same way (`mid_turn: :queue`, `WorkingSetCommand`), but an add
changes nothing sent: it is a request in the turn-start note (D1 (a) of the plan), so the model runs the real
`read` / `memory_read` / `web_fetch` and the output is an ordinary tool run (stamps, ids, forget, stale, the
projection), on both loops. It costs one model step; a model may skip it (the note asks, chi doesn't run the tool).

- **`WorkingSetSteer.add`** refuses an item already added (pending), a URL not http(s) (`web_fetch` fetches only
  those), what the caller's `found` look says can't be read (`WorkingSetCommand#missing`: a file not there or a
  directory; a memory name `memory_read` rejects or that neither scope holds), an item holding the user's drop
  (`undrop_first`: undrop brings it back without a step), one already in the system prompt and with no working-set
  output (`in_prompt`: nothing to add; matched by name and scope, `Tools::MemoryRead.prompt_memory?` over
  `Engine#prompt_memories`, a bare name or an unscoped prompt entry by name only), and one the model has whole (`already_sent`: live, a read of it sent; a memory chi read and then changed itself
is live, so its add is refused as a file chi edited is). The
  prompt-only refusal doesn't apply when the set holds a read of that memory: a stale or forgotten item may still be
  added as the web row's `refresh`. **`unadd`** takes a pending add back (free); without one it is refused
  (`not_added`).
- **The note**: an add always joins it (`the user added lib/tax.rb, memory style to your context: before anything
  else, load them with read "/abs/lib/tax.rb", memory_read "style"`); a file is named by its absolute path in the
  call, since a `read` resolves a relative path against the process's folder. An unadd cancels its add there.
- **The projection**: the pending adds are not items (nothing of them is sent), but the snapshot carries them:
  `WorkingSet.pending_adds` reads the pending note (`WorkingSet.pending_note_index` / `pending_ops`, which
  `WorkingSetSteer` delegates to) into `Snapshot#adds` (`WorkingSet::Add`: `kind`, `key`, `label`), and `to_h` adds
  `adds:` while any is pending. `Engine#emit_working_set` (`EventFanout`, which keeps the last one emitted) compares
  the items and the adds, so an add announces a new set and the next turn's first request (the note sent, no adds)
  emits again, which clears the page's pending add.
  A running turn's set has none (the note was sent when it started), so the Bridge snapshot's `working_set` and the
  GET's `running` answer leave it out.

## Timeline: what the model has of one item

**The projection.** `WorkingSet.timeline_of(conversation, kind:, key:, strategy:, cwd:)` answers a
`WorkingSet::Timeline` (`kind`, `key`, `events`): every run of the item in conversation order, edits and writes too,
from the same `all_touches` walk `build` and `outputs_of` use, so the set, the steer and the timeline never disagree
on which runs are an item's. Each `WorkingSet::Event` is `tool_id` (ToolIds; `derived` for a legacy entry's), the
tool_response entry's `index`, the global `step` (`LLMContextStale::PairedRun#step`: the page's step tags are its own,
see below), `op` (`read`, `edit`, `write`, `memory_read`, `memory_write`, `fetch`), `sent` (the projection's
`still_sent?`; an edit or a write always), `dropped` (the user's applied drop), `forgotten` (not sent, not by a drop),
and what it holds:
- a read: `lines` (`WorkingSet::Lines`: `first`, `last`, `whole`, `partial`) from `LLMContextStale.file_run`, never
  re-parsed from the arguments: `last` is counted off the text, so an `end_line` past the file is clamped (its
  `[read: end_line …]` note is taken off the `text`); a whole read over `read.truncate_at_bytes` (the head/tail
  preview) and a ToolRunner-cut output are `partial`, shown as stored, kept out of the file strip and the merging.
  `text`: the stored output without its `[read]` lead;
- an edit or a write: `diff`, the saved `tool_diffs` (never re-diffed): `ToolResponse.joined` saves an array (one per
  run, nil for none), `.single` the bare Hash, read as `MessageParts` does. nil for a no-op or a failed snapshot, maybe
  `truncated`, `{skipped}` or `{error}`; `diff_view.js diffTemplate` draws them all;
- a memory_read: the whole output (a read of several names is not split: `shared_with` names the others, as
  `Output#shared_with` does), and `memory` (`WorkingSet::MemoryPart`, from the stamp): `scope` (a file under
  `memories/projects/<key>/` is the project's, else the system's), `path`, `overlay_path`, and for a read of one name
  the appended overlay's text (`overlay`, taken off `text`); nil for a session saved before memory stamps;
- a memory_write: the text it wrote (its `content` argument); a fetch: the output.

Merging overlapping reads, the newest-first order and the step tags are the page's (presentation): the page keeps
each row's `tool_id` with its place (`working_set.js` items' `runs`), so an event's tag is its row's (`t3·s14`) and
"go to the call" is the step tags' jump; a legacy row (no id) falls back to the server's global `step`. The file
strip's length is the largest last line any read knows (a whole read's is the file's then), not a stat. The page:
[web-frontend.md](web-frontend.md#the-working-sets-reader).

**Now.** `WorkingSet.memory_now(conversation, key:, …)` answers what the memory's latest `memory_read` would answer
now (`WorkingSet::Now`: `text`, `diff`, `gone`): each name that read read, from the file its stamp names, with the
overlay stamped with it appended as `Tools::MemoryRead.call` appends it (`Model-specific guidance (<key>):`, the key
off the overlay's file name), and a missing name's `Error:` tail kept; `diff` is `TextDiff.unified` of what the read
sent against that (`EditPreview`'s shape, so `diff_view.js` draws it; an empty `text` is "no change"). `gone` when a
file is; nil without a stamp. Each name is a `WorkingSet::Locator` of origin `:run` ([Prompt parts as sent](#prompt-parts-as-sent), The locator):
every name is resolved first (refused: nil; no entry answers: gone), then read, and `memory_now` keeps the join and
the diff.

**The route.** `GET /api/sessions/:id/working_set/item?kind=&key=` (`WorkingSetRoutes#handle_working_set_item`,
`:owner, :session`: a participant gets 403 from `not_permitted_for`) answers `timeline.to_h`, and with `&now=1` for a
memory `now:` too. A live worker that advertises `working_set_item` (`WorkingSet::ITEM_FEATURE`,
`WorkerLink.live_features`) is asked for just the item: the Bridge's `GET working_set/item` (`Engine#working_set_item`,
the query encoded with `URI.encode_www_form`, so a key with spaces or `&` arrives whole), its answer passed on with its
`at` and `running`; no snapshot is fetched and the session file is not read. No reply, or one other than 200 or 404, is
`502 bridge_error`: the page marks its ask failed and asks again at the next event, instead of drawing lagging messages
it would not ask again for. An older worker without the feature, or one answering 404 (no such route), is read as
before: `working_set_source` over its snapshot's messages; with no live worker the file's (no Bridge call). Either way
the session's strategy and folder. `&latest=1` (the peek) answers `Timeline#peek_h` instead: only the events
`ws_timeline.js peekOf` picks (the latest edit with a diff and the newest event after it, else the newest run that isn't
an edit), the per-op `counts` (`read`, `edit`) and `latest: true`. Its texts
are whole (about 1.7k lines at the most seen in real sessions): the tool limits bound them (`read.truncate_at_bytes`,
the ToolRunner cap), so the page asks this route, never a row's `output` (a 2000-char `ToolOutputCut::WEB_PREVIEW_CHARS`
preview for a long one). 400 without a known `kind` and a `key`.

## The page's overlay

The page keeps its row-derived items and their `at` (first entry) and `last` (newest touch) ordinals (the step
tags' jump path; `itemsOfTurn` moves `last` at every touch, `sessionItems` keeps the latest turn's), and overlays the server's
`state` and `tokens` by key (`working_set.js overlay`):
- files by absolute path (the row's `ref.path`; a title fallback won't match, so it stays live);
- memories by name;
- URLs by the row's key, which is its params preview with whitespace collapsed, cut at 80 characters with a "…".
  The "…" is stripped and the rest is matched as a prefix of the server's URL.

An item the server doesn't know yet (a running call) stays live. Known mismatch: live rows' refs resolve against the
worker's `Dir.pwd` (a real path), the server against `working_directory`, so a session under `/tmp` can miss
(`/private/tmp`).

`working_set_view.js` keeps one server snapshot per session; `working_set.js newerSnapshot` picks which. `at` can't
order them: a rollback (a canceled turn's `end_turn`, a failed turn's `TurnFlow` restore) shortens the conversation,
so the right set can have the smaller `at`. The page orders by what it saw instead:
- an event is always taken. The stream delivers them in the order the Engine built them, so the newest event is the
  server's latest set, a rollback's smaller (or empty) one too;
- a GET's answer is dropped when an event came while it was on its way (the view counts the events it took and
  compares the count at the ask with the count at the answer): the event may be newer;
- else it is taken, unless it is `running` and its `at` is smaller than the kept one's (it is behind the running
  turn's events: a GET built from the messages). A `running` GET answered from the turn's last event has that
  event's `at`, so it is taken. An idle GET after a rollback the page missed (a resync) or after a file changed wins at any `at`.

No server sequence: the GET is built in `chi web` from the worker's snapshot or the file, the events in the worker,
and a worker's event count starts over when it respawns; the page's own order needs neither. The page asks for it when it seeds a
session's set (load, resync) and when the list opens (a file changed while the session sat idle). The stream handler
passes `working_set_updated` to it, and does nothing when the flag is off. A new snapshot redraws:
- the session bar's chip and the open list;
- the footprints, in place (`refreshFootprints`, the same node; a `data-ws-sig` of the items' states skips an
  unchanged one). A footprint is a `<span>` in its block's summary line, `.turn-work > summary > .tw-sum`, before the
  steps' `.turn-steps`: drawn in the reload's template (`turnHistoryNodes`; a drawn turn's from its drawing's rows, `turnGroups`' steps), prepended at the hand-off
  (`stage_view.js handOff`, while the stage still hides the summary). A click there must not toggle the block:
  `details_motion.js` skips `.ws-foot`, and `footClick` cancels the click;
- the rail (`onServer`, the stage's `scheduleRefresh`).

**The list's lens.** The expanded list is always the session's set (`sessionSet()`), seen through a lens: `null`
(the session) or a turn's index (`createWorkingSet`'s `lens`). The chip (and the reader's `‹ Set`, `openList`) opens the
session lens; a footprint (`footClick`) and the rail (`openTurn`) open the lens on their turn. In a turn lens
(`working_set.js turnLens`, `lensItem`) the rows the turn touched are `lit` and the rest `dim` (`opacity:
var(--ws-lens-dim)`, a `:root` token in both palettes). A lit row is the session item's state, tokens and actions with
the turn item's `at`, ops and count (its step tag is the turn's, `s3`; a dimmed row keeps the session's, its last
touch, `t1·s3`; `rowTemplate` picks by the lens class, since a lit row carries the session's `last` too): the
turn item is passed through, the session item is never overwritten. The header's `session | ‹ turn N ›` steps over the
finished turns and the running one (`lastTurn()`), `‹` and `›` disabled at the ends; the line under it reads "turn N
touched A · B new" (new: the session set's first `at` is this turn's, a prompt memory never). A folded inner group
(`labelsTemplate`) shows its lit members while folded. A new seed that leaves the lens past the last turn, or a reset
that drops the running turn, puts it back to the session.

**The list's order** (`ws_order.js`). The popover's list only: the rail, the footprints and the reader's side list
(`items()`) keep the set's entry order. `recencyOrder` sorts the items newest `last` (else `at`: an older page's item)
first, by turn, step, row, stable on ties; an item with neither (a preloaded memory never read, a used memory no row
explains) goes after the rest in its order, so without parts too those memories end the memories. The order is
taken when the list opens (`show` with `opening`: the item keys, `openKeys`) and held while it is open
(`heldOrder`): an item not among them comes in on top, newest first, the others stay where they were drawn, one that
left the set is gone. The lens buttons, a refresh, a seed's redraw keep it; a footprint or the rail clicked while it
is open opens it again (`popover.open`), which takes it again; a close drops it. `bodySections` filters by kind and
`fold` puts a group at its first member's place, so a folded directory group stands at its newest member's place,
and a new file in a folder already grouped brings the group to the top (accepted: the group moves as one). A turn lens keeps
the order (lit rows light where they stand). The session lens's step tag (and a dimmed row's) is the last touch:
its text, its jump and its title ("last touched at turn N (prompt), step S"); a lit row's is the turn's entry.

**The head view: sections** (`ws_sections.js headSections`, drawn by `working_set_view.js headTemplate`). With the
session's `prompt_parts` (the worker's sizes of its system prompt; `promptParts` on the page) the list is what is in
chi's head, in three sections, drawn as Read, Conversation, From the start (every reader finds a section by its key):
- **From the start** (`start`): every part in prompt order, the tools part first. A memory part (identity, a model
  note, a preload) IS a memory row: merged with the session set's rows of the same memory, else a row of its own
  (identity: the set never lists it). **The match is scope + name** (`same`): the names match (`memoryName`, which
  also reads an older page's preloaded `system/x` as `x`) and so do the scopes (the part's `scope`, the item's from the
  server, `overlay`); a scope either side lacks (an older worker's part or item, an item the server hasn't stamped)
  matches by name alone, as before scopes. So a project `x` read beside a system `x` in the prompt is two rows: the
  read stays in Read as a plain read (not "prompt", never held twice), and the part's own row gets the key `x@system`
  (no collision with the read's `x`), its words its scope ("preloaded · system") and, like identity's, no actions;
  its ▸ is the prompt peek ([Prompt parts as sent](#prompt-parts-as-sent)). A note and a preload of one name and scope stay one row with both sizes; of two scopes, two rows. The start
  section tracks the items it shows by identity, not by key. It keeps the memory row's peek, state and the drop/pin rules of a preloaded memory (not
  droppable or pinnable until read). Its tokens are the part's, plus `+X` for the read's (the item's server tokens: a
  preloaded row carries none of its own, so the two never double-count). Other parts are read-only `part` rows: a
  label, a sub (the tools part's "N declared"; dropped on a phone), `~tokens`, no actions, and a ▸ that opens what chi
  was sent ([Prompt parts as sent](#prompt-parts-as-sent)); a turn lens dims them. Each start row carries the keys of
  the parts it stands for (`partKeys`, `partSizes`: a note also preloaded has two).
- **Read in this session** (`read`): today's files / memories / urls folds (`bodySections`), minus the memories the
  start section shows. Its meta: held (not struck) and out (forgotten or dropped); its tokens the held items'.
- **Conversation** (`talk`): one row at section level, "Conversation · N turns ~X" (`headSections` still returns the
  section; `headTemplate` draws it headerless, no fold; never lit, so dim in a turn lens),
  `ctxTokens − Σ parts − Σ held items' tokens` (the read
  section's and the start memories' reads), shown only when `ctxTokens` is known and the rest is > 0. Mixed units,
  accepted: parts and items are chars/4, `ctxTokens` the server's count or chi's estimate (which on a chat host leaves
  the tool schemas out, so without server usage the rest can go negative and the row hides); the "~" says so.

**Held twice.** A start memory row whose ops include `read` is held twice: in the prompt and in a read's output. The
session lens tags it `held twice` (warn tokens), and the start header counts them, folded or open (`· N held
twice`, the section's `twice`, in `--warn-text`: a span of its own after the meta, so on a phone the meta's ellipsis
cuts the meta first); a turn lens whose items read it lights it amber with a note under it:
"read again in this turn: already in the prompt, held twice (+X)". A lens lights a merged row by any of its merged
keys (`lensTouched`), and a part-only start row (no merged item, e.g. `x@system`) by its bare name too: a turn's rows
come from tool titles, which carry no scope, so in a turn lens a project `x` read lights a system `x`'s own row (lit,
not held twice: that row holds no read). A row with a merged item lights by its items' keys only. A turn lens counts
new over `headItems` (the set as the head view sees it: another scope's read is a plain read, not the prompt's), so a
project `x` first read beside a system `x` preload is new. It never counts a prompt memory as new (`promptKeys`, out of `turnLens`'s list). A forget or a
drop strikes the row where it stands (today's state words); the server knows an item's state now, not the turn that
changed it, so a turn lens has no forget count.

**Section folds.** Each section header folds (`data-ws="section"`), per session (`chi_ws_sections_folded:<session>`,
`session_prefs.js`); none stored: From the start folded, the rest open (`foldedSections(null)`; the view reads the pref
with no fallback, so nothing stored is told from a stored `[]`, which is all open). A stored list is used as it is, so
a session folded or opened by hand keeps that. Conversation has no header to fold: a stored `talk` (an older page's) is
ignored (`foldedSections`) and the next toggle writes the list without it. Folded, a section shows only the rows the lens lights (the read section's
lit members flat, without their inner groups). The header carries no size (the name, the lens, the ring
and ×: one line on a phone at 390 px); the line under it does. The session lens's: "in chi's head now · ~X of Y"
(`headLine`: X `ctxTokens`, Y the window; no "of Y" without one). Without parts or without `ctxTokens` that line is
the size line instead, "N items · ctx N %" (`.ws-size-line`), so the list never lacks a size; a turn lens has its
touched line only. The tokens-change check (`tokenText`) compares both lines' text. On a phone's sheet rows, section
headers and the lens buttons are 44 px targets.

**No parts** (an old session file, a worker before `prompt_parts`, a participant's list: `[]`): `headSections` is
null and the list is the flat files / memories / urls one with the lens unchanged. A turn end's `?tail=1` from an
older live worker leaves the key out: the page keeps the parts it has (`session_fields.js`: unknown is not none).

A state is the item's state now, not when its turn ran. A state change never refolds and never moves a line: the
rail's line key carries the label's state and its forgotten count, which are patched in place.

**Steering from the page.** The list's `drop`/`undrop` (and `undo`, `undo all`) post `/working-set` lines on the
command route (`createWorkingSet`'s `sendLine`). Pending ops are the queued lines (`command_queued` with `waits:
"turn_end"`, any client's, and the snapshot's `queued_commands` replay after a reload), parsed and netted by
`working_set.js pendingSteers` until each one's `command_ran`; a seed clears them (the replay brings them back).
A steer line names a file by its path relative to the session's folder (`state().dir`, the folder the worker resolves
it against) when inside it, else by its absolute path, so the command's bubble reads as the list does; the page keys
items by absolute path and reads a relative word of any client's line against the folder. A memory is `memory:NAME`, a URL by the server's full key; a key
with whitespace is quoted (`quoteWord`), and `steerWords` reads a line as the worker's `WorkingSetSteer.words` does
(`"…"` or `'…'` keeps its spaces, a backslash escapes the quote or itself). `dropped`
is in `STATES`: struck like forgotten, and a group is `dropped` when all its members are.
`overlay` carries the server's `pinned` and `has_drop` (as `hasDrop`; `undroppable`): a forgotten item holding a
drop offers only `undrop`, a live one `drop` and `undrop`, and neither offers `pin` (the worker asks for the undrop
first). A row offers `pin` only when the strategy the session's `llm_context` summary names (the ⚙ chip's context value)
has forget (`working_set.js forgetOn`, `pinnable`: not a muted, dropped or preloaded-only item). A `command_ran` that carries
`llm_context` redraws the open list (`strategyChanged`), so its pins come and go with the strategy at once. A pinned row shows
`📌` and `unpin` under any strategy (its drop is greyed, `dropRefusal`: "pinned by the user: unpin it first", the
exception's words, so it must keep a way out). A pending row hides its tokens and step tag (its pill and undo take their room) and its ops text gives way before
the name. A pending pin or unpin is dashed with `applies next turn`, and
`pendingSteers` nets it with its inverse; a pin queued after a drop stands for both (the worker's pin takes the
pending drop off). A drop queued after a pin, or of a pinned item, is one the worker refuses (`unpin_first`), so it
is never pending: the row keeps the pin's pill and undo (a pinned row its 📌 and a greyed drop with the refusal's
words).
The rail stays read-only but marks a line with a pending op: dashed, its title adding `drops next turn` (or `pinned
next turn`…; `working_set_rail.js pendingText`, a group's from its members). The view runs its `onServer` listeners
on a change of the pending ops too, so the stage redraws the rail with `pending()`.

**+ add from the page.** The list's foot is a form (`.ws-add`, the sheet's last row on a phone): one KEY as typed,
posted as `working_set.js addLine` (quoted when it has spaces). A stale row, or a forgotten one without the user's
drop (`refreshable`; undrop brings that back without a step), offers `refresh`: `/working-set add` of it. An add is
pending from two sources: the server's snapshot `adds` (an add made between turns runs at once, so no line is
queued; `serverAddIds`, passed to `pendingSteers` as the ops before any queued line) and a queued line mid-turn. An
`unadd` nets either; one with no add pending is never pending (the worker refuses it). An added item the session's
set doesn't hold is a row of its own under `adding · N` (`addedItems`: `+` glyph, `.added`, the server's label, the
same pill/undo and phone strip as any pending row); one it holds (a refresh) gets the `reads next turn` pill on its
row. The next turn's first request emits a set without `adds`, which clears them; a model that skips the read
leaves nothing behind. The rail adds a dashed `+ name · next turn` line per pending add its turn's set doesn't hold
(`working_set_rail.js addLabels`, inside the rail's budget), and `read again next turn` on a held line's title.

**Looks** (design spec §3, §5): a stale line is faded (`--ws-stale-opacity`: `.55` on the light palette, `.4` on the
dark one, where a lighter grey reads as plain secondary text; a footprint label `.55` on both); a forgotten one is struck in `--text-faint`
at `opacity: .5`. A group shows `✂n` for its forgotten members. It is struck only when all its members are
forgotten, and faded when all are stale or forgotten (`groupState`). The list's ops text says `stale` or `forgotten`
in words (colour is never alone) and shows `~1.2k` tokens per row (`tokensText`). A footprint adds `n stale` (plain; a file the turn's
end found changed shows there, the rail is gone by then) and `n forgotten`, struck. Titles add `(stale)` or `(forgotten)` per member.
The secondary text and the rail's rule read through their own tokens, a step brighter on the dark palette and the
base tokens on the light one: `--ws-faint` (the counts, the ops text, step tags; `--text-muted` on dark, `--text-faint`
on light), `--ws-muted` (the rail's head, the list's `files · n` rows, the drop/pin buttons; `--text-3` / `--text-muted`),
`--ws-rule` (the rail's left rule; `--border-strong` / `--border`) and `--ws-act-border` (the buttons' border).

## Prompt parts as sent

Every "From the start" row opens what chi was sent for its part: a slice of the prompt the session already keeps,
never a copy.

**The head and the places.** `Engine#turn_messages` puts the built prompt at `messages[0]`
(`ContextNote.with_system_head`: `{role: "system", content:}` with no `kind`, `ContextNote.system_head?`) and
`end_turn` saves it with the turn. Each `prompt_parts` entry says where it sits in that prompt (`PromptPart`, built by
`PromptLayout` beside the build): `at` (where its lead starts), `len` (lead included), `lead` (the length of what chi
adds before the item's own text: the identity line, a note's `## name`, the first note of a scope its heading, a
preload's "this memory is required … memory name: x" line, a file's header, a plugin's `From b (n):`, an index's
`Project memories:`; none for base, the kit and the volatile lines), so the slice is `head[at, len]` and the item's
own text `head[at + lead, len - lead]`. Joins between items fall in no span. `chars` is not `len`: a section's first
part is charged its joins. `digest` is 12 hex of SHA-256 over the item's own text, `head` 16 hex of the whole prompt
(the same on every part of a build). The tools part has a place only where the declarations are in the prompt: inside
the base text on a native non-Gemma profile (base's slice leaves them out, and so does its digest), after the
rstripped prompt on Gemma (an item running into the rstrip is cut at it); on a chat host they are a request field and
the part has none. `params` say how to fetch an item again: a memory's `requested_scope` (nil for a bare name),
`model_key`, `fallback_model_key`, `project_dir`, `system_dir` as the build read them; a file's `path`; the tools'
`[{name, chars}]` (chat: each schema's JSON; native Gemma declarations: each one's text; Qwen's one JSON list gives no
per-tool length, so names only). The items are recorded where the builders render them
(`SystemPrompt::Section#items`), so a place can't drift from the bytes. Cost: about 80 bytes a part plus 100–200 for
a fetchable part's params, 2–3 KB a session, in the file, every snapshot, reset frame and owner show; one SHA-256 of
the prompt and one per item per changed build.

**The key.** A part is named from the parts list alone: `PromptPart.keys` (`kind:ref`, the label without a ref,
`@scope` when it has one, `#n` for the nth repeat: a duplicate preload is `preloads:x#2`); `ws_sections.js startRows`
has the twin, both held to `spec/shared/prompt_part_keys.json`.

**The route.** `GET /api/sessions/:id/working_set/part?key=` (`WorkingSetRoutes#handle_working_set_part`, `:owner,
:session`: a participant gets 403, and `Web::ParticipantShow` sends no parts) reads the parts and `messages[0]` from
one source: a live worker's snapshot frame (`session_state_snapshot.prompt_parts`, `snapshot.messages`), else the
session file. No Bridge route, no worker feature: one session-file parse. `WorkingSetPart.answer` then: tools always
answer `{part, tools}` (names and sizes, saved with the part); otherwise case C's table, the first that holds winning,
its words in `WorkingSetPart::WORDS` (the page shows them as given, `note`, with a `reason`):

| # | Condition | `reason` | Source text under it? |
|---|---|---|---|
| 1 | the part has no `at`, a live worker of an older chi (its snapshot's `chi_version`; none said: older) | `older_worker` | no |
| 2 | the part has no `at`, no live worker or one of this chi (a fresh worker keeps the file's parts until a turn) | `older_chi` | no |
| 3 | `messages[0]` is not a system head | `no_prompt` | no |
| 4 | the head's digest differs from the part's `head`, a turn runs | `running` (`changed`) | yes, a fetchable part |
| 5 | the head's digest differs, idle (`!rollback`, a failed turn's old head, an older chi's run) | `idle` (`changed`) | yes, a fetchable part |

Else `{part, sent: {text, lead}}`. Mid-turn the snapshot's messages lag the turn, but parts are recorded at its start,
so the slice is exact unless the prompt was rebuilt (4). A memory file with invalid UTF-8 is scrubbed in the saved
head, so its session stays in 5: accepted.

**The locator.** Every "now" the working set shows is fetched by one resolver, `WorkingSet::Locator`
(`working_set_locator.rb`, `Data.define(:origin, :kind, :ref, :scope, :params)`; loaded only when a fetch runs, for the
testing kit's file budget): "where a held text came from and how to fetch it again". `#fetch` has three outcomes: nil
(refused, or nothing to fetch), a `WorkingSet::Now` with `gone`, a `Now` with its text (diff nil). `#composed` is the
same fetch with the files it read (`Locator::Composed`: `now`, `files` of `Locator::Source` `{path, role: :base |
:overlay, key}`, at most two); a gone prompt memory names the base it was sent from (identity's saved `system_dir`, a
preload's built `scope`'s folder, a note's `requested_scope`'s). A note's overlay is found by
`ModelNotes.overlay_path`, the build's own lookup (its label keeps the key as given). Its guard follows
`origin`, and the two stay apart:

- `:run`, a `memory_read` stamp's entry (`WorkingSet.memory_now`): resolved with chi web's own `MemoryPaths.system_dir`,
  any saved folder ignored; a path-only stamp (or one whose project folder is outside the root) reads its stamped
  paths; a `read:` stand-in reads the files.
- `:prompt`, a prompt part's `params` (cases 4 and 5, `&now=1`, the stale states): a memory resolves with the saved
  keys, `requested_scope` and folders only when the saved `system_dir` and `project_dir` are inside chi web's own
  `MemoryPaths.system_dir`, and every path it may look at (the files resolved; a note's file and each saved key's
  overlay, before any is stat'd) passes `memory_paths?`; identity and preloads through `Tools::MemoryRead.resolve` and
  `.compose`, a note through `ModelNotes.body_at` (the composers the build used, so an unchanged memory's text has the
  build's digest). An AGENTS.md is read only when it is on the session `working_directory`'s chain
  (`PromptFiles.agents_paths`, `PromptFiles.content`). An appended file is never fetched (as sent from the head only);
  base, the kit, a plugin's section, an index and the session lines are chi's own text: the line alone. Nothing is
  recomputed: no model key, no folder (a model switch rebuilds the prompt, so the saved keys describe the sent text).

The path guard both share is `WorkingSet::MemoryGuard` (in `working_set.rb`: `#build`'s stale check of a read memory
uses it at load). A file or URL row has no locator: its timeline is the conversation's text, and its stale check is a
`stat` against its stamp.

**Stale prompt parts.** `WorkingSetPart.states(parts, root:, cwd:)` names the parts whose source changed since chi
was sent it, `[{key, state: "stale"}]` (the stale ones only): a part whose locator fetches text with a different
`PromptPart.digest_of` from its saved `digest`, or finds the source gone. A digest covers exactly the text the fetch
returns, so it catches an edit, shadowing (a bare preload now answered by the project scope), an overlay added or
removed, and a file deleted (gone). It does not catch what changes which parts exist rather than a part's text: a
note that newly applies (or whose `models:` line no longer matches), a new AGENTS.md in the chain, a memory muted
after the build. Only fetchable kinds get a state (identity, preloads, notes, AGENTS.md): never an index (it changes at
every memory write), an appended file, chi's own text, or a part an older chi built (no digest). Cost: about 0.8 ms per
GET for 11 fetchable parts (the Studio, warm cache; `find_dot_git` is stat-only).

**chi's own change of a stale part (`by_chi`).** Given the same source's `messages` (and `running`),
`WorkingSetPart.states` adds `by_chi: {tool_id, step, op, current}` to a stale part chi changed itself; the state
stays `"stale"`. The own changes are `WorkingSet::OwnChanges` (`working_set_own_changes.rb`): the latest successful
change per file still in the stored conversation, so its text is still sent in the call's arguments (`op`
`memory_write`, `remove`, `write`, `edit`; `step` is `PairedRun#step`). A `memory_write` counts by its output: "saved
to SCOPE scope" (keyed scope + name), "Model overlay 'x' for KEY saved" (+ the key: the handler's model key, never an
argument), "removed from" (a remove; "its dangling index line was dropped" is none); never a description-only write
("(file unchanged)"), the index, or a failed, denied or interrupted run (`WorkingSet.failed?`). An `edit` or `write`
counts by its `FileRef` path and stamp. Each file the part was read from (`Locator#composed`, at most two) maps to its
latest own change: a memory's by the saved folder it sits in (`File.dirname(path) == dir`: a project's folder is
inside the system one), a file tool's by basename then `realpath`. A change is current while the file holds what it
left: a `memory_write`'s content byte for byte (`File.binread`; a model note's or an overlaid memory's text never
digests to its file, so the compare is per file), a remove's absence, an edit's stamp (`WorkingSet.differs?`).

`current: true` (the row's `✎ edited`) when every file holds chi's change or what was sent, and one holds chi's. "What
was sent" is the part's sent slice (`sent_of`, only when `messages[0]` is the head the parts were built with), split
with the text now at `Tools::MemoryRead.overlay_tail` (the overlay's key now, else the build's `model_key`, then
`fallback_model_key`): the base's text against the body, the overlay's against the tail, and no overlay now must mean
no tail sent (a project `x` chi wrote now answering a bare preload that was sent with a system overlay is stale). A
gone part is current only by chi's current remove of the base it was sent from. Otherwise, when chi changed one of the
files, `current: false` (it changed again after chi's change; or the head is not the build's, case C 4–5, where
nothing proves the other file unchanged). Rolled back (the call's entries gone, the file still chi's text), interrupted,
or someone else's change: no `by_chi`. A merged row (a note also preloaded) gets an answer per part.

An `edit` is checked harder than its stamp (a stricter reading of D2, the code review's M2): `edit` replaces its
`old_text` wherever it still matches, so it can land over a change chi never saw, and the stamp then holds. A part
whose current change of a file is an `edit` is current only when undoing chi's edits of that file, newest first
(`OwnChanges.undoes_to?`: each `new_text` found exactly once and put back to its `old_text`), reaches the sent side
exactly (stripped, as a prompt file is), or chi's own `memory_write` of it before those edits. Otherwise there is no
`by_chi`, so the row stays plain `stale` and the now tab shows the diff. A range edit (`start_line`), an empty
`new_text` or a `write` among them can't be undone: plain `stale` too. An `edit` or `write` with no stamp (an older
session's) gives no `by_chi`, never `current: false`. Read rows and file rows keep the stamp rule (D1, as file rows
always had).

Known limit: own changes have no build point. A write from before the prompt's build counts when the file comes back to
its text (chi writes A; someone writes B; a restart builds the prompt with B; someone writes A back): the row reads
`✎ edited` though the newer prompt says B. Rare; a session that recorded the message index of the head's build could
ignore earlier changes.

While a turn runs (`running`), only a `current: true` goes out: the GET's messages may lag the turn, so chi's newest
write may not be in them, and "changed again" could name chi's own change. A row chi changes in the running turn reads
`stale` until a GET's messages hold the write (D5); in the browser check (2026-11-22, the fake model) the row already
read `✎ edited` in a later step of the same turn, so the lag seems to be the writing step only (inferred, not traced in
the worker), and the hand-off's GET settles it either way. Guard: only the Locator's files are read (`binread`, `stat`); no path a call
or an output names is read, and an overlay key is `[a-z0-9-]+`. Cost: nothing new for a GET with no stale part; with one,
one `paired_runs` walk (about 3 ms at 600–750 messages on the Studio, about twice on the laptop), the messages'
top-level keys symbolized (`WorkingSetPart.symbolized`, shared with `working_set_source`), and at most two reads or
stats per stale part. A stale part stays stale for the worker's life, so each GET of such a session pays it.

The carrier is chi web's `GET …/working_set` alone: `handle_working_set` adds `parts:` for the owner whichever of its
three sources answered (the running turn's set, an idle worker's, a build from the file), from the parts the part
route reads (`#prompt_source`: the live snapshot frame's, else the file's), so a stopped session, a live idle worker
and an older (0.183.0) worker all get them. No field means none stale. No event field, no worker change; a
participant's answer never has it (`ParticipantView.working_set` rebuilds `{items, at}`). The page asks the GET each
time the list opens. A `:working_set_updated` event carries no parts: the page keeps the session's last GET's states on
the event's set (`working_set_view.js takeServer`), and a GET an event overtook still gives its parts. The page asks
the GET again when the session's parts are rebuilt (their heads or digests change, `sessionChanged`) and at a turn's
hand-off when it holds states or the list is open, so a rebuilt prompt's states go.

Stale lasts in a live worker until chi rebuilds its prompt: `SystemPrompt#built_for` caches the build until
`#reset!` (a model switch, a participants change, a plugin's `prompt_changed!`, a toolkit change). An outside edit,
and chi's own `memory_write` of a preloaded memory, do not reset it, so the worker keeps sending the old text across
turns until one of those or a restart. Someone else's change reads `stale`; chi's own (a current `by_chi`) reads
`✎ edited`, since the new text is in chi's conversation; while the turn that made it still runs it may read `stale`
until a GET's messages hold the write (see `by_chi` above).

**The source now.** `GET …/working_set/part?key=&now=1` adds, beside the sent slice, `now: {text, diff, gone}`: the
locator's text (scrubbed to valid UTF-8 before JSON) and `TextDiff.unified` of the sent text against it (nil when
gone), and `rebuild`: when chi's prompt gets the source now, `restart` with a live worker (it keeps its prompt until it
is next built) or `next_turn` without one (the next turn builds it). Under cases 4 and 5 the answer stays as above (the
source now, no diff: nothing sent to diff against; no `rebuild`, their words say when). Parts without a locator have no
`now`. An older chi web sends no `rebuild`, and the page leaves its line out.

**The page.** `ws_part_peek.js` (made by `ws_reader.js` with the reader's markdown cache, handed to the view as
`peek.part`): the peek's head "in the prompt · sent with every request", the text (a memory's and an `.md` file's
rendered), chi's lead folded under "chi adds a line before it", no foot buttons; tools as names and sizes; case C's
line with the source now under it. A row of several holds gets one tab per hold, its kind and size (`note · ~0.9k`,
`preload · ~1.2k`, `in the prompt · ~1.4k`), and `read · t1·s1` for an item that was read: the item peek, first. One
peek open at a time. The popover is 520 wide open or closed.

The GET's `parts` reach the start rows as `headSections`' `states` option (`startRows`: `partStates` beside
`partKeys`, `partStale` when one is). A stale row says `stale` in `--warn-text` (`.ws-pstale`) in place of its words,
which move to its title ("model note · changed after chi's prompt was built"); a memory row whose read is stale too
still says one `stale`, its title and its now tab naming both ("read changed · prompt text changed"). Its peek gets a `now · changed` tab right after the stale hold (`warn`):
the `&now=1` answer, drawn as "<label> changed after chi's prompt was built" with the diff's `+a −d` and
`diff_view.js`'s diff ("no change" once it was edited back), or "Its source is gone now." It opens first unless the row
has a read. No new export: an older `ws_sections.js` ignores `states`, and the 0.183.0 page ignores the field.

**chi's own change on the page.** The view reads the GET's `by_chi` itself, off `server.parts` (`working_set_view.js
ownRow`: an older cached `ws_sections.js` has no `partKeys`, build 2's maps states to `"stale"` or none): a stale part
whose `by_chi.current` is true becomes `"edited"` in the row's `partStates`, and a row none of whose parts is still
stale is edited. It reads `✎` (the file rows' `.e`), then `<span class="st ws-pedited"><span class="ws-pwords">preloaded
· </span>edited</span>` (`removed` for a remove) in `--text-2`, not the warn colour; for AGENTS.md `project instructions ·
edited`. Its title: "preloaded · chi edited it at turn 3, step 2: the new text is in its conversation; its prompt
still sends the old text until it is next built" (a remove: "… chi removed it at turn 3, step 2: its prompt still sends
it until it is next built"). Its tag after the tokens is the call's place, found by `tool_id` over every turn's items
(`ws_timeline.js placeOf`), drawn as the read rows' jump (`.ws-step.ws-own`, `data-ws="jump"`); without a place, a
plain `step N` (the server's step). A memory row whose read is stale says the read's `stale` as before; the
both-causes words ("read changed · prompt text changed") need a read op, so a memory chi only wrote and someone changed
after reads "changed after chi's prompt was built" (its item is stale by D1, faded). A row whose part carries `by_chi`
and whose item has no read gets no `read` tab (the item peek of chi's write): its edited tab, or its now tab with the
"chi edited it at …" line, opens first. In a turn lens the call's tag replaces the lit row's step tag. A merged row
(a note also preloaded) stays `stale` while any part is stale without a current change; each part gets its own tab.
On a phone's sheet the part words go (`.ws-popover.sheet .ws-pwords{display:none}`, D7): `✎ edited` alone, the name
keeps its room; a part row keeps `edited` where it drops its sub text, and the tabs wrap.

The peek (`ws_part_peek.js`) gives an edited part the tab `edited · t3·s2` (`removed · t3·s2`) right after its hold, in
place of the now tab; it opens first unless the row has a read. Its body is the `&now=1` answer: the head "chi edited
`<label>` at t3·s2" with the diff's `+a −d`, the diff sent → now, and one line, "Its prompt still sends the old text with
every request; chi has the new text from its edit.", followed by "The prompt gets it when it is next built (a restart,
a model switch)." (`rebuild: "restart"`) or "The prompt gets it when it is next built (at its next turn)."
(`"next_turn"`); none without `rebuild`. A remove's tab: "chi removed it at t3·s2; its prompt still sends it until it
is next built." A stale now tab gets the rebuild line under the diff: "chi gets the new text when its prompt is next
built (a restart, a model switch)." or "chi gets the new text at its next turn."; with `by_chi.current === false`,
above it (warn) "chi edited it at t3·s2; it changed again after that.". The words are constants beside `BOTH_CHANGED`
(`REBUILD_LIVE`, `REBUILD_NEXT`, `STILL_SENT`, `PROMPT_GETS`). No new export: an older cached peek given `"edited"`
sees no stale and shows the sent text only (`v0.183.0` has no `ws_part_peek.js`, so that pairing gets a fixture once
0.184.0 is tagged); the 0.183.0 page and view ignore `by_chi`; a new page against an older chi web (no `by_chi`, no
`rebuild`) draws build 2's stale with no rebuild line.

**Compat.** An older page ignores the fields and the route; a build-2 page maps any state but `"stale"` to none, so
`by_chi` rides beside `state: "stale"` (no new state value) and such a page draws today's `stale`; an older chi reading a newer file drops the fields
(`PromptPart.from_h`), and its own save drops them (cases 1–2). The corpus's `compat-prompt` session has a head and
placed parts (`ReleaseTools.write_compat_corpus!`, read in `spec/compat/readers_spec.rb`); in the wire samples the head
is `CompatWire::SYSTEM_PROMPT`, so the digest never matches and a wire reader asserts the fallback.
