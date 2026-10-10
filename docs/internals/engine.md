# Engine: the core agent loop

The Engine (`lib/samagotchi/engine.rb`) runs a session's turns. It owns the turn lifecycle, the hooks and
plugins, and the model↔tool cycle, and it reports what happens as events, so every UI (the REPL, a worker
behind the web and the attached TUI, one-shot CLI runs) runs turns the same way without the Engine knowing how
they render.

```
Engine#run_turn → backend.complete(...) → KernelLoop#run (native) or ChatLoop#complete (chat)
  → per iteration: one generation, then ToolResponse.run_batch over the calls
      → ToolRunner#run per call → Guardrails::Gate → KernelLoop#dispatch_tool_call
  → repeat until the model answers without tool calls, or the iteration limit
```

## Quick reference: the turn lifecycle

```
Engine#run_turn(session, prompt, on_event:, max_iterations:, cancel_controller:, max_tool_output_chars:,
                pending_input:, continue:, origin:, images:)
  │
  ├── begin_turn(session, prompt, on_event:, cancel_controller:, origin:, continue:)
  │     # @session = session, session.status = RUNNING, used memories absorbed,
  │     # TurnState#begin!(controller:, sink:) (a new CancellationController when none is given),
  │     # a recap in flight invalidated, GuardrailWiring#begin_turn(origin)
  │     # Returns a Turn {session, prompt (nil on a continue), continue, on_event, controller,
  │     #                 origin, started_at, id}
  │
  ├── Client.swap_probe_cancel(turn.controller)   # a Stop cuts this turn's /props probes
  │
  ├── prepare_turn(turn, images)
  │     # Emits :turn_started {session_id, prompt, turn_id, continue: true (only on a continue),
  │     #                      images (only when there are any)}
  │     # refresh_profile! (may ask the server's /props once)
  │     # turn.settings = LLM::TurnSettings (vision, sampling, thinking; model_name is set in generate)
  │     # announces guardrail load failures, starts and awaits plugin init tasks, applies staged tools
  │     # fires the :session_start hook on the Engine's first turn, then the :before_turn hook
  │     #   (a frozen copy of the history, and the prompt)
  │     # turn_messages: system head + history + due reminders (:reminder_injected) + the user message
  │     # Returns false when a Stop came during the probes or the init wait, else true
  │
  ├── generate(turn, max_iterations:, max_tool_output_chars:, pending_input:)
  │     # sync_kernel_client!, then @kernel.turn_settings = turn.settings with model_name and window_setting
  │     # turn.limit = max_iterations or IterationLimit.for
  │     # backend.complete(messages: turn.messages, ..., pending_input: turn_drain(pending_input))
  │     # Returns LLM::ModelResult (text, conversation, canceled?, exhausted?, tool_activity,
  │     #                          context_status, empty_steps, empty_retries)
  │
  ├── publish_used_memories(session, on_event)    # :used_memories_updated when there are any
  │
  ├── complete_turn(turn, result)
  │     # end_turn(turn, "completed" | "canceled"): under the event lock the session gets the kept
  │     #   messages, goes IDLE, records last_turn, and :turn_completed {result, turn_summary,
  │     #   display_pending} or :turn_canceled {cancellation_reason, cancelled_by, duration_ms} is emitted
  │     # then the :after_turn hook (status, messages, present: the AnswerDisplay presenter)
  │     # store_answer_display (:answer_display to the observers when a hook changed the answer,
  │     #   or display: nil when the web was told to wait for it)
  │     # then the :session_end hook
  │
  ├── warm_up_next_turn(turn, result)
  │     # local llama.cpp on the native loop only: prefills the next turn's prompt while the user
  │     # reads (PromptWarmup; see prompt-caching.md, "The turn-end warm-up"). Never fails the turn.
  │
  └── ensure: release_turn(probe_cancel_before)
        # TurnState#finish! (turn flag off, controller, sink and steers cleared)
        # GenerationPhase#finished!, WaitingSteer#clear!
        # probe cancel swapped back
        # the context window cache dropped, so the next turn asks the server again
        # steers left logged as dropped, activity recorded, turn-scoped hooks cleared
```

