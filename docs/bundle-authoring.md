# Writing a bundle

Read this first when someone asks for new chi functionality "as a bundle". It is the short path: the loop, the
files, what a hook sees, how to test, and what goes wrong. The full references are in this same `docs/` folder:
[plugins.md](plugins.md) (the `chi.*` API and `ctx`) and [hooks.md](hooks.md) (every event's fields).

## The loop

```
chi bundle new my-bundle     # ./my-bundle: manifest.yml, plugin.rb, test/my_bundle_test.rb, README.md
cd my-bundle                 # edit plugin.rb and the test
chi bundle install --dev .   # once while iterating: link this folder; edits load in the next session
chi bundle check --fix       # manifest, files, shas (--fix rewrites them), requires_chi, install + load in a sandbox
chi bundle test              # tests on chi's own Ruby and lib (exit status: the tests')
chi bundle try . -p "Say hello"  # one real model turn; trace the bundle in an isolated install sandbox
chi bundle uninstall my-bundle && chi bundle install .  # at the end: leave dev mode, copy it in
```

The loop is **edit → `check --fix` → `test` → `try`**. `install --dev .` links the folder once, so a new session
loads your edits with no reinstall (a running one doesn't; `try` doesn't need the link: it installs into its own
sandbox). Memories are copied: re-install with `--force` from the same PATH to pick up memory edits. At the end,
`uninstall NAME` leaves dev mode and a plain `install .` copies the bundle in (chi refuses it over a dev link).
Dev-linked scripts aren't chmodded: chi warns with a `chmod +x PATH/scripts/x` hint; set the bit on the source.

`check` prints one finding per line (`error|warn|info CODE file[:line]: message (fix: hint)`), exits 1 on any error
and installs into a temp sandbox, not the user's config or state; run it after every edit. `check` and `test` run
the bundle's plugin and hooks in their own process, as written: run them on code you'd install.

## Trying a bundle

After `chi bundle check --fix`, run `chi bundle try . -p "Say hello"` for one real model call using the user's
configured hosts and keys. It installs the bundle plus chi's shipped guardrails and a default $1 cost cap, then
prints tool calls, hook notices, cards, questions, the answer, token totals and cost.

The child uses a temporary config, state and working directory; the user's other bundles and memories aren't loaded,
nor are the current project's `AGENTS.md` / `CLAUDE.md` files. This is not a security sandbox: the bundle and tools
run with the user's real HOME and account, and can access files and services available there. Use `try` only with
code you trust. See [CLI: Trying a bundle](cli.md#trying-a-bundle) for flags, `--json`, `--keep` and exit statuses.

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
(`chi --set my-bundle.KEY=V`, listed in the manifest's `session_settings:`, typed with `{KEY: number}` so a
value of another type is refused) is read from `ctx.settings` at call
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
step), `ctx.card(…)`, `ctx.stop_turn(reason)`, `ctx.ask_user(…)`, `ctx.data_dir` (the bundle's state folder),
`ctx.cwd`, `ctx.log`. In a test, each recorded notice, steer or stop names its hook as `"plugin.rb (bundle
my-bundle)"`, the plugin's label (a `hooks/x.rb` file's is `"x.rb (bundle my-bundle)"`).

## Testing it

`chi bundle new` writes a Minitest test that passes as written: copy its shape. The kit (`samagotchi/testing`) loads
the bundle's source through chi's own loaders in a sandbox (temp HOME, config and state) and records what it did:
`load_bundle`, then `bundle.command` / `bundle.fire`, and the effects in `bundle.notices`. `bundle.ctx.data_dir` and
`sandbox.state_dir` are that test's temporary state, never the user's (the scaffold's plugin, tested):

```ruby
require "minitest/autorun"
require "samagotchi/testing/minitest"

class MyBundleTest < Samagotchi::Testing::Case
  def test_command_and_failed_execute_notice
    bundle = load_bundle(File.expand_path("..", __dir__), settings: { "greeting" => "hi" })
    assert_equal "hi, there", bundle.command("/my-bundle")
    bundle.fire(:after_tool_call, tool: "execute", status: "error", call: { name: "execute", content: "false" },
                                  result: "exit: 1 (no output)", output: "[execute]\nexit: 1 (no output)")
    assert_equal "the command exited 1", bundle.notices.last.text
    assert_equal File.join(sandbox.state_dir, "plugins", bundle.name), bundle.ctx.data_dir
  end
end
```

`bundle.tool_call` runs guarded hooks; `bundle.tool` calls a registered tool. `bundle.steers`, `cards`, `stops` and
`questions` record effects; `bundle.answer` / `model_answers` provide `ask_user` / `ask_model` answers.
`bundle.http.stub` stubs `ctx.http`; `sandbox.config`, `sandbox.fake_executable` and `bundle.install` cover setup.
The full list is in [plugins.md, Testing a bundle](plugins.md#testing-a-bundle-experimental). The kit is
experimental (it may change before chi 1.0). If a test needs a fake of chi's own (a stub of a `Samagotchi::`
class, a hand-built `ctx`), that is a gap in the kit: say so to the user rather than reaching into chi.

## Pitfalls

- **Shas.** Every file the manifest names has a sha256 line, and an edit makes it stale: the install then warns
  of a checksum mismatch, and a line with no sha installs unchecked. `chi bundle check --fix` rewrites them; run it
  after the last edit.
- **requires_chi.** Use the chi the user runs (`chi --version`). `check` warns when the plugin calls something
  newer than the floor (`ctx.http` needs 0.80.0, `ctx.cost` 0.83.0, `ctx.sessions.children` 0.34.0). A keyword added
  later it can't see: `ctx.ask_model(model:)` needs 0.80.0, `ctx.sessions.send(delivery:)` 0.64.0.
- **trust_level.** Leave it out. `reviewed` / `trusted` are for someone who reviewed the bundle, not its author.
- **Restart.** A session loads bundles when it starts: after an install or a settings change, the user starts a
  new session (or `chi sessions restart ID`).
- **chi's internals.** A bundle may use `chi.*`, `ctx` and the names
  [plugins.md, Stable for bundles](plugins.md#stable-for-bundles) lists; any other `Samagotchi::` name may change
  in any release (`check` warns: `boundary`).
- **Load errors.** A plugin that raises at load is skipped and the session goes on: `check` shows the error at its
  `plugin.rb:LINE`.

## Verifying it live

`chi bundle try . -p "..."` **is** the live check: a real model turn on the installed bundle, with its trace
(tools, plugin, notices, cards). Don't repeat it with `chi send` sessions on the user's own install. After the
final `chi bundle install .`, `chi bundle list` showing the bundle and its version is enough. Then tell the user
what it adds, how to use it, and that a new session picks it up.
