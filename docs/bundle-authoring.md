# Writing a bundle

Read this first when someone asks for new chi functionality "as a bundle". It is the short path: the loop, the
files, what a hook sees, how to test, and what goes wrong. The full references are in this same `docs/` folder:
[plugins.md](plugins.md) (the `chi.*` API and `ctx`) and [hooks.md](hooks.md) (every event's fields).

## The loop

```
chi bundle new my-bundle     # ./my-bundle: manifest.yml, plugin.rb, test/my_bundle_test.rb, README.md
cd my-bundle                 # edit plugin.rb and the test
chi bundle test              # the tests, on chi's own Ruby and lib (exit status: the tests')
chi bundle check --fix       # manifest, files, shas (--fix rewrites them), requires_chi, install + load in a sandbox
chi bundle install .         # into the user's chi; a NEW session loads it (a running one doesn't)
chi bundle install --dev .   # or as a link to this folder: edits apply at the next session, no re-install
```

While you write it, `install --dev .` (once; `uninstall NAME` leaves dev mode) then try it in chi: a new session
loads the plugin and hooks from the folder as they are, with no sha check (that bundle only; memories are copied).
Re-install with `--force` from the same PATH to pick up memory edits.
Dev-linked scripts aren't chmodded, since that would change the source. Chi warns with a `chmod +x PATH/scripts/x`
hint when a listed script isn't executable; set that bit on the source script.

`check` prints one finding per line, `error|warn|info CODE file[:line]: message (fix: hint)`, and exits 1 on any
error. Run it after every edit: an install takes exactly what it checks. It installs into a temp sandbox, not
the user's config or state, but `check` and `test` run the bundle's plugin and hooks in their own process, as
written: run them on code you'd install.

## The files

```yaml
# manifest.yml
name: my-bundle              # a plain name; chi bundle install takes it from here
version: 0.1.0
scope: system
description: "What it adds, in one line"
requires_chi: ">= 0.85.0"    # the chi it needs (new writes the running one; check warns when a call needs newer)
plugin:
  file: plugin.rb
  sha256: sha256:<hex>       # `chi bundle check --fix` fills it; never compute it by hand
# files:                     # memories it installs (top-level *.md); without files: every *.md but README & co.
#   my_notes.md: sha256:<hex>
# hooks:                     # hooks/*.rb files (a plugin's chi.on is usually simpler)
# needs: [gh]                # outside commands it relies on
```

`plugin.rb` defines `class Plugin` with `register(chi)`; `initialize(settings)` (optional) gets config.yml
`bundles: my-bundle:` as a Hash with string keys, once, when the plugin loads. A value a session may set
(`chi --set my-bundle.KEY=V`, listed in the manifest's `session_settings:`) is read from `ctx.settings` at call
time. `chi bundle check --set KEY=VALUE` gives the sandboxed load a setting.

## What a hook sees

`chi.on(event) { |event, ctx| … }` gets a Hash. The events, in a turn's order: `session_start`, `before_turn`,
`before_generation`, `generation_progress`, `after_generation`, `before_tool_call`, `after_tool_call`,
`after_turn`, `session_end` (the fields of each: [hooks.md, Hook Events](hooks.md#hook-events)). A symbol not in
that list is never fired (`check` warns). The two a bundle wants most, for an `execute`:

```ruby
# before_tool_call: vote on the call before it runs
{ type: :before_tool_call, iteration: 1,
  call: { name: "execute", content: "rm -rf build" }, params: "execute rm -rf build",
  guardrail: verdict,        # event[:guardrail].deny!("why") / .ask!("why"); ctx.stop_turn denies and stops the turn
  context: { cwd: "/work", repo_root: nil, branch: nil, session_id: "…", interface: :worker, origin: nil },
  targets: { command: "rm -rf build", paths: [], cwd: "/work", repo_root: nil, outside_repo: false, git_dirs: [] },
  blocked: false, block_reason: nil }

# after_tool_call: what it did
{ type: :after_tool_call, iteration: 1, tool: "execute", status: "error",   # "ok" | "error" | "blocked" | "stopped"
  call: { name: "execute", content: "make test" }, elapsed_ms: 812,
  result: "stdout:\nok\n\nstderr:\n1 failed\n\nexit: 1",                    # the tool's own text, never cut
  output: "[execute]\nstdout:\n…" }                                          # what the model reads: may be cut
```

Match on `result:`, not `output:`. An execute's result is its `stdout:` and `stderr:` blocks (each left out when
empty), then `exit: N` (`exit: 0 (no output)` when both were empty); a non-zero exit makes `status:` `"error"`.
Act through `ctx`: `ctx.notify(text, level: :warn)`, `ctx.steer(text)` (a line the model reads before its next
step), `ctx.card(…)`, `ctx.stop_turn(reason)`, `ctx.ask_user(…)`, `ctx.data_dir` (the bundle's own folder),
`ctx.cwd`, `ctx.log`. In a test, each recorded notice, steer or stop names its hook as `"plugin.rb (bundle
my-bundle)"`, the plugin's label (a `hooks/x.rb` file's is `"x.rb (bundle my-bundle)"`).

## Testing it

`chi bundle new` writes a Minitest test that passes as written: copy its shape. The kit (`samagotchi/testing`)
loads the bundle's source through chi's own loaders, in a sandbox (temp HOME, config and state), and records what
it did at chi's edges:

```ruby
bundle = load_bundle(BUNDLE, settings: { "greeting" => "hi" })   # in a Samagotchi::Testing::Case test
bundle.command("/my-bundle chi")                     # → what the command returned
bundle.fire(:after_tool_call, tool: "execute", status: "error", result: "exit: 1 (no output)", call: { … })
bundle.tool_call({ name: "execute", content: "rm -rf /" }).deny?   # before_tool_call hooks, through the real gate
bundle.tool("my_tool", path: "a.txt")                # a chi.tool, as the model calls it
bundle.notices, bundle.steers, bundle.cards, bundle.stops, bundle.questions   # what it did
bundle.answer({ selected: "yes" }); bundle.model_answers << "text"           # ask_user / ask_model answers
bundle.http.stub(:get, "https://api.example/x", json: { ok: true })          # ctx.http, never the network
bundle.set(cwd: dir, running: false); sandbox.config(hash); sandbox.fake_executable("gh", "echo '{}'")
bundle.install                                        # installed as chi installs it: warnings, load failures
```

The full list is in [plugins.md, Testing a bundle](plugins.md#testing-a-bundle-experimental). The kit is
experimental (it may change before chi 1.0). If a test needs a fake of chi's own (a stub of a `Samagotchi::`
class, a hand-built `ctx`), that is a gap in the kit: say so to the user rather than reaching into chi.

## Pitfalls

- **Shas.** Every file the manifest names has a sha256 line, and an edit makes it stale: the install then warns
  of a checksum mismatch, and a line with no sha installs unchecked. `chi bundle check --fix` rewrites them; run it
  after the last edit.
- **requires_chi.** Use the chi the user runs (`chi --version`). `check` warns when the plugin calls something
  newer than the floor (`ctx.http` needs 0.80.0, `ctx.cost` 0.83.0).
- **trust_level.** Leave it out. `reviewed` / `trusted` are for someone who reviewed the bundle, not its author.
- **Restart.** A session loads bundles when it starts: after an install or a settings change, the user starts a
  new session (or `chi sessions restart ID`).
- **chi's internals.** A bundle may use `chi.*`, `ctx` and the names
  [plugins.md, Stable for bundles](plugins.md#stable-for-bundles) lists; any other `Samagotchi::` name may change
  in any release (`check` warns: `boundary`).
- **Load errors.** A plugin that raises at load is skipped and the session goes on: `check` shows the error at its
  `plugin.rb:LINE`.

## Verifying it live

After `chi bundle install .`, one real session shows it works with the user's chi:

```
chi send --new --wait --format json --dir /tmp/try -m "/my-bundle chi"   # the JSON names the session id
grep plugin_loaded ~/.local/state/samagotchi/samagotchi.log | tail -1    # bundle=my-bundle commands=1 hooks=1
chi sessions delete --force SESSION_ID                                    # leave no test session behind
```

(`$XDG_STATE_HOME/samagotchi/samagotchi.log` when `XDG_STATE_HOME` is set.) Then tell the user what it adds,
how to use it, and that a new session picks it up.
