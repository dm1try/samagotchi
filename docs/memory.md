# Memory

Samagotchi stores memories in two scopes:

- Project scope: `~/.config/samagotchi/memories/projects/<name>_<hash>/`, one folder per
  git repository (named and hashed by its root), shared by all its worktrees and
  subdirectories; outside a repository, one per working directory
- System scope: `~/.config/samagotchi/memories`

Tool behavior:

- `memory_read`: `scope` is optional.
- If `scope` is provided (`project` or `system`), only that scope is read.
- If `scope` is omitted, read falls back from project to system.
- `memory_write`: `scope` is required (`project` or `system`). The entry name is passed via the `name` parameter (not `path` — the file tools use `path`). On success, the return value includes the full file path, so you can use the `edit` tool directly for targeted updates.

## Model-Specific Memory Overlays

Each memory entry may have a companion file named `<name>.<model-key>.md` in the same scope directory. When the entry is read under a matching model, the overlay body is appended automatically, separated by the standard `---` separator with a `Model-specific guidance (<key>):` header.

- **Key derivation**: The harness normalizes the full model name (lowercase, replace non-alphanumeric with `-`, squeeze dashes) to derive the file key. For example, `qwen3.6-35b-a3b` → `qwen3-6-35b-a3b`.
- **Saving overlays**: Pass `current_model_only: true` to `memory_write` (the harness resolves the model key automatically). This writes the content as `<name>.<model-key>.md` and skips index maintenance.
- **Dormancy**: Overlays are only active under the matching model key; other models see the base entry only.
- **Invariant**: The base entry is the contract. Overlays only add model-specific guidance and never contradict the base protocol.


At startup, the agent reads both scope indexes with blank-name memory reads
and injects them into the system prompt as `Project memories` and
`System memories`. A memory muted for the session (`chi --mute NAME`) has its
index line dropped there and from a blank-name `memory_read`; reading it by
name answers `Error: memory 'NAME' is muted for this session` (the other
names of a comma list are read). Its file and index line are untouched.

These startup index reads are harness-injected context assembly and are not
rendered as `tool>` activity lines.

## Bundles that need outside commands

A bundle's memory can rely on a command chi doesn't ship, such as a GitHub
protocol that runs `gh` for everything. The bundle's `manifest.yml` says so
with `needs:`. It's advisory: chi installs nothing and checks no versions.
It only looks the command up on `PATH` (no subprocess is run).

```yaml
needs:
  - command: gh
    why: reads PRs, issues and CI status        # optional
    hint: brew install gh && gh auth login     # optional
  - jq                                          # short form: just the command
```

A command is a plain executable name (no path, no spaces); anything else,
or a `needs:` that isn't a list, fails the install. A need applies to the
whole bundle.

Where a missing need shows up:

- `chi bundle install` / `upgrade` (and `--dry-run`) print one line per
  missing command, then install anyway:
  `needs gh: not found on PATH (brew install gh && gh auth login); installed anyway`.
- `chi bundle status <name>` lists every need:
  `needs gh (reads PRs, issues and CI status) [ok]` or
  `needs gh [not found]: brew install gh && gh auth login`.
- In the system prompt, the index line of each of the bundle's memories
  gets `[needs gh: not found on PATH]` when a need is missing (nothing when
  all are found). The check runs whenever the prompt is built: at session
  start, and again after a model or profile switch. A blank-name
  `memory_read` shows the index without the marker.

The two checks can disagree. `chi bundle status` looks at the `PATH` of
the shell it runs in; a worker started by the desktop helper or `chi send`
can have a shorter one (no `/opt/homebrew/bin`, say). The marker in the
prompt is the worker's own check, and it's the one that counts for a
session.

A `PATH` lookup can't tell that `gh` is logged out or broken, so the memory
itself says what to do when its command fails. Put it in the first lines:

```markdown
# gh helper

Needs the `gh` command (GitHub CLI), logged in. If `gh` is missing or not
logged in (a "command not found" or an auth error), tell the user and stop;
don't try to scrape github.com instead.
```
