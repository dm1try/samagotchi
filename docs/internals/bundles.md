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
  <name>/bases/                  each file's base for the next upgrade's 3-way merge: as installed, or the
                                 bundle's own text after a merge
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
| `AssetInstaller` | the parts that live in `.bundles/<name>/`: hooks, guardrail rules, plugin, scripts; returns `AssetInstaller::Installed` (the paths the record keeps). A file it replaces or removes whose bytes are neither the recorded sha nor the incoming file's is copied to the Installer's `Trash` first (`Trash#copy_edit`, `#copy_edits` for a folder at any depth, as `hooks/x`, `guardrails/x`, `plugin/x`, `scripts/sub/x`; no sha recorded counts as edited; a dev link never is) |
| `Merger` | 3-way classification per file: `.classify` → an `Outcome` (`status`: `install`, `fast_forward`, `keep`, `noop`, `conflict`, `merged`; `base`: where the file's next base comes from, `:on_disk`, `:recorded` or `:incoming`; a new outcome and its base go in its constants, and it needs a branch in `Installer#merge_memory`, a kind in `#next_base` if its base is new, and its status word in `#preview_memory`, `#verify_memory_checksums` and `#summary`). `.classify` never merges and answers `conflict` for two changed sides; `Merger::Upgrade` (provenance, target dir, source dir) is the one way to ask what an upgrade does to a file, nothing written: `#outcome` (`.classify`, then `TextMerge` where both sides changed, git once per call: `merged`, with its `TextMerge::Result` and the digest it read as the Outcome's `merge` and `current_sha`; `ALREADY_MERGED`, a `keep` with base `:incoming`, when the merge adds nothing; or `conflict` with that `merge`, whose `why` says why none was possible), `#classified`, `#forecast` (a `Forecast` of `merged` and `conflicts` in one pass), `#paths`, used by the Installer's merge and dry run, `ShippedUpdate.plan` and `SystemBundle.sync(dry_run:)`. `.write_merged` puts a merge in place: the digest checked just before the rename (`AtomicFile.write`'s block), through a symlink, the mode kept, the old file in the `Trash`; false when a live `memory_write` got in. A mark from an older chi (`InstalledBundle.legacy_mark?`: no `incoming_sha`, or `legacy_base`, which keeps that known once the digest is recorded, until the mark goes) may have the user's own text as its base, 0.149's doing, and a merge against it would undo that text with nothing to show, or a fast-forward replace all of it: `#outcome` makes such a fast-forward, and `.merge_outcome` a merge that takes any line out of the file, a `conflict` (`LEGACY_BASE`), on the Installer's and `Remerge`'s path alike. The price: a real base looks the same, so such a file whose bundle rewords or removes a line it still holds stays behind until it is resolved by hand, with `--agent` or with `--force`; no retry fixes it. `Installer#save_marked_file` now serves only this chi's marks, on a file put back to its base. `.markers?` (a file holding a merge's `<<<<<<<`/`>>>>>>>` lines; `=======` alone is a Markdown underline) |
| `TextMerge` | the text merge: `.merge(base:, ours:, theirs:)` → a `Result` (`status` `:clean` with `text`, `:conflict` with `hunks`, `:failed` with `why`). `git merge-file -p --diff3 --marker-size=20` on temp copies in a temp cwd, with every `GIT_*` that points at a repository or a config unset or at `/dev/null` (it can run inside another tool's hook). git isn't a runtime dependency: none on PATH, or macOS's `/usr/bin/git` with no developer tools behind it (`.apple_stub?`, by `xcode-select -p`; running it pops a dialog), is `:failed`. So is a git past `TIMEOUT` (10 s; its process group is killed: this runs under `SystemBundle`'s lock), and any doubt about the answer: `min(hunks, 127)` against the exit status, a status over 127, a NUL in a side, marker lines that don't pair up (a user's line equal to one), a line no input holds, or an empty answer to non-empty inputs. `Scan` reads the output: a hunk unions (ours, then the entries of theirs that ours lacks) only when the last heading before it, at level 1 or 2 and outside code fences, HTML comments and any hunk, is titled exactly `Changelog` or `Change log`, with nothing but list entries (an item and its indented lines) since that heading and no fence or comment open, and base, ours and theirs each hold only list entries, with every base entry still on both sides: both only added. Any other hunk is a real conflict, and markers never leave the module. `Hunk#heading` is there for what names a miss |
| `Remerge` | the retry at the same version, memory files only, for a file marked `conflict`: `#run(dry_run:)` → a `Result` (`merged`, `settled`, `stamped`, `notes`, `warnings`, `trash_copy`). It merges what merges and settles those entries (`Provenance#resolve_conflicts`, the index line refreshed), leaving `version`, `installed_at` and the assets alone: the Installer would `rm_rf` guardrails, plugin and scripts under live sessions. A file not shipped now (`MemoryFiles.select`) keeps its mark, base and text, with a note; one whose `incoming_sha` isn't the shipped text (a checkout at one VERSION) is left alone and no git runs; a mark with no digest (older chi) is tried as well, and a real conflict then records it (`Provenance#stamp_incoming`). A mark whose digest matches is tried on every run, since the file or git may have changed. `noop` and `keep` settle quietly; `fast_forward` and `install` wait for the next upgrade or restore. A file it can't read or replace stays as it is, with a note. Called from `ShippedUpdate.plan_row`/`apply` (`chi update`) and `SystemBundle.sync`'s equal-version branch, under its lock (each chi start and `chi update`); a bundle chi doesn't ship retries through `chi bundle upgrade`. No marks: nothing is read beyond the record. One marked file costs one git run per Engine start, about 12 ms on the Studio (0.1 ms with none) |
| `Provenance` | the `.bundles/<name>/` dir: `#write` the record + bases (its `files:` is the full list: a key left out is dropped, a nil value keeps the entry with no base; `conflicts:` and `incoming_shas:` are the marks and the bundle text each speaks of, `incoming_sha`; an older mark that stays keeps `legacy_base`), `#resolve_conflicts` (base to the incoming file, mark and its fields gone; a file whose incoming copy is gone keeps both), `#stamp_incoming` (the digest and `legacy_base`), `#record` → `InstalledBundle`, `.each_installed`, `.claimants` (which bundles own a file) |
| `InstalledBundle`, `BundleHook`, `PluginRef` | value objects for the record; tolerant of older records (missing keys read as empty). `BundleHook#events` is the manifest's `event:` or its `events:` list (written back as `event:` for one, as an older chi reads it); `Hooks::BundleLoader#load_hook_file` builds the hook once and registers it under each |
| `Builder` | `chi bundle build`: memories (+ the installed bundle's hooks, rules, plugin, scripts) → zip/tar/dir |
| `Profile` | meta bundles (`includes:`): install the members, record which; `InstallResult#kept_own` names a new member's memory files the user already had, with other bytes (`kept_own_line`, printed by `chi bundle`, `chi update` and `chi bootstrap`); a dry run runs each member's Installer as a dry run too, so it names them as well |
| `SystemBundle`, `ShippedUpdate` | the built-in system bundle (`ensure!` at Engine start, `sync` in `chi update`) and `chi update`'s upgrade of shipped bundles; both drive the Installer with `upgrade: true` and `Remerge` at an equal version (`ShippedUpdate::Row`'s `:would_merge`, `:merged`; `SystemBundle::Result`'s `:merged`). `SystemBundle` also puts back a memory missing at an equal version, that file alone, with no Installer (`verify_files_present`, `Provenance#record_restored`). `ensure!` logs a merge with no echo for now. `ShippedUpdate.external` is the rest: what `chi update` only checks |
| `InstalledCopy`, `BundleCommand::InstalledCheck` | `chi update`'s re-check of the bundles chi didn't ship ([docs/cli.md](../cli.md#updating)). `InstalledCopy` lays a record and its installed files out as a source folder (manifest.yml from `Manifest.write`, the files' own shas, memories from `bases/`); `InstalledCheck` forks per bundle (a plugin's `exit` or hang is that bundle's row; stdio to /dev/null, so `--json` stays parseable; `TIMEOUT`, then KILL of its group) and runs `Check.new(dir, installed: true)` there, which leaves out what only suits a source tree. Its `boundary` finding is narrower there than in a source tree: `Testing::Boundary.gone?` calls a reference gone only when its constant doesn't resolve or the object has no method the name names, so a bundle reaching `Samagotchi::Log` gets no row. lib loads lazily, so when a name doesn't resolve `gone?` requires every file of this chi's library in that same child and asks again (about 0.2 s, only for a bundle that reaches into chi at all); anything it can't read — a `const_get`, a require of a file that is there — is taken as still there. The fork is the point: `Sandbox` swaps ENV and the plugin's code is arbitrary. `UpdateCommand#external_rows` makes the rows (`level`, never `failed`) and holds the check back while a newer gem is yet to take over (`@not_checked`), since a fork is this chi's code |
| `Uninstaller`, `Trash`, `Status`, `Listing` | remove (the bundle's own folder too: an edited file there is copied to the trash first, `Uninstaller#trash_copy_line`); keep removed files (`Trash#move`) and a copy of overwritten ones (`Trash#copy`, its `as:` keeping a subfolder); `chi bundle status`; `chi bundle list` |
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
   README, CHANGELOG, LICENSE and the like; a listed name not shipped warns; a symlink is skipped with a warning): an upgrade 3-way merges the files the bundle owns (`merge_memory`: a clean text merge replaces the file through `Merger.write_merged`, and a real conflict, no git or no base leaves it untouched, `note_conflict`; a fast-forward over an entry this chi marked `conflict`, a file put back by hand, copies it to the trash first: `save_marked_file`), a dry run only
   classifies (`preview_memory`, `would_merge` for a merge, git running on temp copies; both through `Merger::Upgrade`), a plain install writes new files and skips existing ones (`skip_existing`), and `--force` overwrites, a file that
   differs copied to the trash first (`Trash#copy`, said by `#trash_copy_line`; a profile's in `InstallResult#trash_copies`). A
   same-name file the bundle didn't write is the user's: skipped and never recorded (`@owned`). Model overlays
   (`<name>.<key>.md`) get no index line (`note_overlay`).
4. `AssetInstaller#run`: hooks (manifest-listed, else every `hooks/*.rb`), prune dropped hooks, hook checksums,
   guardrails, plugin, scripts; each set replaces the previous version's, an edited file copied to the trash first. requires_chi warnings for hooks/rules. A
   file that is a symlink or resolves outside the bundle dir (`AssetInstaller#linked?`, a linked `hooks/` too) is
   skipped with a warning (a hook or rule) or raises `InstallError` (the plugin, a script).
5. An upgrade's `prune_dropped_files`: unchanged → trash; edited → kept (`kept_pruned`); owned by another bundle → kept.
6. `verify_memory_checksums` (strict), `warn_missing_needs`.
7. `write_provenance` (manifest, not a dry run): an upgrade's bases come from each file's `Merger::Outcome`
   (`Installer#next_base`): the file on disk, which has the bundle's bytes; the incoming file for a merge, since the merged
   file holds the user's edit and taking it would make current == base, so the next upgrade would fast-forward over the
   edit (the edited signal stays current != base, which `chi bundle status` and uninstall's refusal read); and where the user's edit was
   kept (keep, conflict; a file the bundle dropped, kept_pruned, and a re-install's skipped edit take the same path by their
   status and reason): those keep the old base, so the next upgrade still sees the edit. One with no base stays without one (a nil in `Provenance#write`'s `files:`, which keeps the
   entry and its recorded checksum): taking the user's file would let the next upgrade fast-forward over it. A plain
   install carries the `conflict` mark of a file it skipped (`held_conflict_marks`), a newer source moving `version`
   included; it goes once the file has the incoming bytes. A plain install also keeps the record (the old base) of a file an earlier install
   owned and this version doesn't ship, while it is on disk (`dropped_owned_files`), so the next upgrade prunes it.
8. `detect_placeholders`.

A file system error in steps 3 to 5 (`Installer#replace_files`; a `.trash` it can't write, an edited file it can't read) is an
`InstallError` in `Trash.failure_message`'s words, as it is an `UninstallError` in `Uninstaller#run`. Each save comes before
its removal, so no edit is lost, and the record isn't written, so a retry is the same upgrade. Not atomic: files the
failed run already placed stay.

Which files a plan asks `Merger::Upgrade` about is the caller's, and the lists differ, each less the files the bundle
doesn't own: the Installer's `MemoryFiles.select`; `ShippedUpdate.forecast`' every shipped `*.md`, so `chi update`'s plan
can name a file dropped from `files:` or now a symlink, which the upgrade doesn't merge: edited, it stays (`kept_pruned`, or `kept_shared` when another bundle has it too); `SystemBundle`'s dry
run the manifest's `files:`, so a manifest with none plans nothing (the shipped one lists its files).

Results are `@results` (file → `{status:, reason:}`), summarised by `#summary`. An upgrade with conflicts keeps an
owned source dir alive (`#source_dir`) until `#cleanup_source!`, because the conflict agent reads the incoming
files; `BundleCommand#settle_conflicts` then runs `Provenance#resolve_conflicts`, which moves a base forward and keeps
the entry's description, only for a file the agent step changed that holds no markers (`Merger.markers?`), and whose incoming
copy is still there. Any other keeps its old base and mark, and the command exits `CONFLICTS_KEPT`.

## Builder#run, in order

`select_memories` (all but `index.md`/hidden; with `--files` the named ones + their overlays, else leaving out files
another installed bundle owns) → `checksum_memories` → `installed_parts` (`Builder::InstalledParts`: the same-name
installed bundle's hooks, rules, plugin, scripts, context providers, else the scope dir's `hooks/`/`guardrails/`) →
`stage_files` + `write_manifest` in a temp dir → `write_out` (zip, tar, tgz, or a new/empty dir). An installed
profile's name is refused (`refuse_profile!`): a build can't remake its includes.
