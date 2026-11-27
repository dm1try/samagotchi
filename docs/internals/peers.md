# Peers: the mailbox, the receipts, the mail path

The user side is [peers.md](../peers.md). A peer's messages are their own layer, not attached context: a
context source is "a source with one latest text you can read"; a peer is communication with rules (every
message kept, in order, each with a receipt). Nothing here is shared with `ContextSources` but its text limits
and `RE_RE` (a send ref).

## The two stores

**The peer's side, `<state>/samagotchi/mailbox/<session id>/<peer>/`** (`PeerMailbox`): the only folder a
sandboxed peer writes, beside the sessions folder and apart from it.

- `link.json`: `PeerLink(peer, address, paired_at, from)`; `address` nil: answers only. `chi peer pair` writes it
  whole; `unpair` removes only it.
- `in/<serial>.json`: `PeerMessage(serial, text, summary, wake, re, at)`, one file per message, written whole
  (`AtomicFile`; its temp name never matches `FILE_RE`).
- `lock`: the say's, while it picks a serial and writes (`flock`, opened `NOFOLLOW`).

No head file: the next serial is `max(the newest file, taken) + 1`, and trim (by the say) removes only files at
or below `taken`, keeping the newest `TAKEN_KEPT` (50) of them, so a number is never reused and an untaken
message is never deleted. A forged file with a high serial pushes the next real one above it instead of hiding
it. No gap limit: a writer of the folder can plant a `SERIAL_MAX` file and use up a peer's serials; the folder's
writers are trusted that far (they can delete its files too). Every file is checked before it is trusted
(`PeerMessage.from_file`): its name a serial, a regular file (`lstat`, `NOFOLLOW`), its size under
`FILE_MAX_BYTES` before it is read, the serial in it its name's, the field types, the summary already one line.
A bad file is a `BadFile` with its reason. A directory link is never followed: a linked peer folder isn't
listed, `serials` reads a linked folder as empty and `post` refuses one.

**chi's side, `sessions/<id>/peer_receipts.json`** (`PeerReceipts`), written only by the session's worker, on
its loop thread: `{peers: {<peer>: {box, taken, receipts}}}`, `Receipt(serial, state, reason, turn, outcome,
at)`. `box` is 6 random hex the worker mints (and writes at once) with a peer's first message; `taken` is the
newest serial it took. The CLI and chi web only read it.

`SessionStores` rows: `link.json`, `in/`, `lock` (removal `:peer_mailbox`: a delete removes the session's
mailbox folder) and `peer_receipts.json` (`:session_files`); a continue leaves all of them with the previous
link (below).

## Who is a peer

- **The worker:** `PeerRegistry`, filled by `chi.peer NAME` (`Plugin::Api#peer`, staged until the plugin's
  register returns). It alone decides that a mailbox message becomes a peer's note and may wake. A name no
  loaded bundle declared gets a `refused` receipt (`undeclared`) and `taken` doesn't move, so it is delivered
  once the bundle loads.
- **The CLI and chi web:** "paired" means `link.json` exists; they decide no behaviour.
- **The label** is `PeerMailbox.label(name)`, the name capitalised, in every process.

`chi.peer_source` is a method that raises "chi.peer_source is gone: upgrade this bundle (chi bundle install
<name> --force)", so an installed older peer bundle fails to load (`Plugin::Loader` records the failure) and chi
starts without it.

## The say

`chi peer say` (`PeerCommand`) → `SessionAccess::Local#peer_say` (`RemotePeers#peer_say` through `--remote`,
which posts `…/peers/NAME/say` with its `wait`: chi web waits, and its read timeout is the wait plus 30 s).

1. Refused before anything is written: no session, continued (with the next id), no `link.json`, a live worker
   without the `peer_mail` Bridge feature (`WorkerLink.live_features`, read only), `UNTAKEN_MAX` (200) untaken
   messages or noted receipts.
