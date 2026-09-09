# Config Modification Protocol

This memory teaches the harness how to safely read and update `~/.config/samagotchi/config.yml` and related global config.

## Location

- Path: `Samagotchi::ConfigFile.global_path` = `$XDG_CONFIG_HOME/samagotchi/config.yml` or `~/.config/samagotchi/config.yml` (fallback when `XDG_CONFIG_HOME` unset, see `lib/samagotchi/config_file.rb:57`).
- The file is optional. Absence is not an error — treat as empty mapping.
- Content is YAML; top-level must be a mapping. Valid YAML is `YAML.safe_load(..., permitted_classes: [], aliases: false)` (`lib/samagotchi/config.rb:120`, `lib/samagotchi/config_file.rb:63`).

## Structure — Unified Convention (Option A)

Single registry `Samagotchi::Config` (`lib/samagotchi/config.rb:22`) defines the implicit mapping:

- **ENV**: `SAMAGOTCHI_NESTED_PARAM` (UPPER + `SAMAGOTCHI_` + `_` = nesting dot)
- **YAML**: `nested: { param: value }` → dotted `nested.param` (lower `snake_case`, leaf keeps `_`; kebab alias `base-url` also accepted and normalized)
- **CLI**: `--nested-param` (kebab, `_` → `-` for both section+leaf; `--nested_param` is rejected as unknown, see `bin/chi:622`)

Sections forbid `_`/`-` (`SECTION_RE` `/\A[a-z0-9]+\z/`); leaves keep `snake_case` in YAML (`base_url`) and become kebab in CLI (`base-url`) via registry derivation — no generic string split, registry lookup avoids flat vs nested collision.

**Universal entries** (`expose: [:env,:config,:cli]`): `default.model`, `backend`, `server.host/port/transport/open_timeout/read_timeout`, `recap.model/base_url/host_ref/inactivity/timeout/min_user_turns`, `session.retention_days/max_count/keep_status/sweep_interval_hours`, `log.file/disable`, `status.line/width_mode/max_width/fixed_width`, `context.status/window_tokens/chars_per_token/status_thresholds/status_cadence`, `thinking.ui/preview_lines/render_interval`, `n_predict`, `max_tool_output_chars`, `retry.max/base_delay/max_delay`, `read.*`, `execute.*`, `web.port/host`, `no_interrupt`, `no_default_input` etc. (`lib/samagotchi/config.rb:22-75`). Precedence is `CLI > ENV > file > default`.

Example `config.yml` (new nested form, preferred):

```yaml
default:
  model: unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M
  input: "Hey Chi, "
server:
  host: 192.168.1.29
  port: 8081
  transport: llama_cpp  # llama_cpp|mlx|omlx
recap:
  host_ref: recap-box   # or base_url: http://...
  model: gemma4-small
  inactivity: 180
  timeout: 30
  min_user_turns: 2
session:
  retention_days: 14
  max_count: 500
  keep_status: running
  sweep_interval_hours: 24
log:
  file: ./tmp/samagotchi.log
  disable: false
```

Legacy flat keys (`SAMAGOTCHI_DEFAULT_MODEL`, `LLAMA_HOST`, `SAMAGOTCHI_N_PREDICT` etc. at top-level) are still read via fallback in `Config.lookup_yaml` (`lib/samagotchi/config.rb:244`) but warn `Warning: config key 'SAMAGOTCHI_DEFAULT_MODEL' is legacy UPPER — use 'default.model'` (`lib/samagotchi/config_file.rb:32`). Migrate them to nested form and remove the flat entry.

**Excluded maps** (YAML-only, not part of the flat registry; skipped by scalar loader):

- `model_aliases:` map of alias → model id (`config_file.rb:342`, `resolve_model_alias:321`). Keys lowercased on write (`write_model_alias!:367`). Values may be bare `model` or qualified `host:model` (hybrid).
- `hosts:` map of `name → {host, port, transport, enabled}` (`config_file.rb:108`, `host_registry.rb:22`). Names lowercased; `transport` overrides `server.transport`; workers inherit via `SAMAGOTCHI_HOSTS_JSON` (`hosts_json_for_env:251`, `session_manager.rb:80`).
- `hooks:` map of `hooks_dir` + per-event lists `{path, on_error}` (`lib/samagotchi/hooks/loader.rb:32`). `hooks_dir` may start with `~`.

