# samagotchi
agent harness which heavily relies on memory

Samagotchi is the full engine name. Chi (pronounced "chee") is the short friendly name and CLI command.

Run with:

- `bin/chi` — start the interactive REPL
- `bin/chi -p "your prompt"` — run a prompt, then stay in the REPL
- `bin/chi -p "your prompt" --non-interactive` — run a prompt, print the answer, exit
- `bin/chi --resume <session-id>` — resume a prior session in the REPL
- `bin/chi web [--port 4567] [--open]` — start the Web UI (single localhost port session control plane)
- `bin/chi web --web-markdown` — opt in to sanitized Markdown rendering for completed assistant messages
- `bin/chi sessions list|prune|clean` — manage persisted sessions (retention + ordering, see below)

## CLI Usage

Samagotchi exposes one flag that feeds a prompt (`-p`, `--prompt`) and one that
controls exit behavior (`--non-interactive`); `--resume` composes with both.

| Flag | Purpose |
|------|---------|
| `-p`, `--prompt TEXT` | Feed `TEXT` as the first turn (also prefill-equivalent; `-p` feeds **and** runs). |
| `--non-interactive` | Run a single turn then exit the REPL (sets a high iteration cap; implies `--no-interrupt`). Harmless no-op when given without `-p`. |
| `--resume SESSION_ID` | Load a prior session's history instead of creating a fresh one. |
| `--memory NAME` | Preload a memory entry into the system prompt (repeatable). Merged under the config.yml `memories:` baseline. |
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

### Web Markdown rendering

Web responses are escaped text by default. To render completed assistant
responses as HTML, install the optional renderer and enable it for the web
server:

```sh
gem install kramdown
bin/chi web --web-markdown
```

The setting also supports `SAMAGOTCHI_WEB_MARKDOWN=true` or the global config:

```yaml
web:
  markdown: true
```

Only finalized assistant messages are rendered; user messages and live streaming
chunks remain escaped text. Generated HTML is sanitized, raw HTML in model output
is not trusted, and unsafe links are removed. If Markdown is enabled without
Kramdown installed, Chi Web keeps the normal escaped-text display and shows a
warning explaining how to install the optional gem.

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
| Bridge (SSE/HTTP) | `Samagotchi::Bridge`, `SessionManager` | The **single live client transport**: an SSE read stream + HTTP POST turn/cancel/answer surface that attaches to a worker's existing `Engine` via `Engine#subscribe`. Every session worker starts it (bound `127.0.0.1`, no auth, localhost-only). |
| Web (Rack) | `Samagotchi::Web::App`, `SessionManager` | Single-port `127.0.0.1:4567` control plane via `rack`+`webrick` (serve `index.html` + `/api/*`; `/stream` proxies each session's Bridge). `bin/chi web` entrypoint. |
| Sessions | `Samagotchi::Session`, `SessionManager` | File-based `~/.local/state/samagotchi/sessions/<uuid>.json` + sidecar `input/`/`output/`/`pid`; retention (14d/500) + ordering (`updated_at desc`). |

- `bin/chi` (interactive) builds `TerminalUI`. `TerminalUI#run` is the single
  dispatch for the REPL, `-p`/`--prompt`, `--non-interactive`, and `--resume`: it
  builds the working session once, runs a single prompt turn when `-p` is given,
  then either exits (`--non-interactive`) or drops into the REPL carrying the
  post-turn conversation.
- `SessionManager` background workers build `Engine` directly (no terminal rendering).

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
rescues sink errors). A new UI (web, API) supplies its own `on_event` and
renders whatever it needs from the stream + final `Result`. The public Engine API:

```ruby
engine.run_turn(session, prompt, on_event: nil, max_iterations: 100, cancel_controller: nil)
engine.run(session: nil, prompt: "...", on_event: nil)   # create/resume session + run
engine.system_prompt     # fully built system prompt string
engine.session           # current session (Engine owns create/resume)
```

#### Subscribing to the live stream (and the bridge)

For an **always-on** consumer (an external SSE client, a second UI), use
`Engine#subscribe` rather than passing `on_event:` to a single turn. It is a thread-safe,
error-isolated fan-out with a monotonic `event_seq` on every event:

