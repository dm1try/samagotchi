# Configuration

## Global Config File

Chi can preload a global config file and expose those entries as environment
variables before the app boots.

Default path:

- `$XDG_CONFIG_HOME/samagotchi/config.yml`
- Fallback when `XDG_CONFIG_HOME` is unset: `~/.config/samagotchi/config.yml`

Example:

```yaml
SAMAGOTCHI_DEFAULT_MODEL: Qwen3-14B-Instruct
server:
  host: 192.168.1.29
  port: 8081
SAMAGOTCHI_THINKING_UI: spinner

# Multi-host (optional): aggregated /models and per-model routing.
# Bare SAMAGOTCHI_DEFAULT_MODEL uses the default host; host:model pins to a host.
# Transport per host overrides SAMAGOTCHI_SERVER_TRANSPORT; api: openai makes a
# host use the OpenAI chat API instead of chi's raw prompt.
hosts:
  main:
    host: localhost
    port: 8080
    transport: llama_cpp
  recap-box:
    host: 192.168.1.50
    port: 8080

# Idle recap: on by default, written with the session's own model and host
# (on a paid remote host that is one small request per idle window).
# host_ref + model pin another model: host_ref asks that host's OpenAI API (its
# url:, else http://host:port/v1) with its api_key_env; base_url is an OpenAI API
# base as given (e.g. http://h:8081/v1). recap: false turns it off.
recap:
  # host_ref: recap-box
  # model: gemma4-small
  # inactivity: 180
  # timeout: 30
  # min_user_turns: 2
  # sentences: 2-4   # or 3, 5-7; 1-10 (from the next recap written)

model_aliases:
  small: gemma4-small
  tiny: recap-box:gemma4-small  # alias may be bare or host:model (hybrid)

# Plain chi runs its session in a background worker and attaches to it, so the
# web UI can share it (default true; env SAMAGOTCHI_SESSION_SHARED). false keeps
# the in-process REPL; --no-shared does for one run.
session:
  shared: true
  # idle_exit_minutes: 30   # an unused worker exits after this (0 = never)
  # keep_empty: false       # true keeps sessions nothing happened in (default: deleted when left)

# Baseline memories preloaded into the system prompt (same shape as --memory).
# CLI --memory entries are appended after these, deduped.
memories:
  - system/user_preferences
  - project/feature-env-template
```

Behavior:

- The file is optional.
- Top level is a YAML mapping of scalar env overrides plus nested sections.
- Real environment variables still win over config-file values.
- Workers inherit hosts via `SAMAGOTCHI_HOSTS_JSON` propagated through `SessionManager.spawn_options`.

This lets you run `bin/chi` without repeating common defaults such as model
and llama host/port on every invocation.