**Preservation rule**: `write_default_model!` (`config_file.rb:263`) and `write_model_alias!` (`config_file.rb:342`) both load raw YAML (including nested sections and maps), mutate one key (`raw_data["default"]["model"] = ...` for new form), write atomically via `tmp`+`rename`. Never overwrite the file with only scalar keys — that would clobber `hooks:` / `model_aliases:` / `hosts:` / `recap:`.

## Workflow for any config edit

1. **Read** the current file via `read` tool (or `ConfigFile.global_path`). If `File.file?` false, start from `{}`.
2. `YAML.safe_load` (permitted_classes: [], aliases: false). If data nil or not Hash, treat as `{}` or raise with path.
3. Mutate the intended **nested** key in the raw hash. Preserve all other keys byte-for-byte where possible. Example for default model: `raw_data["default"] ||= {}; raw_data["default"]["model"] = "new-model"; raw_data.delete("SAMAGOTCHI_DEFAULT_MODEL")` to migrate legacy.
4. **Validate** (see below) before writing. Also run `Samagotchi::Config.validate_yaml_sections` — it rejects top-level `_` (suggest `default.model`) and warns on legacy flat keys.
5. **Write atomically**: `FileUtils.mkdir_p(File.dirname(path))`, `File.write("#{path}.tmp", YAML.dump(raw_data))`, `File.rename("#{path}.tmp", path)`.
6. Update in-process state: `write_default_model!` sets `ENV["SAMAGOTCHI_DEFAULT_MODEL"]` and `Samagotchi::Config.reload!`; otherwise the harness picks it up on next `Config.get` (live resolve) or restart. CLI overrides (`--default-model`) win over file until process exit.

## Validations

- **Model name** (`default.model` / `SAMAGOTCHI_DEFAULT_MODEL`): `ModelProfile.required_model_name:101` — non-empty string, otherwise harness fails fast at startup. Via `Config.get("default.model")` with ENV fallback.
- **Backend** (`backend`): enum `native|ruby_llm` (`Config` `enum_values`), default `native`.
- **Transport** (`server.transport`): enum `llama_cpp|mlx|omlx`.
- **Alias name** (`write_model_alias!:342`):
  - required, non-empty, no whitespace, not starting with `-`, no `/`, must match `/\A[a-z0-9][a-z0-9._-]*\z/i`
  - reserved: `clear`, `default`, `none`, `off` (lowercased)
  - must not point to itself (case-insensitive)
  - keys are normalized to downcase on write — `Qwen` and `qwen` collide
- **Alias target**: non-empty string (model id).
- **Hosts**: each entry needs `host`, `port` 1-65535, `transport` optional, name must match `/\A[a-z0-9][a-z0-9._-]*\z/i`.
- **Hooks**: each entry must have `path` (relative to `hooks_dir`), `on_error` is `skip` (default) or `log`. Class name must match file basename snake→Pascal.
- **Scalars via registry**: `Config.coerce` validates `String/Numeric/true/false` per `type: :string/:integer/:float/:bool/:enum`; invalid values warn and fall back to entry `default`.
- **Sections**: `validate_yaml_sections` rejects top-level keys containing `_` (suggest dotted) and section names containing `_`/`-`.

## Tools to use

- Prefer `read` + `write`/`edit` on `config.yml`. Do **not** use `memory_write` for config.
- For single-model switches, prefer the `ConfigFile` helpers (`write_default_model!`, `write_model_alias!`) via `execute` `ruby -r samagotchi/config_file -e ...` if available, otherwise direct nested YAML edit as above.
- For generic keys, you may also use `ruby -r samagotchi/config -e 'Samagotchi::Config.reload!(cli_overrides: {...})'` in tests, but prefer file edit for persistence.
- After editing, verify with `YAML.safe_load(File.read(path))` or `XDG_CONFIG_HOME=/tmp/empty bin/chi --help` (shows generated `--recap-base-url` etc.) / `bin/chi bundle status` if relevant.

## Hints

- Precedence is `CLI > ENV > file > default` (`Config.resolve`). Real `ENV` still wins over file (`load_global_env!` `unless env.key?` for legacy sync), and CLI (`--recap-base-url`) wins over both via `Config.reload!(cli_overrides:)`.
- `--recap_base_url` (underscore) is rejected as unknown — use `--recap-base-url` (kebab). Same for all registry flags.
- `model_aliases` require restart or `/model` reload to take effect; document the change.
- Keep edits minimal: touch only the key you intend to change; preserve `hosts:`/`hooks:` maps.
- To silence legacy warnings, migrate flat `SAMAGOTCHI_*` keys to nested form and delete the flat entry atomically.
