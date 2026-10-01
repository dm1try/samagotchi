# Memory Guide

This memory teaches you (the agent) how to use Samagotchi memories — persistent MD files that survive across sessions and are injected into your system prompt.

## What memories are

- Plain Markdown files (`*.md`) stored outside the repo so they persist.
- Loaded at startup into your system prompt as **Project memories** and **System memories** indexes (blank-name `memory_read`).
- You manage them via tools (`memory_write`, or `edit` on a memory's file for a small change), not shell file ops. `index.md` is auto-maintained on every write — do not edit it manually.

## Scopes — where files live

| Scope | Path | Use for |
|-------|------|---------|
| `system` | `$XDG_CONFIG_HOME/samagotchi/memories/`, default `~/.config/samagotchi/memories/` (`MemoryPaths.system_dir`) | User-wide preferences, identity, cross-project knowledge |
| `project` | `<system dir>/projects/<basename>_<hash>/` (`MemoryPaths.project_dir`: `basename(root)` + 8-char `MD5(root)`, root = `MemoryPaths.project_root`) | Repo-specific conventions, workflow, stack decisions |

- The project root is the git repository: its common git dir, which every linked worktree shares. All worktrees and subdirectories of one repository share one project folder; the system prompt shows the resolved root and folder. Outside a repository the root is the working directory. A separate clone is a different project.
- `index.md` lives in each scope dir and contains auto-managed lines like `- **name** · scope · date · bytes — description`. Your free-form sections in `index.md` are preserved but managed lines are owned by `memory_write` (and refreshed when `write`/`edit` change a memory's file).

## Tools you have

### `memory_read` — read entries

- `name: "entry"` — project-first fallback: tries `project/<entry>.md`, then `system/<entry>.md`.
- `name: "entry", scope: "system"|"project"` — scoped read.
- `name: "a, b, c"` — comma-separated, concatenated with `\n\n---\n\n`.
- `name: ""` (optionally with `scope`) — reads the index. Empty name with no scope returns both indexes concatenated (`Project memories:` / `System memories:`). Use this at start to discover what exists.
- Returns `Error: memory not found: …` on miss — treat as missing, not fatal.

### `memory_write` — write/update entries

- Parameters: `name: "entry_name"`, `content: "..."`, `scope: "project"|"system"`, optional `description: "one-liner"`, optional `current_model_only: true`.
- `name` is the entry name **without** `.md` (the tool adds it). Use `name`, **not** `path` — `path` belongs to the file tools and is ignored here. `name: "index"` is a verbatim write to `index.md` (no auto-index update) — rarely needed.
- `scope` is **required** — never omit. Prefer `project` for repo conventions, `system` for user preferences.
- `description` is appended to the managed `index.md` line (`— description`). Replaces previous description if given; otherwise preserves existing one.
- For a small change to an existing memory (a step, a line), `edit` its file instead of rewriting it all: the path is in `memory_write`'s result and the scope dirs are in the prompt. Its index line is refreshed either way.
- On success returns `Memory 'name' saved to <scope> scope (N bytes). File written: <path> Index line refreshed automatically.` — confirm `bytes` and `scope`; the index needs nothing from you.

**When to write:**
- After learning a durable preference (e.g. commit style, test command, coding guideline) that the user confirmed or you observed repeatedly — ask before overwriting existing entries where appropriate.
- Keep entries small and focused (one topic per file). Use clear filenames: `commit_preferences`, `testing_guide`, `project_conventions`.
- Never store secrets, tokens, or transient state. Memories are shared via bundles.

**Placeholders:**
- Content may contain placeholder hints written as double-curly braces around a name (e.g., test_command, language). Detected by `Placeholder` (`Placeholder::PLACEHOLDER_RE`) — install warns but does not fail. Fill them when you write. The placeholder syntax is two opening braces, a name, two closing braces.

## Skills

A skill is a memory named `skill_<name>` (`skill_release`, `skill_deploy_staging`) that holds the steps of a repeatable task done with the user. Next time, follow it; when a step turned out different, fix it in the same turn.

Shape (plain Markdown, no frontmatter):

```markdown
# Skill: release

## Steps
1. Run `scripts/verify.sh`; stop if it fails.
2. …
## Gotchas
- …
## Changelog
- 2026-09-29 created
- 2026-09-30 step 1: check.sh was renamed to verify.sh
```

- **When to use it** is the `description:` of `memory_write`: one line starting with the task ("Release a new version of this repo: verify, tag, push"). It is what the index shows, so it is how you find the skill later.
- **Scope**: `project` by default; `system` when the user asks, or when the skill is clearly not about this project.
- **Saving**: on a request to keep how something was done ("let's memorize this", "save this as a skill", `/skill save`), write it at once, then show it briefly. On an ambiguous one ("I like how we did that") you may ask whether to save it.
- **Following**: before a task a `skill_*` index line matches, `memory_read` it and follow its steps. A step that fails or names a missing file or command: find out why (look around, read nearby READMEs) before skipping it; a step that says stop means stop and ask. When anything looks unexpected (a check fails, output differs from what a step says, a warning the skill doesn't mention): stop, don't improvise a fix, tell the user what you saw and ask. Read each command's whole output, including warnings, before the next step.
- **Updating**: when a step turned out different, update the skill in the same turn: `edit` those steps in its file (`<scope dir>/skill_<name>.md`), or rewrite it with `memory_write`; keep the rest as it was, add a dated Changelog line. No confirmation needed.
- **The `skills` bundle** (`chi bundle install skills`, optional) adds `/skill save [name] [--system]`, `/skill list`, `/skill show <name>`, `/skill diff <name> [N]`; it keeps older versions and shows a short diff line after each update.

## Memory Bundles — shareable packs

Bundles are versioned directories/zips/tar.gz/git URLs with a `manifest.yml` and any of: memories (`*.md`), `hooks/*.rb` (bundle hooks, `docs/hooks.md`), `guardrails/*.yml` (rules, `docs/guardrails.md`), a `plugin.rb` (commands, tools, hooks, services; `docs/plugins.md`). They are shareable and installable.

- Manifest: `files:` (memory → `sha256:`), `hooks:` (file → sha256/event/on_error/priority), `plugin: {file: plugin.rb, sha256: sha256:…}`, `requires_chi: ">= 0.1.30"` (gem-style), `needs:` (outside commands looked up on `PATH`, advisory; `docs/memory.md` "Bundles that need outside commands").
- Integrity: each file's sha256 is recorded at install; a hook/plugin/rule file changed afterwards is not loaded (rules: every call denied) until reinstalled. It is an integrity check, not proof of authorship.
- Installing = trusting its Ruby code (hooks, plugin), like a gem. Install only copies; the code runs at the next session start (`Engine.new`), so a running worker needs a restart to pick it up.
- A bundle without `*.md` (btw, mcp, loop-guard) adds no line to the prompt's memory index.
- Profiles are shipped bundles with only `includes:` (bundle names): `core` (loop-guard, check-in, guardrails; `chi bootstrap` installs it) and `dev` (known-names, mcp, btw, skills, source-links). `chi bundle install core` installs the ones not installed and records them; a bundle the user uninstalled stays out on a later install, upgrade or `chi update`, which install only bundles new to the profile. `chi bundle uninstall core` removes its recorded bundles, then core (`docs/memory.md` "Bundle profiles").

### CLI — `chi bundle`

| Command | Purpose |
|---------|---------|
| `install <source> [--scope system\|project] [--force]` | Install from dir/zip/tar.gz/git URL. `--force` overwrites existing entries, otherwise skips. Writes provenance to `.bundles/<name>/` (base snapshots + `manifest.json`) and updates `index.md`. Warns on double-brace placeholders and checksum mismatches (strict mode). |
| `upgrade <source> [--force] [--dry-run] [--agent]` | 3-way merge upgrade (base vs current vs incoming) per `Merger.classify`: `install` (new file), `noop` (current==incoming), `fast_forward` (current==base, not edited → auto-update), `keep` (incoming==base → preserve local edits), `conflict` (both edited → warn, needs `--force` or interactive `memory_write` resolution). Pruned files (removed from new bundle) are kept if locally edited, otherwise warned. |
| `uninstall <bundle> [--force]` | Removes bundle files (skips locally edited files unless `--force`) and `index.md` lines, deletes provenance dir. |
| `status [<bundle>]` | Provenance + per-file `ok|modified|missing|no-index` vs stored checksum and base snapshot. |
| `diff <bundle> [file]` | Prints `base` (provenance snapshot) vs `current` (on-disk) for each file. |
| `list` | Lists installed bundles (`name v<version> scope files installed_at`, plus the shipped version when newer) and the bundles shipped with chi that are not installed (`install <name>` installs one), grouped under their profile; an installed profile shows `includes=` and `left out=`. |
| `build [--scope system\|project] [--name NAME] [--version VER] [--description DESC] [--out PATH] [FILES...]` | **Inverse of install** — builds a shareable bundle from local memories and installed hooks. Infers `zip` vs `dir`/`tar.gz` from `--out` extension; default `chi_system_memories.zip` (system) or `chi_<repo>_memories.zip` (project, named after the project root) v`1.0.0` in `Dir.pwd`. `FILES...` is an optional allowlist of memory basenames (`identity` or `identity.md`); if omitted, all `*.md` except `index.md`/hidden/non-md are included. Installed hooks are copied to `hooks/` with their manifest metadata. Computes `sha256:` checksums and writes `manifest.yml` via `Manifest.write`. No provenance write. |

**Scope resolution for install/build:**
- CLI `--scope` wins over `manifest.yml` `scope`. Default is `system` if none given (`Installer#run`). For `project`, target is the project folder `<system dir>/projects/<basename>_<hash>` of the project root (`Installer#resolve_target_dir`).

**Example flows:**
```bash
# export your system memories (all files) to zip
chi bundle build --scope system --out my-prefs.zip

# export just two entries, custom name/version, to dir
chi bundle build --scope system --name my-bundle --version 1.2.0 --out ./my-bundle/ identity.md commit_preferences.md

# install a bundle shared by a teammate
chi bundle install ./my-bundle --scope system
chi bundle install https://github.com/org/bundle.git#v1.2.0 --scope system --force

# check what would change and upgrade
chi bundle upgrade ./my-bundle --dry-run
chi bundle upgrade ./my-bundle  # auto-merges, warns on conflicts

# share again after editing
chi bundle build --scope system --out updated.zip
```

### Provenance internals (for debugging)

- Each installed bundle is recorded at `<system dir>/.bundles/<name>/manifest.json` + `bases/<file>.md` snapshots (`Provenance`). Used only for upgrade `Merger` and `status`/`diff`. Build does **not** write provenance.
- `index.md` is best-effort — failures are swallowed (`Installer#update_target_index`).

## Best practices for the agent

1. **Discover first:** read the index (`memory_read ""`) before assuming entries exist. Prefer scoped reads when you know the scope.
2. **Prefer project scope** for repo decisions; `system` for cross-project identity/preferences.
3. **One concept per file:** small files merge and share better than monoliths.
4. **Use bundles for sharing:** `build` → zip → share → `install`. Do not copy raw `~/.config` paths in docs — give `chi bundle install <url>` instructions.
5. **Respect local edits:** installs skip existing files by default; use `--force` only when the user explicitly wants overwrite. Upgrades preserve edits (`keep`) or report `conflict` — guide the user to resolve via `memory_read`/`memory_write` or `chi bundle diff <bundle>` + `--force`.
6. **Keep secrets out:** never write tokens/keys to memories — they are plain files and go into bundles.

## Current system bundle

`samagotchi-system` (`lib/samagotchi/bundles/system/manifest.yml`) ships `identity.md` + `self_map.md` + `config_modification_protocol.md` + `delegated.md` + this guide itself. It is auto-installed/upgraded on first `Engine` creation (`SystemBundle.ensure!`) — no manual install needed. Its files are managed by chi: a newer chi upgrades them (a 3-way merge keeps local edits and reports conflicts), so put your own preferences in separate memories rather than editing these.
