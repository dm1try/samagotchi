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
In REPL mode `TerminalUI#run` is the single dispatch for the REPL, `-p`/`--prompt`,
`--non-interactive` and `--resume`; attached (the default), `-p` and `--resume` go to
`TerminalUI::AttachLauncher`. Flag semantics (also in `docs/cli.md`):
- `-p`, `--prompt TEXT`: feed `TEXT` as the first turn — feeds **and** runs it.
- `--non-interactive`: run one turn then exit (high iteration cap; implies `--no-interrupt`).
  A harmless no-op when given without `-p` (no session created).
- `--resume SESSION_ID`: load a prior session's history instead of creating a fresh one;
  composes with `-p` (prompt runs on the resumed session, prior history preserved as context).
- `-p "..."` alone (no `--non-interactive`) runs one turn and **stays in the session**: the
  attached TUI by default, the REPL with `--no-shared`.
- `--remote NAME` (before the subcommand; or `CHI_REMOTE=NAME`, the flag wins): the session commands
  (`send`, `answer`, `note`, a session's `context`, `sessions list/stop/restart/archive/unarchive/delete`, `share`,
  `review`)
  against another machine's chi web (`SessionAccess::Remote`, `SessionAccess::Dispatch`); what
  `SessionAccess::Contract` lists local-only exits 2. `chi remote add|ls|rm` keeps the remotes
  (`$XDG_CONFIG_HOME/samagotchi/remotes.yml`, 0600). See docs/cli.md (Remote sessions).
- `chi share ID --name NAME [--identity EMAIL] [--agent] [--expires 3d] [--cap 2]` / `share ls [ID]` / `share cap ID P DOLLARS` /
  `share revoke ID [P] | --all` (local or `--remote`): a session's participants, each a `Web::Grants` grant (a `chp_`
  token for one session, digest-only, 7 days, a $2 cap, revoked on archive/delete; `--identity` binds it to one
  account behind an auth proxy that names the user, refused elsewhere) that reaches only that session's
  `:participant` routes through chi web. Their `POST …/turn` is a queued, read-only review turn
  (`Guardrails::ReviewBoundary`, the reserved `review` kit; no `!`/`/` lines, a turn limit, spend by author). Code
  and docs say "participants" / "review", never "shared". See docs/internals/participants.md.
- `chi review FILE… [--dir D] [--model M]` / `chi review --from ID [FILE…]` (local or `--remote`): a review session
  (`review: {subjects, from}`, `ReviewStart`) to share: its subjects are project files checked by
  `Guardrails::ReviewPaths`, a `--from` fork starts from ID's recap and leaves ID running. Participants read the
  subjects as the Plan (`GET …/review`'s `subjects`); the owner's Apply quotes a review turn's proposal
  (`ReviewApply`, `GET …/apply`). See docs/sessions.md (Review sessions).
- `chi web --tunnel tailscale` (`Web::Tunnel::Tailscale`): Tailscale Serve 443 → chi web's port for this run (never
  Funnel), public_url = this machine's ts.net name, identity `Tailscale-User-Login`, owner `web.proxy.owner` else
  this machine's login; never written to config.yml. Adopts only its own exact handler, refuses anything else on 443,
  turns 443 off on exit only while it is still exactly that. Specs: a fake tailscale via `SAMAGOTCHI_TAILSCALE_CLI`
  (spec_helper points it at a missing file). See docs/configuration.md (Tailscale Serve).