Note: The global config file supports both flat scalar entries (for env vars)
and nested sections like `hosts:`, `recap:`, `hooks:`, `guardrails:` (see
[Guardrails](guardrails.md)), `bundles:` (a bundle's settings for its hooks,
see [Hooks: Settings](hooks.md#settings)), `model_aliases:`,
`memories:`. Scalar entries are loaded as environment
variables; non-scalar sections are skipped by the env-loader and parsed by
their respective subsystems (e.g. the hooks system, `HostRegistry`). The
`memories:` list is the persistent baseline for preloaded memory entries —
the same name shape as `--memory` (bare name or `scope/name`), merged under
any per-run `--memory` values (config baseline first, deduped). A per-run
`--mute NAME` removes an entry from the merged list for that session (see
"Muting a memory" in cli.md).

## Model Server Transport

Chi talks to a model server over HTTP and supports three transports:

- `llama_cpp` (default): llama.cpp's native `/completion` and `/models` endpoints.
- `mlx`: [mlx-lm](https://github.com/ml-explore/mlx-lm)'s OpenAI-compatible
  `/v1/completions` and `/v1/models` endpoints (Apple Silicon-native models).
- `omlx`: [oMLX](https://github.com/jundot/omlx) (the mlx-lm successor —
  continuous batching + tiered SSD KV cache) using the same `/v1/completions`
  and `/v1/models` endpoints as `mlx`.

Select the transport with `SAMAGOTCHI_SERVER_TRANSPORT` (`llama_cpp`, `mlx`, or
`omlx`). `SAMAGOTCHI_SERVER_HOST`/`SAMAGOTCHI_SERVER_PORT` are reused for all three —
only the request/response shape differs. oMLX's default server port is `8000` (not
`8080`), so point `SAMAGOTCHI_SERVER_PORT` at it, e.g. `SAMAGOTCHI_SERVER_PORT=8000`.
With `hosts:` each entry may set `transport: llama_cpp|mlx|omlx` to override the
global transport per host (`lib/samagotchi/host_registry.rb`).

Each host may also set `api:`, which says how chi talks to it:

- `llama_cpp`, `mlx` or `omlx`: chi's own raw-prompt loop (the value is also the
  host's transport, so don't set a different `transport:` next to it);
- `openai`: the OpenAI chat API at `http://HOST:PORT/v1`, or at `url:` (see below).

Without `api:` a host uses the raw-prompt loop, as before. The loop follows the
model's host, so `/model other-host:model` can move a session between the two.
Workers started by plain `chi`, `chi web` or `--attach` get the same hosts, `api:` included.

Example for mlx-lm:

```yaml
SAMAGOTCHI_SERVER_TRANSPORT: mlx
server:
  host: 127.0.0.1
  port: 8080
```

```shell
mlx_lm.server --model mlx-community/Qwen3-14B-Instruct-4bit
```

Example for oMLX:

```yaml
SAMAGOTCHI_SERVER_TRANSPORT: omlx
server:
  host: 192.168.1.29
  port: 8000
```

Both the `mlx` and `omlx` transports still send chi's own raw formatted prompt
(via `/v1/completions`) rather than a `messages` array, so the existing
per-model prompt/tool-call formatting is unaffected — neither server reapplies its
own chat template on this endpoint. Only the Gemma4 (`<|tool_call>…`) and Qwen3.6
(`[[…]]`/`<|tool_call>`) tool-call formats are in scope; GLM/Mistral/Kimi/MiniMax
formats are not parsed.

For an OpenAI Chat Completions server such as [Splash](https://github.com/incoai/splash),
give its host `api: openai`:

```yaml
default:
  model: splash:incoai/Qwen3.6-35B-A3B-Splash
hosts:
  splash:
    host: 192.168.1.29
    port: 8000
    api: openai
```

A host can give `url:` instead of `host:`/`port:` (not both): `http` or `https`,
with an optional path. For `api: openai` the url is the API base as written (no
`/v1` is added); raw-prompt hosts use only its scheme, host and port. A remote
provider's key comes from the environment variable that `api_key_env:` names;
the key itself never goes into config.yml, `chi self`, logs or events, and
workers get it by inheriting the environment:

```yaml
hosts:
  fw:
    url: https://api.fireworks.ai/inference/v1
    api: openai
    api_key_env: FIREWORKS_API_KEY
```

`chi self` shows the variable and whether it is set (`api key  FIREWORKS_API_KEY (set)`).

For models on that host, chi uses the chat loop (its own OpenAI chat adapter): it
takes the OpenAI base (`url:`, else `http://HOST:PORT/v1`) and streams messages plus
function schemas from `/v1/chat/completions`; the model's reasoning (`reasoning_content`)
shows as thinking. This works with Splash and with llama.cpp servers that
expose the OpenAI-compatible chat endpoint. In verbose mode (`-v`), chi prints the loop the
starting model uses (`[verbose] backend=chat` or `backend=native`); request
bodies are not logged. The interactive REPL, `--prompt`,
workers, and resumed sessions all use the loop of the model's host. Hosts without
`api: openai` keep using the native `/completion`, `/v1/completions`, or oMLX
transport path.

To manually verify a live chat-loop tool round trip, run the gated integration
spec. It requires the model to call `execute` and return the current UTC date:

```shell
SAMAGOTCHI_INTEGRATION=1 \
SAMAGOTCHI_SERVER_HOST=192.168.1.29 SAMAGOTCHI_SERVER_PORT=8000 \
SAMAGOTCHI_DEFAULT_MODEL=incoai/Qwen3.8-27B-Splash \
bundle exec rspec spec/integration/chat_loop_spec.rb -fd < /dev/null
```

The same test works against a llama.cpp OpenAI-compatible server by changing
the host, port, and model values. The test is skipped unless
`SAMAGOTCHI_INTEGRATION=1` is set.

oMLX's known tool-call limitation (a stream filter that strips markup) only
affects its `/v1/chat/completions` endpoint, not the `/v1/completions` endpoint
chi uses, so raw `[[…]]`/`<|tool_call>` markers stream through untouched.

`SAMAGOTCHI_DEFAULT_MODEL` (config default) and `/model` (runtime effective) pick the model; the status line and `/model`
output always render the runtime effective model (showing default when diverged). Which prompt format it gets is the
prompt profile (see "Prompt profile" below). How the selector reaches the request differs by transport:

- **mlx** (`mlx_lm.server`): the `model` field is omitted entirely — the server
  uses whatever was loaded via its own `--model` CLI flag.
- **omlx**: the server *requires* a `model` field and returns `HTTP 400`
  (`model: Field required`) without it, so samagotchi forwards the selector
  resolved to the exact id listed in the server's `/v1/models` — matched by exact
  (case-insensitive) first, then substring, then passed through unchanged. That
  resolved id is usually prefixed (e.g. `mlx-community--gemma-3-4b-it-4bit`), so a
  short selector such as `gemma-3-4b-it-4bit` is what you set in
  `SAMAGOTCHI_DEFAULT_MODEL`. An unknown selector passes through raw and oMLX 404s,
  listing its available models; if `/v1/models` is unreachable, samagotchi falls
  back to the raw selector and lets the server decide (its own 400/404). Either
  error fails the turn with the server's message (see "Server errors" below). Runtime
  model switch re-resolves each completion (the `/v1/models` id list is cached per
  client; the selector itself is re-resolved every time).

## Prompt profile

A native host (`llama_cpp`, `mlx`, `omlx`) gets a raw prompt in one model family's format: its turn markers, tool-call
syntax, thought tags and stop sequences. That is the prompt profile, `qwen36` or `gemma4`. A wrong one is not just
worse output: a ChatML model under `gemma4` never hits a stop sequence, generates until its limit and then runs the
tool calls it made up on the way. The first of these that says something wins:

1. `--profile NAME` (or `--model-profile NAME`), then `SAMAGOTCHI_MODEL_PROFILE`: for every model in the process,
   including one picked later with `/model`.
2. `models:` in `config.yml`, keyed by model id or alias (case-insensitive; the name as typed, alias-resolved or
   without its host prefix):

   ```yaml
   models:
     ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M:
       profile: qwen36
     ista:
       profile: qwen36
   ```

3. `profile:` on a `hosts:` entry, for anything that host serves:

   ```yaml
   hosts:
     mlx:
       host: 192.168.1.29
       port: 8081
       transport: mlx
       profile: qwen36
   ```

4. The server's chat template, on `llama_cpp` hosts: `/props` (asked with `?model=`, which a router needs) with
   `<|im_start|>` and `<function=` is `qwen36`, any other ChatML template too; `<|turn>` and `<|tool_call>` is `gemma4`.
   mlx_lm.server and oMLX publish no template, so config or the name decides there.
5. The name: `qwen` → `qwen36`, `gemma` → `gemma4`.
6. `qwen36`.

An unknown value in `models:` or `hosts:` warns and is skipped; an unknown `--profile` or `SAMAGOTCHI_MODEL_PROFILE`
warns too (the CLI refuses it). The profile is resolved at start and on `/model`, then kept for the session, so the
system prompt stays the same; a server that swaps models between turns goes unnoticed until `/model` or a new chi. If
`/props` could not be read at start (server down, or 503 while loading), chi asks again before the next turn.

`/stats` and `/model` show the profile and its source (`cli`, `env`, `config (models: …)`, `config (hosts.<name>)`,
`server (chat_template)`, `name`, `default`); `chi self` shows what config says without asking the server. A chat
host (`api: openai`) formats nothing itself: its profile comes from the name and only strips thought tags.

Workers get `hosts:` (with `profile:`) through `SAMAGOTCHI_HOSTS_JSON` and read `models:` from the same config file.
`--profile` reaches the worker a chi starts, but a worker that another process wakes later (`chi web`, `--attach`
after an idle exit) gets that process's environment, so put a lasting choice in config.

## Llama HTTP Timeouts

Long-running llama.cpp completions can exceed Ruby's default HTTP read timeout.
Configure these environment variables to avoid premature request failures:

- `SAMAGOTCHI_SERVER_OPEN_TIMEOUT` (default: `10`) connection timeout in seconds.
- `SAMAGOTCHI_SERVER_READ_TIMEOUT` (default: `600`) response read timeout in seconds.

A streamed answer also has a **first-token limit**: the seconds it may take to show its first text, reasoning or
tool call. A remote provider can keep a queued request open for minutes with SSE keep-alive comments
(OpenRouter's `: OPENROUTER PROCESSING`), which reset the read timeout, so only this limit ends the wait. The
turn then fails with `no answer from host <name> within 120s (first_token_timeout); …` and is not retried.

```yaml
hosts:
  openrouter:
    url: https://openrouter.ai/api/v1
    api: openai
    api_key_env: OPENROUTER_API_KEY
    first_token_timeout: 180   # seconds; 0 = off
```

`hosts.<name>.first_token_timeout` wins over `server.first_token_timeout` (`SAMAGOTCHI_SERVER_FIRST_TOKEN_TIMEOUT`),
which applies to every host. With neither set, remote hosts (an API key or an https url) get 120 seconds and local
servers no limit: a long prompt evaluation is normal there, and the read timeout catches a dead server.

Every chat request carries the session's id as a `Session-Id` header (next to `User-Agent: chi/<version>`). A
gateway that spreads requests over several providers can key on it to keep one conversation on one provider, so
prompt caches hit and every turn is answered by the same model. Servers that don't know the header ignore it.

## Llama Model Routing

To explicitly route requests to a named model in llama.cpp, set:

- `SAMAGOTCHI_DEFAULT_MODEL` (required): model name/id sent as the `model` field on `/completion` requests.

When `SAMAGOTCHI_DEFAULT_MODEL` is unset or blank, Samagotchi fails fast with a clear startup/configuration error.

With several `hosts:`, an unqualified model name goes to the host whose `/models`
list has it (after `/models` ran), by exact id first, then by substring. A
**remote** host (one with `api_key_env:` or an `https` url) is only chosen by exact
id, `host:model` or an alias, never by a substring, and its model list is kept for
10 minutes (60s for local hosts). For a chat host the context window comes from
the running server (llama.cpp's `/props`), else the window the host's model list
gives (`context_length`, `context_window`, `max_model_len` or llama.cpp's
`meta.n_ctx`), else `context.window_tokens`.

## Llama Network Retry Behavior

Transient network failures are retried automatically with exponential backoff.

- Default retries: `5` (up to `6` total attempts including the first call).
- Default backoff: `0.5s`, `1s`, `2s`, `4s`, `8s`.
- Retry scope: transient network errors (timeouts, refused/reset connections, EOF/socket reachability failures),
  HTTP 429 and HTTP 500/502/503/504/529. A `Retry-After` header replaces the backoff delay; one longer than
  60s is not waited out and the error is reported instead.
- A stream that has already produced output is never retried (the retry would repeat it); it fails the turn.
- Cancellation (`Ctrl-C`) is never retried.

Configuration:

- `SAMAGOTCHI_RETRY_MAX` (default `5`): number of retries after the first failed attempt.
- `SAMAGOTCHI_RETRY_BASE_DELAY` (default `0.5`): backoff base delay in seconds.
- `SAMAGOTCHI_RETRY_MAX_DELAY` (default `8.0`): cap for backoff delay in seconds.

Assist-mode UX:

- While waiting, retry notices are rendered in the existing thinking spinner area as a red `network error: retrying ...` status.
- If retry attempts are exhausted, the submitted prompt is restored into the input editor so you can edit and resubmit.

## Server errors

An error status or a server's error event fails the turn with the server's
message (before, a failed llama.cpp `/completion` ended the turn as
`[No response]`). The error names its kind:

| Kind | When | Retried |
|---|---|---|
| connection | refused, reset, timed out, dropped mid-stream | yes (network retry), not mid-stream |
| rate limited | HTTP 429 | yes, honouring `Retry-After` |
| server | HTTP 5xx, llama.cpp's mid-stream `error:` event | 500/502/503/504/529 only |
| auth | HTTP 401/403 | no |
| bad request | other 4xx; a prompt larger than the context window, whatever the status | no |
| protocol | a body the API doesn't promise | no |

The turn's prompt and its completed tool calls stay in the session.

## Debug Log File

Every `chi` process (the REPL, the attached terminal, the background
workers, `chi web`) appends tagged records to one log file, so you can see
what happened in a session, what went over the wire and why something
failed, without `--verbose`.

Default path:

- `$XDG_STATE_HOME/samagotchi/samagotchi.log`, i.e.
  `~/.local/state/samagotchi/samagotchi.log` when `XDG_STATE_HOME` is unset
  (next to the sessions and prompt history, never inside the gem)

Configuration (CLI > env > config file, like every other entry):

- `log.file` / `SAMAGOTCHI_LOG_FILE` / `--log-file PATH`: another path. `~`
  and relative paths are expanded against the directory `chi` runs in.
- `log.disable` / `SAMAGOTCHI_LOG_DISABLE=true` / `--log-disable`: no file logging.
- `log.level` / `SAMAGOTCHI_LOG_LEVEL` / `--log-level LEVEL`: `debug`, `info`
  (default), `warn` or `error`.

A worker takes the log settings (file and level) of the `chi` or `chi web`
that started it.

### Format

One record is one line, plus indented payload lines at debug level:

```
2026-09-25T10:11:12.345Z INFO  turn pid=4242 sid=6f1c2a9b tool_call_completed iteration=1 tool=read ms=12 output_chars=5120
2026-09-25T10:11:13.001Z WARN  http pid=4242 sid=6f1c2a9b retry host=openrouter method=POST url=https://openrouter.ai/api/v1/chat/completions model=qwen/qwen3.6 purpose=chat attempt=1 max_retries=5 delay_s=2.0 status=429 error=Samagotchi::LLM::RateLimited msg="…"
2026-09-25T10:11:14.500Z DEBUG model pid=4242 sid=6f1c2a9b response model=qwen3.6 iteration=2
    the model's answer, every line indented by four spaces
```

- time (UTC, milliseconds), level, tag, the process id, the session's first
  8 characters (`sid=`, when the record is about one; `turn_started` has the
  full id as `session=`), the event, then `key=value` fields. A value with a
  space, quote or `=` is a JSON string, so a record never spans lines;
  control characters (terminal colours in tool output) are escaped.
- Tags: `turn` (a session's event trail), `http` (model requests),
  `worker`, `bridge`, `web`, `attached`, `repl`, `idle`, `recap`, `hooks`,
  `guardrails`, `config`, `memory`, `model` (debug dumps).
- The format is parsed by `Samagotchi::LogLine` (`parse`, `each_record`);
  keep tools that read it on that parser.

What each level adds:

- `error`: crashes (a worker, a bridge connection, the idle scheduler, a
  recap) with the first 20 backtrace frames; failed model requests.
- `warn`: retries (429, 5xx, network), failed turns, hook and guardrail
  problems, config warnings. Warnings `chi` prints on stderr are logged too,
  with the same text as `msg=`; a worker's (its stderr goes nowhere) now
  only reach the file.
- `info`: turns, generations and tool calls with sizes and times (never the
  text of a prompt, answer or tool output), one line per model request
  (status, time to first token, total), worker start/spawn/stop/idle exit,
  `chi web` start.
- `debug`: payload dumps (each model answer with its thinking, tool calls
  and results, context status), probes and model lists, every web API and
  bridge request.

`-v`/`--verbose` (the plain REPL only) logs at `debug` and prints every
record to stderr as well.

### Rotation and secrets

At 5 MB the file moves to `samagotchi.log.1` (one kept) and a new one
starts; every process follows. Request headers and bodies are never
logged; fields named like a credential (`api_key`, `token`, `secret`,
`authorization`, `password`) show `[redacted]`, and URLs lose their user
info and query. Debug dumps can still hold secrets a tool read or was
given (a file's contents, a command line): treat a debug log as sensitive.
`tools/web_fetch` requests are not logged (their own HTTP client).

### Recipes

```sh
tail -f ~/.local/state/samagotchi/samagotchi.log
# one session
grep 'sid=6f1c2a9b' ~/.local/state/samagotchi/samagotchi.log
# model requests only, or warnings and errors
awk '$3 == "http"' ~/.local/state/samagotchi/samagotchi.log
awk '$2 == "WARN" || $2 == "ERROR"' ~/.local/state/samagotchi/samagotchi.log
# how long each tool call took
grep ' tool_call_completed ' ~/.local/state/samagotchi/samagotchi.log | grep -o 'tool=[^ ]* ms=[0-9]*'
```

## Images

Images a model gets (see [CLI: Images](cli.md#images)) are converted and
downscaled first; three settings bound them (env `SAMAGOTCHI_IMAGE_*` or
`config.yml`):

```yaml
image:
  max_side: 1568          # long side in px (Claude's standard; ~1.3k tokens for 1280×800)
  max_bytes: 3750000      # larger after downscaling → re-encoded as JPEG
  max_per_request: 20     # older images in the conversation become placeholder lines
```

Whether a model can see images is found out before a turn with images is sent:

- a native llama.cpp host: `/props` must report `modalities.vision` (the server
  runs with `--mmproj`) and a media marker, and the prompt profile must know the
  chat template's image wrapping (qwen36 does; gemma4 not yet);
- mlx and oMLX hosts: no;
- an OpenAI-API host: a local llama.cpp's `/props`, else the host's model list
  (OpenRouter's `architecture.input_modalities`); when it doesn't say, the image
  is sent and a refusal is reported.

`vision: true|false` overrides that per model or per host:

```yaml
models:
  ornith: { vision: true }
hosts:
  gateway: { url: https://…, api: openai, vision: false }
```

`models:` wins over `hosts:`. On a native host, `vision: true` skips only the
modalities check: without a media marker the prompt can't carry an image.

## Project specific description

If an AGENT.md file is present in the project root, samagotchi injects its
contents into the system prompt under a "Project specific description:" section.

To skip loading AGENT.md, set:

`SAMAGOTCHI_SKIP_AGENT_MD=true`
