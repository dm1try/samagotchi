# Engine: the core agent loop

The Engine is the heart of Samagotchi. It owns everything from session lifecycle to the model↔tool interaction cycle, exposing an event-based API (`on_event`) so any UI (TerminalUI, Web UI, workers, CLI commands) can run turns without being coupled to rendering.

```
User → Engine#run_turn → Backend.complete(...) → KernelLoop#run / ChatLoop#complete
       → ToolRunner#run (per call) → ToolResponse#run_batch (per iteration)
       → Model → ToolRunner → Tool calls → results → repeat
```

## Quick reference: the turn lifecycle

```
Engine#run_turn(session, prompt, on_event:, cancel_controller:, pending_input:, continue:, origin:, images:)
  │
  ├── begin_turn(session, prompt, on_event:, cancel_controller:, origin:, continue:)
  │     # Sets @session, session.status = RUNNING, TurnState.begin!(controller:, sink:),
  │     # clears @recap, guardrail_wiring.begin_turn(origin)
  │     # Returns a Turn {session, prompt, continue, on_event, controller, origin,
  │     #                   started_at, messages, ended, settings, id, limit}
  │
  ├── prepare_turn(turn, images)
  │     # Emits :turn_started (session_id, prompt, turn_id, images)
  │     # probes /props for this session (window, served model, vision)
  │     # sets turn.settings (LLM::TurnSettings: vision, sampling, thinking, model_name)
  │     # fires :session_start on first turn, :before_turn (read-only history copy)
  │     # runs plugin init tasks (slow setup: first MCP server start), awaits completion
  │     # applies staged tools (changed since last turn), drops them from staged
  │     # builds turn.messages: system head + history + reminders + prompt
  │     # Returns false if cancelled (turn ends before model is asked), true otherwise
  │
  ├── generate(turn, max_iterations:, max_tool_output_chars:, pending_input:)
  │     # Routes to backend.complete(...) — either NativeBackend (wraps KernelLoop#run)
  │     # or ChatLoop#complete
  │     # Copies turn.settings into @kernel.turn_settings (model_name, window_setting)
  │     # Sets turn.limit (IterationLimit), wraps pending_input (drained per-loop)
  │     # Returns LLM::ModelResult (text, conversation, tool_calls, canceled, exhausted)
  │
  ├── complete_turn(turn, result)
  │     # Emits :turn_completed (result, turn_summary, display_pending)
  │     # Fires :after_turn (with AnswerDisplay presenter) — hooks may present the answer
  │     # Fires :session_end
  │     # Stores answer display for late-attaching clients (web re-reads then)
  │     # Calls end_turn(turn, outcome) { yield seconds → (kept, event) }
  │     │     # Synchronizes events, replaces session.messages with kept messages,
  │     │     # session.status = STATUS_IDLE, records last_turn, emits event
  │     │     # turn.ended = true, saves session if save: true
  │
  └── ensure: release_turn(probe_cancel_before)
        # TurnState.finish! (turn flag off, controller/sink/steers cleared)
        # GenerationPhase.finished!, WaitingSteer.clear!
        # Restores probe-cancel (swaps back before-state)
        # Drops context window cache (so next turn probes fresh, doesn't double-read)
        # Records activity (advances idle window)
        # Logs dropped steers, clears turn-scoped hooks (persistent hooks survive)
```

### Error paths

```
StandardError in run_turn:
  → if turn.ended (after turn hooks): log as post_turn_error, re-raise
  → else: end_turn(turn, "failed", save: true)
     # FailedTurn.attach(e, conversation) stores partial_conversation on the error.
     # failed_messages reads error.partial_conversation (or turn.messages as fallback)
     # → [kept_messages (partial conversation with TurnNote.failed),
     #    :turn_failed event (error_class, message, duration_ms)]
     # Conversation kept with a TurnNote.failed(summary, continued: turn.continue)

Interrupt (Ctrl-C):
  → if turn.ended: re-raise (already ended by turn hooks)
  → turn.controller.cancel!(:ctrl_c)
  → end_turn(turn, "canceled")
  → [ctrl_c_messages (turn.messages so far with cancel note,
      *not* the loop's finished tool iterations — the loop copies conversation
      internally, so only pre-loop history + prompt survives),
     :turn_canceled (reason: :ctrl_c)]
  → Re-raised (caller handles it)
  # NOTE: the turn.messages is the pre-loop history only; the loop's internal
  # Turn struct holds the full conversation, which is NOT visible from the Engine
  # on a Ctrl-C (no FailedTurn.attach, as Interrupt is not a StandardError).

A "Stop" (cancel from another process or a plugin hook):
  → not an error; the loop returns LLM::ModelResult(canceled: true, conversation: …)
  → Engine proceeds to complete_turn, which saves what the loop's conversation
     provides (tool iterations included). This path is the "normal" completion
     for cancellations from outside a Ctrl-C.

Pre-model cancellation (prepare_turn returns false):
  → stopped_before_model(turn) → end_turn(turn, "canceled")
  → [nil (no conversation kept), :turn_canceled (reason from controller)]
  → LLM::ModelResult(text: "", canceled: true, cancellation_reason: reason)
```

