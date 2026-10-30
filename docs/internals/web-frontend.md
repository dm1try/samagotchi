# The web frontend: where state lives

A map of `lib/samagotchi/web/public/` for whoever changes it: where the page keeps what it knows, how a change
reaches the screen, and the guards every new piece should use. The modules' own header comments say what each one
does; this page says how they hang together. The server side is [architecture.md](../architecture.md) (Web);
the working set's overlay is [working-set.md](working-set.md), participants are [participants.md](participants.md).

No build step: `index.html` and `participant.html` load ES modules as they are, with lit-html (`vendor/`) as the
only library. Pure modules (`*_model.js`, `session_state.js`, `sessions_list.js`, `turn_range.js`, …) touch no DOM
and have `node --test` specs under `spec/web/public/` (happy-dom for the DOM ones); the pages as a whole are covered
by `npm run e2e` (`spec/e2e/`). `app.js` has no unit spec.

**New exports go in new modules.** The static JS is served at unversioned URLs and cached: a new export on an
existing module, imported by a new version of another, finds the cached old module without it and blanks the page.
`answer_fold.js`, `turn_range.js`, `history_reveal.js`, `latest.js`, `session_payload.js` and `method_api.js` are
new modules for that reason.

## Two pages, two models

| Page | Entry | Model |
|---|---|---|
| **Owner page**: the start page and a session page | `index.html` → `app.js` | **Render once, then patch.** A session's open (`select` → `resync` → `renderSessionView`) draws the history from `GET /api/sessions/:id`; from then on each stream event changes the DOM in place (`stream_handlers.js`). The DOM *is* the log. The start page is the same app with `selected = null`. |
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
| **app.js module scope**: 22 top-level `let`s (`selected`, `current`, `allSessions`, `streamControl`, `eventsControl`, `pageCapabilities`/`pageEditorUrl`, `pendingVerifyAnchor`, `pendingClaim`, `resyncsInFlight`/`resyncAgain`, `resyncAttempts`, `scopeError`…) | the open session's id and the page's mode | app.js only; other modules get getters (`selected: () => selected`, `state: () => current`) and hooks | nothing reacts: the writer calls the redraw itself |
| **`current`** (`session_state.js`: `emptySessionState` / `sessionStateFrom`) | the open session's fields, about 40 (info bar, chips, verdicts, timing, worker, stream cursor) | app.js, `stream_handlers.js` (through `state()`), `send_turn.js` (`firstPreview`, `owner`), `session_actions.js` (`status`) | the writer calls the field's redraw (the table below) |
| **`allSessions`** (the hub's projection) | every card | app.js: `openSessionEvents` (`applySessionEvent`), `refresh` (the list fallback), `addCreatedSession`, `replaceSelectedCard` (`setLiveStatus`, `readTurnEnd`, `setUsedMemories`), the stream's close (`withoutWorker`); `session_actions.js` (`setSessions`) | `lists.render()`. An entry is **replaced, never changed in place**. `followSelectedSession` copies the open one's owner, worker and (when not streaming) status into `current` |
| **Factory closures**: the `create*` factories (popovers, panels, views) | each component's own state: open-for, busy, error, its own fetched list | the factory | an `onChange` hook back into app.js, or a getter the factory reads at draw time |
| **The history DOM** | the conversation as drawn: which turn a bubble belongs to (`data-turn-id`, `data-answer-turn`), kept command bubbles, which texts were shown, unnamed badges, folded answers (`.folded`) | `bubbles.js`, `cards_place.js`, `question_cards.js`, `turn_view.js`/`stage_view.js`, `answer_fold.js` | read back as state: `turn_range.js turnElements` (one walker for a turn's elements), `keptCommandBubbles`, `seedSeenFromDom`, `nameUnnamedBadges`/`nameVerdictCards`, `answer_fold.js` (its observer decorates every path that fills `#history`), `history_reveal.js revealInHistory` (the one way a jump unfolds what hides its target) |
| **localStorage** (`storage.js` `readStored`/`writeStored`, guarded) | per-browser choices only | the module that owns the choice | read at start (see Storage keys) |
| **SSE** | see Streams | the server | owner page: events go into the DOM directly; participant page: an event marks the data stale |

The start page's own choices (the model, the ⚙ panel, the 🧰 list) live in `start_page.js`'s closure, never in
`current`. A fresh chain link's picker reads both.

## Writes and their redraws

Nothing subscribes to `current`: **whoever writes `current.X` calls X's redraw.** This table is the checklist for
a new field or a new writer (and the list a store would take over).

| Field(s) | Writers | Redraw after the write |
|---|---|---|
| (a whole new object) | `forgetSession` (select, clearSelection) | everything: `updateInfoBar()`, `updateComposerMode()` |
| every payload field | `renderSessionView` (`Object.assign(current, sessionStateFrom(data))`) | `llmContextControl`/`thinkingControl`/`reasoningHistoryControl.refresh()`, then `updateInfoBar()`, `updateComposerMode()` at its end |
| `status` | `followSelectedSession` (hub, only while not streaming), `setLiveStatus` (stream), `readTurnEnd` and the turn_canceled re-read (`applySessionPayload`), `session_actions.js stoppedWorker`, the payload | `updateInfoBar()`; `lists.render()` when the card changed too. Six writers, order decides: the hardest field to change safely |
| `owner` | `followSelectedSession`, the stream's close (`worker` → null), `send_turn.js` and `composerCommands.ownedByTui` (`owned_by_tui` → `"tui"`) | `updateInfoBar()` and `updateComposerMode()` (a terminal's session turns the composer off) |
| `workerVersion`, `workerFeatures`, `bridgeUp` | `followSelectedSession`, the stream's close (`bridgeUp`) | `updateInfoBar()`; a flip of the Verify gate also `redrawFresh(historyEl, verifyFreshState())` |
| `usedMemories`, `promptNotes` | `setUsedMemories` (stream), `readTurnEnd` | `updateInfoBar()`; `usedMemories` also replaces the card → `lists.render()` |
| `timing` (and `timing.tokens`, `.modelSegments`, `.side`) | `mergeTurnTiming` (`readTurnEnd`, the turn_canceled re-read), `stream_handlers.js` (`generation_completed`, `side_usage`) | `updateInfoBar()` |
| `ctxPct`, `ctxWindow`, `ctxWindowSource`, `ctxUnknownAfterSwitch` | `stream_handlers.js` (`generation_chunk`, `generation_started`, `context_status`) | `updateInfoBar()` |
| `model`, `served` | `stream_handlers.js` (`command_ran` of /model, `generation_completed`) | `updateInfoBar()`; a new model also `syncModelPick()` |
| `llmContext` | `command_ran` | `updateInfoBar()`, `llmContextControl.refresh()`, `workingSet.strategyChanged()` |
| `thinking` | `command_ran` | `updateInfoBar()`, `thinkingControl.refresh()` |
| `reasoningHistory` | `command_ran` | `updateInfoBar()`, `reasoningHistoryControl.refresh()` |
| `toolkit` | `command_ran`, `hook_notice` (`ctx.use_toolkit`) | `updateInfoBar()` |
| `firstPreview` | `send_turn.js` (the first prompt) | `updateInfoBar()` (it calls `updateSessionTitle()`) |
| `verdicts`, `verifyFresh` | `placeVerdict` | the card itself (`placeVerdictWithFresh`) |
| `turnStarted` | `setTurnRunning` | `updateComposerMode()`, `updateInfoBar()` (in `setTurnRunning`) |
| `attachCopiedAt` | the info bar's copy button | `updateInfoBar()` |
| `streamSeq`, `streamFromGuess` | `resync`, `followWokenWorker`, `startStream`, the stream's `takeGuess` | none (not drawn) |

The redraws:
- `updateInfoBar()` (≈45 call sites): the session bar's buttons and info line (`info_bar_model.js sessionBar` →
  `info_bar.js`), the annotate bar, the fold controls, `updateSessionTitle()` and the fresh link's picker. Cheap;
  call it rather than skip it.
