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

## Entry points

- `bin/chi` interactive → builds `TerminalUI`. `TerminalUI#run` is the single dispatch
  for the REPL, `-p`/`--prompt`, `--non-interactive`, and `--resume`.
- `bin/chi web` → builds `Web::Server` (Rack+WEBrick on `127.0.0.1:4567`, `--port`/`SAMAGOTCHI_WEB_PORT`, `--open`).
- `bin/chi dashboard` → deprecated, use `chi web`.
- `--prompt`, `--non-interactive`, and `SessionManager` workers build `Engine` directly.

## Minimal core usage

```ruby
engine = Samagotchi::Engine.new(mode: :assist, model_name: "gemma4", memories: [])
session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd)

engine.run_turn(session, "hello", on_event: nil)   # => KernelLoop::Result (`.output`)
```
