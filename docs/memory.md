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

## Skills

A **skill** is a memory named `skill_<name>` that holds the steps of a
repeatable task you and chi did together: a release, a deploy, a data fix.
chi is told about skills by the system bundle (`identity.md`, every turn, and
`memory_guide.md`), so this works without installing anything:

- **Saving.** Say "let's memorize this" or "save this as a skill" after the
  task, and chi writes the skill with `memory_write` (project scope; system
  when you ask, or when it isn't about this project) and shows it. On a vague
  one ("I like how we did that") it may ask first.
- **Following.** The skill's index line (the `description:` of its
  `memory_write`, "Release a new version of this repo: …") is in every
  prompt, so next time chi reads the skill and follows it. When something
  looks unexpected on the way (a failing check, a warning the skill doesn't
  mention), chi stops, says what it saw and asks how to go on.
- **Updating.** When a step turned out different (a renamed script, an extra
  step), chi fixes the skill in the same turn: those steps changed, the rest
  kept, a dated Changelog line added. No confirmation.

A skill is plain Markdown, no frontmatter:

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

It is a memory like any other: `memory_read`, `chi --mute skill_release`,
`chi bundle build` share it. The optional `skills` bundle (`chi bundle install
skills`, [docs/plugins.md](plugins.md#the-skills-bundle)) adds `/skill save`,
`/skill list`, `/skill show`, `/skill diff`, keeps older versions with a
one-line diff after each update, and nudges a model that skips a failing
step instead of fixing the skill.

## Bundle profiles: core and dev

Every bundle chi ships (the system bundle aside) belongs to one of two
profiles, meta bundles that install a set of them:

| profile | bundles |
|---|---|
| `core` | loop-guard, check-in, guardrails: the recommended safety set |
| `dev` | known-names, mcp, btw, skills, source-links |

`chi bootstrap` installs `core` and, on a terminal, offers `dev`. An existing
install gets neither by itself: `chi bundle install core` (or `dev`).

A profile's `manifest.yml` has `includes:` (bundle names) and nothing else to
install; its dir holds only that file. What installing it does follows one
rule:

    installed now = the profile's bundles − the ones it recorded − the ones installed

- **First install:** each bundle that isn't installed is installed (from the
  bundles chi ships, never a same-named dir in the cwd); one you installed by
  hand is recorded without reinstalling it.
- **Again, or `chi bundle upgrade core`:** only a bundle new to the profile
  is installed. One you uninstalled (`chi bundle uninstall check-in`) was
  recorded, so it stays out; re-running `chi bootstrap` changes nothing.
- **A new chi adds a bundle to a profile:** `chi update` installs just that
  one ("core … updated (+ name)"). A bundle dropped from a profile stays
  installed.
- **A bundle this chi is too old for** (its `requires_chi`) is skipped with a
  note, and one that fails is reported (exit 1); neither is recorded, so the
  next `chi update` or install tries again.
- The profile never pins its bundles' versions: each one upgrades on its own,
  as before (`chi update`, `chi bundle upgrade NAME`).
- Only the profiles chi ships expand: `includes:` in a bundle from anywhere
  else is ignored.

`chi bundle uninstall core` uninstalls each bundle it recorded that is still
installed (one you installed by hand before core too), then core. A bundle
with an edited memory file is kept and named (`--force` removes it), the
rest go, and core stays until it is gone (exit 1). `--scope project` is
refused for a profile. `chi bundle list` shows an installed profile's
bundles (`includes=`) and the ones you left out (`left out=`), a profile not
installed with its bundles on its line, and `chi bundle status core` lists
each one.

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
