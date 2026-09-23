# CLI and REPL

## Flags

Samagotchi exposes one flag that feeds a prompt (`-p`, `--prompt`) and one that
controls exit behavior (`--non-interactive`); `--resume` composes with both.

| Flag | Purpose |
|------|---------|
| `-p`, `--prompt TEXT` | Feed `TEXT` as the first turn (also prefill-equivalent; `-p` feeds **and** runs). |
| `--non-interactive` | Run a single turn then exit the REPL (sets a high iteration cap; implies `--no-interrupt`). Harmless no-op when given without `-p`. |
| `--resume SESSION_ID` | Load a prior session's history instead of creating a fresh one. |
| `--shared` | Run the session (new, or `--resume`'s) in a background worker and attach to it. See [Sharing a session](#sharing-a-session). |
| `--attach SESSION_ID` | Attach to a session a worker is already running. |
| `--memory NAME` | Preload a memory entry into the system prompt (repeatable). Merged under the config.yml `memories:` baseline. |
| `--backend {native,ruby_llm}` | Choose the model backend (default: `native`). See below. |
| `--no-interrupt` | Raise the tool-call limit to 1000 iterations for long tasks. |
| `--no-default-input` | Skip prefilling the first REPL line from `SAMAGOTCHI_DEFAULT_INPUT`. |
| `-v`, `--verbose` | Print raw LLM responses and tool call/result payloads to stderr. |

**Backend selection.** `--backend ruby_llm` (or `SAMAGOTCHI_BACKEND=ruby_llm`) runs
through the ruby_llm gem backend (an OpenAI-compatible endpoint); the default
`native` path is the well-tested built-in. Both support text and agentic
tool-round completion. `--backend` exports `SAMAGOTCHI_BACKEND`, so a value in your
`~/.config/samagotchi/config.yml` sets the default and the CLI flag overrides it;
an unknown value is rejected at startup.

### Entrypoint scenarios

| Command | Behavior |
|---------|----------|
| `bin/chi` | Start the REPL with a fresh transient session. |
| `bin/chi -p "refactor this"` | Run one turn with the prompt, save the session, **stay in the REPL**. |
| `bin/chi -p "refactor this" --non-interactive` | Run one turn, save, **exit** (no REPL). |
| `bin/chi --non-interactive` | Harmless no-op exit; no session created, no error. |
| `bin/chi --resume ID` | Resume session `ID` and enter the REPL with its history. |
| `bin/chi --resume ID -p "next step" --non-interactive` | Resume `ID`, run the prompt, save, exit. |
| `bin/chi --resume ID -p "next step"` | Resume `ID`, run the prompt, **stay in the REPL** on that session. |

Notes:

- `-p` always feeds **and** runs the prompt; there is no feed-and-edit variant. To
  prefill (edit, not execute) the first REPL line, use the
  `SAMAGOTCHI_DEFAULT_INPUT` environment variable instead.
- Prompt history is persisted per session; `--resume` preserves prior messages as
  turn context (a `-p` run on a resumed session never clobbers existing history).
- Non-interactive runs (`-p` with `--non-interactive`, or bare `--non-interactive`)
  print only the final result output — no spinner, status line, or REPL.

### Sharing a session

A session runs in one place: the REPL's own process (`bin/chi`, `--resume`), or a
background worker (sessions started from the Web UI, or with `--shared`). A worker's
session can have any number of UIs at once: the Web UI and attached terminals
(`--shared`, `--attach`). They all see the same turns as they happen, and any of
them can send a prompt, also while a turn runs (it merges into that turn as
steering). The first answer to an `ask_user_question` wins; the other UIs close
their widget.

In an attached terminal, Ctrl-C cancels the running turn (whoever started it),
and Ctrl-D or `/exit` detaches while the worker keeps running (re-attach with
`--attach`). `/stats` works; `/model`, `/continue`, `!rollback` and `!commands`
aren't available in attached mode yet. `--attach`/`--shared` can't be combined
with `-p`, `--non-interactive`, `--model` or `--memory`. The attached view needs
reline 0.6.x to draw around the open prompt; with another version it prints
plainly. A session the REPL has open can't be shared (`--shared --resume` says so).

### Web Markdown rendering

Web responses are escaped text by default. To render completed assistant
responses as HTML, enable the renderer for the web server (it uses
`commonmarker`, which `bundle install` pulls in from the Gemfile; outside
Bundler, `gem install commonmarker`):

```sh
bin/chi web --web-markdown
```

The setting also supports `SAMAGOTCHI_WEB_MARKDOWN=true` or the global config:

```yaml
web:
  markdown: true
```

Only finalized assistant messages are rendered; user messages and live streaming
chunks remain escaped text. Generated HTML is sanitized, raw HTML in model output
is not trusted, and unsafe links are removed. If Markdown is enabled without
commonmarker installed, Chi Web keeps the normal escaped-text display and shows a
warning explaining how to install the optional gem.

## Runtime Model Switch (Assist Mode)

In interactive assist mode, you can switch the request model without restarting:

- `/model <name>`: set a session-scoped model override.
- `/model host:model` or `/model host/alias`: qualified host routing (`host:alias` expands alias bare, alias may itself be `host:model` — hybrid).
- `/model --default <name>`: set session model and persist as new default in `config.yml` (also updates `SAMAGOTCHI_DEFAULT_MODEL` for future sessions; supports `host:model` full ref).
- `/model <name> --alias <alias>`: create alias for current effective model (alias value may be bare or `host:model`).
- `/model`: show the effective model (and default when diverged: `runtime model: <effective> (default: <default>, profile=...)`).
- `/model clear` (or `default`/`none`/`off`): clear the session override, reverting to the configured default.
- `/models`: list model ids aggregated across all `hosts:` (grouped `host (host:port):` with per-host `unreachable` warnings, 60s cache, lazy — no startup prefill).

Notes:

- The switch updates the request `model` field, routes to the matching host (`HostRegistry`, `lib/samagotchi/host_registry.rb:72`), and automatically infers/switches profile behavior.
- Without `--default` the command is session-scoped and does not rewrite config files.
- With `--default` the new default is written to `~/.config/samagotchi/config.yml` (honoring `XDG_CONFIG_HOME`) and takes effect for all new sessions; the current session's effective model is also updated immediately. Bare aliases and `host:model` are both valid.
- Worker sessions inherit `hosts:` via `SAMAGOTCHI_HOSTS_JSON`.
- Recap is a generalized `hosts:` entry (`recap: {host_ref, model}`) — no separate base URL needed.

## Tool Activity Log

Samagotchi now prints a concise, human-friendly tool activity log in normal
chat output. Each tool call is summarized as:

`tool> <action> (<tool> <param-preview>): <status>`

Examples:

- `tool> reading file (read path="README.md"): ok`
- `tool> running command (execute command="bundle exec rspec spec/..." ): error`

Parameter previews are normalized to one line and truncated to keep output concise.

This is separate from verbose mode:

- Default output shows short activity status lines only.
- `-v/--verbose` still prints detailed debug logs (raw LLM responses and full
	tool call/result payloads) to stderr.

## Persistent Prompt History

Assist mode keeps a small persistent prompt history across restarts.

- Default history file: `$XDG_STATE_HOME/samagotchi/history.json`
- XDG fallback when unset: `~/.local/state/samagotchi/history.json`
- Optional override: `SAMAGOTCHI_HISTORY_FILE=/custom/path/history.json`
- Stored entries: most recent `20` prompts
- Format: JSON array of prompt strings

Behavior details:

- Prompt history is loaded on startup before the first `>` prompt.
- Only real user prompts are persisted.
- Continue-flow inputs (`yes`, `no`, `no, <reason>`, `/continue`) are not persisted as prompts.
- In assist mode, pressing `Tab` on an `@`-prefixed token (for example `@lib/sama`) completes project file and directory paths while preserving the `@` prefix.
- Press `Tab` twice to cycle/show multiple matching candidates, similar to IRB completion behavior.
- History read/write errors are ignored so the session continues uninterrupted.

## Status Line

Assist mode can render a compact generalized status line that can include mode,
context estimate, and active memory hints.

Behavior:

- A static status line is printed before the next `>` prompt in assist mode.
- During spinner rendering, status details are rendered in the spinner block.
- When llama.cpp streaming payload includes usage fields, status prefers server-derived token telemetry (`p`, `c`, `t`) and context percent.
- If server usage fields are absent, status falls back to the `:context_status` estimate telemetry.
- When a memory is loaded between tool rounds, the spinner line includes a `loaded: <memory>` notification immediately after the spinner frame.
- After responses, memory details are shown via the same unified `status>` line.
- The legacy standalone `memories>` summary line is no longer emitted.

Configuration:

- `SAMAGOTCHI_STATUS_LINE` (default `on`): set to `off`, `false`, or `0` to disable status-line rendering.
- `SAMAGOTCHI_STATUS_WIDTH_MODE` (default `terminal_cap`): one of `terminal_cap`, `fixed`.
- `SAMAGOTCHI_STATUS_MAX_WIDTH` (default `160`): maximum width used by `terminal_cap`.
- `SAMAGOTCHI_STATUS_FIXED_WIDTH` (default `120`): fixed width used by `fixed` mode.

Width mode behavior:

- `terminal_cap`: use `min(terminal_columns, SAMAGOTCHI_STATUS_MAX_WIDTH)`, single-line with `+N` overflow indicator.
- `fixed`: use `SAMAGOTCHI_STATUS_FIXED_WIDTH`, single-line with `+N` overflow indicator.

Notes:

- Spinner rendering remains app-managed to keep cursor cleanup deterministic.
- Raw terminal auto-wrap is intentionally avoided in the spinner region.

## Thinking Spinner Preview

When `SAMAGOTCHI_THINKING_UI=spinner`, the preview renderer uses a deterministic layout:

- Preview lines use a fixed-width app-managed wrapper.
- Status lines use a configurable width mode (terminal-aware by default).
- Wrapping is done by the app (not terminal auto-wrap).
- The preview area always renders a fixed number of logical lines.

Configuration:

- `SAMAGOTCHI_THINKING_PREVIEW_LINES` (default `1`): number of preview lines to render under the spinner. Values are clamped to `1..3`.

Notes:

- Default behavior remains compact (`1` preview line).
- Setting `2` or `3` enables multi-line preview while keeping spinner redraw height stable.
- When a memory entry is loaded during thinking, the spinner line also shows a compact inline preview of that tool call (for example `tool: memory_read(name=...)`) for live visibility before end-of-turn tool logs.

## Thinking-Phase Cancellation

During assist-mode thinking (while the spinner is active), you can cancel an in-flight model request without exiting the process:

- Press `Ctrl-C` to cancel the active request.

Behavior notes:

- Cancellation returns control to the next prompt immediately.
- Partial model output from the canceled request is not committed as a completed model turn.

## Iteration Limit Behavior

- `max_iterations` remains a hard safety cap on tool-call rounds.
- Tool side effects that already ran before the cap are not rolled back.
- `Samagotchi::KernelLoop#run` now returns a resumable result object with the visible output plus the accumulated conversation.
- If the cap is reached while tool calls are still pending, the result is marked resumable so callers can continue from the saved conversation instead of restarting from scratch.
- In assist mode, the CLI now pauses at a compact continue prompt (`continue(yes/no/no_with_reason)>`), where `yes` (or `/continue`) resumes, `no` cancels, and `no, <explanation>` cancels while keeping the reason in conversation context.