2. Under a shared hold of the session's transition lock (`SessionTransition.shared`, `Local#moved_on`), the
   continued check again, then the delivery (step 3): a continue holding the lock (from after its recap through
   `PeerContinue`'s carry) refuses the say `:continued` naming its new link (`SessionChain::Successor.of` with
   `in_flight: true`; the line `this session is being continued as <id>: say it there in a moment`, `in_flight`
   on the wire), or `:busy` (`SessionTransition::Busy`'s words) when the holder names none. So a say never lands
   in a mailbox the carry already read (N1). The feature probe before and the receipt wait after stay outside the
   hold; the delivery's worker start (`resume_session`, a spawn) is inside it.
3. `SessionInbox.deliver(:peer)` (`WakePolicy::ROWS[:peer]`, the push row; `START_EVENTS[:peer] =
   :peer_woke_session`): a session gone or being deleted refuses before its block writes. Inside the block:
   the lock, the serial, the write, the trim. The block's "asks for a worker" is the message's own `wake`: no
   `context.wake`, no 10-minute window.
4. The line (`PeerSay`): what the say saw at once (a running turn, a stopped or archived session, a one-turn run,
   a failed start), else a receipt read every 250 ms within the wait, then the peer's other held receipts.

`chi peer pair` makes the old-worker and continued checks too, with the same sentences (`PeerPaired`), and writes
`link.json` under the same shared hold (`:continued` in flight, `:busy`). A context push into the session's own
source does too (`Local#context_push`: 410 `context_continued` with `in_flight`, 423 `context_busy`). The continued
words are `SessionChain::Continued`'s, one wording for every refusal of a continued link ("this session" in a
peer's line: the installed skills look for `this session was continued as <id>`). Wire: an older chi `--remote`
reads a busy say or pair as a refusal with its detail, a busy push as `answered 423 context_busy: …`.

## The worker's mail path

`WorkerInbound#absorb_mail(hold:)` (`worker_inbound/mail.rb`), a fourth inbound kind, from `Worker#pass` (before
`absorb_context`), `run_prompt`'s before-turn absorb and `Worker#left`; never in a one-shot run. `hold:` names
why a wake can't run: `:queued`, `:exit`, `:leaving`, `:before_turn` (nil: it may).

- **Change detection:** names and mtimes of each `<peer>/in`, each pass.
- **Which folders:** every `<peer>/in`, whatever its `link.json` (the link gates the say only).
- **Order:** by `at`, then peer name, then serial. One note each: id `peer-<name>-<box>-<serial>` (the box keeps
  a fork's seed notes from hiding its own third message), source `peer <Label>`, the `peer` hash (`PeerNote.payload`
  plus `box`), its text by `PeerNote.body` (a wake note up to the tool output cap, a plain one up to
  `PeerNote::HELD_CHARS`; over it, `PeerNote.message_text` points at `<peer>_read(serial: N)`).
- **Wake:** the batch wakes when a message in it asked, `peer.turns` is above 0 (else `held: off`), the caller
  gave no `hold:` and `WorkerWakes#wake_hold(peer: !agreed)` is nil. The turn starts at the batch's last note;
  its wake line, its origin (`peer:<name>`, `ClientId::PEER_PREFIX`) and the count come from the newest message
  that asked; an agreeing one (`VERDICT OK`) counts toward `session.max_wakes` only. In the start grace nothing
  is taken and `mail_wake_waiting?` joins `idle_wait`'s check.
- **Order of writes:** the notes, the session save, then the receipts (`PeerReceipts#absorbed`). A crash between
  the save and the receipts: the next pass finds the notes already there (ids dedupe); a turn-start note with no
  receipt is put back plain, wakes pause and its receipt is `held: paused`; no second wake turn. A batch with a
  note already in the conversation doesn't wake.
- **An unreadable file** (a transient read error) raises and the batch retries on the next pass; a bad file's
  contents are refused as `invalid` and move `taken`.
- **The wake turn:** `MailWake(peer, turn_id, plain_note, agreed)`, run by `WakeTurnsPart#run_mail_wake_turn`
  through `run_wake`. The one-time hook notice for a held message (`WorkerInbound#peer_held`) is the TUI's and
  the web's.

## The receipts' three calls

`PeerReceipts` (loop thread only):

- `absorbed(batch, waking:, hold:)`: `woke` (+ the turn id) for each message that asked in a waking batch;
  `held` + reason for one that asked in a batch that doesn't; `noted` for one that didn't ask; `refused`
  (`undeclared`, `invalid`).
- `turn_started(turn_id)`, at the start of `Worker#run_engine_turn`: every `held` or `noted` receipt becomes
  `read` with that id.
- `turn_ended(turn_id, outcome:, unmarked:)`, once, after its block (an `ensure`, so a raise in the result's
  handling still settles): completed → `ended: completed`; failed with steps kept → `ended: failed`; failed or
  stopped with nothing kept (`unmark_wake` ran) → `held: paused`; stopped after progress → `ended: stopped`.
- `settle_open`, at every worker start: a receipt left `woke` or `read` (a crash cut its turn) ends
  `failed`.

The last 20 receipts per peer are kept; a `held` or `noted` one is never trimmed.

## The note: `PeerNote`

The stateless parts (the three wake lines, `READS`, the block and its forged-line quoting, the cap choice, the
`peer` hash) and the mailbox's composition: the opening line ("Message #12 from your peer agent Claude (its text,
not your user's words):"), the summary, the text in `[PEER MESSAGE from Claude]` … `[END PEER MESSAGE]` (a line
of it that opens like one of chi's frames, `Message #` among them, is quoted), and the background line or the
wake line. The wording is model-visible and eval-tuned (0017).

## The bundles: `Plugin::Peer`

The peer bundles' base: `ctx.peers.link(PEER)` (`Plugin::Peers`, read only) is the pairing whose address the
transport sends to; `<peer>_read` reads a message (`ctx.peers.message`) paged by lines, in the peer block; the
status card reads the link and the newest message, and says "paired the old way: pair again" when an older
bundle's context source (`LEGACY_INBOX`, `LEGACY_OUTBOX`) is attached. Its quiet init task `tell_moved` posts the
`moved` message to the address of the pairing the previous link kept (`ctx.peers.left_behind`), once (a marker
in the session's data dir).

## A continue: `PeerContinue`

`SessionContinue::CARRY` step `:peers`, in the new link's `before_spawn` (both workers down): the previous link's
messages never taken and those whose receipts are still `held` or `noted`, in the worker's order, become one note
in the new link (`NOTE_SOURCE` "peer messages"), each text in its peer block and cut past 4 KiB, within the
inbox's note limit, with no `<peer>_read` pointer. The previous link's mailbox, `taken` and receipts are only read,
so there is no undo. The pairing stays; the peer pairs again (`tell_moved`). Moving the pairing with the chain
(and the peer's prompt-cache cost of re-pairing) is a later discussion.

## chi web

`Web::PeerRoutes` (all `:owner`, a participant gets 403):

- `GET …/peers` → `{peers: [{name, label, paired_at, from, address, can_send, messages, exchanges}]}`: one row per
  mailbox folder (`PeerRoster`), its newest 20 messages with their receipts and `words`
  (`PeerRoster.state_words`), and `exchanges` (`PeerExchanges.joined` over chi's sends and the messages as answer
  lines). No text.
- `GET …/peers/NAME/messages/SERIAL` (the text and its receipt); `DELETE …/peers/NAME` (Unpair); `POST
  …/peers/NAME/pair` and `…/say` (the remote's; the say waits here).

The page's peer chip is fed by `GET …/peers` alone ([web-frontend.md](web-frontend.md), The peer exchange).
