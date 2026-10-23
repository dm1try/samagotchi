# The working set: what the model really has

The stage view's working set (`web.working_set`, [cli.md](../cli.md#the-working-set)) shows the files, memories
and URLs a session's tool runs brought into the model's context. The page builds the set itself from its tool rows
(`working_set.js`, phase 1). The server says what the model still has of each item: **live**, **stale** (a file
changed since the model last saw it) or **forgotten** (nothing of it is still sent), and its size in tokens. This
page covers the server's side and how the page overlays it.

## Stamps: `tool_stamps`

`ToolRunner#run` stamps an ok `read`, `edit` or `write` (`result[:activity][:status] == "ok"`) with its file right
after the call: `ToolRun#stamp`, `{path:, mtime_ns:, size:}`. The path is the one `FileRef.for` gives (the call's
path against the session's folder, `File.expand_path`, no realpath). A stat that fails, or that isn't a file's (a
directory), gives no stamp; nor does any other tool.

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

## The projection: `WorkingSet.build`

`Samagotchi::WorkingSet.build(conversation, cwd:, strategy:, stat: File.method(:stat), pins: [])` (`lib/samagotchi/working_set.rb`)
is pure and returns a `WorkingSet::Snapshot` (`items`, `at`: the conversation's size in entries, the web's ordering
key). Each `WorkingSet::Item` is `kind` (`file`, `memory`, `url`), `key`, `state` (`live`, `stale`, `forgotten`,
`dropped`), `tokens`, `ops`, `count`,
`first_id` (the first run's ToolIds id), `pinned` (the session's `working_set_pins` name it, whatever the
strategy: the page shows the mark only under forget, so a switch shows it at once) and `has_drop` (any of its content
outputs holds the user's applied drop, whatever the state: an undrop has something to take back). The Engine's event and the GET
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
  found names only, and its tokens are split evenly among them.
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
or is gone. No stamp, live. A forgotten item stays forgotten whatever its file did.

**An item's outputs.** `WorkingSet.outputs_of(conversation, kind:, key:, strategy:, cwd:)` answers an item's
content outputs (`WorkingSet::Output`: `id`, the tool_response entry's `index`, `derived` for a legacy entry's id,
`sent`, the rule above, and `shared_with`, the other names a `memory_read` of several holds there) in conversation order. It walks the runs exactly as `build` does (one shared
`all_touches`), so what acts on an item's outputs and the projection never disagree: an item is forgotten exactly
when it has outputs and none is `sent`. An edit-only item, a failed run's file or an unknown key has none; a
`memory_read` of several names is an output of each name.

**Cost.** Two `paired_runs` walks, one view build and one stat per file item. A 500-message session builds in about
10 ms on an M5 Ultra and 75 ms on a CI runner; `spec/working_set_spec.rb` only guards against a blow-up (< 400 ms).

## Delivery

**The event.** The Engine emits `{type: :working_set_updated, items:, at:}` (and `adds:` while the user's adds are
pending: [Steering: add and unadd](#steering-add-and-unadd)) (`Engine#emit_working_set`):
- after each `:generation_started`, in `build_stream_event_handler`, from the running turn's conversation
  (`Engine#live_conversation`, read on the turn's thread) under the turn's strategy
  (`@kernel.turn_settings.llm_context`). Both loops start a generation after `apply_llm_context!`, so the set is
  what that request sends;
- once in `Engine#end_turn`, after `replace_session_messages` and before the end event, from the kept messages (the
  turn-end apply has run by then);
- between turns, from `Engine#announce_working_set` (the session's messages, under the event lock; after a
  `/working-set` op, after a `rollback_to`, and after an `/llm-context` change: the states are the next turn's strategy's): announced
  (`working_set_updated` is in `ANNOUNCEABLE_EVENTS`; held after a command's `command_ran` inside
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

**The route.** `GET /api/sessions/:id/working_set` (`Web::App#handle_working_set`) answers the snapshot's `to_h`
and `running`. With a live worker it builds from the worker's snapshot messages (as `handle_show` reads them, keys
symbolized) and the worker's llm ctx chip. Without one it builds from the session file and its saved chip
(`SessionSetting::LLM_CONTEXT`). The folder is the session's `working_directory`. `running` is true when the
snapshot has a turn in progress (`current_turn`).

**The GET while a turn runs.** A worker's snapshot messages are the session's, not the running turn's, so they lag
its events. The snapshot also carries `working_set`: the running turn's last `:working_set_updated` (`{items, at}`),
which the Bridge's `TurnAccumulator#working_set` folds from the event log. It is cleared at `:turn_started` and at
the turn's end, so it is nil between turns and before the turn emitted one. While a turn runs and it is set, the GET
answers it as is (no build, no stat): a page opened mid-turn gets the running turn's set at once, and its `at` is the
event's, so the page takes it (below). Before the turn's first event the turn's set is still the session's (the
Engine emits only a set that differs from the last one), and the GET builds from the messages as between turns; so
does one from an older worker without the field, its answer then behind the turn's events, which the page keeps.

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
  (`undrop_first`: undrop brings it back without a step), and one the model has whole (`already_sent`: live, a read
  of it sent). A stale or forgotten item may be added: that is the web row's `refresh`. **`unadd`** takes a pending
  add back (free); without one it is refused (`not_added`).
- **The note**: an add always joins it (`the user added lib/tax.rb, memory style to your context: before anything
  else, load them with read "/abs/lib/tax.rb", memory_read "style"`); a file is named by its absolute path in the
  call, since a `read` resolves a relative path against the process's folder. An unadd cancels its add there.
- **The projection**: the pending adds are not items (nothing of them is sent), but the snapshot carries them:
  `WorkingSet.pending_adds` reads the pending note (`WorkingSet.pending_note_index` / `pending_ops`, which
  `WorkingSetSteer` delegates to) into `Snapshot#adds` (`WorkingSet::Add`: `kind`, `key`, `label`), and `to_h` adds
  `adds:` while any is pending. `Engine#emit_working_set` compares the items and the adds, so an add announces a new
  set and the next turn's first request (the note sent, no adds) emits again, which clears the page's pending add.
  A running turn's set has none (the note was sent when it started), so the Bridge snapshot's `working_set` and the
  GET's `running` answer leave it out.

## The page's overlay

The page keeps its row-derived items and their `at` ordinals (the step tags' jump path), and overlays the server's
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
  unchanged one);
- the rail (`onServer`, the stage's `scheduleRefresh`).

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
first). A row offers `pin` only when the strategy the session's `llm ctx` chip names
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
dark one, where a lighter grey reads as plain secondary text; a footprint label `.55` on both, its text already faint); a forgotten one is struck in `--text-faint`
at `opacity: .5`. A group shows `✂n` for its forgotten members. It is struck only when all its members are
forgotten, and faded when all are stale or forgotten (`groupState`). The list's ops text says `stale` or `forgotten`
in words (colour is never alone) and shows `~1.2k` tokens per row (`tokensText`). A footprint adds `n stale` (plain; a file the turn's
end found changed shows there, the rail is gone by then) and `n forgotten`, struck. Titles add `(stale)` or `(forgotten)` per member.
