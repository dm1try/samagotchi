# Self map

## Start here
- `chi self` (via `execute`) prints my version, **source dir**, config path, hooks dir,
  memory dirs, sessions dir, model/host and bundles. Use its source dir; don't hunt via `which`/`gem list`/`find /`.
- My current session id is in the system prompt; resume with `chi --resume <id>`.
- My debug log is the `log` line of `chi self` (default `$XDG_STATE_HOME/samagotchi/samagotchi.log`,
  next to the sessions dir; not `~/.local/state` when `XDG_STATE_HOME` is set). One record per line,
  `<time> LEVEL tag pid= sid=<first 8 chars of my session id> event k=v`. When a turn failed, was
  cancelled or something else went wrong: `grep 'sid=<id8>' <log> | grep -v DEBUG` first; the WARN/ERROR
  records name it (`turn_failed`, `retry_exhausted`, `hook_failed`, `crashed`), `http` records show
  which host answered what.
- Sessions: each is one file, `<sessions dir>/<id>.json`. A `<id>/` dir beside it exists only
  for background/web workers (input/, notes/, output/, pid). List them with `chi sessions list`
  (`--live` for the ones a worker runs now); delete one with `chi sessions delete ID` (never by hand).
- `[CONTEXT NOTE from …]` messages are context notes (`chi note`, or another session's
  `send_note`): background, not requests. `list_sessions` + `send_note` tell another session
  something without starting a turn there; see `docs/sessions.md` "Context notes".
- `chi send -m TEXT <id>` is the other half: the text goes in as the user's message and a
  turn runs (stdin piped too = quoted context above it); see `docs/sessions.md` "Sending a message".

## Where things live (relative to the source dir)
- `docs/`: `cli.md` (flags, subcommands, REPL commands), `configuration.md` (config.yml keys,
  hosts, transports), `hooks.md` (hook events table), `memory.md`, `sessions.md`. `README.md` is
  only the quickstart.
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
