# samagotchi
agent harness which heavily relies on memory

Samagotchi is the full engine name. Chi (pronounced "chee") is the short friendly name and CLI command.

Run with:

- `bin/chi` — start the interactive REPL
- `bin/chi -p "your prompt"` — run a prompt, then stay in the REPL
- `bin/chi -p "your prompt" --non-interactive` — run a prompt, print the answer, exit
- `bin/chi --resume <session-id>` — resume a prior session in the REPL
- `bin/chi dashboard` — open the dashboard shim

## CLI Usage

Samagotchi exposes one flag that feeds a prompt (`-p`, `--prompt`) and one that
controls exit behavior (`--non-interactive`); `--resume` composes with both.

| Flag | Purpose |
|------|---------|
| `-p`, `--prompt TEXT` | Feed `TEXT` as the first turn (also prefill-equivalent; `-p` feeds **and** runs). |
| `--non-interactive` | Run a single turn then exit the REPL (sets a high iteration cap; implies `--no-interrupt`). Harmless no-op when given without `-p`. |
| `--resume SESSION_ID` | Load a prior session's history instead of creating a fresh one. |
| `--memory NAME` | Preload a memory entry into the system prompt (repeatable). |
| `--backend {native,ruby_llm}` | Choose the model backend (default: `native`). See below. |
| `--no-interrupt` | Raise the tool-call limit to 1000 iterations for long tasks. |
| `--no-default-input` | Skip prefilling the first REPL line from `SAMAGOTCHI_DEFAULT_INPUT`. |
| `-v`, `--verbose` | Print raw LLM responses and tool call/result payloads to stderr. |

**Backend selection.** `--backend ruby_llm` (or `SAMAGOTCHI_BACKEND=ruby_llm`) runs
through the ruby_llm gem backend (an OpenAI-compatible endpoint); the default
`native` path is the well-tested built-in. Both support text and agentic
tool-round completion. `--backend` exports `SAMAGOTCHI_BACKEND`, so a value in your
`~/.config/samagotchi/config.yml` sets the default and the CLI flag overrides it;
an unknown value is rejected at startup.

### Entrypoint scenarios

| Command | Behavior |
|---------|----------|
| `bin/chi` | Start the REPL with a fresh transient session. |
| `bin/chi -p "refactor this"` | Run one turn with the prompt, save the session, **stay in the REPL**. |
| `bin/chi -p "refactor this" --non-interactive` | Run one turn, save, **exit** (no REPL). |
| `bin/chi --non-interactive` | Harmless no-op exit; no session created, no error. |
| `bin/chi --resume ID` | Resume session `ID` and enter the REPL with its history. |
| `bin/chi --resume ID -p "next step" --non-interactive` | Resume `ID`, run the prompt, save, exit. |
| `bin/chi --resume ID -p "next step"` | Resume `ID`, run the prompt, **stay in the REPL** on that session. |

Notes:

- `-p` always feeds **and** runs the prompt; there is no feed-and-edit variant. To
  prefill (edit, not execute) the first REPL line, use the
  `SAMAGOTCHI_DEFAULT_INPUT` environment variable instead.
- Prompt history is persisted per session; `--resume` preserves prior messages as
  turn context (a `-p` run on a resumed session never clobbers existing history).
- Non-interactive runs (`-p` with `--non-interactive`, or bare `--non-interactive`)
  print only the final result output — no spinner, status line, or REPL.

## Architecture

Samagotchi is split into a **core engine** and a **terminal UI**. The core holds all
agent logic and can be used without any terminal rendering; the UI is a thin layer on top.
See `docs/architecture.md` for a visual overview of the layers and turn flow.

| Layer | Class | Responsibility |
|-------|-------|----------------|
| Core | `Samagotchi::Engine` | System prompt, memory injection, tool declarations, session lifecycle, the model↔tool loop (`run_turn`). No terminal coupling. |
| UI | `Samagotchi::TerminalUI` | Interactive REPL (Reline), rendering (ANSI, spinner, status line), REPL commands. Delegates all core work to an `Engine`. |
| Transport | `Samagotchi::Client`, `KernelLoop`, `Session` | HTTP transport, model↔tool loop, session data model (already clean). |
| Bridge (SSE/HTTP) | `Samagotchi::Bridge`, `SessionManager` | **Opt-in** external-client transport: an SSE read stream + HTTP POST turn-creation surface that attaches to a worker's existing `Engine` via `Engine#subscribe`. Bound `127.0.0.1`, no auth (localhost-only). Enabled by `SAMAGOTCHI_ENABLE_BRIDGE` in the forked session worker. |

