# The web frontend: where state lives

A map of `lib/samagotchi/web/public/` for whoever changes it: where the page keeps what it knows, how a change
reaches the screen, and the guards every new piece should use. The modules' own header comments say what each one
does; this page says how they hang together. The server side is [architecture.md](../architecture.md) (Web);
the working set's overlay is [working-set.md](working-set.md), participants are [participants.md](participants.md).

No build step: `index.html` loads ES modules as they are, with lit-html (`vendor/`) as the
only library. Pure modules (`*_model.js`, `session_state.js`, `sessions_list.js`, `turn_range.js`, …) touch no DOM
and have `node --test` specs under `spec/web/public/` (happy-dom for the DOM ones); the pages as a whole are covered
by `npm run e2e` (`spec/e2e/`). `app.js` has no unit spec of its own; `viewer_boot.test.js` boots the whole page
(`page_boot.js`, happy-dom, in a process of its own) for what each viewer gets (The viewer, below).

**Every module has a size cap, `app.js` its own**: `npm run lint` fails past `max-lines` in `eslint.config.js`
(counted as `wc -l` counts, comments and blank lines too). Every `public/*.js` module: 1200 (`samagotchi/module-size`,
about 10% over the largest, `turn_block.js`), so a module near it splits rather than becoming the next `app.js`.
`app.js` (`samagotchi/app-size`): 1649, its size plus 50 once the session-open flow went into `session_sync.js` and
`session_view.js`; ratcheted down from 2000, itself down from 2250 when the versions, the owner's claim links and
Verify, the composer's mode and the strip's hide went into modules of their own. A new feature goes into a module of
its own, wired from `app.js` in a few lines; a refactor that shrinks `app.js` ratchets its cap down with it. Never
raise either: extract instead.

