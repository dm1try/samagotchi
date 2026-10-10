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
| `Manifest` | parses/validates `manifest.yml` (files, hooks as `BundleHook`, plugin, scripts, needs, requires_chi, includes, context_providers) and writes it (`Manifest.write`, for Builder) |
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

Readers of the installed state: `Hooks::BundleLoader` (Engine), `GuardrailWiring#bundle_rules`, `Plugin::Loader`,
`ContextProviders` (scripts), `BundleNeeds` (index markers). Each goes through `Provenance.each_installed` / `#record`
and checks the recorded sha256 (and `requires_chi`) before loading.

## Installer#run, in order

The order matters: warnings print in it, and a plugin/script the manifest names but the bundle lacks raises
`InstallError` after the memories are already copied.

1. `load_source`: normalize, read `manifest.yml` (strict: a missing/invalid one raises; non-strict: a warning).
2. `resolve_target`: scope = CLI > manifest > `system`.
3. `install_memories`, per `*.md`: an upgrade 3-way merges the files the bundle owns (`merge_memory`), a dry run only
   classifies (`preview_memory`), a plain install writes new files and skips existing ones (`skip_existing`). A
   same-name file the bundle didn't write is the user's: skipped and never recorded (`@owned`). Model overlays
   (`<name>.<key>.md`) get no index line (`note_overlay`).
4. `AssetInstaller#run`: hooks (manifest-listed, else every `hooks/*.rb`), prune dropped hooks, hook checksums,
   guardrails, plugin, scripts; each set replaces the previous version's. requires_chi warnings for hooks/rules.
5. An upgrade's `prune_dropped_files`: unchanged → trash; edited → kept (`kept_pruned`); owned by another bundle → kept.
6. `verify_memory_checksums` (strict), `warn_missing_needs`.
7. `write_provenance` (manifest, not a dry run): bases come from the incoming file, except where the user's edit was
   kept (kept/noop/conflict/kept_pruned, or a re-install's skipped edit): those keep the old base, so the next
   upgrade still sees the edit.
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
