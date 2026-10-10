# Config Modification Protocol

This memory explains how to safely read and update `~/.config/samagotchi/config.yml` and related global config.

## Location

- Path: `Samagotchi::ConfigFile.global_path` = `$XDG_CONFIG_HOME/samagotchi/config.yml` or `~/.config/samagotchi/config.yml` (fallback when `XDG_CONFIG_HOME` unset; `ConfigFile` lives in `lib/samagotchi/config.rb`).
- The file is optional. Absence is not an error — treat as empty mapping.
- Content is YAML; top-level must be a mapping. Valid YAML is `YAML.safe_load(..., permitted_classes: [], aliases: false)` (`ConfigFile.read_yaml`).

## Structure — Unified Convention

Single registry `Samagotchi::Config` (`Config::ENTRIES` in `lib/samagotchi/config.rb`) defines the implicit mapping:

- **ENV**: `SAMAGOTCHI_NESTED_PARAM` (UPPER + `SAMAGOTCHI_` + `_` = nesting dot)
- **YAML**: `nested: { param: value }` → dotted `nested.param` (lower `snake_case`, leaf keeps `_`; kebab alias `base-url` also accepted and normalized)
- **CLI**: `--nested-param` (kebab, `_` → `-` for both section+leaf; `--nested_param` is rejected as unknown by `chi` with a "did you mean" hint)

Sections forbid `_`/`-` (`SECTION_RE` `/\A[a-z0-9]+\z/`); leaves keep `snake_case` in YAML (`base_url`) and become kebab in CLI (`base-url`) via registry derivation — no generic string split, registry lookup avoids flat vs nested collision.

**Universal entries** (`expose: [:env,:config,:cli]`): `default.model`, `server.host/port/transport/open_timeout/read_timeout`, `server.first_token_timeout` (env and config only), `recap.model/base_url/host_ref/inactivity/timeout/min_user_turns/sentences`, `session.retention_days/max_count/keep_status/sweep_interval_hours/idle_exit_minutes`, `session.shared/keep_empty/max_children` (env and config only), `log.file/disable`, `status.line`, `context.status/window_tokens/chars_per_token/status_thresholds`, `memory.index_warn_tokens`, `thinking.turn_preamble`, `default.max_tokens`, `max_tool_output_chars`, `retry.max/base_delay/max_delay`, `read.*`, `execute.*`, `web.port/host`, `no_interrupt`, `no_default_input` etc. (`Config::ENTRIES`; `expose` says which of env/config/cli each takes). Precedence is `CLI > ENV > file > default`.

Example `config.yml` (new nested form, preferred):

```yaml
default:
  model: your-model-id
  input: "Please "      # text pre-filled at the prompt; a trailing space is kept
server:
  host: localhost
  port: 8080
  transport: llama_cpp  # llama_cpp|mlx|omlx
  first_token_timeout: 120  # seconds a request may wait for its first token; 0 = off; unset: 120 for remote hosts, none for local
recap:
  host_ref: small-box   # a name under hosts:, or base_url: http://...
  model: your-small-model-id
  inactivity: 180
  timeout: 30
  min_user_turns: 2
  sentences: 2-4        # recap length: N or N-M, 1-10
session:
  retention_days: 14
  max_count: 500
  keep_status: ""        # the default: no status protects a session from pruning; a live worker or REPL always does
  sweep_interval_hours: 24
  idle_exit_minutes: 30   # a background worker nobody uses exits; 0 = never
  shared: true            # the default: plain `chi` runs its session in a background worker and attaches (as `chi --shared`); false keeps the in-process REPL (env SAMAGOTCHI_SESSION_SHARED; no CLI flag, `--no-shared` opts out per run)
  keep_empty: false       # the default: a session nothing happened in (no prompt, default model, no note/image) is deleted when left; true keeps it (env SAMAGOTCHI_SESSION_KEEP_EMPTY)
  max_children: 4         # running child sessions one session may have delegated at a time (the delegate tool; env SAMAGOTCHI_SESSION_MAX_CHILDREN)
log:
  file: ~/chi.log         # optional; the default is $XDG_STATE_HOME/samagotchi/samagotchi.log (~/.local/state/…); relative paths are from the cwd of the `chi` that starts the worker
  disable: false
```

Only the nested form is read. An env name used as a top-level key (`SAMAGOTCHI_DEFAULT_MODEL: m`, the old flat form) is ignored and warns as an unknown key (`did you mean 'default.model'?`): move it to its nested form and delete the flat line. The old `LLAMA_HOST`/`LLAMA_PORT` aliases were removed; use `server.host`/`server.port` (nested) or `SAMAGOTCHI_SERVER_HOST`/`SAMAGOTCHI_SERVER_PORT`.

