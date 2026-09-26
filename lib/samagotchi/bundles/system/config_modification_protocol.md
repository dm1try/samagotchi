# Config Modification Protocol

This memory teaches the harness how to safely read and update `~/.config/samagotchi/config.yml` and related global config.

## Location

- Path: `Samagotchi::ConfigFile.global_path` = `$XDG_CONFIG_HOME/samagotchi/config.yml` or `~/.config/samagotchi/config.yml` (fallback when `XDG_CONFIG_HOME` unset; `ConfigFile` lives in `lib/samagotchi/config.rb`).
- The file is optional. Absence is not an error — treat as empty mapping.
- Content is YAML; top-level must be a mapping. Valid YAML is `YAML.safe_load(..., permitted_classes: [], aliases: false)` (`ConfigFile.read_yaml`).

## Structure — Unified Convention (Option A)

Single registry `Samagotchi::Config` (`Config::ENTRIES` in `lib/samagotchi/config.rb`) defines the implicit mapping:

- **ENV**: `SAMAGOTCHI_NESTED_PARAM` (UPPER + `SAMAGOTCHI_` + `_` = nesting dot)
- **YAML**: `nested: { param: value }` → dotted `nested.param` (lower `snake_case`, leaf keeps `_`; kebab alias `base-url` also accepted and normalized)
- **CLI**: `--nested-param` (kebab, `_` → `-` for both section+leaf; `--nested_param` is rejected as unknown by `bin/chi` with a "did you mean" hint)

Sections forbid `_`/`-` (`SECTION_RE` `/\A[a-z0-9]+\z/`); leaves keep `snake_case` in YAML (`base_url`) and become kebab in CLI (`base-url`) via registry derivation — no generic string split, registry lookup avoids flat vs nested collision.

**Universal entries** (`expose: [:env,:config,:cli]`): `default.model`, `server.host/port/transport/open_timeout/read_timeout`, `server.first_token_timeout` (env and config only), `recap.model/base_url/host_ref/inactivity/timeout/min_user_turns/sentences`, `session.retention_days/max_count/keep_status/sweep_interval_hours/idle_exit_minutes`, `session.shared/keep_empty/max_children` (env and config only), `log.file/disable`, `status.line/width_mode/max_width/fixed_width`, `context.status/window_tokens/chars_per_token/status_thresholds/status_cadence`, `thinking.ui/preview_lines/render_interval`, `n_predict`, `max_tool_output_chars`, `retry.max/base_delay/max_delay`, `read.*`, `execute.*`, `web.port/host`, `no_interrupt`, `no_default_input` etc. (`Config::ENTRIES`; `expose` says which of env/config/cli each takes). Precedence is `CLI > ENV > file > default`.

Example `config.yml` (new nested form, preferred):

```yaml
default:
  model: unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M
  input: "Hey Chi, "
server:
  host: 192.168.1.29
  port: 8081
  transport: llama_cpp  # llama_cpp|mlx|omlx
  first_token_timeout: 120  # seconds a request may wait for its first token; 0 = off; unset: 120 for remote hosts, none for local
recap:
  host_ref: recap-box   # or base_url: http://...
  model: gemma4-small
  inactivity: 180
  timeout: 30
  min_user_turns: 2
  sentences: 2-4        # recap length: N or N-M, 1-10
session:
  retention_days: 14
  max_count: 500
  keep_status: running
  sweep_interval_hours: 24
  idle_exit_minutes: 30   # a background worker nobody uses exits; 0 = never
  shared: true            # the default: plain `chi` runs its session in a background worker and attaches (as `chi --shared`); false keeps the in-process REPL (env SAMAGOTCHI_SESSION_SHARED; no CLI flag, `--no-shared` opts out per run)
  keep_empty: false       # the default: a session nothing happened in (no prompt, default model, no note/image) is deleted when left; true keeps it (env SAMAGOTCHI_SESSION_KEEP_EMPTY)
  max_children: 4         # running child sessions one session may have delegated at a time (the delegate tool; env SAMAGOTCHI_SESSION_MAX_CHILDREN)
log:
  file: ~/chi.log         # optional; the default is $XDG_STATE_HOME/samagotchi/samagotchi.log (~/.local/state/…); relative paths are from the cwd of the `chi` that starts the worker
  disable: false
```

