# samagotchi

An agent harness that relies heavily on memory. Samagotchi is the engine; chi
(pronounced "chee") is its short name and CLI command.

## Requirements

- Ruby 3.0+ and Bundler
- A model server: [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server`
  by default; mlx-lm, oMLX and OpenAI-compatible servers also work
  (see [Configuration](docs/configuration.md#model-server-transport))

## Install

```sh
git clone https://github.com/dm1try/samagotchi && cd samagotchi
bundle install
bin/chi self        # version, source dir, config and memory paths
```

To put `chi` on your PATH, install it as a local gem: `bundle exec rake gem:install`.

## Configure

Create `~/.config/samagotchi/config.yml` (or `$XDG_CONFIG_HOME/samagotchi/config.yml`):

```yaml
default:
  model: gemma4            # the model id your server serves (required)
server:
  host: localhost
  port: 8080
```

Other settings (multiple hosts, transports, timeouts, the idle recap) are in
[Configuration](docs/configuration.md).

## Use

```sh
bin/chi                                       # interactive session the web UI can join too
bin/chi --no-shared                           # the plain in-process REPL
bin/chi -p "explain lib/" --non-interactive   # one turn, print the answer, exit
bin/chi --resume <session-id>                 # continue a saved session
bin/chi web --open                            # web UI on http://127.0.0.1:4567
bin/chi sessions list                         # saved sessions
pbpaste | bin/chi note --source slack <id>    # background context for a session (no turn)
pbpaste | bin/chi send -m "same bug?" <id>    # a message to a session, the clipboard quoted above it
```

`@shot.png` in a prompt (or a pasted/dropped image in the web UI) shows the model an image, when it can see them; see [Images](docs/cli.md#images).

`/model` switches models, Ctrl-C cancels a turn, and Ctrl-D or `/detach` detaches (the session keeps running; `chi --attach ID` comes back). `/exit` detaches and stops the session's worker too, unless something still needs it (a running turn, another UI); `chi --resume ID` picks the conversation up again.

### Context notes

`chi note` pushes text into one or more sessions as background, not as a
prompt: nothing runs, and the model sees it on its next turn framed as a note
(`[CONTEXT NOTE from slack, 14:02] … [END NOTE]`) that it uses when relevant and
never takes orders from. The web and the attached terminal show it as a dim
"note from …" line. `chi sessions list --live --format tsv` lists the sessions
a note reaches (`id<TAB>description`). Agents can do the same: `list_sessions`
finds another session, `send_note` tells it something.

`chi send` is the other half: the text goes in as your message, the same as
typing it in the attached terminal or the web composer, and a turn runs. Piped
stdin plus `-m` puts the stdin above the message as a `>` quote.

### Send to chi (macOS)

`chi desktop install` builds a small native helper: select text in any app →
Services → **Send to chi** (or ⌃⌥⌘N with the clipboard) → pick live sessions in a
Spotlight-like panel → the text lands there as a context note. It needs the
Command Line Tools. See [Desktop helper](docs/desktop.md).

### Guardrails

Every tool call the model makes can be allowed, denied, or put to you first.
Rules come from `config.yml` (`guardrails:`), installed bundles and hooks;
`chi bundle install guardrails` adds a default set (asks before `git push`,
history rewrites, wide `rm -rf`, `curl | sh`, writes outside the repo; denies
writes to `.git/hooks`). You answer in the REPL, the attached TUI or the web:
once, for the session, for the repo, or for the whole rule in the repo.
`/guardrails` lists the rules and your approvals. See [Guardrails](docs/guardrails.md).

## Documentation

- [CLI and REPL](docs/cli.md): flags, sharing a session, web UI, `/model`, status line
- [Configuration](docs/configuration.md): `config.yml`, hosts, model server transports, timeouts, retries, logs
- [Memory](docs/memory.md): scopes and model-specific overlays
- [Sessions](docs/sessions.md): storage, retention, `chi sessions`
- [Desktop helper](docs/desktop.md): `chi desktop`, the macOS "Send to chi" Service and hotkey
- [Guardrails](docs/guardrails.md): allow / ask / deny for tool calls, rules, approvals
- [Hooks](docs/hooks.md): plugin hooks and bundle hooks
- [Architecture](docs/architecture.md): Engine, TerminalUI, bridge, web
- Internals: [Gemma 4 contract](docs/internals/gemma4-contract.md), [context telemetry](docs/internals/context-telemetry.md), [tool output limits](docs/internals/tool-guardrails.md), [background tasks](docs/internals/background-tasks.md)

## Development

```sh
bundle exec rspec    # Ruby specs
npm test             # web frontend specs
```