### Error paths

```
StandardError in run_turn:
  → if turn.ended (it came from the after_turn/session_end hooks): logged as post_turn_error, re-raised
  → else: end_turn(turn, "failed", save: true)
     # Both loops call LLM::FailedTurn.attach(e, conversation) before re-raising, so
     # failed_messages keeps the loop's partial conversation (tool iterations included),
     # else turn.messages, with TurnNote.failed(summary, continued: turn.continue) at the tail.
     # :turn_failed {error_class, message, duration_ms}; a provider error adds
     # error_kind, retryable, host and summary.
  → re-raised

Interrupt (Ctrl-C):
  → if turn.ended: re-raised only
  → turn.controller.cancel!(:ctrl_c)
  → end_turn(turn, "canceled"): ctrl_c_messages keeps turn.messages with TurnNote.cancelled(:ctrl_c)
     # Both loops work on their own copy of the conversation, and Interrupt is not a
     # StandardError, so nothing attaches the loop's conversation: only what the Engine
     # built before the loop (system head, history, reminders, the prompt) survives.
     # Tasks the turn started are missed in the cancel note for the same reason.
  → :turn_canceled {cancellation_reason: :ctrl_c, duration_ms}
  → re-raised (the caller decides whether to exit)

A Stop (Engine#cancel_current_turn!, e.g. the Bridge's POST cancel) or a hook's stop_turn:
  → not an error: the loop returns LLM::ModelResult(canceled: true, conversation: ...)
  → complete_turn keeps the loop's conversation (tool iterations included) with a
     TurnNote.cancelled note; a text streamed before the cancel stays, marked [interrupted]

Stopped before the model was asked (prepare_turn returned false):
  → stopped_before_model(turn) → end_turn(turn, "canceled")
  → nothing kept, :turn_canceled {cancellation_reason, cancelled_by, duration_ms}
  → LLM::ModelResult(text: "", canceled: true, cancellation_reason: reason)
```

## The model↔tool loop

The Engine does not talk to models directly. `Engine#backend` picks the loop the effective model's host speaks:

```
Engine#backend → backend_for(@host_registry.resolve(@effective_model_name))
  → host entry chat? (api: openai): LLM::ChatLoop (one per Engine, built on first use)
  → else:                           LLM::NativeBackend wrapping the Engine's KernelLoop
```

Both implement the `LLM::ModelBackend` contract (`#complete(messages:, max_iterations:, on_stream_event:,
cancel_controller:, model_name:, max_tool_output_chars:, pending_input:)`). `NativeBackend#complete` only calls
`KernelLoop#run` with the same arguments. `ChatLoop` runs its own loop but is built with the same KernelLoop,
whose tools, hooks, gate and dispatch it uses.

### KernelLoop (the native, raw-prompt loop)

Runs models whose server takes a raw prompt (llama.cpp `/completion`, or `/v1/completions` on an
OpenAI-compatible completions server). chi formats the prompt itself, per model profile (Gemma 4, Qwen 3.6), and
parses tool calls out of the generated text.

```
KernelLoop#run(messages, max_iterations:, on_stream_event:, cancel_controller:,
               model_name:, max_tool_output_chars:, pending_input:)
  │
  │ turn = start_turn(...)   # turn.conversation = prepare_conversation(messages): a copy,
  │                          # old model messages without their thought blocks
  │ each iteration:
  │ 1. Queued input (user lines, plugin steers) goes in at the boundary (Steer.inject!)
  │ 2. Format the conversation as prompt text (Prompt.format_with_images); a context
  │    guidance line goes on the tail when the window fills past a threshold
  │ 3. Stream one generation (:generation_started, :generation_chunk, :generation_completed)
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
(`LLM::FailedTurn.attach`), so `Engine#failed_messages` can keep it; a Ctrl-C does not (see Error paths).

### ChatLoop (the OpenAI chat API)