- `updateComposerMode()`: the composer's placeholder, buttons and delivery line (selected, running, owner).
- `xControl.refresh()`: an info-bar chip's **open popover** (the chip itself is drawn by `updateInfoBar`).
- `lists.render()` / `lists.paintActive()`: the strip and the all view from `allSessions`.

A partial re-read of the open session (a `?tail`/`?recent` read) goes through **`applySessionPayload(data,
{fields})`** in app.js (`session_payload.js sessionFieldsFrom`): the named fields read as a full load reads them,
a field whose source the payload doesn't carry left alone. Then call the redraw. Never copy payload keys into
`current` by hand. A new `current` field starts in `emptySessionState` (the spec checks that every field
`sessionStateFrom` sets is there).

`forgetSession()` is the one reset: `select` and `clearSelection` both call it, so anything per-session that isn't
in `current` (capabilities, the markdown warning and tip, the init row, the Verify claim, the turn view) is cleared
there. A new per-session holder goes into it.

## Render idioms

Three, for one job. Pick by what the piece is:

| Idiom | Where | Use it for |
|---|---|---|
| **lit `render(template, keptContainer)`** | most components (~26): the info bar, chips and their popovers, panels, the init row, the working set, `start_page.js` | anything redrawn while the user may be in it: lit keeps the nodes, so focus, typed text, an open `<details>` and a tooltip survive. **The default for new UI.** |
| **lit as a string builder**: `turn_html.js elementOf(template)`, `lists_view.js` (a fresh fragment, then `replaceChildren`) | history bubbles appended once; the session lists | a node built once and then owned by the DOM (history), or a list redrawn whole. `lists_view.js` throws away lit's diffing and binds card listeners per draw, with an `entering` tracker for its animations |
| **hand-built DOM** (`createElement`) | `question_cards.js`, `verdict_card.js`, `verdict_fresh.js`, `participant.js` (`el()`) and a few small ones | older pieces; don't add new ones this way |

Listeners: every factory is a page-lifetime singleton, so `addEventListener` without a remove is fine; a per-render
listener lands on a fresh node. A popover goes through `chip_popover.js createChipPopover` (its own outside-click,
Esc, placement and resize); `context_chips.js`, `model_picker.js`, `ref_menu.js`, `command_list.js` and the lists'
families/chains popovers still hand-roll theirs.

## Stale answers

The page switches sessions, reopens a popover or asks again while a fetch is out. An answer for the old ask must be
dropped. **`latest.js`** is the guard:

- `stillOn(get, at = get())`: `() => true` while `get()` is still `at`. For a one-off read about the open session
  (`const still = stillOn(openId); … await …; if (!still()) return;`). app.js has `openId = () => selected`.
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
| The open session, `GET /api/sessions/:id/stream?from_seq=` (`data.js openStream`) | app.js `startStream` from `current.streamSeq` | events → `stream_handlers.js`. It closes itself on an error; the page resyncs (`resync`: a fresh render and a new stream from its cursor), once at once when it had opened, else after `STREAM_RETRY_MS` |
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
| `chi_answer_fold:<session>` | `answer_fold.js` | the answers folded by hand (swept with the session list) |
| `chi_review_history:<grant>`, `chi_review_history_session:<session>` | `review_history.js` (participant page) | a participant's composer history |

sessionStorage: `chi_client_id` (`turn_events.js`: this tab's client id, kept over a reload mid-turn) and
`chi.authReloadAt` (`auth_lost.js`: one automatic reload a minute).