- `bin/chi` (interactive) builds `TerminalUI`. `TerminalUI#run` is the single
  dispatch for the REPL, `-p`/`--prompt`, `--non-interactive`, and `--resume`: it
  builds the working session once, runs a single prompt turn when `-p` is given,
  then either exits (`--non-interactive`) or drops into the REPL carrying the
  post-turn conversation.
- `SessionManager` background workers build `Engine` directly (no terminal rendering).
- `Dashboard` is currently a minimal no-crash shim; its full rework is documented in
  `tmp/plans/20260818-000000-core-ui-separation.md`.

#### Using the core

```ruby
engine = Samagotchi::Engine.new(mode: :assist, model_name: "gemma4", memories: [])
session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd)

engine.run_turn(session, "hello", on_event: nil)   # => KernelLoop::Result (`.output`)
```

#### The `on_event` seam

`run_turn` accepts an optional `on_event:` callable that receives an event stream. It
forwards the raw `KernelLoop` events unchanged (the low-level contract) and adds a few
higher-level events so UIs get clean turn boundaries without inferring them:

- `:turn_started` — `{ session_id:, prompt: }`
- `:turn_completed` — `{ result: }` (the final `KernelLoop::Result`)
- `:turn_canceled` — `{ cancellation_reason: }`

Every event is a `Hash` with a `:type` symbol key; the sink must not raise (the Engine
rescues sink errors). A new UI (web, API, dashboard) supplies its own `on_event` and
renders whatever it needs from the stream + final `Result`. The public Engine API:

```ruby
engine.run_turn(session, prompt, on_event: nil, max_iterations: 100, cancel_controller: nil)
engine.run(session: nil, prompt: "...", on_event: nil)   # create/resume session + run
engine.system_prompt     # fully built system prompt string
engine.session           # current session (Engine owns create/resume)
```

#### Subscribing to the live stream (and the bridge)

For an **always-on** consumer (an external SSE client, a dashboard, a second UI), use
`Engine#subscribe` rather than passing `on_event:` to a single turn. It is a thread-safe,
error-isolated fan-out with a monotonic `event_seq` on every event:

```ruby
handle = engine.subscribe(observer: ->(event) { ... })   # observer receives {..., event_seq:}
engine.unsubscribe(handle: handle)
engine.session_state_snapshot   # => { status:, message_count:, last_prompt:, event_seq: }
```

`Engine#subscribe` is the seam the SSE bridge (`Samagotchi::Bridge`) rides on. The bridge
is an **optional** HTTP transport that runs **inside the forked session worker** (the same
process that already owns the `Engine`) and exposes:

- `GET  /session/:id/stream` — SSE stream of engine + kernel events, each with an `id: <event_seq>`
  cursor; resume via `Last-Event-ID` / `?from_seq=`; a `: ping` heartbeat keeps idle proxies alive;
  too-old reconnects receive a `reset` marker carrying `session_state_snapshot`.
- `POST /session/:id/turn` — fire-and-forget turn creation; returns `202` with an `enqueued_id`
  (delivery is at-least-once via the worker's file-IPC input path — it never calls `run_turn`
  across the HTTP boundary). Inspect results through the read surface, not the turn response.
- `GET  /session/:id/state` — `session_state_snapshot` (JSON).
- `OPTIONS *` — CORS preflight (`Access-Control-Allow-Origin: *`).

It is engaged only when the worker is spawned with `SAMAGOTCHI_ENABLE_BRIDGE=1`; `bin/chi`
without that flag never loads the bridge or binds a port. The per-session port is
OS-assigned (bound to `0`) and published to a `bridge.json` sidecar for client discovery.
Resume/ring-buffer state is **in-memory** (v1) — durable cross-process resume is a staged
next step, not part of v1.

## Global Config File

Chi can preload a global config file and expose those entries as environment
variables before the app boots.

Default path:

- `$XDG_CONFIG_HOME/samagotchi/config.yml`
- Fallback when `XDG_CONFIG_HOME` is unset: `~/.config/samagotchi/config.yml`

Example:

```yaml
SAMAGOTCHI_MODEL: Qwen3-14B-Instruct
LLAMA_HOST: 192.168.1.29
LLAMA_PORT: 8081
SAMAGOTCHI_THINKING_UI: spinner
```

