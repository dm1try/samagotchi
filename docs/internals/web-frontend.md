# The web frontend: where state lives

A map of `lib/samagotchi/web/public/` for whoever changes it: where the page keeps what it knows, how a change
reaches the screen, and the guards every new piece should use. The modules' own header comments say what each one
does; this page says how they hang together. The server side is [architecture.md](../architecture.md) (Web);
the working set's overlay is [working-set.md](working-set.md), participants are [participants.md](participants.md).

No build step: `index.html` and `participant.html` load ES modules as they are, with lit-html (`vendor/`) as the
only library. Pure modules (`*_model.js`, `session_state.js`, `sessions_list.js`, `turn_range.js`, …) touch no DOM
and have `node --test` specs under `spec/web/public/` (happy-dom for the DOM ones); the pages as a whole are covered
by `npm run e2e` (`spec/e2e/`). `app.js` has no unit spec.

**`app.js` has a size cap**: `npm run lint` fails past `max-lines` in `eslint.config.js` (counted as `wc -l` counts,
a little over its size today). A new feature goes into a module of its own, wired from `app.js` in a few lines; a
refactor that shrinks `app.js` ratchets the cap down with it. Never raise it: extract instead.

**New exports go in new modules.** The static JS is served at unversioned URLs. Today every load revalidates
(app.rb `serve_static` sends `Cache-Control: no-cache` with a content ETag, and `sw.js` has no fetch handler), but an
open tab still holds the modules it loaded, and a proxy that ignores `no-cache` can serve an old one: a new export
on an existing module, imported by a new version of another, then finds the old module without it and blanks the
page. A factory dep a new version stops passing is the same hazard the other way round: the store's redraws took
`updateInfoBar` and the chip controls out of `stream_handlers.js`'s deps (and `updateInfoBar`/`updateComposerMode`
out of `send_turn.js`, `session_actions.js` and `lists_view.js`); a page loaded before keeps all its old modules
until a reload, so the risk is a mixed cache, not an open tab. `answer_fold.js`, `details_motion.js`,
`turn_range.js`, `history_reveal.js`, `latest.js`, `session_payload.js`, `method_api.js`, `session_store.js`,
`session_fields.js`, `feature_gates.js`, `revise_stack.js`, `revise_switch.js`, `shell_command.js`, `stale_params.js` and `popover_modal.js` are new modules for that reason.

## Two pages, two models

| Page | Entry | Model |
|---|---|---|
| **Owner page**: the start page and a session page | `index.html` → `app.js` | **Render once, then patch.** A session's open (`select` → `resync` → `renderSessionView`) draws the history from `GET /api/sessions/:id`; from then on each stream event changes the DOM in place (`stream_handlers.js`). The DOM *is* the log. The start page is the same app with `store.selected` null. |
| **Participant page**: a review or pair link | `participant.html` → `participant.js` | **Re-read at a turn boundary, then a keyed redraw.** It reads `GET …/review`, draws it, and streams; an event that ends or changes a turn (`reloads`) marks the data stale and the page reads it again. `drawnMessages` keeps a message's node while its signature is unchanged; a small `live` overlay (`participant_model.js applyLive`) draws the running turn on top. |

The participant page is **deliberately separate**: it shares leaf modules with the owner page (the annotate bar,
claim links, `composer_mount.js`, the verdict card and Verify fresh, `verify_target.js`, `verify_preset.js`,
`auth_lost.js`, `token_fragment.js`, `format.js`) but none of the data layer, the stream handling or the message
rendering. It has its own `api` (`{status, ok, body}`, never throws, its own ended / auth-lost handling) and its own
`EventSource`. Its parallel copies of the owner's Verify and claim helpers (`verifyFreshState`, `verifyAnchorFor`,
`showPendingClaim`, `CLAIM_ROOTS`) differ on purpose in places (the source kind `reply` vs `answer`, the server's
`fresh_running` vs `verify_fresh`, no home/cwd in its claim options). Don't converge them as a side effect of another
change.

## Where state lives (owner page)