Runs hosts with `api: openai`: remote providers such as OpenRouter (Claude and others) and any OpenAI-compatible
chat server. The model gets the tools as JSON schemas and returns structured tool calls.

```
ChatLoop#complete(messages:, max_iterations:, on_stream_event:, cancel_controller:,
                  model_name:, max_tool_output_chars:, pending_input:)
  │
  │ conversation = Array(messages).map(&:dup)   # a shallow copy of each message
  │ Run.new(self, conversation, on_stream_event, cancel_controller, model_name, pending_input)
  │    .call(max_iterations: max_iterations || 1, cap: KernelLoop.resolve_output_char_cap(max_tool_output_chars))
  │
  └──→ LLM::ModelResult(text, conversation, exhausted, canceled, tool_activity, ...)
```

The differences from the native loop:

- The tools go in each request's `tools` field (`tool_definitions`), not in the system prompt.
- The conversation is converted to the OpenAI wire format (`wire_messages`).
- The first system message carries `cache_split:` (from `SystemPrompt#stable_length`, which the Engine passes in
  as `stable_length:`), where the prompt's stable part ends. For remote Claude, `LLM::PromptCache` puts the
  first cache breakpoint there; see prompt-caching.md.
- Each call's result is its own tool message, paired by `tool_call_id`.

### Shared: ToolResponse (per batch) and ToolRunner (per call)

Both loops run a batch of calls the same way:

```
One iteration with tool calls:
  KernelLoop#dispatch_calls / ChatLoop::Run#dispatch
    → ToolResponse.run_batch(runner, calls, iteration:, emit:, on_stream_event:, cap:)
      → :tool_dispatch_started {iteration, call_count}
      → for each call: ToolRunner#run(call, iteration:, call_index:, call_count:,
                                      on_stream_event:, max_tool_output_chars:)
          → Guardrails::Gate#evaluate (the before_tool_call hooks, then the core checks)
          → :tool_call_started
          → an ask verdict: Gate#settle_ask (asks the user, records waited_ms)
          → KernelLoop#dispatch_tool_call, or the denial text
          → :tool_call_completed, then the :after_tool_call hook
          → returns {output:, capped_output:, truncated:, activity:, images:, shown_params:,
                     shown_label:, diff:}
      → :tool_dispatch_completed {iteration, call_count}
    → native: ToolResponse.joined(runs), one entry with the capped outputs
      chat:   ToolResponse.single(run, tool_call_id:) per call, with the capped output
```

**ToolRunner** (`ToolRunner#run`):
- Runs the gate first, so `:tool_call_started` shows the call that will run (a before_tool_call hook may
  replace it; known-names corrects a misspelled name this way, and the model gets one line saying what ran).
- Emits `:tool_call_started` {iteration, call_count, call_index, tool, call, params, label (plugin tools),
  title, view}.
- Settles an ask verdict after `:tool_call_started`, so a UI shows the tool line and then the approval.
- Dispatches through `KernelLoop#dispatch_tool_call`, or writes the denial text. Unknown tools are answered in
  `KernelLoop#dispatch` ("Error: no such tool ...", never repeating the wrong name).
- For edit and write: diffs the file before and after, and refreshes a memory's index line
  (`MemoryBundle::IndexSync`).
- Attaches returned images, at most `MAX_IMAGES_PER_RESULT` (4) per result.
- Scrubs bytes that aren't UTF-8, and caps the output at `max_tool_output_chars`: a longer one is cut and ends
  with `[cut: N of M chars; read it in parts]` (N kept of M, the whole within the cap unless the cap is shorter
  than that line). The model (both loops), the event and the after_tool_call hook get that text.
- Emits `:tool_call_completed` {iteration, call_count, call_index, tool, output, output_truncated, activity,
  images, diff, waited_ms, view}, then fires `:after_tool_call` {iteration, tool, output, status}.

A denied call gets denial text in place of its output; the rest of the batch still runs. After a hook's
`stop_turn`, the gate denies every remaining call of the batch.

## State management

### TurnState (cross-thread)

