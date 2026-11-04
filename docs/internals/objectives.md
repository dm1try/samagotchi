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
  no list sends the same bytes as before.

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

## Continue, rollback, fork

- **Continue**: `Objectives.carry`, in `SessionContinue`'s `before_spawn`, writes a second note file in the new link,
  after the carry note and any moved context's note, so the list reads as the latest word. It is not in
  `SessionChain.note_text` (capped; the last answer gets what the recap leaves). It reads the previous link fresh,
  with its unabsorbed newest file. A failure is only logged (`continue_objectives_failed`), because it runs inside the
  continue's rollback. A review link's list stays behind, as its last answer does: the next link's participants could
  differ.
- **Rollback**: a note survives `TurnFlow#restore`, and an unabsorbed edit is on disk, untouched.
- **Fork, delegate**: a plugin fork copies what it is passed. A delegate starts with an empty fold.

## Not in this version

Later phases (a move tool that reads `tool_calls` in the fold, a long-answer card, the strip) aren't here, and neither
are stable-prompt lines. A UI of its own would replace the default note bubble.

Taking it out: old notes stay readable framed bubbles and keep being sent, and the key is ignored.
