# samagotchi
agent harness which heavily relies on memory

Samagotchi is the full engine name. Chi (pronounced "chee") is the short friendly name and CLI command.

Run with:

- `bin/chi` — start the interactive REPL
- `bin/chi -p "your prompt"` — run a prompt, then stay in the REPL
- `bin/chi -p "your prompt" --non-interactive` — run a prompt, print the answer, exit
- `bin/chi --resume <session-id>` — resume a prior session in the REPL
- `bin/chi --shared [--resume <session-id>]` — run the session in a background worker and attach the terminal to it, so the Web UI (or another terminal) can share it
- `bin/chi --attach <session-id>` — attach the terminal to a session a worker is already running (e.g. one started from the Web UI)
- `bin/chi web [--port 4567] [--open]` — start the Web UI (single localhost port session control plane)
- `bin/chi web --web-markdown` — opt in to sanitized Markdown rendering for completed assistant messages
- `bin/chi sessions list|prune|clean` — manage persisted sessions (retention + ordering, see below)
- `bin/chi self` — print version, source dir (checkout or installed gem), config/memory/session paths, model/host and bundles

## Documentation

- [CLI and REPL](docs/cli.md): flags, sharing a session, web UI, `/model`, status line
- [Configuration](docs/configuration.md): `config.yml`, hosts, model server transports, timeouts, retries, logs
- [Memory](docs/memory.md): scopes and model-specific overlays
- [Sessions](docs/sessions.md): storage, retention, `chi sessions`
- [Hooks](docs/hooks.md): plugin hooks and bundle hooks
- [Architecture](docs/architecture.md): Engine, TerminalUI, bridge, web
- Internals: [Gemma 4 contract](docs/internals/gemma4-contract.md), [context telemetry](docs/internals/context-telemetry.md), [tool guardrails](docs/internals/tool-guardrails.md), [background tasks](docs/internals/background-tasks.md)
