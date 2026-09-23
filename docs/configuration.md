# Configuration

## Global Config File

Chi can preload a global config file and expose those entries as environment
variables before the app boots.

Default path:

- `$XDG_STATE_HOME/samagotchi/samagotchi.log`, i.e.
  `~/.local/state/samagotchi/samagotchi.log` when `XDG_STATE_HOME` is unset
  (next to the sessions and prompt history, never inside the gem)

This file receives verbose-equivalent internal events (for example raw LLM
responses and full tool call/result payloads). It is append-only and intended
for workflows like:

- `tail -f ~/.local/state/samagotchi/samagotchi.log`

Configuration (CLI > env > config file, like every other entry):

- `log.file` / `SAMAGOTCHI_LOG_FILE` / `--log-file PATH`: another path. `~`
  and relative paths are expanded against the directory `chi` runs in.
- `log.disable` / `SAMAGOTCHI_LOG_DISABLE=true` / `--log-disable`: no file logging.

The REPL, the attached terminal and the background worker write to the same
file: a worker takes the log settings of the `chi` (or `chi web`) that
started it.

Behavior notes:

- `--verbose` still controls stderr output only.
- File logging remains enabled even when `--verbose` is off.
- An attached terminal (plain `chi`) logs which session it joined there:
  `[attached] joined session ID (N messages)`.

## Project specific description

If an AGENT.md file is present in the project root, samagotchi injects its
contents into the system prompt under a "Project specific description:" section.

To skip loading AGENT.md, set:

`SAMAGOTCHI_SKIP_AGENT_MD=true`
