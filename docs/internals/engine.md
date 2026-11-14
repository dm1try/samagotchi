# Engine: the core agent loop

The Engine (`lib/samagotchi/engine.rb`) runs a session's turns. It owns the turn lifecycle, the hooks and
plugins, and the model↔tool cycle, and it reports what happens as events, so every UI (a worker behind the web
and the attached TUI, a `--non-interactive` one-shot) runs turns the same way without the Engine knowing how
they render.

```
Engine#run_turn → backend.complete(..., context:) → KernelLoop#run (native) or ChatLoop#complete (chat)
  → per iteration: one generation, then ToolResponse.run_batch(context:) over the calls
      → ToolRunner#run(call, context:) per call → Guardrails::Gate#evaluate(call, context:)
        → KernelLoop#dispatch_tool_call(call, context) → the handler's ToolContext(kernel, context)
  → repeat until the model answers without tool calls, or the iteration limit
```

`context` is the turn's `TurnContext` (`lib/samagotchi/turn_context.rb`, see "Turn and TurnContext"): every step
of the tool path takes it as an argument; none of them reads the turn from the kernel, the wiring or the Engine's
ivars.

## Quick reference: the turn lifecycle

The skeleton is `Engine#run_turn` in `engine.rb`; read it for the order. Each step and what it owns:

```
Engine#run_turn(session, prompt, on_event:, …, origin:, continue:, resumed:, resume_from:, verify:, revises:, …)
  ├── begin_turn                 → Turn (the TurnContext published with the running flag)
  ├── Client.swap_probe_cancel   (a Stop cuts this turn's /props probes)
  ├── prepare_turn               → false at a STOP CHECK (stopped_before_model), else true
  ├── generate                   → LLM::ModelResult
  ├── publish_used_memories
  ├── complete_turn
  ├── @turn_warmup.after
  └── ensure: release_turn, @context_judge.show_cards_after_turn, show_objective_proposals
```

| Step | Where | What it owns |
|---|---|---|
| `begin_turn` | `engine.rb` | A Verify turn's claim checked (`@verify_anchors.verified`, the sessions dir given); `session.status = RUNNING`; used memories absorbed; the `TurnContext` built **whole** (`new_turn_context`: `GuardrailWiring#begin_turn` gives git, participant and mode; `id:` the caller's or a new uuid; `settings` nil until `generate`), then `TurnState#begin!` publishes it with the controller (a new `CancellationController` when none is given), sink and `input_waiting:` peek in one step; a recap in flight invalidated. `run_turn` sets `turn.resumed` / `turn.resume_from` only on a continue. |
| `prepare_turn` | `engine.rb` | `:turn_started` (an image error raised after it); the toolkit suggestion's `start`; `refresh_profile!`; `turn.prepared_settings = turn_settings(session)` and `refuse_images!`; **STOP CHECK A** (abandons the suggestion `:canceled`); `announce_guardrail_failures`, `start_init_tasks!` / `await_init_tasks`, `apply_staged_tools!`; the suggestion's `settle`, the judge's `start`, the objectives' `incoming`; `apply_toolkit!` (`Registry#toolkit`, `ToolIndex#refresh!`, a prompt rebuild when it changed, a warn per stranded plugin tool); `refresh_participants!`; **STOP CHECK B** (before the hooks run or a reminder is used up); `:session_start` (first turn) and `:before_turn` hooks; `turn_messages`. Its ensure abandons the suggestion `:failed` (nothing once settled) and calls `finish`. |
| `turn_messages` | `engine.rb` | System head + history + due reminders (`:reminder_injected`; none in a participant's turn) + the user message (not on a continue) + the plugins' staged tool loads (`append_tool_loads`, `engine/toolkit.rb`). `turn.messages` is set first and grown in place, so a failure meanwhile keeps what is there. |
| `generate` | `engine.rb` | One `EffectiveModel` **after the hooks** (which may switch the model): `sync_kernel_client!`, the settings completed (`model_name`, `window_setting`, `llm_context`, `price`, `loads_tools`), the turn's `ToolSurface` built, `turn.context.with(…)` published by `TurnState#replace_context`; `turn.limit` (`IterationLimit.for`); `backend(model).complete(…, pending_input: turn_drain(pending_input), reasoning_since:, context:)`. |
| `complete_turn` / `end_turn` | `engine/turn_end.rb`, `engine.rb` | See "Turn ends" below. |
| `@turn_warmup.after` | `TurnStages::Warmup` | Local llama.cpp, native loop only: prefills the next turn's prompt (prompt-caching.md, "The turn-end warm-up"). Never fails the turn. |
| `release_turn` | `engine/turn_end.rb` | `TurnState#finish!`, `SteerCut#finished!`, probe cancel swapped back, the context window cache dropped (the next turn asks the server again), steers left logged as dropped, activity recorded, turn-scoped hooks cleared. Then, after the flag is released, the judge's cards and `show_objective_proposals` (the objectives' `finally`: a completed turn's proposal cards shown, any other's dropped). |

`Engine::Turn` (in `engine.rb`) carries the lifecycle fields; `turn.id`, `session`, `origin` and `controller` read
its context.

**Turn ends.** `end_turn(turn, outcome)` does one step under the event lock: the session gets the kept messages,
goes IDLE, records `last_turn` (its `enqueued_id` from the origin; a continue turn's origin carries its offer
turn's, `ContinueOffer#run_continue_turn`), the working set and the objectives' view (`announce_objectives`) go out, and the end
event is emitted (`:turn_completed` / `:turn_canceled`, every one carrying `turn_id`). Before the replace,
`@verify_anchors.stamp_opening` puts `verify` / `revises` on the opening message (metadata, never sent) and
`record_verdict` adds a Verify turn's verdict. When the turn keeps messages, the end event names their range,
`kept_from` (`turn.history_size`, noted in `turn_messages` right after `ContextNote.with_system_head`) and `kept_to`
(`kept.size`): display-side only, no message gains a key. `complete_turn` then runs `@objectives_stage.outgoing` (not for a
canceled or exhausted turn), the `:after_turn` hook (with `present:` and `refs:`, see "Hooks"),
`store_answer_display` (one replace; `:answer_display` to the observers when a hook changed the answer or attached
refs) and the `:session_end` hook. `TurnEndings` (`turn_endings.rb`) holds the pure builders (`kept_messages`,
`failed_messages`, `ctrl_c_messages`, `failed_event`, `turn_summary`, `stop_facts`); the Engine forwards to it.

### Turn stages

A step that keeps state across the turn is a collaborator under `lib/samagotchi/turn_stages/`, built in
`Engine#initialize`, **never reading the Engine's ivars**, and called by name from the skeleton. **It takes values,
not callbacks**: what lives as long as the Engine goes into its constructor (the side asks, the host registry, the
toolkit binding, `TurnState`, the model settings, the reminder queue); what the Engine knows at the call (the
recorder, the sessions dir, the owner's messages, the running conversation, the host's probe) goes with each call,
read on the caller's thread and held only for that call. At turn time the sessions dir is the turn's
(`TurnContext#state_dir`, set from `session_state_dir` by `new_turn_context`); an off-turn call gets `state_dir:`.
`Objectives` and `VerifyAnchors` are built early; `ToolkitSuggestion` and `ContextJudge` in `build_tools_and_plugins`,
before the plugins load (a plugin may reach them as it loads); `Warmup` after `wire_kernel`. Their state is their own.
The Engine's public methods forward to them (`warm_toolkit_suggestion!`, `announce_objectives`, `propose_objective`,
the private `judge_late_candidates`, `show_objective_proposals`); each stage's builder is in its `engine/*.rb` part.

**The recorder.** A stage saves its System 1 asks as runs through a `SystemOne::Recorder` (`system_one/recorder.rb`,
`Data.define(:runs, :session_model)`; `#wrap(client, judgment, session, mode:)`, `#saving?`), which
`Engine#system_one_recorder` builds **fresh at each stage call**, never kept: `runs` from `#system_one_runs` (Config's
`system_one.runs` read then), `session_model` from `effective_model_name` then, so `outgoing` after a before_turn
hook's model switch names the new model and `incoming` the old one. Building one never raises: on a failure
`Recorder::NONE` (no runs, every client as it was, no audit ask; `system_one_recording_failed`). Not the
`TurnContext`'s model fields: those are frozen at `generate` with the bare guardrail name.

