# Session objectives

A session's objectives are a short list the user types: what this session is to achieve. The first version is a
try-out, so each piece can come out alone. There is no new message kind, store or UI: the list is a note in the
conversation, the command writes a note file, and the UIs show the default note bubble. For the user's side, see
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

`serves` on `ask_user_question` waits until moves read well. The model can't edit the list and can't propose an edit.

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

Later phases (the strip) aren't here, and neither are stable-prompt lines. A UI of its own would replace the default note bubble.

Taking it out: old notes stay readable framed bubbles and keep being sent, and the key is ignored. Old `objectives` calls
stay as history; with a kit no longer declaring the tool, they are ordinary saved calls. The card's bundle uninstalls.