**Excluded maps** (YAML-only, not part of the flat registry; skipped by scalar loader):

- `model_aliases:` map of alias → model id (`ModelRef.parse`, through `HostRegistry#resolve`). Keys lowercased on write (`ConfigFile.write_model_alias!`). Values may be bare `model` or qualified `host:model` (hybrid; only `:` names a host, `org/model` is an id). Aliases apply once: never point an alias at another alias.
- `hosts:` map of `name → {host, port | url, transport, api, api_key_env, profile, first_token_timeout, vision, sampling, thinking, enabled, models}` (`ConfigFile.hosts_config`, `host_registry.rb` `HostEntry`). Names lowercased; `url:` (http/https, optional path) replaces host/port, never both; `api_key_env:` names the env var holding the API key (never write a key into config.yml); `transport` overrides `server.transport`; `first_token_timeout` (seconds, `0` = off; a negative or non-number warns and is ignored) overrides `server.first_token_timeout` for that host; `models:` (a map of model ids, or a plain list) declares ids the host serves whatever its `/v1/models` lists: no "doesn't list" warning, and a bare id routes there as if listed (`HostModel`); an entry may hold `price: {input, output, cache_read?, cache_write?}` in USD per 1M tokens (`ModelPrice`; an unset cache rate is the input rate), which estimates a cost the provider doesn't report or reports as 0 (`cost_estimate`, shown as `~$`), and `served: [ids] | any`, the models a gateway may answer that id with (no served-model warning for them); model settings stay in the root `models:`; workers inherit via `SAMAGOTCHI_HOSTS_JSON` (`hosts_json_for_env`, `session_manager.rb`).
- `models:` map of model id or alias → `{profile, vision, sampling, thinking}` (`ConfigFile.model_settings`). `thinking:` (here, on a host, or `thinking.level` for every model) is `off|low|medium|high|default` (`Thinking`; unquoted `off` works, `on` is not a level; `default` = send nothing). Precedence: the session's own level (`/thinking LEVEL`, saved in the session; `chi --thinking` on a session run, `chi send --new --thinking`) > `chi web --thinking`/`SAMAGOTCHI_THINKING_LEVEL` > `models:` > `hosts.<name>.thinking` > `thinking.level` in config.yml > `default`. A `sampling:` key wins over the fields a level sends (`null` drops one); `docs/configuration.md` "Thinking". `sampling:` (here or on a host) is a map of request fields passed to the provider as written (`temperature`, `top_p`, `presence_penalty`, `repeat_penalty`, …; a model's fields win over its host's per field; `null` = don't send; chi's own fields like `max_tokens`/`stream` are refused with a warning; `docs/configuration.md` "Sampling"). Keys match case-insensitively. `profile` (here or on a host) is `qwen36|gemma4`: the raw prompt format for native hosts. Precedence: `--profile`/`SAMAGOTCHI_MODEL_PROFILE` > `models:` > `hosts.<name>.profile` > the llama.cpp server's chat template > the name (`qwen`/`gemma`) > `qwen36` (`ModelProfile.resolve`). Set one when a model's name hides its family (e.g. a Qwen fine-tune under another name on mlx, which has no template to read).
- `hooks:` map of `hooks_dir` + per-event lists `{path, on_error}` (`Hooks::Loader.load`). `hooks_dir` may start with `~`.
- `guardrails:` tool-call rules (`docs/guardrails.md`; read in `Engine#guardrail_rules`, parsed by `Guardrails::Rules.parse`): `enabled` (bool, default true; `false` drops rules and hooks' asks, a deny still applies; config.yml only, like every `guardrails` setting: no env variable), `parent_approvals` (`off`, the default: a parent agent's `chi answer` can only deny an approval; `once`: it may give "Allow once" too; a convention for an honest parent, not a security boundary, and the user's choice: set it only when the user asks), `rules:` (list), `disable:` (a rule id or a list of them, `id` or `bundle:id`, switching off a bundle's or config rule without editing it), `small_models` (`auto`, the default: small = 32B or less read from the name; a glob or list of globs; `[]` for none). A rule takes only `id`, `tool`, `command`, `path`, `git`, `models`, `verdict`, `reason`, `scopes`: `id` required; at least one of `tool` (a name, `shell` = execute + task_create, a `File.fnmatch` glob like `"mcp_*"`, or a list), `command` (a Ruby regex on the shell command), `path` (a glob, or `outside_repo`: outside the session's repo, tmp folders and memory files excepted), `git` (only `outside_repo`: a shell call runs commit/add/reset/… in another checkout); `models` (optional: `small`, a model-name glob, or a list; without it the rule is for every model); `verdict` `ask|deny`; `scopes` (for `ask`) a subset of `once, session, repo, rule`. **Any parse error (an unknown key, a bad regex, no verdict) makes chi deny every tool call** until fixed, so validate with `YAML.safe_load` and keep the list shape. Rules are read again on the next tool call after config.yml or a bundle's rules change: no restart needed. Installed bundles' rule files (`chi bundle install guardrails`) add to them; `/guardrails` lists what loaded.

```yaml
guardrails:
  enabled: true
  rules:
    - id: git-push
      tool: shell
      command: '\bgit\s+push\b'
      verdict: ask
      reason: git push publishes commits
    - id: mcp-ask
      tool: "mcp_*"
      verdict: ask
      reason: an MCP server's tool
  disable: [guardrails:git-rebase]
```

- `bundles:` map of installed bundle name → its settings (one Hash, string keys, handed to the bundle's hook/plugin `initialize(settings)`). Read when a session's Engine starts: after a change restart the session's worker (`chi sessions stop <id>`) or the REPL. Unknown keys are ignored by the bundle, not validated. `chi bundle list` names the bundles; each bundle's keys are in `docs/plugins.md` / `docs/guardrails.md`.

```yaml
bundles:
  known-names:
    names: [jonathandoe]       # protected besides home/login/git/repo names
    mode: reject               # reject | correct | ask
  btw:
    max_tokens: 1024
    timeout: 120
  loop-guard:
    deny_after: 2              # same call + same result N times in a turn -> deny the next
    stop_after: 4              # stop the turn at this many denies
    mode: deny                 # deny | notify (warn only); ignore_tools: [task_wait, ...]
    thinking:                  # the watch on thinking that repeats itself
      watch: true              # false: the tool-call guard only
      action: retry            # retry (cut, ask again; then stop) | stop | notify
  check-in:
    after: 50                  # tool calls in one turn with no answer before the first check
    every: 50                  # then again every N more
    mode: ask                  # ask (a card) | nudge (nudge the model by itself) | notify; message:, ignore_tools: [...]
  mcp:                         # the model searches the tools (find_mcp_tools) and calls one (mcp_call, <server>/<tool>); /mcp lists them
    timeout: 60                # per call, seconds; startup_timeout: 10
    servers:
      files:                   # server name
        command: [npx, -y, "@modelcontextprotocol/server-filesystem", ~/scratch]  # stdio only; array (or one string, shell-split)
        env: {NODE_OPTIONS: "--no-warnings"}   # optional, added to chi's env
        cwd: ~/scratch                         # optional; default the session's cwd
        tools: [read_*, list_directory]        # optional filter (globs)
        description: files in ~/scratch        # optional: the server's line in find_mcp_tools (default: its instructions' first sentence)
        attach_image_paths: true               # default: an answer that is only an image's path (temp dir/cwd) is attached as a picture
        start: lazy                            # default: tools from the saved tools/list, the server starts on the first call; eager: with every session
```

A guardrail rule's `tool:` may be a glob (`tool: "mcp_*"`, verdict `ask`) to cover every MCP tool: an `mcp_call` acts as `mcp_<server>_<tool>`, so `tool: "mcp_github_*"` covers one server's (a `find_mcp_tools` search is never asked about); see `docs/guardrails.md`. A server's optional `description:` is its line in `find_mcp_tools`' description. The mcp bundle saves each server's tool list in `$XDG_STATE_HOME/samagotchi/plugins/mcp/tools-<server>.json` (keyed by a digest of command/env/cwd): a changed server config is picked up by the next session start, which shows "Starting MCP server x (config changed, …)".

**Preservation rule**: `ConfigFile.write_default_model!` and `ConfigFile.write_model_alias!` (`/model --default`, `/model --alias`) change one key on its own line of the text (`ConfigTextEdit`: the user's comments and layout stay; a new key goes at the end of its section, a missing section at the end of the file), check that the result parses to the old data plus that key (else they dump the whole file from it), and write through `AtomicFile` (a unique temp file renamed over config.yml, through a symlink, keeping its mode). Never overwrite the file with only scalar keys — that would clobber `hooks:` / `model_aliases:` / `hosts:` / `recap:` / `guardrails:` / `bundles:`.

## Workflow for any config edit

1. **Read** the current file via `read` tool (or `ConfigFile.global_path`). If `File.file?` false, start from `{}`.
2. `YAML.safe_load` (permitted_classes: [], aliases: false). If data nil or not Hash, treat as `{}` or raise with path.
3. Mutate the intended **nested** key in the raw hash. Preserve all other keys byte-for-byte where possible. Example for default model: `raw_data["default"] ||= {}; raw_data["default"]["model"] = "new-model"`.
4. **Validate** (see below) before writing. Also run `Samagotchi::Config.validate_yaml_sections` — it returns one `config: unknown key '…' (did you mean '…'?)` per key chi doesn't read (every config-exposed `Config::ENTRIES` key is known as written, including the section-less `max_tool_output_chars` and `skip_agent_md`; names under `hosts:`/`models:`/`model_aliases:`/`hooks:`/`bundles:`/`memories:` are free-form, host and model entries are checked against `Config::MAP_ENTRY_KEYS`). An empty list means no warning at start.
5. **Write**: change only the lines you mean to, with the edit tool, so the user's comments and layout stay; `YAML.dump` of the whole hash drops every comment, so rewrite the file only when it has none worth keeping. From Ruby, write atomically with `Samagotchi::AtomicFile.write(path, text)` (a unique temp file renamed over it), never through a fixed `"#{path}.tmp"` that another chi may be writing at the same time.
6. Nothing else to update: config.yml values are never copied into `ENV`, and every `Config.get` reads the file again when it changed, so the next read (and every worker started after the write) sees the new value with origin `:file`. What a running worker set up at its start (`hosts:`, bundle settings) waits for its restart; guardrail rules and `model_aliases:` are read again live. CLI overrides (`--model`, `--recap-model`, …) win over the file until the process exits; a worker gets its spawner's CLI settings through its env (`Config.cli_env`).

## Validations

- **Model name** (`default.model` / `SAMAGOTCHI_DEFAULT_MODEL`): `ModelProfile.required_model_name` — non-empty string, otherwise harness fails fast at startup. Via `Config.get("default.model")`.
- **Host api** (`hosts.<name>.api`): `llama_cpp|mlx|omlx` (raw-prompt loop; also the transport) or `openai` (chat loop at `http://HOST:PORT/v1`). Absent: raw-prompt loop. It replaces the removed `backend` setting.
- **Transport** (`server.transport`): enum `llama_cpp|mlx|omlx`.
- **Profile** (`models.<id>.profile`, `hosts.<name>.profile`, `SAMAGOTCHI_MODEL_PROFILE`): enum `qwen36|gemma4`; an unknown one warns and is ignored.
- **Alias name** (`write_model_alias!`):
  - required, non-empty, no whitespace, not starting with `-`, no `/`, must match `/\A[a-z0-9][a-z0-9._-]*\z/i`
  - reserved: `clear`, `default`, `none`, `off` (lowercased)
  - must not point to itself (case-insensitive)
  - keys are normalized to downcase on write — `Qwen` and `qwen` collide
- **Alias target**: non-empty string (model id).
- **Hosts**: each entry needs `host` (or `url:`, an http(s) URL with an optional path, replacing `host`/`port`; never both), `port` 1-65535 (default 8080), `enabled: false` skips the entry, `transport` and `api` optional (a raw `api` must match `transport`), name must match `/\A[a-z0-9][a-z0-9._-]*\z/i`.
- **Hooks**: each entry must have `path` (relative to `hooks_dir`), `on_error` is `skip` (default) or `log`; `required: true` on a `before_tool_call` hook denies the call when the hook raises. Class name must match file basename snake→Pascal.
- **Scalars via registry**: `Config.coerce` validates `String/Numeric/true/false` per `type: :string/:integer/:float/:bool/:enum`; invalid values warn and fall back to entry `default`.
- **Keys**: `validate_yaml_sections` flags unknown keys (with a suggestion), a registry section that isn't a mapping, and env/CLI-only keys (`model.profile`).

## Tools to use

- Prefer `read` + `write`/`edit` on `config.yml`. Do **not** use `memory_write` for config.
- For single-model switches, prefer the `ConfigFile` helpers (`write_default_model!`, `write_model_alias!`) via `execute` `ruby -I <source dir>/lib -r samagotchi/config -e ...` (`chi self` prints the source dir) if available, otherwise direct nested YAML edit as above.
- After editing, verify with `YAML.safe_load(File.read(path))` or `chi --help` (shows generated `--recap-base-url` etc.) / `chi bundle list` if relevant.

## Hints

- Precedence is `CLI > ENV > file > default` (`Config.resolve`; `Config.get_with_origin` names the layer). `ENV` holds only what the user (or a spawning chi's CLI flags) set, and CLI (`--recap-base-url`) wins over both via `Config.reload!(cli_overrides:)`.
- `--recap_base_url` (underscore) is rejected as unknown — use `--recap-base-url` (kebab). Same for all registry flags.
- `model_aliases` are read again at each model resolution: an edit applies to the next `--model`, `/model`, new session or delegate, no restart. A running session keeps the model it already resolved.
- Keep edits minimal: touch only the key you intend to change; preserve `hosts:`/`hooks:`/`guardrails:`/`bundles:` maps. Adding a `bundles: <name>:` entry does not install the bundle (`chi bundle install <name>`).
