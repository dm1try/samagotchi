# Testing

```sh
bundle exec parallel_rspec -n 8 spec lib/samagotchi/bundles/*/spec   # Ruby specs, both roots, in parallel
bundle exec rspec spec lib/samagotchi/bundles/*/spec                 # the same, plain
bundle exec rake bundles:specs    # the shipped bundles' own specs, on the bundle test kit alone
npm test                          # web frontend specs
npm run e2e                       # web UI happy paths in Chromium, fake model (once: npx playwright install chromium)
npx playwright test spec/e2e/stage.spec.js   # one e2e file (the root playwright.config.js is the suite's)
bundle exec rake lint             # RuboCop: no offenses (CI runs it)
```

Run `bundle exec rubocop -a` on the files you changed before committing: every enabled style cop follows the
code's own style and has a safe autocorrect, so `-a` fixes them. What it leaves is a Lint finding (a possible
bug) or a broken spec: fix it, or disable that line with the reason (`# rubocop:disable Cop -- why`).
`.rubocop.yml` says why each cop that is off is off.

No spec reads your own setup. The suite points `XDG_CONFIG_HOME` and `XDG_STATE_HOME` at temp folders,
clears your `SAMAGOTCHI_*` environment, and keeps every spec off the network (WebMock).

Goldens (`*_golden_spec.rb`, the prompt snapshots) hold no machine state, so they pass on any runner: no absolute
paths (replace them with placeholders), no PATH tools (the suite pins `rg` as found, `spec_helper.rb`; an example
that sets PATH to test the lookup is tagged `:real_rg`), no Ruby-version-dependent `inspect` (a Hash's or an
exception's text changes between Ruby versions: write the string yourself).

The web specs run in plain node. One that loads lit-html, itself or through a module it imports (`turn_view.js`,
`turn_html.js`, `card.js`, `copy.js`, `images.js`, `scope.js`, `command_view.js`, `diff_view.js`, `read_view.js`,
`question_cards.js`, `stream_handlers.js`, `stage_view.js`, `bubbles.js`, `cards_place.js`, the chips, `info_bar.js`, `info_bar_model.js`, `lists_view.js`, `context_chips.js`, `families_view.js`,
`chains.js`, `unqueue.js`, `toasts.js`, `notice_links.js`, `start_page.js`, `session_actions.js`, `send_turn.js`,
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

A spec that waits for something uses `wait_until(timeout:)`, or `wait_until!(what, timeout:)` where no check
follows (stubs, helper threads: it raises "timed out after N s waiting for <what>") — never a loop with no deadline.
Every example also runs under a 120 s limit (`spec_helper`'s `around`; `integration`, `macos_build`, `warmup` and
`recap` examples are exempt), so a hang fails its example instead of the run. `SPEC_EXAMPLE_TIMEOUT=N` changes the
limit, `0` turns it off (a debugger session).

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
The Ruby specs go to stdout; the node tests to run (`npm test` targets), "web changed: also run npm run e2e" and a
hint for a hub class (named in too many specs to list) go to stderr. Nothing printed means nothing matched.

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
`-L` servers under a temp `TMUX_TMPDIR`, killed after). CI skips them, and `script/affected-specs` doesn't pick them
for a Swift change: run them by hand after editing `lib/samagotchi/desktop/macos/`.

## Integration specs

Examples tagged `:integration` (`spec/integration/`, the "with LLM access" part of `spec/hooks/integration_spec.rb`)
run turns against a live model server. They are skipped unless `SAMAGOTCHI_INTEGRATION=1` is set, and they need the
server and the model it serves:

| Variable | Meaning | Default |
| --- | --- | --- |
| `SAMAGOTCHI_INTEGRATION` | `1` runs them | off |
| `SAMAGOTCHI_INTEGRATION_HOST` | model server host | `localhost` |
| `SAMAGOTCHI_INTEGRATION_PORT` | model server port | `8080` |
| `SAMAGOTCHI_INTEGRATION_MODEL` | the served model id | none: the examples skip |
| `SAMAGOTCHI_INTEGRATION_API` | `openai` for the chat loop (`hosts.<name>.api`) | none: the native loop |
| `SAMAGOTCHI_INTEGRATION_TRANSPORT` | `llama_cpp`, `mlx` or `omlx` (`server.transport`) | none: `llama_cpp` |

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

`spec/integration/omlx_spec.rb` tests oMLX's model-id resolution and runs only with
`SAMAGOTCHI_INTEGRATION_TRANSPORT=omlx`, against an oMLX server (a short model selector in
`SAMAGOTCHI_INTEGRATION_MODEL`).

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