One object, guarded by a `Monitor`, that the turn thread writes (`begin_turn`, `release_turn`) and other threads
read: the idle scheduler, the Bridge's request threads, plugin threads, the UIs.

```
TurnState
  ├── running?
  ├── controller        (the running turn's CancellationController)
  ├── sink              (the turn's on_event)
  ├── steers            (plugin steers for the running turn's next boundary)
  ├── carried_steers    (for the next turn that begins)
  └── activity clock    (last_activity_at, activity_seq)
```

- `begin!(controller:, sink:)`: running, with controller and sink, in one step; carried steers become steers.
- `finish!`: not running, controller and sink cleared; returns the steers never taken (logged as dropped).
- `steer(text, source:)`: queues a steer for the running turn (false with no turn).
- `steer_next_turn(text, source:)`: queues a steer for the next turn that begins.

The lock is a leaf: nothing is called out while it is held.

### Turn (Engine::Turn)

The turn as the Engine sees it (the KernelLoop has its own `Turn` struct):

```ruby
Turn = Struct.new(:session, :prompt, :continue, :on_event, :controller, :origin, :started_at, :messages, :ended,
                  :settings, :id, :limit) do
  def tag(event) = origin ? event.merge(origin: origin) : event   # boundary events carry the origin
  def elapsed = ...                                               # seconds since started_at
end
```

- `messages` is what the Engine sends: system head, history, reminders, the prompt. The loop works on its own
  copy; the Engine keeps `result.conversation` after a normal end or a Stop, and the error's partial
  conversation after a failure.
- `controller` is the turn's `CancellationController`, an in-process signal. Another process stops a worker's
  turn through the Bridge (`POST cancel` → `Engine#cancel_current_turn!`).
- `on_event` is the turn's sink.
- `ended` is set by `end_turn`.

### GenerationPhase

What the running generation streams, fed by the Engine's stream handler: whether a steer sent as a cut (delivery
`cut`: `/cut TEXT`, `chi send --cut`) may cut it. `SteerCut#cut_for_steer` answers `:now`, `:waits` or `:off`; the
Bridge acks it as `cut`.
A generation is cuttable while it has streamed only thinking, is still thinking, and has thought for at least
`steer.cut_after` seconds (`cuttable?(min_age)`). It has `started!`, `chunk!`, `retrying!` and `finished!`.

### WaitingSteer

A message that may cut the generation but came too early (the generation hadn't been thinking long enough). It
waits until the thinking passes `steer.cut_after` (the Engine checks on each thinking chunk), until a drain hands
the message to the model at a boundary, or until the turn ends (`clear!` in `release_turn`).

## Events

### The turn's sink (`on_event`) and the observers

`Engine#emit_event` sends each turn event to the turn's sink (`on_event`, the REPL's renderer) and then to the
persistent observers (`Engine#subscribe`), which get a copy with a monotonic `event_seq`. The observers are the
metrics, the debug log, the thinking tails, and in a worker the Bridge, which streams to the web and the attached
TUI. Errors in the sink or an observer are caught; they never break the turn.

`Engine#announce` puts an event that belongs to no turn (`ANNOUNCEABLE_EVENTS`: `turn_enqueued`, `card`,
`hook_notice`, `guardrail_warning`, `plugin_init_started`, and more) to the observers only.

Turn events (the main ones; `Events` in `events.rb` keeps the shared sets):

