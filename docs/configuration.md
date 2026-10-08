# Configuration

## Global Config File

Chi reads its settings from three places; the first that sets a value wins:

1. a CLI flag (`--server-port 8081`),
2. an environment variable (`SAMAGOTCHI_SERVER_PORT=8081`),
3. the global config file (`server: {port: 8081}`),

then the built-in default. [All settings](#all-settings) lists them.

`chi bootstrap HOST[:PORT]` writes a first config for a model server, or adds
it to this file as a `hosts:` entry (see [First setup](cli.md#first-setup)).

Default path:

- `$XDG_CONFIG_HOME/samagotchi/config.yml`
- Fallback when `XDG_CONFIG_HOME` is unset: `~/.config/samagotchi/config.yml`

Example (every section is optional except `default.model`; README.md has a
minimal one):

```yaml
default:
  model: Qwen3-14B-Instruct
server:                 # the model server when there is no hosts: map below
  host: 192.0.2.10
  port: 8081
thinking:
  level: default        # off | low | medium | high | default; see "Thinking"

# Multi-host (optional): aggregated /models and per-model routing.
# A bare default.model uses the default host; host:model pins to a host.
# transport: on a host overrides server.transport; api: openai makes a
# host use the OpenAI chat API instead of chi's raw prompt.
hosts:
  main:
    host: localhost
    port: 8080
    transport: llama_cpp
  small-box:
    host: 192.0.2.20
    port: 8080

# Idle recap: on by default, written with the session's own model and host
# (on a paid remote host that is one small request per idle window).
# host_ref + model pin another model: host_ref asks that host's OpenAI API (its
# url:, else http://host:port/v1) with its api_key_env; base_url is an OpenAI API
# base as given (e.g. http://h:8081/v1). model is a model ref like any other: an
# alias is applied, and its host:/the alias's host picks the host when host_ref
# is left out; a model naming no host goes where a bare --model goes (the
# default host). A model naming another host than host_ref turns recap off with
# a warning. recap: false turns it off.
recap:
  # host_ref: small-box
  # model: your-small-model-id
  # inactivity: 180
  # timeout: 30
  # min_user_turns: 2
  # sentences: 2-4   # or 3, 5-7; 1-10 (from the next recap written)

model_aliases:
  small: your-small-model-id
  tiny: small-box:your-small-model-id  # alias may be bare or host:model (hybrid)

# Plain chi runs its session in a background worker and attaches to it, so the
# web UI can share it (default true; env SAMAGOTCHI_SESSION_SHARED). false keeps
# the in-process REPL; --no-shared does for one run.
session:
  shared: true
  # idle_exit_minutes: 30   # an unused worker exits after this (0 = never)
  # keep_empty: false       # true keeps sessions nothing happened in (default: deleted when left)
  # max_children: 4         # running sessions one session may have delegated at a time (the delegate tool)
  # delegate_reports: wake  # a child's reply reaches its parent by itself: wake (an idle parent runs a turn), queue, off
  # max_wakes: 10           # turns in a row a parent runs for delegate reports with no human input

# Baseline memories preloaded into the system prompt (same shape as --memory);
# name entries you have, or chi warns at each start.
# CLI --memory entries are appended after these, deduped.
memories:
  # - system/user_preferences
  # - project/feature-env-template
```

Behavior:

- The file is optional.
- Top level is a YAML mapping of sections (`default:`, `server:`, `recap:`, …)
  and the maps described below. Keys are lower `snake_case`, one level per
  dot: `server.read_timeout` is `server: {read_timeout: 600}`.
- A key chi doesn't read warns at start, with the closest known key:
  `config: unknown key 'default.modle' (did you mean 'default.model'?)`.
  Names you choose under the maps below (host names, model ids) don't warn.
- Environment variables and CLI flags win over config-file values.
- An edit to the file needs no restart of `chi web`: a new session's worker
  reads the file when it starts, and a running chi takes a changed value the
  next time it reads that setting (a worker keeps `hosts:` and what it set up
  at its start until it is stopped; the web's model picker lists a `hosts:`
  edit at once). A worker gets the CLI flags of the chi that started it
  through its environment.
- Workers inherit hosts via `SAMAGOTCHI_HOSTS_JSON` propagated through `SessionManager.spawn_options`.

This lets you run `chi` without repeating common defaults such as model
and llama host/port on every invocation.

Besides the settings sections, the file holds maps that are read by their
own subsystems: `hosts:` (below), `models:` (see "Prompt profile" and
"Images"), `model_aliases:`, `hooks:` (see [Hooks](hooks.md)),
`guardrails:` (see [Guardrails](guardrails.md)), `bundles:` (a bundle's
settings for its hooks, see [Hooks: Settings](hooks.md#settings)) and
`memories:`. Their entry names (host names, model ids, aliases) are yours to
choose. The `memories:` list is the persistent baseline for preloaded memory entries —
the same name shape as `--memory` (bare name or `scope/name`), merged under
any per-run `--memory` values (config baseline first, deduped). A per-run
`--mute NAME` removes an entry from the merged list for that session (see
"Muting a memory" in cli.md).

### Environment variables

Every setting has an environment variable (except the ones the table marks
config.yml only): `SAMAGOTCHI_` plus its dotted name in upper case, with `_`
for each dot. `default.model` is
`SAMAGOTCHI_DEFAULT_MODEL`, `server.read_timeout` is
`SAMAGOTCHI_SERVER_READ_TIMEOUT`. Use them to override the file for one run or
one shell (`SAMAGOTCHI_LOG_LEVEL=debug chi`); keep lasting choices in the file.
Most settings also have a CLI flag: the dotted name in kebab case
(`--server-read-timeout 900`); `chi --help` lists them.

An environment name used as a top-level key (`SAMAGOTCHI_DEFAULT_MODEL: my-model`,
the old flat form) is not read: it warns as an unknown key with the nested one
to use (`did you mean 'default.model'?`).

## Model Server Transport

Chi talks to a model server over HTTP and supports three transports:

- `llama_cpp` (default): llama.cpp's native `/completion` and `/models` endpoints.
- `mlx`: [mlx-lm](https://github.com/ml-explore/mlx-lm)'s OpenAI-compatible
  `/v1/completions` and `/v1/models` endpoints (Apple Silicon-native models).
- `omlx`: [oMLX](https://github.com/jundot/omlx) (the mlx-lm successor —
  continuous batching + tiered SSD KV cache) using the same `/v1/completions`
  and `/v1/models` endpoints as `mlx`.

> **mlx and oMLX** are not verified with recent chi versions; llama.cpp and
> OpenAI-compatible hosts (`api: openai`) are the tested paths.

Select the transport with `server.transport` (`llama_cpp`, `mlx`, or `omlx`;
env `SAMAGOTCHI_SERVER_TRANSPORT`). `server.host`/`server.port` are reused for all three —
only the request/response shape differs. oMLX's default server port is `8000` (not
`8080`), so point `server.port` at it. With `hosts:` each entry may set `transport: llama_cpp|mlx|omlx` to override the
global transport per host (`lib/samagotchi/host_registry.rb`).

Each host may also set `api:`, which says how chi talks to it:

- `llama_cpp`, `mlx` or `omlx`: chi's own raw-prompt loop (the value is also the
  host's transport, so don't set a different `transport:` next to it);
- `openai`: the OpenAI chat API at `http://HOST:PORT/v1`, or at `url:` (see below).

Without `api:` a host uses the raw-prompt loop, as before. The loop follows the
model's host, so `/model other-host:model` can move a session between the two.
Workers started by plain `chi`, `chi web` or `--attach` get the same hosts, `api:` included.

Example for mlx-lm (not verified with recent chi versions, like oMLX below):

```yaml
server:
  transport: mlx
  host: 127.0.0.1
  port: 8080
```

```shell
mlx_lm.server --model mlx-community/Qwen3-14B-Instruct-4bit
```

Example for oMLX:

```yaml
server:
  transport: omlx
  host: 192.0.2.10
  port: 8000
```

Both the `mlx` and `omlx` transports still send chi's own raw formatted prompt
(via `/v1/completions`) rather than a `messages` array, so the existing
per-model prompt/tool-call formatting is unaffected — neither server reapplies its
own chat template on this endpoint. Only the Gemma4 (`<|tool_call>…`) and Qwen3.6
(`[[…]]`/`<|tool_call>`) tool-call formats are in scope; GLM/Mistral/Kimi/MiniMax
formats are not parsed.

For an OpenAI Chat Completions server such as [Splash](https://github.com/incoai/splash)
(a fast inference engine for Macs that works well for a local setup alongside
llama.cpp), give its host `api: openai`:

```yaml
default:
  model: splash:incoai/Qwen3.6-35B-A3B-Splash
hosts:
  splash:
    host: 192.0.2.10
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

Every host with `api_key_env:` sends `Authorization: Bearer <key>` on each request,
chat or raw-prompt alike, so a llama.cpp started with `--api-key` works as a native
host too (`chi bootstrap --key-env VAR` writes such an entry). An unset variable
fails the turn before any request (`set VAR`); a 401/403 names the variable to
check, or, on a host without `api_key_env:`, suggests adding it:

```yaml
hosts:
  box:
    host: 192.0.2.20
    port: 8080
    api_key_env: BOX_LLAMA_KEY
```

**Remote or local.** chi treats a host as a remote provider by its address, not
by its key: an `https` url, or an `http` IP address outside the loopback,
private (`10.*`, `172.16–31.*`, `192.168.*`, IPv6 `fc00::/7`), link-local and
CGNAT/Tailscale (`100.64.0.0/10`) nets, or an `http` name with a dot that
doesn't end in a local suffix (`gpu.example.com`). A name without a dot (`box`)
or ending in `localhost`, `.local`, `.lan`, `.home`, `.home.arpa`, `.internal`,
`.intranet`, `.localdomain`, `.private`, `.corp`, `.test`, `.box` (`fritz.box`)
or `.ts.net` (Tailscale) is local: chi doesn't look names up. A remote
host keeps its model list for 10 minutes, gets a 120-second first-token limit,
and isn't asked for llama.cpp's `/props` (its context window and served model
come from its model list and each turn). A local `api: openai` host has no
`/props`, so `chi self` GETs its `/models` with the same short probe timeouts
and reports up/down with the ids it serves. `remote: true` or `remote: false` on a
host decides it instead, e.g. for a llama.cpp behind an https proxy on the LAN:

```yaml
hosts:
  lab:
    url: https://llm.lab.example/v1
    api: openai
    api_key_env: LAB_KEY
    remote: false
```

A host without `port:` (and without `url:`) uses port 8080. `enabled: false`
turns an entry off without deleting it: chi skips it as if it weren't there
(not in `chi models`, never the default host; `box:model` then counts as an
unknown host prefix, see [Llama Model Routing](#llama-model-routing)):

```yaml
hosts:
  box:
    host: 192.0.2.20
    enabled: false
```

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
SAMAGOTCHI_INTEGRATION_HOST=192.0.2.10 SAMAGOTCHI_INTEGRATION_PORT=8000 \
SAMAGOTCHI_INTEGRATION_MODEL=incoai/Qwen3.8-27B-Splash \
bundle exec rspec spec/integration/chat_loop_spec.rb
```

The same test works against a llama.cpp OpenAI-compatible server by changing
the host, port, and model values. The test is skipped unless
`SAMAGOTCHI_INTEGRATION=1` is set; see [Testing](testing.md).

oMLX's known tool-call limitation (a stream filter that strips markup) only
affects its `/v1/chat/completions` endpoint, not the `/v1/completions` endpoint
chi uses, so raw `[[…]]`/`<|tool_call>` markers stream through untouched.

`default.model` (config default) and `/model` (runtime effective) pick the model; the status line and `/model`
output always render the runtime effective model (showing default when diverged). Which prompt format it gets is the
prompt profile (see "Prompt profile" below). How the selector reaches the request differs by transport (mlx and oMLX: not verified with recent chi versions):

- **mlx** (`mlx_lm.server`): the `model` field is omitted entirely — the server
  uses whatever was loaded via its own `--model` CLI flag.
- **omlx**: the server *requires* a `model` field and returns `HTTP 400`
  (`model: Field required`) without it, so samagotchi forwards the selector
  resolved to the exact id listed in the server's `/v1/models` — matched by exact
  (case-insensitive) first, then substring, then passed through unchanged. That
  resolved id is usually prefixed (e.g. `mlx-community--gemma-4-e4b-it-4bit`), so a
  short selector such as `gemma-4-e4b-it-4bit` is what you set in
  `default.model`. An unknown selector passes through raw and oMLX 404s,
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

1. `--profile NAME` (or `--model-profile NAME`), then `SAMAGOTCHI_MODEL_PROFILE` (`model.profile` has no config-file
   form): for every model in the process, including one picked later with `/model`.
2. `models:` in `config.yml`, keyed by model id or alias (case-insensitive; the name as typed, alias-resolved or
   without its host prefix):

   ```yaml
   models:
     ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M:
       profile: qwen36
     my-alias:
       profile: qwen36
   ```

3. `profile:` on a `hosts:` entry, for anything that host serves:

   ```yaml
   hosts:
     mlx:
       host: 192.0.2.10
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

## Sampling

chi sends no sampling fields by default, to chat hosts (`api: openai`) or native ones, so each model runs at its
provider's defaults (llama.cpp: temperature 0.8; vLLM takes them from the model's `generation_config.json`).
`sampling:` on a `hosts:` entry or a `models:` entry sets request fields for the model's turns:

```yaml
hosts:
  work:
    url: https://llm.example.com/v1
    api: openai
    api_key_env: WORK_API_KEY
    sampling: { temperature: 0.6, presence_penalty: 1.5 }
models:
  qwen3.6-35b-a3b:
    sampling: { temperature: 0.6, top_p: 0.95, repeat_penalty: 1.1 }
```

- The fields go into the request as written; chi doesn't check the names, since providers differ (`repeat_penalty`,
  `min_p`, `dry_multiplier` are llama.cpp's; `presence_penalty` is OpenAI-style). A provider that refuses one fails
  the turn with its error (`host work rejected the request: HTTP 400: …`; one server answered a `presence_penalty`
  with "the requested logits or output transformation is not supported"): remove the last field you added from that
  host's or model's `sampling:`, or set it to `null` in the model's entry. A nested map passes through too, e.g.
  `chat_template_kwargs: { enable_thinking: false }`.
- A `models:` entry's fields win over its host's, field by field (the host can set a penalty and the model move only
  the temperature). The entry is found the way `profile:` is (the name as typed, alias-resolved or without its host
  prefix).
- `temperature: null` (or `~`) in a model's entry takes back a host's temperature, so the provider's default applies;
  it also keeps the empty-answer retry (below) at that default.
- Fields chi sets itself are refused with a warning: `model`, `messages`, `prompt`, `stream`, `stream_options`,
  `tools`, `tool_choice`, `stop`, `n_predict`, `max_tokens`, `n`, `parallel_tool_calls`, `response_format`,
  `cache_prompt`. A `sampling:` that isn't a map warns and is skipped.
- Greedy decoding (`temperature: 0`) can make a thinking model loop in its reasoning ("Let me write the reply…"
  for minutes) or end with an empty answer; set it only for a model you have watched. Qwen's own advice for its
  thinking models is `temperature: 0.6, top_p: 0.95`, with `presence_penalty` between 0 and 2 against endless
  repetition.
- The idle recap and side questions don't use `sampling:`; they send their own short output cap and no temperature.

`/model` shows what applies (`sampling: temperature=0.6 presence_penalty=1.5 (hosts.work)`), and each request's
`stream` line in the debug log carries a `sampling=` field with what was sent. The fields are read every turn, so a
`/model` switch takes the new model's. A worker gets `hosts:` (with `sampling:`) when it starts, through
`SAMAGOTCHI_HOSTS_JSON`, and reads `models:` from the config file each turn: after changing a host's `sampling:`,
stop the session's worker (`chi sessions stop`) for it to take effect.

## Thinking

How much a model thinks before it answers. One level, `off`, `low`, `medium`, `high` or `default`, set per model,
per host or for everything:

```yaml
thinking:
  level: default          # every model without its own level
hosts:
  openrouter:
    url: https://openrouter.ai/api/v1
    api: openai
    api_key_env: OPENROUTER_API_KEY
    thinking: low
models:
  qwen3.6-35b-a3b:
    thinking: off         # unquoted off works (YAML reads it as false)
```

- `default` sends nothing: the provider's or the chat template's own default, which is chi's behaviour without the
  setting. For some hybrid models that default is *no* thinking (DeepSeek V3.1 on OpenRouter); `medium` turns it on.
  `on` isn't a level.
- Order, first set wins: `--thinking LEVEL` or `SAMAGOTCHI_THINKING_LEVEL`, then the `models:` entry (found the way
  `profile:` is), then the `hosts:` entry, then `thinking.level` in the file, then `default`. Anything else than a
  level warns once and counts as unset.
- The flag reaches the sessions that start with it; a session already running keeps its level. `models:` levels
  and `thinking.level` in the file are read every turn; a host's `thinking:` reaches a worker when it starts, as
  its `sampling:` does (`chi sessions stop` to change it).
- `/model` shows the level and where it came from (`thinking: off (models: qwen3.6-35b-a3b)`), `chi self` too.
- The idle recap and plugins' side questions always ask with thinking off, whatever the level.

What each backend gets:

| Backend | `off` | `low` / `medium` / `high` |
|---|---|---|
| native (`/completion`), `qwen36` | an empty thought after the assistant cue, and no turn preamble | no knob: thinking stays as the model has it, one notice |
| native, `gemma4` | no `<\|think\|>` token at the start of the system prompt | no knob, one notice |
| chat host (`api: openai`) | `chat_template_kwargs: {enable_thinking: false}` and `reasoning_effort: "none"` | `reasoning_effort: <level>` |

On chat hosts: llama.cpp honours both off switches but ignores the effort (when its `/props` says
`chat_template_caps.supports_reasoning_effort: false`, chi says so once per session and host, from the `/props`
answer the turn already fetched for the window); Splash takes `reasoning_effort` (off only
through `none`) and scales with it; OpenRouter translates `reasoning_effort` per model (some can't turn thinking off:
Qwen3-30B-A3B thinks anyway, gpt-oss refuses).

When the model thinks although the level is `off`, chi says so once per session and host
(`thinking> warning: off wasn't honoured by … (N chars of thinking)`) and logs `thinking_not_honoured` each time.
When a host answers the thinking fields with an HTTP 400 about reasoning (gpt-oss: "Reasoning is mandatory"), chi
sends the request again without them, leaves them out for that model from then on, and says so once.

The fields go under the `sampling:` map ("Sampling"): a `sampling:` key wins over the level's, and
`chat_template_kwargs` merges per sub-key. A `null` there drops a field the level would send, at any depth, for a
host that refuses one of them:

```yaml
hosts:
  strict:
    url: https://llm.example.com/v1
    api: openai
    thinking: off
    sampling: { reasoning_effort: null }   # sends only enable_thinking: false
```

A different level changes a native model's system prompt (Gemma's token, Qwen's turn preamble), so the next turn
reads the whole context again once; on a chat host only the end of the prompt changes.

## Llama HTTP Timeouts

Long-running llama.cpp completions can exceed Ruby's default HTTP read timeout.
Raise these to avoid premature request failures:

- `server.open_timeout` (default: `10`, env `SAMAGOTCHI_SERVER_OPEN_TIMEOUT`) connection timeout in seconds.
- `server.read_timeout` (default: `600`, env `SAMAGOTCHI_SERVER_READ_TIMEOUT`) response read timeout in seconds.
  Either timeout at `0` (or anything not a positive number) is its default, on every host.

```yaml
server:
  open_timeout: 10
  read_timeout: 900
```

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
which applies to every host. With neither set, remote hosts (see "Remote or local" above) get 120 seconds and local
servers no limit: a long prompt evaluation is normal there, and the read timeout catches a dead server.

Every chat request carries the session's id as a `Session-Id` header (next to `User-Agent: chi/<version>`). A
gateway that spreads requests over several providers can key on it to keep one conversation on one provider, so
prompt caches hit and every turn is answered by the same model. Servers that don't know the header ignore it.

Chat requests for a Claude model (an id containing `claude`, such as `anthropic/claude-sonnet-5.5`) on a remote
OpenAI-compatible host get two prompt-cache breakpoints (`cache_control` on the system prompt and on the last
message), so each step reads the earlier prompt from Anthropic's cache instead of paying for it again. The system
prompt goes as two text parts, the breakpoint after the first: everything sessions share, then the model, working
directory and session lines, so a new session reads the shared part from the cache as well; the debug
log's line shows `cache=on`. A provider behind a gateway may still not cache: check the cached tokens in `/stats`.

Anthropic drops a cache entry 5 minutes after its last read, so a session you come back to after a longer pause
writes its prompt again. `cache.ttl: 1h` keeps the breakpoints an hour (the log shows `cache=1h`); a write then
costs 2× the input price instead of 1.25×, so it pays off when you often pause 5–60 minutes between turns.
`cache.key: session` sends the session id as `prompt_cache_key` (OpenAI's API and OpenRouter only; the log shows
`cache_by=session`), which OpenAI uses to route a conversation to the machine that holds its cache:

```yaml
cache:
  ttl: 1h        # 5m (default) or 1h
  key: session   # off (default) or session
```
 Each request's own counts are in the debug log's `generation_completed` line:
`prompt=` (its prompt tokens), `cached=` (read from the server's cache), `cache_write=` (written to it, when the
server reports writes) and `reprefill=` (of the previous request's prompt on the same model, what the server
prefilled again: an `llm_context` edit's cache break, or anything else that rewrote the prompt's middle; only when the
server reports a cached count, and not on the first request after a warm-up); recap and side requests log theirs as `recap request_usage`.

## Llama Model Routing

To explicitly route requests to a named model in llama.cpp, set:

- `default.model` (required; env `SAMAGOTCHI_DEFAULT_MODEL`, `--model` per run): model name/id sent as the `model`
  field on `/completion` requests.

When `default.model` is unset or blank, Samagotchi fails fast with a clear startup/configuration error.

**The default host** is the host named `default`, else the first one under
`hosts:` (without `hosts:`, the `server:` section).

With several `hosts:`, `host:model` (or an alias naming a host) pins the host.
An unqualified model name goes to the default host when its `/models` list has
that exact id, else to the first host in `hosts:` order whose list has it, else
to the default host. Only exact ids count, never a substring: `/model gemma` on
a box that lists `gemma-4-26b` needs `box:gemma` or the exact id. The lists are
known only after `/models` ran (nothing is fetched before the first turn), so
until then an unqualified name goes to the default host; use `host:model` to pin
one. A **remote** host (an `https` url or a public address; see "Remote or local") keeps its model
list for 10 minutes (60s for local hosts).

**The context window** (what the context status and `ctx=` count against) comes from,
first to last:

1. the running server (llama.cpp's `/props` `n_ctx`; a remote host isn't asked),
2. the window the host's model list gives (`context_length`, `context_window`,
   `max_model_len` or llama.cpp's `meta.n_ctx`),
3. `models.<key>.window_tokens` (the key as `sampling:` looks a model up), else
   `hosts.<name>.window_tokens`,
4. `context.window_tokens`, else 256000.

The settings only fill in when the server and its list report nothing: what the
server runs with is the window that counts. Set one for a provider whose list has
no window:

```yaml
hosts:
  work:
    url: https://llm.work.example/v1
    api: openai
    window_tokens: 131072
models:
  qwen3-8b:
    window_tokens: 32768
```

Only `:` names a host: `/` is part of a model id (`openai/gpt-4o` is an
OpenRouter id and goes to the default host as written, even with a host named
`openai`). A `default.model`, an alias or a saved session that still says
`host/model` gets a warning at start; fix it with `host:model`. A `:` in a model
name is often part of the id (`qwen3:8b`, `mistral:7b`,
`unsloth/Qwen3-8B-GGUF:Q4_K_M`), so the part before the first `:` picks a host
only when it is a configured host's name. chi warns at start about a host named
like a model family (`qwen3`, `llama`, `gemma`, …): `qwen3:8b` would go to that
host as `8b`. An unknown prefix is refused with an
error naming it and the configured hosts (with a "did you mean" for a near
miss) when either
- the rest is an `org/model` id (`nosuch:anthropic/claude-sonnet-4`), or
- the prefix is a hosted provider's name: `openrouter`, `openai`, `anthropic`,
  `google`, `gemini`, `groq`, `xai`, `together` or `fireworks`
  (`openai:gpt-4o` with no `openai` host).

The check applies wherever the model comes in: `--model`, `default.model`, an
alias, `/model`, `chi send --new --model`, the web's new-session model and a
delegate's model. Any other unknown prefix (`nosuch:x`) is sent to the default
host as the model id.

### Model aliases

`model_aliases:` maps a name to a model id or `host:model`. An alias works
wherever a model name does (`--model`, `default.model`, `/model`, the web's
new-session model, `chi send --new --model`, a delegate's or fork's model, the
`models:` keys) and the server is sent its target:

- Aliases apply once. An alias whose target is another alias sends that name as
  written, and chi warns about it at start ("aliases don't chain").
- `host:alias` applies the alias on that host. When the alias's target names
  another host, the model is refused (`alias 'tiny' names host 'box', not
  'openrouter'`).
- An alias named like a real model id shadows that id, also as `host:<id>`.
- A session stores the resolved ref (`box:your-small-model-id`) plus the name it
  was typed as, so a resumed session keeps its model when an alias is
  retargeted, and `models: {small: …}` still applies to it.

## Llama Network Retry Behavior

Transient network failures are retried automatically with exponential backoff.

- Default retries: `5` (up to `6` total attempts including the first call).
- Default backoff: `0.5s`, `1s`, `2s`, `4s`, `8s`.
- Retry scope: transient network errors (timeouts, reset connections, EOF/socket reachability failures),
  HTTP 429 and HTTP 500/502/503/504/529. A `Retry-After` header replaces the backoff delay; one longer than
  60s is not waited out and the error is reported instead.
- An HTTP 402 about credit held by in-flight requests (OpenRouter reserves credit for each running request, so
  one session's long request can make another's fail) is retried like a 429, 20s apart unless `Retry-After`
  says otherwise: with the default `retry.max` that is about 100s. With `retry.max: 0` it fails at once.
  Not when its `metadata.reason` is `weight_exceeds_budget`: that request alone is larger than the key's credit
  budget, so it fails at once (lower `default.max_tokens` or raise the key's limit).
- A refused connection (nothing listening) is not retried: the turn fails at once with `can't reach host <name> at
  <address> (connection refused) — is the server running?`.
- A stream that has already produced output is never retried (the retry would repeat it); it fails the turn.
- Cancellation (`Ctrl-C`) is never retried.

Configuration:

- `retry.max` (default `5`, env `SAMAGOTCHI_RETRY_MAX`): number of retries after the first failed attempt.
- `retry.base_delay` (default `0.5`, env `SAMAGOTCHI_RETRY_BASE_DELAY`): backoff base delay in seconds.
- `retry.max_delay` (default `8.0`, env `SAMAGOTCHI_RETRY_MAX_DELAY`): cap for backoff delay in seconds.

```yaml
retry:
  max: 5
  base_delay: 0.5
  max_delay: 8.0
```

`retry.empty_answer` is a different thing: the request worked, but the model's answer had no visible text and no
tool calls (thinking only, or nothing; a thinking loop cut by the provider's output cap looks like this). chi then
asks again in the same turn with a hidden note ("your last reply had no visible answer…"), at `temperature: 0.6`
unless `sampling:` sets one; the REPL prints `↻ empty answer, asking again (1/1)` and the web shows it as a row of
the step. `retry.empty_answer` (default `1`, at most `3`, env `SAMAGOTCHI_RETRY_EMPTY_ANSWER`, no CLI flag) is how
many times per turn; `0` ends the turn at the empty answer as before. An answer cut because the context is full
(90 % or more) is not retried. When the retries run out the turn ends with no answer: every UI shows one muted line,
`no answer: the model returned nothing (after 1 retry)`, and the model is told on its next turn with a hidden note;
no made-up answer is saved.
A generation a plugin cuts while it streams (loop-guard's thinking watch, or any `stop_generation`,
[hooks.md](hooks.md#watching-the-stream)) uses the same budget: `↻ cut by loop-guard, asking again (1/1)`, and with
none left the turn ends as cancelled (hook).
A message for a running turn waits for the next step, unless the model's generation has streamed only thinking for
`steer.cut_after` seconds (default `20`, env `SAMAGOTCHI_STEER_CUT_AFTER`, `0` = never; counted from its first
thinking token, so the wait for a busy server doesn't count) and still does: then a message from you (the terminal,
the web), `chi send` or a parent agent cuts that generation, and the model starts the step again with the message
(`↪ cut in for your message`). A message that comes earlier cuts once the thinking passes `steer.cut_after`, unless
the step ends first and the message goes in there. Such a cut spends no `retry.empty_answer` attempt and sends no
hidden note; only the cut thinking is lost. A generation that has streamed visible text or a tool call is never cut,
and a plugin's steer (`ctx.steer`, `ctx.sessions.send`) never cuts.

Assist-mode UX:

- While waiting, retry notices are rendered in the existing thinking spinner area as a red `network error: retrying ...` status.
- If retry attempts are exhausted, the submitted prompt is restored into the input editor so you can edit and resubmit.

## Server errors

An error status or a server's error event fails the turn with the server's
message (before, a failed llama.cpp `/completion` ended the turn as
`[No response]`). The error names its kind:

| Kind | When | Retried |
|---|---|---|
| connection | reset, timed out, dropped mid-stream; refused | yes (network retry), not mid-stream; refused: no |
| rate limited | HTTP 429 | yes, honouring `Retry-After` |
| credits held | HTTP 402 "… in-flight requests" | yes, after 20s (or `Retry-After`) |
| credits | any other HTTP 402: out of credits; one whose `metadata.reason` is `weight_exceeds_budget` (the request alone is over the key's budget: lower `default.max_tokens`) | no |
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
  `plugins`, `guardrails`, `config`, `memory`, `model` (debug dumps), `context` (attached context fetches),
  `broadcast` (chi broadcast's triage).
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
  max_per_request: 20     # older images become placeholder lines, dropped in batches of half this
```

Whether a model can see images is found out before a turn with images is sent:

- a native llama.cpp host: `/props` must report `modalities.vision` (the server
  runs with `--mmproj`) and a media marker, and the prompt profile must know the
  chat template's image wrapping (qwen36 does; gemma4 not yet);
- mlx and oMLX hosts: no (not verified with recent chi versions);
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

## Desktop helper: agents in kitty

The desktop helper (`chi desktop`) can also paste into agent CLIs (claude,
codex, …) running in [kitty](https://sw.kovidgoyal.net/kitty/) windows. It
lists them only with `kitty.listen_on` set: copy the value of `listen_on` from
your `kitty.conf` as it is (kitty must also have `allow_remote_control` on).

```yaml
kitty:
  listen_on: unix:/tmp/kitty.${KITTY_PID}   # as in kitty.conf; unset = no kitty targets
  binary: /Applications/kitty.app/Contents/MacOS/kitty   # the default
  agents: [claude, codex]   # the programs listed; "*" = every window
```

The helper reads these from its launch file: after editing them run
`chi desktop upgrade` (or `chi update`). See [Desktop helper](desktop.md#agents-in-kitty).

## Project specific description

If an AGENT.md file is present in the project root, samagotchi injects its
contents into the system prompt under a "Project specific description:" section.
The project root is the top of the git work tree chi runs in (a linked
worktree's own checkout), or the current directory outside a repository. An
AGENT.md in the current directory is read instead when there is one; only one
file is read.

To skip loading AGENT.md, set `skip_agent_md: true` at the top level of
`config.yml` (env `SAMAGOTCHI_SKIP_AGENT_MD=true`).

## LLM context: the forget layer

Experimental, off by default. With `forget` in a model's `llm_context.strategy` (next to `stale`), chi offers that
model a tool, `forget_outputs`, to free context by forgetting its own tool outputs. Nothing changes for a model
without it: no ids, no tool, the same prompt.

```yaml
llm_context:
  budget_tokens: 64000        # optional: the [CONTEXT: …] lines count against 64k, not the window
models:
  deepseek-v4.1-flash:
    llm_context_strategy: [stale, forget]
    llm_context_apply: next_request
```

- **Ids.** Every tool output the model sees starts with its id after the tool's name, `[read]` then `[#t41] …`.
  Outputs a session saved before chi gave them ids show none and can't be forgotten.
- **Forgetting.** `forget_outputs(ids: ["t41", "t42"], note: "…")` replaces each output with a stub holding the note
  (`[read] [#t41] (forgotten) …`); the call stays, and the session keeps the outputs. The note is required. Outputs
  one call forgot that follow one another carry the note once: the rest say `(forgotten with t41: see its note)`.
  `keep: ["t42:12-40"]` forgets t42 except those lines, which follow its stub: a read's lines are the file's line
  numbers (a read from `start_line` 120 starts at 120), other outputs count from 1.
- **Refused, per id, with the reason in the result:** an output from the last `llm_context.protect_steps` steps
  before the forget's own (1: the output the model just got); a read of a file edited or written in them, unless the
  forget keeps lines of it; a keep outside the output's lines, of a big file's head/tail preview, or holding all of
  it; an output too small for a stub to free anything; one already stubbed or forgotten; an unknown id, or one whose
  output chi can't pair with its call for sure (it shows no id). The system prompt, user messages, steers and context
  notes have no ids.
- **When stubs reach the prompt** follows `llm_context.apply`, as `stale`'s do: the result says
  `applied, the next request sends the stubs (frees …)` or `staged until the turn ends`.
- **Restore.** `forget_outputs(restore: ["t45"])` brings a forgotten output back with the next request, whatever
  `llm_context.apply` says (the model wants the text now; the result says what the server reads again); a non-read
  stub says `[restore: t45]`. A read whose stub was sent isn't restored (read the file again: it may have changed); one
  still staged is.
- **The description** carries the note contract (facts carried forward, quoted, marked VERIFIED or UNVERIFIED; what
  was ruled out, with the reason and "do not retry"; the commands tried; a NEXT line), the cost of an edit (the
  server reads everything after it again: forget in one batch, older outputs first) and `llm_context.policy`.
- **Offers.** Under `forget` the `[CONTEXT: …]` line becomes a readout, `~52k/64k tokens in use`, and offers the tool
  in tiers, never "forget now": the readout alone in the lower guided buckets; "finish the unit of work in flight,
  then tidy once" in the bucket under the top; "compact settled outputs now: keep what you'll still edit against;
  don't wipe" in the top bucket or over `llm_context.budget_tokens`. They come at a turn's first request (the turn
  before it answered); mid-turn only the top tier offers. Over the budget the compact offer comes every turn.
- `/stats` counts the re-prefilled tokens each applied batch costs; `script/llm_context_bench.rb --strategy
  forget_outputs` replays the offer on stored sessions (docs/internals/llm-context-bench.md).

## LLM context: a session's own strategy

A session can set its own `llm_context` strategy, apply rule and budget, which come before the model's, its host's
and the global ones (resolution: the session, `models.<key>`, `hosts.<name>`, then `llm_context.*`; each value on
its own). The first target is a long session such as a day-long coordinator, where `stale` pays off across many turns.

- **Set it** at start with `chi --llm-context stale,forget --llm-context-apply turn_end --llm-context-budget 64k`
  (the same flags on `chi send --new`), in the session with `/llm-context strategy … apply … budget …`
  (docs/cli.md, "Session commands"), or from the web's `llm ctx` chip in the info bar.
- **A new web chat:** the start page's `llm ctx` chip, beside the model picker, shows the picked model's values
  and follows a model pick. Its form (titled "new chat") sets a choice for that one chat: the chip reads
  `llm ctx stale · new chat` in the accent colour, and the create sends it as `POST /api/sessions`'s
  `llm_context` (`{"strategy": "stale,forget", "apply": "turn_end", "budget": "64k"}`, each a word as
  `/llm-context` takes it, `default` for unset; anything else answers `400 invalid_llm_context` and starts
  nothing), so the session file holds it before the first turn runs. It is not remembered: it resets after a
  create, on a reload and when you open a session (a failed create keeps it), and an untouched chip sends nothing
  (the model's values apply, as without the chip).
- **Values:** `none` and a budget of `off` are values the session sets on purpose (they win over the model's);
  `default` (or `/llm-context reset` for all three) unsets one, back to following the model. A budget is 4k to
  10M tokens (`4000`–`10000000`, or `4k`–`10000k`). The layers are kept in chi's order (`stale`, then `forget`).
  A value in the session file chi can't read (an unknown layer) follows the model and is saved back as written.
- **Kept:** in the session file (`llm_context`), so `--resume` and a respawned worker keep it; a plugin's fork
  copies its parent's; a delegate child starts without one (it follows its own model).
- **When it applies:** from the next turn's start; a running turn keeps the strategy it started with. The command
  runs between turns, like `/model`.
- **Switching on `stale`:** the reads the conversation already holds that a later read superseded go in as one
  batch under the session's apply rule (`next_request`: the next request; `turn_end`: the end of the next turn;
  `payoff`: as for any batch). `/llm-context` says how many.
- **Switching `forget` on or off** changes the tool list (`forget_outputs`), the ids on outputs and the system
  prompt: the next request re-reads the whole prompt once (a full cache break). Turned off, its past `forget_outputs` calls
  and their results stay in the history.
- **Switching a layer off:** its stubs go out whole again from the next request (a cache break from the first). The
  session keeps the originals and the edits, so turning the layer back on brings the same stubs back.
- **Where to see it:** `/llm-context` (each value and where it came from: `the session`, `models: <key>`,
  `hosts entry '<name>'`, `llm_context.*`), `/stats` (`llm context:`), the turn log (an `llm_context` record per
  turn that runs a layer or whose session set its strategy) and the web's chip. A woken worker's status line counts
  its saved context against the session's budget.

## All settings

Every setting below takes the three forms described in
[Environment variables](#environment-variables): a nested key in
`config.yml`, `SAMAGOTCHI_<DOTTED_NAME>` in the environment (not for one
marked config.yml only) and, where the CLI
column says so, a `--kebab-name` flag. The maps (`hosts:`, `models:`,
`model_aliases:`, `hooks:`, `guardrails:` rules, `bundles:`, `memories:`) are
described in their own sections.

| Setting | Default | CLI | What it does |
|---|---|---|---|
| `default.model` | (required) | `--model` | The model a new session starts with; `host:model` pins a host. |
| `default.input` | none | | Text pre-filled at the first prompt (a trailing space is kept); `--no-default-input` skips it. See [CLI](cli.md). |
| `default.max_tokens` | server's | yes | Most tokens one generation may produce (`n_predict` on a native llama.cpp host; OpenRouter: 32768 when unset). |
| `model.profile` | none | `--profile` | Prompt profile for every model (`qwen36`, `gemma4`); env and CLI only. See "Prompt profile". |
| `server.transport` | `llama_cpp` | yes | `llama_cpp`, `mlx` or `omlx`; see "Model Server Transport". |
| `server.host` | `localhost` | yes | The model server when there is no `hosts:` map. |
| `server.port` | `8080` | yes | Its port. |
| `server.open_timeout` | `10` | yes | Connection timeout, seconds. |
| `server.read_timeout` | `600` | yes | Read timeout, seconds. |
| `server.first_token_timeout` | 120 remote, off local | | Seconds to the first token; `0` = off. `hosts.<name>.first_token_timeout` wins. |
| `recap.enabled` | on | | `false` (or `recap: false`) turns the idle recap off. |
| `recap.model` | session's | yes | Model that writes the recap: an id, alias or `host:model` (the host then picks where to ask; a bare id goes where a bare `--model` goes). |
| `recap.host_ref` | session's | yes | A `hosts:` name to ask (`host:` is accepted too, also a host name, not a model ref). |
| `recap.base_url` | none | yes | An OpenAI API base to ask instead (`http://h:8081/v1`). |
| `recap.inactivity` | `180` | yes | Idle seconds before a recap. |
| `recap.timeout` | `30` | yes | Seconds a recap request may take. |
| `recap.min_user_turns` | `2` | yes | Prompts a session needs before it gets a recap. |
| `recap.sentences` | `2-4` | yes | Recap length, `N` or `N-M` (1–10). |
| `broadcast.active_hours` | `8` | | `chi broadcast` reaches a session a worker or a chi REPL runs, or whose last turn ended within this many hours. See [Broadcast](broadcast.md). |
| `broadcast.ticket_pattern` | `\b[A-Z][A-Z0-9]+-\d+\b` | | A Ruby regex for ticket ids; one in the note and in a session's branch (any case) or prompts delivers the broadcast there. See [Broadcast](broadcast.md). |
| `broadcast.triage_model` | recap's | | The model that judges a recipient no tag matched (a model ref, as `recap.model`); unset: the recap's model, else `default.model`. A ~9B dense instruct model or larger; 4B-class ones say yes to nearly everything. See [Broadcast](broadcast.md#triage). |
| `broadcast.triage_host_ref` | none | | A `hosts:` name for the triage model. |
| `broadcast.triage_base_url` | none | | An OpenAI API base for the triage model instead (`http://h:8081/v1`). |
| `broadcast.triage_parallel` | `4` | | Triage requests at a time. |
| `broadcast.triage_deadline` | `20` | | Seconds triage may take in all; a recipient not judged by then gets the note unchecked. |
| `broadcast.threshold` | `0.5` | | The P(yes) a recipient needs, when the triage host gives logprobs; a plain yes or no is 1 or 0. |
| `session.shared` | `true` | | Plain `chi` runs its session in a worker and attaches; `--no-shared` per run. |
| `session.idle_exit_minutes` | `30` | yes | An unused worker exits after this; `0` = never. |
| `session.keep_empty` | `false` | | Keep sessions nothing happened in. |
| `session.max_children` | `4` | | Running delegated sessions one session may have. |
| `session.delegate_reports` | `wake` | | When a delegate child ends a turn, its reply reaches the parent: `wake` runs an idle parent's turn for it, `queue` waits for the parent's next turn, `off` leaves it to `delegate_result`. |
| `session.max_wakes` | `10` | | Turns a parent runs for delegate reports in a row with no human input; past it reports wait for the next turn. |
| `session.retention_days` | `14` | yes | Delete sessions not updated for N days; `0` = forever. See [Sessions](sessions.md). |
| `session.max_count` | `500` | yes | Keep the newest N; `0` = uncapped. |
| `session.keep_status` | none | yes | Comma list of statuses never pruned (a session a worker or `chi` has open is never pruned anyway). |
| `session.sweep_interval_hours` | `24` | yes | How often the retention sweep runs. |
| `image.max_side` | `1568` | | See "Images". |
| `image.max_bytes` | `3750000` | | See "Images". |
| `image.max_per_request` | `20` | | See "Images". |
| `guardrails.enabled` | `true` | | `false`: no rules, and hooks' asks are dropped (a deny still applies). config.yml only: a worker unsets any `SAMAGOTCHI_GUARDRAILS_*` it inherits. See [Guardrails](guardrails.md). |
| `guardrails.mode` | `auto` | | Which rules vote: `auto` leaves out the rules tagged `modes: [strict]` (in the guardrails bundle: `git rebase`, writes and git outside the session's repo); `strict` runs them all. An unknown value warns and is `auto`. config.yml only. See [Guardrails](guardrails.md#modes). |
| `guardrails.small_models` | `auto` | | Which models get the `models: small` rules: `auto` (32B or less by the size in the name, an MoE's active size), a list of globs, or `[]`. config.yml only. See [Guardrails](guardrails.md#rules-for-some-models). |
| `guardrails.parent_approvals` | `off` | | What `chi answer` lets a parent agent allow on an approval: `off` (deny only) or `once` ("Allow once", never a wider scope). config.yml only: no environment variable (a parent can still pick the config dir with `XDG_CONFIG_HOME`). A convention for an honest parent, not a security boundary. See [Guardrails](guardrails.md#approvals-from-a-parent-agent). |
| `log.file` | state dir | yes | See "Debug Log File". |
| `log.disable` | `false` | yes | No file logging. |
| `log.level` | `info` | yes | `debug`, `info`, `warn`, `error`. |
| `status.line` | `on` | yes | The status row under the prompt (the REPL's and attached mode's), `on` or `off`. |
| `context.status` | `true` | yes | Context-usage telemetry for the model. See [context telemetry](internals/context-telemetry.md). |
| `context.window_tokens` | server's, else 256000 | yes | Context window when the server doesn't report one. `models.<key>.window_tokens` and `hosts.<name>.window_tokens` come first; see "The context window". |
| `models.<key>.window_tokens`, `hosts.<name>.window_tokens` | none | | A model's or host's context window when the server and its model list report none. |
| `llm_context.strategy` | `none` | | What the model is sent of the conversation: `none` (everything, unchanged), or a list of layers (`stale`, `forget`; `"\|"`-separated or a YAML list). `stale`: a file read that a later read covering its lines superseded (a read that came back whole: not the head/tail preview of a big file, nor cut at `max_tool_output_chars`) is sent as a stub (`[read] lib/x.rb lines 1-200: superseded by a later read`). With `llm_context.stale_edits: true` (opt-in, experimental) so is a read a later successful edit or write of the file superseded (`superseded by a later edit`); on the replay bench these stubs cost about 5x the tokens they free in re-prefill, and 26% of them were needed again (against a 6% base rate). No read of a file edited or written in the last `llm_context.protect_steps` steps is stubbed. When stubs reach the prompt is `llm_context.apply`: `next_request` sends a read a later read superseded from the next request, and an edit-driven stub at the end of a turn the model answered; `turn_end` sends them all at the end of a turn the model answered (a turn that ran out of steps keeps them staged; on the native loop against a local llama.cpp the turn-end warm-up prefills the edited prompt, elsewhere the next turn's first request carries the cache break); `payoff` sends the batch at a request when the tokens it frees are at least the tail after its earliest stub (what the server reads again), or the context is in the top `context.status_thresholds` bucket (which needs `context.status` on), else at the end of a turn the model answered. A re-read's tail holds the later read, so in practice payoff usually waits for the turn's end. Each batch breaks the prompt cache from its earliest stub; `/stats` counts the re-prefilled tokens. The session keeps the outputs and the stubs it sent, so a `--resume` sends the same. `forget` (experimental) offers the model the `forget_outputs` tool; see "LLM context: the forget layer". An unknown name warns and is `none`. A session's own (`chi --llm-context`, `/llm-context`; "LLM context: a session's own strategy"), then `models.<key>.llm_context_strategy` and `hosts.<name>.llm_context_strategy` come first. |
| `models.<key>.llm_context_strategy`, `hosts.<name>.llm_context_strategy` | none | | A model's or host's `llm_context.strategy`. |
| `llm_context.apply` | `payoff` | | When a layer's edits reach the prompt (each batch breaks the prompt cache from its earliest edit): `payoff`, `next_request` or `turn_end`. An unknown value warns and is `payoff`. A session's own (`--llm-context-apply`, `/llm-context apply`), then `models.<key>.llm_context_apply` and `hosts.<name>.llm_context_apply` come first. |
| `models.<key>.llm_context_apply`, `hosts.<name>.llm_context_apply` | none | | A model's or host's `llm_context.apply`. |
| `llm_context.stale_edits` | `false` | | Opt-in, experimental: `stale` also stubs a read that a later successful edit or write of the file superseded. |
| `llm_context.protect_steps` | `3` | | `stale` never stubs a read of a file edited or written in the last N steps (tool batches; counted across the whole conversation, not only the turn). `0` turns the protection off. Under `forget`, `forget_outputs` refuses an output from the last N steps, and a read of a file edited or written in them unless the forget keeps some of its lines. |
| `llm_context.budget_tokens` | none | | A soft context budget in tokens (e.g. `64000`); off when unset or `0`. When set, the context status buckets (`context.status_thresholds`) count against it instead of the window (the smaller of the two), so the `[CONTEXT: …]` lines, `payoff`'s top bucket and, under `forget`, the `forget_outputs` offers come under it. A session's own (`--llm-context-budget`, `/llm-context budget`; `off` there wins over the model's), then `models.<key>.llm_context_budget_tokens` and `hosts.<name>.llm_context_budget_tokens` come first. |
| `models.<key>.llm_context_budget_tokens`, `hosts.<name>.llm_context_budget_tokens` | none | | A model's or host's `llm_context.budget_tokens`. |
| `llm_context.policy` | the subtask-boundaries line | | The sentence `forget_outputs`' description carries (the `forget` layer): "Tidy at subtask boundaries: once a subtask is done, forget its tool outputs and note what it established; keep anything you'll still edit against." Blank: none. Read when a session starts. |
| `context.chars_per_token` | `4.0` | yes | Estimate ratio when the server reports no usage. |
| `memory.index_warn_tokens` | `2500` | yes | The tokens one scope's memory index (project or system; sent with every prompt) may hold before a `memory_write`, `write` or `edit` that takes it over gets a note asking the model to tighten long index descriptions; `0`: no note. Estimated as characters / `context.chars_per_token`. `memory:` is its own section, not the `memories:` preload list. See [Memory](memory.md). |
| `context.status_thresholds` | `20,40,60,80` | yes | Percentages that trigger a status. |
| `context.status_cadence` | `0` | yes | Also every N rounds; `0` = thresholds only. |
| `context.every_seconds` | `300` | | How often an attached context source's command runs when it has no `--every` (seconds, at least 30). See [Attached context](context.md). |
| `context.wake` | `true` | yes | A source whose update says `wake: true` may start a turn in a live, idle session (one per source per 10 minutes, within `session.max_wakes`); `false`: updates wait as notes for the next turn. See [Waking](context.md#waking). |
| `thinking.turn_preamble` | `true` | yes | Ask a `qwen36` model to open its thinking with a short `TURN:` line (the step label). |
| `thinking.level` | `default` | `--thinking` | `off`, `low`, `medium`, `high` or `default` for every model; the flag and env outrank the `models:`/`hosts:` entries, the file's value doesn't. See "Thinking". |
| `models.<key>.thinking`, `hosts.<name>.thinking` | none | | A model's or host's level. See "Thinking". |
| `hosts.<name>.remote` | by address | | `true`/`false`: treat the host as a remote provider or a local server. See "Remote or local". |
| `max_tool_output_chars` | `10000` | yes | Characters of each tool output kept in the conversation (both loops); a longer one is cut and ends with `[cut: N of M chars; read it in parts]`. A top-level key (see below). |
| `cache.warmup` | `auto` | | `auto`: after a turn, send the next turn's prompt (up to the next message) to a local llama.cpp host on the native loop, so the next turn prefills only its message; never a remote or `api: openai` host. `off`: never. See [prompt caching](internals/prompt-caching.md#the-turn-end-warm-up). |
| `cache.ttl` | `5m` | | How long Anthropic keeps the prompt-cache breakpoints of a Claude model on a remote host: `5m` (Anthropic's default) or `1h`. A 1h cache write costs 2× the input price (5m: 1.25×), a read the same 0.1×. See "Remote or local". |
| `cache.key` | `off` | | `session`: send the session id as `prompt_cache_key` to OpenAI's API and OpenRouter, which route and cache by it; no other host gets it. `off`: none. |
| `retry.max` | `5` | yes | See "Llama Network Retry Behavior". |
| `retry.base_delay` | `0.5` | yes | |
| `retry.max_delay` | `8.0` | yes | |
| `retry.empty_answer` | `1` | | Times a turn asks again after an empty answer (at most 3, `0` = off). See "Llama Network Retry Behavior". |
| `steer.cut_after` | `20` | | Seconds a generation must have streamed only thinking before a message for the running turn (yours, `chi send`'s, a parent agent's) cuts it; `0` = never. See "Llama Network Retry Behavior". |
| `turn.max_iterations` | `100` | | A turn's step limit: model ↔ tool rounds before it stops and asks to continue (an integer ≥ 1). `--no-interrupt` turns get the larger of 1000 and this. See [CLI: Iteration Limit Behavior](cli.md#iteration-limit-behavior). |
| `turn.parent_continue` | `true` | | Whether a parent agent (`chi answer`) may answer Continue to a session's step-limit question; `false`: Stop only. config.yml only: no environment variable. See [Sub-agent](sub-agent.md) and [Guardrails](guardrails.md#approvals-from-a-parent-agent). |
| `update.gem` | `true` | | `false`: `chi update` never installs a newer gem (`--no-gem` for one run). See [CLI: Updating](cli.md#updating). |
| `update.bundles` | `true` | | `false`: `chi update` leaves the shipped bundles to `chi bundle upgrade` (`--no-bundles`). |
| `update.desktop` | `true` | | `false`: `chi update` leaves the desktop helper alone (`--no-desktop`). |
| `kitty.listen_on` | none | | The desktop helper's kitty socket, copied from `kitty.conf`; unset = no kitty targets. See "Desktop helper: agents in kitty". |
| `kitty.binary` | `/Applications/kitty.app/Contents/MacOS/kitty` | | The kitty the helper runs `kitty @` with. |
| `kitty.agents` | `claude\|codex\|gemini\|aider\|opencode\|cursor-agent\|amp\|goose` | | Foreground programs whose kitty windows the helper lists, `\|`-separated (a YAML list works too); `*` lists every window. |
| `read.truncate_at_bytes` | `65536` | yes | A `read` result larger than this is cut to a preview. |
| `read.preview_bytes` | `12288` | yes | Size of that preview. |
| `read.hard_max_bytes` | `2097152` | yes | Largest file `read` opens. |
| `read.telemetry_threshold_pct` | `80` | yes | A `read` result that alone fills this % of the context window carries a token estimate. |
| `execute.truncate_at_bytes` | `65536` | yes | The same for `execute` output. |
| `execute.preview_bytes` | `12288` | yes | |
| `execute.telemetry_threshold_pct` | `80` | yes | |
| `execute.timeout_sec` | `120` | yes | Seconds one `execute` command may run before it is stopped. |
| `execute.description` | `true` | | `execute` offers the model an optional `description` (a few words on what the command does), shown as the tool row's title in `chi web` and in place of the command in the TUI's tool line. `false`: the parameter isn't declared, and rows show the command's first step. |
| `web.port` | `4567` | `--port` | `chi web`'s port. See [CLI](cli.md). |
| `web.host` | `127.0.0.1` | yes | `127.0.0.1`, `::1` or `localhost`; `lan` (this machine's private IPv4 address) or one of its IPv4 addresses also opens `chi web` to the network, with an access token (`chi web --new-token` replaces it). Anything else binds `127.0.0.1` with a warning. See [CLI: chi web on your phone](cli.md#chi-web-on-your-phone). |
| `web.markdown` | `false` | yes | Render answers as Markdown in `chi web`. |
| `web.view` | `stage` | yes | How `chi web` draws a turn: `stage` (the running turn pinned above the composer) or `turn` (one block per turn in the history). See [CLI](cli.md#web-views). |
| `web.annotate_presets` | `Agreed\|Could you please elaborate?` | yes | Quick replies next to Annotate in `chi web`, `\|`-separated (a YAML list works too); `""` in the file or on the CLI leaves only Annotate (an empty env value means the default). See [CLI](cli.md#web-annotate-presets). |
| `history.file` | state dir | | Prompt history path, shared by the TUI and the web composer. |
| `no_interrupt` | `false` | `--no-interrupt` | Raise the step limit of a turn to 1000 (or `turn.max_iterations`, when larger); a top-level key. |
| `no_default_input` | `false` | `--no-default-input` | Don't pre-fill `default.input`; a top-level key. |
| `skip_agent_md` | `false` | | Don't load AGENT.md; a top-level key (see below). |

`max_tool_output_chars`, `skip_agent_md`, `no_interrupt` and
`no_default_input` have no section: in `config.yml` they are top-level keys as
written (`max_tool_output_chars: 20000`).