| Stage | Built with | Called with | Called | State |
|---|---|---|---|---|
| `TurnStages::ToolkitSuggestion` (ToolkitSuggest's ask; configuration.md (Toolkits), guardrails.md (System 1)) | side judgments, host registry, toolkit binding, tools | `start(turn, recorder:)`; `settle`, `abandon(turn, why)`, `finish` (the turn); `warm!(session)` | `start` before `refresh_profile!`; `settle` after `apply_staged_tools!` (on mode: waits up to System 1's timeout or a Stop, which wins over an answer already in; a pick ≥ threshold → `ToolkitBinding#suggest`); `abandon` at STOP CHECK A and in the ensure, then `finish`; `warm!` / `stop_warmup` (Worker start, `shutdown`) | the turn's `ToolkitSuggest::Pending` (turn thread only; another turn's is never touched; dropped at `finish`), the warm-up thread |
| `TurnStages::ContextJudge` ([attached-context.md](attached-context.md), [context.md](../context.md) "The judge") | side judgments, host registry, `TurnState`, `show_card:`, `current_session:` | `start(turn, recorder:)`; `late_candidates(session, messages:, recorder:, state_dir:)`; `show_cards_after_turn` | `start` after `settle`, before `apply_toolkit!` (owner turns only); `late_candidates` from `judge_late_candidates` (which returns on no session or a review session first, before reading anything else); `show_cards_after_turn` after `release_turn` | the cards an answer brought while a turn ran, under their mutex |
| `TurnStages::Objectives` ([objectives.md](objectives.md)) | side judgments, host registry | `incoming(turn, recorder:)`, `outgoing(turn, result, recorder:)`, `note(session, note, recorder:, state_dir:)`, `announce(session, state_dir:, running:)` → the event or nil, `propose(proposal)`, `finally(turn)` → the cards, `track(turn, engine:)` → the tracker's thread or nil, `cancel_track` | `cancel_track` first thing in `begin_turn` (any turn, a wake's too); `incoming` after the judge's `start` (owner and human prompts only); `announce` from `announce_objectives` (inside `end_turn`'s step, and between turns from any thread); `outgoing` in `complete_turn` before `:after_turn`, `track` right after it (`Engine#track_objectives_after`); `note` in `add_context_note`; `propose`; `finally` from `show_objective_proposals` in the ensure | the turn's proposals under their mutex (drained at `finally`), the last view announced (touched only under the event lock), the tracker's automatic read's cancel under its own mutex; the `ObjectivesAudit` is built per call |
| `TurnStages::Warmup` (PromptWarmup) | `PromptWarmup`, kernel, `TurnState`, model settings, reminder queue, `system_prompt` | `after(turn, result, next_turn_waiting:)` | after `complete_turn` (reads `turn.context.settings`) | none (PromptWarmup keeps its pin and thread) |
| `TurnStages::VerifyAnchors` | nothing | `verified(session, anchor, state_dir:)`; `stamp_opening`, `record_verdict` | `verified` in `begin_turn` (before any `TurnContext`); `stamp_opening`, `record_verdict` inside `end_turn`'s step | none |

**Objectives' announce and cards (the Engine does the effects).** `Engine#announce_objectives` takes the event lock,
reads the sessions dir and `live_conversation` in it, calls the stage's `announce` and announces the event it returns
in the same step, so the last view is guarded by the lock that orders the events; it logs a failure
(`objectives_announce_failed`), never raises. `show_objective_proposals` shows the cards `finally` returns and logs a
failure (`objectives_proposal_failed`).

**Why three callables stay** (`spec/turn_stages/constructor_contract_spec.rb` counts the Procs a built Engine's stages
hold, an audit's included: 3). ContextJudge's `show_card` and `current_session` are read on the asks thread when an
answer comes, after the call that started the asks returned: a value given at the call would be stale. Warmup's
`system_prompt` is built last, only once every check passed, for its side effects (the memory index metric, the
prompt notes). The warm-up's other late reads stay lazy too: the model after the canceled/resumable check, the
host's `next_turn_waiting` probe only after the target check. Warmup keeps the kernel (ToolHost's later).

On a shared local System 1 host the judge's asks wait for the turn's end: started before `TurnStages::Warmup#after`,
whose warm-up waits for them, or from `run_turn`'s ensure (docs/context.md, The judge).
`spec/turn_stages_wiring_spec.rb` pins the stages' order among the turn's steps, their threads, the saved runs'
fields and the late and error paths.

### Error paths

```
StandardError in run_turn:
  → turn.ended (raised by the after_turn/session_end hooks): logged post_turn_error, re-raised, no second ending
  → else end_turn(turn, "failed", save: true) (a failing save logged, turn_end_save_failed): failed_messages keeps
    the loop's partial conversation (both loops LLM::FailedTurn.attach it), else turn.messages, with
    TurnNote.failed at the tail; :turn_failed {error_class, message, duration_ms, + error_kind, retryable, host,
    summary for a provider error}; re-raised

Interrupt (Ctrl-C; a one-shot only, a worker traps INT):
  → turn.ended: re-raised only
  → controller.cancel!(:ctrl_c); end_turn(turn, "canceled"): ctrl_c_messages keeps the attached conversation (the
    finished iterations stay, as after a Stop) with TurnNote.cancelled(:ctrl_c); a call mid-batch gets an
    interrupted result (ToolResponse.run_batch), so no call is kept without its result; a half-streamed reply is
    not kept; :turn_canceled {cancellation_reason: :ctrl_c}; re-raised (the caller decides whether to exit)

A Stop (Engine#cancel_current_turn!, the Bridge's POST cancel) or a hook's stop_turn:
  → not an error: LLM::ModelResult(canceled: true, conversation:); complete_turn keeps the conversation with a
    TurnNote.cancelled note; text streamed before the cancel stays, marked [interrupted]

A worker's TERM, HUP or INT (WorkerSignals, a spawned worker only):
  → a Stop with reason :signal (Worker#signalled, off the trap, retried until the loop leaves); saved as after any
    turn; Worker#run returns :signal (:stopped with the stop marker) and takes no new work
  → not ended within Worker::SIGNAL_GRACE (a turn already in its after_turn hooks gets SIGNAL_HARD_EXIT more,
    uncanceled): the session saved as it is, SignalException raised in the loop's thread, only while the loop runs
    (never into start, serve or the teardown, which runs whole)
  → exit! Worker::SIGNAL_HARD_EXIT (10 s) after that at the latest; a signal after the loop left brings only that
    hard exit
  → WorkerBoot.run_session_loop restores the default handlers; exit 0, no discard; input queued behind the stopped turn
    wakes a new worker

The effective model doesn't resolve (HostRegistry#resolve raising):
  → the rescued readers give their fallback (SessionModelSettings#model_setting) and log effective_model_unresolved;
    a setting failing on a resolved model logs <setting>_unresolved (also served_probe_failed,
    alias_note_failed, thinking_notice_failed); WARN once per (event, model, error class),
    DEBUG after (EffectiveModel::Unresolved)
  → session_state_snapshot never raises (its model fields nil); a turn, stats_snapshot, chat_model? and
    system_prompt raise

A session's toolkit doesn't resolve (an unknown kit, a missing bundle's kit, a bad base, a cycle; ToolkitBinding#apply!):
  → that turn declares the full kit plus the session's own adds and removes (Toolkit#resolve's fallback); the saved
    toolkit stays, so a reinstalled bundle gets it back; toolkit_unresolved logged once per process, with a
    :guardrail_warning (label "toolkit")

Stopped before the model was asked (prepare_turn returned false):
  → stopped_before_model → end_turn(turn, "canceled"): nothing kept; :turn_canceled; ModelResult(canceled: true)
```

### Degrading

Work that has a fallback when it fails (a prompt section left out, an empty list from the Bridge) runs in
`Degrade.call(area, event, fallback:, rescue:) { … }` (`degrade.rb`): the same rescue and fallback as a bare
rescue, plus one WARN in the debug log per process for each `[area, event]` (DEBUG after; nothing on stderr). A bare
`rescue` whose body is only a literal (`nil`, `false`, `[]`, `{}`, `""`, `0`, or an array of only those) is flagged
in lib by the `Samagotchi/SilentRescue` cop; a silence that is right (a client gone, a routine probe, Log's own
internals) carries `# degrade-ok: why`.

## The model↔tool loop

The Engine does not talk to models directly. `Engine#backend` (`engine/models.rb`) picks the loop the effective
model's host speaks: an api in `LLM::Adapters::BY_API` (openai, anthropic) gets `LLM::ChatLoop` (one per Engine,
built on first use), anything else `LLM::NativeBackend` wrapping the Engine's `KernelLoop`.

