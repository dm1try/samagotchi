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

`context` is the turn's `TurnContext` (`lib/samagotchi/turn_context.rb`, see "Turn and TurnContext" below): every
step of the tool path takes it as an argument; none of them reads the turn from the kernel, the wiring or the
Engine's ivars.

## Quick reference: the turn lifecycle

```
Engine#run_turn(session, prompt, on_event:, max_iterations:, cancel_controller:, max_tool_output_chars:,
                pending_input:, continue:, origin:, images:, id:, resumed:, resume_from:, input_waiting:)
  │
  ├── begin_turn(session, prompt, on_event:, cancel_controller:, origin:, continue:, id:, input_waiting:)
  │     # a Verify turn's claim checked first: @verify_anchors.verified(session, anchor) (nil when its
  │     #   quote isn't in the source session's answer)
  │     # (then, on a continue, turn.resumed = resumed (a step-limit Continue) and
  │     #  turn.resume_from = resume_from (its run's start; nil: it starts cold))
  │     # @session = session, session.status = RUNNING, used memories absorbed,
  │     # the TurnContext built whole first (new_turn_context: GuardrailWiring#begin_turn(origin, session:)
  │     #   → TurnStart {git (a fresh GitInfo), participant (participants.json), mode}; id: the caller's
  │     #   id:, else a new uuid; cwd, session_dir, state_dir; settings nil until generate),
  │     # then TurnState#begin!(context:, controller:, sink:, input_waiting:): the context published with
  │     # the running flag in one step (a new CancellationController when none is given; input_waiting:
  │     # the caller's peek, Engine#input_waiting?, which task_wait, delegate_result's wait and execute's
  │     # early hand-over poll), a recap in flight invalidated
  │     # Returns a Turn {context, prompt (nil on a continue), continue, on_event, started_at, resumed,
  │     #                 resume_from, wall (MessageTime.now)}; turn.id/session/origin/controller read
  │     #                 the context
  │
  ├── Client.swap_probe_cancel(turn.controller)   # a Stop cuts this turn's /props probes
  │
  ├── prepare_turn(turn, images)                 # its skeleton; the stages are in "Turn stages" below
  │     # emit :turn_started {session_id, prompt, turn_id, at (the turn's wall time, Turn#wall: read once,
  │     #   the user message's and the reminders' stamp too), continue: true (only on a continue),
  │     #   resumed: true (only on a step-limit Continue), images (only when there are any),
  │     #   cut_after (the model's cut wait, s)}; an image error raised after it
  │     @toolkit_suggestion.start(turn)          # before the probes: its latency hides behind them
  │     refresh_profile!                         # may ask the server's /props once
  │     turn.prepared_settings = turn_settings(session); refuse_images!
  │     #   (LLM::TurnSettings: vision, sampling, thinking from one EffectiveModel; model_name, loads_tools …
  │     #   come in generate, after the hooks; ThinkingNotices#turn_started says a level the host can't do)
  │     STOP CHECK A → @toolkit_suggestion.abandon(turn, :canceled); return false
  │     announce_guardrail_failures; start_init_tasks!; await_init_tasks; apply_staged_tools!
  │     @toolkit_suggestion.settle(turn)         # on mode: the turn joins the ask, before anything is declared
  │     @context_judge.start(turn)               # owner turns only; its asks run beside the turn
  │     @objectives_stage.incoming(turn)         # System 1's objectives audit, owner and human prompts only
  │     apply_toolkit!(session, on_event)        # Registry#toolkit, ToolIndex#refresh! for find_tools' chi
  │     #   line, a prompt rebuild when it changed; a warn per plugin tool that arrived mid-session with
  │     #   nothing to reach it (Registry#stranded_names)
  │     refresh_participants!(session)
  │     STOP CHECK B → return false              # before the hooks run or a reminder is used up
  │     :session_start hook (the Engine's first turn), then :before_turn (a frozen copy of the history,
  │     #   the prompt, resumed)
  │     turn_messages(turn, image_refs)          # system head + history + due reminders (:reminder_injected)
  │     #   + the user message + the plugins' staged tool loads (ctx.load_tools: a kind "tool_change" system
  │     #   entry per bundle, only when the turn's host takes tool changes; #append_tool_loads)
  │     ensure: @toolkit_suggestion.abandon(turn, :failed)   # nothing once the ask was settled;
  │     #   then @toolkit_suggestion.finish(turn): the stage lets the turn and its Pending go
  │     # Returns false at a STOP CHECK (stopped_before_model ends the turn canceled), else true
  │
  ├── generate(turn, max_iterations:, max_tool_output_chars:, pending_input:)
  │     # one EffectiveModel (after the hooks, which may switch the model): sync_kernel_client!, then
  │     #   turn.context = turn.context.with(settings: turn.prepared_settings with model_name,
  │     #   window_setting, llm_context (the session's, the model's/host's, else llm_context.strategy),
  │     #   price (hosts.<name>.models.<id>.price) and loads_tools, model_key/fallback_model_key (the
  │     #   memory overlay keys) and model_name (the gate's rules' models:), all frozen now),
  │     #   published by TurnState#replace_context
  │     # turn.limit = max_iterations or IterationLimit.for
  │     # backend(model).complete(messages: turn.messages, ..., pending_input: turn_drain(pending_input),
  │     #                         context: turn.context)
  │     # Returns LLM::ModelResult (text, conversation, canceled?, exhausted?, tool_activity,
  │     #                          context_status, empty_steps, empty_retries)
  │
  ├── publish_used_memories(session, on_event)    # :used_memories_updated when there are any
  │
  ├── complete_turn(turn, result)
  │     # end_turn(turn, "completed" | "canceled"): under the event lock the session gets the kept
  │     #   messages, goes IDLE, records last_turn (enqueued_id: the turn's input, from its origin;
  │     #   a continue turn's origin carries its offer turn's, ContinueOffer#run_continue_turn),
  │     #   and :turn_completed {result, turn_summary, display_pending} or :turn_canceled
  │     #   {cancellation_reason, cancelled_by, duration_ms} is emitted; before the replace,
  │     #   @verify_anchors.stamp_opening puts a Verify turn's `verify` and a completed Revise turn's
  │     #   `revises` (re-targeted to its stack's top) on the opening message, metadata never sent,
  │     #   @verify_anchors.record_verdict adds a completed Verify turn's verdict, the working set and
  │     #   @objectives_stage.announce(session) go out in the same step, and every end event carries
  │     #   `turn_id`, :turn_completed `verify` / `verdict` / `revises` when there are
  │     # then @objectives_stage.outgoing(turn, result) (not for a canceled or exhausted turn)
  │     # then the :after_turn hook (status, messages, present: the AnswerDisplay presenter,
  │     #   refs: the AnswerRefs adder)
  │     # store_answer_display (one replace of the answer: `display` and/or `display_refs`;
  │     #   :answer_display {display, refs: N} to the observers when a hook changed the answer or
  │     #   attached refs, or display: nil when the web was told to wait for it)
  │     # then the :session_end hook
  │
  ├── @turn_warmup.after(turn, result)
  │     # local llama.cpp on the native loop only: prefills the next turn's prompt while the user
  │     # reads (PromptWarmup; see prompt-caching.md, "The turn-end warm-up"). Never fails the turn.
  │
  └── ensure: release_turn(probe_cancel_before)
        # TurnState#finish! (turn flag off, controller, sink and steers cleared; the context kept as
        #   the last one, Engine#last_turn_context, with the last settings when it never got its own)
        # SteerCut#finished! (its GenerationPhase finished, its WaitingSteer cleared)
        # probe cancel swapped back
        # the context window cache dropped, so the next turn asks the server again
        # steers left logged as dropped, activity recorded, turn-scoped hooks cleared
        # then @context_judge.show_cards_after_turn (after the flag is released), then
        # @objectives_stage.finally(turn): a completed turn's proposals shown, any other's dropped
```

### Turn stages

A step that keeps state across the turn (its preparation, its end) is a collaborator under `lib/samagotchi/turn_stages/`, built
in `Engine#initialize` (before the plugins load) from constructor arguments, never reading the Engine's ivars, and
called by name from the skeleton above, next to the STOP CHECKs. Their input is the `Turn` (and its `TurnContext`);
their state is their own. The Engine's public methods forward to them (`warm_toolkit_suggestion!`,
`announce_objectives`, `propose_objective`, the private `judge_late_candidates`).