Legacy flat keys (`SAMAGOTCHI_DEFAULT_MODEL`, `SAMAGOTCHI_N_PREDICT` etc. at top-level) are still read via fallback in `Config.lookup_yaml` but warn `Warning: config key 'SAMAGOTCHI_DEFAULT_MODEL' is legacy UPPER — use 'default.model'` (`ConfigFile.load_global_env!`). Migrate them to nested form and remove the flat entry. The old `LLAMA_HOST`/`LLAMA_PORT` aliases were fully removed (Aug 2026); use `server.host`/`server.port` (nested) or `SAMAGOTCHI_SERVER_HOST`/`SAMAGOTCHI_SERVER_PORT`.

**Excluded maps** (YAML-only, not part of the flat registry; skipped by scalar loader):

- `model_aliases:` map of alias → model id (`ConfigFile.resolve_model_alias`). Keys lowercased on write (`ConfigFile.write_model_alias!`). Values may be bare `model` or qualified `host:model` (hybrid).
- `hosts:` map of `name → {host, port | url, transport, api, api_key_env, profile, first_token_timeout, enabled}` (`ConfigFile.hosts_config`, `host_registry.rb` `HostEntry`). Names lowercased; `url:` (http/https, optional path) replaces host/port, never both; `api_key_env:` names the env var holding the API key (never write a key into config.yml); `transport` overrides `server.transport`; `first_token_timeout` (seconds, `0` = off; a negative or non-number warns and is ignored) overrides `server.first_token_timeout` for that host; workers inherit via `SAMAGOTCHI_HOSTS_JSON` (`hosts_json_for_env`, `session_manager.rb`).
- `models:` map of model id or alias → `{profile}` (`ConfigFile.model_settings`). Keys match case-insensitively. `profile` (here or on a host) is `qwen36|gemma4`: the raw prompt format for native hosts. Precedence: `--profile`/`SAMAGOTCHI_MODEL_PROFILE` > `models:` > `hosts.<name>.profile` > the llama.cpp server's chat template > the name (`qwen`/`gemma`) > `qwen36` (`ModelProfile.resolve`). Set one when a model's name hides its family (e.g. a Qwen fine-tune under another name on mlx, which has no template to read).
- `hooks:` map of `hooks_dir` + per-event lists `{path, on_error}` (`Hooks::Loader.load`). `hooks_dir` may start with `~`.
- `bundles:` map of installed bundle name → its settings (one Hash, string keys, handed to the bundle's hook/plugin `initialize(settings)`). Read when a session's Engine starts: after a change restart the session's worker (`chi sessions stop <id>`) or the REPL. Unknown keys are ignored by the bundle, not validated. `chi bundle list` names the bundles; each bundle's keys are in `docs/plugins.md` / `docs/guardrails.md`.

```yaml
bundles:
  known-names:
    names: [dzmitrydziadou]    # protected besides home/login/git/repo names
    mode: reject               # reject | correct | ask
  btw:
    max_tokens: 1024
    timeout: 120
  loop-guard:
    deny_after: 2              # same call + same result N times in a turn -> deny the next
    stop_after: 4              # stop the turn at this many denies
    mode: deny                 # deny | notify (warn only); ignore_tools: [task_wait, ...]
  mcp:                         # tools become mcp_<server>_<tool>; /mcp lists them
    timeout: 60                # per call, seconds; startup_timeout: 10
    servers:
      files:                   # server name
        command: [npx, -y, "@modelcontextprotocol/server-filesystem", ~/scratch]  # stdio only; array (or one string, shell-split)
        env: {NODE_OPTIONS: "--no-warnings"}   # optional, added to chi's env
        cwd: ~/scratch                         # optional; default the session's cwd
        tools: [read_*, list_directory]        # optional filter (globs)
```

A guardrail rule's `tool:` may be a glob (`tool: "mcp_*"`, verdict `ask`) to cover every MCP tool; see `docs/guardrails.md`.

**Preservation rule**: `ConfigFile.write_default_model!` and `ConfigFile.write_model_alias!` both load raw YAML (including nested sections and maps), mutate one key (`raw_data["default"]["model"] = ...` for new form), write atomically via `tmp`+`rename`. Never overwrite the file with only scalar keys — that would clobber `hooks:` / `model_aliases:` / `hosts:` / `recap:` / `bundles:`.

## Workflow for any config edit

1. **Read** the current file via `read` tool (or `ConfigFile.global_path`). If `File.file?` false, start from `{}`.
2. `YAML.safe_load` (permitted_classes: [], aliases: false). If data nil or not Hash, treat as `{}` or raise with path.
3. Mutate the intended **nested** key in the raw hash. Preserve all other keys byte-for-byte where possible. Example for default model: `raw_data["default"] ||= {}; raw_data["default"]["model"] = "new-model"; raw_data.delete("SAMAGOTCHI_DEFAULT_MODEL")` to migrate legacy.
4. **Validate** (see below) before writing. Also run `Samagotchi::Config.validate_yaml_sections` — it rejects top-level `_` (suggest `default.model`) and warns on legacy flat keys.
5. **Write atomically**: `FileUtils.mkdir_p(File.dirname(path))`, `File.write("#{path}.tmp", YAML.dump(raw_data))`, `File.rename("#{path}.tmp", path)`.
6. Update in-process state: `write_default_model!` sets `ENV["SAMAGOTCHI_DEFAULT_MODEL"]` and `Samagotchi::Config.reload!`; otherwise the harness picks it up on next `Config.get` (live resolve) or restart. CLI overrides (`--default-model`) win over file until process exit.

## Validations

- **Model name** (`default.model` / `SAMAGOTCHI_DEFAULT_MODEL`): `ModelProfile.required_model_name` — non-empty string, otherwise harness fails fast at startup. Via `Config.get("default.model")` with ENV fallback.
- **Host api** (`hosts.<name>.api`): `llama_cpp|mlx|omlx` (raw-prompt loop; also the transport) or `openai` (chat loop at `http://HOST:PORT/v1`). Absent: raw-prompt loop. It replaces the removed `backend` setting.
- **Transport** (`server.transport`): enum `llama_cpp|mlx|omlx`.
- **Profile** (`models.<id>.profile`, `hosts.<name>.profile`, `SAMAGOTCHI_MODEL_PROFILE`): enum `qwen36|gemma4`; an unknown one warns and is ignored.
- **Alias name** (`write_model_alias!`):
  - required, non-empty, no whitespace, not starting with `-`, no `/`, must match `/\A[a-z0-9][a-z0-9._-]*\z/i`
  - reserved: `clear`, `default`, `none`, `off` (lowercased)
  - must not point to itself (case-insensitive)
  - keys are normalized to downcase on write — `Qwen` and `qwen` collide
- **Alias target**: non-empty string (model id).
- **Hosts**: each entry needs `host`, `port` 1-65535, `transport` and `api` optional (a raw `api` must match `transport`), name must match `/\A[a-z0-9][a-z0-9._-]*\z/i`.
- **Hooks**: each entry must have `path` (relative to `hooks_dir`), `on_error` is `skip` (default) or `log`. Class name must match file basename snake→Pascal.
- **Scalars via registry**: `Config.coerce` validates `String/Numeric/true/false` per `type: :string/:integer/:float/:bool/:enum`; invalid values warn and fall back to entry `default`.
- **Sections**: `validate_yaml_sections` rejects top-level keys containing `_` (suggest dotted) and section names containing `_`/`-`.

## Tools to use

- Prefer `read` + `write`/`edit` on `config.yml`. Do **not** use `memory_write` for config.
- For single-model switches, prefer the `ConfigFile` helpers (`write_default_model!`, `write_model_alias!`) via `execute` `ruby -I <source dir>/lib -r samagotchi/config -e ...` (`chi self` prints the source dir) if available, otherwise direct nested YAML edit as above.
- For generic keys, you may also use `ruby -r samagotchi/config -e 'Samagotchi::Config.reload!(cli_overrides: {...})'` in tests, but prefer file edit for persistence.
- After editing, verify with `YAML.safe_load(File.read(path))` or `XDG_CONFIG_HOME=/tmp/empty bin/chi --help` (shows generated `--recap-base-url` etc.) / `bin/chi bundle status` if relevant.

## Hints

- Precedence is `CLI > ENV > file > default` (`Config.resolve`). Real `ENV` still wins over file (`load_global_env!` `unless env.key?` for legacy sync), and CLI (`--recap-base-url`) wins over both via `Config.reload!(cli_overrides:)`.
- `--recap_base_url` (underscore) is rejected as unknown — use `--recap-base-url` (kebab). Same for all registry flags.
- `model_aliases` require restart or `/model` reload to take effect; document the change.
- Keep edits minimal: touch only the key you intend to change; preserve `hosts:`/`hooks:`/`bundles:` maps. Adding a `bundles: <name>:` entry does not install the bundle (`chi bundle install <name>`).
- To silence legacy warnings, migrate flat `SAMAGOTCHI_*` keys to nested form and delete the flat entry atomically.
