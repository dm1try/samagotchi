# Configuration

## Global Config File

Chi reads its settings from three places; the first that sets a value wins:

1. a CLI flag (`--server-port 8081`),
2. an environment variable (`SAMAGOTCHI_SERVER_PORT=8081`),
3. the global config file (`server: {port: 8081}`),

then the built-in default. [All settings](#all-settings) lists them.

`chi bootstrap HOST[:PORT]` writes a first config for a model server (llama.cpp, OpenAI-compatible or Anthropic
Messages), or adds it to this file as a `hosts:` entry (see [First setup](cli.md#first-setup)).

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
# A host talks llama.cpp's own API (api: llama_cpp, the default); api: openai
# makes it use the OpenAI chat API instead of chi's raw prompt.
hosts:
  main:
    host: localhost
    port: 8080
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
# a warning. recap: false turns it off. Each recap also names the session with
# a short auto title (shown when it has no /title), in the same request.
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
  # task_wakes: wake        # a background task finishing unseen: wake (an idle session runs a turn), queue, off
  # max_wakes: 10           # wake turns in a row (delegate reports, finished tasks, context, peers) with no human input

# Baseline memories preloaded into the system prompt (same shape as --memory);
# name entries you have, or chi warns at each start.
# CLI --memory entries are appended after these, deduped.
memories:
  # - system/user_preferences
  # - project/feature-env-template

# Files whose text goes into the system prompt after AGENTS.md (same as
# --append-system-prompt, which adds to these). A relative entry is looked up
# in the directory chi runs in; a missing one is skipped.
append_system_prompt:
  # - CLAUDE.md
  # - ~/notes/house-rules.md
```

Behavior:

- The file is optional.
- Top level is a YAML mapping of sections (`default:`, `server:`, `recap:`, …)
  and the maps described below. Keys are lower `snake_case`, one level per
  dot: `server.read_timeout` is `server: {read_timeout: 600}`.
- Each key takes its own type: a number, a boolean (`true`/`false`, and
  `yes`/`on`/`1`, `no`/`off`/`0`), text, or one of the words the setting
  allows (`auto`, `audit`, `on`, …). YAML 1.1 reads an unquoted `on`, `off`,
  `yes` or `no` as a boolean, so for a setting whose values are `on` and
  `off` an unquoted `off` is the same as `"off"` (`guardrails.system_one.mode: off`,
  `session.task_wakes: off`).
- A key chi doesn't read warns at start, with the closest known key:
  `config: unknown key 'default.modle' (did you mean 'default.model'?)`.
  Names you choose under the maps below (host names, model ids) don't warn.
- Environment variables and CLI flags win over config-file values.
- An edit to the file needs no restart of `chi web`. A new worker reads the
  file when it starts; a running worker sees only settings whose readers check
  the file again (see [When a change applies](#when-a-change-applies)). The web
  model picker refreshes `hosts:` when the file changes, but a running worker
  keeps its host registry until it is restarted. A worker gets the CLI flags of
  the chi that started it through its environment.
- A newly started worker reads `hosts:` from the file, so a delegate (or any
  session started later) sees a host added after its parent started. Hosts
  come only from config.yml: no environment variable sets them.

This lets you run `chi` without repeating common defaults such as model
and llama host/port on every invocation.

Besides the settings sections, the file holds maps that are read by their
own subsystems: `hosts:` (below), `models:` (see "Prompt profile" and
"Images"), `model_aliases:`, `hooks:` (see [Hooks](hooks.md)),
`guardrails:` (see [Guardrails](guardrails.md)), `bundles:` (a bundle's
settings for its hooks, see [Hooks: Settings](hooks.md#settings); a session's own
`--set BUNDLE.KEY=VALUE`, for a key the bundle's manifest lists in `session_settings:`, lays over them, see
[Per-session settings](plugins.md#per-session-settings); `--set KEY=VALUE` does the same for a few core keys,
see "Per-session settings" below),
`memories:` and `append_system_prompt:` (see "Appended prompt files"). Their entry names (host names, model ids, aliases) are yours to
choose. The `memories:` list is the persistent baseline for preloaded memory entries —
the same name shape as `--memory` (bare name or `scope/name`), merged under
any per-run `--memory` values (config baseline first, deduped). A per-run
`--mute NAME` removes an entry from the merged list for that session (see
"Muting a memory" in cli.md).

## When a change applies

The config reader checks the file's modification time and size whenever a
setting is read. That makes a changed value available to a live reader; it
does not reload every object that already holds a snapshot. "Worker start"
includes a worker respawn. A running turn keeps the settings it already
resolved. chi tells you when a changed setting applies only after a worker
or `chi web` restart.

| Key | Applies | Note |
|---|---|---|
| `default.model` | New session | Existing sessions keep their saved model; change one with `/model`. |
| `default.input`, `no_default_input`, `no_interrupt` | Next CLI run | These set up that run's first prompt or turn limit. |
| `default.max_tokens`, `max_tool_output_chars`, `read.*`, `execute.*` except `execute.description`, `image.*` | Next matching request or tool use | An operation already in progress keeps its resolved limits. |
| `server.host`, `server.port`, `hosts.*` | Worker start | Includes host addresses, APIs, declared models and host-level settings. The web model picker refreshes `hosts:` on file change; a running worker does not. |
| `server.open_timeout`, `server.read_timeout`, `server.first_token_timeout` | Worker start | The worker's clients retain the timeouts set when they were built. |
| `model_aliases` | Next model lookup | A session keeps its resolved model unless it is explicitly switched. |
| `models.<key>.profile` | Session start or `/model` | It is resolved when that model is selected; editing it does not switch the current model's profile by itself. |
| Other `models.<key>.*` settings | Next turn or model lookup | Sampling, thinking, vision, context, window, price and steer settings are resolved from the file for their next use. |
| `thinking.level` | Next turn start | A session's own `/thinking` level is saved in that session and takes precedence; a running turn keeps its level. |
| `turn.max_iterations` | Next turn start | The configured step limit is resolved when each turn begins. |
| `cache.*` | Next request or turn-end warm-up | Cache key and TTL are read for a request; warm-up is checked after a turn. |
| `retry.max`, `retry.base_delay`, `retry.max_delay` | Worker start | The client's network retry policy is built with its HTTP client. |
| `retry.empty_answer` | Next empty-answer retry | It is checked when a turn needs to retry an empty answer. |
| `memories` | Worker start | The running engine holds its preload list. The config list is not saved in the session file, so a respawn reads the current list. |
| `append_system_prompt` | Worker start for the file list | The config list is not saved in the session file. File text is read when the prompt is built; `/model` rebuilds it, while an already-built prompt is cached. CLI `--append-system-prompt` files are saved in the session. |
| `toolkit.default`, `toolkit.child` | Session creation | The chosen toolkit is saved; changing the defaults does not move existing sessions. |
| `toolkit.kits`, `execute.description`, `llm_context.policy` | Worker start | These are held by the engine's toolkit or tool registry. |
| `toolkit.suggest.mode`, `toolkit.suggest.threshold`, `toolkit.suggest.defer_turns`, `toolkit.suggest.defer_tokens` | Worker start | Suggestion settings are config-only and are resolved when the worker runs its audit or on-mode ask. |
| `skip_agents_md` | Prompt rebuild | A running engine caches its built prompt; a new worker or `/model` rebuild uses the changed value. |
| `context.*` except `context.every_seconds`, `llm_context.*` except `llm_context.policy`, `steer.cut_after`, `memory.index_warn_tokens`, `status.line`, `web.participants.*` | Next matching turn, display, poll or write | Readers resolve these settings when they perform that operation. Session-specific LLM context and thinking values remain saved in the session. A participant's grant keeps the expiry and cap it was issued with; `web.participants.*` is what the next invite gets, and the cap and queue of a grant from before caps. |
| `context.every_seconds` | Next context poll | The poller checks it for each source that has no explicit interval. |
| `guardrails.*` | Next tool call or approval | Guardrail rules and disable lists are reloaded when the config file changes; rule settings take effect on that evaluation. `guardrails.parent_answers` is checked when a parent answers a question. |
| `hooks`, `bundles` | Worker start | Hooks, plugins and their bundle settings load with the engine. |
| `recap.*` | Worker start | The engine builds its recap job at start, and again when it binds a session with its own `recap.enabled` or `recap.sentences` (`--set`, see "Per-session settings") and when `/recap on\|off\|default` changes the session's own value. |
| `session.shared` | Next `chi` invocation | It selects attached-worker or in-process mode for that invocation. |
| `session.idle_exit_minutes`, `session.keep_empty`, `session.max_children`, `session.delegate_reports`, `session.task_wakes`, `session.max_wakes` | Worker start or next matching lifecycle decision | Existing workers keep their idle-exit timer; the other values are read for the next corresponding decision. |
| `session.retention_*`, `session.max_count`, `session.keep_status`, `session.sweep_interval_hours` | Next retention sweep | `chi web` sweeps on its configured schedule and on `GET /api/sessions`; `chi sessions prune` uses the values for that invocation. The sweep interval is checked on the next hub tick. |
| `web.*` except `web.participants.*` | `chi web` start | Restart `chi web` to change its bind address, port or page settings. |
| `log.*` | Process start | Each process holds its configured log sink and level after first use; restart that process. |
| `history.file` | Next history access | The TUI and web composer resolve its path when they read or append history. |
| `broadcast.*` | Next `chi broadcast` | Each broadcast invocation reads its targeting and triage settings. |
| `update.gem`, `update.bundles`, `update.desktop` | Next `chi update` | The command reads which components to update when it runs. |
| `update.notify`, `update.check_hours`, `update.min_age_hours` | `chi web` start | The update checker starts with chi web; restart it to apply changes. |
| `kitty.*`, `tmux.*` | `chi desktop upgrade` or desktop update | These settings are copied into the desktop helper's launch file. |
| `model.profile`, `reasoning_history` | Not from config.yml | These are CLI/environment settings; `models:` and `hosts:` provide their model- and host-specific forms. |

### Per-session settings

A few core keys can be set for one session: `chi --set KEY=VALUE` (or `chi send --new --set KEY=VALUE`, or
`POST /api/sessions` `settings`) at its creation, and `recap.enabled` later too with `/recap on`, `/recap off` or `/recap default`
(at once; `default` removes the session's own value, see [Session recap](cli.md#session-recap)). The value is saved in the session file (`config_settings`), so a
worker respawn, a continue and a fork keep it; a delegate child starts without it, on config.yml's. It goes first:

    session (--set) → CLI → environment → config.yml → default

- `recap.enabled`: `true` or `false` (also `yes`/`on`/`1`, `no`/`off`/`0`); `true` turns the recap on for the
  session even under `recap: false`.
- `recap.sentences`: `N` or `N-M` (1–10).

A value is typed by its key and checked when given: `--set recap.enabled=maybe` is refused (`recap.enabled takes
true or false, not "maybe"`), and so is a key no session sets (`--set guardrails.mode=strict`: not a session
setting). The same `--set` takes a bundle's `BUNDLE.KEY` (see [Per-session settings](plugins.md#per-session-settings));
a name that is a core key is always the core one, and a bundle can't offer a setting whose `NAME.KEY` is one.
`/stats` lists a session's own values (`settings: recap.enabled=false · cost-cap.cap=3`), and `chi sessions stats
--format json` has them as `settings`.

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

A few environment variables are not settings (no config.yml key, no flag):

- `SAMAGOTCHI_SKIP_SYSTEM_BUNDLE=1` (or `true`): don't install or upgrade the system bundle
  (`samagotchi-system`) into the system memories; chi uses whatever is installed there. For isolated runs and
  specs. `chi bundle try` drops it from its sandboxed child, so the sandbox gets the system bundle installed.
- `SAMAGOTCHI_BOOT_FALLBACK`: internal. A worker's boot line sets it when the newest installed chi failed to
  load and the worker fell back to its starter's version; the worker reads and unsets it, and logs
  `boot_fallback` with the error. See [Sessions](sessions.md) (Which chi a worker runs).
- `SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI=1`: internal. Set beside `SAMAGOTCHI_DEFAULT_MODEL` for a worker a
  `chi --model X` spawned: X is that run's model, which the chi its commands run must not inherit.
- `SAMAGOTCHI_LOG_STRICT=1`: an unknown log tag or a malformed log event raises instead of being dropped. The spec
  suite sets it, and a bundle's tests keep it (`Samagotchi::Testing::Sandbox`).

## Model Server API

Chi talks to a model server over HTTP in one of two ways, set by the host's `api:`:

- `llama_cpp` (the default): chi's own raw-prompt loop on llama.cpp's native `/completion`,
  `/models` and `/props` endpoints;
- `openai`: the OpenAI chat API at `http://HOST:PORT/v1`, or at `url:` (see below);
- `anthropic`: the Messages API, see [Anthropic Messages hosts](#anthropic-messages-hosts).

Without `api:` a host (and the `server.host`/`server.port` one when there is no `hosts:` map)
uses the raw-prompt loop. There is no transport setting: `server.transport`, a host's
`transport:` and `SAMAGOTCHI_SERVER_TRANSPORT` were removed with the `mlx` and `omlx`
transports. Still set to `llama_cpp`, each warns at start and changes nothing (remove it);
set to `mlx` or `omlx`, chi stops with the line below. The loop follows the
model's host, so `/model other-host:model` can move a session between the two.
Workers started by plain `chi`, `chi web` or `--attach` get the same hosts, `api:` included.

**mlx-lm and oMLX** ([mlx-lm](https://github.com/ml-explore/mlx-lm)'s `mlx_lm.server`,
[oMLX](https://github.com/jundot/omlx)) are chat hosts: give them `api: openai` with their `/v1` url.
chi's own `mlx` and `omlx` transports were removed (their chat endpoint matched or beat them); a config
still naming `api:`/`transport:` `mlx` or `omlx` stops chi at start with one line saying what to write.
oMLX's default port is `8000`; an oMLX started with an API key needs `api_key_env:`:

```yaml
hosts:
  omlx:
    url: http://192.0.2.10:8000/v1
    api: openai
    api_key_env: OMLX_API_KEY
```

Name the model exactly as the server's `/v1/models` lists it (oMLX: e.g. `mlx-community--Qwen3.6-35B-A3B-4bit`;
a short name 404s): `chi models` and the `/model` picker show them. Tool calls come back as the chat API's own
`tool_calls`, and the model's reasoning as thinking.

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
provider's key comes from the environment variable that `api_key_env:` names
(on macOS, else from the login Keychain: [API keys from the Keychain](#api-keys-from-the-keychain));
the key itself never goes into config.yml, `chi self`, logs or events, and
workers get it by inheriting the environment:

```yaml
hosts:
  fw:
    url: https://api.fireworks.ai/inference/v1
    api: openai
    api_key_env: FIREWORKS_API_KEY
```

`chi self` shows the variable and whether it is set (`api key  FIREWORKS_API_KEY (set)`), or comes from the
Keychain (`(keychain)`).

Every host with `api_key_env:` sends `Authorization: Bearer <key>` on each request (`api: anthropic`:
`x-api-key: <key>`, see [Anthropic Messages hosts](#anthropic-messages-hosts)),
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
a chat `api:` keep using llama.cpp's native `/completion`.

### API keys from the Keychain

On macOS a key whose variable is unset (or blank) comes from the login Keychain: the generic password with
service `chi` and account the variable's name. Apps macOS starts (the [desktop helper](desktop.md), launchd, a
`chi web` started at login) get no shell exports, so this is how their sessions reach a keyed host. The variable
still wins when it is set. Store a key once (`-w` last prompts for it, so it stays out of your shell history;
`-U` updates an existing one):

```
security add-generic-password -s chi -a FIREWORKS_API_KEY -w
security add-generic-password -U -s chi -a FIREWORKS_API_KEY -w
security delete-generic-password -s chi -a FIREWORKS_API_KEY
```

chi runs `/usr/bin/security find-generic-password -s chi -a VAR -w` when a request needs the key, with a 5 s
deadline (a locked keychain, e.g. over SSH, is a miss, not a hang). A found key is kept for the process; a miss
isn't, so a key you add works on the next turn without a restart. Create items with `security` as above: an item
made in Keychain Access or by another app may raise an "allow access" dialog the worker waits on until the
deadline (or add `-T /usr/bin/security`). An unset key's error names the `security` command;
`chi self` says `VAR (keychain)`, `chi desktop status` which keys the helper gets.
`SAMAGOTCHI_KEYCHAIN=off` turns the Keychain off for a process and everything it starts (the spec suite sets it).
Linux has no fallback: the variable only.

### Anthropic Messages hosts

`api: anthropic` makes a host talk Anthropic's Messages API (`POST {url}/v1/messages`) through the same chat loop:
Anthropic's own API, a gateway that serves `/v1/messages`, or a local server that does (Splash). The url is the API
root **without** `/v1`, as `ANTHROPIC_BASE_URL` takes it (a url that ends in `/v1` is accepted: no second `/v1` is
added); an entry with neither `url:` nor `host:` talks to `https://api.anthropic.com`. The key goes in the
`x-api-key` header; `auth: bearer` sends it as `Authorization: Bearer` instead (a gateway or provider that wants
that), `auth: x-api-key` is the default spelled out. Exactly one of the two headers is sent.

```yaml
hosts:
  claude:
    api: anthropic
    api_key_env: ANTHROPIC_API_KEY
  gateway:
    url: https://gateway.example.com
    api: anthropic
    api_key_env: GATEWAY_KEY
    auth: bearer
  splash-msg:
    url: http://192.0.2.10:8000
    api: anthropic
```

`auth:` works on any host (`bearer` is the default everywhere but `api: anthropic`).

`chi bootstrap https://api.anthropic.com --key-env ANTHROPIC_API_KEY` writes such an entry (a gateway: its url;
`--api anthropic` / `--dialect fireworks` when the detection can't tell, see [First setup](cli.md#first-setup)).

**Claude 5.x preserved thinking:** Claude 5.x models (Opus, Sonnet and Haiku 5.5, Fable 5.1) bind each thinking
block to everything before it: the system prompt, the tools and the earlier messages. chi keeps the history
append-only, but the system prompt or the tools can change under a session: a resume or a worker respawn after
memory or AGENTS.md edits, `/model`, `/thinking`, `/toolkit`, a plugin's tools, or an `llm_context` layer stubbing
older outputs. Then the API refuses the earlier thinking once (HTTP 400 "… bound to a different conversation"); chi
asks again with Anthropic's binding controls (or without those blocks), drops that thinking from the session for
good, and no turn fails. `/stats` counts it (`thinking dropped: N blocks (preserved-thinking recovery)`), and each
time costs one extra (free) 400 and one cache write. `reasoning_history` on these hosts is `all` by default; `turn`
drops more reasoning but never needs a recovery at a turn's start. Fireworks, Splash and other non-Claude models
never see these requests. internals/anthropic.md has the details.

The loop, tools, events, hooks and UIs are the chat loop's, as for `api: openai`; only the wire differs: the
system prompt goes as the request's `system` (later system notes as user text), tool calls as `tool_use` blocks,
results as `tool_result` blocks, images as `image` blocks; thinking streams into the thinking lane; usage counts
cache reads and writes into the prompt (so `/stats` shows them). Without `default.max_tokens`, `max_tokens` is the
model list's `max_tokens` capped at 64000, else 64000 (Messages requires one). chi's OpenAI-only request fields are
never sent there; `sampling:` passes as written.

Its model list is `GET {url}/v1/models` (every page): Anthropic's shape (the window from `max_input_tokens`, images
from `capabilities.image_input`) or the OpenAI shape a gateway, Splash or Fireworks serves there (images from
`input_modalities`, `vision` or `supports_image_input`). A gateway whose list lacks an
id (a high-availability alias) takes it from the host's declared `models:`, as on any host.

**Dialects.** A provider whose `/v1/messages` departs from Anthropic's gets `dialect:` on its host (only on
`api: anthropic`; an unknown value, or a dialect on another api, warns once and is ignored). `chi self` names it on
its `loop` line. `dialect: standard` is the default written out. There is one other dialect today, `fireworks` (Fireworks' Anthropic-compatible API, directly or behind a gateway):

- the key goes as `Authorization: Bearer` (an explicit `auth:` still wins);
- thinking at `low`/`medium`/`high` is `{type: "adaptive"}` with `output_config.effort`, without `display` (Fireworks'
  schema has none and refuses unknown fields; it returns thinking by default); a model switched to the budget form gets
  none either;
- no `cache_control` breakpoints (Fireworks caches prompt prefixes by itself);
- `x-session-affinity: <session id>` beside `Session-Id`, so a session stays on one replica, where its cache is.

A host without `dialect:` is standard Anthropic (Claude, Splash). Give each upstream kind its own host entry: when a
gateway serves both Fireworks models and Claude ids on one url, the Claude ids go on a second entry with the same url
and no `dialect:` (Claude wants `display: summarized` and the breakpoints).

```yaml
hosts:
  work-msg:                               # the work gateway's Messages route, Fireworks behind it
    url: https://gateway.example.com      # the API root, no /v1 (chi adds /v1/messages)
    api: anthropic
    dialect: fireworks                    # Bearer auth, no thinking display, no cache_control, x-session-affinity
    api_key_env: WORK_API_KEY
    # auth: x-api-key                     # only if the gateway itself wants that header
    thinking: medium                      # low|medium|high → output_config.effort; off → thinking disabled
    models:
      accounts/fireworks/models/kimi-k2p5:
        price: {input: 0.6, cache_read: 0.1, output: 2.5}    # example rates: put the gateway's (no cache writes on Fireworks)
  work-claude:                            # the same gateway's Claude ids: standard Messages
    url: https://gateway.example.com
    api: anthropic
    api_key_env: WORK_API_KEY
    auth: bearer                          # if the gateway wants Bearer for Claude ids too
  fireworks:                              # Fireworks directly
    url: https://api.fireworks.ai/inference
    api: anthropic
    dialect: fireworks
    api_key_env: FIREWORKS_API_KEY
```

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

`default.model` (config default) and `/model` (runtime effective) pick the model; the status line and `/model`
output always render the runtime effective model (showing default when diverged). Which prompt format it gets is the
prompt profile (see "Prompt profile" below). The request's `model` field is the selector as written (host prefix
dropped).

## Prompt profile

A native host (`llama_cpp`) gets a raw prompt in one model family's format: its turn markers, tool-call
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
     box:
       host: 192.0.2.10
       port: 8081
       profile: qwen36
   ```

4. The server's chat template, on `llama_cpp` hosts: `/props` (asked with `?model=`, which a router needs) with
   `<|im_start|>` and `<function=` is `qwen36`, any other ChatML template too; `<|turn>` and `<|tool_call>` is `gemma4`.
5. The name: `qwen` → `qwen36`, `gemma` → `gemma4`.
6. `qwen36`.

An unknown value in `models:` or `hosts:` warns and is skipped; an unknown `--profile` or `SAMAGOTCHI_MODEL_PROFILE`
warns too (the CLI refuses it). The profile is resolved at start and on `/model`, then kept for the session, so the
system prompt stays the same; a server that swaps models between turns goes unnoticed until `/model` or a new chi. If
`/props` could not be read at start (server down, or 503 while loading), chi asks again before the next turn.

`/stats` and `/model` show the profile and its source (`cli`, `env`, `config (models: …)`, `config (hosts.<name>)`,
`server (chat_template)`, `name`, `default`); `chi self` shows what config says without asking the server. A chat
host (`api: openai`) formats nothing itself: its profile comes from the name and only strips thought tags.

Workers read `hosts:` (with `profile:`) and `models:` from the config file.
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
`/model` switch takes the new model's. A worker reads `hosts:` (with `sampling:`) from the config file when it
starts, and `models:` each turn: after changing a host's `sampling:`,
stop the session's worker (`chi sessions stop`) for it to take effect.

## Prices

A provider that reports no cost (`usage.cost`), or reports 0, can still be priced: give the model a price under
the host that serves it, in USD per 1M tokens.

```yaml
hosts:
  work:
    url: https://gateway.example/v1
    api: openai
    models:
      rr/deepseek-v4.1:
        price: {input: 0.27, cache_read: 0.07, output: 1.10}
  openrouter:
    url: https://openrouter.ai/api/v1
    api: openai
    models:
      qwen/qwen3.8-27b: {price: {input: 0.10, output: 0.40}}   # a listed id, here only for its price
```

- `input` and `output` are required; `cache_read` and `cache_write` are optional. Each is a number >= 0; a price
  missing one of the required two, or with a value that isn't a number >= 0, warns at start and is ignored.
- An unset rate is the input rate: that overstates cached reads, and understates Anthropic cache writes (billed
  1.25x input for the 5 min cache, 2x for 1 h). Set them when it matters.
- A price is per host, since one model can cost differently on two hosts. It is looked up by the model the session
  asked for (its host and id), never by the model the host says it served.
- Each generation with the server's token counts is estimated as uncached prompt × `input` + cached reads ×
  `cache_read` + cache writes × `cache_write` + completion × `output`, over 1M. A generation with only estimated
  counts (characters / 4, no usage from the server) isn't priced.
- A reported cost wins: a generation with a non-zero `usage.cost` is never estimated. A reported 0 with a price is
  estimated (a gateway that bills elsewhere reports 0); the 0 is kept as the reported cost.
- The estimate is saved apart from the reported cost (`cost_estimate` per turn, `cost_estimate_sum` in the
  session's totals in `analytics.json`) and shows with a `~`.
- A server that sends no cached counts has its whole prompt priced at `input`: an overestimate.
- Side requests (the idle recap, `/btw`, a plugin's `ctx.ask_model`) are priced by the same rule from the price of
  the model they asked on its host: the recap's host and model (`recap.*`, else the session's), `ask_model(model:)`'s
  host. A recap using only `recap.base_url` has no host price. They count on `/stats`' own `side requests:` line,
  never in the session's `cost:`.

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
- Order, first set wins: the session's own level, then the process default (`chi web --thinking LEVEL`, or
  `SAMAGOTCHI_THINKING_LEVEL`), then the `models:` entry (found the way `profile:` is), then the `hosts:` entry, then
  `thinking.level` in the file, then `default`. Anything else than a level warns once and counts as unset.
- **A session's own level** (`off`, `low`, `medium`, `high`) is saved in the session (its file's `"thinking"`), so a
  `--resume`, a respawned worker, a continue (the next link of a chain) and `/model` keep it; a plugin's fork copies
  it, a delegate child starts without it (it runs at its model's level). Set it with:
  - `/thinking LEVEL` in the session (`/thinking default` unsets it, `/thinking` alone shows the level and where it
    came from);
  - `chi --thinking LEVEL` on a run that starts or resumes a session (the REPL, `-p`, `--resume`, an attached one);
  - `chi send --new --thinking LEVEL`;
  - the web's `think` chip, in the session bar and on the start page (`POST /api/sessions` takes `"thinking": "low"`;
    anything that isn't a level answers `400 invalid_thinking`).
- `chi web --thinking LEVEL` is the default for the sessions its workers run, below a session's own. A session started
  with only the env (`SAMAGOTCHI_THINKING_LEVEL=low chi send --new …`) loses the level when a worker without that env
  (`chi web`'s, say) wakes it later: use `chi send --new --thinking low`.
- A level is fixed for a turn: a change takes effect at the next turn's start. `/thinking LEVEL` sent while a turn
  runs waits for its end (as `/model X` does), and holds off that turn's warm-up. What a change costs the prompt cache,
  which `/thinking` says (and asks before the costly ones: "Changes that restart the prompt cache"):

  | Backend | A level change | Asks |
  |---|---|---|
  | native Qwen (`qwen36`) | only the prompt's tail (the thought after the cue) | no |
  | native Gemma 4 (`gemma4`) | the whole prompt is read again: `<\|think\|>` starts the system prompt | yes |
  | chat host, local (llama.cpp, Splash), a model name with `gemma` | the whole prompt: the template writes the same token | yes |
  | chat host, local, any other model | other request fields; the server keeps its cache, only the tail changes | no |
  | chat host, remote (OpenRouter, a hosted API) | Claude's thinking params are part of the cached prefix, an OpenAI effort change rewrites hidden instructions: the conversation is read again | yes |

- `models:` levels and `thinking.level` in the file are read every turn; a host's `thinking:` reaches a worker when
  it starts, as its `sampling:` does (`chi sessions stop` to change it).
- `/model` shows the level and where it came from (`thinking: off (models: qwen3.6-35b-a3b)`, `thinking: low
  (session)`), `/stats` on its `thinking:` line, `chi self` too (a session's own level first when run from its
  commands).
- The idle recap, plugins' side questions and a broadcast's triage always ask with thinking off, whatever the
  level. A model that refuses that gets no thinking fields on an `api: openai` host (its default); on an
  `api: anthropic` host, where such a model always thinks, it gets adaptive thinking at `low` effort and a limit of
  at least 4096 tokens, so the thinking leaves room for the answer; a model that refuses that too (one that takes no
  thinking fields at all) gets none, at the normal limit. What a host refused is kept for the next recap, the next
  `ctx.ask_model` on the same model, and the rest of a broadcast. A recap and `ctx.ask_model` send the session's id
  as the turns do (`Session-Id`, and `x-session-affinity` under `dialect: fireworks`); a triage sends none.

What each backend gets:

| Backend | `off` | `low` / `medium` / `high` |
|---|---|---|
| native (`/completion`), `qwen36` | an empty thought after the assistant cue | no knob: an open thought after the cue where the template has one (below), the same at each effort, one notice |
| native, `gemma4` | no `<\|think\|>` token at the start of the system prompt | no knob, one notice |
| chat host (`api: openai`) | `chat_template_kwargs: {enable_thinking: false}` and `reasoning_effort: "none"` | `reasoning_effort: <level>` |
| Messages host (`api: anthropic`) | `thinking: {type: "disabled"}` | `thinking: {type: "adaptive", display: "summarized"}` and `output_config: {effort: <level>}` |
| Messages host, `dialect: fireworks` | `thinking: {type: "disabled"}` | `thinking: {type: "adaptive"}` and `output_config: {effort: <level>}` (no `display`) |

Native `qwen36` at `default`, `low`, `medium` or `high` gets an open thought, `<think>` and a newline, after the
assistant cue when the llama.cpp server's chat template writes one there (Qwen3.5 and later: its generation prompt
ends `'<think>\n'` unless `enable_thinking` is false), read from the model's `/props` (`?model=`, which a llama.cpp
router answers from the model's own server): the model thinks, as the template would have it, and its reasoning shows
as thinking, not in the answer. Without it Qwen3.6 writes an empty thought at once and never thinks. A template whose
own default is no thinking (Qwen3.5's small models think only with `enable_thinking` true) gets the open thought
too: set `thinking: off` for such a model (`models:` or `hosts:`) to keep its answers immediate. A tool call written
inside a closed thought is not run. With no template
in `/props` (an older Qwen3 or other ChatML template, a router that can't load the model, a failed probe) the prompt
ends at the cue as before. `low`, `medium` and `high` think the same: native Qwen has no effort knob, and chi says
so once (`low isn't supported by native qwen36 on HOST; it thinks, with no effort control`).

On a Messages host `default` sends nothing: the provider's own default, which differs by model (some Claude models
think adaptively but show no thinking text, their blocks still going back; others, and Splash, don't think at all). A model that refuses `disabled` and names `between_tools` in the 400 (Claude 5.x) gets `thinking: {type:
"between_tools"}` wherever `off` asked for `disabled`, from then on: the adapter keeps that per model for as long as it
lives, so a worker's turns keep it, and each side-answer client (recap, `ctx.ask_model`, a broadcast's triage) learns it
once for itself. One that refuses `disabled` without naming it gets the request again without it, as on any chat host. A model that refuses adaptive thinking
(older Claude: Haiku 4.5) is switched, once and for the worker's life, to the budget form: `thinking: {type:
"enabled", budget_tokens: B}` with B 2048 / 8192 / 24576 for low / medium / high and no effort; `max_tokens` always
stays above the budget (the budget is lowered to leave 1024 for the answer, or `max_tokens` raised to 2048). A
host that refuses the thinking `display` field gets thinking without it from then on (the level still applies); one
that refuses `cache_control` gets no cache breakpoints from then on, and a `max_tokens` over the model's output
limit is sent again with the limit the host names. On any chat host, a model that refuses a sampling field
(`temperature`, `top_p`, `top_k`; Claude refuses the empty-answer retry's temperature while thinking) gets the
request again without them, and none of them after.

On chat hosts: llama.cpp honours both off switches but ignores the effort (when its `/props` says
`chat_template_caps.supports_reasoning_effort: false`, chi says so once per session and host, from the `/props`
answer the turn already fetched for the window); Splash honours both off switches and passes the effort to the
model's template, which decides: Qwen3.6's ignores it (`low`, `medium` and `high` think the same), and the server's
`--default-reasoning-effort` decides what `default` means there; OpenRouter translates `reasoning_effort` per model
(some can't turn thinking off: Qwen3-30B-A3B thinks anyway, gpt-oss refuses).

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

A different level changes a native Gemma's system prompt (its token), so the next turn reads the whole context again
once; on native Qwen and a chat host only the end of the prompt changes.

## Reasoning history

Which of its own reasoning a chat host's model (`api: openai`) gets back. chi saves each step's reasoning; with it
sent back, the model goes on from its own plan between tool calls instead of working it out again (in one test a local
Qwen thought about 8x less per request and finished a small task about 40% sooner). One level, set per model or per host:

```yaml
hosts:
  deepseek-api:
    url: https://api.deepseek.com/v1
    api: openai
    api_key_env: DEEPSEEK_API_KEY
    reasoning_history: all   # with tools its API wants every earlier reply's reasoning: under turn, turn 2 fails
models:
  some-model:
    reasoning_history: drop
```

- `turn` (the default) sends the running turn's reasoning: each reply since the turn's start carries its reasoning
  as `reasoning_content` (OpenRouter takes it for DeepSeek, Qwen and other text-reasoning models). A steer, a plugin's
  nudge (check-in, agents-md) or a Continue's text merged into the turn doesn't reset it, as on a native host: the
  request after it is the one before plus the steer, so the server's prompt cache holds. A turn that goes on by itself
  (a reminder, a context wake, a delegate report's wake) sends nothing of the one before it, an interrupted reply's
  partial thought included. A **step-limit Continue** is the same turn going on: it keeps the reasoning of the run it
  continues (back to the first run of a chain of Continues), so its first request matches the last one before the
  limit and the server's prompt cache stays warm; Continue's text keeps it too. A `!cmd` run while the step-limit
  question stands is a user message added after the run: the reasoning before it goes, and that Continue reads the
  conversation again once (a re-prefill on a local server). After a `/model` change while the question stands the
  Continue starts afresh (no other model's reasoning is sent).
- **A stock Qwen template (Splash, vLLM, SGLang; llama.cpp with Qwen's own template)** renders an earlier reply's
  reasoning only after the last user message: a steer hides the reasoning before it whatever chi sends, and the
  prompt changes there. `sampling: {chat_template_kwargs: {preserve_thinking: true}}` on the host renders every
  reasoning chi sends (a reply sent without any renders an empty think block; adding it restarts the prompt cache
  once). What it costs by level, with it on: under `turn` a steer no longer re-reads the turn, but each new turn still
  reads the conversation again from the previous turn's first reply (that turn's reasoning leaves the request); under
  `all` every request extends the one before (append-only), at the cost of a prompt that keeps the reasoning of every
  turn. Without it (the template's default) both re-read from the reply before each user message. A strict server
  that rejects unknown fields ("Unrecognized request argument supplied: chat_template_kwargs": OpenAI proper, some
  gateways) fails every request with it, so set it only on a host you know takes it.
- A **direct DeepSeek API** host (`api.deepseek.com`) with tools wants the reasoning of every earlier reply, earlier
  turns included, and answers HTTP 400 without it: under `turn` every turn after one that thought fails. Set
  `reasoning_history: all` there (the example above). DeepSeek through OpenRouter takes `turn`.
- `drop` sends none (what chi did before this setting).
- **On an `api: anthropic` host** the reasoning goes back as the answer's own content blocks, verbatim (thinking
  blocks with their signatures, in their order among text and `tool_use`), not as `reasoning_content`. The default
  there is `all`: Claude keeps earlier turns' thinking in context, and leaving it out would rewrite the cached prefix
  each turn (a Qwen template on Splash drops earlier turns' reasoning itself, so `all` costs nothing there). `turn`
  leaves earlier turns' thinking blocks out (their text and calls stay), and `drop` counts as `turn`: the running
  turn's thinking blocks always go back (a tool loop with thinking needs the last reply's). An interrupted reply, or
  one whose tool calls never got their results, goes back as plain text without its blocks.
- `all` sends every reply's reasoning, earlier turns too. It sends only the field: a local template that leaves out
  earlier turns' reasoning (Qwen's) needs `preserve_thinking` as well (above).
- Order, first set wins: the session's own level, `SAMAGOTCHI_REASONING_HISTORY` (the whole process; for A/B runs),
  the `models:` entry (found the way `profile:` is), the `hosts:` entry, then `turn` (`all` on `api: anthropic`). Anything else than a level warns
  once and counts as unset. A host's level reaches a worker when it starts, as its `sampling:` does.
- **A session's own level** (`drop`, `turn` or `all`; an explicit `turn` counts as its own) is saved in the session
  (its file's `"reasoning_history"`), so a `--resume`, a respawned worker, a continue and `/model` keep it; a plugin's
  fork copies it, a delegate child starts without it. Set it with `/reasoning-history LEVEL` in the session
  (`/reasoning-history default` unsets it, `/reasoning-history` alone shows the level and where it came from) or the
  web's `reasoning` chip in the session bar (shown on chat hosts only). There is no start flag: a fresh session runs
  the command before its first turn at no cost. A change takes effect at the next turn's start; sent while a turn runs
  it waits for its end.
- What a change costs the prompt cache (`/reasoning-history` says so, and asks first when it costs: "Changes that
  restart the prompt cache"):

  | Change | Cost |
  |---|---|
  | `drop` ↔ `turn` | none: a turn's first request carries no reasoning under either |
  | to or from `all`, once an earlier reply has thinking | every earlier reply gains or loses its reasoning: a server that renders it (hosted APIs, llama.cpp's default template) reads the conversation again from the first earlier thought |
  | nothing thought yet, the same level, or a native host | none |

- The native loop (`/completion`) ignores it: it always keeps the running turn's reasoning, a mid-turn steer included,
  and a step-limit Continue keeps the thoughts of the run it continues, a mid-turn steer's earlier ones included.
- When a host answers a request that sent reasoning back with an HTTP 400 about reasoning, chi asks again without it,
  sends none to that model from then on (until the worker restarts) and says so once. If the request without it is
  refused too, the thinking fields get the same fallback ("Thinking") and the reasoning goes back on the next step.
- `/model` names a level that isn't the default (`reasoning history: drop (models: some-model)`, `all (session)`),
  `/stats` shows it on its `reasoning history:` line (chat hosts only), and `chi self` on its `reasoning history` row
  (a session's own level first when run from its commands).
- Claude via OpenRouter signs its reasoning (`reasoning_details`), which chi doesn't keep: it gets the plain text,
  and the fallback above covers a refusal.

## Changes that restart the prompt cache

`/thinking`, `/reasoning-history` and `/toolkit` ask before a change that makes the server read the conversation again:
Gemma's thinking switch, a remote chat host's thinking fields ("Thinking"), a change to or from `all` once an earlier
reply has thinking ("Reasoning history"), and any change to the declared tools, which start every request
("Toolkits"). They ask only when what the next turn runs under really changes and the session has a model reply.

- The reply says what it costs and changes nothing yet. When known, it estimates the reread size: the whole
  conversation for full-prefix changes, or from the first changed reply for reasoning history. On `api: anthropic`,
  a full-prefix change also says preserved thinking in replies is dropped from then on.
- `Nothing changed yet: send /thinking low --yes to apply.` names the line that applies it.
- `--yes` (or `-y`, anywhere after the command) applies it at once.
- The terminal (the REPL and an attached TUI) puts the `--yes` line in the next input: Enter applies it.
- The web's reply bubble has an **Apply (restarts the cache)** button. The session bar's chips are already an explicit
  choice: their Set sends the `--yes` line, and their form says what a change costs. Command bubbles are page-only, so
  the button is gone after a reload.
- Only a person at a web tab or a chi TUI is asked. `chi send ID "/thinking low"`,
  `chi -p "/thinking low" --non-interactive`, lines piped into the REPL, a delegate, a plugin and a card's action
  apply directly, since nobody would see the question; so do the start flags (`chi --thinking` on a resumed or
  attached session sends `/thinking LEVEL --yes`). A plain `chi -p` opens the REPL, which asks.

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
server reports writes) and `reprefill=` (of the previous request's prompt on the same model through the same host,
what the server prefilled again: an `llm_context` edit's cache break, or anything else that rewrote the prompt's
middle; only when the server reports a cached count, and not on the first request after a warm-up; a `/model` to the
same model on another host is the switch's prefill, not a re-prefill); recap and side requests log theirs as `recap request_usage`.

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
to the default host. A host's declared ids (`hosts.<name>.models`, below) count
as listed. Only exact ids count, never a substring: `/model gemma` on
a box that lists `gemma-4-26b` needs `box:gemma` or the exact id. The lists are
known only after `/models` ran (nothing is fetched before the first turn), so
until then an unqualified name (or an alias's unqualified target) goes by the
lists last saved on disk (`model_lists.json`, what `chi models`, `/models` or the
web last listed, at most a week old) the same way, else to the default host,
unless a host declares it; use `host:model` to pin one. A **remote** host (an `https` url or a public address; see "Remote or local") keeps its model
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

### Models a host serves but doesn't list

A gateway can serve ids its `/v1/models` never lists (round-robin aliases such
as `rr/deepseek-v4.1`). Declare them under the host:

```yaml
hosts:
  work:
    url: https://gateway.example/v1
    api: openai
    api_key_env: WORK_API_KEY
    models:
      rr/deepseek-v4.1:
      rr/qwen3.8-27b:
```

A plain list says the same: `models: [rr/deepseek-v4.1, rr/qwen3.8-27b]`. Ids are
full ids (no globs), matched case-insensitively. A declared id is known on its
host whatever the host lists:

- `work:rr/deepseek-v4.1` never gets the "host 'work' doesn't list model" warning,
  and the host isn't re-listed for it (`chi send --new --model`, delegates).
- A bare `rr/deepseek-v4.1` goes to `work` as if `work` listed it, also before
  any `/models` and in a session's worker. When several hosts list or declare an
  id, the default host wins if it is one of them, else the first in `hosts:`
  order; two hosts declaring one id get a warning at start saying which one a
  bare id goes to. `host:id` still pins a host.

**A gateway that answers with another model.** A round-robin id is served by one
of its targets, and the reply names that one (`fireworks/deepseek-v4.1`), so chi
marks every turn as served by another model than asked (the web's `⚠`, the status
line's `(served; asked …)`, `/model`'s `served:`). `served:` lists the models the
host may answer with, as exact ids (any case), or `any`:

```yaml
hosts:
  work:
    models:
      rr/deepseek-v4.1:
        served: [fireworks/deepseek-v4.1, baseten/deepseek-v4.1]
      rr/qwen3.8-27b:
        served: any
```

A served model it names is no mismatch: the web and the status line keep the name
you asked for, and `/stats` names the served model without "(asked for …)". One it
doesn't name is still marked. `any` gives that check up for the id.

**Root `models:` vs `hosts.<name>.models:`.** The root `models:` holds settings
by model name (sampling, thinking, window, profile…), on whatever host the model
runs on; it says nothing about which host serves a model. `hosts.<name>.models:`
says which models that host serves. Keep settings in the root one.

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
- Retry scope: transient network errors (timeouts, reset connections, broken pipes, EOF/socket reachability
  failures, a TLS handshake that drops: `SSL_connect … unexpected eof while reading`), HTTP 429 and HTTP 500/502/503/504/529. A `Retry-After` header replaces the backoff delay; one longer than
  60s is not waited out and the error is reported instead.
- An HTTP 402 about credit held by in-flight requests (OpenRouter reserves credit for each running request, so
  one session's long request can make another's fail) is retried like a 429, 20s apart unless `Retry-After`
  says otherwise: with the default `retry.max` that is about 100s. With `retry.max: 0` it fails at once.
  Not when its `metadata.reason` is `weight_exceeds_budget`: that request alone is larger than the key's credit
  budget, so it fails at once (lower `default.max_tokens` or raise the key's limit).
- A refused connection (nothing listening) is not retried: the turn fails at once with `can't reach host <name> at
  <address> (connection refused) — is the server running?`.
- Nor is a TLS handshake that can't work, which fails at once saying what to check: a certificate chi doesn't
  trust (`certificate verify failed (self-signed certificate)`, `unable to get local issuer certificate`, an expired
  one: set `SSL_CERT_FILE` to a CA bundle that has the gateway's CA), a certificate for another name (`hostname
  mismatch`: check the host's `base_url`), or a server that doesn't speak TLS there (`wrong version number`: an
  `https://` base_url on a plain HTTP port; should it be `http://`?).
- A stream that has already produced output is never retried at the transport (the retry would repeat it). The
  chat loop (an OpenAI-compatible host) drops the partial reply and asks again for the whole step, from the same
  conversation, at most twice (at most `retry.max` times when that is smaller: `retry.max: 0` turns it off), after
  the same backoff, reported as a retry (`↻ retrying (stream dropped) …`); once those run out the turn fails with
  the error, as before. A refusal, a first-token timeout, a provider error and a cancel are never retried this way.
- Cancellation (`Ctrl-C`) is never retried.

Configuration:

- `retry.max` (default `5`, env `SAMAGOTCHI_RETRY_MAX`): number of retries after the first failed attempt; it also
  caps a dropped stream's asks-again (at most 2), and `0` turns those off too.
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
A provider that refuses the answer (a Messages host's `stop_reason: refusal`, or an OpenAI-compatible host's
`finish_reason: content_filter` with no text) is not asked again: the turn ends with no answer (text streamed before
a Messages refusal is not kept), every UI shows `no answer: refused by the provider (cyber)` (the category from
`stop_details`, when there is one), and the hidden note says the answer was refused. A `content_filter` stop after
some text keeps that text as the answer, followed by `[cut off by the provider's content filter]`, and is not asked
again either. Tool calls that come with either are not run.
A generation a plugin cuts while it streams (loop-guard's thinking watch, or any `stop_generation`,
[hooks.md](hooks.md#watching-the-stream)) uses the same budget: `↻ cut by loop-guard, asking again (1/1)`, and with
none left the turn ends as cancelled (hook).

Assist-mode UX:

- While waiting, a retry shows in the activity row (the web's timing line words it the same):
  `↻ retrying (503) in 4.0s, 2/5`: why (the HTTP status, the error's short name such as `ECONNREFUSED`, or
  `stream dropped`), the wait, and the retry of all there will be.
- If retry attempts are exhausted, the submitted prompt is restored into the input editor so you can edit and resubmit.

## Messages during a running turn: steer and cut

A message for a running turn goes in at its next step and cuts nothing. A message sent as a cut (`/cut TEXT` in a
terminal or the web composer, `chi send --cut`) cuts the model's generation once it has streamed only thinking for
that model's cut wait (`steer.cut_after` seconds, default `20`, `0` = never; counted from its first thinking token,
so the wait for a busy server doesn't count) and still does, and the model starts the step again with the message
(`↪ cut in for your message`). One that comes earlier cuts once the thinking passes it, unless the step ends first
and the message goes in there. A plain message (from the web composer, `chi send` without `--cut`, a parent agent)
never asks for a cut, nor does a queued one (`/queue TEXT`, `chi send --queue`, `ctx.sessions.send(…, delivery:
:queue)`), which runs as a turn of its own after the running one. Such a cut spends no `retry.empty_answer` attempt and sends no hidden note; only the cut
thinking is lost. A generation that has streamed visible text or a tool call is never cut, and a plugin's steer
(`ctx.steer`, `ctx.sessions.send`) never cuts.

A message that would go in at the next step (any but a queued one, one with images or a participant's) also ends a
`task_wait` the model is blocked in, within half a second: the task keeps running, the model is told a message waits,
reads it at once and decides whether to wait again. A plugin's steer and a delegate child's report don't end one.

The wait resolves per model, in this order: env `SAMAGOTCHI_STEER_CUT_AFTER`, then
`models.<key>.steer_cut_after`, `hosts.<name>.steer_cut_after`, `steer.cut_after` in config.yml, then 20. `0` means
never cut (a slow local thinker is left alone); a bad value warns and is ignored, like the other keys here.

```yaml
steer:
  cut_after: 20   # seconds of thinking-only output before a cut may land; 0 = never

hosts:
  splash:
    host: splash.lan
    steer_cut_after: 0   # never cut: a slow local thinker

models:
  qwen:
    steer_cut_after: 60  # a big model thinks a while before it answers
```

`/model` shows the resolved wait (`; steer cut: after 60 s (models: qwen)`, `; steer cut: never (hosts.splash)`).

`/queue TEXT` (in a terminal or the web composer) runs TEXT as a turn of its own after the running one: the request
carries `delivery: "queue"`, the input file keeps it, and the worker's drain leaves the file for after the turn. The
Bridge acks `delivery: "queue"` while a turn runs (to an idle session the message is simply the next turn:
`next_step`). A worker whose sidecar doesn't name the `delivery` feature (older than queueing) would steer it, so the
sender refuses it (`409 delivery_unavailable`, "restart it"), and so does a worker that answers the request with a
400 `delivery_unavailable`.
Until its turn starts, a queued message can be taken back: `/unqueue` in an attached terminal, the × on its bubble
in the web ([sessions.md](sessions.md), *Removing a queued message*).

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

An error event (or an error body inside a 200) has no HTTP status of its own: its numeric `error.code` stands for
one, or a Google-style code name (Fireworks: `INVALID_ARGUMENT` 400, `UNAUTHENTICATED` 401, `PERMISSION_DENIED` 403,
`NOT_FOUND` 404, `RESOURCE_EXHAUSTED` 429), else its `error.type` (Anthropic's names; some OpenAI-compatible servers,
OpenAI and Ollama, use some of them: `invalid_request_error` 400, `authentication_error` 401, `billing_error` 402,
`permission_error` 403, `not_found_error` 404, `request_too_large` 413, `rate_limit_error` 429, `api_error` 500,
`timeout_error` 504, `overloaded_error` 529); with neither it counts as a 500.

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
  chat template's image wrapping (qwen36 and gemma4 do);
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

## Desktop helper: agents in kitty and tmux

The desktop helper (`chi desktop`) can also paste into agent CLIs (claude,
codex, …) running in [kitty](https://sw.kovidgoyal.net/kitty/) windows or
tmux panes. It lists kitty's only with `kitty.listen_on` set: copy the value of `listen_on` from
your `kitty.conf` as it is (kitty must also have `allow_remote_control` on).

```yaml
kitty:
  listen_on: unix:/tmp/kitty.${KITTY_PID}   # as in kitty.conf; unset = no kitty targets
  binary: /Applications/kitty.app/Contents/MacOS/kitty   # the default
  agents: [claude, codex]   # the programs listed; "*" = every window
```

tmux panes (agents started inside tmux, in any terminal) only with
`tmux.enabled` on:

```yaml
tmux:
  enabled: true             # default false
  binary: /opt/homebrew/bin/tmux   # default: the tmux on chi's PATH when the launch file is written
  agents: [claude, codex]   # default as kitty.agents; "*" = every pane
```

The helper reads these from its launch file: after editing them run
`chi desktop upgrade` (or `chi update`). The tmux binary and the socket dir
(`$TMUX_TMPDIR/tmux-<uid>`, else `/tmp/tmux-<uid>`) are resolved then and
frozen in it. See [Desktop helper](desktop.md#agents-in-kitty-and-tmux).

## Project specific description

If an AGENTS.md file is present in the project root, samagotchi injects its
contents into the system prompt under a "Project specific description:" section.
The project root is the top of the git work tree chi runs in (a linked
worktree's own checkout), or the current directory outside a repository.

Started in a subdirectory, chi loads the chain: every AGENTS.md from the work
tree top down to the current directory, outermost first. The first keeps the
plain header; each further one is headed with its directory, e.g. "Project
specific description for pkg/:". Outside a repository only the current
directory's AGENTS.md is read. Edits are picked up by a new process or a
prompt rebuild (`/model`).

To skip loading AGENTS.md (all of the chain), set `skip_agents_md: true` at the top level of
`config.yml` (env `SAMAGOTCHI_SKIP_AGENTS_MD=true`).

Nested `AGENTS.md` files (in directories the session doesn't run in) are
steered into the conversation on first touch by the `agents-md` bundle
([The agents-md bundle](plugins.md#the-agents-md-bundle)); `skip_agents_md`
disables that steering too.

## Appended prompt files

`append_system_prompt:` (a top-level list) and `chi --append-system-prompt FILE`
(repeatable) put a file's text into the system prompt right after the AGENTS.md
chain and before the memory indexes, in the stable part a prompt cache keeps.
Each file is one section, `Appended from <path>:`, the path relative to the
work tree top when inside it, else with `~`.

- The config list comes first, then the flag's files; a repeat, or a file the
  AGENTS.md chain already holds, is left out, and so is an empty file.
- A config entry: `~` is expanded, and a relative one is looked up in the
  directory chi runs in, so `append_system_prompt: [CLAUDE.md]` loads a
  project's `CLAUDE.md` wherever there is one. A missing entry is skipped
  without a warning. The list is read when the session's engine starts (a new
  process picks up an edit).
- `--append-system-prompt FILE`: relative to the shell's directory. A missing,
  unreadable or non-file `FILE` stops chi (`Error: --append-system-prompt FILE:
  no such file`); above 32,000 chars it warns once (`… is N chars; it is in
  every request`). The files are saved in the session (`appended_prompt_files`),
  so a respawned worker builds the same prompt, and a fork or a continue keeps
  them; a delegate child doesn't. With `--attach` or `--resume` the flag is
  ignored with one line, as `--memory` is; a REPL `--resume` (`--no-shared`)
  adds them for that run only.
- The files' text is read at each prompt build, as AGENTS.md's is: an edit is
  picked up by a new process or a rebuild (`/model`). `/stats` lists the files
  in the prompt on its `prompt files:` line.

## Toolkits

A session's **toolkit** names the tools its prompts declare. The declared tools are the front of every request (the
`tools` field, or the native template's declarations), so a session that declares fewer sends a shorter prompt, and
sessions on the same toolkit share that prefix in a prompt cache.

```yaml
toolkit:
  default: lean        # the sessions you start (unset: full)
  child: child         # delegate children (unset: full)
  kits:                # your own, on a base
    audit: { base: lean, add: [web_fetch, delegate], remove: [memory_write], description: "Code review and inspection" }
    terse: { base: lean, prompt: "- Be concise in your responses" }
    web: { base: lean, groups: [chrome] }
    coding: { base: lean, groups: [] }
```

| toolkit | declares |
|---|---|
| `full` | every built-in; the default |
| `lean` | `execute`, `read`, `write`, `edit`, `memory_read`, `memory_write`, `task_create`, `task_wait`, `task_get`, `task_list`, `task_stop`, `ask_user_question`, `web_fetch`, `context_read` |
| `child` | `lean` plus `send_note`, without `memory_write`, `delegate`, `delegate_result` |
| `coordinator` | `lean` plus `delegate`, `delegate_result`, `list_sessions` (declared by the coordinator bundle) |
| `coding` | `child`, with the prompt text `- Be concise in your responses` / `- Show file paths clearly when working with files` (declared by the coordinator bundle, for build and fix children) |
| `review` | `read`, `memory_read` (not `forget_outputs`, even under the `forget` layer): what a [participant's](internals/participants.md#turns) turn may call, whatever the session declares (the review boundary, [guardrails](guardrails.md#a-participants-review-boundary)). Reserved: `toolkit.kits.review` is refused ("review is reserved for participants' turns"), and a bundle can't declare it. A session may run on it too, as any kit |

- **Plugin tools** are declared in every toolkit unless its `remove:` names them, and so is `forget_outputs` under
  the `forget` layer. A `kits:` entry takes `base:` (default `full`), `add:`, `remove:`, `prompt:`, `groups:` and
  `description:`
  (any other key, a typo or a `tools:` list, is ignored with a warning); it can't reuse a built-in's name
  (`review`'s least of all: it is the participants' boundary). A bundle declares its own with `chi.toolkit`
  ([plugins](plugins.md#chitoolkitname-base-add--remove--prompt-nil-groups-nil-description-nil)).
  `description:` is optional classifier input, up to 300 characters; it is not included in the session prompt.
- **Memory kits.** A memory named `toolkit_<name>.md` defines kit `<name>` with one fenced YAML block containing
  optional `base:`, `add:`, `remove:` and `groups:`, plus a required `description:` (up to 300 characters).
  `prompt:` is refused. A memory kit may use a config or bundle kit as its base. Built-ins cannot be redefined.
  The precedence is built-ins, config, bundles, then memory kits; within memories, project scope wins over system
  scope. Muted memory kits are skipped, and `/toolkit` shows each one's `memory:project` or `memory:system` source.
  Kits are read once per worker, so changes take effect when a new worker starts. See
  [Toolkit memories](memory.md#toolkit-memories) for the format and when to create one.
- **Audit suggestions.** `toolkit.suggest.mode: audit` asks System 1 which described kit fits an eligible new session's
  prompt, without changing its toolkit or delaying the turn. It offers the configured default as the fallback and
  `undecided` for greetings or check-ins. Only a default-origin session with at least two described candidates is
  asked; chosen or inherited toolkits, delegate children, review sessions and participant turns are skipped. After
  `undecided`, later owner prompts may be asked again within both defer limits. The default is `off`. System 1's
  host, model and timeout come from `guardrails.system_one.*`; the suggestion threshold and defer limits are its own
  settings below. Suggestions are
  kept in `toolkit_suggestions.jsonl`; `chi toolkit report` grades them against the session's tool calls. One ask
  runs at a time (a turn that comes while one still runs goes unasked, with an info line), and a kit that doesn't
  resolve (a missing base, a cycle) is left out of the candidates. A worker that exits waits about a second for a
  running ask, so a one-shot `-p --non-interactive` run may end before its suggestion is logged.
- **On mode.** `toolkit.suggest.mode: on` asks the same question on the same eligible turns, but the turn waits for
  the answer before it declares any tool, for at most `guardrails.system_one.timeout_ms` from the ask's start (it
  starts right after the turn does, so plugin and MCP start-up hide most of it). A described kit picked with
  confidence at or above `toolkit.suggest.threshold` becomes the session's toolkit, saved with `toolkit_origin:
  suggested`, and the turn's first request declares it; the notice reads
  `toolkit: web (suggested, p=0.71) · /toolkit to change`. Anything else (the default, a low-confidence or unknown
  pick, `undecided`, no answer, a failing System 1, which warns once as `[samagotchi:toolkit]`) keeps the default
  kit. A Stop during the wait (or before it, even with the answer in) ends the turn before its first request, and
  nothing switches. After an `undecided`, a later prompt within the defer limits may switch the session; that notice
  says `from this turn`, and that request re-reads the whole prompt (system prompt, tools and conversation, which
  the defer limits keep small) without `/toolkit`'s cache confirmation. `/toolkit` or `ctx.use_toolkit` marks the
  toolkit chosen, and nothing is suggested after that; a `/toolkit` sent during a turn runs after it and replaces
  that turn's suggestion. When System 1's host is the model's own local server (the same `hosts:` name or server
  root, as audit checks), on mode asks only on a session's first turn, never on the deferred path, and sends no
  warm-up (one info line). Otherwise an idle worker for an eligible session sends one warm-up ask with the real
  question and a stand-in prompt so the server has its prefix cached; its answer is dropped and never logged, and
  the first real ask stops a warm-up still running. Each answered ask's line in `toolkit_suggestions.jsonl` adds
  `did`: `suggested`, `default`, `defer`, `chosen` (the toolkit was no longer the default), `unavailable` (the
  picked kit was gone), `timeout` or `canceled` (written when the late answer arrives; a Stop after a timeout
  doesn't cut it), or `failed` (the turn failed or the switch couldn't be saved); `chi toolkit report` grades
  on-mode lines by what they did.
- **Tool-index groups.** `groups:` selects source groups by name or glob (`chrome`, `db*`; any case, `{a,b}` braces,
  as the guardrails rules' `models:`); for the MCP bundle each group is a server. Anything but a name or a list (a
  map such as `{chrome: true}`) refuses every new session on that kit or on a kit built on it, on every surface (chi,
  `chi send --new`, chi web, `delegate`, a continue or a fork): `toolkit.kits.NAME: groups must be a list of group
  names or globs; fix config.yml to start a session on toolkit KIT`. A session already saved on it keeps running,
  its kit reaching no group (with a `toolkit>` warning) until config.yml is fixed. Selectors are sorted and deduplicated and match the groups declared when plugins load.
  An omitted key inherits the base's selectors; `full` and `lean` (and `child`, which is on `lean`) reach all
  groups, `review` (the participants' kit) reaches none, `groups: ["*"]` matches every group, and `groups: []`
  reaches none. A kit whose base doesn't resolve (an unknown name, a cycle) falls back to `full`, which reaches
  every group.
  A selector that matches no group in that load-time snapshot warns once. `find_tools` and `call_tool` are
  declared only when the toolkit reaches a source group or has a reachable built-in. Calls naming an unreached
  group are refused before guardrails and do not start its server. The first-run init wait is unchanged: it can
  still block the first turn even when its server's group is unreached; `start: eager` and stale-cache refreshes
  also still start. `/mcp` marks servers outside the current toolkit.
- **A kit's prompt text.** `prompt:` (text, several lines allowed) goes into the system prompt of the sessions on
  that kit, verbatim, with no header: after AGENTS.md and the appended files, before the memory indexes. A kit
  without one inherits its base's (`audit: {base: terse, add: [web_fetch]}` stays concise); `prompt: ""` clears
  it; a session's own `--tool` / `/toolkit add` never touch it. Sessions on the same kit share it in the prompt
  cache; `full` and every kit without a prompt send the bytes they sent before. Keep it to a line or two that
  fits the kit's work (the coordinator bundle's `coding`: be concise): one that isn't text or is over 2000
  characters is left out with a warning, and long text belongs in `append_system_prompt:`. `/toolkit` shows it
  (`prompt: …`), `/stats` its kit and size (`kit prompt:`), the web's tools chip in its tooltip.
- **Saved at creation, definitions resolve at worker start.** A session stores its toolkit as named
  (`"toolkit": {"name": "lean", "add": [], "remove": []}`) when it is created: `toolkit.default`, `toolkit.child`
  for a delegate child (or the kit its `delegate` call names), or `chi --toolkit NAME` / `--tool` / `--no-tool` ([cli](cli.md)). Changing `toolkit.default`
  doesn't move existing sessions, not even when their worker is woken again; a session from before toolkits is on
  `full`. A continue and a fork keep the toolkit name. `/toolkit` shows and changes it. The kit's tools, prompt
  text and group selectors are part of its definition, not the session file: edits reach a saved name at its next
  worker start.
- **Left out: reachable or removed.** A built-in missing from a kit's base list (`lean` has no `delegate`; a
  `kits:` entry on `base: lean` or `child` inherits that) is left out softly: it is **reachable**. `find_tools` searches it as group `chi` (`chi/delegate`, with its inputSchema) beside
  the MCP servers' tools, and `call_tool(tool: "chi/delegate", args: {…})` runs it as `delegate` itself, through the
  usual guardrails, approvals and hooks ([plugins](plugins.md#chitool_sourcecall-acts_as-label-wait-prefix)). A
  tool in a toolkit's `remove:`, a `--no-tool` or a `/toolkit remove` is **removed**: hard, also after an add, and
  call_tool can't reach it (`child` removes `memory_write`, `delegate` and `delegate_result`, so a child on it
  starts no children). To keep a built-in away from the model, name it under `remove:`. `find_tools` and `call_tool`
  are declared when a toolkit has a reachable built-in or reaches a source group; `full` with no reachable source
  declares neither, and removing them there (`--no-tool call_tool`) leaves nothing out: no prompt line, no chip.
- **On `api: anthropic`, reachable tools are callable by name.** Every tool `call_tool` reaches (the reachable
  built-ins, tools from reached MCP groups as `mcp_<server>_<tool>`) also goes in the request's tools deferred
  (`defer_loading`: Messages keeps them out of the model's view until something loads them, at a flat ~100 tokens).
  A direct call of one (`list_sessions`, `mcp_fs_read`) runs, under the same guardrails, approvals and rows as
  through `call_tool` (an MCP tool's call is `call_tool`'s). A `find_tools` hit **loads** its matches (up to 5):
  the model then sees their definitions and calls them by name; only the new result is read uncached. Not on
  Fireworks' dialect, nor on `api: openai` or a native host, where such a call gets the `call_tool` route and a hit
  reads as text.
- **The prompt line.** One line after the base prompt names them: `Not declared in this session (toolkit lean): ….
  Search them with find_tools; call one with call_tool.`, then `Removed (toolkit child): memory_write, …. Only the
  user can load one (/toolkit add <name>).` With `find_tools` removed, the first sentence ends `Call one with
  call_tool(tool: "chi/<name>", args: {…}).` instead. With `call_tool` itself removed, nothing is reachable and one
  line names them all: `Not loaded in this session (toolkit lean): …. Only the user can load one (/toolkit add
  <name>).`
- **Calls by name.** A direct call of a reachable tool is refused before the guardrails (no approval card), with
  the route: `Error: delegate isn't declared in this session (toolkit lean); call it with call_tool(tool:
  "chi/delegate", args: {…}) (find_tools gives its inputSchema).` A removed tool's: `Error: memory_write isn't
  loaded in this session (toolkit child) and can't be loaded from here; only the user can (/toolkit add
  memory_write).` An MCP tool in an unreached group gets a toolkit-specific refusal before guardrails; a deferred
  stub for it points to the toolkit instead of suggesting a search. `/toolkit` lists group selectors and the
  change; the web's toolkit chip says its source-group scope in the tooltip.
- **Applied at a turn's start.** A change (`/toolkit`, a plugin's `ctx.use_toolkit`) is saved at once and the next
  turn declares it, with its kit's prompt text and group filter; once the session has a model reply, `/toolkit`
  asks first ("Changes that restart the prompt cache"), also when only the group selectors change and the
  declared tools stay the same.
- **A name that doesn't resolve** (a typo, a bundle that was uninstalled) declares every tool for that process,
  with one `toolkit>` warning at the first turn; the saved name stays, so the bundle's return brings it back.
- **Versions.** A toolkit's definition (its tools and its prompt text) can change with chi or a bundle, which
  changes what saved sessions on it send after an upgrade: the next request reads the prompt again once, as a
  tool's schema change does. So can an edit to `toolkit.kits`: a session's worker reads the kits once when it starts, so a running session keeps its
  tools and the edit reaches it at its next worker start (after an idle exit, `chi sessions restart`).

## LLM context: the forget layer

Experimental, off by default. With `forget` in a model's `llm_context.strategy` (next to `stale`), chi offers that
model a tool, `forget_outputs`, to free context by forgetting its own tool outputs. Nothing changes for a model
without it: no ids, no tool, the same prompt.

```yaml
llm_context:
  budget_tokens: 64k          # optional (64000, 64k; 4k to 10M): the [CONTEXT: …] lines count against 64k, not the window
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
  notes have no ids. An output you dropped, or one of an item you pinned, is refused too (`dropped by the user`,
  `pinned by the user: it stays in your context`).
- **Pins.** `/working-set pin KEY…` (or the web list's `pin`, shown under forget only) keeps an item from the model's
  forget: every read of it, those to come too, until `/working-set unpin KEY…` (see [cli.md](cli.md#the-working-set)).
  It sends nothing different, so the prompt cache holds. The pins are the session's own (`working_set_pins` in the
  session file): a respawned worker, a continue and a fork keep them, across a strategy switch too; a delegate child
  starts without. Stale stubs still apply to a pinned file's superseded reads (its newer read is sent).
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

## LLM context: what you see (✂)

Every edit is shown; the session keeps the originals.

- **A ✂ row** for each batch of stubs that reaches the prompt (`stale`'s, a `forget_outputs` call's, or the ones
  staged until a turn's end), in the step it came in, in the web and the terminal alike:
  `✂ forgot 2 outputs, stubbed 1 stale read · frees ~4.1k tokens (paid off)`. It says why it went now (`paid off`,
  `the context is nearly full`, `at turn end`; nothing under `next_request`) and how many stubs stay staged. In the
  web, its hover lists each output (its id, tool and path or command), a stale stub's reason, a forget's note once
  with the lines it keeps, the tokens it frees and the tail the server reads again. A batch held back, the warm-up's
  own copy and a restore show no row (the `forget_outputs` row says what a restore did). A reload puts the rows back
  where they were (`cards.json`, its own cap of 20, apart from hook notices).
- **A ✂ mark** on a tool row after a reload, above its output, when the model is sent a stub for it:
  `✂ stubbed: superseded by a later read · ~1.0k tokens`, `✂ forgotten: <note>`, `✂ forgotten with t41` (the
  other outputs of the call whose row carries the note), `✂ forget staged`, and `· lines 12-40 kept`.
  The running turn's rows get theirs on the next reload.
- Tokens are estimates (chars/4), hence the `~`.

## LLM context: a session's own strategy

A session can set its own `llm_context` strategy, apply rule and budget, which come before the model's, its host's
and the global ones (resolution: the session, `models.<key>`, `hosts.<name>`, then `llm_context.*`; each value on
its own). The first target is a long session such as a day-long coordinator, where `stale` pays off across many turns.

- **Set it** at start with `chi --llm-context stale,forget --llm-context-apply turn_end --llm-context-budget 64k`
  (the same flags on `chi send --new`), in the session with `/llm-context strategy … apply … budget …`
  (docs/cli.md, "Session commands"), or from the web's `llm ctx` chip in the info bar.
- **A new web chat:** the start page's `llm ctx` chip, beside the model picker, shows the picked model's values
  and follows a model pick. Its form (titled "new session") sets a choice for that one chat: the chip reads
  `llm ctx stale · new session` in the accent colour, and the create sends it as `POST /api/sessions`'s
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

## Opening files from chi web

In `chi web`, a file tool's row (read, edit, write) and the lines of its diff are refs to that file. They look like
text until hovered (the title gets a dotted underline and `↗`, a diff line an accent bar and `↗ N`); a click opens the
file in your editor: a row's title at the lines it read or edited (an edit without a range at its first changed
line, a write at line 1), a diff line at its line, a hunk header at the hunk's start. A drag that selects text isn't
a click. `web.editor` picks what opens:

```yaml
web:
  editor: vscode     # or vscode-insiders, cursor, zed, none
  # editor: "idea://open?file={path}&line={line}"   # a template of your own
```

- A preset, or a URL template with `{path}` (the absolute path, each segment URL-encoded, the slashes kept) and an
  optional `{line}` (1 when there is none). A value that is neither a preset nor has `{path}` logs a warning and
  counts as `none`. A change needs a `chi web` restart.
- A template that puts `{path}` in a query (`?file={path}`) gets the path's slashes unencoded; editors accept that.
- The first click asks twice, once each: the browser asks to open the editor's links (choose "always allow"; Safari
  and Chrome ask per origin, so another `chi web` port asks again), and VS Code asks to allow opening local files.
- It opens the file as it is now, not the agent's copy: after later edits a diff line's number can point elsewhere,
  and a file in a worktree that was removed won't open. The row's diff and output are what the agent saw.
- Only a viewer on this machine opens the editor: a loopback request, or this machine on its own LAN address
  (`web.host: lan`, the LAN URL or its QR code opened here; with `web.host: lan` the loopback page needs the token
  too: open the `Local:` link chi web prints). A phone gets the targets that need no editor (an
  answer's ref shows its row in the turn; see the refs in [sessions.md](sessions.md)); a row's title stays plain
  text there. An SSH tunnel or a local reverse proxy (`tailscale serve`) looks like loopback unless `web.public_url`
  is set (then a request through it is never this machine's viewer), so without it a remote viewer behind one gets an
  editor target that can't open.
- `GET /api/sessions/:id` (and its `?tail=1`) carries `capabilities.editor` (true for such a viewer) and
  `editor_url`, the template (null otherwise).

## Behind an auth proxy

Experimental. `chi web` binds 127.0.0.1 only; to use it from elsewhere over https, put it behind a proxy that does TLS
and, usually, a sign-in (oauth2-proxy, nginx `auth_request`, Caddy `forward_auth`, Cloudflare Access, Tailscale
Serve; a work pod forwarding `https://<port>.<pod>.<domain>` through oauth2-proxy) and tell chi web its public URL.
The proxy must run **on the same machine** as chi web: only a request from a loopback peer (127.0.0.0/8, ::1) counts
as one through the proxy, with its identity header. A proxy on another host, reaching chi web on its LAN address
(`web.host: lan`), isn't supported: its requests are LAN requests (the LAN token; a link bound to an account refused),
since any LAN device could send the same headers.

```yaml
web:
  public_url: https://4567.pod.example.com     # the https origin people open: no path
  proxy:
    identity_header: X-Forwarded-Email         # optional: the header the proxy puts the signed-in email in
    owner: me@example.com                      # optional, needs identity_header: you, as that header says it
```

What changes once `web.public_url` is set:

- **Every request needs the access token**, this machine's too (`$XDG_STATE_HOME/samagotchi/web-token`, made at
  start; `chi web --new-token` replaces it). A proxy that adds no header and rewrites Host (nginx's `proxy_pass` with
  its defaults) would otherwise look like this machine. On this machine the page opens through the proxy too: a
  request that didn't come through it takes the token only as `Authorization: Bearer` (no cookie: a cookie for
  127.0.0.1 would go to every server on any local port; a phone on the LAN, with `web.host: lan`, keeps its LAN link
  and cookie). A browser on this machine that opens the port directly gets a 401 page with no paste box: it links
  `web.public_url`, the address to open instead. chi's own probe of the port (a second `chi web`, `chi share`,
  `chi update`) sends no token; chi web answers it the few fields it checks. Links and the start line come from this
  machine's config, never from whatever answers on the port.
- **A request through the proxy** (it carries `X-Forwarded-For`, `Forwarded`, `X-Real-IP`, a known identity header,
  or the public Host) is the owner only with the token **and**, when `web.proxy.identity_header` is set, that header
  being exactly `web.proxy.owner` (any case). A repeated, comma-separated or empty value, or the header sent under a
  second spelling (`X_Forwarded_Email` next to `X-Forwarded-Email`), is refused (401, the reason in the answer's
  detail). With `identity_header` unset the token alone decides: that works behind any proxy. `owner` without
  `identity_header` stops `chi web` from starting.
- Through the proxy the cookie is `__Host-chi_token` (Secure, Path=/, no Domain: other host names under the domain,
  such as a pod's other ports `https://<port>.<pod>…`, don't get it; the LAN's `chi_token` is separate). Cookies aren't
  scoped by port: another server on the **same host name** and a different port does get it, so give chi web a host
  name of its own, or port 443. Through the proxy a `?token=` page isn't traded (it would ride the sign-in redirect,
  and a crafted link could swap your session): a link's one-time code and the 401 page's paste box do it, the paste
  box's redirect going to the public URL (never to a client-sent `X-Forwarded-Host`). The page accepts `POST`s from the public `https://` origin only (a sibling port on the same
  domain, or `http://`, is refused). No page of chi web's may be framed by another (`X-Frame-Options: DENY`,
  `frame-ancestors 'none'`, in every mode).
- Links carry a **one-time code** in the fragment, never a token: `chi web` prints `Proxied: https://…/#code=chc_…`
  (the owner's: once, within 10 minutes; `chi web` again prints a new one), and a participant's link (`chi share`,
  the Invite dialog) is `https://<public url>/#code=chc_…&s=ID` (once, until the grant expires). A fragment isn't sent
  to the proxy, but it outlives the sign-in's redirects: the sign-in page sits at that URL (its scripts can read it)
  and it stays in the browser's history, which is why it holds a code that works once. The page trades the code for
  the cookie (`POST /api/token`) and drops it from the URL; a page that already has a session asks first, since the
  trade replaces it. An owner's code (or an unbound participant's) presented with the wrong identity is used up and
  gives nothing, so whoever already holds a link can spend it (`chi web` again, or a new invite, makes another); a
  link bound to one account ([Inviting colleagues](#inviting-colleagues)) is refused to anyone else and keeps its code. The 401 page's paste box posts the token in
  the request's body, never in the URL.
- When the proxy's sign-in or chi's token ends, the page says so: it reloads once (the proxy's sign-in brings you
  back), and within a minute of that shows "Signed out … Reload" instead of a list that quietly stopped updating. Its
  API calls ask for JSON, so oauth2-proxy answers an ended sign-in with 401 instead of a redirect.
- A session's Bridge (its worker's own port) answers only a request that names its secret, which only chi's own
  clients on this machine read (from the worker's 0600 `bridge.json`): a proxy or tunnel that forwards every local
  port reaches the port but gets 403. It also refuses a request that carries a proxy header such as
  `X-Forwarded-For` or `Forwarded` (403 `proxied`).
- `chi --remote` to a chi web behind a sign-in proxy isn't supported yet.
  SSH to that machine works instead: forward its port and add it as a remote
  ([Through an SSH tunnel](cli.md#through-an-ssh-tunnel)).

Which header to trust: only one the proxy **sets** on every signed-in request **and replaces** when a client sends
it. Check before setting `identity_header`: run an echo on a free port behind the same proxy (`python3 -c` with
`http.server`, or any header-echo server), open it signed in, and send your own copies (`curl -H 'X-Forwarded-Email:
evil@x' -H 'X_Forwarded_Email: evil@x' …` with your sign-in cookie): the header you trust must come back with your
email only. chi warns once in its log when a proxied request carries a known identity header but not the configured
one.

| Setup | `identity_header` | Notes |
|---|---|---|
| oauth2-proxy (`--pass-user-headers`) | `X-Forwarded-Email` | Replaced, spelling variants dropped; `X-Forwarded-For` always added. **Not** `X-Auth-Request-Email`: oauth2-proxy puts that on its *response*, a client's copy reaches chi untouched. Checked against oauth2-proxy 7.15.5. |
| nginx `auth_request` + oauth2-proxy (`--set-xauthrequest`) | `X-Auth-Request-Email` | Only as nginx sets it from the auth reply (`auth_request_set $email $upstream_http_x_auth_request_email; proxy_set_header X-Auth-Request-Email $email;`), which replaces a client's copy; nginx drops underscore spellings by default. Checked with nginx 1.27. |
| Caddy `forward_auth` (`copy_headers X-Auth-Request-Email`) | the copied header | Replaced from the auth reply; Caddy passes an underscore spelling through, which chi refuses. Checked with Caddy 2.8. |
| Cloudflare Access | `Cf-Access-Authenticated-User-Email` | Not checked yet: verify with an echo. chi trusts the header only; it doesn't validate the `Cf-Access-Jwt-Assertion` token. |
| Tailscale Serve | `Tailscale-User-Login` | Replaced, not appended (`Tailscale-User-Name`, `X-Forwarded-For`, `X-Forwarded-Host` too); `X-Forwarded-For` = the requesting device's tailnet IP, Host = the public name. Tailnet only. Checked with Tailscale 1.104.2 (macOS). Not checked: Funnel and tagged-device requests; never use Funnel. See [Tailscale Serve](#tailscale-serve-your-tailnet). |
| Authelia, Authentik (behind nginx, Caddy, Traefik) | `Remote-Email` (Authelia), `X-Authentik-Email` (Authentik) | Not checked yet; only as the front proxy copies it from the auth reply (the nginx and Caddy rows). |
| A TLS proxy with no sign-in (nginx, Caddy, an SSH tunnel) | leave unset | The token alone decides. |

Keep the state dir (`web-token`, the grants) out of any folder others can read, such as a team's shared folder.

### Inviting colleagues

Behind a proxy whose sign-in lets colleagues in (a work pod behind Okta and oauth2-proxy, a tailnet you share), give
each reviewer a link bound to their account:

```sh
chi share 3f9a1c2e --name Alex --identity alex@corp.example
# p_7c01d2aa  Alex (human, reviewer) · session 3f9a1c2e · expires … · cap $2.00 · bound to alex@corp.example
# https://4567.pod.example.com/#code=chc_…&s=3f9a1c2e-…
```

- It needs `web.proxy.identity_header` (or `chi web --tunnel tailscale`): the link opens only through the proxy,
  signed in as that email (any case). Opened by someone else (forwarded, pasted in the wrong chat), on the LAN or on
  this machine, it says "This review link is for another account …", and its one-time code stays: Alex can still open
  it. The refusal is in the session's participants audit with the identity that tried. Without an identity header
  `--identity` is refused: the link could never open.
- Run only chi 0.109 or newer on the same state dir: an older chi rewriting the grants store drops the binding and
  makes every bound link open for anyone the proxy lets in.
- An unbound link there opens for anyone the proxy lets in who has it; `chi share` warns when you make one. The web's
  Invite has an email field behind such a proxy (the name defaults to the email's first part).
- The identity is what the trusted header carries: the work email through Okta, the Tailscale login (`alex@github`)
  through Tailscale Serve. Bind to the one your proxy sends. A tagged Tailscale device has no user login, so a bound
  link refuses it.
- The header is the proxy's word only for requests from this machine (the proxy is local; a LAN device's copy is
  ignored): any program on this machine that reaches chi web's port directly can send it too. On a machine or pod only you use, that is you already; on a host
  other users share, a bound link's identity isn't a boundary against them.

### Tailscale Serve (your tailnet)

chi web on your phone away from the home Wi-Fi: [Tailscale](https://tailscale.com) Serve gives this Mac an https
name on your tailnet, `https://<machine>.<tailnet>.ts.net`, with a real certificate, and tells chi web who is asking
(your Tailscale login, next to chi's token). Only devices on your tailnet reach it: with Tailscale off on the phone the
name doesn't load. By hand, on the Mac that runs chi web (or steps 1–2, then
[`chi web --tunnel tailscale`](#chi-web---tunnel-tailscale) does 3–5 for one run):

1. Install Tailscale on the Mac and the phone and sign both in with the same login. **Rename the machines first**
   (admin console → Machines): HTTPS certificates go into the public Certificate Transparency log, so the
   `<machine>.<tailnet>.ts.net` name is public once a certificate is issued, and a later rename puts a new name there.
2. Turn on HTTPS certificates (admin console → DNS; they need MagicDNS on).
3. Serve chi web's port on the tailnet, never on the internet:

   ```sh
   tailscale serve --bg 4567
   ```

   On macOS the app's CLI is `/Applications/Tailscale.app/Contents/MacOS/Tailscale` unless you installed `tailscale`
   on your PATH. `tailscale serve status` shows what it serves; `tailscale serve --https=443 off` turns it off. Turn
   it off when you stop using it: while it is on, whatever listens on 127.0.0.1:4567 is reachable from your tailnet.
4. Tell chi web its public name and whose login is the owner (config.yml; `chi web` reads it at start):

   ```yaml
   web:
     public_url: https://chi-host.example-tailnet.ts.net
     proxy:
       identity_header: Tailscale-User-Login
       owner: owner@example.com      # your Tailscale login
   ```

   Your login: `tailscale whois <the phone's 100.x IP>` (the User block), or `tailscale status --json`
   (`User["<Self.UserID>"].LoginName`), or start without `owner` and read it off the 401 page's detail ("owner token
   with identity …"). A login made with Sign in with Apple is a private-relay address (`…@privaterelay.appleid.com`):
   it is stable, use it as it is. Every device signed in with that login (the phone, a laptop, an iPad) is the owner,
   each with the token too.
5. `chi web` prints `Proxied: https://chi-host.example-tailnet.ts.net/#code=chc_…`; open that link on the phone (copy,
   AirDrop or type it). The code works once, within 10 minutes (`chi web` again prints a new one); the phone then
   keeps the `__Host-chi_token` cookie.

#### `chi web --tunnel tailscale`

Steps 3–5 in one command, after steps 1–2 (Tailscale signed in, HTTPS certificates on):

```sh
chi web --tunnel tailscale
```

```
Chi Web on http://127.0.0.1:4567/ (public: …)
Proxied: https://chi-host.example-tailnet.ts.net/#code=chc_…   ← opens chi web as you once, within 10 minutes (…)
         (owner owner@example.com by Tailscale-User-Login, and the token; …)
         via Tailscale Serve (tailnet only), owner owner@example.com (this machine's Tailscale login)
Tailnet Lock is off: a device Tailscale's servers add to your tailnet could reach this page; tailscale lock init turns it on (…)
<the link's QR code>
```

- It checks before it changes anything: Tailscale is connected, this machine has its `ts.net` name and a certificate
  for it, and what Serve already has on port 443. Nothing there: once chi web has bound its port (so Serve never
  forwards your tailnet to another program that took the port first), it runs
  `tailscale serve --bg --https=443 http://127.0.0.1:<port>`, then prints its lines. Exactly that one handler for this port (a leftover of an
  earlier run killed hard, or step 3 done by hand): it adopts it. Anything else on 443 (another port, other paths, TCP
  forwarding, Funnel) is refused and left alone. Serve's other ports are never touched.
- The owner is `web.proxy.owner` if config.yml has it, else this machine's own Tailscale login (a tagged machine has
  none: set `web.proxy.owner`). `public_url` and `identity_header` are the tunnel's for this run, never written to
  config.yml: a `web.public_url` or `web.proxy.identity_header` that says otherwise (in config.yml or the environment)
  is refused, so a config from step 4 with this machine's name works as it is.
- On exit (Ctrl-C, a kill, closing the terminal) it runs `tailscale serve --https=443 off`, but only while 443 still
  serves exactly what it set; if you changed 443 meanwhile it leaves it and says so. A Ctrl-C while it turns Serve on
  or off waits for that command (at most 15 s each) and the teardown still runs; a teardown that fails is one warning
  line. Killed hard (`kill -9`, a power
  loss) the serve stays on: Serve answers 502 for the name while nothing listens on the port, and whatever later
  listens on 127.0.0.1:<port> is reachable from your tailnet; the next `chi web --tunnel tailscale` adopts it and
  turns it off on exit, a plain `chi web` doesn't look.
- A chi web already on the port is refused ("stop that one first"): `--tunnel` starts its own.
- The `tailscale` it runs: `SAMAGOTCHI_TAILSCALE_CLI` if set, else `tailscale` on PATH, else the macOS app's
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.
- Tailnet Lock off is a warning line, never a refusal.

- **Never Funnel** (`tailscale funnel`): it puts the name on the public internet. This recipe was checked on the
  tailnet only; Funnel requests weren't.
- Recommended: **Tailnet Lock** (`tailscale lock init`, see Tailscale's docs): new devices then need a signature from a
  device you trust before they join, not only Tailscale's coordination server's say-so. chi web works either way.
- What Serve sends (checked with Tailscale 1.104.2 on macOS): it **replaces** a client's `Tailscale-User-Login`,
  `Tailscale-User-Name`, `X-Forwarded-For` and `X-Forwarded-Host` (never appends); `X-Forwarded-For` is the
  requesting device's tailnet IP, Host the public name, and chi web's peer is 127.0.0.1. A process on this Mac can
  still reach 127.0.0.1:4567 directly with headers of its own: there the token decides, as with any proxy.
- While chi web isn't running Serve answers 502 for the name (checked). Not checked yet: requests from a tagged
  device (expect no user login, so refused with `identity_header` set), and whether the serve stays on across a
  reboot.
- A participant's link (`chi share`, the Invite dialog) is a `https://<machine>.<tailnet>.ts.net/…` link too: it opens
  only on a device on your tailnet (or one you shared this machine with in Tailscale); the grant still decides.
- Without Serve, a plain tailnet IP (`web.host: 100.x.y.z`) works like the LAN (see
  [chi web on your phone](cli.md#chi-web-on-your-phone)): token only, plain http in the browser (WireGuard encrypts
  the path) so no `Secure` cookie and no notifications, and no identity.

### Phone notifications (Web Push)

chi web as an app on your iPhone's Home Screen that buzzes (the Watch too) when a session needs you: an
**approval**, a **question**, a **step-limit** question, a **card** that asks (check-in's Nudge / Keep going / Stop),
or a **failed turn**, also while the app is closed. A tap opens that session; once it is answered anywhere (the Mac,
the phone, `chi answer`), its notification goes when you open the app (or swipe it away; a failed turn's stays until
you do). Every push shows a notification: iOS turns off an app's pushes after a few that show none.

What it needs:

- chi web on an **https** public URL: `chi web --tunnel tailscale` ([above](#chi-web---tunnel-tailscale)) or a
  `web.public_url`. On the LAN's plain http there is no push (no secure context: the bell is hidden); use the tunnel.
- iOS 16.4 or later, and chi web **added to the Home Screen**: iOS gives push to a Home Screen app only.
- No Apple account or registration: chi web signs its pushes with a key of its own (VAPID).

Turning it on, on the phone: open the `Proxied:` link in Safari → Share → **Add to Home Screen** → open the **Chi**
app → tap the **bell** at the top → turn on **This device** in the sheet → Allow. A test notification arrives at once.
The app opens on the project chi web starts in (`web.start_dir`; the header's project picker switches projects), but its
notifications are every project's: opening it closes the ones whose question or card is no longer open and sets its
badge for every project, whichever project the page shows.
In a browser tab the bell stays the tab's own notifications (while the tab is in the background), as before.

**The devices** (the bell's sheet in the app; a bottom sheet on the phone): this device first, with its switch (off
removes it from chi web and is the same as the bell turned off), then every other device chi web pushes to: its label,
the last delivery and the last error, a **Long turns done** switch each, and **Remove** (it can turn its bell on again
to come back). Devices made on an earlier public URL show as one line ("1 more device from an earlier address"): they
are never sent to; `chi web push rm ID` removes them. From the Mac: `chi web push ls` lists them, `chi web push test
[ID]` sends a test notification, `chi web push rm ID` removes one ([CLI](cli.md)). A device iOS dropped silently still
shows a recent delivery (Apple keeps accepting pushes for it): if one stops getting notifications, switch it off and on
there; the new subscription replaces the dead one.

- **What a tap opens**: the session, in its own project's view (the all view for a session in no repo), whichever
  project the app was showing; an open app window moves there.
- **What is sent**: the session's name and the reason ("needs approval", "needs an answer", "hit its step limit",
  "needs you", "turn failed", "done in N s"), never the question or the command, as the tab's notification on the
  Mac. The session's name shows on the lock screen and the Watch.
- **What Apple sees**: the push is end-to-end encrypted to the phone; Apple's push service sees that this machine
  pushes to that device, and when. A subscription holds no device name and no personal data (an opaque address on
  `web.push.apple.com` and two keys); chi names it itself ("iPhone · 2026-10-24", from the User-Agent's device class
  and the date).
- **When**: the same things the tab notifies for, still open 3 s after they came (3.5 s for a delegated child's
  approval, which its parent may relay instead); one push each. A delegated child's failed or finished turn is its
  parent's to report. **Done turns** (10 s or longer, or one nobody started: a delegate's report, a context change, a
  finished task) are **off** by default, per device: the **Long turns done** switch in the devices sheet turns them on.
- **Quiet while you look**: nothing is pushed while any chi web page (a tab on the Mac, or the app) is in front and
  was touched in the last 2 minutes; what came meanwhile is never pushed later (the page has it). A page left in
  front untouched stops quieting the phone after about 2 minutes.
- **Limits**: at most 30 pushes an hour (the rest are dropped, with one warning on chi web's terminal); a busy push service is tried once more. An approval or question asked while chi web was stopped or
  restarting (under an hour ago, still open) is pushed once when it starts; the first restart after updating may
  push one you already saw, once.
- **The files**: `$XDG_STATE_HOME/samagotchi/web-push/` (next to `web-token`): `vapid.pem` (chi web's key),
  `subscriptions.json` (the devices) and `sent.json` (what was pushed in the last day), 0600 in a 0700 folder; chi web refuses to start when others can read them.
  Subscriptions belong to the public URL they were made on: after renaming the machine or the tailnet, turn the bell
  on again on the phone (the old ones are never sent to). iOS can drop a subscription without telling chi web; if
  notifications stop arriving, turn the bell off and on again: the new subscription replaces the dead one.
- `web.push.enabled: false` turns it off; `web.push.contact` (a `mailto:` address or an `https://` URL; default:
  the public URL) is the contact the push services see in chi web's key. A value that is neither stops `chi web`
  (Apple refuses it); a `[chi web] the push service refused chi's VAPID token` line means the contact or the key was
  refused, and pushes stop until chi web restarts.
- The app keeps its own cookie (iOS copies Safari's when it is added, 400 days): `chi web --new-token` logs it out
  (it shows the "needs chi web's access token" page; paste the token there). Pushes keep coming meanwhile.
- chi web not running: no pushes (Serve answers 502; a tap couldn't open the page anyway).

## All settings

Every setting below takes the three forms described in
[Environment variables](#environment-variables): a nested key in
`config.yml`, `SAMAGOTCHI_<DOTTED_NAME>` in the environment (not for one
marked config.yml only) and, where the CLI
column says so, a `--kebab-name` flag. The maps (`hosts:`, `models:`,
`model_aliases:`, `hooks:`, `guardrails:` rules, `bundles:`, `memories:`,
`append_system_prompt:`, `toolkit.kits`) are described in their own sections.

| Setting | Default | CLI | What it does |
|---|---|---|---|
| `default.model` | (required) | `--model` | The model a new session starts with; `host:model` pins a host. |
| `default.input` | none | | Text pre-filled at the first prompt (a trailing space is kept); `--no-default-input` skips it. See [CLI](cli.md). |
| `default.max_tokens` | server's | yes | Most tokens one generation may produce (`n_predict` on a native llama.cpp host; OpenRouter: 32768 when unset). |
| `model.profile` | none | `--profile` | Prompt profile for every model (`qwen36`, `gemma4`); env and CLI only. See "Prompt profile". |
| `server.host` | `localhost` | yes | The model server when there is no `hosts:` map. |
| `server.port` | `8080` | yes | Its port. |
| `server.open_timeout` | `10` | yes | Connection timeout, seconds. |
| `server.read_timeout` | `600` | yes | Read timeout, seconds. |
| `server.first_token_timeout` | 120 remote, off local | | Seconds to the first token; `0` = off. `hosts.<name>.first_token_timeout` wins. |
| `recap.enabled` | on | | `false` (or `recap: false`) turns the idle recap off. Per session too: `--set recap.enabled=false`, or `/recap off` in the session (see "Per-session settings"). |
| `recap.model` | session's | yes | Model that writes the recap: an id, alias or `host:model` (the host then picks where to ask; a bare id goes where a bare `--model` goes). |
| `recap.host_ref` | session's | yes | A `hosts:` name to ask (`host:` is accepted too, also a host name, not a model ref). |
| `recap.base_url` | none | yes | An OpenAI API base to ask instead (`http://h:8081/v1`). |
| `recap.inactivity` | `180` | yes | Idle seconds before a recap. |
| `recap.timeout` | `30` | yes | Seconds a recap request may take. |
| `recap.min_user_turns` | `2` | yes | Prompts a session needs before it gets a recap. |
| `recap.sentences` | `2-4` | yes | Recap length, `N` or `N-M` (1–10). Per session too: `--set recap.sentences=3`. |
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
| `session.task_wakes` | `wake` | | When a background task the session started (`task_create`, an `execute` handed over at its limit) finishes and the model hasn't seen it finish: `wake` runs an idle session's turn opened by a `TASK FINISHED` note, `queue` leaves the note for the next turn, `off` leaves it to `task_wait`. See [Finish wake](internals/background-tasks.md#finish-wake). |
| `session.max_wakes` | `10` | | Wake turns a session runs in a row with no human input: for delegate reports, finished background tasks, attached context and peer answers; past it reports wait for the next turn and task finishes and context updates arrive as notes. |
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
| `guardrails.parent_answers` | `soft` | | Which options a parent agent (`chi answer`) may pick on a session's question, by their effect: `hard` (a deny, a Stop, a plain answer), `standard` (+ Continue and other spending options), `soft` (+ "Allow once"); never a wider scope or an allow on chi's own config. An invalid value warns and is `hard`. A session's own `parent_answers` (`chi --parent-answers`, `/parent-answers`) may only tighten it. Replaces `guardrails.parent_approvals` and `turn.parent_continue`. config.yml only: no environment variable (a parent can still pick the config dir with `XDG_CONFIG_HOME`). A convention for an honest parent, not a security boundary. See [Guardrails](guardrails.md#answers-from-a-parent-agent). |
| `guardrails.system_one.mode` | `off` | | System 1, the cheap judgment that answers an ask before the user sees it: `off` (the default), `audit` (judge every ask, log it, never decide), `on` (also allowed to allow a call once, behind the gates in [System 1](guardrails.md#system-1-experimental)). An unknown value warns and is `off`. Experimental. config.yml only. See [Guardrails](guardrails.md#system-1-experimental). |
| `guardrails.system_one.host` | none | | The `hosts:` entry serving `/v1/systemone` (a local Splash, or the hosted Jev API); unset: no judgment. config.yml only. |
| `guardrails.system_one.model` | none | | The judgment model; unset uses the host's first model, and a host that names none has no judgment. config.yml only. |
| `guardrails.system_one.rules` | none | | The rule ids System 1 may answer for in `on` mode: `"git-push|git-rebase"` or a YAML list, parsed like `guardrails.small_models`. Nothing is auto-allowed while it is unset; the `chi-answer-piped`, `chi-answer-http` and `chi-broadcast` rules never are, however they are listed. config.yml only. |
| `guardrails.system_one.threshold` | `0.8` | | The probability an auto-allow needs. config.yml only. |
| `guardrails.system_one.min_record` | `5` | | How many clean records a rule needs before System 1 is trusted for it: labelled asks of that rule at the threshold the user allowed. config.yml only. |
| `guardrails.system_one.timeout_ms` | `2000` | | Milliseconds one judgment may take; a slower one is no judgment and the ask goes to the user. config.yml only. |
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
| `llm_context.budget_tokens` | none | | A soft context budget in tokens (`64000` or `64k`, 4k to 10M, as `/llm-context budget` takes it); off when unset, `0` or `off`; a value out of range warns and is ignored. When set, the context status buckets (`context.status_thresholds`) count against it instead of the window (the smaller of the two), so the `[CONTEXT: …]` lines, `payoff`'s top bucket and, under `forget`, the `forget_outputs` offers come under it. A session's own (`--llm-context-budget`, `/llm-context budget`; `off` there wins over the model's), then `models.<key>.llm_context_budget_tokens` and `hosts.<name>.llm_context_budget_tokens` come first. |
| `models.<key>.llm_context_budget_tokens`, `hosts.<name>.llm_context_budget_tokens` | none | | A model's or host's `llm_context.budget_tokens`. |
| `llm_context.policy` | the subtask-boundaries line | | The sentence `forget_outputs`' description carries (the `forget` layer): "Tidy at subtask boundaries: once a subtask is done, forget its tool outputs and note what it established; keep anything you'll still edit against." Blank: none. Read when a session starts. |
| `context.chars_per_token` | `4.0` | yes | Estimate ratio when the server reports no usage. |
| `memory.index_warn_tokens` | `2500` | yes | The tokens one scope's memory index (project or system; sent with every prompt) may hold before a `memory_write`, `write` or `edit` that takes it over gets a note asking the model to tighten long index descriptions; `0`: no note. Estimated as characters / `context.chars_per_token`. `memory:` is its own section, not the `memories:` preload list. See [Memory](memory.md). |
| `context.status_thresholds` | `20,40,60,80` | yes | Percentages that put the estimate into a bucket; the rise into a guidance bucket (from the second up) leaves the model its own `[CONTEXT: …]` line, and the bucket decides the guidance. |
| `context.every_seconds` | `300` | | How often an attached context source's command runs when it has no `--every` (seconds, at least 30). See [Attached context](context.md). |
| `context.wake` | `true` | yes | A source whose update says `wake: true` may start a turn in a live, idle session (one per source per 10 minutes, a peer source up to `context.peer_turns` in a row, within `session.max_wakes`); so may a session's pushed source's first push. `false`: updates wait as notes for the next turn. See [Waking](context.md#waking). |
| `context.peer_turns` | `3` | yes | Wake turns in a row a peer agent's answers may start (a peer bundle's outbox source, such as `codex-outbox`), with no message typed in the web or a TUI in between (`chi send` doesn't count); within `session.max_wakes`. Then answers wait as notes, and the UIs hear it once. An answer whose summary ends its verdicts with `VERDICT OK` wakes once to close the round, counted toward `session.max_wakes` only. `0`: a peer source wakes like any other. See [Waking](context.md#waking). |
| `toolkit.default` | `full` | | The toolkit a new session is stored on: the tools its prompts declare (`full`, `lean`, `child`, one of `toolkit.kits` or a bundle's). `chi --toolkit` picks one per session. See "Toolkits". |
| `toolkit.child` | `full` | | A delegate child's toolkit, unless its `delegate` call names one (`toolkit:`). See "Toolkits". |
| `toolkit.suggest.mode` | `off` | | `audit` asks System 1 for a toolkit suggestion without changing the session; `on` waits for it (up to `guardrails.system_one.timeout_ms`) on an eligible turn and starts the session on a confidently suggested kit (Toolkits, On mode). The System 1 host, model and timeout come from `guardrails.system_one.*`. config.yml only. |
| `toolkit.suggest.threshold` | `0.5` | | Minimum confidence for a non-default toolkit suggestion. config.yml only. |
| `toolkit.suggest.defer_turns` | `3` | | Maximum owner-prompt number for another ask after `undecided` (the owner's own prompts: not steers, notes, reminders or `!` command output). config.yml only. |
| `toolkit.suggest.defer_tokens` | `5000` | | Maximum estimated conversation size for another ask after `undecided` (characters / 4). config.yml only. |
| `reasoning_history` | `turn` | | Which of its reasoning a chat host's model gets back: `drop`, `turn`, `all`; environment only (`SAMAGOTCHI_REASONING_HISTORY`), below a session's own level (`/reasoning-history`), above the `models:`/`hosts:` entries. See "Reasoning history". |
| `thinking.level` | `default` | `--thinking` | `off`, `low`, `medium`, `high` or `default` for every model; the flag and env outrank the `models:`/`hosts:` entries, the file's value doesn't; a session's own level outranks them all, and `--thinking` sets it on a session run (on `chi web` it sets this). See "Thinking". |
| `models.<key>.thinking`, `hosts.<name>.thinking` | none | | A model's or host's level. See "Thinking". |
| `hosts.<name>.models` | none | | The model ids a host serves whatever its `/v1/models` lists: a map of ids, or a plain list. See "Models a host serves but doesn't list". |
| `hosts.<name>.models.<id>.served` | none | | The models the host may answer that id with (exact ids, any case), or `any`: no served-model warning for those. See "Models a host serves but doesn't list". |
| `hosts.<name>.models.<id>.price` | none | | The model's price on that host, USD per 1M tokens: `input`, `output`, optional `cache_read` and `cache_write`. Estimates the cost a provider doesn't report. See "Prices". |
| `hosts.<name>.remote` | by address | | `true`/`false`: treat the host as a remote provider or a local server. See "Remote or local". |
| `max_tool_output_chars` | `10000` | yes | Characters of each tool output kept in the conversation (both loops). A longer one is cut: an `execute` result keeps its first and last lines with a gap line between them and is saved whole in the session's folder (`sessions/<id>/tool_output/`; the gap line names the file, and the model reads it there instead of running the command again); any other tool's keeps its head and ends with `[cut: N of M chars; read it in parts]`. See [Tool output guardrails](internals/tool-guardrails.md#the-runners-cut-max_tool_output_chars). A top-level key (see below). |
| `cache.warmup` | `auto` | | `auto`: after a turn, send the next turn's prompt (up to the next message) to a local llama.cpp host on the native loop, so the next turn prefills only its message; never a remote or `api: openai` host. `off`: never. See [prompt caching](internals/prompt-caching.md#the-turn-end-warm-up). |
| `cache.ttl` | `5m` | | How long Anthropic keeps the prompt-cache breakpoints of a Claude model on a remote host: `5m` (Anthropic's default) or `1h`. A 1h cache write costs 2× the input price (5m: 1.25×), a read the same 0.1×. See "Remote or local". |
| `cache.key` | `off` | | `session`: send the session id as `prompt_cache_key` to OpenAI's API and OpenRouter, which route and cache by it; no other host gets it. `off`: none. |
| `retry.max` | `5` | yes | See "Llama Network Retry Behavior". |
| `retry.base_delay` | `0.5` | yes | |
| `retry.max_delay` | `8.0` | yes | |
| `retry.empty_answer` | `1` | | Times a turn asks again after an empty answer (at most 3, `0` = off). See "Llama Network Retry Behavior". |
| `steer.cut_after` | `20` | | Seconds a generation must have streamed only thinking before a message sent as a cut (`/cut TEXT`, `chi send --cut`) cuts it; other messages go in at the next step; `0` = never. `models.<key>.steer_cut_after` and `hosts.<name>.steer_cut_after` come first; see [Messages during a running turn](#messages-during-a-running-turn-steer-and-cut). |
| `models.<key>.steer_cut_after`, `hosts.<name>.steer_cut_after` | none | | A model's or host's seconds a cut waits for its thinking: whole seconds, `0` = never (e.g. a slow local thinker). `/model` shows the resolved one. See [Messages during a running turn](#messages-during-a-running-turn-steer-and-cut). |
| `turn.max_iterations` | `300` | | A turn's step limit: model ↔ tool rounds before it stops and asks to continue (an integer ≥ 1). `--no-interrupt` turns get the larger of 1000 and this. See [CLI: Iteration Limit Behavior](cli.md#iteration-limit-behavior). |
| `update.gem` | `true` | | `false`: `chi update` never installs a newer gem (`--no-gem` for one run). See [CLI: Updating](cli.md#updating). |
| `update.bundles` | `true` | | `false`: `chi update` leaves the shipped bundles to `chi bundle upgrade` (`--no-bundles`). |
| `update.desktop` | `true` | | `false`: `chi update` leaves the desktop helper alone (`--no-desktop`). |
| `update.notify` | `on` | | `on`: chi web checks RubyGems once a day and shows aged stable releases newer than both this chi and the newest installed chi; `off`: no thread or network check. |
| `update.check_hours` | `24` | | Hours between RubyGems checks (at least 1). The first check starts about 30 seconds after chi web starts. |
| `update.min_age_hours` | `24` | | A release must be this old before chi web offers it; `0` disables the age delay. |
| `kitty.listen_on` | none | | The desktop helper's kitty socket, copied from `kitty.conf`; unset = no kitty targets. See "Desktop helper: agents in kitty". |
| `kitty.binary` | `/Applications/kitty.app/Contents/MacOS/kitty` | | The kitty the helper runs `kitty @` with. |
| `kitty.agents` | `claude\|codex\|gemini\|aider\|opencode\|cursor-agent\|amp\|goose` | | Foreground programs whose kitty windows the helper lists, `\|`-separated (a YAML list works too); `*` lists every window. |
| `tmux.enabled` | `false` | | The desktop helper lists agents in tmux panes. See "Desktop helper: agents in kitty and tmux". |
| `tmux.binary` | none | | The tmux the helper runs; unset = the `tmux` on chi's PATH when the launch file is written. |
| `tmux.agents` | `claude\|codex\|gemini\|aider\|opencode\|cursor-agent\|amp\|goose` | | Foreground programs whose tmux panes the helper lists, as `kitty.agents`; `*` lists every pane. |
| `read.truncate_at_bytes` | `65536` | yes | A `read` result larger than this is cut to a preview. |
| `read.preview_bytes` | `12288` | yes | Size of that preview. |
| `read.hard_max_bytes` | `2097152` | yes | Largest file `read` opens. |
| `read.telemetry_threshold_pct` | `80` | yes | A `read` result that alone fills this % of the context window carries a token estimate. |
| `execute.truncate_at_bytes` | `65536` | yes | The same for `execute` output. |
| `execute.preview_bytes` | `12288` | yes | |
| `execute.telemetry_threshold_pct` | `80` | yes | |
| `execute.cut_head_chars` | `1000` | yes | An `execute` result over `max_tool_output_chars` keeps at most this many characters of its start (and never more than a quarter of the cap); its end gets the rest. |
| `execute.timeout_sec` | `120` | yes | Seconds one `execute` command may run before `execute.on_timeout` applies. |
| `execute.on_timeout` | `task` | yes | What happens to a command still running at that limit: `task` keeps it running as a background task (the result names its `task_id`; `task_wait` waits for it, `task_stop` stops it), `kill` stops it (`Error: command timed out after …s`). The `!cmd` bang always kills. See [Background tasks](internals/background-tasks.md). |
| `execute.description` | `true` | | `execute` offers the model an optional `description` (a few words on what the command does), shown as the tool row's title in `chi web` and in place of the command in the TUI's tool line. `false`: the parameter isn't declared, and rows show the command's first step. |
| `web.port` | `4567` | `--port` | `chi web`'s port. See [CLI](cli.md). |
| `web.host` | `127.0.0.1` | yes | `127.0.0.1`, `::1` or `localhost`; `lan` (this machine's private IPv4 address) or one of its IPv4 addresses also opens `chi web` to the network, with an access token, asked of this machine's 127.0.0.1 too (its `Local:` link carries a one-time code; `chi web --new-token` replaces the token). Anything else binds `127.0.0.1` with a warning. See [CLI: chi web on your phone](cli.md#chi-web-on-your-phone). |
| `web.markdown` | `false` | yes | Render answers as Markdown in `chi web`. |
| `web.view` | `stage` | yes | How `chi web` draws a turn: `stage` (the running turn pinned above the composer) or `turn` (one block per turn in the history). See [CLI](cli.md#web-views). |
| `web.working_set` | `true` | yes | The stage view's working set: the files, memories and URLs a turn brought into the model's context, in a rail in the stage, a footprint line under each finished turn and a `set N` chip in place of the mem chip; `false` brings the mem chip back. `?working_set=1` or `?working_set=0` on the page URL overrides it for that page load; the turn view ignores it. See [CLI: the working set](cli.md#the-working-set). |
| `web.annotate_presets` | `Agreed\|Could you please elaborate?` | yes | Quick replies next to Annotate in `chi web`, `\|`-separated (a YAML list works too); `""` in the file or on the CLI leaves only Annotate (an empty env value means the default). See [CLI](cli.md#web-annotate-presets). |
| `web.editor` | `vscode` | yes | What a file ref in `chi web` (a file tool row's title, a diff line) opens, for a viewer on this machine: a preset (`vscode`, `vscode-insiders`, `cursor`, `zed`) or a URL template with `{path}` and an optional `{line}`; `none` turns refs off. See [Opening files from chi web](#opening-files-from-chi-web). |
| `web.start_dir` | the folder `chi web` runs in | | The folder `chi web` starts in (`chi web --start-dir DIR` for one run): its page (the printed link, a bare `/`, the LAN link and QR code, the Home Screen app) opens on that folder's project, outside a repo on every session, and a new session from the all view starts there; the header's project picker switches projects. `~` and a relative path (resolved from your home folder) work; one that isn't a folder stops `chi web` from starting. `chi web` never changes its own folder. See [CLI](cli.md). |
| `web.participants.expires` | `7d` | | How long a participant's link lasts unless `chi share --expires` says otherwise: `Nh` or `Nd`, 1h to 30d. See [participants](internals/participants.md). |
| `web.participants.cap` | `2.0` | | What a participant's turns, and the side calls they cause, may cost you in dollars unless `chi share --cap` says otherwise ($0 to $1000); at the cap their next comment is refused (429 `cap_reached`) and you get a notice. `chi share cap ID P DOLLARS` changes one grant's. |
| `web.participants.queue` | `3` | | How many of a participant's turns may wait behind their running one (0 to 20); one more is refused (429 `too_many_turns`). |
| `web.public_url` | | | Experimental. The https origin people open `chi web` at through an auth proxy (`https://host` or `https://host:port`, no path); set, every request needs the access token, this machine's too, and links use it. A value that isn't an https origin stops `chi web` from starting. See [Behind an auth proxy](#behind-an-auth-proxy). |
| `web.proxy.identity_header` | | | Experimental. The request header the proxy puts the signed-in user's email in (`X-Forwarded-Email` for oauth2-proxy), checked next to the token: only one the proxy sets *and* replaces. Unset or `none`: the token alone decides. See [Behind an auth proxy](#behind-an-auth-proxy). |
| `web.proxy.owner` | | | Experimental. Your email as the identity header carries it (any case): a proxied request is the owner only with this identity and the token. Unset: nobody is the owner by identity. Needs `web.proxy.identity_header`. |
| `web.push.enabled` | `true` | | Push notifications to a phone's Home Screen app (approvals, questions, step-limit questions, cards, failed turns; done turns per device) when the bell there is on. Does anything only with an https public URL (`web.public_url`, or `chi web --tunnel tailscale`'s) and once a device subscribed; `false` turns the pushes and the routes off. See [Phone notifications](#phone-notifications-web-push). |
| `web.push.contact` | the public URL | | The contact the push services see in chi web's VAPID token: a `mailto:` address or an `https://` URL. Anything else stops `chi web` from starting (Apple refuses it). |
| `history.file` | state dir | | Prompt history path, shared by the TUI and the web composer. |
| `no_interrupt` | `false` | `--no-interrupt` | Raise the step limit of a turn to 1000 (or `turn.max_iterations`, when larger); a top-level key. |
| `no_default_input` | `false` | `--no-default-input` | Don't pre-fill `default.input`; a top-level key. |
| `skip_agents_md` | `false` | | Don't load AGENTS.md; a top-level key (see below). |

`max_tool_output_chars`, `skip_agents_md`, `no_interrupt` and
`no_default_input` have no section: in `config.yml` they are top-level keys as
written (`max_tool_output_chars: 20000`).
