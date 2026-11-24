# Peers: another agent beside chi

A **peer** is another agent's session the user works with beside chi: a Claude Code session (the claude-peer
bundle) or a Codex CLI session (codex-peer). chi sends it a part of its work (`claude_send`, `/claude validate`),
and the peer answers into chi. Each answer is a **message** in the session's **mailbox**: its own note in the
conversation, in order, with its text. chi says what it did with each one, on the peer's terminal and in the
peer chip. How it is built: [internals/peers.md](internals/peers.md).

## Pairing

The peer pairs from its side, with its `chi-peer` skill (`/claude install-skill` or `/codex install-skill`
installs it). Its pair script runs one command:

```sh
chi peer pair claude <session id> --address <where chi sends> --from "<who paired>"
```

- `--address` is where chi's sends go: Claude Code's inbox socket, Codex's thread id. A pairing without one
  answers only: the peer can say, chi can't send to it (a peer on another machine with no forwarded socket).
- Pairing again only replaces the address (a Claude Code restart gives it a new socket).
- `chi peer unpair claude <id>` ends the pairing. Its messages stay, and chi still reads those it hasn't. The
  peer chip's **Unpair** does the same.
- `chi peer pair` refuses a session whose live worker is older than the mailbox ("restart the session"), and a
  session that was continued (it names the new id).

Which agents are peers is the bundles' to say (`chi.peer NAME` in plugin code), never a file's. A message from
a name no loaded bundle declared is refused with "no bundle in that session declares peer NAME".

## Saying something: `chi peer say`

```sh
chi peer say claude <id> --wake --re s-ab12cd --summary "validate step 2: VERDICT CHANGES, 2 issues" --wait 8 <<'EOF'
<the full answer>
EOF
```

- `--wake` or `--nowake` is required: `--wake` asks chi to run a turn for it (a validate's answer, a question's,
  a message chi should act on now); `--nowake` leaves it as a note for chi's next turn.
- `--re` names the send it answers (the `ref:` line of chi's message); leave it out for a message the peer starts.
- `--summary` is one line (200 characters); the text is stdin, or `-m TEXT`, up to 1 MiB.
- `--wait SECONDS` (0 to 30) waits for chi's answer; the skills use 8.

It prints one line, which the skills tell the agent to quote to its user:

| What chi did | The line |
|---|---|
| started a turn | `#12 received · woke chi` |
| held it | `#12 received · held: 3 peer turns in a row (peer.turns) · waits for the user's next message` |
| took it as background | `#12 received · noted` |
| can't say yet | `#12 received · chi is in a turn: it reads this when the turn ends`, `chi is stopped: …`, `this session is archived: …`, `chi's worker isn't running and couldn't be started from here: …` |
| nothing within the wait | `#12 received · no answer from chi yet` |
| refused | `refused: no bundle in that session declares peer claude` (exit 1) |

Other messages of the same peer held and unread follow: `· also held: #10, #11 (paused)`. A held message is not
lost: it is a note, and the user's next message lets chi read it. The skills say not to send it again, and not to
`chi send` past it.

A say is refused, with nothing written, for: no such session; a session being deleted; a continued one (`this
session was continued as <id>: say it there`); not paired (`not paired: run the pair script`); an older worker
(`restart the session`); 200 messages chi hasn't read yet.

Through `--remote NAME` (or `CHI_REMOTE`) the remote's chi web does the say and the wait, and returns the line.

## What chi does with a message: the receipts

The worker takes the peer's messages in order, between turns, and writes one receipt per message:

- `woke` (a turn started for it), `held` with a reason, `noted` (it asked for no turn), `refused`;
- then `read` once a turn starts with it in the conversation, and `completed`, `failed` or `stopped` when that
  turn ends.

Held reasons: `off` (`peer.turns` is 0), `paused` (after a failed wake turn), `continue` (a continue offer waits),
`max_wakes`, `peer turns`, `queued`, `exit`, `leaving`, `before a turn`.

`chi peer ls <id>` lists each peer, its pairing and its newest messages with their receipts; the peer chip's list
shows the same words (`held · peer turns`, `read`, `completed`).

## The budget: `peer.turns`

A peer's messages may wake chi `peer.turns` times in a row (default 3) with nothing typed by the user, within
`session.max_wakes`. Past it they wait as notes, the say's line says so, and the TUI and the web say it once. A
message whose summary ends its round with `VERDICT OK` wakes chi once more to close it, held only by
`session.max_wakes`. Only input typed in the web or a TUI resets the count: `chi send` does not, since a peer can
run it. `peer.turns: 0` means a peer's message never wakes chi. `context.wake` is attached context's only.

`peer.turns` replaced `context.peer_turns` (no alias): rename it in config.yml.

## Limits

- A message's text up to 1 MiB, its summary one line of 200 characters.
- In the conversation, a note that wakes chi holds the text up to the tool output cap (10,000 characters by
  default); one that doesn't, up to 2,000. A longer one points at the `claude_read` / `codex_read` tool
  (`serial`, `offset`, `limit`), which pages it.
- 200 messages chi hasn't read: further says are refused until it reads them.
- The mailbox keeps every message chi hasn't taken, and the newest 50 it has.
- A continued message is cut at 4 KiB in the new link; run `chi peer ls <previous id>` to read the rest.
- A `chi peer say` sent at the very moment of a continue may stay with the previous session; run
  `chi peer ls <previous id>` to read it there.

## Continuing a session

A continue leaves the pairing and the mailbox with the previous link:

- the new link's `/claude` init task posts the peer a `moved` message with the new id, and the peer pairs again
  with it, the way it paired before (its skill knows how);
- a say to the old id is refused, naming the new id;
- the messages the previous link hadn't read (never taken, or held or noted and not yet read by a turn) reach the
  new link as **one** note, each text in its peer block.

## Codex's sandbox

Codex's default sandbox writes only where its config allows, and `chi peer pair` and `say` write the mailbox:

```toml
[sandbox_workspace_write]
writable_roots = ["<state>/samagotchi/mailbox"]
```

`/codex install-skill` shows the exact line and makes the folder, so the root exists when Codex restarts. A config
from an older skill names `…/samagotchi/context`: change it. A say from inside the sandbox can't start a stopped
worker; it prints "couldn't be started from here", and chi reads the message at its next start.

## Who can write the mailbox

The mailbox is `<state>/samagotchi/mailbox/<session id>/<peer>/`, apart from the sessions folder: the only folder a
sandboxed peer writes, so it holds nothing chi trusts. chi's own record of each message (the receipts) is in the
session's own folder, written only by its worker. Every message file is checked before it is read.

The say is unauthenticated, as a context push is: any process that can write the mailbox can send as a peer. A
writer of the mailbox folder can also plant a file with the largest serial and use up a peer's serials (later
says then fail with "serials are used up"); the folder's writers are trusted that far, as they can delete its
files. chi's own tools can't write there (the `chi-mailbox` guardrail), and a shell command naming it asks.

## Upgrading from an older peer bundle

The claude-peer and codex-peer bundles paired through two attached context sources (`<peer>-inbox`,
`<peer>-outbox`). That is gone, with no compatibility:

1. `chi update` (or `chi bundle upgrade claude-peer`); an older bundle that still declares `chi.peer_source` fails
   to load with "upgrade this bundle", and chi starts without it.
2. In Claude Code: `/claude install-skill`, then **Replace**; in Codex: `/codex install-skill` and change the
   `writable_roots` line.
3. Pair again. Until then `/claude` says "paired the old way: pair again", and a push to an old `claude-outbox`
   source is an ordinary context note.