| Stage | Built with | Called | State |
|---|---|---|---|
| `TurnStages::ToolkitSuggestion` (ToolkitSuggest's ask: audit and on mode, one eligibility, a copied snapshot, SideJudgments' `:toolkit` kind) | `side_judgments`, `host_registry`, `toolkit_binding`, `tools`, `state_dir`, `recording`, `runs` | `start(turn)` before `refresh_profile!`; `settle(turn)` after `apply_staged_tools!` (on mode: waits up to System 1's timeout from its start, or a Stop, which wins over an answer already in and cuts the ask through `Pending#cancel_controller`; a pick ≥ threshold → `ToolkitBinding#suggest`); `abandon(turn, why)` at STOP CHECK A (`:canceled`) and in the ensure (`:failed`), then `finish(turn)` there; `warm!(session)` / `stop_warmup` (Worker start, `shutdown`) | the turn's `ToolkitSuggest::Pending` while it prepares (turn thread only; another turn's is never touched; dropped at `finish`), the warm-up thread |
| `TurnStages::ContextJudge` (the attached-context candidate judge: [attached-context.md](attached-context.md), [context.md](../context.md) "The judge") | `side_judgments`, `host_registry`, `state_dir`, `recording`, `session`, `messages`, `turn_running`, `show_card` | `start(turn)` after `settle`, before `apply_toolkit!` (owner turns only: `ContextCandidatesLog#look`, then unless `context.candidates.mode` is off the due asks on SideJudgments' `:context` kind); `late_candidates` (a plugin's late proposal); `show_cards_after_turn` from `run_turn`'s ensure, after `release_turn` | the cards an answer brought while a turn ran, under their mutex |
| `TurnStages::Objectives` (System 1's objectives audit, ObjectivesAudit; the view; the model's proposals: [objectives.md](objectives.md)) | `side_judgments`, `host_registry`, `state_dir`, `recording`, `runs`, `synchronize`, `announce`, `running`, `show_card` | `incoming(turn)` after the judge's `start`; `announce(session)` inside `end_turn`'s event step (and `Engine#announce_objectives` between turns); `outgoing(turn, result)` in `complete_turn`, after the end event and before `:after_turn`; `note(session, note)` (`add_context_note`); `propose(proposal)` (`Engine#propose_objective`); `finally(turn)` in `run_turn`'s ensure, after the judge's cards | the turn's proposals under their mutex (drained at `finally`), the last view announced, the audit |
| `TurnStages::Warmup` (the turn-end warm-up, PromptWarmup: [prompt-caching.md](prompt-caching.md), "The turn-end warm-up") | `prompt_warmup`, `kernel`, `turn_state`, `model_settings`, `model`, `system_prompt`, `reminders_due`, `next_turn_waiting` | `after(turn, result)` after `complete_turn` (reads `turn.context.settings`) | none (the PromptWarmup keeps its pin and thread) |
| `TurnStages::VerifyAnchors` (Verify and Revise anchors) | `state_dir` | `verified(session, anchor)` in `begin_turn`; `stamp_opening(messages, turn, outcome)` and `record_verdict(turn, outcome)` inside `end_turn`'s event step | none |

On a shared local System 1 host the judge's asks wait for the turn's end: started before `TurnStages::Warmup#after`, whose
warm-up waits for them, or from `run_turn`'s ensure (docs/context.md, The judge). See configuration.md (Toolkits) and
guardrails.md (System 1) for the suggestion.

### Error paths

```
StandardError in run_turn:
  → if turn.ended (it came from the after_turn/session_end hooks): logged as post_turn_error, re-raised
  → else: end_turn(turn, "failed", save: true) (a save that fails there is logged, turn_end_save_failed)
     # Both loops call LLM::FailedTurn.attach(e, conversation) before re-raising, so
     # failed_messages (TurnEndings) keeps the loop's partial conversation (tool iterations included),
     # else turn.messages, with TurnNote.failed(summary, continued: turn.continue) at the tail.
     # :turn_failed {error_class, message, duration_ms}; a provider error adds
     # error_kind, retryable, host and summary.
  → re-raised

Interrupt (Ctrl-C; a one-shot only: a worker traps INT, see the signal row below):
  → if turn.ended: re-raised only
  → turn.controller.cancel!(:ctrl_c)
  → end_turn(turn, "canceled"): ctrl_c_messages keeps the loop's conversation, else turn.messages
     # (it came before the loop), with TurnNote.cancelled(:ctrl_c) at the tail.
     # Both loops attach their conversation to the Interrupt as to a failure
     # (LLM::FailedTurn.attach), so the turn's finished iterations stay, as after a Stop,
     # and the cancel note names the tasks the turn started. One mid-tool is answered:
     # ToolResponse.run_batch gives every call left an interrupted result (the native
     # loop's batch entry joins them after the finished ones), so no call is kept without
     # its result. A half-streamed reply is not kept (a Stop keeps it, [interrupted]).
  → :turn_canceled {cancellation_reason: :ctrl_c, duration_ms}
  → re-raised (the caller decides whether to exit)

A Stop (Engine#cancel_current_turn!, e.g. the Bridge's POST cancel) or a hook's stop_turn:
  → not an error: the loop returns LLM::ModelResult(canceled: true, conversation: ...)
  → complete_turn keeps the loop's conversation (tool iterations included) with a
     TurnNote.cancelled note; a text streamed before the cancel stays, marked [interrupted]

A worker's TERM, HUP or INT (WorkerSignals, trapped by a spawned worker only):
  → a Stop with reason :signal (Worker#signalled, off the trap, retried until the loop leaves)
  → :turn_canceled {cancellation_reason: :signal}, saved by the Worker as after any turn;
     Worker#run returns :signal (:stopped with the stop marker), takes no new work
  → not ended within Worker::SIGNAL_GRACE (a turn that ended and runs its after_turn hooks gets
     SIGNAL_HARD_EXIT more, uncanceled): the session saved as it is, SignalException raised in the
     loop's thread, only while the loop runs (never into start, serve or the teardown, which runs whole)
  → the process ends SIGNAL_HARD_EXIT (10 s) after that at the latest (exit!); a signal after the
     loop left brings only that hard exit, and run_session_loop restores the default handlers
  → run_session_loop: exit 0, no discard; input queued behind the stopped turn wakes a new worker

The effective model doesn't resolve (a broken host config, HostRegistry#resolve raising):
  → the rescued readers give their fallback (SessionModelSettings#model_setting) and log effective_model_unresolved;
     a setting that fails on a resolved model gives its fallback and logs <setting>_unresolved
     (sampling, thinking, reasoning_history, steer_cut_after, llm_context, window, price, served,
     vision_adapter); served_probe_failed when asking the server for its served model fails;
     alias_note_failed, thinking_notice_failed likewise
  → WARN once per process for an (event, model, error class), DEBUG after (EffectiveModel::Unresolved)
  → session_state_snapshot never raises (its model fields are nil); a turn, stats_snapshot,
     chat_model? and system_prompt raise, as before

A session's toolkit doesn't resolve (an unknown kit name: a typo, a bundle's kit that isn't installed; a base that
doesn't resolve, a cycle), at a turn's start (ToolkitBinding#apply!):
  → that turn declares the full kit with the session's own added and removed tools on top (Toolkit#resolve's
     fallback); the saved toolkit stays as it is, so a reinstalled bundle gets it back
  → each warning (that fallback, a config.yml kit with a problem: Toolkit.kits) logged once per process as
     toolkit_unresolved (WARN), with a :guardrail_warning (label "toolkit") to the turn and the observers

Stopped before the model was asked (prepare_turn returned false):
  → stopped_before_model(turn) → end_turn(turn, "canceled")
  → nothing kept, :turn_canceled {cancellation_reason, cancelled_by, duration_ms}
  → LLM::ModelResult(text: "", canceled: true, cancellation_reason: reason)
```

**Degrading.** Work that has a fallback when it fails (a prompt section left out, an empty list from the Bridge) runs
in `Degrade.call(area, event, fallback:, rescue:) { … }` (`degrade.rb`): same rescue class and fallback as a bare rescue,
plus one WARN in the debug log per process for each `[area, event]` (DEBUG after; nothing on stderr). A bare `rescue`
whose body is only a literal (`nil`, `false`, `[]`, `{}`, `""`, `0`, or an array of only those: `[nil, nil]`) is flagged in lib by the `Samagotchi/SilentRescue`
cop; a silence that is right (a client gone, a routine probe, Log's own internals) carries `# degrade-ok: why`.

## The model↔tool loop

The Engine does not talk to models directly. `Engine#backend` picks the loop the effective model's host speaks:

```
Engine#backend → backend_for(effective_model)    # EffectiveModel.of(@host_registry, @model_binding.choice)
  → host entry chat? (an api in LLM::Adapters::BY_API: openai, anthropic): LLM::ChatLoop (one per Engine, built on first use)
  → else:                                                     LLM::NativeBackend wrapping the Engine's KernelLoop
```

Both implement the `LLM::ModelBackend` contract (`#complete(messages:, max_iterations:, on_stream_event:,
cancel_controller:, model_name:, max_tool_output_chars:, pending_input:, reasoning_since:)`; `reasoning_since:` is
where the run a step-limit Continue resumes started, the Engine's `resume_from`). `NativeBackend#complete` only calls
`KernelLoop#run` with the same arguments. `ChatLoop` runs its own loop but is built with the same KernelLoop,
whose tools, hooks, gate and dispatch it uses.

### KernelLoop (the native, raw-prompt loop)

Runs models whose server takes a raw prompt (llama.cpp `/completion`). chi formats the prompt itself, per model profile (Gemma 4, Qwen 3.6), and
parses tool calls out of the generated text.

```
KernelLoop#run(messages, max_iterations:, on_stream_event:, cancel_controller:,
               model_name:, max_tool_output_chars:, pending_input:, reasoning_since:)
  │
  │ turn = start_turn(...)   # turn.conversation = prepare_conversation(messages): a copy,
  │                          # old model messages without their thought blocks, but a resumed
  │                          # run's (a step-limit Continue's reasoning_since:, #thought_floor:
  │                          # all of them, a steer merged mid-run included; only a user entry
  │                          # added after the run's last reply starts them past itself)
  │ each iteration:
  │ 1. Queued input (user lines, plugin steers) goes in at the boundary (Steer.inject!)
  │ 2. Format the conversation as prompt text (Prompt.format_with_images); a context
  │    guidance line goes on the tail when the window fills past a threshold
  │ 3. Fire :before_generation, then stream one generation (:generation_started, :generation_chunk, :generation_completed)
  │ 4. Parse tool calls (ToolCallParser for the profile):
  │    → Gemma 4:  <|tool_call>call:NAME{params}<tool_call|>
  │    → Qwen 3.6: <tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>
  │    A Qwen block left open is asked to be finished (QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_LIMIT = 2)
  │ 5. Calls: dispatch_calls → ToolResponse.run_batch; one tool_response entry for the batch
  │ 6. No calls: an answer, an empty answer to retry (EmptyAnswerRetry), or queued input to answer
  │
  └──→ LLM::ModelResult(text, conversation, exhausted, canceled, tool_activity, ...)
```

`turn.conversation` is the loop's own copy, not the Engine's `turn.messages`. A failure attaches it to the error
(`LLM::FailedTurn.attach`), so `Engine#failed_messages` can keep it; an Interrupt (Ctrl-C) too, for
`Engine#ctrl_c_messages` (see Error paths). Both are `TurnEndings`', with the other pure builders of a turn's end
(`kept_messages`, `failed_event`, `turn_summary`, `stop_facts`); the Engine forwards to it and keeps `end_turn`,
`complete_turn`, `store_answer_display` and `record_last_turn`.

### ChatLoop (the chat APIs)

Runs hosts whose api has a chat adapter (`LLM::Adapters::BY_API`): `api: openai` on `LLM::OpenAIChat` (remote
providers such as OpenRouter, Claude among others, and any OpenAI-compatible chat server) and `api: anthropic` on
`LLM::AnthropicMessages` (Anthropic's Messages API; [anthropic.md](anthropic.md)). The Engine sets the adapter per
turn for the effective model's host (`HostRegistry#adapter_for`). The model gets the tools as JSON schemas and returns
structured tool calls.

```
ChatLoop#complete(messages:, max_iterations:, on_stream_event:, cancel_controller:,
                  model_name:, max_tool_output_chars:, pending_input:, reasoning_since:)
  │
  │ conversation = Array(messages).map(&:dup)   # a shallow copy of each message
  │ Run.new(self, conversation, on_stream_event, cancel_controller, model_name, pending_input,
  │         start: reasoning_since)
  │    .call(max_iterations: max_iterations || 1, cap: KernelLoop.resolve_output_char_cap(max_tool_output_chars))
  │
  └──→ LLM::ModelResult(text, conversation, exhausted, canceled, tool_activity, ...)
```

The differences from the native loop:

- The tools go in each request's `tools` field (`tool_definitions(conversation, model:)`, the turn's
  `ToolSurface#schemas`), not in the system prompt.
  On an adapter that loads tools (`#loads_tools?`: `AnthropicMessages`), the tools the session reaches but doesn't
  declare follow, `defer_loading: true` (`ToolSurface#deferred_for`; anthropic.md, "Deferred tools"); the Run keeps the
  last request's deferred names and logs a call of one (`tool_direct_deferred`).
- The conversation is converted to the OpenAI wire format (`wire_messages`), for every chat host;
  `AnthropicMessages` translates that again into Messages' `system` and content blocks (`LLM::AnthropicWire`).
- The first system message carries `cache_split:` (from `SystemPrompt#stable_length`, which the Engine passes in
  as `stable_length:`), where the prompt's stable part ends. The adapter puts the first cache breakpoint there:
  `OpenAIChat` for a Claude model on a remote host (`LLM::PromptCache.mark`), `AnthropicMessages` on every chat
  request unless its dialect has no breakpoints or the host refused `cache_control` (`AnthropicWire.translate`,
  `Dialect#cache_breakpoints`); see prompt-caching.md and anthropic.md.
- Each call's result is its own tool message, paired by `tool_call_id`.
- A model turn's saved reasoning (`thinking:`) goes back as `reasoning_content` per the turn's
  `TurnSettings#reasoning_history` (`ReasoningHistory.resolve`, the session's own level first:
  `Session#reasoning_history`, `/reasoning-history`): `all` on every model message, `turn` past
  `ChatLoop#reasoning_boundary`: the Run's `@reasoning_start`, fixed once per Run by `ReasoningHistory.run_start`
  (the rule `KernelLoop#start_turn` uses too) from the Run's start (the conversation length at `#complete`), so a
  continue turn (reminder, context wake, delegate report wake) replays nothing of the run before. Entries the Run
  merges (a person's line, a plugin's steer, a Continue's text) don't move it, as natively (nothing re-sanitizes
  within a run): the request after a steer extends the one before. A step-limit Continue's Run starts where the run
  it resumes did: `#complete`'s `reasoning_since:` (the Engine's `resume_from`, checked against the messages' length
  in `Engine#resumed_run_start`), past a user entry added after that run's last reply (a `!cmd`'s output). Without
  `since:` (`#reasoning_chars` from outside a Run) the boundary is the last query (a `role: "user"` or `turn_start`
  entry). `Run#prompt_chars` counts it (`#reasoning_chars`).
- On an adapter that sends its blocks back (`#replays_content?`: `AnthropicMessages`), a model turn's saved blocks
  (`anthropic_content`, the response's `provider_content`, saved by `Run#with_thinking`) go back verbatim, thinking
  blocks with their signatures (`#replay_blocks`): not for an interrupted entry or one with an unpaired call, and
  without the thinking blocks before the reasoning boundary (the last model entry with tool calls keeps them).
  `#reasoning_history` floors `drop` at `turn` there, since Messages needs the running run's thinking blocks.
- A 400 about reasoning (`BadRequest#reasoning_refused?`) for a request that sent reasoning back asks the step again
  without it (not on a replaying adapter, where the body would be the same); when that goes through,
  `#reasoning_history_refused!` marks the model (worker lifetime; the loop's `LLM::RefusalMemo`, as for the thinking
  and sampling refusals) and
  `:reasoning_history_refused` goes out. When it is refused too, the thinking-fields fallback (`#thinking_refused!`,
  `:thinking_refused`) runs on it, still without reasoning. Up to three requests per step. A 400 about a thinking
  block's signature (`BadRequest#thinking_signature?`) or a refused binding control
  (`#thinking_binding_unsupported?`) is not one: `ProviderErrors` leaves `reasoning_refused?` false for them, so one
  bad block never turns reasoning off for the model.

### Shared: ToolResponse (per batch) and ToolRunner (per call)

Both loops run a batch of calls the same way:

```
One iteration with tool calls:
  KernelLoop#dispatch_calls / ChatLoop::Run#dispatch
    → ToolResponse.run_batch(runner, calls, context:, iteration:, emit:, on_stream_event:, cap:)
       # context: the turn's TurnContext (the native run's, ChatLoop::Run's); chat passes a block,
       # called with each run as it finishes
      → :tool_dispatch_started {iteration, call_count}
      → for each call: ToolRunner#run(call, context:, iteration:, call_index:, call_count:,
                                      on_stream_event:, max_tool_output_chars:)
          → under TurnSettings#loads_tools, a direct call of a source tool's acts_as (mcp_fs_read) is wrapped
            into the call_tool call it stands for (Registry::Index#wrap, ToolIndex#wrap)
          → first, the call's entry unwraps it (Registry::Entry#unwrap: a call_tool of chi/<name>, a built-in or
            a plugin tool, becomes that tool's call with via: "call_tool", ToolIndex#unwrap); the rest sees the
            real call
          → a tool the session's toolkit leaves out (ToolSurface#left_out; with via:, one the surface's index_only
            doesn't hold) skips the gate: no hooks, no card; KernelLoop#dispatch answers it (the call_tool route for a
            reachable tool, the not-loaded error for a removed one). Under the surface's loads_tools a reachable
            built-in or plugin tool called by its own name is no such call: it runs through the gate, and KernelLoop#dispatch
            takes it (ToolSurface#entry_for)
          → Guardrails::Gate#evaluate(call, context:) (the before_tool_call hooks, then the core checks)
          → :tool_call_started
          → an ask verdict: Gate#settle_ask(verdict, context:) (asks the user, records waited_ms)
          → KernelLoop#dispatch_tool_call(call, context), or the denial text
          → :tool_call_completed, then the :after_tool_call hook
          → returns a ToolRun value object with output, capped_output, truncated, activity, images, shown_params,
            shown_label, refs, diff and output_file; fields a call doesn't produce are nil
      → :tool_dispatch_completed {iteration, call_count}
    → native: ToolResponse.joined(runs, ids:), one entry with the capped outputs
      chat:   ToolResponse.single(run, tool_call_id:, ids:) as each call finishes (the block), with the
              capped output
      ids: ToolIds.next_ids, chi's own ids for the outputs ("t41"), saved on the entry as tool_ids
      (one per call of the batch for native, one for chat); LLM context edits name outputs by them
```

**ToolRunner** (`ToolRunner#run`): what it reads of the turn is the `context:` it is given (a `TurnContext`): the
session's folders (`cwd`, `session_dir`), the settings' vision, LLM context layers and `loads_tools`, the
participant's author and mode; the kernel gives it only what lives as long as the Engine (tools, hooks, the gate).
- Unwraps a call_tool of a built-in first (`Registry::Entry#unwrap`), so `original`, the params and the label
  are the built-in's and no "ran as:" line follows.
- Runs the gate first, so `:tool_call_started` shows the call that will run (a before_tool_call hook may
  replace it; known-names corrects a misspelled name this way, and the model gets one line saying what ran).
- Emits `:tool_call_started` {iteration, call_count, call_index, tool, call, params, label (plugin tools),
  title, called_as, via, view, ref, refs}. The row fields (title, called_as, via, view, ref) come from `ToolRowFields.for`, which the
  reload (`MessageParts#tool_part`, after `BuiltinCalls.unwrap_saved`) calls too. `ToolRowFields::ACTIVITY_KEYS` (title, called_as, via) travel
  inside `activity` on the completed event; `EVENT_KEYS` (view, ref, refs) go top-level on both events.
  `Bridge::TurnAccumulator` (snapshot and replay) and the web (`activity.js` `ACTIVITY_FIELDS` /
  `EVENT_FIELDS`) copy them by these lists, so a new row field is added there. `ref` is `FileRef.for` (a
  read/write/edit's file against the cwd, `{kind: "file", path, line?, end_line?}`); the web opens it in the editor
  that `Web::Editor` (web.editor) names, for a local viewer only (`App#viewer_capabilities`).
  `refs` is a plugin tool's row refs: its registry entry's `refs` (chi.tool's `refs:` lambda, `ToolSpec#per_call`), run
  once per call by `RowRefs.for` (never raises: a raise or a non-list gives none, `tool_refs_failed`; each entry a
  `Ref`, a bad one dropped, `tool_refs_rejected`; a relative file resolved against the session's folder
  (`TurnContext#cwd`, else the process's), one outside it (its spelling or its real path) dropped, a kept one
  stored under the real path; at most `RowRefs::MAX_REFS` and `MAX_BYTES`). `ToolRowFields.for` can't build it (no plugins on a reload), so the run carries it
  as `refs:`, saved with the result as `tool_refs` (`ToolResponse::SAVED_KEYS`, never sent), and
  `MessageParts#tool_part` reads it back through `RowRefs.for_display` (checked again). The page binds them to the
  row's title (`refs.js bindRowRefs`, from `turn_block.js` live and on a reload): the first ref on it, the rest in its
  menu.
- Settles an ask verdict after `:tool_call_started`, so a UI shows the tool line and then the approval.
- Dispatches through `KernelLoop#dispatch_tool_call`, or writes the denial text. `KernelLoop#dispatch` runs the call
  on the entry `ToolSurface#entry_for` gives; one without an entry gets `ToolSurface#unknown_tool_error` ("Error: no
  such tool ...", never repeating the wrong name).
- For edit and write: diffs the file before and after, and refreshes a memory's index line
  (`MemoryBundle::IndexSync`).
- Attaches returned images, at most `MAX_IMAGES_PER_RESULT` (4) per result.
- Scrubs bytes that aren't UTF-8, and caps the output at `max_tool_output_chars` (a `memory_read`'s is `memory.read_max_chars`, 0: none, with an overflow guard at half a known window) by the tool's `ToolOutputCut`
  policy: `read` and most tools are cut to their head and end with `[cut: N of M chars; read it in parts]` (N
  kept of M, the whole within the cap unless the cap is shorter than that line); an `execute` result keeps a head
  and a long tail with a gap line between them, its whole output saved in `sessions/<id>/tool_output/`
  (`ToolOutputFiles`, in the turn's `TurnContext#session_dir`). See
  [Tool output guardrails](tool-output-limits.md#the-runners-cut-max_tool_output_chars). The model (both loops), the
  event and the after_tool_call hook get that text.
- Emits `:tool_call_completed` {iteration, call_count, call_index, tool, output, output_truncated, output_file,
  activity, images, diff, waited_ms, view, ref, refs}, then fires `:after_tool_call` {iteration, tool, output,
  status, call, elapsed_ms, result}.
  `output_file` (the saved whole output) is also on the run hash; the session doesn't keep it (the cut text names it).
- The activity's status (`ToolActivity#tool_activity_status`; a call the gate denied is `blocked`, set by
  `ToolRunner#denied`): `stopped` for a call the turn's Stop (or a signal to chi, or the session's stop) left
  unrun (`Tools::Execute::NOT_RUN_ON_STOP`, `NOT_RUN`) or an execute it killed (`STOPPED_BY_USER`, `STOPPED_BY`),
  and for a `task_wait` whose header (before `output_tail:`) says `wait_result: canceled` or `status: stopped`;
  `ok` for an execute handed over as a task (`#handed_over?`: its output tail may hold any `exit: N`); `error` for
  any other `Error:` result, for a `task_wait` whose header says `status: failed`, and for an execute that exited
  non-zero (a numberless `exit:` line, killed by a signal, counts), except a grep-family search that found nothing
  (`ToolActivity.no_match?`:
  exit 1, no stderr block, the last step is grep/egrep/fgrep/rg/ag/pgrep, no `&&` after a step that can fail
  silently or sends output to /dev/null, no background `&`, no earlier exit/return or `set -e`; when unsure,
  not a no-match). That one stays `ok` with `no_match: true` on the activity, which SessionMetrics keeps on the tool
  record and the Bridge's TurnAccumulator on the part, for the web row's "no match" word. The model's text is
  unchanged.

A denied call gets denial text in place of its output; the rest of the batch still runs. After a hook's
`stop_turn`, the gate denies every remaining call of the batch.

**ToolSurface** (`lib/samagotchi/tools/tool_surface.rb`, `Tools::ToolSurface`): the turn's tools as one frozen
value, built once in `Engine#generate` (`ToolSurface.for(registry, layers:, loads_tools:)`, the settings' LLM context
layers and the host's `loads_tools` known there) into `TurnContext#surface`. The Registry is its only input (its
lists `entries`, `reachable_names`, `left_out_names`, `removed_names`, `stranded_names`, read under the Registry's
toolkit or a `toolkit:` given). It holds `declared` (the entries the request declares, in prompt order), `index_only`
(left out, reached by `call_tool`), `left_out` (`{name => :indexed | :user_only}`), `removed`, `stranded`,
`registered`, `toolkit`, `reaching_kit`, `index`, `layers` and `loads_tools`, and answers `entry_for(call)` (a `via:` call only from `index_only`; a direct one from
`declared`, or `index_only` under `loads_tools`), `unknown_tool_error(name, via:)`, `schemas` and
`deferred_for(conversation)` (`Tools::DeferredTools.list` over the surface; the index's source tools are asked per
request, so a late MCP server joins mid-turn as before). Its readers: `KernelLoop#dispatch`,
`ChatLoop#tool_definitions` / `#deferred_tools` (whether to append the deferred ones is still the adapter's
`#loads_tools?`, asked per request: a refusal turns it off mid-turn), `ToolRunner`'s unwrap, wrap, left-out and
group-refusal checks, and the tool index: `find_tools`' and `call_tool`'s handlers take the surface from their
`KernelLoop::ToolContext#surface`, and the call tool's unwrap and the index's `deferrable` / `wrap` / `unreached`
are given the runner's or the deferred list's (its `chi` group is the surface's `index_only`). A change while the turn
runs (`/toolkit`, a staged `chi.replace_tools`, a direct `Registry#register`) shapes the next turn's declared,
searched and dispatched tools only. A context without one (a bare kernel or loop, a spec) computes one on read
(`ToolSurface.of(context, registry)`); nothing caches or invalidates it.

Readers outside a turn compute one on read from the Registry (`ToolSurface.for`): the system prompt, one per build
under the build's layers in `turn_messages`, before `generate` knows `loads_tools` (`SystemPrompt::Built#surface`;
spec/engine_tool_surface_spec.rb checks it equals generate's but for `loads_tools`); `ToolkitBinding#explained`
(`/toolkit`, the snapshot, the plugin host's `declared_tools`), under the toolkit it explains; `#warn_stranded`;
the toolkit suggestion's logged tool lists (what `chi toolkit report` grades), under full; and the tool index's
callers without a turn (`#declare`, `#refresh!`, a rule's `call_targets`, the row's `call_preview`,
`ctx.load_tools`' `#deferred_name`).

## State management

### TurnState (cross-thread)

One object, guarded by a `Monitor`, that the turn thread writes (`begin_turn`, `release_turn`) and other threads
read: the idle scheduler, the Bridge's request threads, plugin threads, the UIs.

```
TurnState
  ├── running?
  ├── context           (the running turn's TurnContext; nil between turns)
  ├── last_context      (the last finished turn's, kept while the next one runs)
  ├── controller        (the running turn's CancellationController)
  ├── thread, ended     (the turn's own thread; its end event is out: post-turn work)
  ├── sink              (the turn's on_event)
  ├── steers            (plugin steers for the running turn's next boundary)
  ├── carried_steers    (for the next turn that begins)
  └── activity clock    (last_activity_at, activity_seq)
```

- `begin!(context:, controller:, sink:)`: running, with the turn's context, controller and sink (and the calling
  thread, the turn's own), in one step; carried steers become steers. `Engine#begin_turn` builds the context whole
  before it (GuardrailWiring#begin_turn's mode and git included), so no reader sees a running turn with the last
  turn's author.
- `replace_context(context)`: the turn thread's new context for its running turn (`generate`'s settings), one
  assignment of a frozen value; refused from another thread or for another turn's id.
- `ended!`: the turn's end is decided (`end_turn`, next to `turn.ended`): its after_turn / session_end hooks run
  after it and before `finish!`.
- `own_controller(handler:)`: the controller for work done for the turn itself, which a plugin's `ctx.http` call
  without `cancel:` stops with (`Plugin::Host#cancel_controller`, `Engine#plugin_cancel_controller`): the turn's, on
  its thread or inside a plugin handler, until `ended!`; nil elsewhere (an anytime command, a service, a plugin's
  own thread) and outside a turn. An init task's own controller wins inside one.
- `finish!`: not running, context, controller, thread and sink cleared, the context kept as `last_context` (with the
  last settings when the turn never reached `generate`); returns the steers never taken (logged as dropped).
- `steer(text, source:)`: queues a steer for the running turn (false with no turn).
- `steer_next_turn(text, source:)`: queues a steer for the next turn that begins.

The lock is a leaf: nothing is called out while it is held.

**Reading the turn from another thread.** A thread off the turn (a Bridge request, an anytime command, a plugin's
thread, a hook fired by one) reads the running turn only through `Engine#turn_context` (`TurnState#context`, nil
between turns) and `Engine#last_turn_context`, one read each, never through the kernel, `GuardrailWiring` or an
Engine ivar. The readers that do: `Engine#turn_author` (`ctx.turn_author`, the hooks' `author:`, the judgments'
`participant:`, `ObjectivesCheck`), `#side_author` (the recap's: the last turn's), `EventFanout#working_set_llm_context`
(`/working-set`'s list: the running turn's settings, the last turn's until it has its own) and
`#live_conversation` (nil unless the loop's `LLMContextForget::Turn#turn_id` is the running turn's). The turn's own
code takes the context as an argument (the tool path, `guard_participant_spend`, `TurnStages::Warmup#after`'s
`turn.context.settings`); cancel stays `TurnState#controller` (a Stop never reads `context.controller` off the
turn). `spec/turn_context_readers_spec.rb` reads each from a thread the moment a turn is published.

### EffectiveModel (a snapshot per read)

`EffectiveModel.of(registry, choice)` resolves the model once (`HostRegistry#resolve`: host, client, the id
sent) with its lookup names, and reads each setting from them (sampling, thinking, reasoning history, steer cut,
LLM context, window, price, served model, vision, profile). It is built per read and never kept: config.yml is
read live, a model listing can move a bare id to another host, and another process's saved model lists change
what a resolve gives, all without a `/model`. Frozen, so any thread may hold one.

- The Engine's readers take one (`Engine#effective_model`); those whose fallback always covered the resolve go
  through `SessionModelSettings#model_setting` (`session_model_settings.rb`: the Engine forwards its readers of the session's settings there). A turn takes one in `turn_settings` (before the hooks) and one in `generate` (after
  them); `system_prompt`, `steer_cut_after` (at `:turn_started`) and the turn-end warm-up take their own;
  `stats_snapshot` and `session_state_snapshot` take one each (the latter nil-tolerant; both `EngineSnapshots`',
  `engine_snapshots.rb`, which the Engine forwards to).
- Never resolved (they hold on a broken resolve): `effective_model_ref`, `bare_model_name`,
  `guardrail_model_name`, `sync_model_key!`, `served_model(probe: false)` (`HostRegistry#model_ref`/`#bare_name`).
- Readers on other threads: the Bridge (`/state`, `/stats`, the SSE reset, a steer's cut wait), the worker's
  command thread, the recap thread and plugin threads (`session_model_recap_target`).
- `ModelChoice` (`ModelBinding#choice`) holds the name and the typed name as one value, so a reader on another
  thread never pairs one model's name with another's typed name.
- `EffectiveModel.of_session` builds a saved session's (no worker): `Web::App`, `LLMContextStrategy.for_session`.

`SessionSetting` names the four per-session settings (llm_context, thinking, reasoning_history, toolkit): the
session's own value, the commands that move each chip, its chip from an EffectiveModel or from the Engine's
readers, a saved session's chip, and how the web takes a worker snapshot's. The session state, `/stats` (no
toolkit), a `:command_ran` and the web's session JSON list them from it.

### ModelBinding (the choice and its profile)

`ModelBinding` (`model_binding.rb`) holds the session's model choice, the profile given to `Engine.new` (until a
switch), the prompt profile resolved for the choice (kept as a `[choice, resolution]` pair) and the memory overlay
keys (`#sync_model_key!`), under one mutex; it is ToolkitBinding's counterpart, and the Engine forwards
`profile_resolution`, `refresh_profile!`, `store_profile`, `apply_profile`, `resolve_profile`, `sync_model_key!`
and `model_key` to it.

- `#switch!` (`Engine#switch_model!`'s swap) is one assignment under the mutex: a reader on another thread sees
  the old pair or the new one. It drops the given profile and the kept resolution.
- `#store_profile` keeps and applies a resolution only while the choice is still the one it was resolved for,
  by identity (`equal?`, not `==`): a `/stats` probing on a Bridge thread while `/model` runs keeps nothing.
- `#apply_profile` runs under the mutex: the system prompts built for another profile are dropped, then
  `KernelLoop#use_profile!`. Nothing else takes the mutex.

### ThinkingNotices

What a turn's thinking level leads to, said once per session and host (`thinking_notices.rb`): an effort the
host can't do, off the model didn't honour, a host refusing the thinking fields or the reasoning sent back. It
keeps the turn's `[level, ModelTarget]` and whether the generation thought; `turn_settings` and the stream handler
call it. Turn thread only.

### Turn and TurnContext

One source of truth: the `TurnContext` holds what the tool path reads of a turn, and `Engine::Turn` keeps only
its lifecycle state, reading the rest from its context (`turn.id`, `turn.session`, `turn.origin`,
`turn.controller` are the context's). The KernelLoop has its own `Turn` struct, a run's.

```ruby
TurnContext = Data.define(:id, :session, :origin, :author, :participant_mode, :participant, :controller, :cwd,
                          :session_dir, :state_dir, :git, :settings, :model_key, :fallback_model_key, :model_name,
                          :surface)   # frozen; TurnContext.none for a bare kernel, a spec, the bundle test kit
Turn = Struct.new(:context, :prompt, :continue, :on_event, :started_at, :messages, :ended, :prepared_settings,
                  :limit, :resumed, :resume_from, :wall, :verify, :revises, :outcome) do
  def resumed? = resumed ? true : false                           # a step-limit Continue
  def tag(event) = origin.empty? ? event : event.merge(origin: origin.to_h)   # boundary events carry the origin
  def elapsed = ...                                               # seconds since started_at
end
```

- `TurnContext` is built in `begin_turn` (`new_turn_context`) and published by `TurnState#begin!`; `settings` (the
  `LLM::TurnSettings` the requests send), `model_key`/`fallback_model_key` (memory overlays) and `model_name` (the
  gate's rules' `models:`) are nil until `generate` sets them, after the `before_turn` hook that may switch the
  model (`turn.prepared_settings`, computed before the hooks, give vision, sampling and thinking: a hook's switch
  gets the old model's, as before). `surface` (the turn's `Tools::ToolSurface`, see "Shared: ToolResponse (per
  batch) and ToolRunner (per call)") is nil until `generate` builds it with the settings.
- The live bits are objects it holds, not copies: `session` (its working-set pins are read at call time),
  `controller` (cancel state), `git` (`Guardrails::GitInfo`, the per-turn git cache).
- Down the tool path it is an argument: `ModelBackend#complete(context:)` → `KernelLoop#run(context:)` (the run's
  own copy takes the run's model name; `KernelLoop#context` / `#turn_settings` read it on the turn thread, the last
  run's after it) or `ChatLoop#complete(context:)` (`ChatLoop#turn_context`, its Run's) → `ToolResponse.run_batch` →
  `ToolRunner#run` → `Guardrails::Gate#evaluate` / `#settle_ask` and `KernelLoop#dispatch_tool_call(call, context)` →
  the handler's `KernelLoop::ToolContext.new(kernel, context)` (`participant_mode`, `model_key`, `muted_memory_read`,
  `forget_outputs`). The generation guard gets it too (`KernelLoop::Services#generation_guard`, `guard_participant_spend`).
- After a chat-loop turn the kernel's own `context` / `turn_settings` still hold the last native run's (a chat run
  never sets them), and `ChatLoop#turn_context` keeps its last run's: both are the turn thread's working copies, so
  a reader outside the turn uses `Engine#turn_context` / `#last_turn_context` instead.
- A spec runs a loop, a runner or a gate outside an Engine turn with `run_context(settings: …)` (spec/support/test_kernel.rb).
- What lasts the Engine's life is not in it: `KernelLoop::Services` (hooks, tools, reminder store, mutes, the
  question handler, peers, the gate, warm-up, the generation guard), one frozen value the kernel gets at
  `KernelLoop.new(services:)` or `#attach` (a spec's kernel: `attach_services(kernel, tools: …)`). No turn field
  goes in Services, no Engine-lifetime one in TurnContext.

- `messages` is what the Engine sends: system head, history, reminders, the prompt. The loop works on its own
  copy; the Engine keeps `result.conversation` after a normal end or a Stop, and the error's partial
  conversation after a failure.
- `controller` is the turn's `CancellationController`, an in-process signal. Another process stops a worker's
  turn through the Bridge (`POST cancel` → `Engine#cancel_current_turn!`).
- `on_event` is the turn's sink.
- `ended` is set by `end_turn`.
- The live conversation: both loops register the array they append to on the kernel
  (`KernelLoop#llm_context_turn`, `LLMContextForget::Turn#conversation`, tagged with the run's `turn_id`;
  `KernelLoop#start_turn`, `ChatLoop::Run#initialize`). `Engine#live_conversation` returns it while a turn runs and
  only once its loop registered it (nil otherwise: the kernel never clears it, and the turn id tells the last turn's
  from this one's). A worker's drain (`Worker#pending_input_drain`, on the turn's thread at every iteration
  boundary) copies it, with the lines that boundary merges, into `Session#turn_checkpoint` (`TurnCheckpoint`):
  every save while the turn runs writes that copy with an `interrupted_turn` mark instead of the session's
  messages, written at the first boundary and then at most every 10 s, so a killed worker loses at most that much
  of its turn. `session.messages` itself is untouched until the turn ends. When the checkpoint writes, the worker
  also calls `Engine#checkpoint_metrics` (`SessionMetrics#persist(running_turn: true)`): `analytics.json` gets the
  running turn's record so far as a killed turn's (canceled, `worker_stopped`), which the next worker loads; the
  turn's end writes over it.

### SteerCut, GenerationPhase and WaitingSteer

The Engine holds one `SteerCut` (`@steer_cut`), which owns a `GenerationPhase` and a `WaitingSteer`: the Bridge and
the TUI ask it (`Engine#cut_for_steer`, `#input_epoch`, `#generation_snapshot`), the Engine's stream handler feeds it
(`SteerCut#observe`), a drain that took input calls `#delivered!`, and `release_turn` calls `#finished!`.

`GenerationPhase` is what the running generation streams, fed through `SteerCut#observe`: whether a steer sent as a
cut (delivery `cut`: `/cut TEXT`, `chi send --cut`) may cut it. `SteerCut#cut_for_steer` answers `:now`, `:waits` or `:off`; the
Bridge acks it as `cut`.
A generation is cuttable while it has streamed only thinking, is still thinking, and has thought for at least
the model's cut wait (`SteerCutAfter.resolve`: `steer_cut_after` per models:/hosts: entry, else `steer.cut_after`) seconds (`cuttable?(min_age)`). It has `started!`, `chunk!`, `retrying!` and `finished!`.
`snapshot` is the running generation as `GenerationPhase::Snapshot` `{thinking_only, age}` (nil with none running;
`age`: its thinking's seconds, nil before any): `SteerCut#generation_snapshot` → `Engine#generation_snapshot`, which
`Bridge#snapshot` merges into `current_turn.generation`, so a web page joining mid-generation can clock its delivery
line and tell whether "cut in now" can land.

### WaitingSteer

A message that may cut the generation but came too early (the generation hadn't been thinking long enough). It
waits until the thinking passes the model's cut wait (`SteerCut#observe` rechecks it on each thinking chunk), until a
drain hands the message to the model at a boundary, or until the turn ends (`SteerCut#finished!` clears it).

## Events

### The turn's sink (`on_event`) and the observers

`Engine#emit_event` (`EventFanout#emit_event`, `event_fanout.rb`, which also builds the loops' stream handler and
emits the working set) sends each turn event to the turn's sink (`on_event`, a one-shot's renderer) and then to the
persistent observers (`Engine#subscribe`), which get a copy with a monotonic `event_seq`. The observers are the
metrics, the debug log, the thinking tails, and in a worker the Bridge, which streams to the web and the attached
TUI. Errors in the sink or an observer are caught; they never break the turn.

`Engine#announce` puts an event that belongs to no turn (`ANNOUNCEABLE_EVENTS`: `turn_enqueued`, `turn_dequeued`
(a queued message taken back before it ran, `{enqueued_id, client_id}`: the remover's), `card`,
`hook_notice`, `guardrail_warning`, `plugin_init_started`, `participants_changed` (`{participants, joined, left}`:
who is in the review now and who was invited, revoked or expired since the worker last looked; `ParticipantsWatch`,
[participants](participants.md#the-owners-terminal)), and more) to the observers only. `:side_usage`
(`{kind, side}`: a side request's usage, the recap's, `/btw`'s or `ask_model`'s, and the session's side sums) goes
to the observers the same way from `Engine#note_side_usage` (any thread), without being announceable.

Turn events (the main ones; `Events` in `events.rb` keeps the shared sets):

| Event | When | Payload |
|---|---|---|
| `:turn_started` | `prepare_turn` | `{session_id, prompt, turn_id, at, continue?, resumed?, images?, cut_after}` (`resumed`: a step-limit Continue; `at`: the turn's wall time, its prompt's stamp) |
| `:reminder_injected` | due reminders went into the turn | `{reminders, at}` (`at`: the turn's wall time, the reminder message's stamp) |
| `:context_status` | every request (unless `context.status` is off), the current estimate before it; and outside any turn after `/model` (or when a session is loaded on another model than its last turn ran on), to the observers only (`Engine#announce_switched_context!`) | `{iteration, status, usage, bucket, source}`; the switch's form has no `iteration`: `{usage, bucket, context_window_tokens, context_window_source}`, with `usage.source: "switch"`, and `usage` nil when the new window doesn't resolve (internals/context-telemetry.md) |
| `:generation_started` | a request begins | `{iteration, context_window_tokens, context_window_source, price, model_ref}` (`price`: the turn's `ModelPrice#to_h`, nil without one; `model_ref`: the turn's model, asked `host:model`, added by the Engine's stream handler from the model `#generate` resolved after the `before_turn` hooks, so a hook's switch is the one named; native adds `profile`, `profile_source`) |
| `:generation_chunk` | each streamed chunk | `{iteration, content, text, thinking, payload, tool_call?}` (SSE clients get the Bridge's projection instead: `{iteration, text, thinking, tool_call?, counts?}`, architecture.md) |
| `:generation_retrying` | the transport retries the request, or the chat loop asks again for a step whose stream dropped mid-answer (`restarted: true`: what the step streamed is void, and the web's live step, the TUI's activity line, the Bridge's TurnAccumulator and the stream hooks' watch start it over) | `{iteration, attempt, max_retries, next_delay, error_class, error_message, status, restarted?}` |
| `:generation_completed` | a generation ended, or was cut | `{iteration, content_length, thinking_chars, served_model, requested_model, finish_reason, ...}`; a cut adds `stopped_by`, `stop_reason`; the Engine adds `speed`, `tokens`, `model_segments` |
| `:generation_cancelled` | the turn was cancelled mid-loop | `{iteration, reason, stopped_by}` |
| `:thinking_dropped` | the chat loop settled a preserved-thinking recovery: the adapter dropped replayed thinking blocks and they left the history (`ChatLoop#settle_dropped_thinking!`; the step's `:generation_completed` carries `thinking_dropped`; internals/anthropic.md) | `{iteration, count, how}` (`how`: `:drop_block` or `:strip`) |
| `:empty_answer_retry` | an empty, cut or malformed answer is asked again | `{iteration, attempt, of, finish_reason, thinking_chars, stopped_by?, malformed?}` |
| `:steer_cut` | a steer cut the generation | `{iteration, source}` |
| `:llm_context_edited` | the apply rule applied a batch of LLM context edits (a request, a forget_outputs call, turn end; never the warm-up) | `{moment, why, freed_tokens, tail_tokens, staged, text, groups}` (`LLMContextNotice`) |
| `:thinking_refused` / `:reasoning_history_refused` | the chat loop asked a step again without the thinking fields / the reasoning sent back; the Engine logs it and makes a once-per-session-and-host `:hook_notice` of it, the event itself never reaches the sink | `{iteration, model, level, detail}` |
| `:pending_input_merged` | queued input joined the conversation | `{iteration, count, content, steers?, answer}` |
| `:tool_dispatch_started` / `:tool_dispatch_completed` | around a batch | `{iteration, call_count}` |
| `:tool_call_started` | before a call runs | Engine event includes `call` (see ToolRunner); the Bridge's SSE frame omits it |
| `:tool_call_completed` | after a call ran | see ToolRunner |
| `:question_requested` / `:question_answered` / `:question_cancelled` | `QuestionDesk`: a question is asked (an approval, `ask_user_question`, a hook's or plugin's `ask_user`, the step-limit Continue), answered, or withdrawn | `{pending_question}` / `{id, answer}` / `{id, reason}` |
| `:plugin_init_wait` | a turn waits for plugin init tasks that provide tools (`PluginTasks`) | `{tasks: [{bundle, id, label}]}` |
| `:used_memories_updated` | a memory was read, and after the loop | `{used_memory_names, read_names?}` |
| `:working_set_updated` | after `:generation_started` (the running turn's conversation, the turn's strategy) and once in `end_turn` before the end event (the kept messages), only when the set differs from the last one emitted for the session and is not empty, except one empty event when the last one had items (a rollback emptied the set): a tool-free turn emits none (`Engine#emit_working_set`); between turns `Engine#announce_working_set` announces it under the next turn's strategy (after a `/working-set` op, held behind the command's `command_ran`) | `{items: [{kind, key, state (live\|stale\|forgotten\|dropped), tokens, ops, count, first_id, pinned, has_drop}], at, adds?: [{kind, key, label}]}` (`WorkingSet`, internals/working-set.md; `adds` while the user's adds are pending) |
| `:hook_notice` | a hook's or plugin's notify during a turn | `{hook, text, level}` (announced with `between_turns: true` outside a turn) |
| `:guardrail_warning` | a guardrails line during a turn | `{message}` |
| `:turn_completed` | normal end | Engine event `{turn_id, result, turn_summary, display_pending}`, plus `verify: true` (a Verify turn, verdict or not: the page's `data-verify`), `verdict` (a Verify turn's recorded verdict) and `revises` (a Revise turn's stamp, `{turn_id}`) when there are; the Bridge's SSE frame omits `result` (answer remains in `turn_summary.output`) |
| `:turn_canceled` | Stop, hook stop, Ctrl-C | `{turn_id, cancellation_reason, cancelled_by?, duration_ms}` |
| `:turn_failed` | an error | `{turn_id, error_class, message, duration_ms, error_kind?, retryable?, host?, summary?}` |
| `:answer_display` | after the after_turn hooks (observers only, not the sink) | `{display, refs?}` (display a string, or nil; refs the count of the answer's refs, only when a hook attached some) |

A turn's origin is a `TurnOrigin` (`lib/samagotchi/turn_origin.rb`, a `Data.define` of `client_id`, `enqueued_id`
and `author`): `SessionInbox.read_input` makes it from an input file's own fields, the wakes, reports and reminders
make theirs, and `Engine#run_turn`, the Worker and `GuardrailWiring` pass it on. Its readers say what callers ask
(`#participant?`, `#participant_author`, `#participant_id`, `#source` = `ClientId.origin`, `#human?` =
`ClientId.human?`). At a boundary it is turned once: `#to_h` writes the wire Hash (only the fields set, as before),
`TurnOrigin.from` reads a Hash back (symbol or string keys; nil for none). In-process an origin is never nil:
`TurnOrigin.of` gives `TurnOrigin::NONE` (no sender: an owner's turn with no client) for nil or `{}`, and NONE is
`run_turn(origin:)`'s default (a Hash is still read as one). NONE has no wire form (`#empty?`; `#wire` is nil, or
`#to_h` for any other origin), so the events and the hooks' `context` carry no origin for it, as before.
`LastTurn#author` stays the session file's string; `LastTurn#participant_author` reads it as
`TurnOrigin#participant_author` does. The boundary events (`:turn_started`, `:turn_completed`, `:turn_canceled`, `:turn_failed`) also carry
`origin` when the turn was queued with one: `{client_id:, enqueued_id:}`, plus `author:` when someone other than
the session's owner wrote it (its input file's `author`, stamped by chi web from the request's `Web::Principal`).
An owner's turn has no `author` anywhere: not in its input file, its origin or the session. The turn's
`TurnContext` carries the origin and its participant author (`TurnContext#author`) for the gate's checks
(`GuardrailWiring#begin_turn` decides the participant's mode from it); the guardrails `Context` (the hooks'
`context`) keeps the wire Hash.

Where a participant's author (`"p:<id>"`; `Steer.participant_author?`: any author but none or `"owner"`) goes:

- **The opening message**: `{role: "user", content:, turn_id:, author:, author_name:}` (`Engine#author_fields`;
  the name from `participants.json` at the turn's start, `SessionParticipants`, left out when the sidecar doesn't
  name the participant). Merged input and steers carry the same two keys (`Steer::Line#author`, grouped by sender
  and author so a participant's lines never share the owner's message). Assistant and tool messages carry none:
  `Steer.author_at(messages, index)` resolves the turn's author by position. `ChatLoop#plain` keeps the keys
  (`Steer::AUTHOR_KEYS`).
- **The wire**: such a message goes out under the review-contribution header (`Steer.header` /
  `Steer.review_header`, both loops through `Steer.wire_text`; see prompt-caching.md). Saved raw.
- **`Session#last_turn.author`** (`LastTurn#origin` stays the category) and the turn's analytics record's `author`
  (`SessionMetrics`).
- **Queued turns**: `turn_enqueued`; the accumulator's queued rows. A participant's `/word` or `!line` is never a
  command: `Bridge#handle_post_turn` answers it 403 and `WorkerInbound#queue_as_command` drops it (so
  `QueuedCommand#author` stays nil on every path now).
- **Delivery**: a participant's input file always waits for a turn of its own (`SessionInbox.waits_for_turn_end?`),
  so `Worker#pending_input_drain` never merges it; the Bridge queues their `POST /turn` whatever its delivery and
  counts their running and queued turns against chi web's `pending_limit` (429 `too_many_turns`).
  `Worker#run_prompt` checks their link and cap (`participant_refusal`: `participants.json`'s entry and cap against
  `SessionMetrics#spend`) before their turn starts and after it ends (the owner's notice, once per cap). A Continue
  keeps the offer turn's author (`ContinueOffer#run_continue_turn`, from `last_turn.author`).
- **The gate**: `GuardrailWiring#participant_boundary(turn)` is the core check after the load failures, picked by
  the call's `TurnContext#participant_mode`: `Guardrails::PairBoundary` for a pair turn, `Guardrails::ReviewBoundary`
  for a review one. Both read the turn's `author` and are no-ops for the owner's turns; the review boundary denies a participant's turn everything
  outside `Toolkit::REVIEW_TOOLS` (not `forget_outputs`), the pair boundary denies secrets, owner-voiced tools and
  `ask_user_question` and always asks before a write that may land outside the project (docs/guardrails.md).
  The declared tools stay the session's (D3: no rebuild per author).
- **Hooks and plugins**: `Engine#turn_author` (the running turn's participant author, nil otherwise: the
  published `TurnContext#author`, so any thread reads the running turn's from its first moment) is the hook
  runtime's `turn_author` (`Hooks::Registry#with_runtime` adds `author:` to every event of such a turn) and the
  plugin host's (`ctx.turn_author`).
- **Spend**: the analytics turn record's `author` feeds `SessionMetrics#spend` / `spend_by_author` (the snapshot's
  `spend_by_author`, `/stats`); `Engine#note_side_usage` stamps a side request's author (`#side_author`: the running
  turn's, the recap's after it, else the owner's) into `SideTotals#by_author`.
- **Side models**: `IdleRecap::TranscriptFilter` and `Plugin::SideQuestion` name a participant's message as theirs.
- **The system prompt**: `Engine#refresh_participants!` at a turn's start (after `apply_toolkit!`) rebuilds the
  prompt when the session gains its first active participant or loses its last (the participants line).

### Hook points (not events)

`:session_start`, `:before_turn`, `:after_turn` and `:session_end` are hook points: the Engine fires them on the
hook registry (`@hooks.fire`), not on the sink or the observers. The other hook points are `:before_generation`,
`:after_generation`, `:generation_progress` (Hooks::StreamWatch, in batches while the response streams),
`:before_tool_call` (the guardrail gate) and `:after_tool_call` (ToolRunner). docs/hooks.md lists their payloads.

## Session lifecycle

```
Engine initialization (in this order, among other things):
  @turn_state, @steer_cut (SteerCut: its GenerationPhase and WaitingSteer)
  @event_fanout (EventFanout: emit_event, the stream handler, the working set; its lookups read at call time)
  @turn_endings (TurnEndings: the turn endings' builders)
  @host_registry, @model_binding (ModelBinding: the ModelChoice, i.e. the name and the name as typed, and the given
    profile or nil: resolved on first need, so building an Engine makes no network call); @model_settings
    (SessionModelSettings: the choice and the session read at use); @client = effective_model.client
  MemoryBundle::SystemBundle.ensure! (the shipped system bundle installed; a failure is logged, not raised)
  @event_routes (EventRoutes: where a card or a notice goes: held while the plugins load, an anytime command's, an init task's, a turn event, else announced or held)
  @hook_routes (HookRoutes: notices (through @event_routes), hook questions, stop_turn/stop_generation, steer attribution)
  @guardrail_wiring, @question_desk, @relay_desk (RelayDesk: a delegate's approval relay)
  @thinking_notices (ThinkingNotices)
  build_tools_and_plugins:
  @extension_load = ExtensionLoad.new; @hooks = @extension_load.hooks (config.yml's, then the bundles')
  @tools = Tools::Builtins.registry; @command_registry (SessionCommands' built-ins); @plugin_tasks
  @toolkit_binding (ToolkitBinding: the kits, the plugins' among them, and the turn-start apply)
  @tool_index = Tools::ToolIndex.new; @peer_sources = PeerSources.new
  the bundles' plugins load (load_plugins → ExtensionLoad#load_plugins; each plugin's ctx is a
    Plugin::Context over plugin_host, whose ctx.sessions it builds itself: the test kit passes its own, sessions:),
    then (plugins or not) @tool_index.declare(@tools): find_tools + call_tool (source "index", not core),
    declared per toolkit by Registry#declared? (a source registered at load, or a tool registered then that
    the toolkit leaves reachable: Registry::Index#loaded; Toolkit::Resolved#declares? treats built-ins and
    plugin tools alike: full declares both, another kit its list and adds) and
    sets call_tool's unwrap (Tools::ToolIndex: the chi group from ToolSurface#index_only, the sources'
    groups, search, call checks, the unwrap; a source runs the call with its own plugin Context)
  @reminder_store = ReminderStore.new (the kernel gets it), @reminder_queue, @reminders
  wire_kernel: one KernelLoop::Services (Engine-lifetime, never per turn: hooks, tools, reminder_store,
    muted_memory_names, question_handler, peers (PeerView), gate (@guardrail_wiring.gate(hooks:, tools:): values,
    both built by now), warmup (PromptWarmup), generation_guard) →
    @kernel = KernelLoop.new(client:, profile:, model_name:, services:), or a given kernel's #attach(services);
    then sync_kernel_client! (the client is no service: a model switch swaps it, KernelLoop#client=)
  @hooks.runtime = @hook_routes.runtime (HookRoutes, built first: what a hook or plugin does reaches the UIs)
  @native_backend = LLM::NativeBackend.new(kernel: @kernel)
  @prompt_builder = SystemPrompt.new(...)
  @session_observer with the metrics, the log subscriber and the thinking tails subscribed (subscribe_session_observers)
  @engine_snapshots (EngineSnapshots: session_state_snapshot and stats_snapshot), built last: nothing reads a
    snapshot while the Engine is built

Model switching, Engine#switch_model!(model_name, persist_default:, typed:):
  → checks the host (ModelProfile.check_host!), sets the choice (ModelBinding#switch!: name and typed name in
    one assignment)
  → drops the given profile and the profile resolution (resolved again on first need; one that another
    thread finishes for the old model is neither kept nor applied: #store_profile)
  → sync_model_key! (the next turn's TurnContext takes the keys), @prompt_builder.reset! (the system prompt is
    built again)
  → sync_kernel_client! (the kernel talks to the new host), the context window cache dropped
  → the old model's ctx dropped: @metrics.forget_model_reports! (its window and profile reports) and
    @last_context_status = nil; /model (SessionCommands#switch_model) then calls #announce_switched_context!
    (the ctx % on the new model's window, before its first turn; Engine#session= does the configured-window-only
    variant for a session loaded on another model; internals/context-telemetry.md)
  → the kernel is never rebuilt; the next turn's backend follows the new host's api

Model probes (per turn):
  The profile, window, served model and vision are asked from the server's /props as needed.
  The cache is dropped at the turn's end, not its start, so one turn doesn't ask twice.
  A Stop cuts the probes early (Client.swap_probe_cancel).
```

## Hooks

Plugins and hook files register hooks on hook points (see "Hook points" above, and docs/hooks.md). Every fire
puts the hook runtime on the event: `event[:hook]` (the hook's label) and five helpers, which call the Engine's
`Hooks::Runtime` (built by `HookRoutes`, `hook_routes.rb`, which routes each to the UIs). A plugin's `ctx` has the same ones (`ctx.notify`, `ctx.steer`, ...).
A question takes keywords only at that plugin-facing edge (`event[:ask_user]`, `ctx.ask_user`); from there it is one
`HookQuestion` (`hook_question.rb`: the question, its options, header, freeform flag, the hook's label and its
label => effect map) through `Hooks::Runtime#ask_user` / `Plugin::Host#ask_user`, `Engine#hook_ask_user` and
`HookRoutes#ask_user` to `QuestionDesk#ask_for_hook`, which turns the effects into the pending question's per-option
tags. The bundle test kit records the same value (`Testing::Recorder#questions`).

| Helper | What it does | Used by |
|---|---|---|
| `event[:notify].call(text, level:, fallback_for:)` | One line to the user (`:hook_notice`); `fallback_for: :display` marks a line that stands in for the answer's display, which a UI that renders the display's links leaves out | mcp (a server didn't start), loop-guard |
| `event[:ask_user].call(question:, options:, header:, allow_freeform:)` | A single-select question through the question flow; nil when there is no one to ask | known-names (a near-miss name: correct it?) |
| `event[:stop_turn].call(reason)` | Cancel the running turn (reason `:hook`), with a warn notice | loop-guard (repeated calls), check-in (`/checkin stop`) |
| `event[:stop_generation].call(reason)` | Cut the streaming generation; the turn goes on | loop-guard (thinking repeats itself) |
| `event[:steer].call(text)` | Queue text for the running turn's next boundary | check-in (nudge mode), skills |

From `:after_turn` and `:session_end` there is no turn left: `stop_turn` and `steer` return false.

`:after_turn` adds two of its own, built by `complete_turn` on the stored conversation's last message when it is the
model's: `event[:present]` (`AnswerDisplay`, the answer's `display` text) and `event[:refs]` (`AnswerRefs`, refs kept
as `display_refs`: caps, validation, relative file paths resolved against the session's folder, `refs_rejected`
logged). Both are display only: `AnswerDisplay::DISPLAY_ONLY` lists `display`, `empty_answer` and `display_refs`, which
`strip`/`strip_all` drop from every model-facing copy (hooks' `messages:`, the recap, `ctx.messages`,
after_generation), while `KernelLoop#sanitize_history` and `ChatLoop#plain` copy them so the stored conversation keeps
them across turns. `Web::App#messages_for_display` sends `display_refs` re-validated (`AnswerRefs.for_display`).

History stamps: user prompts, merged input and steers, reminders, context and task notes and the model's replies carry
`at` (`MessageTime::KEY`, `message_time.rb`: a local-offset ISO time with milliseconds), when the entry happened. A
turn reads the wall clock once (`Turn#wall`, `MessageTime.now`): `:turn_started`'s `at`, its prompt's and its
reminders' stamps; `Steer::Merge#messages` stamps a merge at the boundary, `ContextNote.message` a note with its
`created_at` (else now), `KernelLoop#iterate` / `#cancelled_result` and the chat loop's `Run#with_thinking` /
`Run#canceled` each reply. Tool results, `!cmd` messages and TurnNote notes carry none. Like `display`, `at` must
survive the two rebuilds: both model branches of `KernelLoop#sanitize_history` and `ChatLoop#plain` copy it (an
allow-list that drops a key loses it for good on the next turn; `spec/message_time_history_spec.rb` checks both
loops). It is display-only and never reaches the wire (prompt-caching.md, rule 7), but it is not in
`AnswerDisplay::DISPLAY_ONLY`: hooks and `ctx.messages` see it. `:recap_ready` carries the saved recap's
`created_at` (`Engine#emit_recap(created_at:)`, from `IdleRecap#collect`). The UIs' gap dividers come from
`MessageTime.gap_line` (10 min, `GAP_SECONDS`).

`:question_asked` (`QuestionAsked`, `question_asked.rb`) fires from the two Engine seams where a question of the
model's opens, never from `QuestionDesk`: `Engine#request_question` (the kernel's `Services#question_handler`, after
`AskUserQuestion.validate`; not with `interface == :non_interactive`) and the guardrail wiring's `ask:` lambda
(`GuardrailWiring#request_approval`, after a stored approval and the non-interactive deny). So `ask_for_hook`, a
relayed approval (`Engine::RelayPeer#open_question` → `Engine#open_question`) and `post` (the step-limit question) never
fire it. `QuestionAsked.fire` is a no-op without a subscriber (`Registry#any?`); else it finds the live
conversation's last `role: "model"` entry (`Engine#live_conversation`, one lookup for both loops: a ChatLoop batch may
end in a tool result), builds an `AnswerRefs` on that step alone with the question caps (50 / 32 KiB), fires with the
step's text (`Engine#question_step_text`: the parser's thought and tool-call strip, then
`OutputFormatter.strip_markup`), a frozen copy of the fields and a no-op `ask_user`, then sets `display_refs` on
the step **in place** under the event lock (the loops and the forget layer hold entries by identity) and returns the
fields with `refs:`. `QuestionDesk#request` forwards `refs` past its slice; `PendingQuestion#refs` carries them to
`:question_requested`, the session file and the cards. `Web::App#with_question_refs` re-validates them (the pending
question, `cards_for_display`) with the same caps; the page pairs them in the asking slot, on the card and on the
step's text ([architecture.md](../architecture.md), the `display_refs` paragraph). The kit's
`Testing::Bundle#question_asked` calls `QuestionAsked.fire` with a one-step conversation.

### Hook lifecycle

- **Bundle hooks** (`Registry#register_bundle`) and **config hooks** (`register_persistent`, from config.yml)
  live for the process: `clear_all` leaves them, so they apply to every turn.
- **Turn-scoped hooks** (`Engine#register_hook`, `Registry#register`) are cleared by `clear_hooks` in
  `release_turn`.
- Order of a fire: bundle hooks (by priority, bundle, hook name), then config hooks, then turn-scoped hooks.
- A hook that raises is logged; it never breaks the turn. A plugin's `chi.on` handler and a bundle's `hooks/*.rb`
  file also tell the user, once per label in this Engine (`Hooks.wrap(on_failure:)` → `HookRoutes#plugin_hook_failed`: a
  `:guardrail_warning` labelled `plugins`, with `Engine#plugin_warning` for a UI that joins later). The Engine hands
  that callback to the hook files through `ExtensionLoad.new(hook_failed:)` → `Hooks::BundleLoader.load(hook_failed:)`;
  a config hook (config.yml's own files) has none, and the test kit's sandbox gives none.
- A notice from a hook goes to the running turn's sink and the observers. Outside a turn it is announced with
  `between_turns: true`; while the plugins load it is held and announced after. `EventRoutes#route` decides it, the
  same routes as a card's (`Engine#show_card`), with their own marks (`NOTICE_MARKS`, `CARD_MARKS`); a guardrails
  line after load takes only the turn / between-turns routes (`#route_by_turn`).
- Plugin init tasks (`chi.init`, slow setup such as an MCP server's first start): a turn waits for the ones that
  provide tools before it builds its messages, and a Stop or Ctrl-C ends the wait.

## Guardrails

`ToolRunner` asks the kernel's `Guardrails::Gate` (set by the Engine from `GuardrailWiring`) before each call,
with the call's `TurnContext` (`Gate#evaluate(call, context:)`: its controller, model key and name, and what
`GuardrailWiring#context(turn)` / `#checks(turn)` make of it; `GuardrailWiring` keeps no per-turn state);
the gate is not itself a hook. `Gate#evaluate` fires the `:before_tool_call` hooks (the voters, e.g. the
known-names bundle or a config hook), which vote through `event[:guardrail]` (`deny!`, `ask!`) or the legacy
`event[:blocked]` flag. A deny stays a deny for the hooks after it; a hook's ask is dropped when guardrails are
disabled. Then the core checks run on the final call in `GuardrailWiring#checks` order
(`lib/samagotchi/guardrail_wiring.rb`): the load failures first, then the participant's boundary
(`participant_boundary`, `PairBoundary` for a pair turn else `ReviewBoundary`), then the hook asks, the protected
paths, the scratch writes, the delegate child's boundary, the rules. That method is the order; it is not spelled
out here so this page can't drift from it.

A gate that raises denies the call.

The verdict is one of:

- **allow**: the call runs.
- **deny**: that call's output is replaced with denial text; the rest of the batch still runs.
- **ask**: `Gate#settle_ask` first looks for a stored approval that covers the call. Otherwise
  `Engine#request_approval` asks the user through the question flow (attached TUI, web). A
  `--non-interactive` run has no one to ask, so the call is denied. An approval wider than this once is stored.

docs/guardrails.md covers the rules and the approval scopes.

## Anytime commands

A slash command a plugin registers with `anytime: true` (the btw bundle's `/btw`) runs on its own thread, even
while a turn runs:

```
Engine
  ├── spawn_anytime { ... }          # a thread #shutdown waits for
  ├── running_anytime { ... }        # cards and notices on this thread are announced at once,
  │                                  # marked anytime: true, never as the running turn's events
  ├── add_init_task(bundle:, label:, plugin_label:, provides_tools:, quiet:, timeout:, failed:)
  └── await_init_tasks(controller, on_event)
```

`add_init_task` and `await_init_tasks` belong to plugin init tasks (`PluginTasks`), not to anytime commands.

## Shared loop behaviors

Both loops:

- <a id="a-reply-that-is-only-a-tool-call"></a>**A reply that is only a tool call** (`LLM::StrayToolCall`, `LLM::ChatLoop` only): a reply with no tool
  calls whose whole text is one tool-call block closed by the tag that opened it (`<function=` by `</function>`, `<parameter=` by `</parameter>` or
  `</function>`, `<tool_call>` by `</tool_call>`), with nothing else in it — the block need not carry inner tags — isn't an answer. A reply
  opening with prose or a fence, or saying anything after the close, stays an answer, and the check is one string test on a normal one. Nothing is
  guessed from the block and it never enters the history (`:generation_completed`
  and `:after_generation` have already seen the text): `:generation_retrying` with `restarted` voids the streamed text, `:empty_answer_retry` with
  `malformed` goes out, and a hidden `TurnNote.malformed_retry` asks again at the retry temperature. It has its own budget, so `retry.empty_answer: 0`
  doesn't turn it off, and a real tool call resets it. Two in a row fail the turn with `LLM::MalformedGeneration`, keeping its earlier steps; a Stop that lands on a stray reply ends the turn cancelled, not failed, because a stopped turn skips this path. Each is
  logged as `generation_malformed` with the shape, finish reason, served model and the text's tail. `KernelLoop` has its own path (`ToolCallParser#malformed`).
- **Empty-answer retry** (`EmptyAnswerRetry`): a generation with no visible text and no tool calls is asked
  again, up to `retry.empty_answer` times (at most 3), with a hidden nudge (`TurnNote.empty_retry`) on the tail.
  The retry request runs at temperature 0.6 when the configured sampling sets no temperature; a configured one
  is kept. A length stop with the context at least 90% full is not retried. When the retries run out, the
  Engine keeps a `TurnNote.empty` note as the turn's end. A Stop that lands on an empty reply ends the turn cancelled, in both loops.
- **A refusal** (chat loop only): a finish reason `refusal` (Messages), or `content_filter` (OpenAI) with no text, is
  an empty answer never retried; text streamed before a refusal is not kept, and tool calls with it are not run. A
  `content_filter` with text keeps it, marked `ChatLoop::FILTERED_MARK`, also never retried. `ModelResult#refusal` is `{category:}` (from the response's
  `stop_details`) or `{}`, and goes on the `TurnNote.empty` marker and `turn_summary.empty_answer` as `refusal`, so
  every UI words the notice `no answer: refused by the provider (cyber)`.
- **A cut generation** (`after_cut`): a generation a plugin cut (`stop_generation`) spends the same retry budget
  with its own nudge; when it is used up, the turn ends cancelled (`:hook`). A steer's cut asks again with the
  steer and spends nothing.
- **Steering**: queued input goes in at iteration boundaries (`Steer.inject!`, `:pending_input_merged`). A
  worker's drain (`Worker#pending_input_drain`) takes every input file in name order except the ones
  `SessionInbox.waits_for_turn_end?` leaves for a turn of their own (`delivery: queue`, or images): those are
  skipped, not a barrier, so a line sent after them still merges. Only the files it claims reach
  `:input_merged`, the failure hand-back (`@merged_this_turn`) and the checkpoint; the skipped ones run after the
  turn, one turn each, in name order (`Worker#run_input_files`).
- **Context status**: an estimate of the window's fill before each request,
  emitted on every request (`:context_status`) so the UI always has a current
  number, with a guidance line on the tail only when it rises far enough.
- **Cancel**: text streamed before a cancel stays, marked `[interrupted]`.
- **The same events**: generation events, tool dispatch and tool call events, and the before/after generation
  and tool call hooks.

Native loop only: the Qwen open-block recovery, and the thinking prefill (`Thinking.native`: with thinking off, Qwen
gets an empty thought after the cue, `QWEN_EMPTY_THOUGHT`, and Gemma 4 its empty thought channel,
`GEMMA_EMPTY_THOUGHT`, with no `<|think|>` token before the system prompt; at any other level Qwen gets an open
thought, `QWEN_OPEN_THOUGHT` (`<think>\n`), when the server's chat template writes one after its cue
(`Thinking.opens_thought?` on the model's `/props`, a Qwen3.5+ template; `KernelLoop#native_prefill`, once per turn).
The prefill is kept in the model message so the next prompt starts with what the server has cached; each
generation's `ThoughtStreamSplitter` is seeded with it (an open thought's reasoning streams as `thinking:`), and the
answer is stripped from prefill + response, so the reasoning never lands in it).

## Key design principles

1. **Turn state is cross-thread safe.** TurnState uses one Monitor and calls nothing out while it is held.
2. **Turn-scoped and process-wide hooks.** `register_hook` hooks are cleared at `release_turn`; bundle hooks
   and config.yml hooks survive.
3. **Each loop works on its own copy of the conversation.** The Engine's `turn.messages` is what it sent. After
   a normal end or a Stop it keeps `result.conversation`; after a failure, the copy attached with
   `FailedTurn.attach` (a Ctrl-C's too); `turn.messages` only when it ended before the loop.
4. **Events are the contract.** UIs read events, not internal state. `on_event` is per turn; observers are
   persistent.
5. **A stable system prompt for the cache.** `SystemPrompt#build` caches the prompt per Engine, keyed by
   `[chat, thinking, layers]` (chat/native, the thinking level, the turn's LLM context layers), and is reset
   only on a model switch, a tools change, a plugin's `prompt_changed!` (`Engine#prompt_changed!`), a profile
   change or a toolkit change (`Engine#apply_toolkit!`). The stable part (base prompt, the toolkit's not-loaded line,
   rg guidance, identity, model notes, preloaded memories, AGENTS.md, appended files, the toolkit's kit prompt, the
   plugins' prompt sections, memory indexes) comes before the volatile tail (model, working directory, session).
   prompt-caching.md covers this in detail.

## Key files

Paths are under `lib/samagotchi/`.

| File | Role |
|---|---|
| `engine.rb` | Engine: the wiring (`initialize`, the `build_*` methods, the kernel), the turn skeleton (`run_turn`, `begin_turn`, `prepare_turn`'s ordered steps, `generate`, `end_turn`) and `shutdown`; the rest is in its parts, below |
| `engine/steering.rb` | `Engine::SteeringPart`: steering the running turn (or the next), the drains, the cut, the activity clock, the cancel |
| `engine/side_requests.rb` | `Engine::SideRequestsPart`: ctx.ask_model's and Check this's side requests, their side usage, System 1's recording |
| `engine/recap.rb` | `Engine::RecapPart`: the idle recap job and `/recap`, the idle scheduler's start and stop |
| `engine/models.rb` | `Engine::ModelsPart`: the model's names, identity and notes, `/model`'s switch, the profile, the loop it runs on |
| `engine/model_settings.rb` | `Engine::ModelSettingsPart`: the session's model settings (SessionModelSettings) and the snapshots (EngineSnapshots), forwarded |
| `engine/events.rb` | `Engine::EventsPart`: observers, `#announce`, the event lock, held announcements, load events, the emit helpers |
| `engine/cards.rb` | `Engine::CardsPart`: `#show_card`, anytime commands and their threads |
| `engine/objectives.rb` | `Engine::ObjectivesPart`: the objectives' stage builder, `announce_objectives` and `propose_objective` (forwarded), Check this's side request |
| `engine/messages.rb` | `Engine::MessagesPart`: the session messages API (out-of-turn edits, checkpoints, the live conversation) |
| `engine/plugins.rb` | `Engine::PluginsPart`: loading plugins, init tasks and staged tools, `Plugin::Host` |
| `engine/hooks.rb` | `Engine::HooksPart`: turn-scoped hooks, the hook runtime (HookRoutes, forwarded), reminders |
| `engine/guardrails.rb` | `Engine::GuardrailsPart`: the guardrails' readers and the first turn's load warnings |
| `engine/participants.rb` | `Engine::ParticipantsPart`: the turn's author, a pair turn's stop, the participants line |
| `engine/session.rb` | `Engine::SessionPart`: `#session=`, the state dir, the relay's view, the system prompt and its memory names |
| `engine/verify.rb` | `Engine::VerifyPart`: the Verify/Revise anchors' stage builder |
| `engine/questions.rb` | `Engine::QuestionsPart`: ask-user-question (QuestionDesk, forwarded) |
| `engine/toolkit.rb` | `Engine::ToolkitPart`: the toolkit, `ctx.load_tools`, System 1's toolkit suggestion (the stage's builder and `warm_toolkit_suggestion!`, forwarded) |
| `engine/context_judge.rb` | `Engine::ContextJudgePart`: the candidate judge's stage builder and `judge_late_candidates`, forwarded |
| `turn_stages/toolkit_suggestion.rb`, `turn_stages/context_judge.rb`, `turn_stages/objectives.rb`, `turn_stages/warmup.rb`, `turn_stages/verify_anchors.rb` | `TurnStages::ToolkitSuggestion`, `TurnStages::ContextJudge`, `TurnStages::Objectives`, `TurnStages::Warmup`, `TurnStages::VerifyAnchors`: the turn stages ("Turn stages" above) |
| `engine/turn_helpers.rb` | `Engine::TurnHelpersPart`: a turn's settings, images, model ref, used memories, the turn-end warm-up's stage builder |
| `engine/turn_end.rb` | `Engine::TurnEndPart`: the normal ending and after-turn hooks, release, what an ending keeps, last_turn, the answer's display |
| `event_fanout.rb` | `EventFanout`: how an event reaches the turn's sink and the observers (`emit_event`), the loops' stream handler, the working set's emit and dedupe; the Engine forwards |
| `engine_snapshots.rb` | `EngineSnapshots`: the UIs' read model, `session_state_snapshot` (cheap, never raises) and `stats_snapshot` (may probe `/props`); the Engine forwards |
| `model_binding.rb` | `ModelBinding`: the model choice and the prompt profile resolved for it, under one mutex, and the overlay keys; the Engine forwards |
| `turn_endings.rb` | `TurnEndings`: what each turn ending keeps and announces (the kept messages and their `TurnNote`, `failed_event`, `turn_summary`, `stop_facts`); the Engine forwards |
| `turn_state.rb` | Cross-thread turn state (running, controller, sink, steers, activity clock) |
| `steer_cut.rb` | `SteerCut`: the Engine's seam for a message cutting the generation |
| `generation_phase.rb`, `waiting_steer.rb` | Whether a steer may cut the running generation, and the steer that waits to |
| `effective_model.rb` | `EffectiveModel` (the effective model's settings, a snapshot per read; `.of_session`), `ModelChoice`, the fallbacks' log lines (`Unresolved`) |
| `session_setting.rb` | `SessionSetting`: the per-session settings' descriptors (own value, chips, the web's fallback) |
| `session_model_settings.rb` | `SessionModelSettings`: the session's settings on its effective model (its own thinking, reasoning_history and llm_context over the model's, the `/model` and `/stats` summaries, what a turn resolves, `#model_setting`'s fallbacks); the Engine forwards its readers there |
| `level_setting_command.rb`, `thinking_command.rb`, `reasoning_history_command.rb` | `/thinking` and `/reasoning-history` (`LevelSettingCommand` and its two Specs) |
| `thinking_notices.rb` | `ThinkingNotices`: the notices a turn's thinking level leads to |
| `steer_cut_after.rb`, `cut_policy.rb` | The model's cut wait (`SteerCutAfter.resolve`); the loops' cut path (`CutPolicy`) |
| `steer.rb` | Queued input and steers at iteration boundaries |
| `kernel_loop.rb` | Native loop: `#run` (format, generate, parse, dispatch, iterate) |
| `llm/chat_loop.rb` | Chat loop: `#complete` (tool schemas per request, wire conversion, block replay) |
| `llm/adapters.rb` | `LLM::Adapters::BY_API`: which chat adapter a host's api gets |
| `llm/openai_chat.rb` | `LLM::OpenAIChat`, the `/v1/chat/completions` adapter |
| `llm/adapter_common.rb` | `LLM::AdapterCommon`: what both chat adapters share (the HTTP layer and its timeouts, the paged model list, the SSE line loop, JSON errors) |
| `llm/refusal_memo.rb` | `LLM::RefusalMemo`: what a host refused (for one model, or the whole host), remembered for its holder's life (an adapter, or the worker's ChatLoop) |
| `llm/anthropic_messages.rb`, `llm/anthropic_wire.rb`, `llm/anthropic_assembly.rb`, `llm/dialect.rb` | The `/v1/messages` adapter, its wire translation, its response, its dialects ([anthropic.md](anthropic.md)) |
| `llm/prompt_cache.rb` | Cache breakpoints on the OpenAI path, and the `cache_control` both adapters send |
| `llm/turn_settings.rb` | `LLM::TurnSettings`, what a turn runs under (vision, sampling, thinking, reasoning history, …) |
| `llm/native_tool_normalizer.rb`, `llm/stream_drops.rb` | A chat adapter's tool calls as chi's call hashes (`Tools::BuiltinCalls`); asking again for a step whose stream dropped (both loops) |
| `reasoning_history.rb` | `ReasoningHistory`: the levels, `.resolve`, `.run_start` |
| `llm/backend.rb` | The `LLM::ModelBackend` contract (`#complete(...)`) |
| `llm/native_backend.rb` | Wraps KernelLoop as a backend (`#complete` calls `#run`) |
| `llm/model_result.rb` | `LLM::ModelResult`, what a backend returns |
| `tool_runner.rb` | Per-call path (gate, start/complete events, output cap, images, diffs) |
| `tool_output_cut.rb`, `tool_output_files.rb` | `ToolOutputCut`: how a tool's output longer than `max_tool_output_chars` (a `memory_read`'s: `memory.read_max_chars`) is cut, by the tool's policy (`POLICIES`; `:head` for a tool with none); `ToolOutputFiles`: the whole output of an execute cut that way, saved in the session's `tool_output/` folder ([tool-output-limits.md](tool-output-limits.md)) |
| `tool_row_fields.rb`, `row_refs.rb` | `ToolRowFields`: a tool row's fields beyond its params (`ACTIVITY_KEYS`, `EVENT_KEYS`), the same live and on a reload; `RowRefs`: a plugin tool's row refs (`refs:`), checked, capped and saved with the result |
| `tool_response.rb` | Per-batch dispatch and tool_response entries (joined for native, single for chat) |
| `empty_answer_retry.rb` | The empty-answer and cut retry budget |
| `prompt_warmup.rb` | The turn-end warm-up |
| `tools/registry.rb` | The tools a session offers: schemas, handlers, order |
| `tools/tool_index.rb` | `Tools::ToolIndex`: `find_tools` and `call_tool`, the tools a session knows but doesn't declare one by one (the sources' groups and the built-ins its toolkit leaves out), `#declare`, `#refresh!`, `#unwrap` |
| `plugin/tool_spec.rb` | `Plugin::ToolSpec`: a checked tool declaration (`chi.tool`, a tool set, `ToolSpec.build`), what `Registry#register` gets; `#per_call` |
| `system_prompt.rb` | System prompt construction (stable part, volatile tail) |
| `prompt_files.rb`, `model_notes.rb` | The AGENTS.md chain and appended files; the model notes the prompt loads |
| `toolkit.rb`, `toolkit_command.rb` | A session's toolkit (`Toolkit#resolve`, what `Registry` declares); `/toolkit` |
| `toolkit_binding.rb` | `ToolkitBinding`: the Engine's toolkit seam (the kits, `#explained`, `ctx.use_toolkit`, the turn-start `#apply!` behind `Engine#apply_toolkit!`) |
| `hooks/registry.rb` | Hook registry, fire order, `Hooks::Runtime` |
| `hook_routes.rb` | `HookRoutes`: the Engine's routes for a hook's or plugin's notice (`:hook_notice`, `fallback_for:`), question, stop and steer, and the guardrails' after-load line |
| `question_asked.rb` | `QuestionAsked`: the `:question_asked` fire, the asking step's refs (`display_refs` in place, the pending question's `refs`) |
| `question_desk.rb`, `pending_question.rb`, `question_answer.rb` | `QuestionDesk`: the one open question (ask, post, answer, cancel, relay mark); `PendingQuestion` and `QuestionAnswer`, its values (Hashes only in events, Bridge JSON, the session file and the hook/plugin `ask_user` result) |
| `hook_question.rb` | `HookQuestion`: a hook's or plugin's `ask_user` question as one value, from the runtime/host edge to `QuestionDesk#ask_for_hook` |
| `event_routes.rb` | `EventRoutes`: where a card (`Engine#show_card`), a notice (`HookRoutes#notify`) and a guardrails line (`#guardrail_notify`, turn or between turns only) go: held while the plugins load, an anytime command's, an init task's, a running turn's event, else announced or held for `holding_announcements` |
| `engine_peers.rb`, `peer_sources.rb` | `Engine::PeerView` (what the kernel's peer tools see of the Engine) and `Engine::RelayPeer` (a delegate's approval relay); `PeerSources`: the attached context sources a peer bundle declares as its peer's answers (`chi.peer_source`) |
| `extension_load.rb` | What an Engine loads at start: config.yml and bundle hooks, plugins, `bundles:` settings; events held while plugins load |
| `guardrail_wiring.rb`, `guardrails/gate.rb` | The gate's context and approvals; the verdict per call |
| `events.rb` | Event type sets shared by the Worker, the Bridge, the TUI and the web |
| `cancellation_controller.rb` | A turn's cancel signal, and a generation's child controller |
| `session.rb` | Session model (status, messages, persistence) |
| `turn_checkpoint.rb` | `TurnCheckpoint`: a worker's running turn saved at the loop's iteration boundaries (`Session#turn_checkpoint`), so a killed worker loses at most `INTERVAL` of it |
| `context_status.rb` | `ContextStatus`: one turn's context tracking (the status line's value, the `:context_status` event, the model's guidance line) ([context-telemetry.md](context-telemetry.md)) |
| `session_manager.rb` | Background session processes (workers) and their IPC |
| `worker_wakes.rb` | `WorkerWakes`: a worker's wake budget for the turns nobody typed (`session.max_wakes`) |
| `task_watch.rb`, `task_finish_note.rb` | `TaskWatch`: the background tasks a worker's session started that the model hasn't seen finish; `TaskFinishNote`: the note one leaves when it does ([background-tasks.md](background-tasks.md#finish-wake)) |
| `side_usage.rb` | `SideUsage`: one side request's usage (a recap, `ctx.ask_model`), folded into the session's side sums (`:side_usage`) |
| `bridge/client_event.rb` | `Bridge::ClientEvent.project`: what an SSE client gets for an engine event ([bridge.md](bridge.md)) |
| `guardrails/parent_policy.rb` | `Guardrails::ParentPolicy`: which options of a question a parent agent may pick (`guardrails.parent_answers`) |
