# Memory bundles: install, upgrade and build

How `lib/samagotchi/memory_bundle/` turns a bundle (a dir, git URL, zip or tar holding `manifest.yml`, `*.md`
memories and optional `hooks/`, `guardrails/`, a plugin file and `scripts/`) into installed state, and back. The
user-facing side (what a bundle owns, profiles, needs) is in [memory.md](../memory.md#what-a-bundle-owns) and
[plugins.md](../plugins.md) and [bundles.md](../bundles.md).

## Where things live

```
<scope memories dir>/            MemoryPaths.scope_dir: system ~/.config/samagotchi/memories,
                                 project <system>/projects/<project key>
  *.md, index.md                 the bundle's memories, one managed index line each ("· from <bundle>")
<system memories>/.bundles/      MemoryPaths.bundles_dir
  <name>/manifest.json           the install record (Provenance#write, read as InstalledBundle)
  <name>/bases/                  each file as installed: the base of the next upgrade's 3-way merge
  <name>/hooks/ guardrails/ plugin/ scripts/
  .trash/<name>-<stamp>/         files an uninstall or upgrade took away, and copies of what an install
                                 overwrote (Trash), never deleted
```

## Components

| Piece | Role |
|---|---|
| `BundleCommand` (`lib/samagotchi/bundle_command.rb`) | `chi bundle install/upgrade/uninstall/status/diff/list/build/trash/new/test/check/try` (`install --dev`: the Installer's `dev:`, links and `Provenance::DEV_SHA`); runs the Installer, prints its summary, runs the conflict agent step; refuses a source already installed under another name (`installed_under_another_name?`: a git URL bundle recorded under its repo's name before the manifest named it) |
| `BundleCommand::Check` (bundle_command/check.rb) | `chi bundle check [PATH] [--fix] [--set K=V]`: a bundle being written, checked as an install takes it (docs/cli.md lists the codes); parses the manifest from `Shas.parseable` (a placeholder sha is a `sha` finding, not a YAML error), reads the user's installed bundles only for `clash`, and installs and loads through `Testing::Install` in a `Testing::Sandbox` with `force: true`, the log's echoes swallowed |
| `BundleCommand::Try` (`bundle_command/try/`) | `chi bundle try PATH -p TEXT`: `Command` (its flags, help and checks) drives the rest and `Render` prints the trace; a filtered-config `Sandbox` (its folders a `SandboxLayout`, the layout `Testing::Sandbox` uses too) installs the tried bundle and shipped `guardrails` / `cost-cap` in a separate child, then `Run` starts one non-interactive chi process from its realpath work dir; `TraceReader` reads that session's analytics, cards (`Bridge::CardStore.saved`, as the web does) and session JSON by id (never `Session.list`), joining timing and tool args for text or experimental JSON output (a turn a `--timeout` interrupt cut keeps its calls like a Ctrl-C, the one cut short answered as interrupted, so its rows come from the saved calls too; `Run::Result#timed_out` becomes `timed_out`). `Sandbox#child_env` is a Hash, never an ENV mutation; it keeps ordinary user model settings and Keychain access while dropping the spawner's session/guardrail/worker markers (`ChildEnv`, the scrub a session's worker spawn uses too). The child runs in its own process group: a `--timeout` sends it INT, then `ProcessGroup.stop` (the groups its processes started too); after any exit the group is signalled only while a straggler is still in it, never a reaped group. `Sandbox#stop_leftovers` (before the trace, and in `cleanup`) stops what left the child's tree, found by the sandbox's own records: a delegate's worker by its session's `owner.lock`, a task by its running `task.json` whose pid still leads its group. |
| `BundleCommand::ApiCalls` (bundle_command/api_calls.rb) | what a plugin's source calls of the API, by Prism: `#findings` (a call or keyword the API's classes lack, `check`'s `api`), `#keywords` (the floor check's `call(keyword:)`). Its only list is `MEMBERS`, which object a member gives (`ctx.sessions` → `Plugin::Sessions`); a new such object joins it |
| `BundleCommand::Scaffold` (bundle_command/scaffold.rb) | `chi bundle new NAME`: the starting files (block-form `plugin:` entry, `requires_chi` at this chi, a kit test that passes as written); the manifest's shas are filled through `Shas.refresh` |
| `BundleCommand::TestRun` (bundle_command/test_run.rb) | `chi bundle test`: `RbConfig.ruby -I <chi's lib>` on `test/**/*_test.rb` (Minitest) or `spec/` (RSpec, as `rake bundles:specs`), under `Bundler.with_unbundled_env` when Bundler's runtime is loaded |
| `Shas` (shas.rb) | a manifest's `sha256:` lines: `.refresh(dir[, text])` rewrites them line by line (the layout kept; a `files:` entry it can't place raises `Shas::Error`), `.stale` → `[Stale(file, old, new)]` (`old` `""` for a placeholder, nil for a plugin / hook / script entry with no sha line), `.parseable` (a placeholder `sha256: sha256:` isn't YAML). Plain Ruby: `rake bundles:sha` / `bundles:check` (`script/release/release_tools.rb`) and `chi bundle check --fix` share it |
| `SourceNormalizer` (source.rb) | source → local dir; a git/zip/tar extract is *owned* and removed after the install |
| `SourceIdentity` (source.rb) | what a source is, for comparing two installs of one name: `shipped:<dir>` (any gem or checkout), `git:<url>` (no `#ref`, trailing `/` or `.git`), `path:<realpath>`; nil when it can't place one |
| `PreparedSource` (source.rb) | one source normalized once (dir, owned, git commit): `BundleCommand` reads the bundle's name from its `manifest.yml` (the name for every kind of source, a git URL too) and hands it to the Installer (`prepared:`), so a source is cloned or extracted once per command |
| `MemoryFiles` | which top-level `*.md` files of a bundle are its memories (`.select`: the `files:` list, else all but README/LICENSE and the like), `.unshipped` (listed, not shipped) and `.symlinks` (skipped: a symlink is never a memory) |
| `Manifest` | parses/validates `manifest.yml` (`name:` is the bundle's name and a directory under `.bundles/`, so a path such as `../x`, `a/b`, `.` or `..` is refused: `name: … is not a bundle name`; YAML that doesn't parse or isn't a mapping is a `ValidationError` too; files, hooks as `BundleHook`, plugin, scripts, needs, requires_chi, includes, context_providers, session_settings: the keys a session's `chi --set` may give, a list or a mapping of them to types (`SESSION_SETTING_TYPES`), recorded at install in `manifest.json` (`session_settings`, `session_setting_types`) for `SessionConfig` to check; settings: the keys config.yml's `bundles: <name>:` may have, the same shape, recorded as `settings` (nil when the manifest has none) and `setting_types` for `BundleSettingsCheck`, whose warnings the Engine holds for the first turn and `SessionConfig`'s refusals share the words of) and writes it (`Manifest.write`, for Builder). It ignores `requires_chi_next`, a shipped bundle's release-time marker (`script/release/release_tools.rb`, docs/releasing.md) |
| `Installer` | one install/upgrade/dry run of one bundle (below) |
| `AssetInstaller` | the parts that live in `.bundles/<name>/`: hooks, guardrail rules, plugin, scripts; returns `AssetInstaller::Installed` (the paths the record keeps). A file it replaces or removes whose bytes are neither the recorded sha nor the incoming file's is copied to the Installer's `Trash` first (`#save_edit`, as `hooks/x`, `guardrails/x`, `plugin/x`, `scripts/x`; no sha recorded counts as edited; a dev link never is) |
| `Merger` | 3-way classification per file: `install`, `fast_forward`, `keep`, `noop`, `conflict`; `.markers?` (a file holding a merge's `<<<<<<<`/`>>>>>>>` lines; `=======` alone is a Markdown underline) |
| `Provenance` | the `.bundles/<name>/` dir: `#write` the record + bases, `#record` → `InstalledBundle`, `.each_installed`, `.claimants` (which bundles own a file) |
| `InstalledBundle`, `BundleHook`, `PluginRef` | value objects for the record; tolerant of older records (missing keys read as empty). `BundleHook#events` is the manifest's `event:` or its `events:` list (written back as `event:` for one, as an older chi reads it); `Hooks::BundleLoader#load_hook_file` builds the hook once and registers it under each |
| `Builder` | `chi bundle build`: memories (+ the installed bundle's hooks, rules, plugin, scripts) → zip/tar/dir |
| `Profile` | meta bundles (`includes:`): install the members, record which; `InstallResult#kept_own` names a new member's memory files the user already had, with other bytes (`kept_own_line`, printed by `chi bundle`, `chi update` and `chi bootstrap`); a dry run runs each member's Installer as a dry run too, so it names them as well |
| `SystemBundle`, `ShippedUpdate` | the built-in system bundle (`ensure!` at Engine start, `sync` in `chi update`) and `chi update`'s upgrade of shipped bundles; both drive the Installer with `upgrade: true`. `ShippedUpdate.external` is the rest: what `chi update` only checks |
| `InstalledCopy`, `BundleCommand::InstalledCheck` | `chi update`'s re-check of the bundles chi didn't ship ([docs/cli.md](../cli.md#updating)). `InstalledCopy` lays a record and its installed files out as a source folder (manifest.yml from `Manifest.write`, the files' own shas, memories from `bases/`); `InstalledCheck` forks per bundle (a plugin's `exit` or hang is that bundle's row; stdio to /dev/null, so `--json` stays parseable; `TIMEOUT`, then KILL of its group) and runs `Check.new(dir, installed: true)` there, which leaves out what only suits a source tree. Its `boundary` finding is narrower there than in a source tree: `Testing::Boundary.gone?` calls a reference gone only when its constant doesn't resolve or the object has no method the name names, so a bundle reaching `Samagotchi::Log` gets no row. lib loads lazily, so when a name doesn't resolve `gone?` requires every file of this chi's library in that same child and asks again (about 0.2 s, only for a bundle that reaches into chi at all); anything it can't read — a `const_get`, a require of a file that is there — is taken as still there. The fork is the point: `Sandbox` swaps ENV and the plugin's code is arbitrary. `UpdateCommand#external_rows` makes the rows (`level`, never `failed`) and holds the check back while a newer gem is yet to take over (`@not_checked`), since a fork is this chi's code |
| `Uninstaller`, `Trash`, `Status`, `Listing` | remove; keep removed files (`Trash#move`) and a copy of overwritten ones (`Trash#copy`, its `as:` keeping a subfolder); `chi bundle status`; `chi bundle list` |
| `IndexUpdater`, `IndexSync` | the managed `index.md` lines (Installer; and the write/edit tools for memories) |
| `EntrySize` | one memory's size in tokens: `memory.entry_warn_tokens`' crossing note after a memory write, `chi self`'s `big memories` row |
| `IndexSize` | one scope's memory index as the prompt carries it (tokens, lines, bytes): `memory.index_warn_tokens`' crossing note after a memory write, `chi self`'s summary, the prompt's figures (`SystemPrompt`) |
| `Placeholder` | `{{placeholder}}` patterns left in an installed memory, one line per file from `Installer#detect_placeholders`; a hint, never a gate |

A dev install (`chi bundle install --dev PATH`, `Installer#initialize(dev: true)`) links instead of copying:
`AssetInstaller#place` symlinks each hook, rule file, plugin and script into `.bundles/<name>/` to its realpath in
the source (memories are still copied: their bases and the index are the install's), and the record gets `"dev": true`
(`InstalledBundle#dev`, `source` the realpath) with `Provenance::DEV_SHA` (`sha256:dev`, never a hex digest) in
place of every hook, rule, plugin and script sha256. `Provenance.sha_matches?` / `.unchecked?` read it as "not
checked", which is how the readers below skip it for that bundle only. `Installer#refuse_dev_mismatch` keeps a dev
and a normal install from replacing each other (this is also why `chi bundle upgrade` refuses a dev bundle);
`Uninstaller` removes links with `rm_rf`/`rm_f`, which never follow them into the source.

Readers of the installed state: `Hooks::BundleLoader` (Engine), `GuardrailWiring#bundle_rules`, `Plugin::Loader`,
`ContextProviders` (scripts), `BundleNeeds` (index markers). Each goes through `Provenance.each_installed` / `#record`
and checks the recorded sha256 (and `requires_chi`) before loading.
The checks live in `Hooks::BundleLoader.load` and `Plugin::Loader.load_bundle`; the loading itself is
`BundleLoader.load_hook_file` (one hook file, into a given `namespace:`) and `Plugin::Loader.register_file` (one
plugin file: build, `register`, `commit!`), which raise instead of logging: the bundle test kit
(`Samagotchi::Testing::Bundle`) loads a bundle's source through them, unchecked. `Samagotchi::Testing::Install` is the
checked path in a sandbox: the Installer, then `ExtensionLoad` (bundle hooks, then `load_plugins`), returning the
Installer's warnings, this bundle's load failures and what it registered (`Install.registered`, an `Install::Registered` value, also the parity
spec's shape). A load failure carries `LoadFailures::Failure#location` (the first backtrace frame inside the
bundle, or a SyntaxError's own line), which `Install` maps from the installed copy (`.bundles/<name>/plugin/`,
`hooks/`) back to the source dir.

## Installer#run, in order

The order matters: warnings print in it, and a plugin/script the manifest names but the bundle lacks raises
`InstallError` after the memories are already copied.

1. `load_source`: normalize (or take the `PreparedSource` `BundleCommand` passed as `prepared:`), read `manifest.yml` (strict: a missing/invalid one raises; non-strict: a warning).
2. `resolve_target`: scope = CLI > manifest > `system`; then `check_source` against the existing record
   (`SourceIdentity`, source.rb): a name differing from an installed one only in case raises (`force` too); a
   shipped name (any case) from a source that isn't a dir in the Installer's `shipped_dir:` (default `SHIPPED_DIR`;
   ShippedUpdate, Profile and SystemBundle pass theirs) raises unless `force` (a recorded source is matched by the
   `SHIPPED_SOURCE` path pattern instead, for older gems); a plain install
   over a record from another source raises (`force` too); an upgrade may switch sources and sets
   `#source_change` (the summary's first line, `Source changes: old → new`). A source `SourceIdentity` can't place
   (an older record's relative path) never refuses.
3. `install_memories`, per memory (`MemoryFiles.select`: a non-empty `files:` list, else every top-level `*.md` but
   README, CHANGELOG, LICENSE and the like; a listed name not shipped warns; a symlink is skipped with a warning): an upgrade 3-way merges the files the bundle owns (`merge_memory`), a dry run only
   classifies (`preview_memory`), a plain install writes new files and skips existing ones (`skip_existing`), and `--force` overwrites, a file that
   differs copied to the trash first (`Trash#copy`, said by `#trash_copy_line`; a profile's in `InstallResult#trash_copies`). A
   same-name file the bundle didn't write is the user's: skipped and never recorded (`@owned`). Model overlays
   (`<name>.<key>.md`) get no index line (`note_overlay`).
4. `AssetInstaller#run`: hooks (manifest-listed, else every `hooks/*.rb`), prune dropped hooks, hook checksums,
   guardrails, plugin, scripts; each set replaces the previous version's, an edited file copied to the trash first. requires_chi warnings for hooks/rules. A
   file that is a symlink or resolves outside the bundle dir (`AssetInstaller#linked?`, a linked `hooks/` too) is
   skipped with a warning (a hook or rule) or raises `InstallError` (the plugin, a script).
5. An upgrade's `prune_dropped_files`: unchanged → trash; edited → kept (`kept_pruned`); owned by another bundle → kept.
6. `verify_memory_checksums` (strict), `warn_missing_needs`.
7. `write_provenance` (manifest, not a dry run): bases come from the incoming file, except where the user's edit was
   kept (kept/noop/conflict/kept_pruned, or a re-install's skipped edit): those keep the old base, so the next
   upgrade still sees the edit. A plain install also keeps the record (the old base) of a file an earlier install
   owned and this version doesn't ship, while it is on disk (`dropped_owned_files`), so the next upgrade prunes it.
8. `detect_placeholders`.

Results are `@results` (file → `{status:, reason:}`), summarised by `#summary`. An upgrade with conflicts keeps an
owned source dir alive (`#source_dir`) until `#cleanup_source!`, because the conflict agent reads the incoming
files; `BundleCommand#settle_conflicts` then runs `Provenance#resolve_conflicts`, which moves a base forward and keeps
the entry's description, only for a file the agent step changed that holds no markers (`Merger.markers?`). Any other keeps
its old base and mark, and the command exits `CONFLICTS_KEPT`.

## Builder#run, in order

`select_memories` (all but `index.md`/hidden; with `--files` the named ones + their overlays, else leaving out files
another installed bundle owns) → `checksum_memories` → `installed_parts` (`Builder::InstalledParts`: the same-name
installed bundle's hooks, rules, plugin, scripts, context providers, else the scope dir's `hooks/`/`guardrails/`) →
`stage_files` + `write_manifest` in a temp dir → `write_out` (zip, tar, tgz, or a new/empty dir). An installed
profile's name is refused (`refuse_profile!`): a build can't remake its includes.
