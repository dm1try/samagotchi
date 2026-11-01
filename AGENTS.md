# AGENTS.md

## Project Overview: Samagotchi
Samagotchi is an agent harness which heavily relies on memory. It runs each session's Engine in a background Worker that terminals (TerminalUI) and the browser (`chi web`) reach through the worker's Bridge, using project/system memories for long-term state.

Naming note: Samagotchi is the full engine name. Chi (pronounced "chee") is the friendly shorthand used in conversational and CLI contexts.

## Architecture

Samagotchi is split into a core **Engine** (`lib/samagotchi/engine.rb`) and a
**TerminalUI** (`lib/samagotchi/terminal_ui.rb`); see `docs/architecture.md`.
- `Engine` owns all agent logic: system prompt, memory injection, tool declarations,
  session lifecycle, and the model↔tool loop (`Engine#run_turn`). No terminal coupling.
- A session's **Worker** (`lib/samagotchi/worker.rb`) builds its `Engine` and runs it with
  the session's **Bridge** (`lib/samagotchi/bridge.rb`, a localhost SSE + HTTP surface);
  `SessionManager` forks/spawns the workers. `chi web` (`Web::App`) is the browser's control
  plane over the workers' Bridges and the session files.
- Interactive `bin/chi` runs **attached** by default (`session.shared: true`;
  `LaunchMode.resolve`): `TerminalUI::AttachLauncher` finds or starts the worker and
  `TerminalUI::AttachedLoop` is a client of its Bridge, with no `Engine` in the terminal.
  `--no-shared`, `--non-interactive` and `--verbose` run the in-process REPL instead:
  `TerminalUI` owns the REPL (Reline), rendering and REPL commands, and delegates all core
  work to its own `Engine`.
- The `on_event:` seam on `run_turn` exposes raw `KernelLoop` events plus higher-level
  `:turn_started` / `:turn_completed` / `:turn_canceled` events, so any new UI can render
  without terminal coupling.

## CLI Usage (`bin/chi`)
The flags, subcommands and REPL commands are in `docs/cli.md` (its Flags table and Entrypoint scenarios are the
reference); a subcommand's class is `XCommand` under `lib/samagotchi/` (`chi home` is `HomeCommand`). What an agent gets wrong without being told:
- In REPL mode `TerminalUI#run` is the single dispatch for the REPL, `-p`/`--prompt`, `--non-interactive` and
  `--resume`; attached (the default), `-p` and `--resume` go to `TerminalUI::AttachLauncher`. `-p` **feeds and runs**
  the prompt and, without `--non-interactive`, **stays in the session** (the attached TUI; the REPL with
  `--no-shared`). `--non-interactive` is one turn then exit; bare, it is a no-op that creates no session.
- Flags that shape a *new* session (`--memory`, `--mute`, `--toolkit`/`--tool`/`--no-tool`, `--append-system-prompt`,
  `--set`) are saved in it at creation and ignored with `--attach`/`--resume`; `--model` is for this run only,
  `--thinking` and `--llm-context*` are the session's own, saved. Saved means a respawn, a fork and a continue keep
  them (a toolkit is never re-resolved from config).
- `--remote NAME` / `CHI_REMOTE` (the flag wins) runs the session commands (`send`, `answer`, `note`, a session's
  `context`, `sessions list/stop/restart/archive/unarchive/delete`, `share`, `review`) and, with `--attach`,
  `--resume` or `-p`, the TUI against another machine's chi web (`SessionAccess::Remote`/`Dispatch`,
  `RemoteAttachCommand`, branched in bin/chi after `RunOptions.parse`); what `SessionAccess::Contract` lists as
  local-only (`Contract::RUN` for the run flags) exits 2; `--dir` is remote-only. See docs/cli.md (Remote sessions),
  docs/internals/remote-sessions.md.
- `chi share` (the owner inviting participants) makes `Web::Grants` grants (`chp_` tokens, one session, digest-only) that reach only that
  session's `:participant` routes through chi web; `ParticipantMode.of` decides what their turn is: a read-only
  review turn (`Guardrails::ReviewBoundary`) or, for a grant stamped `mode: pair` at invite, a pair turn under the
  owner's guardrails (`Guardrails::PairBoundary`). `chi review` starts a review session (`ReviewStart`; subjects checked
  by `Guardrails::ReviewPaths`; the owner's Apply is `ReviewApply`). **Code and docs say "participants" / "review" /
  "pair", never "shared"** (`session.shared` already means attached by default). See docs/cli.md (Participants),
  docs/sessions.md (Review sessions), docs/internals/participants.md.
