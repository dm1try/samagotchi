# Testing

```sh
bundle exec parallel_rspec -n 8   # Ruby specs, in parallel (or plain: bundle exec rspec)
npm test                          # web frontend specs
npm run e2e                       # web UI happy paths in Chromium, fake model (once: npx playwright install chromium)
bundle exec rake lint             # RuboCop: no offenses (CI runs it)
```

Run `bundle exec rubocop -a` on the files you changed before committing: every enabled style cop follows the
code's own style and has a safe autocorrect, so `-a` fixes them. What it leaves is a Lint finding (a possible
bug) or a broken spec: fix it, or disable that line with the reason (`# rubocop:disable Cop -- why`).
`.rubocop.yml` says why each cop that is off is off.

No spec reads your own setup. The suite points `XDG_CONFIG_HOME` and `XDG_STATE_HOME` at temp folders,
clears your `SAMAGOTCHI_*` environment, and keeps every spec off the network (WebMock).

## Integration specs

Examples tagged `:integration` (`spec/integration/`, the "with LLM access" part of `spec/hooks/integration_spec.rb`)
run turns against a live model server. They are skipped unless `SAMAGOTCHI_INTEGRATION=1` is set, and they need the
server and the model it serves:

| Variable | Meaning | Default |
| --- | --- | --- |
| `SAMAGOTCHI_INTEGRATION` | `1` runs them | off |
| `SAMAGOTCHI_INTEGRATION_HOST` | model server host | `localhost` |
| `SAMAGOTCHI_INTEGRATION_PORT` | model server port | `8080` |
| `SAMAGOTCHI_INTEGRATION_MODEL` | the served model id | none: the examples skip |
| `SAMAGOTCHI_INTEGRATION_API` | `openai` for the chat loop (`hosts.<name>.api`) | none: the native loop |
| `SAMAGOTCHI_INTEGRATION_TRANSPORT` | `llama_cpp`, `mlx` or `omlx` (`server.transport`) | none: `llama_cpp` |

They run under a config built from these variables alone (`default.model`, `server.host`/`port`, and one
`hosts.integration` entry; `spec/support/integration_server.rb`), never your `~/.config/samagotchi/config.yml`: no
aliases, memories, hooks, guardrails or other hosts of yours. Sessions and logs go to the suite's temp state folder.

Run them one at a time (plain `rspec`, not `parallel_rspec`): each example is a real model turn, and the server may be
shared.

```sh
SAMAGOTCHI_INTEGRATION=1 \
SAMAGOTCHI_INTEGRATION_HOST=192.0.2.10 SAMAGOTCHI_INTEGRATION_PORT=8081 \
SAMAGOTCHI_INTEGRATION_MODEL=org/Model-GGUF:Q4_K_M \
bundle exec rspec --tag integration spec/integration spec/hooks/integration_spec.rb spec/integration_config_spec.rb
```

A run takes one to four minutes against a 35B MoE model on llama.cpp (25 examples). `ECONNREFUSED` means the server is down. The
examples assert what the model did (the tool it called, the file it edited), not its wording, but they still depend on
a model that follows tool instructions: a small model may fail some of them.

`spec/integration/omlx_spec.rb` tests oMLX's model-id resolution and runs only with
`SAMAGOTCHI_INTEGRATION_TRANSPORT=omlx`, against an oMLX server (a short model selector in
`SAMAGOTCHI_INTEGRATION_MODEL`).