| Holder | What | Who writes | How a change reaches the screen |
|---|---|---|---|
| **The session store** (`session_store.js`; app.js `store`) | `store.selected` (the open session's id), `store.current` and `store.sessions` (below) | through the store only (see The session store); other modules get getters (`selected: () => store.selected`, `state: () => store.current`) or the store itself (`stream_handlers.js`, `send_turn.js`, `session_actions.js`) | the store runs the redraws that read what changed (below); nobody calls them by hand |
| **app.js module scope**: about 20 top-level `let`s (`streamControl`, `eventsControl`, `pageCapabilities`/`pageEditorUrl`, `pendingVerifyAnchor`, `pendingClaim`, `resyncsInFlight`/`resyncAgain`, `resyncAttempts`, `scopeError`…) | the page's mode and its streams | app.js only; other modules get getters and hooks | the writer touches the redraw that reads it (`store.touch("infoBar")`: the stream, versions, `restartingIds`), or calls a redraw only it feeds |
| **`store.current`** (`session_state.js`: `emptySessionState` / `sessionStateFrom`; per field: `session_fields.js FIELDS`) | the open session's fields, about 40 (info bar, chips, verdicts, timing, worker, stream cursor) | `store.update` / `setStatus` from app.js, `stream_handlers.js`, `send_turn.js` (`firstPreview`, `owner`), `session_actions.js` (`status`); `forgetSession`'s `replaceCurrent`. Two writers in place, on purpose (D8 in `FIELDS`): live_timing.js's `activeTurn`, verdict_fresh.js's running list | the store runs the field's redraws (`FIELDS[key].redraws`) |
| **`store.sessions`** (the hub's projection) | every card | `store.update({sessions})` from app.js: `openSessionEvents` (`applySessionEvent`), `refresh` (the list fallback), `addCreatedSession`, `applyView` (re-sorted), `replaceSelectedCard` (`setLiveStatus` through `setStatus`, `readTurnEnd`, `setUsedMemories`), the stream's close (`withoutWorker`); `session_actions.js` (`setSessions`) | the store: `lists` and `infoBar`. **Always a new array**; an entry is replaced, never changed in place. `followSelectedSession` copies the open one's owner and worker (`fieldsFromCard`) and, when not streaming, its status (`setStatus(…, "hub")`) into `store.current` |
| **Factory closures**: the `create*` factories (popovers, panels, views) | each component's own state: open-for, busy, error, its own fetched list | the factory | an `onChange` hook back into app.js, or a getter the factory reads at draw time |
| **The history DOM** | the conversation as drawn: which turn a bubble belongs to (`data-turn-id`, `data-answer-turn`), kept command bubbles, which texts were shown, unnamed badges, folded answers and long prompts (`.folded`), Revise stamps (`data-revises` on a prompt; a Verify turn's `data-verify`) and the stacks' folded versions (`.stack-hidden`, `.stack-stub.open`); the switcher's version on view is `revise_stack.js`'s own (a copy `.stack-view` before the top answer, the top `.stack-swapped`; never stored) | `bubbles.js`, `cards_place.js`, `question_cards.js`, `turn_block.js`/`stage_view.js`, `answer_fold.js`, `revise_stack.js`, `stream_handlers.js` (a live `turn_completed`'s `revises` and `verify` onto its prompt) | read back as state: `turn_range.js turnElements` (one walker for a turn's elements), `keptCommandBubbles`, `seedSeenFromDom`, `nameUnnamedBadges`/`nameVerdictCards`, `answer_fold.js` and `revise_stack.js` (their observers decorate every path that fills `#history`; the stacks are `stacks()` of the stamps, read again on each change, never a store field), `history_reveal.js revealInHistory` (the one way a jump unfolds what hides its target) |
| **localStorage** (`storage.js` `readStored`/`writeStored`, guarded) | per-browser choices only | the module that owns the choice | read at start (see Storage keys) |
| **SSE** | see Streams | the server | owner page: events go into the DOM directly; participant page: an event marks the data stale |

The start page's own choices (the model, the ⚙ panel, the 🧰 list) live in `start_page.js`'s closure, never in
`store.current`. A fresh chain link's picker reads both.

## The session store

`session_store.js` holds the open session's state; `session_fields.js` says what each field is. **Every write goes
through the store**, never `current.X = …`:

- `store.update({selected?, current?: {field: value}, sessions?})`: `current`'s fields are written into the same
  object (it is replaced only by a session switch); `sessions` is always a new array (one changed in place isn't
  seen).
- `store.setStatus(value, source, {streaming})`: the one way `status` changes (below).
- `store.replaceCurrent(state)`: `forgetSession` only; always a new object, so a stale async writer still holding the
  old one writes there alone.
- `store.batch(fn)`, `store.touch(name)`, `store.on(name, fn)`: the redraws (below).

The ESLint block `samagotchi/session-writes` (eslint.config.js) enforces it in the six modules that hold the state
(app.js, `stream_handlers.js`, `send_turn.js`, `session_actions.js`, `start_page.js`, `working_set_view.js`): an
assignment, `++`, `delete` or `Object.assign` into `current`, `store.current` or `state()` is an error
(`spec/web/public/lint_session_writes.test.js` runs it on a sample). An alias (`const st = state(); st.x = …`) isn't
caught: don't write through one.

**Read `store.current` fresh after every await.** A `const cur = store.current` held across an await pins the object
from before it, which a session switch (`forgetSession`) may have replaced: app.js's `readTurnEnd`,
`mergeTurnTiming`, `resync` and `refreshTimingFromSession` read it again after each await. Keep `store.sessions`
reads fresh too.

### Fields and their redraws

`session_fields.js FIELDS` has one entry per `emptySessionState` key: its payload source (a partial re-read takes a
field only when the payload carries it: `session_payload.js` reads its sources from here), its hub card source
(`fieldsFromCard`: owner, workerVersion, workerFeatures, bridgeUp; never status), its redraws (store `ORDER` names)
and its writers. A new field starts in `emptySessionState` and gets an entry (its spec checks both).

A changed value (`!==`) marks its field's redraws; `sessions` marks `lists` and `infoBar` (the bar reads the list:
the chain's ← → links, the children chip, the archived button, the card's title, the fresh link's picker); `selected`
marks `paintActive`, `composer` and `infoBar`; `touch(name)` marks one redraw for an input the store doesn't hold
(the clock, versions, the stream, `liveTurn.running`). They run synchronously, once each, at the end of the outermost
`batch()` (at once for a bare write), in one `ORDER`: `lists`, `paintActive`, the open panels (`settingsPanel`,
`workingSetStrategy`), `featureGates`, `composer`, `infoBar`. `lists` comes before
the bar because `updateSessionTitle` reads the strip's active card; `composer` before the bar as `setTurnRunning`
runs them. Not a rAF (a background tab runs none, and the title badge tests run there; the e2e per-frame checks would
see the composer move a frame late) and not a microtask (code that reads the page right after a write would see it
stale).

**The redraws are registered, not called.** app.js registers each name once (`store.on`, at the bottom, once every
piece a redraw calls exists): `lists` → `lists.render()`, `paintActive` → `lists.paintActive()`, `settingsPanel` →
`settingsControl.refresh()`, `workingSetStrategy` → `workingSet.strategyChanged()`, `featureGates` (below), `composer` →
`updateComposerMode()`, `infoBar` → `updateInfoBar()`. A writer writes and stops there: no `updateInfoBar()` after
a store write. A value written unchanged redraws nothing (a chunk with the same ctx %).

An input the store doesn't hold calls `store.touch(name)` where it changes: `infoBar` for the clock (liveTurn's
`onTick`), the versions (`noticeVersions`), `restartingIds`, the stream (`startStream`, `workerGone`), the working
set's and the participants' `onChange`, the continue and review in-flight sets
(`session_actions.js`); `composer` and `infoBar` for `liveTurn.running` (`setTurnRunning`, with `settingsPanel`:
the open ⚙ panel's running-turn note) and at the end of `renderSessionView` (a whole view drawn). Left as they are,
on purpose: the `narrowScreen` listener calls `updateComposerMode()` (the bar doesn't read it),
`applyStripHidden`/`applyView` call `updateSessionTitle()`, and `closeStream`/`stream.restart` set
`streamControl = null` without a redraw (a resync or a workerGone follows).

A function that writes more than once batches its synchronous part, so each redraw runs once: `select` (before its
`await resync()`), `clearSelection`, the hub's `snapshot` and `session` events, `workerGone`, `setTurnRunning`,
`turn_started` (inside `keepFollowing`, so the composer and the bar redraw before its scroll), `readTurnEnd` (after
its timing merge), `setUsedMemories`, and `renderSessionView`'s field write only: the replay's own
`setTurnRunning` redraws where they run, before `turnDom.flush()`. A stream handler writes one patch.

`batch(fn)`:
- `fn` is synchronous: one that returns a promise is refused (`console.error`, the redraws run at once). Batch an
  async function's synchronous parts only, never across an await.
- The redraws run in `finally`, also when `fn` throws (the page shows what was written), then `fn`'s error is
  rethrown; a redraw error meanwhile goes to `console.error`. A throw never leaves the store inside a batch.
- During a flush, a write, a touch or a batch's end only enqueues: the next pass runs it, after the current pass's
  `ORDER`. Passes stop at 3 (`console.error` names the redraw). A redraw that throws doesn't stop the others; its
  error is thrown after the flush.

### `status`

Six writers, each with its rule, all through `setStatus(value, source)` (`session_fields.js statusWrite`):

| source | writer | applies | the open session's card |
|---|---|---|---|
| `payload` | `renderSessionView` | always | left alone |
| `hub` | `followSelectedSession` | only while the stream isn't live | left alone (the card came from the hub) |
| `stream` | `setLiveStatus` (`turn_*`, `workerGone`'s idle) | always | `withLiveStatus`: status, owner, `updated_at` |
| `turnEnd` | `readTurnEnd`, the turn_canceled re-read (`refreshTimingFromSession`) | when the payload carries one (the caller skips it otherwise), and **not while a turn runs**: a re-read that lands after the next queued turn's `turn_started` doesn't write its stored "idle" over "running" (the test `mergeTurnTiming` keeps `activeTurn` by) | left alone: `readTurnEnd` writes its card itself after its timing merge, with `used_memory_names` |
| `stop` | `session_actions.js stoppedWorker` | always | left alone (`workerGone`'s `withoutWorker` changes it) |

`setStatus` answers whether it replaced the card; the new list redraws the lists and the bar by itself.

### Feature gates

A page action the open session's worker must support (its sidecar features and a live bridge) is a gate in
`feature_gates.js`, registered as the store's `featureGates` redraw: `{name, unavailable(current), redraw}`. It runs
when a field it reads changes (`workerFeatures`, `bridgeUp`), and a gate's `redraw` only when its answer flipped: a
restart's hub event that brings the feature enables it, the worker going (`workerGone`'s `bridgeUp = false`) says
it's unavailable. `forgetSession` and `renderSessionView` draw the history with the answer already, so they `prime()`
the gates in the batch of their write, and nothing fires. Today two gates: `verify` (Verify fresh on a verdict's
card, `redrawFresh`) and `revise` (the answers' Revise buttons and the composer's Revising chip, `redrawRevise`).
Both refuse only a live worker without the feature: a worker that isn't up is woken by the send as a new one, which
has it. A new action that needs a worker feature is one more entry.

### Exceptions

- **Writers in place (D8)**, named in `FIELDS`: live_timing.js sets `timing().activeTurn` (the running turn's own
  clock; `mergeTurnTiming` keeps it), and verdict_fresh.js `startFresh` pushes onto `fresh.running`, which is
  `store.current.verifyFresh`.
- **Events, not state (D9)**: these stay direct calls next to their write: a `/model`'s picker sync
  (`syncModelPick`), the working set's `commandRan`, the context chips on a note, the participants reload, a
  verdict's own `renderFresh`. (The working set's `strategyChanged` and the Verify gate's `redrawFresh` follow
  fields: they are registered redraws.)

A partial re-read of the open session (a `?tail`/`?recent` read) goes through **`applySessionPayload(data,
{fields})`** in app.js (`session_payload.js sessionFieldsFrom`): the named fields read as a full load reads them, a
field whose source the payload doesn't carry left alone; its status goes through `setStatus(…, "turnEnd")`. Their
redraws follow. Never copy payload keys into `store.current` by hand.

The redraws, by their store names:
- `infoBar` (`updateInfoBar()`): the session bar's buttons and info line (`info_bar_model.js sessionBar` →
  `info_bar.js`), the annotate bar, the fold controls, `updateSessionTitle()` and the fresh link's picker. Cheap: it
  runs on most writes and every clock tick.
- `composer` (`updateComposerMode()`): the composer's placeholder, buttons and delivery line (selected, running,
  owner).
- `settingsPanel` (`settingsControl.refresh()`): the ⚙ chip's **open panel** (`settings_chip.js`; the chip itself is
  drawn by the bar), on `thinking`, `reasoningHistory` and `llmContext`; `workingSetStrategy`: the working set's open
  list.
- `lists` / `paintActive` (`lists.render()` / `lists.paintActive()`): the strip and the all view from
  `store.sessions`.
- `featureGates`: the gates above.

`forgetSession()` is the one reset: `select` and `clearSelection` both call it, so anything per-session that isn't
in `store.current` (capabilities, the markdown warning and tip, the init row, the Verify claim, the armed Revise,
the running turn's DOM) is cleared there, and the feature gates are primed for the empty session. A new per-session holder
(an armed composer anchor like the Verify claim or the Revise) goes into it. The armed Revise
(`pendingReviseAnchor`) is set only through `setReviseAnchor`, which redraws its chip and the Revise buttons (a
redraw only it feeds, not a store field).

## Render idioms

Three, for one job. Pick by what the piece is:

| Idiom | Where | Use it for |
|---|---|---|
| **lit `render(template, keptContainer)`** | most components (~26): the info bar, chips and their popovers, panels, the init row, the working set, `start_page.js` | anything redrawn while the user may be in it: lit keeps the nodes, so focus, typed text, an open `<details>` and a tooltip survive. **The default for new UI.** |
| **lit as a string builder**: `turn_html.js elementOf(template)`, `lists_view.js` (a fresh fragment, then `replaceChildren`) | history bubbles appended once; the session lists | a node built once and then owned by the DOM (history), or a list redrawn whole. `lists_view.js` throws away lit's diffing and binds card listeners per draw, with an `entering` tracker for its animations |
| **hand-built DOM** (`createElement`) | `question_cards.js`, `verdict_card.js`, `verdict_fresh.js`, `participant.js` (`el()`) and a few small ones | older pieces; don't add new ones this way |

Listeners: every factory is a page-lifetime singleton, so `addEventListener` without a remove is fine; a per-render
listener lands on a fresh node. A popover goes through `chip_popover.js createChipPopover` (its own outside-click,
Esc, placement and resize); `context_chips.js` and the lists' families/chains popovers (`families_view.js
createFamilyPop`) still place their own. Every popover behaves the same (`popover_modal.js`): a modal dialog
(`modalDialog`: `aria-modal`, Tab wraps inside it), the opener's `aria-expanded` (a lit-drawn chip writes
`aria-expanded="false"` statically; the shell flips it), Esc closes it and focus goes back to the opener
(`focusBack`), and its `:hover` tints (the opener's too) sit in `@media(hover:hover)`, so a tap on a phone leaves
none behind. `model_picker.js`, `command_list.js` (listboxes: the focus stays in the input), `ref_menu.js` (a menu)
and `update_sheet.js` (a native modal `<dialog>`) aren't popovers in that sense.

## Stale answers

The page switches sessions, reopens a popover or asks again while a fetch is out. An answer for the old ask must be
dropped. **`latest.js`** is the guard:

- `stillOn(get, at = get())`: `() => true` while `get()` is still `at`. For a one-off read about the open session
  (`const still = stillOn(openId); … await …; if (!still()) return;`). app.js has `openId = () => store.selected`.
- `createLatest(get)`: `begin()` gives a guard that also goes stale when a newer ask begins; `drop()` makes every
  ask out stale (a close, a reset). For a list that is re-read.

On it: `context_chips.js`, `project_picker.js`, `participants_panel.js` (`load`), `cards_place.js`
(`refreshCardBodies`), `stream_handlers.js` (`answer_display`), `working_set_view.js` (`fetchServer`) and app.js's
turn-end re-reads (`readTurnEnd`, `refreshTimingFromSession`, `mergeTurnTiming`) and init-row timers. Still by hand
(the id decides more than "drop it"): app.js `resync`/`retryResync` (the re-read budget, `resyncAgain`), the stream's
close, `session_actions.js` (continue/review open another session on purpose), `send_turn.js` (a failure for another
session becomes a toast), and `participant.js` (its own `loadSeq`, the separate page). A new await in a component
uses `latest.js`.

## API clients

- `data.js api(path, opts)`: the owner page's. Throws an `Error` with the server's words, `.status`, `.code` (the
  server's error code: match on it, never on the words) and `.body`; a signed-out proxy answer (401, a redirect,
  HTML) or a fetch that fails on a sign-in redirect reports to `auth_lost.js` (`onAuthLost`, set by app.js).
  `cantText(what, error)` is the toast.
- `method_api.js methodApi(method, path, body)`: the same, as `notifications.js` and `push_devices.js` call it.
- `participant.js api`: its own (see above).

## Streams

| Stream | Opened by | Lifecycle |
|---|---|---|
| The hub, `GET /api/events` (`data.js openEvents`) | app.js `openSessionEvents` (scoped by `?dir`) | `snapshot` then `session` / `session_gone` → `applySessionEvent` → `allSessions`; EventSource reconnects itself (a fresh snapshot); `onClosed` (a proxy sign-in on reconnect): probe, reopen after `EVENTS_REOPEN_MS` |
| A second hub stream, unscoped | `notifications.js` (`allEvents`) on a project's page | the Home Screen app's device tidy-up across projects |
| The open session, `GET /api/sessions/:id/stream?from_seq=` (`data.js openStream`) | app.js `startStream` from `store.current.streamSeq` | events → `stream_handlers.js`. It closes itself on an error; the page resyncs (`resync`: a fresh render and a new stream from its cursor), once at once when it had opened, else after `STREAM_RETRY_MS` |
| The participant stream | `participant.js connect` | listens for `STREAM_EVENTS`, which is `Web::ParticipantView::EVENTS` (checked by `spec/web/participant_view_spec.rb`); reopened from fresh data when CLOSED |

A new event type for the owner page is a handler in `stream_handlers.js` (the participant view spec makes it decide
`EVENTS` or `DROPPED`); for the participant page also an entry in `STREAM_EVENTS`.

## Storage keys

Through `storage.js` (`readStored`/`writeStored`: storage can throw, a missing value is the default), except
`notifications.js`, which takes an injected storage for its specs. Per-browser choices only: never anything that must
reach another device or the server.

| Key | Module | What |
|---|---|---|
| `chi_model`, `chi_model_recent` | `model_pick.js`, `model_picker.js`, `start_page.js` | the start page's model and its recent list |
| `chi_composer_collapsed` | `composer_fold.js` | the composer folded |
| `chi_composer_floor` | `composer_grip.js`, `composer_mount.js` | the composer's dragged height |
| `chi_strip_hidden` (`chi_zen`: the old name, read once) | app.js | the session strip hidden |
| `chi_stage_collapsed` | `stage_view.js` | the stage collapsed |
| `chi_working_set_collapsed` | `working_set_rail.js` | the working set rail collapsed |
| `chi_markdown_tip_dismissed` | `markdown_tip.js` | the markdown tip dismissed |
| `chi_update_available_shown` | app.js | update notices already shown |
| `chi_notify`, `chi_push_device` | `notifications.js` (an injected storage) | the bell's state, this device's push id |
| `chi_answer_fold:<session>` | `answer_fold.js`, `revise_stack.js` | the answers and long prompts (`<turn id>:prompt`) folded by hand, and the Revise stubs unfolded by hand (`stub:<turn id>`) (swept with the session list) |
| `chi_review_history:<grant>`, `chi_review_history_session:<session>` | `review_history.js` (participant page) | a participant's composer history |

sessionStorage: `chi_client_id` (`turn_events.js`: this tab's client id, kept over a reload mid-turn) and
`chi.authReloadAt` (`auth_lost.js`: one automatic reload a minute).
