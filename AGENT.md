# AGENT.md

## Project Overview: Samagotchi
Samagotchi is a self-evolving Ruby agent harness. The agent is part of the code, capable of recursive self-improvement through "Evolving Mode" using RSpec as a safety net.

Naming note: Samagotchi is the full engine name. Chi (pronounced "chee") is the friendly shorthand used in conversational and CLI contexts.

## Core Principles
- **Self-Inhabiting**: The agent's tools are the mechanisms for its own modification.
- **Persistent Cognition**: Use project memories (`~/.config/samagotchi/memories/projects/<name>_<hash>/`) and system memories (`~/.config/samagotchi/memories`) for long-term state.
- **Single Mode (Assist)**: The harness currently runs in **Assist Mode** only (human-AI collaboration). Autonomous evolution is paused; future self-modification will be re-introduced as a controlled, layer-isolated approach with a frozen core to prevent accidental self-removal.

## Operational Instructions
- **Always validate the test suite** (`bundle exec rspec`) after adding, updating, or removing functionality. Failing specs must be fixed before committing.
- When modifying code, always ensure RSpec tests pass.
- Use memory scopes explicitly: `memory_read` may omit scope (project -> system fallback), while `memory_write` must provide `scope` (`project` or `system`).
- `memory_write` accepts an optional `description` (and its scoped `index.md` is auto-maintained). Each entry is written as a managed line — `- **name** · scope · date · size — description` — with every other line preserved byte-for-byte.
- When adding new capabilities, update the relevant tools in `lib/samagotchi/tools/`.
- Always check `AGENT.md` for current operational context.
- Prefer `execute` for short commands and `task_create`/`task_wait` for long-running commands. Use `task_get`/`task_list` for nonblocking status checks and `task_stop` to stop a task.
- Let `task_wait` return its timeout tail before separately reading a task `output_path`; use `done_pattern` when the command emits a reliable completion marker.