Behavior:

- The file is optional.
- Entries must be a flat YAML mapping of scalar values.
- Real environment variables still win over config-file values.

This lets you run `bin/chi` without repeating common defaults such as model
and llama host/port on every invocation.

Note: The global config file supports both flat scalar entries (for env vars)
and nested sections like `hooks:`. Scalar entries are loaded as environment
variables; non-scalar sections are skipped by the env-loader and parsed by
their respective subsystems (e.g. the hooks system).

## Plugin Hooks

Samagotchi supports pluggable Ruby hooks that fire at key lifecycle points
during agent turns. Hooks let you add external tooling (CI checks, logging,
analytics) or in-process verification (test gates, policy checks).

### Configuration

Add a `hooks:` section to your global config file (`~/.config/samagotchi/config.yml`):

```yaml
hooks:
  hooks_dir: "~/.config/samagotchi/hooks/"
  session_start:
    - path: "analytics.rb"
      on_error: log
  before_turn:
    - path: "audit.rb"
      on_error: skip
  after_tool_call:
    - path: "metrics.rb"
      on_error: skip
```

### Plugin Format

Each plugin is a `.rb` file in the hooks directory. The class name must match
the filename (snake_case → PascalCase):

```ruby
# ~/.config/samagotchi/hooks/metrics.rb
class Metrics
  def call(event)
    # event is a Hash — you can read or mutate fields
    tool = event[:tool]
    output = event[:output]
    # ... record metrics, log, etc.
  end
end
```

The plugin class must respond to `#call(event)` — duck-typed, no base class required.

### Hook Events

| Event | When it fires | Event payload |
|-------|--------------|---------------|
| `:session_start` | First turn of the session | `{ type: :session_start, session_id: "..." }` |
| `:before_turn` | Before each turn starts | `{ type: :before_turn }` |
| `:after_turn` | After each turn completes | `{ type: :after_turn }` |
| `:before_generation` | Before LLM API call | `{ type: :before_generation, iteration: N }` |
| `:after_generation` | After LLM returns | `{ type: :after_generation, iteration: N, response: "..." }` |
| `:before_tool_call` | Before tool dispatch | `{ type: :before_tool_call, iteration: N, call: {...}, params: {...} }` |
| `:after_tool_call` | After tool execution | `{ type: :after_tool_call, iteration: N, tool: "read", output: "..." }` |
| `:session_end` | After every turn (turn-level lifecycle) | `{ type: :session_end, session_id: "..." }` |

### Error Handling

- `on_error: "skip"` (default): silently ignore hook failures
- `on_error: "log"`: emit a `warn` message to stderr

Hook failures never break the engine loop — each hook is wrapped in its own
try/catch.

### Runtime Hook Registration

You can also register hooks programmatically during a turn (they are cleared
automatically after each `run_turn`):

```ruby
engine = Samagotchi::Engine.new(mode: :assist)
engine.register_hook(:before_turn) do |event|
  puts "Turn starting..."
end
engine.run_turn(session, "Hello")
# Hooks cleared automatically — won't fire on the next turn
```

### Example Plugins

**Logging every tool call:**

```ruby
# ~/.config/samagotchi/hooks/audit.rb
class Audit
  def call(event)
    return unless event[:type] == :after_tool_call
    puts "[audit] #{event[:tool]} → #{event[:output][0..100]}"
  end
end
```

**Tracking tool call counts:**

```ruby
# ~/.config/samagotchi/hooks/tool_counter.rb
class ToolCounter
  def initialize
    @counts = Hash.new(0)
    @mutex = Mutex.new
  end

  def call(event)
    return unless event[:type] == :after_tool_call
    @mutex.synchronize { @counts[event[:tool]] += 1 }
  end

  def report
    @mutex.synchronize { @counts.dup }
  end
end
```

**Blocking turns with a policy check:**

```ruby
# ~/.config/samagotchi/hooks/safety.rb
class Safety
  def call(event)
    return unless event[:type] == :before_tool_call
    tool = event[:call][:name]
    if tool == "execute" && event[:call][:content]&.include?("rm -rf /")
      event[:call][:content] = "echo 'Safety check: dangerous command blocked'"
    end
  end
end
```

Note: `:before_tool_call` can mutate the `:call` hash to modify or intercept tool execution.

## Model Server Transport