**New exports go in new modules.** The static JS is served at unversioned URLs. Today every load revalidates
(app.rb `serve_static` sends `Cache-Control: no-cache` with a content ETag, and `sw.js` has no fetch handler), but an
open tab still holds the modules it loaded, and a proxy that ignores `no-cache` can serve an old one: a new export
on an existing module, imported by a new version of another, then finds the old module without it and blanks the
page. A factory dep a new version stops passing is the same hazard the other way round: the store's redraws took
`updateInfoBar` and the chip controls out of `stream_handlers.js`'s deps (and `updateInfoBar`/`updateComposerMode`
out of `send_turn.js`, `session_actions.js` and `lists_view.js`); a page loaded before keeps all its old modules
until a reload, so the risk is a mixed cache, not an open tab. `answer_fold.js`, `details_motion.js`,
`turn_range.js`, `history_reveal.js`, `latest.js`, `session_payload.js`, `method_api.js`, `session_store.js`,
`session_fields.js`, `feature_gates.js`, `revise_stack.js`, `revise_switch.js`, `shell_command.js`, `stale_params.js`, `popover_modal.js`, `more_sheet.js`, `hash_intent.js` (what the hash asks for: session, all, start or keep), `worker_features.js`, `version_notices.js`, `owner_claim.js`, `owner_verify.js`, `composer_mode.js`, `strip_hidden.js`, `block_open.js`, `text_roots.js`, `block_source.js`, `block_frame.js`, `block_host.js`, `block_watch.js`, `card_stamps.js`, `recap_stamp.js` (a saved recap's place by its `opening_id` stamp, else its count), `inline_widgets.js`, `widget_walk.js`, `widget_picks.js`, `history_shape.js` (the history's shape, live against a reload: the e2e reload checks and the opt-in reload check share its normalizer and its `ACCEPTED` allowlist), `turn_pieces.js` (a finished turn's one order and its answer rule: the live hand-off's `handOffOrder` and `turnEnded`, and a reload's `turnHistoryNodes`), `reload_check.js` (the opt-in `web.reload_check`: after the stage's hand-off, the turn against a reload of it, the counts posted; it compares the turn's own cards and questions, dropping every entry CardStore attributes to another turn), `cards_offscreen.js` (the reload check's placer: `createCardsPlace`, `createBubbles` and `createQuestionCards` over a detached holder, every page hook inert - no stage, no scroll, no session id, no api, no storage - so a snapshot's cards land where a reload would put them without touching the page), `turn_drawing.js` (a finished turn's drawing, `turn_drawings` in the show: its fold into steps and its end kind; `turn_block.js` draws it), `stage_stall.js` (the stage's quiet signal), `history_end.js` (the stage's one move of pieces to the history's end), `stage_opened.js` (a running turn opened in the history while a card waits: the lead-in bubble, the moves, the end fold), `stage_asking.js` (the stage's docked card and its fold: the docking and lead-in rules, the opening, a waiting card's own toggle, the folded row's text per kind, the fold's choice, reveal and the docked card's fold; `stage_view.js` wires it), `stage_waiting.js` (the stage's waiting cards as data, keyed by `data-qid` / `data-card-id`: kind, docked, approval, the stage's order, the shown card and its pager, the docked card's fold, kept for this tab in `chi_asking_fold:<session>`; `front`, `count`, `shown`, `blocking`), `stage_cards.js` (the cards that wait in the stage: `PENDING`, `ASKS`, `waitsInStage`, read by `stage_model.js placeKind`), `resync_reach.js` (a re-read that can't reach chi web keeps the drawn history; the status chip says retrying / offline, outside a turn), `session_sync.js` (the open session's sync: `select`, `resync` and its retries, the stream's life; the stream handle and the re-read bookkeeping are its own), `session_view.js` (the open session's view: `renderSessionView` draws a read, `forgetSession` resets the page for another session, `readTurnEnd`, `endTurnView`; app.js makes both right after the cards, each reaching the other and the later views through getters), `participant_main.js`, `participant_bar.js`, `viewer_self.js`, `stage_owner_wait.js`, `participant_revise.js` (a participant's page: The participant's page, below), `ws_timeline.js`, `ws_cards.js`, `ws_peek.js`, `ws_reader.js`, `ws_way_in.js` (what chi has of a working-set item: below, The working set's reader), `no_contact_fill.js` (a text field that isn't a contact form: autocomplete off and a name with no contact word, against iOS Safari's AutoFill Contact bar; a template's fields carry the same attributes, and its spec checks the page's markup for them) and the `objectives_*.js` modules are new modules for that reason. The last four `block_*` draw fenced blocks (`block_watch.js` finds and watches them, `block_host.js` is its frame drawer for a bundle's renderers): [block-renderers.md](block-renderers.md). `inline_widgets.js` is its core drawer for `chi-ui` blocks, drawing `widget_walk.js`'s and `widget_picks.js`'s widgets in a shadow root styled by `widgets.css`: [inline-widgets.md](inline-widgets.md).

## One page, every viewer

| Page | Entry | Model |
|---|---|---|
| **The main page**: the start page and a session page, the owner's and a participant's | `index.html` → `app.js` | **Render once, then patch.** A session's open (`session_sync.js` `select` → `resync` → `session_view.js` `renderSessionView`) draws the history from `GET /api/sessions/:id`; from then on each stream event changes the DOM in place (`stream_handlers.js`). The DOM *is* the log. The start page is the same app with `store.selected` null. |

A participant's link opens the same page: chi web serves them `index.html` stamped with
their viewer (The viewer, below), their show and stream are filtered (`Web::ParticipantView`,
[participants.md](participants.md#what-a-participant-sees)), and what is theirs on the page is
`participant_main.js` (The participant's page, below). There is no second page: the participant page
(`participant.html`, `participant.js`, `GET …/review`) went with the participant main page's Phase C.

## Where state lives (owner page)

| Holder | What | Who writes | How a change reaches the screen |
|---|---|---|---|
| **The session store** (`session_store.js`; app.js `store`) | `store.selected` (the open session's id), `store.current` and `store.sessions` (below) | through the store only (see The session store); other modules get getters (`selected: () => store.selected`, `state: () => store.current`) or the store itself (`stream_handlers.js`, `send_turn.js`, `session_actions.js`) | the store runs the redraws that read what changed (below); nobody calls them by hand |
| **app.js module scope**: about a dozen top-level `let`s (`eventsControl`, `pageCapabilities`/`pageEditorUrl`, `scopeError`…); the open session's stream handle and re-read bookkeeping (`streamControl`, `resyncsInFlight`/`resyncAgain`, `resyncAttempts`) are `session_sync.js`'s, in its closure | the page's mode and its streams | their module only; other modules get getters and hooks (`sessionSync.hasStream()`: a stream object, also while it connects, the bar's streaming; `streamLive()`: it delivers) | the writer touches the redraw that reads it (`store.touch("infoBar")`: the stream; `version_notices.js` does it for the versions and its `restarting` set), or calls a redraw only it feeds |
| **`store.current`** (`session_state.js`: `emptySessionState` / `sessionStateFrom`; per field: `session_fields.js FIELDS`) | the open session's fields, about 40 (info bar, chips, verdicts, timing, worker, stream cursor) | `store.update` / `setStatus` from app.js, `stream_handlers.js`, `session_sync.js`, `session_view.js`, `send_turn.js` (`firstPreview`, `owner`), `session_actions.js` (`status`), `owner_verify.js` (`verdicts`, `verifyFresh`); `forgetSession`'s `replaceCurrent` (`session_view.js`). Two writers in place, on purpose (D8 in `FIELDS`): live_timing.js's `activeTurn`, verdict_fresh.js's running list | the store runs the field's redraws (`FIELDS[key].redraws`) |
| **`store.sessions`** (the hub's projection) | every card | `store.update({sessions})` from app.js: `openSessionEvents` (`applySessionEvent`), `refresh` (the list fallback), `addCreatedSession`, `applyView` (re-sorted), `replaceSelectedCard` (`setLiveStatus` through `setStatus`, `readTurnEnd`, `setUsedMemories`), the stream's close (`withoutWorker`); `session_actions.js` (`setSessions`) | the store: `lists` and `infoBar`. **Always a new array**; an entry is replaced, never changed in place. `followSelectedSession` copies the open one's owner and worker (`fieldsFromCard`) and, when not streaming, its status (`setStatus(…, "hub")`) into `store.current` |
| **Factory closures**: the `create*` factories (popovers, panels, views) | each component's own state: open-for, busy, error, its own fetched list | the factory | an `onChange` hook back into app.js, or a getter the factory reads at draw time |
| **The history DOM** | the conversation as drawn (a running turn's reason bubble, `.bubble.said`, is live only: see A turn opened in the history): which turn a bubble belongs to (`data-turn-id`, `data-answer-turn`), what opens a turn (`TURN_PROMPT`, `bubbles.js`: a prompt or a wake's note, the same turns `Steer.turn_opening?` counts for a card's `turns_since`), an opening's id for a card's and the saved recap's stamp (`data-turn-id` on a prompt, `data-opening-id` on a wake's note or `/continue no`'s reason line; `card_stamps.js` places a snapshot's card after the stamped opening, `recap_stamp.js` the saved recap after the last turn it covers, each by its count (`turns_since`) only without one), kept command bubbles, which texts were shown, unnamed badges, folded answers and long prompts (`.folded`), Revise stamps (`data-revises` on a prompt; a Verify turn's `data-verify`) and the stacks' folded versions (`.stack-hidden`, `.stack-stub.open`); the switcher's version on view is `revise_stack.js`'s own (a copy `.stack-view` before the top answer, the top `.stack-swapped`; never stored) | `bubbles.js`, `cards_place.js`, `question_cards.js`, `turn_block.js`/`stage_view.js`, `answer_fold.js`, `revise_stack.js`, `stream_handlers.js` (a live `turn_completed`'s `revises` and `verify` onto its prompt) | read back as state: `turn_range.js turnElements` (one walker for a turn's elements), `keptCommandBubbles`, `seedSeenFromDom`, `nameUnnamedBadges`/`nameVerdictCards`, `answer_fold.js` and `revise_stack.js` (their observers decorate every path that fills `#history`; the stacks are `stacks()` of the stamps, read again on each change, never a store field), `history_reveal.js revealInHistory` (the one way a jump unfolds what hides its target) |
| **A drawn turn** (`turn_drawings` of the full read) | every finished turn, as live drew it: `turnGroups` groups by the stamps only, a turn's stamped items (`drawn: <turn_id>`) one group, and `turnHistoryNodes` draws it by feeding its drawing's events to a live turn block offscreen (`turn_block.js drawnTurnNodes`: the block's own handlers, as the stage's), the stage's extras (a reminder, merged lines, a card that asks or warns) and end as live, then the answer, the merged lines and the steps' texts from their saved items (markdown, refs). Each of its top-level elements carries `data-drawn`: `cards_place.js` leaves that turn's in-turn CardStore entries (`of_turn`) to it, and a kept reminder bubble of that turn (`data-turn-id`) stays out after a resync. chi web sends a drawing for every finished turn (one made from its messages where live wrote none): `drawnGroup` pairs the record the end names (`end.record_id`, by place for a turn saved before turn ids), else by the turn's id, and the answer's `data-answer-turn` is the end's own `turn_id` only (a made-up id, `m…` or `…~N`, keys none: no Revise). Nothing is rebuilt from messages: an item that comes unstamped is a `plain` group drawn as a plain row of its text (its prompt or answer bubble, no steps), the running turn's as expected (`runningTurnId`, the show's `current_turn`: it has no line yet), any other a miss, marked `data-undrawn`, logged once per render (`console.warn`) and counted by the reload check (`undrawn`), never a throw; a drawing with no parts (a minimal line) draws its prompt, answer and end | chi web (the show) | `renderHistory`, the reload check's render |
| **localStorage** (`storage.js` `readStored`/`writeStored`, guarded) | per-browser choices only | the module that owns the choice | read at start (see Storage keys) |
| **SSE** | see Streams | the server | events go into the DOM directly (a participant's through `participant_main.js wrapHandlers` first) |

The objectives' strip keeps the list in its own closure (`objectives_strip.js`, seeded by `renderSessionView`, reset by
`forgetSession`, updated by `objectives_updated`): [objectives.md](objectives.md#the-page).

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

The ESLint block `samagotchi/session-writes` (eslint.config.js) enforces it in the nine modules that hold the state
(app.js, `stream_handlers.js`, `send_turn.js`, `session_actions.js`, `start_page.js`, `working_set_view.js`,
`owner_verify.js`, `session_sync.js`, `session_view.js`): an
assignment, `++`, `delete` or `Object.assign` into `current`, `store.current` or `state()` is an error
(`spec/web/public/lint_session_writes.test.js` runs it on a sample). An alias (`const st = state(); st.x = …`) isn't
caught: don't write through one.

**Read `store.current` fresh after every await.** A `const cur = store.current` held across an await pins the object
from before it, which a session switch (`forgetSession`) may have replaced: app.js's `mergeTurnTiming` and
`refreshTimingFromSession`, `session_view.js`'s `readTurnEnd` and `session_sync.js`'s `resync` read it again after each await. Keep `store.sessions`
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
`composerMode.update()` (`composer_mode.js`), `infoBar` → `updateInfoBar()`. A writer writes and stops there: no `updateInfoBar()` after
a store write. A value written unchanged redraws nothing (a chunk with the same ctx %).

An input the store doesn't hold calls `store.touch(name)` where it changes: `infoBar` for the clock (liveTurn's
`onTick`), the versions and the sessions restarting (`version_notices.js` `notice`, `restart`), the stream (`session_sync.js` `startStream`, `workerGone`), the working
set's and the participants' `onChange`, the continue in-flight set
(`session_actions.js`); `composer` and `infoBar` for `liveTurn.running` (`setTurnRunning`, with `settingsPanel`:
the open ⚙ panel's running-turn note) and at the end of `renderSessionView` (a whole view drawn). Left as they are,
on purpose: `composer_mode.js`'s phone-width listener calls its `update()` (the bar doesn't read it),
`strip_hidden.js`'s apply and `applyView` call `updateSessionTitle()`, and `session_sync.js`'s `closeStream`/`restart`
(the stream handlers' `stream.restart`) drop the stream handle without a redraw (a resync or a workerGone follows).

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
the gates in the batch of their write, and nothing fires. Today three gates: `verify` (Verify fresh on a verdict's
card, `redrawFresh`), `revise` (the answers' Revise buttons and the composer's Revising chip, `redrawRevise`) and
`objectivesTrack` (the objectives' Where are we?, in the list and on the no-move line, `objectives.redraw`).
All refuse only a live worker without the feature — `workerPredates(features, up, feature)` in
`worker_features.js`, the rule both gates share: a worker that isn't up is woken by the send as a new one, which
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
- `composer` (`composer_mode.js` `update()`): the composer's placeholder, buttons and delivery line (selected, running,
  owner).
- `settingsPanel` (`settingsControl.refresh()`): the ⚙ chip's **open panel** (`settings_chip.js`; the chip itself is
  drawn by the bar), on `thinking`, `reasoningHistory` and `llmContext`; `workingSetStrategy`: the working set's open
  list.
- `lists` / `paintActive` (`lists.render()` / `lists.paintActive()`): the strip and the all view from
  `store.sessions`.
- `featureGates`: the gates above.

`forgetSession()` (`session_view.js`) is the one reset: `select` and `clearSelection` both call it, so anything per-session that isn't
in `store.current` (capabilities, the markdown warning and tip, the init row, the Verify claim, the armed Revise,
the running turn's DOM) is cleared there, and the feature gates are primed for the empty session. A new per-session holder
(an armed composer anchor like the Verify claim or the Revise) goes into it. The armed Verify claim is
`owner_verify.js`'s holder (`anchor()`, `set(a)`, `clear(a?)`: `clear(a)` lets go only of `a`). The armed Revise
(`pendingReviseAnchor`) is set only through `setReviseAnchor`, which redraws its chip and the Revise buttons (a
redraw only it feeds, not a store field).

## The viewer

Who looks at the main page and what they may do there is the **viewer** (`viewer.js`), chi web's `Web::Viewer`
(`lib/samagotchi/web/viewer.rb`: `Viewer.for(principal)` is the one place that decides it; the owner gets every
capability). chi web stamps it on `<body>` (`data-viewer-kind`, `data-viewer-can`: the names, space-separated;
`App#index_data_attributes`), and the owner's session show carries it as `viewer` next to `capabilities`. app.js
makes one `viewer` from the body at boot; `setCapabilities` passes a show's `viewer` to `viewer.update` (it narrows
the stamp, never widens it: the boot's controls were made from the stamp) and `forgetSession`'s
`setCapabilities(null, null)` resets it to the stamp. A page with no stamp may do nothing. It is not the show's
`capabilities` (what the page renders: markdown display, the editor) nor `refEditor()` (where a ref opens: the
editor and its URL, refs.js's actions): those two are per request.

**The null-control rule.** An owner-only control or call goes through `viewer.can(name)` where it is made, never at
each use: a control the viewer may not use is not created and not wired (`const x = viewer.can("…") ? createX(…) :
null`, then `x?.…` where it is read; a module's hook passed as `null`, as `stage_view.js onCancel`,
`working_set_view.js sendLine`, `composer_mount.js loadHistory`), and its static element in `index.html` stays hidden
(`viewer.control(el, name)` / `controls(els, name)`: the element when allowed, else hidden, marked `data-withheld`
and `null`; index.html's `[data-withheld]{display:none!important}` beats an element's own `display` rule, which a
bare `hidden` does not). A module the
page reads everywhere takes a flag instead (`question_cards.js answers`, and `block_host.js renderers`). No scattered `if (owner)`, and no 403 tolerated as a way of gating. The
gates are boot-time: a show's narrower `viewer` changes what `viewer.can` answers later, not the controls made.

| Capability | Controls | Calls |
|---|---|---|
| `sessions` | `#newBtn`, `#scope` (and `project_picker.js`), `#topStrip`, `#stripStatus`, `#stripGrip` (`strip_hidden.js`) | `refresh` (`GET /api/sessions`), `openSessionEvents` (`GET /api/events`), `/api/projects` |
| `models` | `#modelPick` (never shown without the list) | `startPage.loadModels` (`GET /api/models`) |
| `prompt_history` | ↑/↓ over the prompt history | `GET /api/history` (`loadHistory`) |
| `push` | `#notifyBtn` (`notifications.js` not made; the tab title is set directly) | `/api/push*`, presence, the second `/api/events` stream |
| `context` | the context chips (`context_chips.js`) | `…/context*` |
| `working_set` | the stage's working set (`working_set_view.js`) | `GET …/working_set` |
| `working_set_items` | the list rows' `▸` peek, the reader over the stage, a tool row's `timeline`, the ref menu's "What chi has" (`ws_reader.js createWorkingSetPreview`: not made without it, so `working_set_view.js` gets `peek: null`, `ws_way_in.js` stays off, `installRefClicks` gets `whatChiHas: null`) | `GET …/working_set/item` (on a tap only) |
| `participants_admin` | the participants chip and panel, Copy link's participant target (`claimTarget`) | `…/participants*` |
| `rename` | `#titleRenameBtn` | (`/title` goes as a session command) |
| `images` | `#attachBtn`, `#attachInput`; paste and drop toast `IMAGES_NOT_HERE` | `POST …/images` |
| `session_controls` | `#infoContinueBtn`, `#infoArchiveBtn`, `#infoStopBtn`, `#infoDeleteBtn`, `#infoMoreBtn` (the ⋯ sheet), the ⚙ chip and panel, the `/` list, the stage's task stop, the working set's drop/undrop | `POST …/command` (`composer.js`: without it a `/` or `!` line goes as a turn, and the worker decides), `…/stop`, `…/holds*`, `…/tasks/:id/stop`, `…/reload_check`, continue → (`POST /api/sessions`) |
| `revise` | the answers' Revise (`revise_stack.js`) | (a Revise goes with `POST …/turn`) |
| `revise_own_turn` (a participant's) | Revise on the answers to their own messages (`participant_revise.js`, `revise_stack.js mayRevise`); the stacks for everyone | (`POST …/turn` with `revises`, checked by chi web) |
| `answer_cards` | question, approval and continue cards (`question_cards.js`), System 1's "wrong" | `…/answer`, `…/question/dismiss`, `…/guardrails/wrong` |
| `render` | | `POST /api/render` (`markdown_place.js`: step texts, a question's kept reply) |
| `block_renderers` | a bundle's drawn blocks (the core `chi-ui` drawer stays) | `/api/block_renderers*` |
| `stop_any_turn` | the stage's Stop turn (`onCancel`) | `POST …/cancel` |
| `steer_any_turn` | none: the delivery line reads a participant's own `steer_own_turn` instead (`viewerTurn`) | |

A participant's `can` (`Viewer::PARTICIPANT_CAPABILITIES`, in their show's `viewer` and on `<body>`) names
capabilities of their own, not the owner's: `send` (the composer), `stop_own_turn` (Stop turn on a turn they
started, `POST …/cancel` with its `turn_id`), `steer_own_turn` (a message during their own turn goes in at its next
step, on a worker with `participant_steer`), `revise_own_turn` (Revise on the answer to their own message); and of the owner's only `working_set` and `images`, which their routes
serve filtered: the working set's project files ([participants.md](participants.md#the-main-pages-show)); their own
uploads within their cap and quota, read back only by them ([participants.md](participants.md#participant-images)).
Their messages carry their own images as refs (thumbnails) and anyone else's as a count, which `images.js
thumbsTemplate` draws as a muted "N images" line (`.thumbs-hidden`). `stop_any_turn` / `stop_own_turn` both make the
stage's Stop turn (`onCancel`); a participant's shows on their own turn only (`stage_view.js canCancel`).

The owner routes (`App::ROUTES` rows marked `:owner`) the page never calls without one of the above:
`/api/update*` and `…/restart` (`version_notices.js`: its versions come only from the hub stream, `sessions`);
`…/archive`, `…/unarchive`, `DELETE …/:id` (the bar's buttons, `session_controls`; the strip and the all view,
`sessions`); `POST /api/sessions` from the start page (a participant's page opens the grant's session and never the start
page); `GET …/images/:file` (a message's image refs; a
participant's messages carry refs only for their own uploads, the one image a participant's route serves them); the objectives strip's posts and the plugin cards' actions (`…/command`:
drawn only from the show's `objectives` / `cards` and their stream events, which `ParticipantView` drops). Not called
by the page at all: `/api/sessions/summaries`, `…/output`, `…/notes`, `…/wake`, `…/worker`, `…/exit`, `…/recap`,
`…/stats`, `…/children/counts`, `…/turns/:id/records`, `/api/participants`. `viewer_boot.test.js` pins the table:
with every capability today's calls and controls, with none no owner call and no owner control, each one alone,
and a participant's (their show, the working set and their stream, nothing else).

## The participant's page

What is a participant's on the main page is `participant_main.js`, made by app.js only when `viewer.kind()` is
`participant` (`participant`, null on the owner's page) and wired in a few lines; its pure views are
`participant_bar.js`. The page stays the owner's model (render once, then patch); the participant's parts only read:

- **One session.** `<body data-session>` (the grant's) is the session `selectFromHash` opens, whatever the hash
  names (an old `#s=ID` link, a claim link's `#s=…&t=…&q=…`, which `owner_claim.js` still shows); `allViewOpen` is
  never true; there is no start page.
- **Who they are** (`viewer_self.js`): set from each show's `viewer` (`setCapabilities` → `participant.shown`),
  since `<body>` names no ids. `turn_events.js isOwn` counts their client id (`review:<grant>`, chi web's for every
  tab of theirs) as the tab's own; a `turn_started` with `mine` starts their queued bubble (`bubbles.js
  queuedOwnBubble`: no origin names its enqueued id to them). `turn_html.js userBubbleTemplate` gives their echo
  their badge and the owner's prompts the "owner" label; `participant_names.js authorBadgeText` reads their turn as
  the name alone for them (an older chi's read-only turn "· read-only").
- **The rows.** The top row: a plain logo (`.plain-brand`, not `#newBtn`), their name ("Alex · invited") and, on a
  desktop, when the link ends. The bottom row (`#participantBar`) in `#infoText`'s place, drawn by the `infoBar`
  redraw (`updateInfoBar` returns early): status, ctx %, the last speed (the turn's time while one runs), their
  spend of the cap, and on a desktop what their turns may do (`RULES_TEXT`). Never the owner's cost, the model,
  memories or a path.
- **The running turn.** `wrapHandlers` wraps `stream_handlers.js`'s handlers: `turn_started`'s author and `mine`
  decide Stop turn (`canCancel`) and the delivery line (`deliveryTurn` → `delivery_line.js viewerTurn`: their own
  turn on a `participant_steer` worker takes the message at its next step, Alt+Enter queues; anyone else's queues it
  as their own turn) and the placeholder (`composer_mode.js steers`); `question_requested` / `continue_offered`
  (their `kind` alone) set the stage's waiting look (`stage_owner_wait.js`, through `stage_view.js ownerWait`), no
  card; a turn's end reads the show again for their usage (the light re-reads carry no viewer).
- **The closed composer** (`#participantClosed`): their cap reached (the show's `cap_reached`, or a send refused
  `cap_reached`: the show read again), a send refused `session_stopped`, or a link that ended (`token_revoked`,
  `token_expired`: a refused send's words, or `linkEnded`, `onAuthLost`'s handler, from a brief read's 401). The
  refusals show the server's `detail` as it is (`send_turn.js closesOn`); every other refusal is the toast.
- **Revise** (`participant_revise.js`): the stacks are installed for `revise_own_turn` too, so their page folds every
  stack (the owner's included); the Revise button is `installReviseStacks`' `mayRevise`, `participantMayRevise`:
  `mayReviseOwn` mirrors `ParticipantRevise` on `historyTurns`' list (their prompt's `data-author` or this tab's
  echo, an answer, no `data-verify`, and only their own turns after it), false while the composer is closed
  (`participant.closed()`; `onClosed` redraws on a flip). The gate is the `participant_revise` feature, its words
  `PARTICIPANT_REVISE_UNAVAILABLE`, the one page copy of `ParticipantMessages::REVISE_UNAVAILABLE`. A send refused
  `revise_not_own` / `revise_overtaken` is a failed line with the server's `detail`, the text and the chip kept
  (`send_turn.js`).

## Render idioms

Three, for one job. Pick by what the piece is:

| Idiom | Where | Use it for |
|---|---|---|
| **lit `render(template, keptContainer)`** | most components (~26): the info bar, chips and their popovers, panels, the init row, the working set, `start_page.js` | anything redrawn while the user may be in it: lit keeps the nodes, so focus, typed text, an open `<details>` and a tooltip survive. **The default for new UI.** |
| **lit as a string builder**: `turn_html.js elementOf(template)`, `lists_view.js` (a fresh fragment, then `replaceChildren`) | history bubbles appended once; the session lists | a node built once and then owned by the DOM (history), or a list redrawn whole. `lists_view.js` throws away lit's diffing and binds card listeners per draw, with an `entering` tracker for its animations |
| **hand-built DOM** (`createElement`) | `question_cards.js`, `verdict_card.js`, `verdict_fresh.js` and a few small ones | older pieces; don't add new ones this way |

Listeners: every factory is a page-lifetime singleton, so `addEventListener` without a remove is fine; a per-render
listener lands on a fresh node. A popover goes through `chip_popover.js createChipPopover` (its own outside-click,
Esc, placement and resize); `context_chips.js` and the lists' families/chains popovers (`families_view.js
createFamilyPop`) still place their own. Every popover behaves the same (`popover_modal.js`): a modal dialog
(`modalDialog`: `aria-modal`, Tab wraps inside it), the opener's `aria-expanded` (a lit-drawn chip writes
`aria-expanded="false"` statically; the shell flips it), Esc closes it and focus goes back to the opener
(`focusBack`), and its `:hover` tints (the opener's too) sit in `@media(hover:hover)`, so a tap on a phone leaves
none behind. `model_picker.js`, `command_list.js` (listboxes: the focus stays in the input), `ref_menu.js` (a menu)
and `update_sheet.js` (a native modal `<dialog>`) aren't popovers in that sense.

**The session bar: one row** (`bar_fold.js`, `more_sheet.js`): `#infoBar` is one row at every width, and what doesn't
fit folds into ⋯. Every chip and button is an **item** of `info_bar_model.js` `BAR_ITEMS`: `{key, selector, group,
rank, phone, compact, menuOrder}`. `rank` is the desktop fold order (higher stays longer; `pinned` never folds: status,
ctx, ⋯; `menu` is never on the row: archive, delete); `phone: row` items are the only row candidates at 600 px or less
(status, ctx, speed, ⚙, ⋯); ⚙ alone has a `compact` form (its icon, the dot when the session set its own), tried before
it folds, and the phone's from the start. `info_bar.js` draws the `.meta` as four groups (identity: id, status, ctx,
speed, clock | setup: ⚙, model, 🧰, notes, set/mem | relations | trail: folder, worker badge), each `.bar-sep` classed
by the group it precedes; `#infoActions` (continue →, stop session) and ⋯ follow, right-aligned.

The **fold** is `foldPlan` (pure): every candidate full, then while the row is wider than the bar the lowest rank on it
(all items of that rank together) goes compact, else folds; pinned items never fold (the row clips). Its widths are
measured, never read from a squeezed box: the row's children are `flex:none` and the caps (model 40ch, folder 48ch)
hold always, so a drawn chip's width is its natural one. `createBarFold` caches them per key + text; a folded item has
no box, so a text first seen while folded is measured by dropping the fold's attributes for one synchronous pass
(before paint). ⋯'s count joins the row's width once something it counts folds. The live chips (ctx, speed, clock) are
cached per key as a budget (their CSS reserve is their `min-width`): a tick within it costs a width read, no refold.
A recompute runs only when an input changes: `foldSignature(bar, buttons)` (the items present and every non-live
text: a status, `set 9 → set 10`, a delegate starting to wait), the bar's width (`ResizeObserver` on `#infoBar`), the
phone profile, a live chip past its budget, the fonts ready or a zoom (those clear the cache). A recompute it starts by
itself calls `onChange` (app.js touches `infoBar`) so ⋯ follows. Call order in `app.js updateInfoBar`: `renderInfoBar`
→ `barFold.update` → `moreSheet.update({bar, buttons, folded})`, in one task. The plan is three attributes on
`#infoBar` (lit renders into `#infoText` inside it, so they survive the redraws): `data-folded="notes toolkit dir"`,
`data-compact="settings"`, `data-empty-groups="relations"`; index.html has one `display:none` selector per key and
hides an empty group with its hairline. **A new chip needs a `BAR_ITEMS` entry and its `data-folded` selector**
(`bar_fold.test.js` checks every foldable key has one), or it can't fold.

⋯'s menu (`more_sheet.js`) is a popover above 600 px and a bottom sheet under it (`chip_popover.js`, `SHEET_MAX`; its
own resize handling switches them, so a width change doesn't close it). It holds a row only for a folded item (the id,
⚙ when folded and not compact, "earlier links pruned" included), the folded ones of speed, clock and folder on its
telemetry line (none: no line), archive and delete always, continue and stop when folded. Its dot (`moreAttention`)
and its count (`moreCount`, a desktop's, none at 0; archive and delete don't count) are from folded items alone: a chip
on the row shows its own state. Folded items stay in the DOM, display:none: a row or an action clicks the real chip or
button, so each keeps one set of handlers, confirmations and in-flight rules, and what a chip opens has no box to be
placed at, so `chip_popover.js` places it, marks `aria-expanded` and gives focus back at the page's
`[data-anchor-stand-in]` (⋯). Rows and actions draw into fixed slots, so a row that joins keeps the focus where it was.
The e2e reach an item wherever it is with `spec/e2e/support/layout.js` `clickBarItem` (the row, else ⋯'s `[data-row]`).


## Safe areas

The owner page runs under a phone's notch, status bar and home indicator (`viewport-fit=cover`; the body is `100dvh`,
so a Safari tab's toolbar never covers the composer). index.html's `:root` names the insets once, `--safe-t/r/b/l`
(`env(safe-area-inset-*)`, 0 on a desktop), and only these read them: main's padding (16px, or the inset where it is
wider; its bottom is 16px less than `--safe-b`, since the session's card floats 16px above main's bottom; a phone's
session panel has no bottom padding and runs to the screen's bottom, its card at `--dock-bottom`, 16px or the
indicator's line), a bottom sheet's offset (`chip_popover.js place`: 8px above the indicator, or a keyboard's offset
alone), the update sheet, the toast's fallback place (in a session `--toast-bottom` already sits it above the card), the
lightbox's padding and the signed-out banner (`auth_lost.js`, `env()` itself).
On phones, the standalone app also has a 12px body inset, keeping its content below iOS 26's blurred band under the
clock. A new fixed or bottom-anchored piece reads `--safe-*`, never `env()`: the e2e set the names by hand (`web.spec.js`, a portrait phone and a landscape one),
as Chromium has no insets. The theme-color metas are tokens.css's `--bg-top` per theme up to 600px wide (a phone's page starts from that colour at its top edge, so the status bar meets the top bar with no seam), else its `--bg` (`theme.test.js` pins them). An iOS 26 Home Screen app ignores them for the status bar strip: it paints the strip in the body's `background-color`, so a phone's body gradient keeps a `--bg-top` colour layer under it (black strip without one).
In a session, the dock (composer card) shares the history's centered column, at most 960px wide; its right edge follows a classic scrollbar (`--history-sb`, 0 with overlay scrollbars; index.html and `dock_reserve.js`).

## The stage's height

`stage_frame.js` is the one writer. The cap is a ceiling: 60% of the page, 80% with the cloud open, 85% with a raised
cap, and never above the session panel (less the card, its offset from the panel's bottom as computed: index.html
`--dock-bottom`, and 16px). The frame is grow-only while a turn runs, so a change inside the stage never moves its top
edge, with **a shrink for each asking form and after an answer** (`forgetContent`):
- **the asking form**: each card that docks (it opens, or finds opened, the turn in the history, below): the stage shows
  that card alone (`stage_view.js place`, in the card's task);
- **an answer that leaves another docked card**: it fits the card now in front once the answered card leaves the
  stage. Paging between cards does not change the height. When no card remains, the shrink is at **the next step after
  a blocking card's answer** (`stage_view.js releaseHeldWait`, from `generationStarted`). The
  `held-wait` class says it is due: set with `waiting`, cleared there, so a later step, which calls it again, does
  nothing. What goes together: the live slots' waiting height, a raised cap, the tallest content seen. With one card,
  at the tap nothing moves: it collapses to its line inside the held frame and the stage's scroll stays, unless the line
  would be above the view (a reader who scrolled down a card taller than the stage), when it comes back to the view's
  top (`settleAnsweredCard`). With two cards, answering the one in front fits the frame to the one left; paging alone
  never changes it.

**The stage's fold** (`stage_model.js stageCollapsed`, `stage_asking.js`): collapsed to its status row the stage holds no
frame (`frameTarget` returns null) and an unfold refits to what shows. Three things decide it, kept apart: the user's
**choice** (the ▾ by hand, in memory, written to `chi_stage_collapsed`; never read back from storage to decide, so
another tab's write doesn't apply live), **revealed** (a ref's "show in turn" opened it for this turn; the choice stays)
and **the docked card's fold** (the waiting card the user folded, by its key, held in `chi_asking_fold:<session>`
in sessionStorage: this tab's own, so a reload or a resync mid-turn draws it folded as it was — `stage_waiting.js`
writes it on the fold and reads it back in `trackFold` once the replay has drawn the card; it goes when the card is
answered or cancelled (`question_cards.js`), when the fold drops, when the turn hands off, and when the page opens
another session (`session_sync.js`); `reset` clears the memory only, so the replay can take the fold back). In the
asking form only that fold counts: the ▾ and a tap on the folded row set or clear it and write nothing to
`chi_stage_collapsed` (another blocking card that comes to wait meanwhile
drops it, so the stage opens on the front card), so a card always arrives open (in the card's task, before
`question_cards.js focusWhenIdle` focuses it) and a new one never matches an old fold; the same card drawn again with its
id keeps it. The fold reads the registry checked against the slots first (`reconcileWaiting`), so a card answered in
the same task no longer holds a click. When the form ends (an answer, a dismiss, a cancel; `emptySlots` for a reset, a
session switch, the next turn) the stage is as the choice and revealed say. `refresh` applies it (`drawCollapsed`: only
when it changed, no refresh of its own). Folded, the status row's `.ts-mini` says what the shown card asks
(`stage_asking.js foldedText`: a question's `.question-text`, an approval's summary and its command's first line, a
plugin card's `.card-title`; `foldedRowText`, `.ts-mini-question`: first line, the whole as its title, the UI font)
instead of the running call; on a phone the step and the timing leave the row and the text wraps to a second line.

There is no asking slot: the reply that asked is the lead-in bubble in the history, or nothing. One card raises the cap:
a blocking approval too tall for the stage's view, a delegate's relayed one too (`raiseForApproval`, the registry's
`approval` flag, `stage_frame.js fitsCap`). It opens at its question and command (`revealTop`).

## A turn opened in the history

Every card that waits for the user docks (`stage_asking.js docks`: a `PENDING` card but the step limit, or an `ASKS`
card, placed before the turn's end): the stage opens the turn in the history (`stage_asking.js openTurn`,
`stage_opened.js`) and shows the card alone. **The lead-in:** chi's own question or approval
(`.bubble.question[data-kind="question"]:not([data-relay]), .bubble.question[data-kind="approval"]:not([data-relay])`)
whose step wrote text gets that text as a bubble in the history (`stage_asking.js leadInText`, the reply from
`askingGen`: live, the step whose call runs; in a replay, below); a relayed card, a hook's question and a card without
a lead-in message get none, and then a reader who was at the history's end follows the turn's move (`atEnd`, read
before it). **The step limit** never docks: its card arrives after the turn's end and hands the turn off at once
(`place` calls `handOff`, not the in-use watch; the end read doesn't hold it either), so the card sits right under its
turn in the history, as a reload draws it; a piece removed while the turn slides (the old continue card the step-limit
question replaces) stays gone.

| Piece | Where, from the opening to the turn's end |
|---|---|
| The prompt, the steps block (closed; its steps in order from now on, `turn_block.js inOrder`) and the rows the extras held | the history's end, in `handOffOrder`'s order (`history_end.js moveToHistoryEnd`). A lone step's block keeps its chrome there (`data-opened-turn`, until the hand-off), so its summary leads to the step's text when no lead-in shows it (a hook's question asked before its call's row) |
| The reply that asked: `.bubble.said` (`data-question-id`, `data-said-turn`, never `data-turn-id`: that marks an opening) | the history's end, in the card's task; raw, then its markdown; `.pending` ("asking you", the amber edge) while its card waits |
| Rows that arrive (`placeFor` `"opened"`: notes, steered prompts, commands, a card that stopped waiting) | the history's end, in arrival order |
| A card that waits (`stage_cards.js waitsInStage`: `PENDING`, `ASKS`, a warning) | the stage; a docked one shows the asking form (`.asking-form`: the status row and the card; the prompt, the live slots with the working set and the chip hidden), one with a lead-in a "↑ its reason" link in its summary. Two docked at once (check-in still open, then a question or approval): one at a time (`stage_waiting.js shown`; the others `.ts-behind`), the front one first, `‹ 1 of 2 ›` in the status row (`.ts-pager`). A warning stays beside the card. A `PENDING` card in the stage has no toggle of its own (a capture listener refuses the summary's click, tested at the click, so `question_cards.js` sets no `data-toggled`; the summary is out of the tab order, without its ▾): the stage's fold is the one (The stage's height) |
| A docked card answered or cancelled | right under its lead-in (`settle`), also after the turn's end; one without a lead-in at the history's end while the turn runs (after the turn's end it stays in the stage for the hand-off). Its own clamp is hidden while the lead-in is there (CSS). A card that stopped waiting goes there before a row placed after it in the same task (a replay) |
| check-in docked, nothing blocking (`.asks-live`) | the status row says the running call (`liveSlots().tool`, `foldedRowText` with `running`) after "waiting for you", then the turn's time; the dot keeps blinking; the live step's text streams under the card (`.ts-asks-text`), the row's word "writing" meanwhile (`stage_model.js phaseLabel`; `data-phase` stays "waiting for you"); at the turn's end `placeAnswer` empties it in the task that fills `.ts-answer`. The composer's delivery line reads blocking cards only (`stage_view.js phase`) |
| Live slots, the streaming answer, the end line, the queued slot | the stage, as before (no steps chip once opened: the steps line in the history says the count; a tick or a ref still reveals a step there); the hand-off appends what it still holds |

A turn released without its end (a lost `turn_completed`, the next turn's start) drops its reasons (`stage_opened.js
drop`) and leaves the rest; a late recap goes above an opened turn (`place`). The reload check's turn starts at its
opening: its prompt, else a wake's note (`data-opening-id`) right before it, notes that reached the history mid-turn
included (`wholeTurn`).

**Where the waiting-card state lives:** `stage_waiting.js`, one registry per stage keyed by a card's id (`q:<qid>`,
`c:<card id>`, `continue` for the old continue card), never by its node (`card.js drawCard` may swap a plugin card's
DIV for a DETAILS; a resync draws a question card anew). `place` adds (`arrive`: the kind, docked, approval);
`question_cards.js` settles through its `onSettled` hook (answered, cancelled, replaced, removed, the
continue card resolved or dropped), `cards_place.js upsertCard` settles a plugin card redrawn without its actions,
`turnEnded` the warn cards that leave, and `emptySlots` resets it. A second feed only settles: at each refresh
`stage_asking.js reconcileWaiting` drops an entry whose card is gone from the slots or waits no more (a card answered
outside `question_cards.js`, as the stage's unit tests do), and again before the fold, `pendingCard` and an opened row.
The registry's order is the stage's: blocking cards before the asking ones, arrival order within each, and `place`
puts a blocking card before check-in's in the slot, so a live page and a reload agree whatever the replay's order. The
asking form's card is the shown docked entry, the fold is the folded key (`stageCollapsed` compares keys); `opener`'s
lead-in Map is keyed the same way (a card drawn again with its key keeps its bubble: `relink`). `pendingCard`,
`asksCard`, the approval's cap, the summaries' tab order and the frame's waiting card read the registry.

The stage says where the block is (`blockPlace`: cloud, answer, history; `data-block="history"` on the stage for
`refs.js turnBlockOf`); the chip and a tick reveal the block or a step in the history. **Follow:** every row that reaches
the history follows a reader who was at its end (`atHistoryEnd`, read before the change); a reason is read from its first
line instead, and the history is marked `data-reading` until that scroll ends so the bottom reserve's own follow
(`dock_reserve.js`) doesn't take the end back. A reader scrolled up is never moved. **The end fold** (`finishFold`, after
the pieces, in their task): the reasons go and each answered card's two-line clamp says it, as the turn reloads; the first
row in view after a reason keeps its place when the history has room to scroll. The hand-off also waits while the pointer
or a selection is in a reason (`stage_watch.js alsoWatched`). The reload check gets the turn from its opening (`wholeTurn`).
**A reload or a resync** draws the same picture: `renderSessionView` replays the running turn (`data.replay`), in which
the asking call may have completed when its `question_requested` comes (`TurnAccumulator.join_events`: a question's
always, an approval's once it is answered), so the asking step is the last one whose last call is the one that asks
(any of its calls: `ask_user_question`; for an approval the tool it approves, the card's `data-tool`) and whose reply no
question card of this page took yet (`stage_asking.js askingGen`, `asked`; live, the step whose call runs). Live or
replayed, a step's reply is one card's lead-in: a second approval, or a question after an approval, of the same step has
none. The replayed card opens the turn as live; a question answered earlier in the turn settles under its reason with the
replayed `question_answered`, and `releaseHeldWait` reads a pending card, not the `waiting` class the replay's one task
hasn't refreshed yet.

## Frames

During a turn the cost is frames, not code: JS, layout and style are each a few percent of a core, while an animation
that updates at 60 fps keeps the compositor and GPU busy (25-50% of a core with nothing to show). Moving a pulse to
`transform`/`opacity` on the compositor still costs most of that, because the composites go on; the update rate is what
counts. So:

- **An infinite animation is stepped, moves only `opacity` or `transform`, and stops when the turn waits.**
  `spec/web/public/frames.test.js` reads every page and stylesheet for the first two (`.card.skeleton` is the allowed
  exception: loading only), and for its off switch under `prefers-reduced-motion`.
- The dot, a running tick and a live step's dot share `live-blink 2.4s steps(16)`. `steps()` applies per segment and the
  keyframes have two, so that is 13 updates/s: a third keyframe would change the rate. The spinners are
  `init-spin .8s steps(16)`, 20 updates/s.
- A blocking card (`.turn-stage.waiting`: a question, an approval, a delegate's relayed one, whose parent's turn blocks on
  it) stops them all, so movement means chi is working; `stage.spec.js`'s question scenario checks it, also after a
  reload. An asking card (check-in) has no `.waiting`, as its turn goes on: docked, its dot keeps blinking and the status
  row says the running call (A turn opened in the history). `.init-spin` is outside the stage (plugin setup only).
- A one-shot fade on something that arrives many times a second is a recurring cost too. A live answer's new line
  appears at once: its fade alone was about a quarter of the streaming answer's total on the Studio (24-25% of a core to
  17-19%). The headline's `ts-fade` stays: turning it off saved nothing measurable.

A running turn's text reaches the page at most every 100 ms (`turn_block.js FLUSH_MS`): a chunk only marks its step dirty,
and `flush` writes the dirty steps, follows and runs `onChange`, which refreshes the stage on the next frame
(`stage_view.js scheduleRefresh`, unthrottled: a collapse or a card stays immediate). The first chunk after a quiet
interval flushes on the next frame, so a first token isn't late; one inside the interval sets a timer for the rest, which
then asks for a frame, so a hidden tab's flush still pauses. A chunk that opens a step applies at once. What must not wait
writes for itself: `generationCompleted` and a step's close write its text, a card's refresh reads the model.
`reset`, `turnEnded` and `flush` itself cancel the timer. A frame already requested can't be cancelled that way, so it may
run `flush` with nothing to write, which doesn't count as a flush for the interval.

**Quiet (stall).** The dot blinks the same whether the model works or the line went dead: the Bridge's idle `: ping`
never reaches EventSource's JS, and a running tool sends nothing between its start and end. So a running turn that
has had no event for a while says so (`stage_stall.js`; the code says "stall" — `stallOf`, `.ts-stall`,
`data-stall` — the user reads "quiet": `liveSlots().quiet` and `stage_model.js QUIET_MS` are other things). Alive is
any `stage_view.js` call a turn event drives (`turnStarted`, the generation and tool events, a chunk, a notice, a
steer, a card, a place, `questionRefs`; a replay's count too). Kind A (streamed, or between steps) reads "quiet 0:40 ·
no new events" from 30 s, louder from 90 s; kind B (no token yet in the step; a joiner counts from the snapshot's
generation age, `delivery_line.js genAge`) reads "thinking quietly 0:50 · no tokens yet" from 45 s, louder from 3 min.
A phone shows the short text. Nothing is said while a tool runs (its own clock, `.ts-tool-clock`, from 10 s instead),
a blocking card waits, the live timing line has a note (a retry, plugins' setup: `live_timing.js note`), the turn has
ended, or for 5 s after the page shows again (`visibilitychange`). The open session's stream not live for a second
(`session_sync.js`'s stream handle gone: `workerGone` until the resync streams again) reads "reconnecting… · events paused" and wins.
It ticks on the live timing line's clock (app.js `createLiveTurn`'s `onTick` → `turnDom.tick`; 200 ms, then 1 s) and
writes only when its text changes. Expanded, it is a right-aligned span in the now row, its tint by level
(`.ts-now[data-stall]`); where the now row doesn't show (a collapsed stage, a plain turn's), its short text follows
the timing line in the status row (`.ts-stall-head`). Hooks: `.turn-stage.stalled` and `data-stall` (1, 2, net) on
the stage's root. The dot keeps blinking meanwhile.

## The working set's reader

What chi has of one working-set item ([working-set.md](working-set.md#timeline-what-the-model-has-of-one-item)):
`ws_timeline.js` is the pure part (the server's events into cards newest first, reads merged by state, and between the same edits, into line
slices, the file strip, the peek's pick, the step tags from the item's `runs`: working_set.js `itemsOfTurn` keeps each
row's `tool_id` with its place), `ws_cards.js` the cards' templates (`diff_view.js` for diffs, `.read-line` for lines),
`ws_peek.js` the popover's peek (one row at a time; working_set_view.js draws it under the row and grows the popover to
`PEEK_WIDTH`, a phone's sheet to `SHEET_TALL`: `chip_popover.js` reads `width`/`sheetShare` as functions per
placing), `ws_reader.js` the reader and the wiring (`createWorkingSetPreview`: the peek, the reader, `attach(workingSet)`
for the set, its jumps and its list, and `whatChiHas` for refs.js), `ws_way_in.js` a tool row's `timeline` button (a
flag turn_html.js reads; on only once the reader is attached). State: the reader's own closure (the open item, its
answer, the tab), never `store.current`. The reader is a `section` in `#center` over the history and the composer
(both `inert` while it is open, so their scroll place stays; a phone's is `position: fixed`). Each item answer goes
through `createLatest` keyed by the session and the item; a new server snapshot (`onServer`) asks again while it is
open (the route's messages lag a running turn). Leaving the session closes it and the peek: `session_view.js
forgetSession` (a switch, the start page, + New, a deleted or archived session) calls `wsPreview.reset()`, so
`#center` is never left inert, whatever the next session's GET does; close gives focus back to where it was at the
open (not after a jump or a reset). Styles: `ws_preview.css`.

## Stale answers

The page switches sessions, reopens a popover or asks again while a fetch is out. An answer for the old ask must be
dropped. **`latest.js`** is the guard:

- `stillOn(get, at = get())`: `() => true` while `get()` is still `at`. For a one-off read about the open session
  (`const still = stillOn(openId); … await …; if (!still()) return;`). app.js has `openId = () => store.selected`.
- `createLatest(get)`: `begin()` gives a guard that also goes stale when a newer ask begins; `drop()` makes every
  ask out stale (a close, a reset). For a list that is re-read.

On it: `context_chips.js`, `project_picker.js`, `participants_panel.js` (`load`), `cards_place.js`
(`refreshCardBodies`), `stream_handlers.js` (`answer_display`), `working_set_view.js` (`fetchServer`), `ws_peek.js` and `ws_reader.js` (an item's timeline), the
turn-end re-reads (`session_view.js` `readTurnEnd`, app.js's `refreshTimingFromSession`, `mergeTurnTiming`) and app.js's init-row timers. Still by hand
(the id decides more than "drop it"): `session_sync.js` `resync`/`retryResync` (the re-read budget, `resyncAgain`), the stream's
close, `session_actions.js` (a continue opens another session on purpose), `send_turn.js` (a failure for another
session becomes a toast). A new await in a component
uses `latest.js`.

## API clients

- `data.js api(path, opts)`: the owner page's. Throws an `Error` with the server's words, `.status`, `.code` (the
  server's error code: match on it, never on the words) and `.body`; a signed-out proxy answer (401, a redirect,
  HTML) or a fetch that fails on a sign-in redirect reports to `auth_lost.js` (`onAuthLost`, set by app.js).
  `cantText(what, error)` is the toast.
- `method_api.js methodApi(method, path, body)`: the same, as `notifications.js` and `push_devices.js` call it.
- A participant's page uses `data.js api` too: a 401 (their link ended) goes to `participant_main.js linkEnded`
  (`onAuthLost` set again by app.js), never the owner's signed-out banner.

## Streams

| Stream | Opened by | Lifecycle |
|---|---|---|
| The hub, `GET /api/events` (`data.js openEvents`) | app.js `openSessionEvents` (scoped by `?dir`) | `snapshot` then `session` / `session_gone` → `applySessionEvent` → `allSessions`; EventSource reconnects itself (a fresh snapshot); `onClosed` (a proxy sign-in on reconnect): probe, reopen after `EVENTS_REOPEN_MS` |
| A second hub stream, unscoped | `notifications.js` (`allEvents`) on a project's page | the Home Screen app's device tidy-up across projects |
| The open session, `GET /api/sessions/:id/stream?from_seq=` (`data.js openStream`) | `session_sync.js` `startStream` from `store.current.streamSeq` | events → `stream_handlers.js`. It closes itself on an error; the page resyncs (`resync`: a fresh render and a new stream from its cursor), once at once when it had opened, else after `STREAM_RETRY_MS`. Meanwhile a turn the stage holds reads "reconnecting…" (Quiet, under Frames), and the Bridge's `: ping` is invisible to the page. A re-read that can't reach chi web keeps the history it drew (`resync_reach.js`): the session bar's status chip says "retrying" while `retryResync` tries, "offline" once the tries ran out (`store.current.reach`; short words that fit the chip's reserved width, the full words in its tooltip), but only while no turn runs: during a turn the stage's "reconnecting…" is the one signal (on a phone the bar can hide its status) and the chip keeps the turn's word, and any hub event for the session then re-reads it (`followSelectedSession`); the next drawn re-read clears it. Only a first load (select's "Loading…") shows the error in the history |

A new event type is a handler in `stream_handlers.js`; the participant view spec makes it decide `EVENTS` or `DROPPED`,
and checks that every type in `EVENTS` has a handler there or in `participant_main.js` (a participant's page opens
the same stream, filtered).

## Storage keys

Through `storage.js` (`readStored`/`writeStored`: storage can throw, a missing value is the default), except
`notifications.js`, which takes an injected storage for its specs. Per-browser choices only: never anything that must
reach another device or the server.

| Key | Module | What |
|---|---|---|
| `chi_model`, `chi_model_recent` | `model_pick.js`, `model_picker.js`, `start_page.js` | the start page's model and its recent list |
| `chi_composer_collapsed` | `composer_fold.js` | the composer folded (a card's text field folds it for the time it has the focus on a narrow or touch screen, `composer_grip.js watchCardField`, on top of this and of the visit's state: neither is written) |
| `chi_composer_floor` | `composer_grip.js`, `composer_mount.js` | the composer's dragged height |
| `chi_strip_hidden` (`chi_zen`: the old name, read once) | `strip_hidden.js` | the session strip hidden |
| `chi_stage_collapsed` | `stage_asking.js` | the stage collapsed by hand (not written from the asking form, whose fold is that question's only) |
| `chi_working_set_collapsed` | `working_set_rail.js` | the working set rail collapsed |
| `chi_markdown_tip_dismissed` | `markdown_tip.js` | the markdown tip dismissed |
| `chi_update_available_shown` | `version_notices.js` | update notices already shown |
| `chi_notify`, `chi_push_device` | `notifications.js` (an injected storage) | the bell's state, this device's push id |
| `chi_answer_fold:<session>` | `answer_fold.js`, `revise_stack.js` | the answers and long prompts (`<turn id>:prompt`) folded by hand, and the Revise stubs unfolded by hand (`stub:<turn id>`) (swept with the session list) |

sessionStorage (this tab only, `storage.js` `readSession`/`writeSession`/`removeSession`, guarded the same way):
`chi_client_id` (`turn_events.js`: this tab's client id, kept over a reload mid-turn),
`chi_asking_fold:<session>` (`stage_waiting.js`: the docked card the user folded and how many cards waited at the
fold, so a reload or a resync mid-turn draws the asking form as they left it), and
`chi.authReloadAt` (`auth_lost.js`: one automatic reload a minute).
