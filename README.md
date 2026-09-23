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
bin/chi                                       # interactive REPL
bin/chi -p "explain lib/" --non-interactive   # one turn, print the answer, exit
bin/chi --resume <session-id>                 # continue a saved session
bin/chi web --open                            # web UI on http://127.0.0.1:4567
bin/chi --shared                              # a session the web UI can join too
bin/chi sessions list                         # saved sessions
```

In the REPL, `/model` switches models and Ctrl-C cancels a turn.

## Documentation

- [CLI and REPL](docs/cli.md): flags, sharing a session, web UI, `/model`, status line
- [Configuration](docs/configuration.md): `config.yml`, hosts, model server transports, timeouts, retries, logs
- [Memory](docs/memory.md): scopes and model-specific overlays
- [Sessions](docs/sessions.md): storage, retention, `chi sessions`
- [Hooks](docs/hooks.md): plugin hooks and bundle hooks
- [Architecture](docs/architecture.md): Engine, TerminalUI, bridge, web
- Internals: [Gemma 4 contract](docs/internals/gemma4-contract.md), [context telemetry](docs/internals/context-telemetry.md), [tool guardrails](docs/internals/tool-guardrails.md), [background tasks](docs/internals/background-tasks.md)

## Development

```sh
bundle exec rspec    # Ruby specs
npm test             # web frontend specs
```
