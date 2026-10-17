# Memory bundles: install, upgrade and build

How `lib/samagotchi/memory_bundle/` turns a bundle (a dir, git URL, zip or tar holding `manifest.yml`, `*.md`
memories and optional `hooks/`, `guardrails/`, a plugin file and `scripts/`) into installed state, and back. The
user-facing side (what a bundle owns, profiles, needs) is in [memory.md](../memory.md#what-a-bundle-owns) and
[plugins.md](../plugins.md).

## Where things live

```
<scope memories dir>/            MemoryPaths.scope_dir: system ~/.config/samagotchi/memories,
                                 project <system>/projects/<project key>
  *.md, index.md                 the bundle's memories, one managed index line each ("· from <bundle>")
<system memories>/.bundles/      MemoryPaths.bundles_dir
  <name>/manifest.json           the install record (Provenance#write, read as InstalledBundle)
  <name>/bases/                  each file as installed: the base of the next upgrade's 3-way merge
  <name>/hooks/ guardrails/ plugin/ scripts/
  .trash/<name>-<stamp>/         files an uninstall or upgrade took away (Trash), never deleted
```

## Components

| Piece | Role |
|---|---|
| `BundleCommand` (`lib/samagotchi/bundle_command.rb`) | `chi bundle install/upgrade/uninstall/status/diff/list/build/trash`; runs the Installer, prints its summary, runs the conflict agent step |
| `SourceNormalizer` (source.rb) | source → local dir; a git/zip/tar extract is *owned* and removed after the install |
| `SourceIdentity` (source.rb) | what a source is, for comparing two installs of one name: `shipped:<dir>` (any gem or checkout), `git:<url>` (no `#ref`, trailing `/` or `.git`), `path:<realpath>`; nil when it can't place one |
| `PreparedSource` (source.rb) | one source normalized once (dir, owned, git commit): `BundleCommand` reads the bundle's name from its `manifest.yml` (the name for every kind of source, a git URL too) and hands it to the Installer (`prepared:`), so a source is cloned or extracted once per command |
| `MemoryFiles` | which top-level `*.md` files of a bundle are its memories (`.select`: the `files:` list, else all but README/LICENSE and the like), `.unshipped` (listed, not shipped) and `.symlinks` (skipped: a symlink is never a memory) |
| `Manifest` | parses/validates `manifest.yml` (YAML that doesn't parse or isn't a mapping is a `ValidationError` too; files, hooks as `BundleHook`, plugin, scripts, needs, requires_chi, includes, context_providers) and writes it (`Manifest.write`, for Builder). It ignores `requires_chi_next`, a shipped bundle's release-time marker (`script/release/release_tools.rb`, docs/releasing.md) |
| `Installer` | one install/upgrade/dry run of one bundle (below) |
| `AssetInstaller` | the parts that live in `.bundles/<name>/`: hooks, guardrail rules, plugin, scripts; returns `AssetInstaller::Installed` (the paths the record keeps) |
| `Merger` | 3-way classification per file: `install`, `fast_forward`, `keep`, `noop`, `conflict` |
| `Provenance` | the `.bundles/<name>/` dir: `#write` the record + bases, `#record` → `InstalledBundle`, `.each_installed`, `.claimants` (which bundles own a file) |
| `InstalledBundle`, `BundleHook`, `PluginRef` | value objects for the record; tolerant of older records (missing keys read as empty) |
| `Builder` | `chi bundle build`: memories (+ the installed bundle's hooks, rules, plugin, scripts) → zip/tar/dir |
| `Profile` | meta bundles (`includes:`): install the members, record which |
| `SystemBundle`, `ShippedUpdate` | the built-in system bundle (`ensure!` at Engine start, `sync` in `chi update`) and `chi update`'s upgrade of shipped bundles; both drive the Installer with `upgrade: true` |
| `Uninstaller`, `Trash`, `Status`, `Listing` | remove, keep removed files, `chi bundle status`, `chi bundle list` |
| `IndexUpdater`, `IndexSync` | the managed `index.md` lines (Installer; and the write/edit tools for memories) |
| `IndexSize` | one scope's memory index as the prompt carries it (tokens, lines, bytes): `memory.index_warn_tokens`' crossing note after a memory write, `chi self`'s summary, the prompt's figures (`SystemPrompt`) |
| `Placeholder` | `{{placeholder}}` patterns left in an installed memory, one line per file from `Installer#detect_placeholders`; a hint, never a gate |

Readers of the installed state: `Hooks::BundleLoader` (Engine), `GuardrailWiring#bundle_rules`, `Plugin::Loader`,
`ContextProviders` (scripts), `BundleNeeds` (index markers). Each goes through `Provenance.each_installed` / `#record`
and checks the recorded sha256 (and `requires_chi`) before loading.

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
   classifies (`preview_memory`), a plain install writes new files and skips existing ones (`skip_existing`). A
   same-name file the bundle didn't write is the user's: skipped and never recorded (`@owned`). Model overlays
   (`<name>.<key>.md`) get no index line (`note_overlay`).
4. `AssetInstaller#run`: hooks (manifest-listed, else every `hooks/*.rb`), prune dropped hooks, hook checksums,
   guardrails, plugin, scripts; each set replaces the previous version's. requires_chi warnings for hooks/rules. A
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
files; `Provenance#resolve_conflicts` then moves the resolved files' bases forward.

## Builder#run, in order

`select_memories` (all but `index.md`/hidden; with `--files` the named ones + their overlays, else leaving out files
another installed bundle owns) → `checksum_memories` → `installed_parts` (`Builder::InstalledParts`: the same-name
installed bundle's hooks, rules, plugin, scripts, context providers, else the scope dir's `hooks/`/`guardrails/`) →
`stage_files` + `write_manifest` in a temp dir → `write_out` (zip, tar, tgz, or a new/empty dir). An installed
profile's name is refused (`refuse_profile!`): a build can't remake its includes.
