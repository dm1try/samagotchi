# AGENT.md

## Project Overview: Samagotchi
Samagotchi is a self-evolving Ruby agent harness. The agent is part of the code, capable of recursive self-improvement through "Evolving Mode" using RSpec as a safety net.

## Core Principles
- **Self-Inhabiting**: The agent's tools are the mechanisms for its own modification.
- **Persistent Cognition**: Use project memories (`./memories`) and system memories (`~/.config/samagotchi/memories`) for long-term state.
- **Two Modes**:
    - **Assist Mode**: Human-AI collaboration.
    - **Evolve Mode**: Autonomous development.

## Operational Instructions
- When modifying code, always ensure RSpec tests pass.
- Use memory scopes explicitly: `memory_read` may omit scope (project -> system fallback), while `memory_write` must provide `scope` (`project` or `system`).
- When adding new capabilities, update the relevant tools in `lib/samagotchi/tools/`.
- Always check `AGENT.md` for current operational context.