```ruby
handle = engine.subscribe(observer: ->(event) { ... })   # observer receives {..., event_seq:}
engine.unsubscribe(handle: handle)
engine.session_state_snapshot   # => { status:, message_count:, last_prompt:, event_seq: }
```

`Engine#subscribe` is the seam the SSE bridge (`Samagotchi::Bridge`) rides on. The bridge
is the **single live transport** and runs **inside the forked session worker** (the same
process that already owns the `Engine`); every worker starts it, and it exposes:

- `GET  /session/:id/stream` — SSE stream of engine + kernel events, each with an `id: <event_seq>`
  cursor; resume via `Last-Event-ID` / `?from_seq=`; a `: ping` heartbeat keeps idle proxies alive;
  too-old reconnects receive a `reset` marker carrying `session_state_snapshot`.
- `POST /session/:id/turn` — fire-and-forget turn creation; returns `202` with an `enqueued_id`
  (delivery is at-least-once via the worker's file-IPC input path — it never calls `run_turn`
  across the HTTP boundary). Inspect results through the read surface, not the turn response.
- `GET  /session/:id/state` — `session_state_snapshot` (JSON).
- `OPTIONS *` — CORS preflight (`Access-Control-Allow-Origin: *`).

The per-session port is OS-assigned (bound to `0`) and published to a `bridge.json` sidecar
for client discovery. `chi web`'s `GET /api/sessions/:id/stream` proxies this bridge
(503 `not_live` when the worker is not running; full history of any session is served by
`GET /api/sessions/:id/output`). Resume/ring-buffer state is **in-memory** (v1) — durable
cross-process resume is a staged next step, not part of v1.

## Session Management & Retention

Sessions are plain files — no DB. Each session is `~/.local/state/samagotchi/sessions/<uuid>.json` (XDG-aware via `XDG_STATE_HOME`) plus a sidecar dir `<uuid>/` with `input/`/`output/`/`pid`/`bridge.json` (`Session.session_dir`).

**Retention (file-based, opt-out via env):**

| Env | Default | Purpose |
|-----|---------|---------|
| `SAMAGOTCHI_SESSION_RETENTION_DAYS` | `14` (`0`=forever) | Delete if `updated_at` older than N days |
| `SAMAGOTCHI_SESSION_MAX_COUNT` | `500` (`0`=uncapped) | Keep newest N, prune overflow |
| `SAMAGOTCHI_SESSION_KEEP_STATUS` | `running` | CSV of statuses never auto-pruned |
| `SAMAGOTCHI_SESSION_SWEEP_INTERVAL_HOURS` | `24` | Throttle lazy sweep |

A session is deleted if **expired by age OR overflow by count** (unless `keep_status` or live-worker guard). Orphan dirs without a `*.json` are never deleted. Deletion removes both `*.json` and sidecar dir atomically. Set both `DAYS=0` and `MAX=0` to retain forever.

**Lazy sweep:** automatic prune runs at most once per 24h on `GET /api/sessions` (Web). No background thread or cron. Manual prune is always available.

**CLI:**

```sh
bin/chi sessions list [--sort updated_at|created_at] [--order desc|asc] [--limit N]
bin/chi sessions prune [--dry-run] [--days N] [--keep N] [--keep-status running,...] [--test-only]
bin/chi sessions clean [--dry-run] [--days N] [--keep N]   # alias to prune --test-only
```

Examples:

```sh
bin/chi sessions list --sort updated_at --order desc --limit 20
bin/chi sessions prune --dry-run --days 14 --keep 500
bin/chi sessions prune --days 14 --keep 500          # actually delete
bin/chi sessions clean --dry-run --days 7            # only test sessions
```

