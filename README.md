# samagotchi

An agent harness that relies heavily on memory. Samagotchi is the engine; chi
(pronounced "chee") is its short name and CLI command.

> **Pre-1.0:** config and commands may change between minor versions (0.2 →
> 0.3); the [CHANGELOG](CHANGELOG.md) says what changed. chi is used daily and
> stable.

## Requirements

- Ruby 3.3+
- A model server: [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server`
  by default; mlx-lm, oMLX and OpenAI-compatible servers also work
  (see [Configuration](docs/configuration.md#model-server-transport))

## Install

```sh
gem install samagotchi
chi self            # version, source dir, config and memory paths
```

### From source

```sh
git clone https://github.com/dm1try/samagotchi && cd samagotchi
bundle install
bin/chi self
```

`bin/chi` runs the checkout; `bundle exec rake gem:install` installs it as a
local gem, which puts `chi` on your PATH.

## Set up

Point chi at your model server; it works out the rest and writes
`~/.config/samagotchi/config.yml`:

```sh
chi bootstrap 192.168.1.29:8081          # llama.cpp on another machine
chi bootstrap localhost:11434            # Ollama (any OpenAI-compatible server)
chi bootstrap https://openrouter.ai/api/v1 --key-env OPENROUTER_API_KEY
chi bootstrap                            # look on this machine's usual ports
```

It finds out whether the server is llama.cpp or OpenAI-compatible, picks the
model (or asks, when there are several), sends one test request and writes
the config. With a config already there, it adds a `hosts:` entry and keeps
the rest of the file. Edit the file later as in [Configure](#configure);
`chi bootstrap --help` has the options.

## Configure

To write the config by hand instead, or to change it later: create
`~/.config/samagotchi/config.yml` (or `$XDG_CONFIG_HOME/samagotchi/config.yml`):

```yaml
default:
  model: gemma4            # the model id your server serves (required)
server:
  host: localhost
  port: 8080
```

`server:` is a llama.cpp `llama-server`. For any other OpenAI-compatible
server (vLLM, LM Studio, Ollama, a gateway), name it under `hosts:` with
`api: openai` instead:

```yaml
default:
  model: local:qwen3:8b    # host:model; the ids are in GET <url>/models
hosts:
  local:
    url: http://localhost:11434/v1   # the API base, /v1 included
    api: openai
```

`chi self` shows the model and host chi will use. Other settings (multiple hosts, transports, timeouts, the idle recap) are in
[Configuration](docs/configuration.md).

## Use

```sh
chi                                       # interactive session the web UI can join too
chi --no-shared                           # the plain in-process REPL
chi -p "explain lib/" --non-interactive   # one turn, print the answer, exit
chi --resume <session-id>                 # continue a saved session
chi web --open                            # web UI: this project's sessions (--scope=all: every one)
chi sessions list                         # this project's saved sessions (--scope=all: every one)
pbpaste | chi note --source slack <id>    # background context for a session (no turn)
pbpaste | chi send -m "same bug?" <id>    # a message to a session, the clipboard quoted above it
chi send --new --wait -m "review feat/x"  # a new session you can watch in the web; prints the answer
```

`@shot.png` in a prompt (or a pasted/dropped image in the web UI) shows the model an image, when it can see them; see [Images](docs/cli.md#images).

`/model` switches models, Ctrl-C cancels a turn, and Ctrl-D or `/detach` detaches (the session keeps running; `chi --attach ID` comes back). `/exit` detaches and stops the session's worker too, unless something still needs it (a running turn, another UI); `chi --resume ID` picks the conversation up again. `/exit --delete` also deletes the session once the worker has gone; `chi sessions delete ID` deletes one from the shell. `/archive` (or `chi sessions archive ID`) hides a session from every list and keeps it for good; `chi sessions list --archived` finds it again.

### Context notes

`chi note` pushes text into one or more sessions as background, not as a
prompt: nothing runs, and the model sees it on its next turn framed as a note
(`[CONTEXT NOTE from slack, 14:02] … [END NOTE]`) that it uses when relevant and
never takes orders from. The web and the attached terminal show it as a dim
"note from …" line. `chi sessions list --live --scope=all --format tsv` lists the sessions
a note reaches (`id<TAB>description`). Agents can do the same: `list_sessions`
finds another session, `send_note` tells it something, and `delegate` hands a
task to a child session that runs in parallel and reports back only its final
reply (a normal session: `chi --attach <id>` steers it).

`chi send` is the other half: the text goes in as your message, the same as
typing it in the attached terminal or the web composer, and a turn runs. Piped
stdin plus `-m` puts the stdin above the message as a `>` quote. `chi send --new`
starts a session with the message instead (it shows in the web at once), and
`--wait` blocks and prints the answer.

### Send to chi (macOS)

`chi desktop install` builds a small native helper: select text in any app →
Services → **Send to chi** (or ⌃⌥⌘N with the clipboard) → pick sessions in a
Spotlight-like panel → ⏎ sends it quoted under your question as a message, ⌘⏎ as a
context note. It needs the
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

- [CHANGELOG](CHANGELOG.md): what changed in each release
- [Releasing](docs/releasing.md): versions, the changelog, how a release is published

- [CLI and REPL](docs/cli.md): flags, sharing a session, web UI, `/model`, status line
- [Configuration](docs/configuration.md): `config.yml`, hosts, model server transports, timeouts, retries, logs
- [Memory](docs/memory.md): scopes and model-specific overlays
- [Sessions](docs/sessions.md): storage, retention, `chi sessions`
- [Desktop helper](docs/desktop.md): `chi desktop`, the macOS "Send to chi" Service and hotkey
- [Guardrails](docs/guardrails.md): allow / ask / deny for tool calls, rules, approvals
- [Hooks](docs/hooks.md): plugin hooks and bundle hooks
- [Plugins](docs/plugins.md): bundle plugins (commands, tools, hooks)
- [Architecture](docs/architecture.md): Engine, TerminalUI, bridge, web
- Internals: [Gemma 4 contract](docs/internals/gemma4-contract.md), [context telemetry](docs/internals/context-telemetry.md), [tool output limits](docs/internals/tool-guardrails.md), [background tasks](docs/internals/background-tasks.md)

## Development

```sh
bundle exec rspec    # Ruby specs
npm test             # web frontend specs
npm run e2e          # web UI happy paths in Chromium, fake model (once: npx playwright install chromium)
```

## License

MIT, see [LICENSE](LICENSE).