## The model↔tool loop

Engine does not talk to models directly. It delegates to **backends**:

```
Engine.backend
  → if chat_model? (entry.chat?): ChatLoop (LLM::ChatLoop)
  → else: NativeBackend (LLM::NativeBackend) wrapping KernelLoop (Samagotchi::KernelLoop)
```

Both implement the `LLM::Backend` contract (`#complete(...)`), but the native path uses a wrapper:

```
NativeBackend
  # complete(messages, max_iterations:, on_stream_event:, cancel_controller:,
  #          model_name:, max_tool_output_chars:, pending_input:)
  → @kernel.run(messages, ...)  (KernelLoop#run)
  → LLM::ModelResult (returned by KernelLoop)
```

The ChatLoop implements `#complete` directly and also uses the same KernelLoop instance (shared with the NativeBackend) for tool dispatch.

### KernelLoop (native/raw-prompt loop)

Runs locally-hosted models (Gemma 4, Qwen 3.6, etc.) that speak a tool-calling format in raw text.

```
KernelLoop#run(messages, max_iterations:, on_stream_event:, cancel_controller:,
               model_name:, max_tool_output_chars:, pending_input:)
  │
  │ turn.conversation = prepare_conversation(messages)  (sanitized copy)
  │ iteration 1, 2, 3...
  │ 1. Format conversation as prompt text (Prompt.format_with_images)
  │    → Gemma 4:  <|tool_call>call:NAME{params}<tool_call|>
  │    → Qwen 3.6: ���<function=NAME><parameter=KEY>VALUE</parameter></function>�
  │ 2. Send to model (llama.cpp /completion)
  │ 3. Parse response for tool-call blocks (ToolCallParser, with Qwen
  │    unterminated-block recovery)
  │ 4. For each call: dispatch_calls → collect results
  │ 5. Inject results into turn.conversation (in-place mutation)
  │ 6. Repeat from step 1 until model emits no tool calls or max_iterations reached
  │
  └──→ LLM::ModelResult(text, conversation, tool_calls, canceled?, exhausted?)
```

Key: `turn.conversation` is a **copy** (created in `start_turn` via `prepare_conversation`), not `Engine#turn.messages`. On a failure, the loop stores it on `FailedTurn.attach(e, conversation)` so `Engine#failed_messages` can retrieve it. On a Ctrl-C, the Engine only sees `turn.messages` (pre-loop), because `Interrupt` is not a `StandardError` and doesn't get `FailedTurn.attach`'d.

### ChatLoop (OpenAI chat API)

Runs remote models (Claude, others via OpenRouter) that natively support tool schemas in `/v1/chat/completions`.

```
ChatLoop#complete(messages:, max_iterations:, on_stream_event:, cancel_controller:,
                  model_name:, max_tool_output_chars:, pending_input:)
  │
  │ conversation = Array(messages).map(&:dup)  (sanitized copy)
  │ Run.new(self, conversation, on_stream_event, cancel_controller, model_name, pending_input)
  │    .call(max_iterations: max_iterations || 1, cap: KernelLoop.resolve_output_char_cap(max_tool_output_chars))
  │
  └──→ LLM::ModelResult(text, conversation, tool_calls, canceled?, exhausted?)
```

The ChatLoop uses the shared KernelLoop for tool dispatch (via `@kernel`) — it doesn't reinvent `KernelLoop#run`. The ChatLoop passes `stable_length` to get Anthropic cache breakpoint splits (`cache_split:`).

The difference:

