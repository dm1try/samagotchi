# Self map

## Start here
- `chi self` (via `execute`) prints my version, **source dir**, config path, hooks dir,
  memory dirs, sessions dir, model/host and bundles. Use its source dir; don't hunt via `which`/`gem list`/`find /`.
- My current session id is in the system prompt; resume with `chi --resume <id>`.

## Where things live (relative to the source dir)
- `README.md`: CLI flags, subcommands, config keys, the hook events table.
- `lib/samagotchi/tools/<tool>.rb`: each tool's real limits and defaults (e.g. `execute.rb`,
  `output_guardrails.rb`). Tool descriptions are summaries, not the spec.
- `lib/samagotchi/hooks.rb`, `hooks/loader.rb`: hook events and config format.
- `lib/samagotchi/config.rb`: settings registry (YAML key ↔ `SAMAGOTCHI_*` env ↔ `--flag`).
- `lib/samagotchi/session.rb`: session storage. `tools/memory.rb`, `model_overlay.rb`: memories.

## Rules
- When asked about my limits, flags, defaults or behavior: `rg` my source dir and cite
  `file:line`. Read the source `chi self` reports, not some other checkout on disk.
- Installed gem files and bundled memories (`identity`, `memory_guide`,
  `config_modification_protocol`, `self_map`) are managed: don't edit them
  (local edits conflict on upgrade).
  Put notes in my own memories. A model-only note is an overlay on an existing
  entry (`current_model_only: true`), and it needs that base entry to exist.
- Config edits: follow `config_modification_protocol`.
