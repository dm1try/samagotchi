# Session objectives

A session's objectives are a short list the user types: what this session is to achieve. The first version is a
try-out, so each piece can come out alone. There is no new message kind or store: the list is a note in the
conversation and the command writes a note file. Terminals show the default note bubble; the web draws it
([The page](#the-page)). For the user's side, see
[sessions.md](../sessions.md#objectives) and [cli.md](../cli.md).

## The object and the entry

`Objectives::List` holds `Objectives::Item`s (`id`, `text`, `status` active|done|dropped, optional `done_when`) and the
number the next id takes. That number only grows, so an id is never reused, not after a drop or a `set`. `done_when`
is a hint, never enforced.

Each edit is a whole new list in one note entry:

```ruby
ContextNote.message(note_id:, text: list.text, source: "objectives", header: ContextNote::OBJECTIVES_HEADER,
                    objectives: list.to_payload)
```

- `objectives` is one key in `ContextNote::KEYS`, so everything that copies a note field by field keeps it
  (`ChatLoop#plain`). A note is also what `take_initial_prompt` and `TurnFlow#restore` already handle, which is why
  this isn't a new kind.
- The payload is `{"next" => 3, "items" => [{"id", "text", "status", "done_when"}]}`, in string keys before a save and
  after one (`List#to_payload`). `Objectives.from_payload` reads either style.
- It is never sent. The wire gets role and content only, and the frame instructs by itself:

  ```
  [OBJECTIVES, set by the user. What the user wants this session to achieve; replaces any earlier list. Keep work on it. Say when something falls outside it. Don't change it yourself.]
  O1 [done] Two coffees, open the cart
  O2 Stops before checkout (done when: no order is placed)
  [END NOTE]
  ```

  A dropped item is left out of the text, and a list with nothing left says `(no objectives now)` so that it still
  replaces the one before it. The frame has no clock, and there are no system prompt lines about it, so a session with
  no list adds no note and no prompt line. It still carries the tool's bytes ([Moves](#moves)).

A note body isn't escaped when it is saved, and a system-role note reaches the model as it stands, so outside text
could carry a line that looks exactly like this frame. On the wire, `Steer.wire_text` leads such a line with `(quoted) `
(`Steer::FORGED_OBJECTIVES`). That covers every entry with a kind, on both loops: a context note, a peer's `send_note`,
`chi note`, a delegate report, a steer. A participant's message gets the wider `FORGED_OPENINGS`. The real note is
known by its `objectives` payload key, never by its text. The saved content stays raw, the rewrite is deterministic,
and text with no such line goes out byte for byte, so the prompt cache holds. The owner's typed prompt has no kind and
isn't touched. Tool output isn't covered: it goes out as a tool result, not as a system message.

A payload whose `next` isn't an Integer or whose `items` isn't an Array is not a list (`from_payload` answers nil), so
it can't wipe the fold or restart the ids.

## The current list

`Objectives.build(conversation, pending:)` is a pure fold over the entries, shaped like `WorkingSet.build`: the newest
list note wins, and a pending payload wins over that, because a file not yet absorbed is newer than anything in the
conversation. `Objectives.pending_payload(session_dir)` finds the newest objectives file among the notes;
`Objectives.current` is the two together.

`build` also fills `List#moves`, the latest `Objectives::Move` per id ([Moves](#moves)). Moves are never in the frame or
the payload, so an edit and a continue carry none: a new link starts with no last move.

## Editing

`/objectives` (`ObjectivesCommand`, registered `anytime`) reads `Objectives.current`. An edit goes out through
`NoteDelivery.deliver(objectives:)`, which means:

- One edit's read and write are one step (`Objectives.with_lock`, a file lock in the session's folder, across threads
  and processes), and the worker's absorb holds it from its claim to the files' delete, so no edit reads between them.
  Each note holds a whole list: without this, two edits that read the same list lost one.
- `done` refuses a dropped item, and `undo` puts an item back to active.
- A part with no text of its own refuses the line. An empty done-when is none, and of two done-when groups the last
  counts. A leading `[done]`, `[dropped]` or `[active]` is stripped, so a text can't pass for a status. Any whitespace
  collapses, Unicode line separators too, so each item stays one line of the frame.
- It never writes session.json and runs on any thread: it only adds a file to `notes/`.
- It is refused in a session a chi REPL owns (`--no-shared`), with the reason `chi note` gives
  (`NoteDelivery::REPL_REFUSAL`). A show still answers there.
- A second edit stacks on an unabsorbed first, since the current list reads the pending file.
- `WorkerInbound#absorb_notes` adds only the newest list in a batch and deletes the others, so edits made during a
  turn cost one entry. It runs between turns: an idle edit lands at the worker's next pass (the fallback tick, or just
  before the next turn), and a mid-turn edit waits for the turn's end. A long coordinator turn is the known gap.

The attached TUI and the web composer send the line like any session command (the registry's listing tells them it
runs mid-turn too). So does `chi send -m "/objectives …"`. A participant's command is refused as any other is.

## Moves

The `objectives` tool (`Tools::ObjectivesTool`, schema last in `TOOL_SCHEMAS`) has one action, `move`: `id`, `note`,
optional `evidence`. A call with no `action` is a move too. It is information only: nothing is written, and the call in
history is the record. A handler can't append an entry mid-turn safely, and a system entry would split a call from its
response, so there is no new entry kind. `Objectives.moves_in` reads the calls back with
`LLMContextStale.paired_runs`, as `WorkingSet` does: both hosts' forms, a `call_tool` of it as it ran. A run whose output
counts only if its output is the tool's answer that it recorded that id (`ObjectivesTool.recorded?`): a call with no list,
a refusal, a denial or an interrupt recorded nothing. A rollback that drops the turn drops its moves.

Mid-turn, `session.messages` doesn't hold the running turn. `/objectives` adds the loop's own conversation
(`Engine#live_conversation`, a `dup` read on the command's thread), because `Engine#plugin_messages`' running part (the
Bridge's `TurnAccumulator#current_messages`) leaves tool calls out. A move shows once its result is in.

- **The answer** says it recorded a move, that the list is unchanged and that the user edits it with `/objectives`; so
  does the schema's description. Other actions get an `Error:` with the same sentence. A small model told to edit the
  list has nothing to call, and this is the only place it is told so: no stable-prompt line.
- **No list**: `There are no objectives here…`, not an error, for a delegate (its fold is empty), a session with no list
  and a kernel without a session (`Tools::Peers#objectives` is nil; `Engine::PeerView#objectives` reads the session).
- **Refused**: an unknown id, a dropped objective, an empty note. A `done` objective takes a move.
- **Declared**: on `full` (`all_core`) and on the coordinator kit (its bundle adds it); named in the not-loaded line
  elsewhere, and so counted in `find_tools`' chi line, and among the deferred tools on a host that loads tools.
- **Cost**: one extra generation when the move is the step's only call, none when it comes in a batch with another call.
- **Guardrails**: no rule names it, so it passes with no ask, in `strict` too. `ReviewBoundary` denies it as anything
  outside its kit. `PairBoundary` denies it as owner-voiced: a move stays in the owner's history and reads as the
  session's own.
- **The row**: `recording a move` in the TUI's line with `id=`, `note=`, `evidence=`; the web's row is `objectives O2 note · evidence`
  (`ToolActivity#tool_title`). No UI of its own.

`serves` on `ask_user_question` waits until moves read well. The model can't edit the list.

## Proposals

`action: propose` (`change` add, reword, done or drop; `id`; `text`; `note`, why) checks the change against the list
(`Objectives::Proposal#refusal`) and hands it to `Engine#propose_objective`, which keeps it until the turn is over,
as `#context_choice`'s cards are kept: shown in `run_turn`'s ensure, it is a between-turns card (no `in_turn`), so it
writes no `pending_card.json`, the stage doesn't say it waits, and it keeps its buttons over a restart (`CardStore` takes
them only from a card shown in a turn). The same change twice in a turn is one card. A P3 finding stands: a card action
can't carry a plain reply, so an action here is a real edit.

Apply is `/objectives --card ID done O2`: the proposal's own line (`Proposal#line`) behind a prefix the command reads
(`ObjectivesCommand::CARD`), so it goes through the one route, with its refusals. On success the card with that id is
replaced by a one-line notice. Dismiss (`--card ID dismiss`) only folds it. Either is recorded under the lock
(`objectives_cards.json` in the session's folder), so a repeat, from a stale tab or a second tap, applies nothing: it
says the proposal was already applied and folds the card again. A reword carries what it was proposed against
(`--was`, `Objectives.fingerprint`) and is refused when the item has changed since. It keeps the item's done-when unless its text
brings its own. The page keeps a proposal card's buttons off until the folded card comes or the action fails
(`cards_place.js actionFailed`). A turn leaves at most `PROPOSALS_PER_TURN` (3) cards; past that the tool says so. A refused edit leaves the card, and its
`command_ran` shows the refusal. Nothing is recorded as a move (`recorded?` is positive); the call stays in history as
any call. An add's text can't split on ` | `. The body names the line, for a terminal, which shows no button.

## The page

`Objectives.view` (`List#to_view`) is what the page draws: the items, each with its last move, and `pending`, whether
the newest list is a file still waiting. The session read (`objectives`, no key with no list) and the live
`:objectives_updated` carry it. `Engine#announce_objectives` emits when the view differs from the last: after an edit,
once a list note is in (`add_context_note`), at a turn's end (its moves) and after a rollback between turns. A session
with no list emits nothing. Between two tabs that is all it takes. A participant gets neither: the event is in
`ParticipantView::DROPPED`.

Idle, an edit lands at once: the worker's anytime path wakes the loop (`@waker.wake`, one extra pass for any anytime
command), which absorbs the file. It no longer waits for the fallback tick.

- **The wiring** (`objectives_wiring.js`): the routes the strip and the moves post on, each following a woken worker
  only while the page still shows that session.
- **The strip** (`objectives_strip.js`, `#objectivesStrip`; pure parts in `objectives_model.js`, CSS in
  `objectives.css`). A factory with its own closure (the list; never `store.current`), seeded by `renderSessionView` and reset
  by `forgetSession`. Its edit list is a `chip_popover.js` shell, so a phone gets the bottom sheet and the focus rules.
  Every edit is a line on the command route with `card: true`: no echo, and `commandView` hides a good `/objectives`
  answer that came with that mark, so a tap leaves no bubble, a refusal does. The strip redraws from the event, never
  optimistically.
- **The entry** (`objectives_entry.js`, from `turn_html.js noteBubbleTemplate`): `Objectives.entry` puts the note's items
  and, against the list before it, `changes` (`Objectives.changes`, display only) on the history item and on
  `context_added`. A first list is pills; a later one a line, `You marked O1 done`. The raw text stays the tooltip.
- **Moves** (`objectives_moves.js`): a tool row's id is a chip (`moveRowText`), and a row that recorded a move carries
  `data-move-id`. One observer on `#history` reads those back into a line after each finished `.turn-work`, so a reload,
  a live end and a hand-off all draw it. The newest line's Not yet is `objectivesStrip.notYet`. A decision card's
  `Concerns O2` gets the chip there too.
- **Not yet** is `POST /turn` with a client id of its own (`<tab>:objectives`), so the stream draws its bubble in every
  tab, this one too: the page's own echo needs the composer. It steers a running turn or starts a turn, as a typed line.
- **Short version**: the same observer offers `/short` (decision-card) under the newest long answer (`foldable`), only with a list
  and with the command in the session's listing, and not during a turn: `/short` itself refuses then, since a running
  turn's "last answer" is interim text. A request that fails, or a worker that leaves with one still out (the bundle's service
  stops after chi's 3 s wait for a command), ends the card saying so; a worker killed outright leaves its one-line `…` row.

## Continue, rollback, fork

- **Continue**: `Objectives.carry`, in `SessionContinue`'s `before_spawn`, writes a second note file in the new link,
  after the carry note and any moved context's note, so the list reads as the latest word. It is not in
  `SessionChain.note_text` (capped; the last answer gets what the recap leaves). It reads the previous link fresh,
  with its unabsorbed newest file. A failure is only logged (`continue_objectives_failed`), because it runs inside the
  continue's rollback. A review link's list stays behind, as its last answer does: the next link's participants could
  differ.
- **Rollback**: a note survives `TurnFlow#restore`, and an unabsorbed edit is on disk, untouched.
- **Fork, delegate**: a plugin fork copies what it is passed. A delegate starts with an empty fold, so the tool answers
  that there are none.

## The long-answer card

A bundle, not core: [decision-card](../bundles.md#the-decision-card-bundle), removed by uninstalling. It reads the list with
`ctx.objectives`, the plugin API over `Objectives.current`; `items` and `text` are the bundle's only view of the object.

`:after_turn` reads the answer's length and tail from `event[:answer]`, not from the stored message, which on the native
loop still holds its thought block, and starts a thread only when both pass, so the turn's end
is held for no request and the web's answer doesn't wait (no `event[:present]`). The thread reads the list and, with an active
objective, makes one `ctx.ask_model`. A Transcript drops system entries, so the list goes in `prompt:`. The objective a reply
names is display only: an id the list doesn't have, or has dropped, is left out.

Stale is a new turn: `:before_turn` takes the running `Ask` and cancels its request, so a one-slot server is free for that
turn, and `show` holds the same mutex, so a card shows before that start or not at all. The hook runs inside its turn, so the
card waits for `ctx.turn_running?` to go false: shown earlier, it gets `in_turn: true` and lands in that turn's collapsed block.
The request doesn't wait: it goes ahead of the turn-end warm-up, so on a one-slot server the warm-up queues behind it and is the
last thing in the slot, and the next turn keeps its prefilled prompt. A shown card is replaced by a one-line one with
the same id only at a turn of the owner's (a prompt, no author): a wake has no prompt, and a child's report isn't an answer. A
worker that restarts forgets a shown card, which then stays as it is: it has no buttons.

A card with no actions writes no `pending_card.json`, so it never reaches `Web::Push::Attention`.

## Not in this version

Stable-prompt lines aren't here, and terminals have no picture: they keep `/objectives`. Checks (P5) come later.

Taking it out: old notes stay readable framed bubbles and keep being sent, and the key is ignored. Old `objectives` calls
stay as history; with a kit no longer declaring the tool, they are ordinary saved calls. The card's bundle uninstalls. The
page's pieces are the `objectives_*.js` modules and `objectives.css`, wired in a few lines of `app.js`; without them a list note
falls back to the default bubble once `noteBubbleTemplate`'s first line goes.