- Tools are sent as JSON schemas in each request (`tools` field), not in the system prompt.
- The engine's conversation format (internal messages with role, content, tool_call_id, etc.) is converted to OpenAI wire format (`wire_messages`).
- The system prompt's stable part gets a `cache_split:` hint for Anthropic's prompt cache (breakpoint #1).

### Shared: ToolRunner (per-call) and ToolResponse (per-iteration)

Both loops dispatch tool calls through `ToolRunner` (per-call policy) which delegates to `KernelLoop#dispatch_tool_call`, and each iteration uses a per-iteration `ToolResponse` to build tool messages for the next loop round:

```
One iteration:
  KernelLoop / ChatLoop
    → ToolResponse.run_batch(calls, iteration, call_count, on_stream_event, cap)
      → for each call: KernelLoop#dispatch_tool_call(call)
        → ToolRunner.run(call, iteration:, call_index:, call_count:, on_stream_event:, max_tool_output_chars:)
          → evaluate (Guardrails::Gate) → tool_call_started event
          → handle ask verdict (wait for approval)
          → dispatch or deny
          → emit tool_call_completed event
          → fire :after_tool_call hook
          → return run result (output:, capped_output:, truncated:, activity:, images:,
                              shown_params:, shown_label:, diff:)
    → build tool_response message(s) for the next iteration
```

**ToolRunner responsibilities:**
- Runs the guardrail gate first (before `:tool_call_started`). If the gate denies, that call's output is replaced with denial text.
- Emits `:tool_call_started` (iteration, call_count, call_index, tool, call, params, label, view).
- Handles the "ask" verdict: waits for approval (records `waited_ms`).
- Dispatches the call to KernelLoop, or writes the denial text.
- For edit/write tools: takes diffs and refreshes the memory index (via MemoryBundle::IndexSync).
- Attaches images (at most 4 per result).
- Scrubs bad UTF-8 bytes, applies the output cap (returns `capped_output:`, `truncated:` flag).
- Emits `:tool_call_completed`, then fires `:after_tool_call` hook.

**What ToolRunner does NOT do:**
- Validate calls. Unknown tools are handled in `KernelLoop#dispatch_tool_call`.
- Handle the hook runtime (other than `:after_tool_call`).
- Build tool_response messages for the conversation — each loop does that.

**What ToolResponse does (per-iteration):**
- Emits `:tool_dispatch_started` and `:tool_dispatch_completed`.
- Native loop: one `tool_response` entry for the whole batch (full outputs joined via `ToolResponse.joined`).
- Chat loop: one tool message per call, paired by `tool_call_id`, carrying capped output (`ToolResponse.single`).
- A deny replaces only that one call's output (the rest of the batch continues running).

## State management

### TurnState (cross-thread synchronization)

A single `Monitor`-guarded object shared between the turn thread and all other threads:

```
TurnState
  ├── running? (Boolean)
  ├── controller (CancellationController)
  ├── sink (Proc — per-turn event callback)
  ├── steers (Array<Hash> — queued for current turn boundary)
  ├── carried_steers (Array<Hash> — queued for next turn's first boundary)
  └── Activity clock (last_activity_at, activity_seq)
```

- `begin!(controller:, sink:)`: sets running=true, controller, sink, moves carried_steers to steers.
- `finish!`: sets running=false, nils controller/sink, returns steers (for logging as dropped).
- `steer(text, source:)`: queues a steer for the current turn's next iteration boundary.
- `steer_next_turn(text, source:)`: queues a steer for the next turn's first boundary.

Nothing is called *out* while the lock is held, so external callbacks never deadlock.

### Turn (Engine::Turn)

The session's turn as seen by the Engine (not the KernelLoop's internal Turn struct):

```ruby
Turn = Struct.new(
  :session, :prompt, :continue, :on_event,
  :controller, :origin, :started_at, :messages,
  :ended, :settings, :id, :limit
) do
  attr_reader :elapsed  # seconds
  def tag(event)  # helper adding turn metadata
end
```

Key properties:
- `messages` is the pre-loop messages (history + system head + prompt). After the loop, the Engine reads what the loop's `ModelResult.conversation` provides (on failure/stop).
- `controller` is cross-process (a file flag) for canceling from another process.
- `on_event` is the per-turn sink (REPL prints, Web updates).
- `ended` is set by `end_turn`.

### GenerationPhase

Tracks whether a generation is in progress (to determine if a steer may cut the generation).

```
GenerationPhase
  ├── in_progress? (Boolean)
  ├── finished! (called at turn end)
  └── Clock (monotonic seconds)
```

### WaitingSteer

A steer that arrived too early (during prompt building, before the generation started). It's queued and replayed at the next turn boundary.

## Events

### Per-turn sink (`on_event`)

The primary event path: emitted synchronously during a turn, received by:

- **TerminalUI**: prints the answer, renders tool steps, question cards.
- **Web UI**: receives via SSE (Server-Sent Events).
- **Bridge**: relays to attached remote sessions.