- `chi web --tunnel tailscale` (`Web::Tunnel::Tailscale`) never uses Funnel and never writes config.yml. Specs reach
  no real `tailscale`: `spec_helper` points `SAMAGOTCHI_TAILSCALE_CLI` at a missing file (docs/testing.md); the
  command is in docs/configuration.md (Tailscale Serve).
- Other commands are in docs/cli.md: `chi web --start-dir`, `chi web push`, `chi guardrails replay`, `chi toolkit
  report`, and `chi home` (`ChiHome`: the Ruby every chi launch boots, never `GEM_*` in an env; docs/architecture.md
  "How chi launches itself").
- Which loop runs is the host's `api:`: docs/cli.md, "Which loop runs".

## Core Principles
- **Memory-Centric**: The harness relies heavily on memory (project/system scopes) for persistent cognition; tools operate on code/memories but the core is not self-modifying.
- **Persistent Cognition**: Use project memories (`~/.config/samagotchi/memories/projects/<name>_<hash>/`, one per git repository, shared by its worktrees) and system memories (`~/.config/samagotchi/memories`) for long-term state.
- **Single Mode (Assist)**: The harness currently runs in **Assist Mode** only (human-AI collaboration). Persisted state lives in memories; see Memory Scopes.

## Operational Instructions
- **Validate with specs, in this order**: while working, `script/affected-specs --run` (`--why` says why each was picked; it also names the `npm test` targets and when to run `npm run e2e`). Before committing, the full suite (`bundle exec rspec spec lib/samagotchi/bundles/*/spec`: the shipped bundles' own specs are a second root; `npm test` and `npm run lint` too for web frontend changes — files under `lib/samagotchi/web/public/` and `spec/web/public/`; `npm run e2e` for the web UI's happy paths), unless your task says the coordinator runs it. Failing specs must be fixed before committing. See docs/testing.md.
- **Run `bundle exec rubocop -a` on changed Ruby files before committing**; `bundle exec rake lint` must report no offenses (CI runs it). An offense `-a` doesn't fix is a Lint finding or a broken spec: fix it, or disable that line with the reason. See docs/testing.md.
- Keep requests prompt-cache friendly: volatile content last, history append-only, deterministic order. See `docs/internals/prompt-caching.md`.
- Use memory scopes explicitly: `memory_read` may omit scope (project -> system fallback), while `memory_write` must provide `scope` (`project` or `system`).
- `memory_write` accepts an optional `description` (and its scoped `index.md` is auto-maintained). The entry name is passed via the `name` parameter (not `path` — the file tools use `path`). Each entry is written as a managed line — `- **name** · scope · date · size — description` — with every other line preserved byte-for-byte.
- `memory_write` also accepts `current_model_only: true` to save a model-specific overlay (`<name>.<model-key>.md`) that is auto-appended when read under that model. See `docs/memory.md`.
- When adding new capabilities, update the relevant tools in `lib/samagotchi/tools/`.
- Prefer `execute` for short commands and `task_create`/`task_wait` for long-running commands; an `execute` still running at its limit (120 s) is handed over as a task (its `task_id` is in the result) rather than killed. Use `task_get`/`task_list` for nonblocking status checks and `task_stop` to stop a task.
- Let `task_wait` return its timeout tail before separately reading a task `output_path`; use `done_pattern` when the command emits a reliable completion marker.
- Sessions are file-based (`~/.local/state/samagotchi/sessions/<uuid>.json` + sidecar). Retention is 14d/500 (env `SAMAGOTCHI_SESSION_RETENTION_DAYS`, `SAMAGOTCHI_SESSION_MAX_COUNT`), `updated_at desc` by default, lazy sweep at most once per `session.sweep_interval_hours` (default 24) from `chi web`'s session hub tick (and on `GET /api/sessions`); manual via `bin/chi sessions {list,prune,clean} --dry-run`. Use `XDG_STATE_HOME` for isolated test runs; `test_run` flag auto-set when `SAMAGOTCHI_ENV`/`RACK_ENV`/`CI`.