| Event | When | Payload |
|---|---|---|
| `:turn_started` | `prepare_turn` | `{session_id, prompt, turn_id, continue?, images?}` |
| `:reminder_injected` | due reminders went into the turn | `{reminders}` |
| `:context_status` | every request, the current estimate before it | `{iteration, ...}` |
| `:generation_started` | a request begins | `{iteration, context_window_tokens, context_window_source}` (native adds `profile`, `profile_source`) |
| `:generation_chunk` | each streamed chunk | `{iteration, content, text, thinking, payload, tool_call?}` |
| `:generation_retrying` | the transport retries the request, or the chat loop asks again for a step whose stream dropped mid-answer (`restarted: true`: what the step streamed is void, and the web's live step, the TUI's activity line, the Bridge's TurnAccumulator and the stream hooks' watch start it over) | `{iteration, attempt, max_retries, next_delay, error_class, error_message, status, restarted?}` |
| `:generation_completed` | a generation ended, or was cut | `{iteration, content_length, thinking_chars, served_model, requested_model, finish_reason, ...}`; a cut adds `stopped_by`, `stop_reason`; the Engine adds `speed`, `tokens` |
| `:generation_cancelled` | the turn was cancelled mid-loop | `{iteration, reason, stopped_by}` |
| `:empty_answer_retry` | an empty, cut or malformed answer is asked again | `{iteration, attempt, of, finish_reason, thinking_chars, stopped_by?, malformed?}` |
| `:steer_cut` | a steer cut the generation | `{iteration, source}` |
| `:llm_context_edited` | the apply rule applied a batch of LLM context edits (a request, a forget_outputs call, turn end; never the warm-up) | `{moment, why, freed_tokens, tail_tokens, staged, text, groups}` (`LLMContextNotice`) |
| `:pending_input_merged` | queued input joined the conversation | `{iteration, count, content, steers?, answer}` |
| `:tool_dispatch_started` / `:tool_dispatch_completed` | around a batch | `{iteration, call_count}` |
| `:tool_call_started` | before a call runs | see ToolRunner |
| `:tool_call_completed` | after a call ran | see ToolRunner |
| `:used_memories_updated` | a memory was read, and after the loop | `{used_memory_names, read_names?}` |
| `:hook_notice` | a hook's or plugin's notify during a turn | `{hook, text, level}` (announced with `between_turns: true` outside a turn) |
| `:guardrail_warning` | a guardrails line during a turn | `{message}` |
| `:turn_completed` | normal end | `{result, turn_summary, display_pending}` |
| `:turn_canceled` | Stop, hook stop, Ctrl-C | `{cancellation_reason, cancelled_by?, duration_ms}` |
| `:turn_failed` | an error | `{error_class, message, duration_ms, error_kind?, retryable?, host?, summary?}` |
| `:answer_display` | after the after_turn hooks (observers only, not the sink) | `{display}` (a string, or nil) |

The boundary events (`:turn_started`, `:turn_completed`, `:turn_canceled`, `:turn_failed`) also carry `origin`
when the turn was queued with one.

### Hook points (not events)

`:session_start`, `:before_turn`, `:after_turn` and `:session_end` are hook points: the Engine fires them on the
hook registry (`@hooks.fire`), not on the sink or the observers. The other hook points are `:before_generation`,
`:after_generation`, `:generation_progress` (Hooks::StreamWatch, in batches while the response streams),
`:before_tool_call` (the guardrail gate) and `:after_tool_call` (ToolRunner). docs/hooks.md lists their payloads.

## Session lifecycle

```
Engine initialization (in this order, among other things):
  @turn_state, @generation_phase, @waiting_steer
  @host_registry, @effective_model_name; @client = @host_registry.resolve(...).client
  @given_profile = profile or nil (resolved on first need, so building an Engine makes no network call)
  @guardrail_wiring, @question_desk
  @extension_load = ExtensionLoad.new; @hooks = @extension_load.hooks (config.yml's, then the bundles')
  @tools = Tools::Builtins.registry; the bundles' plugins load (load_plugins → ExtensionLoad#load_plugins)
  wire_kernel: @kernel = KernelLoop.new(client:, profile:, hooks:, reminder_store:, tools:)
  @kernel.guardrail_gate = @guardrail_wiring.gate; @kernel.warmup = PromptWarmup.new
  @hooks.runtime = hook_runtime
  @native_backend = LLM::NativeBackend.new(kernel: @kernel)
  @prompt_builder = SystemPrompt.new(...)
  @session_observer with the metrics, the log subscriber and the thinking tails subscribed (subscribe_session_observers)

Model switching, Engine#switch_model!(model_name, persist_default:, typed:):
  → checks the host (ModelProfile.check_host!), sets @effective_model_name
  → drops the given profile and the profile resolution (resolved again on first need)
  → sync_model_key!, @prompt_builder.reset! (the system prompt is built again)
  → sync_kernel_client! (the kernel talks to the new host), the context window cache dropped
  → the kernel is never rebuilt; the next turn's backend follows the new host's api

Model probes (per turn):
  The profile, window, served model and vision are asked from the server's /props as needed.
  The cache is dropped at the turn's end, not its start, so one turn doesn't ask twice.
  A Stop cuts the probes early (Client.swap_probe_cancel).
```