Events emitted during a turn:

| Event | When emitted | Payload |
|---|---|---|
| `:turn_started` | `prepare_turn` | `{session_id, prompt, turn_id, continue?, images}` |
| `:generation_started` | Model request begins | `{model, window, duration_ms}` |
| `:generation_chunk` | Each model token | `{text, thinking?, tokens, delta}` |
| `:generation_completed` | Model finishes | `{text, conversation, tokens, tool_calls?, canceled?, exhausted?, context_status}` |
| `:generation_retrying` | Provider retry | `{attempt, message}` |
| `:generation_cancelled` | Cancel mid-stream | `{reason, stopped_by}` |
| `:tool_dispatch_started` | ToolResponse batch starts | `{iteration, call_count}` |
| `:tool_dispatch_completed` | ToolResponse batch done | `{iteration, call_count}` |
| `:tool_call_started` | Before tool runs | `{iteration, call_count, call_index, tool, call, params, label?, view?}` |
| `:tool_call_completed` | After tool runs | `{iteration, call_count, call_index, tool, output, output_truncated, activity, images?, diff?, waited_ms?, view?}` |
| `:used_memories_updated` | After `publish_used_memories` | `{used_memory_names, read_names}` |
| `:answer_display` | After answer stored | `{display: text, nil}` |
| `:hook_notice` | Plugin notices | `{hook, text, level}` |
| `:reminder_injected` | Reminders injected | `{reminders}` |
| `:pending_input_merged` | Steering drained | `{message}` |
| `:guardrail_warning` | Guardrail failures | `{message}` |
| `:turn_completed` | Normal completion | `{result, turn_summary, display_pending}` |
| `:turn_canceled` | Cancel/failure | `{cancellation_reason, cancelled_by, duration_ms}` |
| `:turn_failed` | Error path | `{error_class, message, error_kind?, retryable?, host?}` |
| `:session_start` | First turn | `{session_id}` |
| `:before_turn` | Before generation | `{session_id, prompt, messages}` |
| `:after_turn` | After completion | `{status, messages, present: presenter}` |
| `:session_end` | After turn lifecycle | `{session_id}` |

### Persistent subscribers (`session_observer`)

After per-turn emission, a copy with monotonic `event_seq` is sent to persistent subscribers (session observer for web streaming). Errors in subscribers are isolated — they never break the turn.

## Session lifecycle

```
Engine initialization:
  @turn_state = TurnState.new(clock: monotonic_now)
  @generation_phase = GenerationPhase.new(clock: monotonic_now)
  @waiting_steer = WaitingSteer.new
  @client = @host_registry.resolve(@effective_model_name).client
  @given_profile = profile (or nil, resolved on first use)
  @hooks = Hooks::Registry.new (loaded from bundle plugins)
  @kernel = KernelLoop.new(client:, profile:, hooks:, ...)

Model switching:
  Engine#switch_model!(model_name)
    → updates @effective_model_name, resolves client from HostRegistry
    → @chat_backend.reset! (clears ChatLoop cache)
    → @native_backend = nil (new NativeBackend wrapping fresh KernelLoop)
    → profile_resolution resolves a new ModelProfile
    → hooks are reloaded (tools_changed! → apply_staged_tools!)
    → system prompt is rebuilt (prompt_builder.reset!)

Model probe (per turn):
  Engine probes /props for window, served_model, vision
  Cache is dropped at turn end, not start (so probes during a turn are consistent)
  A Stop (other-process cancel) can cut the probes early
```

## Hooks

Plugins register hooks that fire at lifecycle points. The Engine provides a **hook runtime** (`Hooks::Runtime`) with five capabilities:

| Hook capability | What it does | Example |
|---|---|---|
| `notify(text:, level:, hook:)` | Post a notice (to the user) | "Loading bundle X..." |
| `ask_user(question:, options:, header:, allow_freeform:, hook:)` | Ask a structured question | Source-links asks which issues to fetch |
| `stop_turn(reason:, hook:)` | Cancel the current turn | Guardrails blocks a tool call |
| `stop_generation(reason:, hook:)` | Cut a running generation | Source-links stops model during prompt building |
| `steer(text:, hook:)` | Queue steering for the next boundary | Idle reminder fires |

Hooks fire at: `:session_start`, `:before_turn`, `:after_turn`, `:session_end`, and plugin-specific points (`:tool_call_started`, `:generation_started`, etc.).

### Hook lifecycle

