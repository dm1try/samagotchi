# Memory

Samagotchi stores memories in two scopes:

- Project scope: `$XDG_CONFIG_HOME/samagotchi/memories/projects/<name>_<hash>/`, one folder per
  git repository (named and hashed by its root), shared by all its worktrees and
  subdirectories; outside a repository, one per working directory
- System scope: `$XDG_CONFIG_HOME/samagotchi/memories`

`$XDG_CONFIG_HOME` falls back to `~/.config` when unset.

Tool behavior:

- `memory_read`: `scope` is optional.
- If `scope` is provided (`project` or `system`), only that scope is read.
- If `scope` is omitted, read falls back from project to system.
- `memory_write`: `scope` is required (`project` or `system`). The entry name is passed via the `name` parameter (not `path` — the file tools use `path`). On success, the return value includes the full file path. For a small change to an existing memory (a step, a line) the model is told to `edit` that file rather than rewrite it all with `memory_write`.
- `memory_write`'s `description` is the managed `index.md` line's text: one line (whitespace and newlines collapse to single spaces), at most 200 characters (longer is refused, since every session's prompt for the repo carries it). A missing or blank one keeps the line's description.
- `memory_write` with `name`, `scope` and `description` but no `content` changes only that entry's index line (its size and date are refreshed; the date becomes today) and leaves the file as it is: a skill that keeps its status in a memory's description changes it without resending the body. The memory must exist in that scope; the form is refused for `index` and with `current_model_only`.
- `memory_write` with `name`, `scope` and `remove: true` (no content, description or `current_model_only`) removes a memory: its file and its model overlays (`<name>.<key>.md`, not a dotted memory with an index line of its own) move into one dir of the bundle trash, `memory-<name>-<time>` under `memories/.bundles/.trash/`, which `chi bundle trash` lists and empties, and its index line is dropped. When the file is already gone (deleted by hand), the dangling line is dropped alone. A memory a bundle owns (an installed bundle's record lists it, or its line says `· from <bundle>`) is refused: `chi bundle uninstall` removes it. `index` can't be removed. The guardrails bundle's `memory-remove` rule asks before every removal, once at a time (see [Guardrails](guardrails.md#the-guardrails-bundle)).
- `write`/`edit` that change a `*.md` right in a scope dir refresh its managed `index.md` line (date, bytes; the description is kept), as `memory_write` does. A memory created with `write` gets a line with no description; any other `.md` written there gets a line too. Model overlays (`<name>.<key>.md` next to `<name>.md`), files in another project's folder and files changed by `execute` are left out.

## Model-Specific Memory Overlays

Each memory entry may have a companion file named `<name>.<model-key>.md` in the same scope directory. When the entry is read under a matching model, the overlay body is appended automatically, separated by the standard `---` separator with a `Model-specific guidance (<key>):` header.

- **Key derivation**: The harness normalizes the model name sent to the server, without its host prefix (`box:qwen3.6-35b-a3b` keys as `qwen3.6-35b-a3b`; an alias keys as its target, and the alias's own key is read when the target has no overlay) (lowercase, replace non-alphanumeric with `-`, squeeze dashes) to derive the file key. For example, `qwen3.6-35b-a3b` → `qwen3-6-35b-a3b`.
- **Saving overlays**: Pass `current_model_only: true` to `memory_write` (the harness resolves the model key automatically). This writes the content as `<name>.<model-key>.md` and skips index maintenance. The guardrails bundle asks before a model writes one (`model-overlay-write`). Habits of a model in general go in a [model note](#model-notes), which can name a family or all small models.
- **Which key is mine**: the system prompt's `Model:` line names the session's model key, and `chi self` (via `execute`) has a `model key` row; both follow `/model`.
- **In the system prompt**: the identity memory and the preloaded memories (`--memory`, config `memories:`) get their overlays too, as `memory_read` gives them; after `/model` the rebuilt prompt carries the new model's.
- **Dormancy**: Overlays are only active under the matching model key; other models see the base entry only.
- **Invariant**: The base entry is the contract. Overlays only add model-specific guidance and never contradict the base protocol.
- **In a bundle**: ship `<name>.<key>.md` next to `<name>.md` (ship the base too; an overlay with no base anywhere installs with a warning and loads only once the base exists; one whose base is only among your installed memories is taken as an overlay of it, with a warning naming it). The overlay gets no `index.md` line, so other models don't see it, and `chi bundle status` reads it `ok (model overlay)`; `chi bundle build FILES...` brings a named memory's overlays along.
  - The key is the `model key` row of `chi self` under that model. It follows the provider's model id: OpenRouter's `deepseek/deepseek-v4.1-flash` keys as `deepseek-deepseek-v4-1-flash`, while a local server names the same model differently, so one model may need one overlay per provider.
  - Key an alias by its **target**, not the alias: the alias's own key is read only as a fallback, when the alias was typed and the target has no overlay.
  - The overlay is read in the scope its base is found in: a project memory with the same name shadows a system-scope bundle's base and overlay.


## Model notes

A **model note** is a memory named `model_notes_<name>` whose first line says
which models it is for. It goes into the system prompt of every session on a
matching model, so it is where a model's own habits go ("explore briefly, then
act"), independent of the identity memory:

```markdown
models: deepseek-*|*deepseek-v4*
Working habits for this model:
- Explore briefly, then act.
```

- **`models:`**: `|`-separated entries, each `small` (a small model per
  `guardrails.small_models`, see [Guardrails](guardrails.md)) or a glob
  (case-insensitive, `*`, `?`, `{a,b}`) on the model id sent to the server
  (no host prefix) or on its model key. Any entry matching loads the note. The
  grammar is the guardrails rules' `models:`.
- **Stacked**: every matching note loads, the system scope's first, then the
  project's, by name within a scope. Notes add habits; none overrides another.
- **In the prompt**: their own section right after the identity memory,
  `Model notes (for <model>, scope=…):`, each note under its name, the
  `models:` line left out. A note's index line is left out of the prompt's
  memory indexes (its body is already there, or it isn't for this model); the
  tools still see it.
- **Overlays**: a note is read like any memory, so its own
  `model_notes_<name>.<key>.md` overlay is appended.
- **Muting**: `chi --mute model_notes_<name>` drops one for a session. Muting
  `identity` no longer drops a model note.
- **Names**: no dot after `model_notes_` (`memory_write` refuses one: next to a
  note of the stem's name it would read as a model overlay); a dotted file
  made by hand is skipped with a warning. No memory name takes a comma
  (`memory_read` reads a comma list of names).
- **The `models:` line**: `memory_write` refuses a `model_notes_` memory whose
  first line isn't one (`models:`, any case, with at least one entry). A file
  made by hand without one is skipped with a warning (once, in the debug log)
  naming the file, and keeps its index line in the prompt.
- **Asked first**: with the guardrails bundle, a model's write of a memory that
  reaches the system prompt (identity, a model note, or an overlay of either)
  with `memory_write`, `write` or `edit`, through a symlink or in any case of
  the name, asks the user, once at a time (`prompt-memory-write`); so does a
  model overlay of any memory (`model-overlay-write`). Only the user may allow
  either, not a parent session. The prompt's `Model:` line tells the model that
  guidance for it goes in a model note.
- **Exact prefix**: only files named `model_notes_…` as written load; a
  `MODEL_NOTES_x.md` (which a case-insensitive disk's listing also returns)
  doesn't.
- **Size**: they cost every request. A note over 1,500 characters, or all of a
  model's notes over 3,000, still loads but warns once.
- **Timing**: a note takes effect at the next prompt build: a session's start,
  a resume, a web worker waking, `/model`. A note written mid-session doesn't
  change the running prompt.
- **Recorded and shown**: each prompt build writes the notes it carried to the
  session file (`prompt_notes`: name, scope, size in characters and a short
  digest of the text), so a session says later what it ran with; `/model`
  switches record the new model's. `/stats` has a
  `model notes:      model_notes_deepseek (system, 612 chars)` line, `/model`
  ends its model line with `; notes: …` (after a switch, the new model's), the
  web's info bar a `notes: deepseek` chip (the full line in its tooltip), and
  `chi self` a `model notes` row after `model key`: the notes a prompt of the
  reported model loads now, the session's `--mute` list left out when it runs
  in one, `none` without any. None of the others shows a line without notes.
  A resumed session, or a web worker that woke, shows the saved ones until its
  first turn builds the prompt again.
- **Judged**: `ruby script/model_notes_report.rb` (a development script, not
  shipped) groups stored sessions by model and recorded notes and compares the
  calls to the first edit and commit, commits per 100 steps, bare `&`, the
  longest run without an edit and the Continues and steers each needed; run a
  note on and muted for the same kind of task. See
  [testing.md](testing.md) ("The model notes report").
- Without a model note the system prompt is what it was.


At startup, the agent reads both scope indexes with blank-name memory reads
and injects them into the system prompt as `Project memories` and
`System memories`. A memory muted for the session (`chi --mute NAME`) has its
index line dropped there and from a blank-name `memory_read`; reading it by
name answers `Error: memory 'NAME' is muted for this session` (the other
names of a comma list are read). Its file and index line are untouched.

These startup index reads are harness-injected context assembly and are not
rendered as `tool>` activity lines.

### The index's size

Both indexes go into every prompt in full (a model note's line and a muted
memory's line are left out), so their size is paid on every request. Nothing caps
or trims them; chi measures them (tokens estimated as characters /
`context.chars_per_token`) and shows the size:

- `chi self` has a `memory index` row:
  `system ~2.0k tokens (54 lines), project ~1.4k tokens (35 lines)`, with
  `, over 2500` inside the parentheses for a scope over
  `memory.index_warn_tokens`.
- `/stats` has `memory index:     ~3.4k tokens in this session's prompt (system 2.0k, project 1.4k)`,
  and the web's ctx tooltip (info bar and session card) the same line. It is
  what this session's prompt holds, measured when the prompt was built (after
  the session's mutes): a memory written during the session changes neither
  the running prompt nor this figure until the prompt is built again (a
  resume, a woken worker, `/model`).

`memory.index_warn_tokens` (default `2500`, per scope; `0` turns it off) is
the size a write may take an index to before the model is told. When a
`memory_write` (with content, or a description-only one) or a `write`/`edit` on
a memory file refreshes an index line and takes its scope's index from at or
under the limit to over it, the tool result ends with one note:

> Note: the project memory index is now ~2510 tokens (over memory.index_warn_tokens 2500) and is sent with every prompt. When you next have a moment, tighten long index descriptions (memory_write with name, scope and description only). Don't remove or merge memories unless the user asks.

The note comes once per crossing: a write while the index is already over gets
none (the tightening it asks for doesn't start a loop), nor does a remove, a
model overlay or the verbatim `index` write. Sessions sharing a project's folder
measure on their own, so writes in parallel sessions that race over the limit
may each get it. Bundle installs and uninstalls and hand edits
change index lines without a note; `chi self`'s row shows where an index
stands.

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
  step), chi fixes the skill in the same turn: those steps changed (with `edit`
  on its file, so a small fix doesn't resend the whole skill), the rest kept, a
  dated Changelog line added. No confirmation.

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

## What a bundle owns

A bundle owns the memory files it wrote, nothing else. `chi bundle install`
copies each of its `*.md` files into the scope dir; a file of the same name
that is already there is left as it is and reported `Skipped` (`--force`
overwrites it, and then the bundle owns it). A skipped file stays yours: the
bundle doesn't record it, so `chi bundle upgrade` never merges into it and
`chi bundle uninstall` never removes it. That holds for a file the user wrote,
for `chi bundle build` then installing the result on the same machine, and
for a file another bundle installed.

- **The index says where a memory came from.** The `index.md` line of a file
  a bundle installed ends in `· from <bundle>`, before the description:
  `- **memory_guide** · system · 2026-10-03 · 5120 · from samagotchi-system —
  …`. `memory_write`, `write` and `edit` keep it. A bundle installed by chi
  0.16 or earlier gets it on its next install or upgrade.
- **A bundle can give a memory its index description.** A `files:` entry
  may be a mapping instead of a sha line:

  ```yaml
  files:
    identity.md: sha256:…
    skill_coordinator.md:
      sha256: sha256:…
      description: "Coordinate parallel work: …"
  ```

  The install writes that description into the memory's `index.md` line
  (after `— `), so the model can tell what a shipped skill is for from the
  index alone. The bundle's record keeps it, `chi bundle build` writes the
  mapping back, and `rake bundles:sha` refreshes the nested sha. A file
  with a plain sha line keeps the description its line already has.
- **Uninstall moves, it doesn't delete.** The bundle's memory files go to
  `$XDG_CONFIG_HOME/samagotchi/memories/.bundles/.trash/<bundle>-<YYYYmmdd-HHMMSS>/`,
  and the output names them and the dir:
  `Moved to the trash: notes.md (…/.trash/team-notes-20261003-120000)`. So
  does an upgrade's removal of a file the new version no longer ships. A
  file you edited still needs `--force`. `chi bundle trash` lists the trash
  (oldest first, with file count, size, and age); `--empty` deletes all
  folders, `--older-than DAYS` keeps only recent ones, and `--dry-run`
  previews. Hooks, rules and the plugin live in the bundle's own dir and
  are deleted with it.
- **A file two bundles list stays** until the last of them is uninstalled
  (`Kept identity.md: bundle samagotchi-system has it too`); its index line
  then names the bundle that still has it.
- **Installs by chi 0.16 or earlier** recorded skipped files too. Such a bundle may
  still list a file that was yours; uninstalling it moves that file to the
  trash rather than deleting it, so check the `Moved to the trash` line and
  move a file back if it was yours (and its line in `index.md` comes back
  with the next `memory_write`, `write` or `edit` of it).
- **`chi bundle build`** packs your memories, not other bundles': a memory an
  installed bundle owns is left out with a line (`Left out identity.md:
  installed by bundle samagotchi-system (name it to include it)`); naming it
  in `FILES...` includes it.

## Bundle profiles: core and dev

Every bundle chi ships (the system bundle aside) belongs to one of two
profiles, meta bundles that install a set of them:

| profile | bundles |
|---|---|
| `core` | loop-guard, check-in, guardrails: the recommended safety set |
| `dev` | known-names, mcp, btw, skills, source-links, github-pr, coordinator |

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
