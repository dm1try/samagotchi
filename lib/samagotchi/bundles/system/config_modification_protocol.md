# Config Modification Protocol

This memory teaches the harness how to safely read and update `~/.config/samagotchi/config.yml` and related global config.

## Location

- Path: `Samagotchi::ConfigFile.global_path` = `$XDG_CONFIG_HOME/samagotchi/config.yml` or `~/.config/samagotchi/config.yml` (fallback when `XDG_CONFIG_HOME` unset, see `lib/samagotchi/config_file.rb:26`).
- The file is optional. Absence is not an error — treat as empty mapping.
- Content is YAML; top-level must be a mapping (`parse_file:32` raises otherwise).

## Structure

- **Flat scalar env overrides**: string/number/boolean values become `ENV` entries (`load_global_env!:16` only sets if `ENV[key]` not already set). Examples: `SAMAGOTCHI_DEFAULT_MODEL`, `LLAMA_HOST`, `LLAMA_PORT`, `SAMAGOTCHI_BACKEND`, `SAMAGOTCHI_THINKING_UI`, `SAMAGOTCHI_STATUS_LINE`, etc.
- **Nested sections** (skipped by env loader, parsed by subsystems):
  - `model_aliases:` map of alias → model id (`model_aliases:80`, `resolve_model_alias:101`). Keys lowercased on read/write (`write_model_alias!:140`).
  - `hooks:` map of `hooks_dir` + per-event lists `{path, on_error}` (`lib/samagotchi/hooks/loader.rb:32`). `hooks_dir` may start with `~`.
- **Preservation rule**: `write_default_model!:63` and `write_model_alias!:128` both load raw YAML (including nested sections), mutate one key, write atomically via `tmp`+`rename`. Never overwrite the file with only scalar keys — that would clobber `hooks:` / `model_aliases:`.

## Workflow for any config edit

1. **Read** the current file via `read` tool (or `ConfigFile.global_path`). If `File.file?` false, start from `{}`.
2. `YAML.safe_load` (permitted_classes: [], aliases: false). If data nil or not Hash, treat as `{}` or raise with path.
3. Mutate the intended key in the raw hash. Preserve all other keys byte-for-byte where possible.
4. **Validate** (see below) before writing.
5. **Write atomically**: `FileUtils.mkdir_p(File.dirname(path))`, `File.write("#{path}.tmp", YAML.dump(raw_data))`, `File.rename("#{path}.tmp", path)`.
6. Update in-process `ENV` if the harness caches it (e.g., `write_default_model!:75` sets `ENV[DEFAULT_MODEL_KEY]`).

## Validations

- **Model name** (`SAMAGOTCHI_DEFAULT_MODEL`): `ModelProfile.required_model_name:101` — non-empty string, otherwise harness fails fast at startup.
- **Alias name** (`write_model_alias!:111`):
  - required, non-empty, no whitespace, not starting with `-`, no `/`, must match `/\A[a-z0-9][a-z0-9._-]*\z/i`
  - reserved: `clear`, `default`, `none`, `off` (lowercased)
  - must not point to itself (case-insensitive)
  - keys are normalized to downcase on write — `Qwen` and `qwen` collide
- **Alias target**: non-empty string (model id).
- **Hooks**: each entry must have `path` (relative to `hooks_dir`), `on_error` is `skip` (default) or `log`. Class name must match file basename snake→Pascal.
- **Env scalars**: `scalar_value?:54` — String/Numeric/true/false only; Arrays/Hashes are ignored for ENV but valid for `hooks`/`model_aliases`.

## Tools to use

- Prefer `read` + `write`/`edit` on `config.yml`. Do **not** use `memory_write` for config.
- For single-model switches, prefer the `ConfigFile` helpers (`write_default_model!`, `write_model_alias!`) via `execute` `ruby -r samagotchi/config_file -e ...` if available, otherwise direct YAML edit.
- After editing, verify with `YAML.safe_load(File.read(path))` or `chi --help` / `chi memory status` if relevant.

## Hints

- Real `ENV` wins over config file (`load_global_env!:20` `unless env.key?`). Setting a value in config won’t override an exported env var in the same session.
- `model_aliases` require restart or `/model` reload to take effect; document the change.
- Keep edits minimal: touch only the key you intend to change.