- Also (docs/cli.md): `chi web --start-dir DIR` (config `web.start_dir`: the project chi web's page opens on),
  `chi web push ls|rm|test` (this machine's Web Push devices, `PushCommand`), `chi guardrails replay`
  (`GuardrailsCommand`: seeds System 1's record from the approvals already answered), and
  `chi toolkit report [--days N]` (`ToolkitReportCommand`: grades audit suggestions against session tool calls).
- `--attach ID`: attach to a session's worker (waking one if it has exited);
  `--shared`/`--no-shared` override `session.shared` for this run.
- `--remote NAME` (or `CHI_REMOTE`) before `--attach ID`, `--resume ID` or `-p` (attached only): the TUI on that
  machine's session, through its chi web (`RemoteAttachCommand`, branched in bin/chi after `RunOptions.parse` and
  before the local checks). A new session there needs `--dir DIR` (that machine's absolute path; `--dir` is
  remote-only). `--non-interactive`, `--verbose`, `--no-shared`, `--memory`, `--mute`, `--append-system-prompt`
  are this machine's (exit 2; `Contract::RUN`).
- `--model NAME` (this run, not saved), `--thinking LEVEL` and `--llm-context`
  (`--llm-context-apply`, `--llm-context-budget`): the session's own thinking level and
  LLM context strategy, saved in the session.
- `--memory` / `--mute NAME` (both repeatable): preload a memory into the prompt / hide one
  from the session. `--no-interrupt`, `--no-default-input`, `-v`/`--verbose`, `--help` also
  available; `SAMAGOTCHI_DEFAULT_INPUT` prefill (edit, not run).
  The config.yml `memories:` list is the persistent baseline of preloaded memory
  entries (same name shape as `--memory`); `--memory` values are appended after
  it, deduped.
- `--toolkit NAME`, `--tool NAME` / `--no-tool NAME` (repeatable): a new session's toolkit, the tools its prompts
  declare (`full` by default; config `toolkit.default`, `toolkit.child`, `toolkit.kits`). Saved in the session at
  creation, never re-resolved from config; `/toolkit` changes it from the next turn's start. Ignored with
  `--attach`/`--resume`, like `--memory`.
- `--append-system-prompt FILE` (repeatable): FILE's text goes into the system prompt after the
  AGENTS.md chain (root → cwd); config.yml `append_system_prompt:` is its baseline. Saved in the
  session (kept by respawns, forks and continues); ignored with `--attach`/`--resume`, like `--memory`.
- `--set KEY=VALUE` (repeatable; also `chi send --new --set`): a core key marked session-settable
  (`Config::Entry#session?`: `recap.enabled`, `recap.sentences`; saved as `config_settings`, read first through
  `Config.get(key, session:)`) or `BUNDLE.KEY`: a bundle setting for a new session, a key the
  installed bundle's manifest lists in `session_settings:` (others exit 2). Saved in the session (kept by respawns,
  forks and continues), laid over config.yml's `bundles: <name>:` in `ctx.settings`; ignored with
  `--attach`/`--resume`.
- The loop follows the model's host: a host whose `api:` has a chat adapter
  (`LLM::Adapters::BY_API`) uses the chat loop, `LLM::ChatLoop`: `api: openai` on
  `LLM::OpenAIChat` (`/v1/chat/completions`), `api: anthropic` on
  `LLM::AnthropicMessages` (`/v1/messages`). Every other host runs chi's own
  raw-prompt loop (`KernelLoop`). `--backend` and `SAMAGOTCHI_BACKEND` are gone
  (see docs/configuration.md).

## Core Principles
- **Memory-Centric**: The harness relies heavily on memory (project/system scopes) for persistent cognition; tools operate on code/memories but the core is not self-modifying.
- **Persistent Cognition**: Use project memories (`~/.config/samagotchi/memories/projects/<name>_<hash>/`, one per git repository, shared by its worktrees) and system memories (`~/.config/samagotchi/memories`) for long-term state.
- **Single Mode (Assist)**: The harness currently runs in **Assist Mode** only (human-AI collaboration). Persisted state lives in memories; see Memory Scopes.

## Operational Instructions
- **Validate with specs, in this order**: while working, `bundle exec rspec $(script/affected-specs)` (`--why` says why each was picked; it also names the `npm test` targets and when to run `npm run e2e`). Before committing, the full suite (`bundle exec rspec spec lib/samagotchi/bundles/*/spec`: the shipped bundles' own specs are a second root; `npm test` and `npm run lint` too for web frontend changes — files under `lib/samagotchi/web/public/` and `spec/web/public/`; `npm run e2e` for the web UI's happy paths), unless your task says the coordinator runs it. Failing specs must be fixed before committing. See docs/testing.md.
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
- Engine, turn loop, KernelLoop/ChatLoop, tool dispatch → `docs/internals/engine.md`; components, Worker, Bridge, web → `docs/architecture.md`
- System prompt order, request layout, prompt caching → `docs/internals/prompt-caching.md`
- Anthropic's Messages API (`api: anthropic`: wire translation, dialects, cache breakpoints, thinking replay) → `docs/internals/anthropic.md`
- LLM context strategies (`llm_context`, the forget layer) → `docs/internals/llm-context-forget.md`
- LLM context benchmarks (the offline replay, the live runs) → `docs/internals/llm-context-bench.md`, `docs/internals/llm-context-live.md`
- Context-usage telemetry (`:context_status`, the CONTEXT line) → `docs/internals/context-telemetry.md`
- Attached context (`chi context`, refreshed outside text) → `docs/context.md`
- The web's working set (stamps, `WorkingSet`, `:working_set_updated`, the overlay) → `docs/internals/working-set.md`
- Task tools (`task_create`/`task_wait`…) → `docs/internals/background-tasks.md`
- read/execute limits (size, timeout, hand-over) → `docs/internals/tool-guardrails.md`; allow/ask/deny, approvals, rules → `docs/guardrails.md`
- System 1, the approval judge (`lib/samagotchi/system_one/`, `GuardrailWiring#request_approval`, `chi guardrails replay`) → `docs/guardrails.md` (System 1)
- Hooks → `docs/hooks.md`; plugins (commands, tools in a bundle) → `docs/plugins.md`
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
