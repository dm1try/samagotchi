# AGENT.md

## Project Overview: Samagotchi
Samagotchi is a self-evolving Ruby agent harness. The agent is part of the code, capable of recursive self-improvement through "Evolving Mode" using RSpec as a safety net.

Naming note: Samagotchi is the full engine name. Chi (pronounced "chee") is the friendly shorthand used in conversational and CLI contexts.

## Architecture

Samagotchi is split into a core **Engine** (`lib/samagotchi/engine.rb`) and a
**TerminalUI** (`lib/samagotchi/terminal_ui.rb`); see the README's Architecture section.
- `Engine` owns all agent logic: system prompt, memory injection, tool declarations,
  session lifecycle, and the model↔tool loop (`Engine#run_turn`). No terminal coupling.
- `TerminalUI` owns the REPL (Reline), rendering, and REPL commands; it delegates all core
  work to an internal `Engine`.
- Background workers (`SessionManager`) and `--prompt`/`--non-interactive` build `Engine`
  directly. `bin/chi` interactive mode still builds `TerminalUI`.
- The `on_event:` seam on `run_turn` exposes raw `KernelLoop` events plus higher-level
  `:turn_started` / `:turn_completed` / `:turn_canceled` events, so any new UI can render
  without terminal coupling.

## CLI Usage (`bin/chi`)
`TerminalUI#run` is the single dispatch for the REPL, `-p`/`--prompt`, `--non-interactive`,
and `--resume`. Flag semantics (also in README's "CLI Usage" section):
- `-p`, `--prompt TEXT`: feed `TEXT` as the first turn — feeds **and** runs it.
- `--non-interactive`: run one turn then exit (high iteration cap; implies `--no-interrupt`).
  A harmless no-op when given without `-p` (no session created).
- `--resume SESSION_ID`: load a prior session's history instead of creating a fresh one;
  composes with `-p` (prompt runs on the resumed session, prior history preserved as context).
- `-p "..."` alone (no `--non-interactive`) runs one turn and **stays in the REPL**
  (breaking change vs the old one-shot-then-exit behavior).
- `--mode`, `--memory` (repeatable), `--no-interrupt`, `--no-default-input`,
  `-v`/`--verbose`, `--help` also available; `SAMAGOTCHI_DEFAULT_INPUT` prefill (edit, not run).
- `--backend {native,ruby_llm}` selects the model backend (default: `native`; also
  `SAMAGOTCHI_BACKEND`). `:native` is the default and well-tested; `:ruby_llm` is
  the gem-backed path behind `SAMAGOTCHI_BACKEND` (Phase 4). The CLI flag exports
  `SAMAGOTCHI_BACKEND` and overrides any `config.yml` value.

## Core Principles
- **Self-Inhabiting**: The agent's tools are the mechanisms for its own modification.
- **Persistent Cognition**: Use project memories (`~/.config/samagotchi/memories/projects/<name>_<hash>/`) and system memories (`~/.config/samagotchi/memories`) for long-term state.
- **Single Mode (Assist)**: The harness currently runs in **Assist Mode** only (human-AI collaboration). Autonomous evolution is paused; future self-modification will be re-introduced as a controlled, layer-isolated approach with a frozen core to prevent accidental self-removal.

## Operational Instructions
- **Always validate the test suite** (`bundle exec rspec`) after adding, updating, or removing functionality. Failing specs must be fixed before committing.
- When modifying code, always ensure RSpec tests pass.
- Use memory scopes explicitly: `memory_read` may omit scope (project -> system fallback), while `memory_write` must provide `scope` (`project` or `system`).
- `memory_write` accepts an optional `description` (and its scoped `index.md` is auto-maintained). The entry name is passed via the `name` parameter (not `path` — the file tools use `path`). Each entry is written as a managed line — `- **name** · scope · date · size — description` — with every other line preserved byte-for-byte.
- When adding new capabilities, update the relevant tools in `lib/samagotchi/tools/`.
- Always check `AGENT.md` for current operational context.
- Prefer `execute` for short commands and `task_create`/`task_wait` for long-running commands. Use `task_get`/`task_list` for nonblocking status checks and `task_stop` to stop a task.
- Let `task_wait` return its timeout tail before separately reading a task `output_path`; use `done_pattern` when the command emits a reliable completion marker.
