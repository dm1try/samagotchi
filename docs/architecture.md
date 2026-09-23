# Samagotchi Architecture

A compact visual overview of the current architecture, then the core API in prose
(see [Core and UI](#core-and-ui)).

## System map

```
                          ┌─────────────────────────────────────────┐
                          │               bin/chi                    │
                          │           (CLI entry point)             │
                          └───────────────────┬─────────────────────┘
                                              │
                     ┌──────────────────────────┴──────────────┐
                     │           TerminalUI                     │  ← REPL (Reline),
                     │   render · status line · REPL commands   │    rendering, commands
                     └──────────────────────────┬──────────────┘
                                                  │ delegates
                      ┌───────────────────────────┴───────────────────────┐
                      │                    Engine (core logic)             │
                      │   system prompt · memory injection                  │
                      │   tool declarations · session lifecycle           │
                      │   model↔tool loop — `run_turn`                    │
                      └───────────────────────────┬───────────────────────┘
                                                  │ delegates
                     ┌────────────────────────────┴──────────────┐
                     │             Web::App (Rack)                │ ← browser UI
                     │   dashboard parity · SSE poll · /api/*      │   via SessionManager file IPC
                     └───────────────────────────┬───────────────┘
                                                   │
        ┌───────────────────────────────┬──────────┴───────────────┬──────────────────┐
        │                                 │                          │                  │
  ┌─────┴─────┐                   ┌───────┴───────────┐    ┌────────┴───────┐  ┌───────┴────────┐
  │ KernelLoop │◀── drives────────▶│     Model API      │    │    Session      │  │ SessionManager │
  │  (the loop)│                   │   (LLM HTTP call)   │    │  (state,       │  │  (bg workers)  │
  └─────┬──────┘                   └─────────────────────┘    │  history)      │  └────────────────┘
      │                                                          └──────────────────┘  └────────────────┘
      │ run_turn events (turn_started, turn_completed,
      │ turn_canceled, raw KernelLoop events)
      ▼
  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │                                       Tools                                         │
  │  execute · read · edit · write · memory · web_fetch · task_create/get/list/          │
  │  task_stop/wait                                                                    │
  │  declared via tool_declarations.rb                                                 │
  └──────────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │                                   Persistence                                      │
  │   Project:  ~/.config/samagotchi/memories/projects/<name>_<hash>/                │
  │   System:   ~/.config/samagotchi/memories/                                       │
  └──────────────────────────────────────────────────────────────────────────────────┘
```

## The two-layer split

```
TerminalUI  ──  delegates  ──▶  Engine
(REPL / render / commands)         (pure logic, no terminal)
        ▲                                  │
        └────────── on_event: ◀────────────┘
             (turn_started, turn_completed,
              turn_canceled, raw KernelLoop events)
```

- **`Engine`** (`lib/samagotchi/engine.rb`) owns *all* agent logic and knows nothing
  about the terminal.
- **`TerminalUI`** (`lib/samagotchi/terminal_ui.rb`) owns the REPL and rendering; it
  delegates all core work to an `Engine`.
- The `on_event:` seam on `run_turn` exposes raw `KernelLoop` events plus the
  higher-level turn events, so any new UI can render without terminal coupling.

## Request / turn flow

```
bin/chi ─▶ TerminalUI ─▶ Engine#run_turn ─▶ KernelLoop ──┬─▶ Model API (LLM)
        (builds)          │                            └─▶ Tool call(s) ─▶ Tool
                          │                                 │
                          └── on_event: ─▶ render update ────┘
                                    (turn started / completed / canceled)
```

## Layers at a glance

| Layer | Class(es) | Responsibility |
|-------|-----------|----------------|
| Core | `Samagotchi::Engine` | System prompt, memory injection, tool declarations, session lifecycle, model↔tool loop (`run_turn`). No terminal coupling. |
| UI | `Samagotchi::TerminalUI` | REPL (Reline), rendering, REPL commands. Delegates all core work to an `Engine`. |
| Transport | `Samagotchi::Client`, `KernelLoop`, `Session` | HTTP transport, model↔tool loop, session data model. |
| Tools | `lib/samagotchi/tools/*` | Execute, read, edit, write, memory, task_*, web_fetch, plus runtime/output-guardrails. |
| Background | `Samagotchi::SessionManager` | Builds `Engine` directly (no terminal rendering) for workers. |
| Web | `Samagotchi::Web::App`, `Samagotchi::Web::Server` | Rack+WEBrick single-port `127.0.0.1:4567` (index.html + `/api/*` + SSE). Replicates dashboard via file IPC. |
| Sessions | `Samagotchi::Session`, `SessionManager` | File `sessions/<uuid>.json` + sidecar `input/`/`output/`/`pid`; retention 14d/500, `updated_at desc`, lazy sweep. |

## Entry points

- `bin/chi` interactive → builds `TerminalUI`. `TerminalUI#run` is the single dispatch
  for the REPL, `-p`/`--prompt`, `--non-interactive`, and `--resume`.
- `bin/chi --attach ID` / `--shared [--resume ID]` → `TerminalUI::AttachLauncher`: no `Engine`
  and no `OwnerLock`; finds or starts the session's worker and runs `TerminalUI::AttachedLoop`
  as a client of its Bridge (`BridgeClient#follow`, `post_turn`, `cancel`, `answer`).
- `bin/chi web` → builds `Web::Server` (Rack+WEBrick on `127.0.0.1:4567`, `--port`/`SAMAGOTCHI_WEB_PORT`, `--open`).
- `bin/chi sessions {list,prune,clean}` → retention & ordering (`Session.prune`, `updated_at desc`, dry-run, test-only).
- `bin/chi dashboard` → deprecated, use `chi web`.
- `--prompt`, `--non-interactive`, and `SessionManager` workers build `Engine` directly.

## Session retention & ordering

- **Files:** `~/.local/state/samagotchi/sessions/<uuid>.json` + `<uuid>/input|output|pid|owner.lock|bridge.json` (XDG-aware).
- **Single owner:** the process running a session's Engine (worker or in-process TUI) holds a flock on `owner.lock` (`OwnerLock`); a second owner backs off, and the web answers 409 for a TUI-owned session.
- **Status:** `status` is turn state (`idle`/`running`); liveness is the lock.
- **Retention:** 14 days / 500 cap (env `SAMAGOTCHI_SESSION_RETENTION_DAYS`/`MAX_COUNT`, optional `KEEP_STATUS`), live-owner guard, only when `*.json` present; lazy sweep ≤1/24h on `GET /api/sessions` & `Dashboard#render_list`, manual via `bin/chi sessions prune --dry-run`.
- **Ordering:** `Session.list(sort:,order:,limit:,offset:)` and `GET /api/sessions?sort=&order=&limit=&offset=` default `updated_at desc`; Web UI sort/filter/pagination.
- **Test hygiene:** `test_run` flag when `SAMAGOTCHI_ENV=test`/`RACK_ENV=test`/`CI`, targetable via `prune --test-only` / `clean`.

## Core and UI

Samagotchi is split into a **core engine** and a **terminal UI**. The core holds all
agent logic and can be used without any terminal rendering; the UI is a thin layer on top.

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
- `bin/chi --attach`/`--shared` builds no `Engine`: `TerminalUI::AttachLauncher` finds
  or starts the worker, and `TerminalUI::AttachedLoop` is a client of its Bridge
  (`BridgeClient#follow` for events, `post_turn`/`cancel`/`answer` for input). It
  renders through the same `EventRenderer` as the REPL, on an `AttachedView` that
  draws around the open Reline prompt (`AttachedScreen`).

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