## Hooks

Plugins and hook files register hooks on hook points (see "Hook points" above, and docs/hooks.md). Every fire
puts the hook runtime on the event: `event[:hook]` (the hook's label) and five helpers, which call the Engine's
`Hooks::Runtime`. A plugin's `ctx` has the same ones (`ctx.notify`, `ctx.steer`, ...).

| Helper | What it does | Used by |
|---|---|---|
| `event[:notify].call(text, level:)` | One line to the user (`:hook_notice`) | mcp (a server didn't start), loop-guard |
| `event[:ask_user].call(question:, options:, header:, allow_freeform:)` | A single-select question through the question flow; nil when there is no one to ask | known-names (a near-miss name: correct it?) |
| `event[:stop_turn].call(reason)` | Cancel the running turn (reason `:hook`), with a warn notice | loop-guard (repeated calls), check-in (`/checkin stop`) |
| `event[:stop_generation].call(reason)` | Cut the streaming generation; the turn goes on | loop-guard (thinking repeats itself) |
| `event[:steer].call(text)` | Queue text for the running turn's next boundary | check-in (nudge mode), skills |

From `:after_turn` and `:session_end` there is no turn left: `stop_turn` and `steer` return false.

### Hook lifecycle

- **Bundle hooks** (`Registry#register_bundle`) and **config hooks** (`register_persistent`, from config.yml)
  live for the process: `clear_all` leaves them, so they apply to every turn.
- **Turn-scoped hooks** (`Engine#register_hook`, `Registry#register`) are cleared by `clear_hooks` in
  `release_turn`.
- Order of a fire: bundle hooks (by priority, bundle, hook name), then config hooks, then turn-scoped hooks.
- A hook that raises is logged; it never breaks the turn.
- A notice from a hook goes to the running turn's sink and the observers. Outside a turn it is announced with
  `between_turns: true`; while the plugins load it is held and announced after.
- Plugin init tasks (`chi.init`, slow setup such as an MCP server's first start): a turn waits for the ones that
  provide tools before it builds its messages, and a Stop or Ctrl-C ends the wait.

## Guardrails

`ToolRunner` asks the kernel's `Guardrails::Gate` (set by the Engine from `GuardrailWiring`) before each call;
the gate is not itself a hook. `Gate#evaluate` fires the `:before_tool_call` hooks (the voters, e.g. the
known-names bundle or a config hook), which vote through `event[:guardrail]` (`deny!`, `ask!`) or the legacy
`event[:blocked]` flag. A deny stays a deny for the hooks after it. Then the core checks run on the final call:
protected paths, then the rules (config and bundles, e.g. the guardrails bundle's `rules.yml`; a rule can match
the tool, its targets and the model). A gate that raises denies the call.

The verdict is one of:

- **allow**: the call runs.
- **deny**: that call's output is replaced with denial text; the rest of the batch still runs.
- **ask**: `Gate#settle_ask` first looks for a stored approval that covers the call. Otherwise
  `Engine#request_approval` asks the user through the question flow (REPL, attached TUI, web). A
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

- **Empty-answer retry** (`EmptyAnswerRetry`): a generation with no visible text and no tool calls is asked
  again, up to `retry.empty_answer` times (at most 3), with a hidden nudge (`TurnNote.empty_retry`) on the tail.
  The retry request runs at temperature 0.6 when the configured sampling sets no temperature; a configured one
  is kept. A length stop with the context at least 90% full is not retried. When the retries run out, the
  Engine keeps a `TurnNote.empty` note as the turn's end.
- **A cut generation** (`after_cut`): a generation a plugin cut (`stop_generation`) spends the same retry budget
  with its own nudge; when it is used up, the turn ends cancelled (`:hook`). A steer's cut asks again with the
  steer and spends nothing.
- **Steering**: queued input goes in at iteration boundaries (`Steer.inject!`, `:pending_input_merged`).
- **Context status**: an estimate of the window's fill before each request,
  emitted on every request (`:context_status`) so the UI always has a current
  number, with a guidance line on the tail only when it rises far enough.
- **Cancel**: text streamed before a cancel stays, marked `[interrupted]`.
- **The same events**: generation events, tool dispatch and tool call events, and the before/after generation
  and tool call hooks.

Native loop only: the Qwen open-block recovery, and the thinking prefill (Qwen with thinking off gets an empty
thought after the cue, kept in the model message so the next prompt starts with what the server has cached).

## Key design principles

1. **Turn state is cross-thread safe.** TurnState uses one Monitor and calls nothing out while it is held.
2. **Turn-scoped and process-wide hooks.** `register_hook` hooks are cleared at `release_turn`; bundle hooks
   and config.yml hooks survive.
3. **Each loop works on its own copy of the conversation.** The Engine's `turn.messages` is what it sent. After
   a normal end or a Stop it keeps `result.conversation`; after a failure, the copy attached with
   `FailedTurn.attach`; after a Ctrl-C, only `turn.messages`.
4. **Events are the contract.** UIs read events, not internal state. `on_event` is per turn; observers are
   persistent.
5. **A stable system prompt for the cache.** `SystemPrompt#build` caches the prompt per Engine (per chat/native
   and thinking level) and is reset only on a model switch, a tools change or a profile change. The stable part
   (base prompt, identity, memories, AGENT.md, memory indexes) comes before the volatile tail (model, working
   directory, session). prompt-caching.md covers this in detail.

## Key files

Paths are under `lib/samagotchi/`.

| File | Role |
|---|---|
| `engine.rb` | Engine: turn lifecycle, event emission, hooks runtime, plugins, model switching |
| `turn_state.rb` | Cross-thread turn state (running, controller, sink, steers, activity clock) |
| `generation_phase.rb`, `waiting_steer.rb` | Whether a steer may cut the running generation, and the steer that waits to |
| `steer.rb` | Queued input and steers at iteration boundaries |
| `kernel_loop.rb` | Native loop: `#run` (format, generate, parse, dispatch, iterate) |
| `llm/chat_loop.rb` | Chat loop: `#complete` (tool schemas per request, wire conversion) |
| `llm/backend.rb` | The `LLM::ModelBackend` contract (`#complete(...)`) |
| `llm/native_backend.rb` | Wraps KernelLoop as a backend (`#complete` calls `#run`) |
| `llm/model_result.rb` | `LLM::ModelResult`, what a backend returns |
| `tool_runner.rb` | Per-call path (gate, start/complete events, output cap, images, diffs) |
| `tool_response.rb` | Per-batch dispatch and tool_response entries (joined for native, single for chat) |
| `empty_answer_retry.rb` | The empty-answer and cut retry budget |
| `prompt_warmup.rb` | The turn-end warm-up |
| `tools/registry.rb` | The tools a session offers: schemas, handlers, order |
| `system_prompt.rb` | System prompt construction (stable part, volatile tail) |
| `hooks/registry.rb` | Hook registry, fire order, `Hooks::Runtime` |
| `extension_load.rb` | What an Engine loads at start: config.yml and bundle hooks, plugins, `bundles:` settings; events held while plugins load |
| `guardrail_wiring.rb`, `guardrails/gate.rb` | The gate's context and approvals; the verdict per call |
| `events.rb` | Event type sets shared by the Worker, the Bridge, the TUI and the web |
| `cancellation_controller.rb` | A turn's cancel signal, and a generation's child controller |
| `session.rb` | Session model (status, messages, persistence) |
| `session_manager.rb` | Background session processes (workers) and their IPC |
