# Samagotchi Architecture

A compact visual overview of the current architecture. Prose version lives in the
README's **Architecture** section.

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

## Minimal core usage

```ruby
engine = Samagotchi::Engine.new(mode: :assist, model_name: "gemma4", memories: [])
session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd)

engine.run_turn(session, "hello", on_event: nil)   # => KernelLoop::Result (`.output`)
```