- **Persistent hooks** (registered via `register_persistent` from config.yml or bundle defaults) survive across turns.
- **Turn-scoped hooks** (added with `register` during a turn) are cleared by `clear_hooks` at `release_turn`.
- A hook loaded during a turn can steer/stop that turn (if the turn is running).
- A hook loaded during plugin loading (between turns) is announced with `between_turns: true` (cards shown to the user).
- Plugin init tasks are slow setup (MCP server start) — the turn waits for them, and a Ctrl-C cancels the wait.

## Guardrails

The Guardrails::Gate runs before each tool call (`:before_tool_call` hook). It can:

- **Allow** the call through
- **Block** the call (replaces that one call's output with denial text; the rest of the batch continues)
- **Ask for approval** (requires action turn)

The gate checks rules based on the tool name, args, and the model's identity.

## Background/anytime execution

```
Engine
  ├── spawn_anytime { ... }  → starts a thread with any-time hooks
  ├── add_init_task(bundle:, label:, plugin_label:, provides_tools:, ...)
  └── await_init_tasks(controller, on_event)
```

Any-time hooks run in separate threads outside the turn flow:

- They cannot steer a turn (no turn running).
- They can notify, ask_user, and stop_generation (but not stop_turn).
- Results are captured via a Desk (RelayDesk) or callbacks.

## Shared loop behaviors

Both loops share these behaviors:

- **Empty-answer retry**: `EmptyAnswerRetry` adjusts sampling when the model returns empty text (retry with lower temperature).
- **After-cut handling**: `after_cut` when a plugin cuts a generation, keeping the partial streamed text marked `[interrupted]`.
- **Same stream events**: `:generation_started`, `:generation_chunk`, `:generation_completed`, `:generation_retrying`, `:generation_cancelled`.
- **Same tool call flow**: `:tool_dispatch_started`, `:tool_dispatch_completed`, `:tool_call_started`, `:tool_call_completed`, `:after_tool_call`.
- **Qwen-specific**: unterminated tool-call block recovery (up to `QWEN_INCOMPLETE_TOOL_CALL_RECOVERY_LIMIT`), thinking preamble injection, prefill text, context-guidance line when filling up.

## Key design principles

1. **Turn state is cross-thread safe.** TurnState uses a single Monitor — no callbacks while the lock is held.
2. **Hooks: turn-scoped vs persistent.** Hooks added with `register` are cleared at `release_turn`. Hooks registered with `register_persistent` (from config.yml or bundle defaults, including Guardrails) survive across turns.
3. **Each loop copies the conversation** in `start_turn` (`prepare_conversation`). The Engine's `turn.messages` is the pre-loop history. The loop's internal `Turn.conversation` (KernelLoop) or `conversation` (ChatLoop) is what the Engine retrieves on failure via `FailedTurn.attach(e, conversation)`.
4. **Events are the contract.** UIs subscribe to events, not internal state. The `on_event` sink is per-turn; `session_observer` is persistent.
5. **Stable system prompt for cache.** The SystemPrompt is built once per loop, with a stable prefix (tools, identity, memories) and a volatile tail (model, location, session). The prompt cache document covers this in detail.

## Key files

| File | Role |
|---|---|
| `engine.rb` | Engine class: turn lifecycle, event emission, hooks, plugins |
| `turn_state.rb` | Cross-thread state (running, controller, sink, steers) |
| `kernel_loop.rb` | Native loop: `#run` (format, model, parse, dispatch, iterate) |
| `llm/chat_loop.rb` | OpenAI chat API: `#complete` (tool schemas per-request, wire conversion) |
| `llm/backend.rb` | Backend contract (`#complete(...)`) |
| `llm/native_backend.rb` | Wraps KernelLoop as a backend (implements `#complete` by delegating to `#run`) |
| `tool_runner.rb` | Per-call tool policy (gate, start/complete events, output cap, images, diffs) |
| `tool_response.rb` | Per-iteration tool batching (joined for native, single for chat) |
| `tools/registry.rb` | Tool registry, resolution, execution |
| `system_prompt.rb` | System prompt construction (stable/volatile split) |
| `hooks.rb` | Hook registry, runtime (notify, ask_user, stop_turn, steer, stop_generation) |
| `guardrails.rb` | Guardrail system (gate, approvals) |
| `events.rb` | Event types, emission helpers |
| `cancellation_controller.rb` | Cross-process cancellation (file flag) |
| `session.rb` | Session model (status, messages, persistence) |
| `session_manager.rb` | Session CRUD, retention, session hub |