Chi talks to a model server over HTTP and supports three transports:

- `llama_cpp` (default): llama.cpp's native `/completion` and `/models` endpoints.
- `mlx`: [mlx-lm](https://github.com/ml-explore/mlx-lm)'s OpenAI-compatible
  `/v1/completions` and `/v1/models` endpoints (Apple Silicon-native models).
- `omlx`: [oMLX](https://github.com/jundot/omlx) (the mlx-lm successor —
  continuous batching + tiered SSD KV cache) using the same `/v1/completions`
  and `/v1/models` endpoints as `mlx`.

Select the transport with `SAMAGOTCHI_SERVER_TRANSPORT` (`llama_cpp`, `mlx`, or
`omlx`). `LLAMA_HOST`/`LLAMA_PORT` are reused for all three — only the
request/response shape differs. oMLX's default server port is `8000` (not `8080`),
so point `LLAMA_PORT` at it, e.g. `LLAMA_PORT=8000`.

Example for mlx-lm:

```yaml
SAMAGOTCHI_SERVER_TRANSPORT: mlx
LLAMA_HOST: 127.0.0.1
LLAMA_PORT: 8080
```

```shell
mlx_lm.server --model mlx-community/Qwen3-14B-Instruct-4bit
```

Example for oMLX:

```yaml
SAMAGOTCHI_SERVER_TRANSPORT: omlx
LLAMA_HOST: 192.168.1.29
LLAMA_PORT: 8000
```

Both the `mlx` and `omlx` transports still send chi's own raw formatted prompt
(via `/v1/completions`) rather than a `messages` array, so the existing
per-model prompt/tool-call formatting is unaffected — neither server reapplies its
own chat template on this endpoint. Only the Gemma4 (`<|tool_call>…`) and Qwen3.6
(`[[…]]`/`<|tool_call>`) tool-call formats are in scope; GLM/Mistral/Kimi/MiniMax
formats are not parsed.

oMLX's known tool-call limitation (a stream filter that strips markup) only
affects its `/v1/chat/completions` endpoint, not the `/v1/completions` endpoint
chi uses, so raw `[[…]]`/`<|tool_call>` markers stream through untouched.

`SAMAGOTCHI_MODEL`/`/model` always drive samagotchi's own prompt-profile
selection (Gemma4 vs Qwen36 formatting); how the selector reaches the request
differs by transport:

- **mlx** (`mlx_lm.server`): the `model` field is omitted entirely — the server
  uses whatever was loaded via its own `--model` CLI flag.
- **omlx**: the server *requires* a `model` field and returns `HTTP 400`
  (`model: Field required`) without it, so samagotchi forwards the selector
  resolved to the exact id listed in the server's `/v1/models` — matched by exact
  (case-insensitive) first, then substring, then passed through unchanged. That
  resolved id is usually prefixed (e.g. `mlx-community--gemma-3-4b-it-4bit`), so a
  short selector such as `gemma-3-4b-it-4bit` is what you set in
  `SAMAGOTCHI_MODEL`. An unknown selector passes through raw and oMLX 404s,
  listing its available models; if `/v1/models` is unreachable, samagotchi falls
  back to the raw selector and lets the server decide (its own 400/404). Runtime
  model switch re-resolves each completion (the `/v1/models` id list is cached per
  client; the selector itself is re-resolved every time).

## Runtime Model Switch (Assist Mode)

In interactive assist mode, you can switch the request model without restarting:

- `/model <name>`: set a session-scoped model override.
- `/model`: show the effective model currently used for requests.
- `/model clear` (or `default`/`none`/`off`): clear the session override.
- `/models`: list model ids currently discovered by llama.cpp.

Notes:

- The switch updates the request `model` field and automatically infers/switches profile behavior.
- The command is session-scoped and does not rewrite config files.

## Tool Activity Log

Samagotchi now prints a concise, human-friendly tool activity log in normal
chat output. Each tool call is summarized as:

`tool> <action> (<tool> <param-preview>): <status>`

Examples:

- `tool> reading file (read path="README.md"): ok`
- `tool> running command (execute command="bundle exec rspec spec/..." ): error`

Parameter previews are normalized to one line and truncated to keep output concise.

This is separate from verbose mode:

- Default output shows short activity status lines only.
- `-v/--verbose` still prints detailed debug logs (raw LLM responses and full
	tool call/result payloads) to stderr.

## Debug Log File

Samagotchi also writes internal debug events to a file so you can inspect runs
without enabling `--verbose` in the terminal.

Default path:

- `./tmp/samagotchi.log`

This file receives verbose-equivalent internal events (for example raw LLM
responses and full tool call/result payloads). It is append-only and intended
for workflows like:

- `tail -f tmp/samagotchi.log`

Configuration:

- `SAMAGOTCHI_LOG_FILE`: override log file path.
- `SAMAGOTCHI_DISABLE_LOG_FILE=true` (or `1`): disable file logging.

Behavior notes:

- `--verbose` still controls stderr output only.
- File logging remains enabled even when `--verbose` is off.

## Project specific description

If an AGENT.md file is present in the project root, samagotchi injects its
contents into the system prompt under a "Project specific description:" section.

To skip loading AGENT.md, set:

`SAMAGOTCHI_SKIP_AGENT_MD=true`

## Memory Scopes

Samagotchi stores memories in two scopes:

- Project scope: `~/.config/samagotchi/memories/projects/<name>_<hash>/`
- System scope: `~/.config/samagotchi/memories`

Tool behavior:

- `memory_read`: `scope` is optional.
- If `scope` is provided (`project` or `system`), only that scope is read.
- If `scope` is omitted, read falls back from project to system.
- `memory_write`: `scope` is required (`project` or `system`). The entry name is passed via the `name` parameter (not `path` — the file tools use `path`).

At startup, the agent reads both scope indexes with blank-name memory reads
and injects them into the system prompt as `Project memories` and
`System memories`.

These startup index reads are harness-injected context assembly and are not
rendered as `tool>` activity lines.

## Llama HTTP Timeouts

Long-running llama.cpp completions can exceed Ruby's default HTTP read timeout.
Configure these environment variables to avoid premature request failures:

- `LLAMA_OPEN_TIMEOUT` (default: `10`) connection timeout in seconds.
- `LLAMA_READ_TIMEOUT` (default: `600`) response read timeout in seconds.

## Llama Model Routing

To explicitly route requests to a named model in llama.cpp, set:

- `SAMAGOTCHI_MODEL` (required): model name/id sent as the `model` field on `/completion` requests.

Profile inference uses the model name:

- names containing `qwen` map to the `qwen36` profile
- all others map to the `gemma4` profile

When `SAMAGOTCHI_MODEL` is unset or blank, Samagotchi fails fast with a clear startup/configuration error.

## Llama Network Retry Behavior

Transient network failures are retried automatically with exponential backoff.

- Default retries: `5` (up to `6` total attempts including the first call).
- Default backoff: `0.5s`, `1s`, `2s`, `4s`, `8s`.
- Retry scope: transient network errors only (timeouts, refused/reset connections, EOF/socket reachability failures).
- Cancellation (`Ctrl-C`) is never retried.

Configuration:

- `SAMAGOTCHI_RETRY_MAX` (default `5`): number of retries after the first failed attempt.
- `SAMAGOTCHI_RETRY_BASE_DELAY` (default `0.5`): backoff base delay in seconds.
- `SAMAGOTCHI_RETRY_MAX_DELAY` (default `8.0`): cap for backoff delay in seconds.

Assist-mode UX:

- While waiting, retry notices are rendered in the existing thinking spinner area as a red `network error: retrying ...` status.
- If retry attempts are exhausted, the submitted prompt is restored into the input editor so you can edit and resubmit.

## Gemma 4 Behavior Contract

This project uses canonical Gemma 4 tool-call parsing and explicit thought-context handling.

### Canonical Tool Calls Only

The kernel loop accepts canonical calls in this format:

`<|tool_call>call:NAME{...}<tool_call|>`

XML tool tags and declaration-echo parsing are intentionally not supported.

### Thought Context Rules

Thought handling follows the Gemma guidance:

- Include `<|think|>` in the system instruction to activate thinking mode.
- When thinking mode is active, the model may emit internal reasoning as `<|channel>thought ... <channel|>`.
- Standard multi-turn: prior model thoughts are stripped from conversation history before the next turn.
- Function/tool-calling exception: during a single turn that includes tool calls, thoughts are not stripped between those tool-call rounds.
- Final model output returned to the caller is thought-stripped.

In short, raw thought blocks are treated as in-turn transient context, not durable history.

### Thinking Spinner Preview

When `SAMAGOTCHI_THINKING_UI=spinner`, the preview renderer uses a deterministic layout:

- Preview lines use a fixed-width app-managed wrapper.
- Status lines use a configurable width mode (terminal-aware by default).
- Wrapping is done by the app (not terminal auto-wrap).
- The preview area always renders a fixed number of logical lines.

Configuration:

- `SAMAGOTCHI_THINKING_PREVIEW_LINES` (default `1`): number of preview lines to render under the spinner. Values are clamped to `1..3`.

Notes:

- Default behavior remains compact (`1` preview line).
- Setting `2` or `3` enables multi-line preview while keeping spinner redraw height stable.
- When a memory entry is loaded during thinking, the spinner line also shows a compact inline preview of that tool call (for example `tool: memory_read(name=...)`) for live visibility before end-of-turn tool logs.

### Thinking-Phase Cancellation

During assist-mode thinking (while the spinner is active), you can cancel an in-flight model request without exiting the process:

- Press `Ctrl-C` to cancel the active request.

Behavior notes:

- Cancellation returns control to the next prompt immediately.
- Partial model output from the canceled request is not committed as a completed model turn.

### Iteration Limit Behavior

- `max_iterations` remains a hard safety cap on tool-call rounds.
- Tool side effects that already ran before the cap are not rolled back.
- `Samagotchi::KernelLoop#run` now returns a resumable result object with the visible output plus the accumulated conversation.
- If the cap is reached while tool calls are still pending, the result is marked resumable so callers can continue from the saved conversation instead of restarting from scratch.
- In assist mode, the CLI now pauses at a compact continue prompt (`continue(yes/no/no_with_reason)>`), where `yes` (or `/continue`) resumes, `no` cancels, and `no, <explanation>` cancels while keeping the reason in conversation context.

## Persistent Prompt History

Assist mode keeps a small persistent prompt history across restarts.

- Default history file: `$XDG_STATE_HOME/samagotchi/history.json`
- XDG fallback when unset: `~/.local/state/samagotchi/history.json`
- Optional override: `SAMAGOTCHI_HISTORY_FILE=/custom/path/history.json`
- Stored entries: most recent `20` prompts
- Format: JSON array of prompt strings

Behavior details:

- Prompt history is loaded on startup before the first `>` prompt.
- Only real user prompts are persisted.
- Continue-flow inputs (`yes`, `no`, `no, <reason>`, `/continue`) are not persisted as prompts.
- In assist mode, pressing `Tab` on an `@`-prefixed token (for example `@lib/sama`) completes project file and directory paths while preserving the `@` prefix.
- Press `Tab` twice to cycle/show multiple matching candidates, similar to IRB completion behavior.
- History read/write errors are ignored so the session continues uninterrupted.

## Context Status Telemetry

The kernel can emit synthetic system telemetry messages to help the model plan under context pressure.
Telemetry messages use this prefix:

`CONTEXT_STATUS ...`

Emission behavior:

- A status is emitted when estimated usage crosses configured threshold buckets.
- Optional cadence-based updates can also be enabled every N rounds.
- This is warn-only behavior (no automatic history truncation).
- When the model server reports real `usage` fields in the stream payload, the
  telemetry uses those actual token counts (prefixed `src=server`) instead of the
  synthetic char-based estimate (`src=estimate`). The guidance text is dynamic
  and escalates with the bucket: healthy → proceed normally; moderate → prefer
  targeted/range reads; elevated → be concise, avoid large re-reads; critical →
  summarize aggressively and delegate broad work to subagents.

Configuration:

- `SAMAGOTCHI_CONTEXT_STATUS` (`true` by default): set to `false` or `0` to disable telemetry.
- `SAMAGOTCHI_CONTEXT_WINDOW_TOKENS` (default `256000`): estimated context window size.
- `SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN` (default `4.0`): heuristic ratio for char-to-token estimation.
- `SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS` (default `20,40,60,80`): comma-separated threshold percentages.
- `SAMAGOTCHI_CONTEXT_STATUS_CADENCE` (default `0`): emit every N rounds in addition to threshold crossings.

## Status Line

Assist mode can render a compact generalized status line that can include mode,
context estimate, and active memory hints.

Behavior:

- A static status line is printed before the next `>` prompt in assist mode.
- During spinner rendering, status details are rendered in the spinner block.
- When llama.cpp streaming payload includes usage fields, status prefers server-derived token telemetry (`p`, `c`, `t`) and context percent.
- If server usage fields are absent, status falls back to synthetic `CONTEXT_STATUS` estimate telemetry.
- When a memory is loaded between tool rounds, the spinner line includes a `loaded: <memory>` notification immediately after the spinner frame.
- After responses, memory details are shown via the same unified `status>` line.
- The legacy standalone `memories>` summary line is no longer emitted.

Configuration:

- `SAMAGOTCHI_STATUS_LINE` (default `on`): set to `off`, `false`, or `0` to disable status-line rendering.
- `SAMAGOTCHI_STATUS_WIDTH_MODE` (default `terminal_cap`): one of `terminal_cap`, `fixed`.
- `SAMAGOTCHI_STATUS_MAX_WIDTH` (default `160`): maximum width used by `terminal_cap`.
- `SAMAGOTCHI_STATUS_FIXED_WIDTH` (default `120`): fixed width used by `fixed` mode.

Width mode behavior:

- `terminal_cap`: use `min(terminal_columns, SAMAGOTCHI_STATUS_MAX_WIDTH)`, single-line with `+N` overflow indicator.
- `fixed`: use `SAMAGOTCHI_STATUS_FIXED_WIDTH`, single-line with `+N` overflow indicator.

Notes:

- Spinner rendering remains app-managed to keep cursor cleanup deterministic.
- Raw terminal auto-wrap is intentionally avoided in the spinner region.

## Read Tool Size Guardrails

The `read` tool now applies adaptive limits to avoid accidental context exhaustion
when opening very large files (for example, VCR cassettes).

Behavior:

- Small files: return full file content.
- Large files: return a head+tail preview plus truncation metadata.
- Extremely large files: return an error indicating the hard size limit.

Configuration:

- `SAMAGOTCHI_READ_TRUNCATE_AT_BYTES` (default `65536`): files above this size return a preview instead of full content.
- `SAMAGOTCHI_READ_PREVIEW_BYTES` (default `12288`): total preview budget split across head and tail.
- `SAMAGOTCHI_READ_HARD_MAX_BYTES` (default `2097152`): files above this size return `Error: file too large`.

Optional preview telemetry:

- `SAMAGOTCHI_READ_TELEMETRY_THRESHOLD_PCT` (default `80`): include estimated preview token impact only when preview payload is at or above this percentage of the configured context window.

Telemetry uses existing context estimation settings:

- `SAMAGOTCHI_CONTEXT_WINDOW_TOKENS`
- `SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN`

## Execute Tool Output Guardrails

The `execute` tool applies the same guardrail model to command output:

- Small stdout/stderr: returned in full.
- Large stdout/stderr: returned as head+tail previews with truncation metadata.

Configuration:

- `SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES` (default `65536`): output above this size is truncated.
- `SAMAGOTCHI_EXECUTE_PREVIEW_BYTES` (default `12288`): total preview budget split across head and tail.
- `SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT` (default `80`): include estimated output token impact only when threshold is crossed.

Implementation note:

- Shared logic lives in `lib/samagotchi/tools/output_guardrails.rb` and is used by both `read` and `execute`.
- Additional tools that can emit large payloads should rely on this shared helper for consistent behavior.

## Background Task Tools

Samagotchi supports long-running commands in the background through five task tools:

- `task_create`: start a background command and return `task_id` plus `output_path`.
- `task_get`: fetch current task metadata by id.
- `task_list`: list all tasks for the current workspace.
- `task_stop`: stop a running task by id.
- `task_wait`: wait up to 600 seconds by default for a task to finish.

Recommended workflow:

1. Create a task with `task_create`.
2. Use `task_wait` once. On timeout it returns the last 10 log lines, avoiding a separate read just to see progress.
3. For commands with a reliable completion marker, pass `done_pattern` to return when the recent log tail matches it.
4. Use `task_get` or `task_list` for nonblocking status checks, and `task_stop` if needed.

Behavior:

- Task metadata and output are persisted under `tmp/tasks/`.
- Task listing is workspace-scoped (current project only).
- `task_get` returns metadata and `output_path`; use `read` for output contents.
- `task_wait` accepts `timeout`, `tail_lines` (maximum 100), and `done_pattern` (a regular expression string).
- `task_create` accepts `env` as a JSON object string for deterministic overrides such as `PATH`; use an absolute interpreter path when that is simpler. Ruby/Bundler isolation variables remain protected.