Both implement `LLM::ModelBackend#complete(messages:, max_iterations:, on_stream_event:, cancel_controller:,
model_name:, max_tool_output_chars:, pending_input:, reasoning_since:, context:)`. `reasoning_since:` is where the
run a step-limit Continue resumes started (the Engine's `resume_from`, checked in `Engine#resumed_run_start`).
`NativeBackend#complete` only calls `KernelLoop#run`. `ChatLoop` runs its own loop but uses the KernelLoop's tools,
hooks, gate and dispatch.

**Each loop works on its own copy of the conversation**, not the Engine's `turn.messages`. The Engine keeps
`result.conversation` after a normal end or a Stop, the copy attached with `LLM::FailedTurn.attach` after a failure
or a Ctrl-C, and `turn.messages` only when the turn ended before the loop.

### KernelLoop (the native, raw-prompt loop)

Runs models whose server takes a raw prompt (llama.cpp `/completion`). chi formats the prompt itself per model
profile (Gemma 4, Qwen 3.6) and parses tool calls out of the generated text. `KernelLoop#run` → `start_turn`
(`prepare_conversation`: a copy, old model messages without their thought blocks, except a resumed run's,
`keep_thought_from: ReasoningHistory.run_start(messages, reasoning_since)`), then per iteration (`#iterate`):

1. Queued input (user lines, plugin steers) goes in at the boundary (`Steer.inject!`).
2. The conversation is formatted (`Prompt.format_with_images`); a context guidance line goes on the tail past a
   fill threshold.
3. `:before_generation`, then one streamed generation.
4. Tool calls parsed (`ToolCallParser` for the profile):
   - Gemma 4: `<|tool_call>call:NAME{params}<tool_call|>`
   - Qwen 3.6: `<tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>`

   A Qwen block left open is asked to be finished (`QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_LIMIT` = 2).
5. Calls: `dispatch_calls` → `ToolResponse.run_batch`, one `tool_response` entry for the batch.
6. No calls: an answer, an empty answer to retry (`EmptyAnswerRetry`), or queued input to answer.

Gemma 4's native contract (and thought context) is [gemma4-contract.md](gemma4-contract.md).

### ChatLoop (the chat APIs)

Runs hosts whose api has a chat adapter: `api: openai` on `LLM::OpenAIChat` (OpenRouter, any OpenAI-compatible
server) and `api: anthropic` on `LLM::AnthropicMessages` ([anthropic.md](anthropic.md)). The Engine sets the
adapter per turn (`HostRegistry#adapter_for`), with the session id and the loop's own client (`ChatLoop#client`, the
effective model's `EffectiveModel#client`: what `#context_window` probes on a local host, and the host a request's
re-prefill is counted against on the Engine's `ReprefillMeter`, one for both loops: prompt-caching.md, "Reading
the numbers"). `Engine#backend_for` writes all three under `@chat_backend_mutex`, from whichever
thread asks (the turn's, or a `/model` switch's through `sync_kernel_client!`); the turn reads them on its own
thread. The chat loop never reads the kernel's client. `ChatLoop#complete` copies the messages (each `dup`ed) and runs a
`ChatLoop::Run` (`start: reasoning_since`, cap `ToolOutputCut.max_chars`). Differences from the native
loop:

- The tools go in each request's `tools` field (`ChatLoop#tool_definitions`, the turn's `ToolSurface#schemas`).
  On an adapter that loads tools (`#loads_tools?`: `AnthropicMessages`), the tools the session reaches but doesn't
  declare follow with `defer_loading: true` (`ToolSurface#deferred_for`; anthropic.md, "Deferred tools"); a call of
  one is logged `tool_direct_deferred`.
- The conversation goes out in the OpenAI wire format (`wire_messages`); `AnthropicMessages` translates it again
  (`LLM::AnthropicWire`). Each call's result is its own tool message, paired by `tool_call_id`.
- The first system message carries `cache_split:` (`SystemPrompt#stable_length`); where the adapters put cache
  breakpoints is prompt-caching.md's and anthropic.md's.