## Where to read before changing a layer
- Engine, turn loop, KernelLoop/ChatLoop, tool dispatch → `docs/internals/engine.md`; components, Worker, web → `docs/architecture.md`
- The Bridge (routes, SSE replay and `reset`, `TurnAccumulator`, `CardStore`, `SSEWriter`, the secret) → `docs/internals/bridge.md`
- System prompt order, request layout, prompt caching → `docs/internals/prompt-caching.md`
- Anthropic's Messages API (`api: anthropic`: wire translation, dialects, cache breakpoints, thinking replay) → `docs/internals/anthropic.md`
- LLM context strategies (`llm_context`, the forget layer) → `docs/internals/llm-context-forget.md`
- LLM context benchmarks (the offline replay, the live runs) → `docs/internals/llm-context-bench.md`, `docs/internals/llm-context-live.md`
- Context-usage telemetry (`:context_status`, the CONTEXT line) → `docs/internals/context-telemetry.md`
- Attached context (`chi context`, refreshed outside text) → `docs/context.md`; the mechanism (`ContextSources`, poller, absorber, candidates, judge, `ContextMove`, `left.json`) → `docs/internals/attached-context.md`
- The web's working set (stamps, `WorkingSet`, `:working_set_updated`, the overlay) → `docs/internals/working-set.md`
- The web frontend (where page state lives, write → redraw, render idioms, stale-answer guards, storage, streams) → `docs/internals/web-frontend.md`
- Task tools (`task_create`/`task_wait`…) → `docs/internals/background-tasks.md`
- read/execute limits (size, timeout, hand-over) → `docs/internals/tool-output-limits.md`; allow/ask/deny, approvals, rules → `docs/guardrails.md`
- System 1, the approval judge (`lib/samagotchi/system_one/`, `GuardrailWiring#request_approval`, `chi guardrails replay`) → `docs/guardrails.md` (System 1)
- System 1's common layer and saved runs (`SystemOne::Recording`, `Runs`, `RunsStore`, `ApprovalLabel`, `chi judgments`) → `docs/system-one.md`
- Hooks → `docs/hooks.md`; plugins (commands, tools in a bundle, `chi.prompt_section`, `ctx.cache_confirm`) → `docs/plugins.md`; their prompt place → `docs/internals/prompt-caching.md`
- What each shipped bundle does for a user (btw, mcp, cost-cap, work-cap, claude-peer, skills…; the bundles' own settings) → `docs/bundles.md`
- The chi home (`ChiHome`, home.json, `Record#boot_argv`, `chi home`, `HomeDoctor`, `HomeNotice`) → `docs/architecture.md` (How chi launches itself), `docs/configuration.md` (The chi home)
- The project env (`ProjectEnv`, `session.project_env`, the chi shim) → `docs/sessions.md` (Project env); the env tools spawn with → `docs/internals/background-tasks.md`
- Writing a bundle (the walkthrough, `chi bundle new`/`check`/`test`/`try`) → `docs/bundle-authoring.md`
- Toolkits (which tools a session declares, `/toolkit`, `chi.toolkit`) → `docs/configuration.md` (Toolkits); the session field → `docs/sessions.md`
- Bundle install, upgrade and build → `docs/internals/bundles.md`
- Session files, context notes, sending, chains, delegating → `docs/sessions.md`; review sessions (`chi review`, `ReviewStart`, Apply) → `docs/sessions.md` (Review sessions), `docs/internals/participants.md`
- Remote sessions (`chi --remote`, `SessionAccess`, chi web's session routes) → `docs/internals/remote-sessions.md`
- chi web behind an auth proxy (`web.public_url`, `Web::ProxyGate`, identity header + token, Bridges refusing proxy
  traces) → `docs/configuration.md` (Behind an auth proxy); the gate → `docs/internals/participants.md` (The gate)
- Web Push (`Web::Push`, the Notifier, the service worker, the Home Screen app's bell) → `docs/internals/web-push.md`; the user side → `docs/configuration.md` (Phone notifications)
- Participants (`chi share`, `Web::Grants`, the participant gate and routes, review turns, `participants.json`) → `docs/internals/participants.md`; their review boundary → `docs/guardrails.md`
- chi run by another agent (`chi send --wait`, `chi answer`) → `docs/sub-agent.md`
- `chi broadcast` → `docs/broadcast.md`
- macOS desktop helper → `docs/desktop.md`
- Memory scopes, tools, overlays, model notes, skills, bundles' memories → `docs/memory.md`
- Settings, config.yml, env vars → `docs/configuration.md`
- CLI commands and REPL → `docs/cli.md`
- Gemma 4 native tool calls and thought context → `docs/internals/gemma4-contract.md`
- Specs, affected specs, lint, worktrees → `docs/testing.md`
- Versions, bundle versions, release runbook → `docs/releasing.md`

## Releases
Releases follow `docs/releasing.md`: versioning (gem == system bundle; other bundles bump their own version), CHANGELOG rules, and the runbook (`rake release:draft_changelog` → the user approves → `rake release:bump[X.Y.Z]` → `rake release:check` → tag `vX.Y.Z` → GitHub Actions publishes). Never publish or push a tag without the user's OK.
