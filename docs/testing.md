# Testing

```sh
bundle exec parallel_rspec -n 8 spec lib/samagotchi/bundles/*/spec   # Ruby specs, both roots, in parallel
bundle exec rspec spec lib/samagotchi/bundles/*/spec                 # the same, plain
bundle exec rake bundles:specs    # the shipped bundles' own specs, on the bundle test kit alone
npm test                          # web frontend specs
npm run lint                      # web frontend: undefined names and unused imports (ESLint; CI runs it)
npm run e2e                       # web UI happy paths in Chromium, fake model (once: npx playwright install chromium)
npx playwright test spec/e2e/stage.spec.js   # one e2e file (the root playwright.config.js is the suite's)
bundle exec rake lint             # RuboCop: no offenses (CI runs it)
```

Run `bundle exec rubocop -a` on the files you changed before committing: every enabled style cop follows the
code's own style and has a safe autocorrect, so `-a` fixes them. What it leaves is a Lint finding (a possible
bug) or a broken spec: fix it, or disable that line with the reason (`# rubocop:disable Cop -- why`).
`.rubocop.yml` says why each cop that is off is off.

`npm run lint` is the web frontend's twin, for the modules in `lib/samagotchi/web/public/` (not `vendor/`): ESLint
with two rules only, `no-undef` (a name used but never imported or declared: a dropped import) and `no-unused-vars`
(an import or variable left over), over the browser's globals (`eslint.config.js`). It is a missing-name guard, not a
style pass: add a rule only for a bug class it would have caught. It runs in about 2 s, in CI's `npm test` job and in
`rake release:check`; `rake lint` stays RuboCop alone (CI's rubocop job has no node). A name that is also a browser
global (`name`, `status`, `open`…) passes even when its import is gone: give an export such a name only with care.
It also checks `spec/e2e/` for one thing, the Playwright twin of `Samagotchi/SpecSleep`: no `page.waitForTimeout`.
Wait for the state (a locator's `expect`, `data-phase`, an animation's end through `waitForFunction`); a pause that
is the behaviour (a pointer's dwell) carries `// eslint-disable-line no-restricted-syntax -- why`.

CI's e2e job keeps the tests, chi and the fake model on the runner but runs Chromium in Playwright's image
(`mcr.microsoft.com/playwright:v<version>-noble`, `playwright run-server` on the host network); the tests connect
to it with `PW_TEST_CONNECT_WS_ENDPOINT`, and traces and the report stay on the runner. Nothing is installed with
apt. The tag is the installed `@playwright/test`'s version, read at run time, so bumping it in `package-lock.json`
moves the image too (`spec/ci_playwright_image_spec.rb` keeps a pinned tag out of the workflow). To run the suite
that way locally: `npx playwright run-server --port 3333`, then `PW_TEST_CONNECT_WS_ENDPOINT=ws://127.0.0.1:3333/ npm run e2e`.

No spec reads your own setup. The suite points `XDG_CONFIG_HOME` and `XDG_STATE_HOME` at temp folders,
clears your `SAMAGOTCHI_*` environment, and keeps every spec off the network (WebMock).

Goldens (`*_golden_spec.rb`, the prompt snapshots) hold no machine state, so they pass on any runner: no absolute
paths (replace them with placeholders), no PATH tools (the suite pins `rg` as found, `spec_helper.rb`; an example
that sets PATH to test the lookup is tagged `:real_rg`), no Ruby-version-dependent `inspect` (a Hash's or an
exception's text changes between Ruby versions: write the string yourself).

The web specs run in plain node. One that loads lit-html, itself or through a module it imports (`turn_view.js`,
`turn_html.js`, `card.js`, `copy.js`, `images.js`, `scope.js`, `command_view.js`, `diff_view.js`, `read_view.js`,
`question_cards.js`, `stream_handlers.js`, `stage_view.js`, `bubbles.js`, `cards_place.js`, the chips, `info_bar.js`, `info_bar_model.js`, `lists_view.js`, `context_chips.js`, `families_view.js`,
`chains.js`, `working_set_view.js`, `working_set_rail.js`, `unqueue.js`, `toasts.js`, `notice_links.js`, `start_page.js`, `session_actions.js`, `send_turn.js`, `dock_reserve.js`,
`vendor/lit-html.js`) needs a DOM: `import "./dom_shim.js";` as its first import (happy-dom, a devDependency only,
never shipped; lit reads `document` as it loads). The shim's `markupOf(template)`,
`htmlOf(nodes)` and `canon(html)` compare markup without lit's marker comments; the DOM writes text with only `&`, `<`, `>`
escaped (a `"` in text stays `"`) and an attribute with `&` and `"` escaped. happy-dom 20 picks the wrong option of a `<select>` whose options lit inserted with
`?selected`: read the option marked `selected` (`option[selected]`), not `select.value`; the browser follows the mark.
A select bound with `.value` instead reads right in both, but lit sets it before the options exist on a first render:
`llm_context_chip.js`'s `renderForm` draws twice then. Assert a kept node with `assert.ok(a === b)`: a failing
`assert.equal` on two DOM nodes inspects the whole DOM (huge output, can stall the run).

`npm test` runs every file in one process (`--test-isolation=none`; CI and local runs use Node 24): the files share
`globalThis`, the shim's one happy-dom window and every module's state: a global a spec sets (stage_view's
`ResizeObserver` stand-in) is there for the files after it, so set only harmless stand-ins and put anything else
back (`t.mock` restores itself). A test that sets off a module's timer (a flash, a highlight's end) fakes it
(`t.mock.timers.enable({ apis: ["setTimeout"] })`, then `tick`): a real one still pending after the last test keeps
node running until it fires (a 4 s one made the run 6 s for 2 s of work). One file:
`node --test spec/web/public/NAME.test.js`.

Where a composer line goes is decided twice, in Ruby (`ComposerRoute`, both terminals) and in the web
(`composer.js#routeComposerLine`). `spec/fixtures/composer_routes.json` holds the cases both answer: rspec
(`spec/composer_route_spec.rb`) and `npm test` (`spec/web/public/composer.test.js`) run every row. A change to
either router adds its row there; a row where a UI differs on purpose (or a found divergence) carries a `web` or
`repl` override and a `note`. The Ruby side runs each row with every core command (a new one fails its
`CORE_ROUTES` check until listed there); a row's names that core lacks stand for plugin commands.

## Waiting and time

A spec waits *for* something and never sleeps to wait: a fixed pause is too short on a loaded runner (a parallel
run, CI) and too long on a fast one. The contract a new spec follows:

1. **Never `sleep` to wait.** Wait for the condition: `wait_for("what") { condition }`, or
   `eventually { expect(…) }` for a value. A `sleep` that *is* the behaviour (slowness, holding a connection,
   separating mtimes) carries `# sleep-ok: why` on its line or the line above (for a call over several lines, its
   first line). A bounded best-effort `wait_until`
   whose timeout is fine ("at most 0.5 s, fine to cut short") carries `# wait-ok: why`; it must not become
   `wait_for`, which would raise where the code moves on. A `Timeout.timeout` is a wait too (use `pop!`, `join!` or
   `wait_for`); one that only guards a call that returns by itself against a hang carries `# timeout-ok: why`.
2. **Time logic takes seams.** Intervals, graces and deadlines in lib take `clock:` / `sleeper:` / `interval:`
   constructor arguments, and the unit spec moves the clock itself (`SessionAccess::Remote` is the model;
   `IdleScheduler.new(interval:)`). Real time is used only in one smoke example per class. Two sessions or inbox
   files that must sort apart get distinct times, not a pause: `Session.new_session(now:)`, `Session#save(now:)` and
   `SessionInbox.write_input` / `write_note` / `write_output(now:)` take `now: next_stamp` (spec/support/stamps.rb:
   a millisecond later on each call, starting a second in the past).
   An example at a threshold's edge (a TTL, a grace) passes one `now:` to both sides and never reads `Time.now`
   twice for it: a second boundary crossed between the reads moves the edge (`ModelProfile.model_warning(now:)`).
3. **What a spec starts, it stops and waits for** before teardown: `join!(thread, what)`, `with_task_dir { … }`
   (spec/support/task_dirs.rb: a tasks' folder of its own, its tasks stopped and their exit-status recorders joined
   with `TaskRuntime.quiesce!`), a `stop` that joins (`IdleScheduler#stop`). Never only `Thread#kill`.
4. **"Nothing happens" is shown by counting passes** (the worker's loop rounds, spec/support/worker_loop_rounds.rb;
   a class's ticks), not by a pause.
5. **A wall-clock bound** only as "not the full N s", with at least 5× headroom measured on the slow (x86) laptop.

The helpers are the bundle test kit's (`Samagotchi::Testing::Waiting`, [plugins.md](plugins.md#testing-a-bundle-experimental)),
so core and bundle specs share one copy; `SpecWaiting` (spec/support/waiting.rb) includes them in every example
group and also answers them as module calls (`SpecWaiting.pop!`, for a stubbed lib thread):

- `wait_for(what, timeout: 5, interval: 0.01, seen: nil) { … }` returns the block's first truthy value, or raises
  `Waiting::TimedOut`. `seen:` (a callable) shows what the condition last saw, since a falsy block value tells
  nothing.
- `join!(thread, what, timeout: 5)` and `pop!(queue, what, timeout: 5)`: `Thread#join` and `Queue#pop` with the
  same deadline and message. A gate a stubbed lib thread waits on takes `timeout: 30`: it only ends a hang.
- `wait_until(timeout:) { … }` returns the block's last value (falsy at the deadline): for a value the example
  checks after, or a `wait-ok` wait.
- `eventually(timeout: 5) { expect(…) }` (spec only) retries until the expectations hold, then re-raises the last
  failure prefixed `still failing after 5 s:`, so the matcher's own expected/got is in the message.

One formatter builds the failure text of `wait_for`, `join!` (which adds "to finish") and `pop!`:

```
timed out after 5 s waiting for task 20261023-0a1b to end
timed out after 10.0 s (5 s × SPEC_TIME_SCALE 2) waiting for task 20261023-0a1b to end; last saw: "running"
```

**`SPEC_TIME_SCALE`** (default 1, at least 1; CI's `rspec`, `rspec-macos` and `bundles` jobs set 2) multiplies
every helper deadline, explicit `timeout:` values included: a positive wait only gets more headroom, and a passing
run is no slower. Set it locally to reproduce a CI timing (`SPEC_TIME_SCALE=2 bundle exec rspec FILE`). It does not
scale the lib's own timeouts a spec passes in (`wait: 0.05`, `grace: 0.1`): those are the code's deadlines, and a
flaky one gets a `clock:` seam instead. A helper's own spec pins the scale (stub `Waiting.time_scale`). Keep
explicit helper timeouts at 30 or below: 60 s on CI, under the per-example limit.

Every example also runs under a 120 s limit (`spec_helper`'s `around`; `integration`, `macos_build`, `warmup` and
`recap` examples are exempt), so a hang fails its example instead of the run. `SPEC_EXAMPLE_TIMEOUT=N` changes the
limit, `0` turns it off (a debugger session). The limit is not scaled.

**The cops.** `Samagotchi/SpecSleep` (an untagged `sleep` in a spec) and `Samagotchi/SilentWait` (a `wait_until`
whose value is dropped, an example's last line included, `expect(wait_until { … }).to be(true)`, or an untagged
`Timeout.timeout`) live in `rubocop/` and run in `rake lint`, so CI fails on them. RSpec counts `wait_for`,
`eventually`, `join!` and `pop!` as an example's expectation (`RSpec/NoExpectationExample`), so a wait can be an
example's last line. What the cops can't see, `script/affected-specs` hints at (`timing:`, below).

### Flakes

When `parallel_rspec` fails in CI's `rspec` or `rspec-macos` job, the next step (`script/rerun_failures.rb`) reruns
only the failed examples, once, with plain `rspec`. It reads their ids from `tmp/parallel_failures.log`
(`.rspec_parallel`'s `FailuresLogger`) and writes the job summary: **Flaky: passed on rerun** or **Failed twice**,
with the example ids, the Ruby version and the job. It skips the rerun when no ids were logged (a load error) or more
than 20 failed (a real breakage). The job fails either way: a flake is a bug to fix, not a pass. The `bundles` job
does the same after `rake bundles:specs`: that run writes rspec's `--format json` report to
`tmp/bundle_failures.json` (the failed examples' ids and full descriptions, as the main suite's summary has), and the rerun (`--rspec`) runs on the bundle test kit alone, as the specs ran.

Every flake is classified into one of the four patterns, each with its own fix:

1. **A settle sleep**: the spec paused for "long enough". Wait for the condition (`wait_for`, `eventually`).
2. **A live loop racing the spec's own drive of it** (a worker loop, a scheduler tick the spec also calls). Count
   passes, or stop the loop before driving it by hand.
3. **Teardown before background work stops**: a thread, task or process still running when the example's `after`
   removes its folder. Stop it and wait for it (`join!`, `with_task_dir`, a joining `stop`).
4. **A lib deadline on the real clock** (`wait: 0.05`, `grace: 0.1`) too short on a loaded runner. Give the class a
   `clock:` / `sleeper:` seam and move the clock in the spec.

A second flake of the same pattern at a new site means that pattern needs a seam in lib there (for example an `on_*:`
callback the spec can wait on), not another local fix in the spec.

## Bundle specs: the test kit

A shipped bundle's plugin and hook files are tested through the bundle test kit (`samagotchi/testing`,
[plugins.md](plugins.md#testing-a-bundle-experimental)): `shipped_bundle("check-in", settings: …)` loads it through
chi's own loaders, registries, `ctx` and guardrail Gate, with the session, the hook helpers and `ctx.sessions`
recorded. No fake `chi` or `ctx`: what the kit can't express is a kit change (with a kit spec), not a local fake.

These specs live **next to the bundle**, in `lib/samagotchi/bundles/<name>/spec/` (their fixtures in its
`spec/fixtures/`), and require only `samagotchi/testing/rspec` (tagged `:bundle` by their path): no `spec_helper`, no
`spec/support`, as an external bundle's specs would run. `rake bundles:specs` runs them that way
(`rspec --options /dev/null -r samagotchi/testing/rspec`), in CI's bundles job; the full suite runs them too, under
`spec_helper`, given both roots (plain `rspec` runs `spec/` only: `.rspec` holds no `--pattern`, which would make
`rspec FILE` run everything). They are never shipped: the gem and an install leave `spec/` out, and the release
tools' version check ignores a bundle's `spec/` (a spec-only change needs no bump). A spec that runs real turns
(install → Engine → `run_turn`) stays in `spec/samagotchi/plugin/<name>_bundle_spec.rb`.

The kit's own specs, in `spec/samagotchi/testing/`, keep it and the bundles honest:

- `spec/samagotchi/testing/contract_spec.rb`: the kit sets every `Plugin::Host` and `Hooks::Runtime` member,
  `Testing::Sessions` has `Plugin::Sessions`' methods and parameters, and each `ctx` helper lands in its recorder. A
  member added to the Host fails it until the kit has it.
- `spec/samagotchi/testing/shipped_bundles_spec.rb`: each shipped bundle with a plugin or hooks registers the same
  commands, tools, hooks, inits, toolkits and sources loaded by the kit as installed and loaded by chi
  (`Testing::Install`).
- `spec/samagotchi/bundle_command/check_spec.rb`: `chi bundle check` passes every shipped bundle with no errors (one
  example per bundle), so a shipped bundle that wouldn't install or load cleanly for a user fails here too. Run it
  by hand on one with `ruby -Ilib bin/chi bundle check lib/samagotchi/bundles/NAME`.
- `spec/samagotchi/testing/boundary_spec.rb`, the boundary lint: each bundle's Ruby (plugin, hooks, scripts, specs)
  reaches chi only through `Samagotchi::Testing::Boundary::ALLOWED` (the "Stable for bundles" list) and that
  bundle's `Boundary::EXCEPTIONS` entry, each with why. A new internal reference fails it, and so does an exception
  no longer used. Fix the reference (the kit or a stable API), or add the exception with its why.

## Guardrail cases corpus

`spec/fixtures/guardrails/cases.jsonl` holds one labelled tool call per line, run by
`spec/guardrails/cases_corpus_spec.rb` against a fixed rule set (`spec/fixtures/guardrails/rules.yml`) or the
shipped guardrails bundle's rules. A case:

- `id` (required, unique, kebab-case), `tool` (required: `execute`, `task_create`, `write`, `edit` or `read`),
  `command` (a shell tool) or `path` (a file tool), `cwd` (optional: the call's `cwd:`, relative to the spec's
  temp repo), `expect` (required), `rule` (a rule id), `rules` (optional: `fixture`, the default, or
  `guardrails-bundle`), `source` (required: where the case came from: `heredoc-fp`, `heredoc-bypass`,
  `chi-answer-piped`) and `note` (optional: why the label is what it is).
- `expect` is one of two kinds: `match` / `no_match` say whether rule `rule` matches the call (`Rule#matches?`),
  and `allow` / `ask` / `deny` the whole rule set's decision (`Rules#check`, not the Gate's core checks); with
  `rule` given, an ask or deny must also be decided by that rule.

Add a case with every guardrail false positive or miss you fix, under the `source` it came from. Never relabel
a case to make a spec pass: a case that goes red means the code is wrong. The spec also keeps the corpus
well formed (unique ids, known keys and labels, a rule that exists in its set).

## While you work: affected specs

```sh
script/affected-specs                 # the specs for this branch's change, best first, at most 10
bundle exec rspec $(script/affected-specs)
script/affected-specs --why           # with the reason for each pick; --all: no cap; --run: runs them
script/affected-specs A..B            # another range (A...B: from their merge-base); a single REV: vs the working tree
```

A builder runs these while working, not the full suite: the specs the change touched, the specs named after the
files it changed (`lib/samagotchi/foo/bar.rb` → `spec/foo/bar_spec.rb`, `bar_*_spec.rb`…), the specs that read
docs or source as text (its `RULES`: add one when a full run catches what the names missed) and the golden of a changed
file's layer (any `terminal_ui/*.rb` → `spec/terminal_ui_golden_spec.rb`; `turn_flow.rb` and `turn_note.rb`, whose
words the REPL prints, pick it by a rule), then the other name matches (a spec named after several changed files first, e.g. `engine_toolkit_spec.rb` for `engine.rb` and
`toolkit.rb`; then one beside the file, so `plugin/context.rb` picks `spec/samagotchi/plugin/*context*` before
`spec/guardrails/context_spec.rb`), then the specs that name a changed file's class. The default range is the merge-base with main (or origin/main) plus uncommitted and untracked files.
The Ruby specs go to stdout; the node tests to run (`npm test` targets), "web changed: also run npm run e2e" (with `npm run lint` too when a frontend module changed) and a
hint for a hub class (named in too many specs to list) go to stderr, and so do the `timing:` hints, from the lines a
changed spec adds (`git diff -U0` against the base; an untracked spec, all its lines): a `Thread.new`, `.start`,
`spawn` or `fork` with no `join!`, `wait_for`, `with_task_dir` or `Process.wait` added in the same file, and a
sub-second `be < 0.x` bound ([Waiting and time](#waiting-and-time), rules 3 and 5). Nothing printed means nothing
matched.

It finds a change's own specs, not the regressions it causes elsewhere. So before committing, run the full suite
(`bundle exec parallel_rspec -n 8 spec lib/samagotchi/bundles/*/spec`), unless your task says the coordinator runs it; the coordinator runs it at merge
either way.

## Worktrees

Each fix or feature gets its own worktree next to the main checkout:

```sh
script/worktree NAME [-b BRANCH]   # ../samagotchi-NAME off main, branch NAME unless -b; prints the path
```

It runs `git worktree add ../samagotchi-NAME -b BRANCH main`, then `npm ci --prefer-offline` in it, so
`npm test` and `npm run e2e` work there right away (Ruby gems and Playwright's browsers are shared: nothing else
to install). It refuses when the folder or the branch already exists.

## The desktop helper's build specs

`SAMAGOTCHI_MACOS_BUILD=1 bundle exec rspec spec/desktop` also compiles the macOS helper (`:macos_build`, needs the
Command Line Tools) and runs `ChiHelper` against a fake kitty and, when a `tmux` is on PATH, a real one (private
`-L` servers under a temp `TMUX_TMPDIR`, killed after). Without the variable they are filtered out (CI's runs), and
`script/affected-specs` doesn't pick them for a Swift change: run them by hand after editing
`lib/samagotchi/desktop/macos/`.

## Integration specs

Examples tagged `:integration` (`spec/integration/`, the "with LLM access" part of `spec/hooks/integration_spec.rb`)
run turns against a live model server. They are filtered out unless `SAMAGOTCHI_INTEGRATION=1` is set (a file of
them run alone prints "All examples were filtered out"; `--tag integration` without the variable selects them, and
they skip), and they need the server and the model it serves:

| Variable | Meaning | Default |
| --- | --- | --- |
| `SAMAGOTCHI_INTEGRATION` | `1` runs them | off |
| `SAMAGOTCHI_INTEGRATION_HOST` | model server host | `localhost` |
| `SAMAGOTCHI_INTEGRATION_PORT` | model server port | `8080` |
| `SAMAGOTCHI_INTEGRATION_MODEL` | the served model id | none: the examples skip |
| `SAMAGOTCHI_INTEGRATION_API` | `openai` for the chat loop (`hosts.<name>.api`) | none: the native loop |

They run under a config built from these variables alone (`default.model`, `server.host`/`port`, and one
`hosts.integration` entry; `spec/support/integration_server.rb`), never your `~/.config/samagotchi/config.yml`: no
aliases, memories, hooks, guardrails or other hosts of yours. Sessions and logs go to the suite's temp state folder.

Run them one at a time (plain `rspec`, not `parallel_rspec`): each example is a real model turn, and the server may be
shared.

```sh
SAMAGOTCHI_INTEGRATION=1 \
SAMAGOTCHI_INTEGRATION_HOST=192.0.2.10 SAMAGOTCHI_INTEGRATION_PORT=8081 \
SAMAGOTCHI_INTEGRATION_MODEL=org/Model-GGUF:Q4_K_M \
bundle exec rspec --tag integration spec/integration spec/hooks/integration_spec.rb spec/integration_config_spec.rb
```

A run takes one to four minutes against a 35B MoE model on llama.cpp (25 examples). `ECONNREFUSED` means the server is down. The
examples assert what the model did (the tool it called, the file it edited), not its wording, but they still depend on
a model that follows tool instructions: a small model may fail some of them.

## The llm_context replay benchmark

`ruby script/llm_context_bench.rb SESSIONS_DIR` replays stored sessions offline and scores the LLM context
strategies (freed tokens, wrongly forgotten outputs, one-step re-reads, re-prefilled tokens; for `forget_outputs` a
model's answers to chi's offer, with its call rate and notes). It is opt-in: the suite
runs its code only on small synthetic sessions, never on yours. See
[internals/llm-context-bench.md](internals/llm-context-bench.md). `script/llm_context_live.rb` runs chi itself on
real tasks under each strategy (needs a model; costs tokens): [internals/llm-context-live.md](internals/llm-context-live.md).

## The model notes report

`ruby script/model_notes_report.rb` reads a sessions folder (`--sessions DIR`, else chi's own) and groups the
sessions by model and by the model notes their prompt carried (the session file's `prompt_notes`, as
`name@digest`; `none` without notes, or in a file from before they were recorded). For each session and group it
prints the numbers a model note is meant to move: the place of the first edit (an `edit` or `write` call) and of the
first commit (an `execute` call that runs `git [options] commit`) among the tool calls, commits per 100 steps (model
requests), `execute` calls with a bare `&`, the longest run of calls with no edit, and what the session needed from
outside: Continues (the step-limit Continues: the turns in its `analytics.json` marked `resumed: true`, the mark a
file written after 2026-10-11 carries; a file from 2026-10-09 on has `continue: true` only, which a reminder's and a
wake's turn carry too, and that is counted instead, record by record in a file that spans both; an older file has neither, and its turns with no prompt of their
own are counted), steers (lines that reached a
running turn from the user, `chi send` or a parent, and a Continue's text), follow-up prompts and plugin nudges. A
group has the medians of the places and runs, commits per 100 steps pooled and the counts summed. `--help` defines
each column; `--model GLOB`, `--since DATE` and `--min-steps N` filter, `--json` gives JSON. It reads only and prints
no session text (ids, model names, note names and digests, dates, numbers), and the suite runs it only on small
synthetic sessions. It is how a note is judged on and off (`chi --mute model_notes_<name>`) for the same kind of
task: see [memory.md](memory.md) ("Model notes").

## Dependency check

`bundle exec rake deps:check` says what our dependencies did since the last check; `rake "deps:check[json]"` gives
the same as JSON. It reads only and always exits 0: it informs (a tech-debt audit round runs it first, and its NEW
lines go into that round's follow-ups), it doesn't gate, and CI doesn't run it. Three sections:

- **Engines:** each `hosts:` entry of your config.yml on a loopback or private address (an IP, `localhost`, a
  single-label name or `.local`/`.lan`/`.internal`/`.home.arpa`; a public API is never probed) gets `/props`
  (`build_info`: llama.cpp) and `/status` (`identity` and `chat_template`: Splash), 2 s each. A host that doesn't
  answer prints "down, skipped"; one that is neither is left out. Each line carries the newest upstream release
  (GitHub, no auth) with its URL, for a model to read the notes: llama.cpp's newest `b<N>` tag and how many builds
  behind the host is, Splash's newest release.
- **Ruby gems:** `bundle outdated --only-explicit` (direct dependencies, with the Gemfile's requirement).
- **npm:** `npm outdated` (direct) and `npm audit`'s advisories by severity.

A section that can't be read (offline, a GitHub rate limit) says why and the others go on. What a run saw goes to
`$XDG_STATE_HOME/samagotchi/deps-check.json` (`~/.local/state/...`; `DEPS_CHECK_STATE` overrides it), outside the
repo since the engines are this machine's; the next run prints `NEW` on each line that changed since (the first run:
all), NEW lines first in each section.

**The Splash version** isn't in Splash's `/status`, so you record it: read `splash --version` on the engine host,
then `rake "deps:splash_version[1.3.2]"` (every Splash host) or `rake "deps:splash_version[host:port,1.3.2]"`. It is
kept with the build id `/status` shows (`identity.cache.build_id`); when that changes, the check asks you to confirm
the version and record it again. This step goes once a Splash release carries its version in `/status`.

The code is `script/deps/deps_check.rb`; its spec stubs every request and command (`spec/deps_check_spec.rb`).