- **Reasoning sent back** (`reasoning_content`) follows `TurnSettings#reasoning_history` (`ReasoningHistory.resolve`,
  the session's own level first): `all` on every model message, `turn` past `ChatLoop#reasoning_boundary`, the Run's
  `@reasoning_start`, fixed **once per Run** by `ReasoningHistory.run_start` (the rule the native loop uses too).
  So a continue turn (reminder, context wake, report wake) replays nothing of the run before, and entries the Run
  merges (a steer, a person's line) don't move it: the request after a steer extends the one before. A step-limit
  Continue's Run starts where the run it resumes did (`reasoning_since:`). Outside a Run (`#reasoning_chars`) the
  boundary is the last query.
- On an adapter that sends its blocks back (`#replays_content?`: `AnthropicMessages`), a model turn's saved blocks
  (`anthropic_content`, saved by `Run#with_thinking`) go back verbatim with their signatures (`#replay_blocks`), not
  for an interrupted entry or one with an unpaired call, and without thinking blocks before the reasoning boundary.
  `#reasoning_history` floors `drop` at `turn` there.
- A 400 about reasoning (`BadRequest#reasoning_refused?`) for a request that sent reasoning back asks the step again
  without it (not on a replaying adapter); when that goes through, `#reasoning_history_refused!` marks the model
  for the worker's life (`LLM::RefusalMemo`) and `:reasoning_history_refused` goes out; refused again, the
  thinking-fields fallback (`#thinking_refused!`) runs. Up to three requests per step. A bad thinking signature
  (`#thinking_signature?`) or a refused binding control (`#thinking_binding_unsupported?`) is **not** a reasoning
  refusal (`ProviderErrors`), so one bad block never turns reasoning off for the model.

### Shared: ToolResponse (per batch) and ToolRunner (per call)

```
KernelLoop#dispatch_calls / ChatLoop::Run#dispatch
  → ToolResponse.run_batch(runner, calls, context:, iteration:, emit:, on_stream_event:, cap:)
    → :tool_dispatch_started
    → per call: ToolRunner#run(call, context:, …)
        wrap (under loads_tools: a direct call of a source tool's acts_as → its call_tool call; Registry::Index#wrap)
        unwrap (Registry::Entry#unwrap: call_tool of chi/<name> → that tool's call, via: "call_tool")
        a tool the toolkit leaves out (ToolSurface#left_out) skips the gate: KernelLoop#dispatch answers it
        Guardrails::Gate#evaluate → :tool_call_started → Gate#settle_ask (an ask) → KernelLoop#dispatch_tool_call
          or the denial text → :tool_call_completed → :after_tool_call hook
        → a ToolRun value (output, capped_output, truncated, activity, images, shown_params, shown_label, refs,
          diff, output_file; nil when a call doesn't produce one)
    → :tool_dispatch_completed
  → native: ToolResponse.joined(runs, ids:), one entry; chat: ToolResponse.single(run, tool_call_id:, ids:) per call
    ids: ToolIds.next_ids ("t41"), saved as tool_ids; LLM context edits name outputs by them
```

A denied call gets denial text in place of its output; the rest of the batch still runs. After a hook's
`stop_turn`, the gate denies every remaining call of the batch. Under the surface's `loads_tools` a reachable
built-in or plugin tool called by its own name is not a left-out call: it runs through the gate
(`ToolSurface#entry_for`).

**ToolRunner** (`tool_runner.rb`) reads of the turn only the `context:` it is given (folders, the settings' vision,
LLM context layers and `loads_tools`, the participant's author and mode); the kernel gives it only what lives as
long as the Engine (tools, hooks, the gate). The rules an edit gets wrong:

- The gate runs **before** `:tool_call_started`, so the event shows the call that will run (a before_tool_call
  hook may replace it; known-names corrects a misspelled name this way). An ask is settled **after** it, so a UI
  shows the tool line, then the approval. An unwrapped call_tool shows the built-in's params and label.
- **Row fields.** `ToolRowFields.for` builds the row fields (title, called_as, via, view, ref) live and on a reload
  (`MessageParts#tool_part`, after `BuiltinCalls.unwrap_saved`). `ToolRowFields::ACTIVITY_KEYS` travel inside
  `activity`; `EVENT_KEYS` go top-level on both events. `Bridge::TurnAccumulator` and the web (`activity.js`
  `ACTIVITY_FIELDS` / `EVENT_FIELDS`) copy them by these lists, **so a new row field is added there too**. `ref` is
  `FileRef.for` (opened in `Web::Editor`'s editor, for a local viewer only).
- **Row refs.** A plugin tool's `refs:` lambda (`ToolSpec#per_call`) runs once per call through `RowRefs.for`, which
  never raises (`tool_refs_failed`, `tool_refs_rejected`), resolves relative files against `TurnContext#cwd` (else
  the process's), drops a ref whose spelling **or** real path is outside it, stores a kept one under its real path
  (`File.realpath`), and caps at `RowRefs::MAX_REFS` / `MAX_BYTES`. A reload has no plugins, so the run saves them as
  `tool_refs` (`ToolResponse::SAVED_KEYS`, never sent) and `MessageParts#tool_part` re-checks them
  (`RowRefs.for_display`).
- An unknown tool gets `ToolSurface#unknown_tool_error` ("Error: no such tool ...", never repeating the wrong name).
- Edit and write: the file is diffed, and a memory's index line refreshed (`MemoryBundle::IndexSync`). At most
  `MAX_IMAGES_PER_RESULT` images per result. Non-UTF-8 bytes are scrubbed.
- The output cap (`max_tool_output_chars`, a `memory_read`'s `memory.read_max_chars`) cuts by the tool's
  `ToolOutputCut` policy; an execute's whole output is saved by `ToolOutputFiles` in `TurnContext#session_dir`. See
  [tool-output-limits.md](tool-output-limits.md#the-runners-cut-max_tool_output_chars). The model, the event and the
  after_tool_call hook all get the cut text; `output_file` is on the run and the event, never in the session.
- **The activity's status** (`ToolActivity#tool_activity_status`): `blocked` for a gate denial
  (`ToolRunner#denied`); `stopped` for a call a Stop or signal left unrun (`Tools::Execute::NOT_RUN_ON_STOP`,
  `NOT_RUN`), an execute it killed (`STOPPED_BY_USER`, `STOPPED_BY`) or a `task_wait` whose header says canceled or
  stopped; `ok` for an execute handed over as a task (`#handed_over?`); `error` for any other `Error:` result, a
  failed `task_wait`, and an execute that exited non-zero, **except** a grep-family search that found nothing
  (`ToolActivity.no_match?`, conservative: when unsure, not a no-match), which stays `ok` with `no_match: true`
  (kept by SessionMetrics and the TurnAccumulator for the web's "no match" word). The model's text is unchanged.

The two events' payloads are in "Events" below.

### ToolSurface

`Tools::ToolSurface` (`tools/tool_surface.rb`): the turn's tools as **one frozen value**, built once in
`Engine#generate` (`ToolSurface.for(registry, layers:, loads_tools:)`) into `TurnContext#surface`. The Registry is its
only input (`entries`, `reachable_names`, `left_out_names`, `removed_names`, `stranded_names`). It holds `declared`
(prompt order), `index_only` (reached by `call_tool`), `left_out` (`{name => :indexed | :user_only}`), `removed`,
`stranded`, `registered`, `toolkit`, `reaching_kit`, `index`, `layers`, `loads_tools`, and answers `entry_for(call)` (a `via:` call only from
`index_only`; a direct one from `declared`, or `index_only` under `loads_tools`), `unknown_tool_error`, `schemas` and
`deferred_for(conversation)` (the index's source tools are asked per request, so a late MCP server joins mid-turn).

- **Who reads it**: `KernelLoop#dispatch`, `ChatLoop#tool_definitions` / `#deferred_tools` (whether to append
  deferred ones is still the adapter's `#loads_tools?` per request: a refusal turns it off mid-turn), the runner's
  wrap / unwrap / left-out / group-refusal checks, `find_tools` and `call_tool` (`KernelLoop::ToolContext#surface`),
  and the gate's and the row's `call_targets` / `call_preview` (an entry's `preview` / `targets` take
  `(call, surface)`; `Registry#register` wraps a one-argument one).
- **A change mid-turn** (`/toolkit`, a staged `chi.replace_tools`) shapes the next turn's surface only.
- **Fail closed**: a context without a surface raises `Tools::MissingSurface` (`ToolSurface.of`); the `targets:` /
  `preview:` rescues and the runner's unwrap re-raise it, so the call never reaches the gate. A bare kernel's or
  loop's own context builds one (`ToolSurface.bare`: `KernelLoop#own_context`, `ChatLoop#turn_context`).
- **Outside a turn's context**: on the turn thread, built from the Registry (`ToolSurface.for`: the prompt, cached
  per build before `generate` knows `loads_tools`, `SystemPrompt::Built#surface`; `#warn_stranded`; the
  suggestion's lists; the index's `#declare` / `#refresh!`). Off the turn thread, from `ToolkitBinding#published`
  only (`#explained` for `/toolkit` and the snapshot, `ctx.load_tools`).

## State management

### TurnState (cross-thread)

One object (`turn_state.rb`), guarded by a `Monitor`, that the turn thread writes (`begin_turn`, `release_turn`)
and other threads read: the idle scheduler, the Bridge's request threads, plugin threads, the UIs. It holds
running, `context` (nil between turns), `last_context`, `controller`, the turn's thread and `ended`, the sink,
steers and carried steers, and the activity clock.

- `begin!(context:, controller:, sink:, input_waiting:)`: all of it in one step, carried steers become steers. The
  context is built whole before (mode and git included), **so no reader sees a running turn with the last turn's
  author**.
- `replace_context(context)`: the turn thread's new frozen context (`generate`'s settings); refused from another
  thread or for another turn's id.
- `ended!`: the end is decided (`end_turn`); the after_turn / session_end hooks run after it, before `finish!`.
- `own_controller(handler:)`: the controller a plugin's `ctx.http` without `cancel:` stops with
  (`Plugin::Host#cancel_controller`): the turn's, on its thread or inside a plugin handler, until `ended!`; nil
  elsewhere (an anytime command, a service, a plugin's own thread). An init task's own controller wins inside one.
- `finish!`: everything cleared, the context kept as `last_context` (with the last settings when it never reached
  `generate`); returns the steers never taken.
- `steer(text, source:)` (false with no turn), `steer_next_turn(text, source:)`.

**The lock is a leaf: nothing is called out while it is held.**

**Reading the turn from another thread.** A thread off the turn (a Bridge request, an anytime command, a plugin's
thread, a hook fired by one) reads the running turn **only** through `Engine#turn_context` and
`Engine#last_turn_context`, one read each, never through the kernel, `GuardrailWiring` or an Engine ivar. The
readers that do: `Engine#turn_author`, `#side_author`, `EventFanout#working_set_llm_context` and `#live_conversation`
(nil unless the loop's `LLMContextForget::Turn#turn_id` is the running turn's). The turn's own code takes the
context as an argument. The turn stages' reads off the turn: ContextJudge's asks thread reads `current_session`
(`@session`) and shows a card through `show_card` (`Engine#show_card`, whose route `EventRoutes` reads on that thread),
and asks `TurnState#running?`; `announce_objectives` from a Bridge, command or Check this thread reads
`live_conversation` and `session_state_dir` under the event lock. Cancel stays `TurnState#controller` (a Stop never reads `context.controller`).
`spec/turn_context_readers_spec.rb` reads each the moment a turn is published. The tool Registry likewise: off the
turn thread it is `ToolkitBinding#published`, a frozen `Registry#snapshot` swapped at the Engine's build, after
`apply_staged_tools!` and after `apply_toolkit!`.

### EffectiveModel (a snapshot per read)

`EffectiveModel.of(registry, choice)` (`effective_model.rb`) resolves the model once (`HostRegistry#resolve`) and
reads each setting from it (sampling, thinking, reasoning history, steer cut, LLM context, window, price, served
model, vision, profile). **It is built per read and never kept**: config.yml is read live, a model listing can move
a bare id to another host, and another process's saved model lists change what a resolve gives, all without a
`/model`. Frozen, so any thread may hold one.

- The Engine's readers take one (`Engine#effective_model`); those with a fallback go through
  `SessionModelSettings#model_setting` (`session_model_settings.rb`). A turn takes one in `turn_settings` (before
  the hooks) and one in `generate` (after them); `system_prompt`, `steer_cut_after` and the warm-up take their own;
  `stats_snapshot` and `session_state_snapshot` (`EngineSnapshots`, `engine_snapshots.rb`) one each.
- Never resolved (they hold on a broken resolve): `effective_model_ref`, `bare_model_name`, `guardrail_model_name`,
  `sync_model_key!`, `served_model(probe: false)`.
- Readers on other threads: the Bridge (`/state`, `/stats`, the SSE reset, a steer's cut wait), the worker's
  command thread, the recap thread, plugin threads.
- `ModelChoice` (`ModelBinding#choice`) holds the name and the typed name as **one value**, so a reader never pairs
  one model's name with another's typed name.
- Every reader passes its `ModelLookup` (`model_lookup.rb`) to the setting module: one input for every layer (the
  target's host entry, the lookup names, the `models:` map, and the env the CLI/env/file layers are read with, the
  registry's own: `HostRegistry#env`). Each module (`Thinking`, `ReasoningHistory`, `SteerCutAfter`,
  `SamplingSettings`, `VisionSupport`, `ContextWindow.setting`, `LLMContextStrategy`) keeps its own ordered
  `resolve` over it and never names `ModelLookup` or `ModelSettings` (the class map's rule: the modules' parsers are
  what `ModelSettings` calls). `ModelProfile.resolve` takes its `models` map. `.of(registry, choice, models:)` takes
  one map for many models (the start page's picker).
- `EffectiveModel.of_session` builds a saved session's (no worker): `SessionSetting#saved_summary`, and
  `EffectiveModel.session_llm_context` / `.session_budget` (a session page, a session list's ctx %).
- The registry: an Engine (and the TerminalUI) takes `HostRegistry.current` once at its start, so a running worker
  keeps the hosts it started with; commands and chi web read `.current` (one per process, built again when
  `hosts:` changes; it refuses a client override, so a spec's `client:` goes on a registry of its own).

`SessionSetting` (`session_setting.rb`) describes the four per-session settings (llm_context, thinking,
reasoning_history, toolkit): own value, commands, chips, a saved session's chip, the web's fallback. The session
state, `/stats` (no toolkit), `:command_ran` and the web's session JSON list them from it.

### ModelBinding (the choice and its profile)

`ModelBinding` (`model_binding.rb`) holds the model choice, the profile given to `Engine.new` (until a switch), the
prompt profile resolved for the choice (a `[choice, resolution]` pair) and the memory overlay keys, under one mutex.
The Engine forwards `profile_resolution`, `refresh_profile!`, `store_profile`, `apply_profile`, `resolve_profile`,
`sync_model_key!` and `model_key` to it.

- `#switch!` is one assignment under the mutex: a reader sees the old pair or the new one. It drops the given
  profile and the kept resolution.
- `#store_profile` keeps a resolution only while the choice is still the one it was resolved for, **by identity**
  (`equal?`): a `/stats` probing on a Bridge thread while `/model` runs keeps nothing.
- `#apply_profile` runs under the mutex (prompts for another profile dropped, then `KernelLoop#use_profile!`).
  Nothing else takes the mutex.

`ThinkingNotices` (`thinking_notices.rb`) says once per session and host what a turn's thinking level leads to (an
effort the host can't do, an off not honoured, a host refusing the thinking fields or the reasoning sent back).
Turn thread only.

### Turn and TurnContext

The `TurnContext` (`turn_context.rb`, a frozen `Data.define`; `TurnContext.none` for a bare kernel, a spec, the
bundle test kit) holds what the tool path reads of a turn; `Engine::Turn` keeps only lifecycle state. The
KernelLoop has its own `Turn` struct, a run's.

- **Nil until `generate`**: `settings` (`LLM::TurnSettings`), `model_key` / `fallback_model_key` (memory overlays),
  `model_name` (the gate's rules' `models:`) and `surface`. They are set after the `before_turn` hook that may switch
  the model. `turn.prepared_settings` (before the hooks) give vision, sampling and thinking, so a hook's switch gets
  the old model's for those.
- The live bits are objects it holds, not copies: `session` (working-set pins read at call time), `controller`,
  `git` (`Guardrails::GitInfo`, the per-turn git cache).
- **Down the tool path it is an argument**: `ModelBackend#complete(context:)` → `KernelLoop#run` / `ChatLoop::Run` →
  `ToolResponse.run_batch` → `ToolRunner#run` → `Gate#evaluate` / `#settle_ask` and `KernelLoop#dispatch_tool_call`
  → `KernelLoop::ToolContext.new(kernel, context)`. The generation guard gets it too
  (`KernelLoop::Services#generation_guard`, `guard_participant_spend`).
- The kernel's own `context` / `turn_settings` and `ChatLoop#turn_context` are the turn thread's working copies
  (after a chat turn the kernel's still hold the last native run's): **a reader outside the turn uses
  `Engine#turn_context` / `#last_turn_context`**.
- What lasts the Engine's life is not in it: `KernelLoop::Services` (hooks, tools, reminder store, mutes, the
  question handler, peers, the gate, warm-up, the generation guard), one frozen value given at
  `KernelLoop.new(services:)` or `#attach`. **No turn field goes in Services, no Engine-lifetime one in
  TurnContext.**
- Specs: `run_context(settings: …)` and `attach_services(kernel, tools: …)` (spec/support/test_kernel.rb).
- `controller` is an in-process signal; another process stops a worker's turn through the Bridge (`POST cancel` →
  `Engine#cancel_current_turn!`).

**The live conversation and the checkpoint.** Both loops register the array they append to on the kernel
(`KernelLoop#llm_context_turn`, `LLMContextForget::Turn#conversation`, tagged with the run's `turn_id`).
`Engine#live_conversation` returns it only while a turn runs and once its loop registered it (the kernel never
clears it; the turn id tells the last turn's from this one's). A worker's drain (`Worker#pending_input_drain`, at
every iteration boundary) copies it, with the merged lines, into `Session#turn_checkpoint` (`TurnCheckpoint`): every
save while the turn runs writes that copy with an `interrupted_turn` mark instead of the session's messages, at the
first boundary and then at most every `TurnCheckpoint::INTERVAL`. `session.messages` itself is untouched until the
turn ends. The worker then also calls `Engine#checkpoint_metrics`, so `analytics.json` has the running turn's record
as a killed turn's (canceled, `worker_stopped`); the turn's end writes over it.

### SteerCut, GenerationPhase and WaitingSteer

The Engine's one `SteerCut` (`steer_cut.rb`) owns a `GenerationPhase` and a `WaitingSteer`. The Bridge and the TUI
ask it (`Engine#cut_for_steer`, `#input_epoch`, `#generation_snapshot`), the stream handler feeds it
(`SteerCut#observe`), a drain that took input calls `#delivered!`, and `release_turn` calls `#finished!`.

- `GenerationPhase`: whether a steer sent as a cut (`/cut TEXT`, `chi send --cut`) may cut the running generation.
  `cut_for_steer` answers `:now`, `:waits` or `:off`. A generation is cuttable while it has streamed only thinking,
  is still thinking, and has thought for at least the model's cut wait (`SteerCutAfter.resolve`). Its `snapshot`
  (`{thinking_only, age}`) goes into the Bridge's `current_turn.generation`, so a page joining mid-generation can
  tell whether "cut in now" can land.
- `WaitingSteer`: a cut that came too early. It waits until the thinking passes the cut wait (rechecked on each
  thinking chunk), until a drain hands it to the model at a boundary, or until the turn ends.

## Events

### The turn's sink (`on_event`) and the observers

`Engine#emit_event` (`EventFanout#emit_event`, `event_fanout.rb`, which also builds the loops' stream handler and
emits the working set) sends each turn event to the turn's sink (a one-shot's renderer) and then to the persistent
observers (`Engine#subscribe`), which get a copy with a monotonic `event_seq`: the metrics, the debug log, the
thinking tails, and in a worker the Bridge ([bridge.md](bridge.md)). **Errors in the sink or an observer are
caught; they never break the turn.**

`Engine#announce` puts an event that belongs to no turn (`Engine::ANNOUNCEABLE_EVENTS`: `turn_enqueued`,
`turn_dequeued` (`{enqueued_id, client_id}`: the remover's), `card`, `hook_notice`, `guardrail_warning`, `participants_changed`
([participants](participants.md#the-owners-terminal)), and more) to the observers only. `:side_usage` (a side
request's usage and the session's side sums) goes to the observers the same way from `Engine#note_side_usage` (any
thread), without being announceable.

Turn events (the main ones; `events.rb` keeps the shared sets):

| Event | When | Payload |
|---|---|---|
| `:turn_started` | `prepare_turn` | `{session_id, prompt, turn_id, at, continue?, resumed?, images?, cut_after}`, plus `author` / `author_name` / `participant_mode` for a participant |
| `:reminder_injected` | due reminders went in | `{reminders, at}` |
| `:context_status` | every request (unless `context.status` is off); outside a turn after `/model`, observers only | [context-telemetry.md](context-telemetry.md) |
| `:generation_started` | a request begins | `{iteration, context_window_tokens, context_window_source, price, model_ref}` (`model_ref` from the model `generate` resolved after the hooks; native adds `profile`, `profile_source`) |
| `:generation_chunk` | each streamed chunk | `{iteration, content, text, thinking, payload, tool_call?}` (SSE clients get the Bridge's projection) |
| `:generation_retrying` | a transport retry, or a chat step asked again after its stream dropped (`restarted: true`: what the step streamed is void, and every live view starts it over) | `{iteration, attempt, max_retries, next_delay, error_class, error_message, status, restarted?}` |
| `:generation_completed` | a generation ended, or was cut | `{iteration, content_length, thinking_chars, served_model, requested_model, finish_reason, ...}`; a cut adds `stopped_by`, `stop_reason`; the Engine adds `speed`, `tokens`, `model_segments` |
| `:generation_cancelled` | cancelled mid-loop | `{iteration, reason, stopped_by}` |
| `:thinking_dropped` | the chat loop dropped replayed thinking blocks (`ChatLoop#settle_dropped_thinking!`; anthropic.md) | `{iteration, count, how}` |
| `:empty_answer_retry` | an empty, cut or malformed answer asked again | `{iteration, attempt, of, finish_reason, thinking_chars, stopped_by?, malformed?}` |
| `:steer_cut` | a steer cut the generation | `{iteration, source}` |
| `:llm_context_edited` | the apply rule applied a batch of LLM context edits (a request, a forget_outputs call, turn end; never the warm-up) | `{moment, why, freed_tokens, tail_tokens, staged, text, groups}` (`LLMContextNotice`) |
| `:thinking_refused` / `:reasoning_history_refused` | the chat loop's fallbacks; logged and made a once-per-session-and-host `:hook_notice`, **never reaching the sink** | `{iteration, model, level, detail}` |
| `:pending_input_merged` | queued input joined the conversation | `{iteration, count, content, steers?, answer}` |
| `:tool_dispatch_started` / `_completed` | around a batch | `{iteration, call_count}` |
| `:tool_call_started` | before a call runs | `{iteration, call_count, call_index, tool, call, params, label, title, called_as, via, view, ref, refs}`; the SSE frame omits `call` |
| `:tool_call_completed` | after a call ran | `{iteration, call_count, call_index, tool, output, output_truncated, output_file, activity, images, diff, waited_ms, view, ref, refs}` |
| `:question_requested` / `_answered` / `_cancelled` | `QuestionDesk` (an approval, `ask_user_question`, a hook's `ask_user`, the step-limit Continue) | `{pending_question}` / `{id, answer}` / `{id, reason}` |
| `:plugin_init_wait` | a turn waits for init tasks that provide tools (`PluginTasks`) | `{tasks: [{bundle, id, label}]}` |
| `:used_memories_updated` | a memory was read, and after the loop | `{used_memory_names, read_names?}` |
| `:working_set_updated` | after `:generation_started` and once in `end_turn`, only when the set changed (`Engine#emit_working_set`) | [working-set.md](working-set.md) |
| `:hook_notice` | a hook's or plugin's notify | `{hook, text, level}` (`between_turns: true` outside a turn) |
| `:guardrail_warning` | a guardrails line | `{message}` |
| `:turn_completed` | normal end | `{turn_id, result, turn_summary, display_pending}`, plus `verify`, `verdict`, `revises` when there are; the SSE frame omits `result` |
| `:turn_canceled` | Stop, hook stop, Ctrl-C, signal | `{turn_id, cancellation_reason, cancelled_by?, duration_ms}` |
| `:turn_failed` | an error | `{turn_id, error_class, message, duration_ms, error_kind?, retryable?, host?, summary?}` |
| `:answer_display` | after the after_turn hooks (observers only) | `{display, refs?}` |

### Origins and authors

A turn's origin is a `TurnOrigin` (`turn_origin.rb`, `client_id`, `enqueued_id`, `author`). `SessionInbox.read_input`
makes it from an input file; the wakes, reports and reminders make theirs. Ask it, don't read fields
(`#participant?`, `#participant_author`, `#participant_id`, `#source`, `#human?`). At a boundary it is turned once:
`#to_h` writes the wire Hash (only the fields set), `TurnOrigin.from` reads one back. **In-process an origin is never
nil**: `TurnOrigin.of` gives `TurnOrigin::NONE` (an owner's turn with no client) for nil or `{}`; NONE has no wire
form (`#empty?`, `#wire` nil), so events and hooks carry no origin for it. The boundary events (`:turn_started`,
`:turn_completed`, `:turn_canceled`, `:turn_failed`) carry `origin` when there is one (`Turn#tag`), with `author:`
when someone other than the owner wrote it (stamped by chi web from the request's `Web::Principal`). **An owner's turn
has no `author` anywhere**: not in its input file, its origin or the session.

Where a participant's author (`"p:<id>"`; `Steer.participant_author?`) goes (the model is in
[participants.md](participants.md)):

- **The opening message** gets `author` and `author_name` (`Engine#author_fields`; the name from
  `participants.json` at the turn's start, left out when unnamed). Merged input and steers carry the same keys,
  grouped by sender and author so a participant's lines never share the owner's message (`Steer::Line#author`).
  Assistant and tool messages carry none: `Steer.author_at(messages, index)` resolves by position. `ChatLoop#plain`
  keeps the keys (`Steer::AUTHOR_KEYS`).
- **The wire**: such a message goes out under the review-contribution header (`Steer.wire_text`; prompt-caching.md).
  Saved raw.
- **`Session#last_turn.author`** and the analytics record's `author` (`SessionMetrics`); a Continue keeps the offer
  turn's author (`ContinueOffer#run_continue_turn`).
- **Never a command**: a participant's `/word` or `!line` is refused (`Bridge#handle_post_turn` 403,
  `WorkerInbound#queue_as_command` drops it). The same two intakes ask `CommandIntake.allowed?` for every other
  sender: only a person's (`ClientId.human?`, not `review:`) and `cli:answer`'s line is a command; from a delegate, a
  schedule, a plugin or a wake a `/word` line is a prompt and a `!` line is refused (the Bridge's 403
  `command_not_permitted`; an input file's or a first prompt's is queued and `Worker#run_command_line` answers it with
  the error `command_ran`). A session's first prompt carries its sender too: `WorkerInbound#initial_origin` reads
  `Session#first_turn_client_id` (a delegate child without it: `ClientId.delegate` of its parent) and `first_turn_id`,
  for `#initial_command?` and `Worker#run_initial_prompt`.
- **Delivery**: a participant's input always waits for a turn of its own (`SessionInbox.waits_for_turn_end?`), so
  the drain never merges it; their turns count against chi web's `pending_limit` (429 `too_many_turns`).
  `Worker#run_prompt` checks their link and cap (`participant_refusal`) before the turn and after it.
- **The gate**: `GuardrailWiring#participant_boundary` picks `Guardrails::PairBoundary` or
  `Guardrails::ReviewBoundary` by `TurnContext#participant_mode` (guardrails.md). Both are no-ops for the owner.
  The declared tools stay the session's (no rebuild per author).
- **Hooks and plugins**: `Engine#turn_author` (the published `TurnContext#author`, so any thread reads it from the
  turn's first moment) is the hook runtime's (`author:` on every event of such a turn) and `ctx.turn_author`.
- **Spend**: `SessionMetrics#spend` / `spend_by_author`; `Engine#note_side_usage` stamps a side request's author
  (`#side_author`) into `SideTotals#by_author`.
- **Side models**: `IdleRecap::TranscriptFilter` and `Plugin::SideQuestion` name a participant's message as theirs.
- **The system prompt**: `Engine#refresh_participants!` rebuilds it when the session gains its first active
  participant or loses its last.

### Hook points (not events)

`:session_start`, `:before_turn`, `:after_turn` and `:session_end` are hook points: the Engine fires them on the
hook registry (`@hooks.fire`), not on the sink or the observers. The others are `:before_generation`,
`:after_generation`, `:generation_progress` (`Hooks::StreamWatch`), `:before_tool_call` (the gate) and
`:after_tool_call` (ToolRunner). docs/hooks.md lists their payloads.

## Session lifecycle

`Engine#initialize` (`engine.rb`, the `build_*` methods) wires the collaborators. Read it for the order; what an
edit must keep:

- **Building an Engine makes no network call**: the profile is resolved on first need (`ModelBinding`).
- `MemoryBundle::SystemBundle.ensure!` runs at build; a failure is logged, not raised.
- The turn stages are built before the plugins load (`build_tools_and_plugins`: `ExtensionLoad`, the built-in
  `Tools::Builtins.registry`, `ToolkitBinding`, `Tools::ToolIndex`, `PeerSources`, then the plugins; each plugin's
  `ctx` is a `Plugin::Context` over `plugin_host`). After the plugins (or none), `@tool_index.declare(@tools)`
  registers `find_tools` + `call_tool` (source "index", not core), declared per toolkit by `Registry#declared?`
  (`Toolkit::Resolved#declares?` treats built-ins and plugin tools alike).
- `wire_kernel` gives the kernel one `KernelLoop::Services` (Engine-lifetime: hooks, tools, reminder store, mutes,
  question handler, peers, gate, warm-up, generation guard); the client is no service (a model switch swaps it,
  `sync_kernel_client!`).
- `@hooks.runtime = @hook_routes.runtime`: what a hook or plugin does reaches the UIs (`HookRoutes`, built first).
- `EngineSnapshots` is built last: nothing reads a snapshot while the Engine is built.

**Model switching** (`Engine#switch_model!`, `engine/models.rb`): checks the host (`ModelProfile.check_host!`),
`ModelBinding#switch!` (name and typed name in one assignment, the profile and resolution dropped), `sync_model_key!`,
`@prompt_builder.reset!`, `sync_kernel_client!`, the context window cache dropped, the old model's context reports
dropped (`@metrics.forget_model_reports!`); `/model` then calls `#announce_switched_context!`
(context-telemetry.md). **The kernel is never rebuilt**; the next turn's backend follows the new host's api.

**Model probes.** The profile, window, served model and vision are asked from the server's `/props` as needed. The
cache is dropped at the turn's end, not its start, so one turn doesn't ask twice; a Stop cuts the probes
(`Client.swap_probe_cancel`).

## Hooks

Plugins (`chi.on`) and config hook files register hooks on hook points (docs/hooks.md). Every fire puts the hook runtime on the
event: `event[:hook]` (the label) and five helpers, which call the Engine's `Hooks::Runtime` (built by `HookRoutes`,
`hook_routes.rb`). A plugin's `ctx` has the same ones. A question takes keywords only at that plugin-facing edge;
from there it is one `HookQuestion` value through `Engine#hook_ask_user` and `HookRoutes#ask_user` to
`QuestionDesk#ask_for_hook` (the bundle test kit records the same value, `Testing::Recorder#questions`).

| Helper | What it does | Used by |
|---|---|---|
| `event[:notify].call(text, level:, fallback_for:)` | One line to the user (`:hook_notice`); `fallback_for: :display` marks a line standing in for the answer's display | mcp, loop-guard |
| `event[:ask_user].call(question:, options:, header:, allow_freeform:)` | A single-select question; nil when there is no one to ask | known-names |
| `event[:stop_turn].call(reason)` | Cancel the running turn (`:hook`), with a warn notice | loop-guard, check-in |
| `event[:stop_generation].call(reason)` | Cut the streaming generation; the turn goes on | loop-guard |
| `event[:steer].call(text)` | Queue text for the running turn's next boundary | check-in, skills |

From `:after_turn` and `:session_end` there is no turn left: `stop_turn` and `steer` return false.

**Display-only fields.** `:after_turn` adds `event[:present]` (`AnswerDisplay`, the answer's `display` text) and
`event[:refs]` (`AnswerRefs`, refs kept as `display_refs`), built on the stored conversation's last message when it
is the model's. `AnswerDisplay::DISPLAY_ONLY` (`display`, `empty_answer`, `display_refs`) is dropped from every
model-facing copy (`strip` / `strip_all`: hooks' `messages:`, the recap, `ctx.messages`, after_generation), while
`KernelLoop#sanitize_history` and `ChatLoop#plain` copy them so the stored conversation keeps them across turns.
`Web::App#messages_for_display` re-validates `display_refs` (`AnswerRefs.for_display`).

**History stamps.** User prompts, merged input and steers, reminders, context and task notes and the model's replies
carry `at` (`MessageTime::KEY`, `message_time.rb`). A turn reads the wall clock once (`Turn#wall`): `:turn_started`'s
`at`, its prompt's and its reminders' stamps. The others are stamped by `Steer::Merge#messages` (a merge),
`ContextNote.message` (a note's `created_at`), `KernelLoop#iterate` / `#cancelled_result` and the chat loop's
`Run#with_thinking` / `Run#canceled` (each reply): **a new reply path stamps it too**. Tool results, `!cmd` messages and TurnNote notes carry none. **`at`
must survive the two rebuilds**: both model branches of `KernelLoop#sanitize_history` and `ChatLoop#plain` copy it
(an allow-list that drops a key loses it for good; `spec/message_time_history_spec.rb` checks both loops). It never
reaches the wire (prompt-caching.md) but is not in `DISPLAY_ONLY`: hooks and `ctx.messages` see it. Gap dividers
come from `MessageTime.gap_line`.

**`:question_asked`** (`QuestionAsked`, `question_asked.rb`) fires only from the two seams where a question of the
model's opens: `Engine#request_question` (the kernel's question handler; not non-interactive) and
`GuardrailWiring#request_approval` (after a stored approval and the non-interactive deny), never from
`QuestionDesk` (so not `ask_for_hook`, a relayed approval or the step-limit question). It is a no-op without a
subscriber. Else it finds the live conversation's last model entry (`Engine#live_conversation`), builds an
`AnswerRefs` on that step with the question caps, fires with `Engine#question_step_text`, and sets `display_refs` on
the step **in place** under the event lock (the loops and the forget layer hold entries by identity). The refs ride
`PendingQuestion#refs` to `:question_requested`, the session file and the cards; `Web::App#with_question_refs`
re-validates them ([architecture.md](../architecture.md), the `display_refs` paragraph).

### Hook lifecycle

- **Bundle hooks** (`Registry#register_bundle`) and **config hooks** (`register_persistent`) live for the process:
  `clear_all` leaves them.
- **Turn-scoped hooks** (`Engine#register_hook`) are cleared by `clear_hooks` in `release_turn`.
- Fire order: bundle hooks (by priority, bundle, hook name), then config hooks, then turn-scoped hooks.
- **A hook that raises is logged; it never breaks the turn.** A plugin's `chi.on` handler also tells the user once
  per label (`Hooks.wrap(on_failure:)` → `HookRoutes#plugin_hook_failed`: a `:guardrail_warning` labelled
  `plugins`, through `Plugin::Registries#hook_failed`). A config hook has none, nor the test kit's sandbox.
- `ExtensionLoad#hooks` loads config.yml's hooks only; an installed record's class-file bundle hooks (an older
  chi's install) never load ([hooks.md](../hooks.md#class-file-hooks-are-retired)).
- A notice goes to the running turn's sink and the observers; outside a turn it is announced with
  `between_turns: true`; while the plugins load it is held. `EventRoutes#route` decides it, the same routes as a card's
  (`Engine#show_card`); a guardrails line after load takes only the turn / between-turns routes (`#route_by_turn`).
- Plugin init tasks (`chi.init`): a turn waits for those that provide tools before it builds its messages; a Stop or
  Ctrl-C ends the wait.

## Guardrails

`ToolRunner` asks the kernel's `Guardrails::Gate` before each call with the call's `TurnContext`
(`Gate#evaluate(call, context:)`); **`GuardrailWiring` keeps no per-turn state**, it makes the guardrails context and
checks from the turn (`#context(turn)`, `#checks(turn)`). The gate is not itself a hook. It fires the
`:before_tool_call` hooks (the voters), which vote through `event[:guardrail]` (`deny!`, `ask!`) or the legacy
`event[:blocked]`. A deny stays a deny for the hooks after it; a hook's ask is dropped when guardrails are disabled.
Then the core checks run on the final call in `GuardrailWiring#checks` order (`guardrail_wiring.rb`). **That method is
the order**; it is not spelled out here so this page can't drift from it.

**A gate that raises denies the call.**

- **allow**: the call runs.
- **deny**: the output is replaced with denial text; the rest of the batch still runs.
- **ask**: `Gate#settle_ask` looks for a stored approval first, else `GuardrailWiring#request_approval` asks the user
  through the question flow. A `--non-interactive` run has no one to ask: denied. An approval wider than this once is
  stored.

docs/guardrails.md covers the rules, the boundaries and the approval scopes.

## Anytime commands

A slash command a plugin registers with `anytime: true` (`/btw`) runs on its own thread, even while a turn runs:
`Engine#spawn_anytime` (a thread `#shutdown` waits for) and `#running_anytime` (cards and notices on that thread are
announced at once, marked `anytime: true`, **never as the running turn's events**), in `engine/cards.rb`.
`add_init_task` / `await_init_tasks` belong to plugin init tasks (`PluginTasks`), not to anytime commands.

## Shared loop behaviors

Both loops, unless marked:

- <a id="a-reply-that-is-only-a-tool-call"></a>**A reply that is only a tool call** (`LLM::StrayToolCall`, chat loop
  only): a reply with no tool calls whose whole text is one tool-call block closed by the tag that opened it, or by
  the wrapper's `</tool_call>` (`<function=` by `</function>` or `</tool_call>`, `<parameter=` by `</parameter>`, `</function>`
  or `</tool_call>`, `<tool_call>` by `</tool_call>`; inner tags not needed) isn't an answer. Prose or a fence before it, or anything
  after the close, keeps it an answer. Nothing is guessed from the block and it never enters the history (`:generation_completed` and
  `:after_generation` have already seen the text): `:generation_retrying`
  with `restarted` voids the streamed text, `:empty_answer_retry` with `malformed` goes out, and a hidden
  `TurnNote.malformed_retry` asks again at the retry temperature. Its own budget (`retry.empty_answer: 0` doesn't turn
  it off; a real tool call resets it); two in a row fail the turn with `LLM::MalformedGeneration`, keeping its
  earlier steps. A Stop on a stray reply ends the turn cancelled, not failed. Logged `generation_malformed`.
  `KernelLoop` has its own path (`ToolCallParser#malformed`).
- **Empty-answer retry** (`EmptyAnswerRetry`): no visible text and no tool calls is asked again, up to
  `retry.empty_answer` times (at most 3), with a hidden `TurnNote.empty_retry`, at temperature 0.6 only when the
  configured sampling sets none. A length stop with the context ≥ 90% full is not retried. Out of retries, the turn
  ends with a `TurnNote.empty` note. A Stop on an empty reply ends the turn cancelled.
- **A refusal** (chat loop only): finish reason `refusal`, or `content_filter` with no text, is an empty answer never
  retried; text streamed before it is not kept and tool calls with it don't run. A `content_filter` with text keeps
  it, marked `ChatLoop::FILTERED_MARK`, also never retried. `ModelResult#refusal` (`{category:}` or `{}`) goes on the `TurnNote.empty`
  marker and `turn_summary.empty_answer`, so every UI words the notice the same.
- **A cut generation** (`after_cut`): a plugin's cut (`stop_generation`) spends the same retry budget with its own
  nudge; used up, the turn ends cancelled (`:hook`). A steer's cut asks again with the steer and spends nothing.
- **Steering**: queued input goes in at iteration boundaries (`Steer.inject!`, `:pending_input_merged`). A worker's
  drain takes every input file in name order except those `SessionInbox.waits_for_turn_end?` leaves for a turn of
  their own (`delivery: queue`, images): skipped, **not a barrier**, so a line sent after them still merges. Only
  the claimed files reach `:input_merged`, the failure hand-back and the checkpoint; the skipped ones run after the
  turn, one turn each (`Worker#run_input_files`).
- **Context status**: an estimate before every request (`:context_status`), a guidance line on the tail only when
  it rises far enough.
- **Cancel**: text streamed before a cancel stays, marked `[interrupted]`.
- **The same events** and generation / tool call hooks.

Native loop only: the Qwen open-block recovery, and the thinking prefill (`Thinking.native`,
`KernelLoop#native_prefill`, once per turn): with thinking off, Qwen gets `QWEN_EMPTY_THOUGHT` and Gemma 4
`GEMMA_EMPTY_THOUGHT` (no `<|think|>` token); otherwise Qwen gets `QWEN_OPEN_THOUGHT` when its chat template writes
one (`Thinking.opens_thought?`). The prefill is kept in the model message so the next prompt starts with what the
server cached; each generation's `ThoughtStreamSplitter` is seeded with it, so the reasoning never lands in the
answer.

## Key design principles

1. **Turn state is cross-thread safe.** TurnState uses one Monitor and calls nothing out while it is held; other
   threads read the turn only through `Engine#turn_context` / `#last_turn_context`.
2. **Turn-scoped and process-wide hooks.** `register_hook` hooks are cleared at `release_turn`; bundle and config
   hooks survive.
3. **Each loop works on its own copy of the conversation** (see "The model↔tool loop").
4. **Events are the contract.** UIs read events, not internal state. `on_event` is per turn; observers persist.
5. **A stable system prompt for the cache.** `SystemPrompt#build` caches per Engine, keyed by
   `[chat, thinking, layers]`, reset only on a model switch, a tools change, `Engine#prompt_changed!`, a profile
   change or `Engine#apply_toolkit!`. The section order and the stable/volatile split are prompt-caching.md's.

## Key files

Paths are under `lib/samagotchi/`. The session manager, the Worker, the Bridge, task watches and guardrails files
are in [architecture.md](../architecture.md)'s file table.

| File | Role |
|---|---|
| `engine.rb` | The wiring (`initialize`, `build_*`, the kernel), the turn skeleton (`run_turn`, `begin_turn`, `prepare_turn`, `turn_messages`, `generate`, `end_turn`), `shutdown` |
| `engine/steering.rb` | `Engine::SteeringPart`: steers, the drains, the cut, the activity clock, the cancel |
| `engine/side_requests.rb` | `Engine::SideRequestsPart`: ctx.ask_model's and Check this's side requests, side usage, System 1's recording (`system_one_recorder`) |
| `engine/recap.rb` | `Engine::RecapPart`: the idle recap and `/recap` |
| `engine/models.rb` | `Engine::ModelsPart`: model names, identity, notes, `switch_model!`, the profile, `backend` |
| `engine/model_settings.rb` | `Engine::ModelSettingsPart`: SessionModelSettings and EngineSnapshots, forwarded |
| `engine/events.rb` | `Engine::EventsPart`: observers, `#announce`, the event lock, held announcements |
| `engine/cards.rb` | `Engine::CardsPart`: `#show_card`, anytime commands |
| `engine/objectives.rb` | `Engine::ObjectivesPart`: the objectives stage's builder and forwards (`announce_objectives`, `show_objective_proposals`, `track_objectives_after`), Check this's and the tracker's side requests (`ask_objective_check`, `ask_objective_track`) |
| `engine/messages.rb` | `Engine::MessagesPart`: out-of-turn message edits, checkpoints, the live conversation |
| `engine/plugins.rb` | `Engine::PluginsPart`: plugins, init tasks, staged tools, `Plugin::Host` |
| `engine/hooks.rb` | `Engine::HooksPart`: turn-scoped hooks, the hook runtime, reminders |
| `engine/guardrails.rb` | `Engine::GuardrailsPart`: the guardrails' readers, the first turn's load warnings |
| `engine/participants.rb` | `Engine::ParticipantsPart`: the turn's author, a pair turn's stop, the participants line |
| `engine/session.rb` | `Engine::SessionPart`: `#session=`, the state dir, the relay's view, the system prompt |
| `engine/verify.rb` | `Engine::VerifyPart`: the Verify/Revise anchors' stage builder |
| `engine/questions.rb` | `Engine::QuestionsPart`: ask-user-question (QuestionDesk, forwarded) |
| `engine/toolkit.rb` | `Engine::ToolkitPart`: the toolkit, `ctx.load_tools`, the toolkit suggestion's builder |
| `engine/context_judge.rb` | `Engine::ContextJudgePart`: the candidate judge's builder and `judge_late_candidates` |
| `engine/turn_helpers.rb` | `Engine::TurnHelpersPart`: turn settings, images, model ref, used memories, the warm-up's builder |
| `engine/turn_end.rb` | `Engine::TurnEndPart`: `complete_turn`, release, what an ending keeps, `last_turn`, the answer's display |
| `turn_stages/*.rb`, `system_one/recorder.rb` | The turn stages and their recorder ("Turn stages") |
| `turn_context.rb`, `turn_state.rb`, `turn_endings.rb`, `turn_origin.rb`, `turn_checkpoint.rb` | `TurnContext`; cross-thread turn state; the endings' builders; `TurnOrigin`; the running turn's checkpoint |
| `event_fanout.rb`, `events.rb`, `event_routes.rb` | `EventFanout` (sink + observers, the stream handler, the working set's emit); the shared event sets; where a card, notice or guardrails line goes |
| `engine_snapshots.rb` | `session_state_snapshot` (cheap, never raises), `stats_snapshot` (may probe `/props`) |
| `model_binding.rb`, `effective_model.rb`, `session_model_settings.rb`, `session_setting.rb` | The model choice and profile; `EffectiveModel` / `ModelChoice`; the session's settings on its model; the per-session setting descriptors |
| `model_lookup.rb`, `host_registry.rb`, `host_address.rb` | `ModelLookup`, every setting layer's input; `HostRegistry` (`.current`, the shared one); `HostAddress`, whether an address is remote |
| `thinking_notices.rb`, `level_setting_command.rb`, `thinking_command.rb`, `reasoning_history_command.rb`, `reasoning_history.rb` | Thinking notices; `/thinking`, `/reasoning-history`; `ReasoningHistory` (`.resolve`, `.run_start`) |
| `steer.rb`, `steer_cut.rb`, `generation_phase.rb`, `waiting_steer.rb`, `steer_cut_after.rb`, `cut_policy.rb` | Steers at boundaries; the cut seam and its parts; the cut wait; the loops' cut path |
| `kernel_loop.rb` | The native loop |
| `reprefill_meter.rb` | `ReprefillMeter`: the Engine's one re-prefill baseline, given to both loops (prompt-caching.md, "Reading the numbers") |
| `llm/chat_loop.rb`, `llm/adapters.rb`, `llm/openai_chat.rb`, `llm/adapter_common.rb`, `llm/refusal_memo.rb` | The chat loop; `BY_API`; the OpenAI adapter; what both adapters share; refusals remembered |
| `llm/anthropic_messages.rb`, `llm/anthropic_wire.rb`, `llm/anthropic_assembly.rb`, `llm/dialect.rb`, `llm/prompt_cache.rb` | The Messages adapter ([anthropic.md](anthropic.md)); cache breakpoints |
| `llm/backend.rb`, `llm/native_backend.rb`, `llm/model_result.rb`, `llm/turn_settings.rb` | `ModelBackend`; `NativeBackend`; `ModelResult`; `TurnSettings` |
| `llm/native_tool_normalizer.rb`, `llm/stream_drops.rb`, `llm/stray_tool_call.rb` | Adapter tool calls as chi's; a dropped stream asked again; a reply that is only a tool call |
| `tool_runner.rb`, `tool_response.rb`, `tool_row_fields.rb`, `row_refs.rb` | Per call; per batch; row fields; plugin row refs |
| `tool_output_cut.rb`, `tool_output_files.rb` | The output cap's policies; an execute's saved whole output ([tool-output-limits.md](tool-output-limits.md)) |
| `tools/tool_surface.rb`, `tools/registry.rb`, `tools/tool_index.rb`, `plugin/tool_spec.rb` | The turn's surface; the Registry; `find_tools` / `call_tool`; a checked plugin tool declaration |
| `toolkit.rb`, `toolkit_command.rb`, `toolkit_binding.rb` | Toolkits; `/toolkit`; the Engine's toolkit seam (`#published`, `#apply!`) |
| `empty_answer_retry.rb`, `prompt_warmup.rb` | The empty-answer and cut retry budget; the turn-end warm-up |
| `system_prompt.rb`, `prompt_files.rb`, `model_notes.rb` | The system prompt; AGENTS.md and appended files; model notes |
| `hooks/registry.rb`, `hook_routes.rb`, `hook_question.rb`, `extension_load.rb` | Hook registry and `Hooks::Runtime`; the hook routes; `HookQuestion`; what an Engine loads at start |
| `question_desk.rb`, `pending_question.rb`, `question_answer.rb`, `question_asked.rb` | The one open question and its values; `:question_asked` |
| `engine_peers.rb`, `peer_sources.rb` | `Engine::PeerView`, `Engine::RelayPeer`; `PeerSources` |
| `guardrail_wiring.rb`, `guardrails/gate.rb` | The gate's context, checks and approvals; the verdict per call |
| `cancellation_controller.rb`, `context_status.rb`, `side_usage.rb`, `degrade.rb` | A turn's cancel signal; context tracking ([context-telemetry.md](context-telemetry.md)); a side request's usage; `Degrade` |