`--dry-run` is the safe preview (your choice #5). Web has no prune endpoint; use the CLI.

**Ordering:**

- `Session.list` / `SessionManager.list_sessions` / `GET /api/sessions?sort=&order=&limit=&offset=` default to `updated_at desc` (newest activity first). Also supports `created_at`, `asc`. `X-Total-Count` header when paginated.
- Web UI (`bin/chi web`) has sort select (Updated/Created), order toggle (Desc/Asc), filter input (preview/id/status), `localStorage` persistence, and pagination (first 100 + Show all) to avoid 10k-row jank.
- The web frontend is a zero-build ES-module stack in `lib/samagotchi/web/public/`: `data.js` (retrieval + typed SSE `openStream` with an `onStreamError` backoff retry), `app.js` (presentation/state, retry cap + terminal stream-error state), `format.js` (pure formatters such as `previewOf`). Unit-tested via `npm test` (`node --test spec/web/public/*.test.js`).
- Selecting a session in the web UI eager-resumes its worker: `GET /api/sessions/:id` spawns the worker + bridge when stopped (no `/turn` needed to wake it), and `/stream` briefly waits for a freshly-spawned bridge before answering. A caught-up SSE reconnect holds the stream open; `reset` markers are only sent for reconnects behind the ring window (or across a worker restart).

**Test-session hygiene:**

- New sessions set `test_run:true` when `SAMAGOTCHI_ENV=test` or `RACK_ENV=test` or `CI` is set (explicit flag, `metadata_version` 2). Old sessions without the flag load as `test_run:false`.
- Future `CI`/test runs are tagged and obey the same retention but can be targeted via `bin/chi sessions prune --test-only` or `bin/chi sessions clean`.
- For ad-hoc manual QA use `XDG_STATE_HOME=/tmp/chi-test-$USER bin/chi ...` to isolate from real state.

## Global Config File

Chi can preload a global config file and expose those entries as environment
variables before the app boots.

Default path:

- `$XDG_CONFIG_HOME/samagotchi/config.yml`
- Fallback when `XDG_CONFIG_HOME` is unset: `~/.config/samagotchi/config.yml`

Example:

```yaml
SAMAGOTCHI_DEFAULT_MODEL: Qwen3-14B-Instruct
server:
  host: 192.168.1.29
  port: 8081
SAMAGOTCHI_THINKING_UI: spinner

# Multi-host (optional): aggregated /models and per-model routing.
# Bare SAMAGOTCHI_DEFAULT_MODEL uses the default host; host:model pins to a host.
# Transport per host overrides SAMAGOTCHI_SERVER_TRANSPORT.
hosts:
  main:
    host: localhost
    port: 8080
    transport: llama_cpp
  recap-box:
    host: 192.168.1.50
    port: 8080

# Idle recap now generalized via host_ref (preferred) or base_url fallback.
recap:
  host_ref: recap-box
  model: gemma4-small
  # inactivity: 180
  # timeout: 30
  # min_user_turns: 2

model_aliases:
  small: gemma4-small
  tiny: recap-box:gemma4-small  # alias may be bare or host:model (hybrid)

# Baseline memories preloaded into the system prompt (same shape as --memory).
# CLI --memory entries are appended after these, deduped.
memories:
  - system/user_preferences
  - project/feature-env-template
```

Behavior:

- The file is optional.
- Top level is a YAML mapping of scalar env overrides plus nested sections.
- Real environment variables still win over config-file values.
- Workers inherit hosts via `SAMAGOTCHI_HOSTS_JSON` propagated through `SessionManager.spawn_options`.

This lets you run `bin/chi` without repeating common defaults such as model
and llama host/port on every invocation.

Note: The global config file supports both flat scalar entries (for env vars)
and nested sections like `hosts:`, `recap:`, `hooks:`, `model_aliases:`,
`memories:`. Scalar entries are loaded as environment
variables; non-scalar sections are skipped by the env-loader and parsed by
their respective subsystems (e.g. the hooks system, `HostRegistry`). The
`memories:` list is the persistent baseline for preloaded memory entries —
the same name shape as `--memory` (bare name or `scope/name`), merged under
any per-run `--memory` values (config baseline first, deduped).

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

**Blocking tool calls with a guardrail (veto):**

```ruby
# ~/.config/samagotchi/hooks/safety.rb
class Safety
  def call(event)
    return unless event[:type] == :before_tool_call
    tool = event[:call][:name]
    if tool == "execute" && event[:call][:content]&.include?("rm -rf /")
      event[:blocked] = true
      event[:block_reason] = "dangerous command denied by policy"
    end
  end
end
```

When `event[:blocked] = true`, the tool is not dispatched. The model receives `Error: blocked by guardrail: <reason>` as the tool output (with `block_reason` or default `blocked by hook`), activity status is `blocked`, and `:after_tool_call` still fires. Only `:before_tool_call` supports veto — `blocked` is ignored on other hooks.

**Mutating params (legacy):**

```ruby
# ~/.config/samagotchi/hooks/safety_legacy.rb
class SafetyLegacy
  def call(event)
    return unless event[:type] == :before_tool_call
    tool = event[:call][:name]
    if tool == "execute" && event[:call][:content]&.include?("rm -rf /")
      event[:call][:content] = "echo 'Safety check: dangerous command blocked'"
    end
  end
end
```

Note: `:before_tool_call` can mutate the `:call` hash to modify tool execution, or set `blocked`/`block_reason` to veto it entirely.

### Bundle Hooks (unified workflow bundle)

Bundles can ship executable guardrails alongside memories. A bundle with hooks lives as a directory with a `hooks/` subdirectory (flat, basename-keyed):

```
my-bundle/
  manifest.yml
  identity.md
  hooks/
    guardrails.rb   # class Guardrails; def call(event); ...; end; end
    audit.rb
```

`manifest.yml` may carry an optional `hooks:` map (both `files:` and `hooks:` are optional; a bundle may carry only one):

```yaml
name: code-review-workflow
version: 1.0.0
scope: project
files:
  identity.md: sha256:abc...
hooks:
  guardrails.rb:
    sha256: 1234...
    event: before_tool_call
    on_error: fail_closed   # default for before_tool_call
    priority: 10
  audit.rb:
    sha256: 5678...
    event: after_tool_call
    on_error: log
    priority: 100
trust_level: reviewed        # reviewed | experimental (default)
```

Notes:

- Hook key = basename (flat under `hooks/`). No subdirs in v1.
- `event` is required for auto-registration; a hook with no event is skipped.
- `sha256` is integrity (not authenticity). No signing in v1.
- Hook code is the bundle author's source of truth: on upgrade, hooks are overwritten; if the installed file was locally modified, a warning is emitted (`was locally modified; overwriting`).
- A raising `:before_tool_call` guardrail respects `on_error`: `fail_closed` sets `event[:blocked]=true` (fail-closed), `log` warns, `skip` is silent.
- Ordering: bundle hooks fire by `(priority, bundle_name, hook_name)` (lower priority first), then plain `config.yml` hooks in registration order.
- Installing a bundle executes its hook code at `Engine` startup. Only install bundles you trust, as you would a gem. Hooks are **not** executed at install time (copy-only); they are `module_eval`'d at `Engine.new` inside per-bundle `Samagotchi::Bundles::<name>` namespaces (no top-level `require` collisions). Keep hook files side-effect-free at load time; do work in `#call` — top-level side effects (require, IO, `at_exit`, global assignment) run once per `Engine.new` (class redefinition is idempotent).

Lifecycle:

- `bin/chi bundle install <source>` copies `hooks/*.rb` to `~/.config/samagotchi/memories/.bundles/<name>/hooks/` and persists metadata + `trust_level` + `source_commit` (git HEAD) to provenance.
- `Engine.new` loads `config.yml` hooks first, then bundle hooks via `Provenance.each_installed_holding_hooks` → `Hooks::BundleLoader.load`. Bundle hooks are process-scoped (they survive the per-turn `clear_hooks`; only plain hooks are cleared). Experimental bundles emit a one-line startup warning.
- `bin/chi bundle status`, `diff`, `uninstall`, `build` are hook-aware (counts, metadata, removal).

## Model Server Transport

Chi talks to a model server over HTTP and supports three transports:

- `llama_cpp` (default): llama.cpp's native `/completion` and `/models` endpoints.
- `mlx`: [mlx-lm](https://github.com/ml-explore/mlx-lm)'s OpenAI-compatible
  `/v1/completions` and `/v1/models` endpoints (Apple Silicon-native models).
- `omlx`: [oMLX](https://github.com/jundot/omlx) (the mlx-lm successor —
  continuous batching + tiered SSD KV cache) using the same `/v1/completions`
  and `/v1/models` endpoints as `mlx`.

Select the transport with `SAMAGOTCHI_SERVER_TRANSPORT` (`llama_cpp`, `mlx`, or
`omlx`). `SAMAGOTCHI_SERVER_HOST`/`SAMAGOTCHI_SERVER_PORT` are reused for all three —
only the request/response shape differs. oMLX's default server port is `8000` (not
`8080`), so point `SAMAGOTCHI_SERVER_PORT` at it, e.g. `SAMAGOTCHI_SERVER_PORT=8000`.
With `hosts:` each entry may set `transport: llama_cpp|mlx|omlx` to override the
global transport per host (`lib/samagotchi/host_registry.rb:25`).

Example for mlx-lm:

```yaml
SAMAGOTCHI_SERVER_TRANSPORT: mlx
server:
  host: 127.0.0.1
  port: 8080
```

```shell
mlx_lm.server --model mlx-community/Qwen3-14B-Instruct-4bit
```

Example for oMLX:

```yaml
SAMAGOTCHI_SERVER_TRANSPORT: omlx
server:
  host: 192.168.1.29
  port: 8000
```

Both the `mlx` and `omlx` transports still send chi's own raw formatted prompt
(via `/v1/completions`) rather than a `messages` array, so the existing
per-model prompt/tool-call formatting is unaffected — neither server reapplies its
own chat template on this endpoint. Only the Gemma4 (`<|tool_call>…`) and Qwen3.6
(`[[…]]`/`<|tool_call>`) tool-call formats are in scope; GLM/Mistral/Kimi/MiniMax
formats are not parsed.

For an OpenAI Chat Completions server such as [Splash](https://github.com/incoai/splash),
select the `ruby_llm` backend instead of an HTTP transport:

```yaml
backend: ruby_llm
default:
  model: incoai/Qwen3.6-35B-A3B-Splash
hosts:
  splash:
    host: 192.168.1.29
    port: 8000
```

`--backend ruby_llm` takes precedence over `SAMAGOTCHI_BACKEND` and the config
file. RubyLLM reuses the host selected for the active model, derives its OpenAI
base as `http://HOST:PORT/v1`, and posts messages plus function schemas to
`/v1/chat/completions`. This works with Splash and with llama.cpp servers that
expose the OpenAI-compatible chat endpoint. In verbose mode, Chi prints a safe
endpoint diagnostic such as
`[samagotchi] backend=ruby_llm POST http://HOST:PORT/v1/chat/completions`; the
request body is intentionally not logged. The interactive REPL, `--prompt`,
workers, and resumed sessions all use the selected backend. Without the backend
flag, Chi keeps using the native `/completion`, `/v1/completions`, or oMLX
transport path.

To manually verify a live RubyLLM tool round trip, run the gated integration
spec. It requires the model to call `execute` and return the current UTC date:

```shell
SAMAGOTCHI_INTEGRATION=1 \
SAMAGOTCHI_SERVER_HOST=192.168.1.29 SAMAGOTCHI_SERVER_PORT=8000 \
SAMAGOTCHI_DEFAULT_MODEL=incoai/Qwen3.8-27B-Splash \
bundle exec rspec spec/integration/ruby_llm_backend_spec.rb -fd < /dev/null
```

The same test works against a llama.cpp OpenAI-compatible server by changing
the host, port, and model values. The test is skipped unless
`SAMAGOTCHI_INTEGRATION=1` is set.

oMLX's known tool-call limitation (a stream filter that strips markup) only
affects its `/v1/chat/completions` endpoint, not the `/v1/completions` endpoint
chi uses, so raw `[[…]]`/`<|tool_call>` markers stream through untouched.

`SAMAGOTCHI_DEFAULT_MODEL` (config default) and `/model` (runtime effective) drive samagotchi's own prompt-profile
selection (Gemma4 vs Qwen36 formatting); the status line and `/model` output always render the runtime effective model (showing default when diverged). How the selector reaches the request
differs by transport:

- **mlx** (`mlx_lm.server`): the `model` field is omitted entirely — the server
  uses whatever was loaded via its own `--model` CLI flag.
- **omlx**: the server *requires* a `model` field and returns `HTTP 400`
  (`model: Field required`) without it, so samagotchi forwards the selector
  resolved to the exact id listed in the server's `/v1/models` — matched by exact
  (case-insensitive) first, then substring, then passed through unchanged. That
  resolved id is usually prefixed (e.g. `mlx-community--gemma-3-4b-it-4bit`), so a
  short selector such as `gemma-3-4b-it-4bit` is what you set in
  `SAMAGOTCHI_DEFAULT_MODEL`. An unknown selector passes through raw and oMLX 404s,
  listing its available models; if `/v1/models` is unreachable, samagotchi falls
  back to the raw selector and lets the server decide (its own 400/404). Runtime
  model switch re-resolves each completion (the `/v1/models` id list is cached per
  client; the selector itself is re-resolved every time).

## Runtime Model Switch (Assist Mode)

In interactive assist mode, you can switch the request model without restarting:

- `/model <name>`: set a session-scoped model override.
- `/model host:model` or `/model host/alias`: qualified host routing (`host:alias` expands alias bare, alias may itself be `host:model` — hybrid).
- `/model --default <name>`: set session model and persist as new default in `config.yml` (also updates `SAMAGOTCHI_DEFAULT_MODEL` for future sessions; supports `host:model` full ref).
- `/model <name> --alias <alias>`: create alias for current effective model (alias value may be bare or `host:model`).
- `/model`: show the effective model (and default when diverged: `runtime model: <effective> (default: <default>, profile=...)`).
- `/model clear` (or `default`/`none`/`off`): clear the session override, reverting to the configured default.
- `/models`: list model ids aggregated across all `hosts:` (grouped `host (host:port):` with per-host `unreachable` warnings, 60s cache, lazy — no startup prefill).

Notes:

- The switch updates the request `model` field, routes to the matching host (`HostRegistry`, `lib/samagotchi/host_registry.rb:72`), and automatically infers/switches profile behavior.
- Without `--default` the command is session-scoped and does not rewrite config files.
- With `--default` the new default is written to `~/.config/samagotchi/config.yml` (honoring `XDG_CONFIG_HOME`) and takes effect for all new sessions; the current session's effective model is also updated immediately. Bare aliases and `host:model` are both valid.
- Worker sessions inherit `hosts:` via `SAMAGOTCHI_HOSTS_JSON`.
- Recap is a generalized `hosts:` entry (`recap: {host_ref, model}`) — no separate base URL needed.

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
- `memory_write`: `scope` is required (`project` or `system`). The entry name is passed via the `name` parameter (not `path` — the file tools use `path`). On success, the return value includes the full file path, so you can use the `edit` tool directly for targeted updates.

#### Model-Specific Memory Overlays

Each memory entry may have a companion file named `<name>.<model-key>.md` in the same scope directory. When the entry is read under a matching model, the overlay body is appended automatically, separated by the standard `---` separator with a `Model-specific guidance (<key>):` header.

- **Key derivation**: The harness normalizes the full model name (lowercase, replace non-alphanumeric with `-`, squeeze dashes) to derive the file key. For example, `qwen3.6-35b-a3b` → `qwen3-6-35b-a3b`.
- **Saving overlays**: Pass `current_model_only: true` to `memory_write` (the harness resolves the model key automatically). This writes the content as `<name>.<model-key>.md` and skips index maintenance.
- **Dormancy**: Overlays are only active under the matching model key; other models see the base entry only.
- **Invariant**: The base entry is the contract. Overlays only add model-specific guidance and never contradict the base protocol.


At startup, the agent reads both scope indexes with blank-name memory reads
and injects them into the system prompt as `Project memories` and
`System memories`.

These startup index reads are harness-injected context assembly and are not
rendered as `tool>` activity lines.

## Llama HTTP Timeouts

Long-running llama.cpp completions can exceed Ruby's default HTTP read timeout.
Configure these environment variables to avoid premature request failures:

- `SAMAGOTCHI_SERVER_OPEN_TIMEOUT` (default: `10`) connection timeout in seconds.
- `SAMAGOTCHI_SERVER_READ_TIMEOUT` (default: `600`) response read timeout in seconds.

## Llama Model Routing

To explicitly route requests to a named model in llama.cpp, set:

- `SAMAGOTCHI_DEFAULT_MODEL` (required): model name/id sent as the `model` field on `/completion` requests.

Profile inference uses the model name:

- names containing `qwen` map to the `qwen36` profile
- all others map to the `gemma4` profile

When `SAMAGOTCHI_DEFAULT_MODEL` is unset or blank, Samagotchi fails fast with a clear startup/configuration error.

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

The kernel surfaces context-usage telemetry to UI consumers (status line,
web/SSE clients) as a `:context_status` stream event. It is no longer injected
into the model's conversation. The event carries a `status` string using this
prefix:

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
- If server usage fields are absent, status falls back to the `:context_status` estimate telemetry.
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
