# Samagotchi Architecture

A compact visual overview of the current architecture, then the core API in prose
(see [Core and UI](#core-and-ui)).

## System map

```
            bin/chi (CLI entry point)                        bin/chi web
                       │                                          │
  ┌────────────────────┴────────────────────┐    ┌───────────────┴────────────────┐
  │                TerminalUI               │    │        Web::App (Rack)         │  ← browser UI
  │  attached (default): AttachLauncher +   │    │  session hub · /api/events     │
  │    AttachedLoop, no Engine              │    │  /api/* · reads session files  │
  │  REPL (--no-shared …): its own Engine   │    └───────────────┬────────────────┘
  └────────────────────┬────────────────────┘                    │ App#relay, bridge_get,
                       │ BridgeClient (SSE + HTTP)               │ /stream proxy
                       └────────────────────┬────────────────────┘
                                            ▼
                      ┌─────────────────────┴─────────────────────┐
                      │ Worker (one process per session) + Bridge │ ← forked/spawned by
                      │ input queue · idle exit · owner.lock      │   SessionManager
                      └─────────────────────┬─────────────────────┘
                                            │ builds, runs turns
                      ┌─────────────────────┴─────────────────────┐
                      │            Engine (core logic)            │
                      │  system prompt · memory injection         │
                      │  tool declarations · session lifecycle    │
                      │  model↔tool loop — `run_turn`             │
                      └─────────────────────┬─────────────────────┘
                                            │
        ┌───────────────────────────────────┴──────────────────────────┐
        │                                   │                          │
  ┌─────┴──────┐                  ┌─────────┴──────────┐      ┌────────┴─────────┐
  │ KernelLoop │◀──── drives ────▶│     Model API      │      │     Session      │
  │ / ChatLoop │                  │  (LLM HTTP call)   │      │ (state, history) │
  └─────┬──────┘                  └────────────────────┘      └──────────────────┘
        │
        │ run_turn events (turn_started, turn_completed,
        │ turn_canceled, raw KernelLoop events)
        ▼
  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │                                      Tools                                       │
  │  execute · read · edit · write · memory_read/write · web_fetch ·                 │
  │  task_create/get/list/stop/wait · delegate · delegate_result · ask_user_question │
  │  register_reminder/cancel_reminder/list_reminders · send_note · list_sessions ·  │
  │  context_read · forget_outputs · find_tools · call_tool (+ bundle plugin tools)  │
  │  offered by Tools::Registry (Builtins + bundles), filtered by the toolkit        │
  └──────────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │                                   Persistence                                    │
  │   Project:  ~/.config/samagotchi/memories/projects/<repo>_<hash>/ (per git repo) │
  │   System:   ~/.config/samagotchi/memories/                                       │
  └──────────────────────────────────────────────────────────────────────────────────┘
```

## The two-layer split

```
TerminalUI  ──  delegates  ──▶  Engine
(REPL / render / commands)         (pure logic, no terminal)
        ▲                                  │
        └────────── on_event: ◀────────────┘
             (turn_started, turn_completed,
              turn_canceled, raw KernelLoop events)
```

- **`Engine`** (`lib/samagotchi/engine.rb`) owns *all* agent logic and knows nothing
  about the terminal ([internals/engine.md](internals/engine.md)).
- **`TerminalUI`** (`lib/samagotchi/terminal_ui.rb`) owns the REPL and rendering; it
  delegates all core work to an `Engine`.
- The `on_event:` seam on `run_turn` exposes raw `KernelLoop` events plus the
  higher-level turn events, so any new UI can render without terminal coupling.
- **`ComposerRoute`** (`lib/samagotchi/composer_route.rb`) decides where a line typed at
  either terminal's prompt goes (the REPL's `steer_line` / `run_input_line`, the attached
  `AttachedLoop#submit`): `/cut TEXT` / `/queue TEXT`, a terminal's own word, a session
  command, a typo, a prompt. Each UI keeps what it does with the route. The web's
  `composer.js#routeComposerLine` decides the same; `spec/fixtures/composer_routes.json`
  holds the cases both answer (see [testing.md](testing.md)).

## Request / turn flow

```
bin/chi ─▶ TerminalUI ─▶ Engine#run_turn ─▶ KernelLoop / ChatLoop ──┬─▶ Model API (LLM)
        (builds)          │                                         └─▶ Tool call(s) ─▶ Tool
                          │                                              │
                          └── on_event: ─▶ render update ────────────────┘
                                    (turn started / completed / canceled)
```

That is the REPL; attached (the default) the session's `Worker` calls `Engine#run_turn` and the
terminal renders the events it gets over the Bridge.

## Layers at a glance

| Layer | Class(es) | Responsibility |
|-------|-----------|----------------|
| Core | `Samagotchi::Engine` | System prompt, memory injection, tool declarations, session lifecycle, model↔tool loop (`run_turn`). No terminal coupling. |
| UI | `Samagotchi::TerminalUI` | REPL (Reline), rendering, REPL commands. Delegates all core work to an `Engine`. |
| Model loops | `KernelLoop` (via `LLM::NativeBackend`), `LLM::ChatLoop` | The model↔tool loop: raw prompt, or a chat API (OpenAI chat, Anthropic Messages), chosen per host (see below). |
| Adapters | `Samagotchi::Client`, `LLM::OpenAIChat`, `LLM::AnthropicMessages`, `LLM::HTTP` | Raw-prompt servers, the OpenAI chat API, Anthropic's Messages API, and the HTTP they share. |
| Tools | `lib/samagotchi/tools/*` | Execute, read, edit, write, memory, task_*, web_fetch, delegate/delegate_result, ask_user_question, reminders, send_note, list_sessions, context_read, forget_outputs, find_tools/call_tool (the tool index), plus runtime/output-guardrails. |
| Bundles | `lib/samagotchi/memory_bundle/*`, `BundleCommand` | `chi bundle`: install/upgrade (3-way merge), build, uninstall; the install record under `.bundles/<name>/` that the hook, guardrail and plugin loaders read ([internals/bundles.md](internals/bundles.md)). |
| Background | `Samagotchi::Worker`, `Samagotchi::SessionManager` | `SessionManager` forks/spawns one worker process per session; its `Worker` builds the `Engine` and `Bridge` (no terminal rendering) and runs queued turns. The spawned process (own process group) forks the worker, which `setsid`s and is reparented to init once its starter exits (it waits until the worker holds `owner.lock`, so the spawner's `Process.detach` waiter tells a starting worker): nothing that walks the spawner's process tree reaches it (`SAMAGOTCHI_WORKER_DETACH=1`, `detach_from_spawner`). The lock's pid is the worker's; `spawn`'s `child_pid` is its starter's. |
| Web | `Samagotchi::Web::App`, `Samagotchi::Web::Server`, `Samagotchi::Web::SessionHub` | Rack+WEBrick on one port, `127.0.0.1:4567` (index.html + `/api/*` + SSE); with `web.host: lan` also on this machine's LAN address, behind an access token (`Web::Lan`, `Web::Token`). The hub is chi web's projection of the session list, pushed to every tab over `GET /api/events`. |
| Sessions | `Samagotchi::Session`, `SessionManager` | File `sessions/<uuid>.json` + sidecar `input/`/`output/`; retention 14d/500, `updated_at desc`, lazy sweep. |

## Entry points

- `LaunchMode.resolve` picks the terminal's mode. By default (`session.shared: true`)
  plain `bin/chi`, `-p` and `--resume ID` run attached, like `--shared`; `--no-shared`,
  `session.shared: false`, `--non-interactive` and `--verbose` run the REPL. `--memory`
  and `--mute` are session fields (`preloaded_memory_names`, `muted_memory_names`) the
  worker reads when it builds its `Engine`; `MutedMemories` filters the prompt's index and
  the kernel's `memory_read`.
- The REPL → builds `TerminalUI`. `TerminalUI#run` is the single dispatch
  for the REPL, `-p`/`--prompt`, `--non-interactive`, and `--resume`.
- Attached (`bin/chi`, `--attach ID`, `--shared [--resume ID]`) → `TerminalUI::AttachLauncher`: no `Engine`
  and no `OwnerLock`; finds or starts the session's worker and runs `TerminalUI::AttachedLoop`
  as a client of its Bridge (`BridgeClient#follow`, `post_turn`, `post_command`, `cancel`, `answer`,
  `dismiss_question`). The worker runs in the session's `working_directory`, so `!cmd` and
  the tools don't depend on where the terminal attached from.
- `bin/chi web` → builds `Web::Server` (Rack+WEBrick on `127.0.0.1:4567`, `--port`/`SAMAGOTCHI_WEB_PORT`, `--open`;
  `web.host: lan` adds a LAN address, `--new-token` replaces its access token).
- `bin/chi sessions {list,stop,restart,archive,unarchive,delete,prune,clean,stats}` (`SessionsCommand`; not the REPL's `SessionCommands`) → retention & ordering (`SessionRetention`, `updated_at desc`, dry-run, test-only); `stop` is `SessionManager.stop_session(wait:)`, which waits for the worker to release `owner.lock`; `delete` (`SessionDeleteCommand`) is `SessionManager.delete_session(stop:)`, which the TUI's `/exit --delete` and the web's `DELETE /api/sessions/:id` use too.
- Session commands (`chi send`, `answer`, `note`, a session's `context`, `sessions list/stop/restart/archive/unarchive/delete`) →
  `SessionAccess` (`session_access.rb`): what they ask of a session goes through one backend object,
  `SessionAccess::Local` (`session_access/local.rb`) on this machine's files and workers; a `--wait`'s pre-send state
  (cursor, baseline, own turn) is `prepare_wait`'s `WaitStart`. `SessionAccess::Contract` lists which commands and flags
  run against a remote and which on this machine only.
- In REPL mode `TerminalUI` builds the `Engine` in process (`-p` and `--non-interactive` too);
  otherwise the session's `Worker` (`lib/samagotchi/worker.rb`, spawned by `SessionManager`) builds it.

## Session retention & ordering

- **Files:** `~/.local/state/samagotchi/sessions/<uuid>.json` + `<uuid>/input|output|owner.lock|bridge.json` (XDG-aware), and the `<uuid>/stopped` and `<uuid>/archived` marker files.
- **Single owner:** the process running a session's Engine (worker or in-process TUI) holds a flock on `owner.lock` (`OwnerLock`); a second owner backs off, and the web answers 409 for a TUI-owned session.
- **Status:** `status` is turn state (`idle`/`running`); liveness is the lock. A stop is the `<uuid>/stopped` marker (`Session.mark_stopped`; a resume removes it), which `Session.load` and `.summary_from_file` read as status `stopped`, so no other process rewrites a worker's session file.
- **Retention:** 14 days / 500 cap (env `SAMAGOTCHI_SESSION_RETENTION_DAYS`/`MAX_COUNT`, optional `KEEP_STATUS`), live-owner guard, only when `*.json` present; lazy sweep at most once per `session.sweep_interval_hours` (default 24) from the session hub's full-probe tick (and on `GET /api/sessions`, which the page no longer calls), manual via `bin/chi sessions prune --dry-run`.
- **Ordering:** `Session.list(sort:,order:,limit:,offset:)` and `GET /api/sessions?sort=&order=&limit=&offset=` default `updated_at desc`; Web UI sort/filter/pagination.
- **Test hygiene:** `test_run` flag when `SAMAGOTCHI_ENV=test`/`RACK_ENV=test`/`CI`, targetable via `prune --test-only` / `clean`.

## Core and UI

Samagotchi is split into a **core engine** and a **terminal UI**. The core holds all
agent logic and can be used without any terminal rendering; the UI is a thin layer on top.

| Layer | Class | Responsibility |
|-------|-------|----------------|
| Core | `Samagotchi::Engine` | System prompt, memory injection, tool declarations, session lifecycle, the model↔tool loop (`run_turn`). No terminal coupling. |
| UI | `Samagotchi::TerminalUI` | Interactive REPL (Reline), rendering (ANSI, spinner, status line), REPL commands. Delegates all core work to an `Engine`. |
| Model loops and adapters | `KernelLoop`, `LLM::ChatLoop`, `Samagotchi::Client`, `LLM::OpenAIChat`, `LLM::AnthropicMessages`, `LLM::HTTP` | The model↔tool loops and the HTTP adapters they talk through (see "Model loops and adapters"). |
| Bridge (SSE/HTTP) | `Samagotchi::Bridge`, `SessionManager` | The **single live client transport**: an SSE read stream + HTTP POST turn/cancel/answer surface that attaches to a worker's existing `Engine` via `Engine#subscribe`. Every session worker starts it (bound `127.0.0.1`, no auth, localhost-only). |
| Web (Rack) | `Samagotchi::Web::App`, `SessionManager` | Single-port `127.0.0.1:4567` control plane via `rack`+`webrick` (serve `index.html` + `/api/*`). With `web.host: lan` (or one of this machine's IPv4 addresses) the server also listens on that address, where every request but this machine's needs the access token (`App#token_gate`: the `chi_token` cookie or `Authorization: Bearer`; [CLI](cli.md#chi-web-on-your-phone)). Experimental: behind an auth proxy (`web.public_url`, `Web::ProxyGate`) every request needs the token, this machine's too, and one that came through the proxy also the configured identity header for the owner ([configuration.md](configuration.md#behind-an-auth-proxy)). A request goes through, in order: the Host check (`local_host_header?`: loopback names, the LAN address, the public host), the cross-site check (`cross_site?`: Origin this server's or the public origin, no `Sec-Fetch-Site` cross-site/same-site on a POST or `/api`), the frame check (`framed?`: a frame/embed/object load from another origin, 403 `framed`; every HTML answer carries `X-Frame-Options: DENY` and `frame-ancestors 'none'`), the token gate (`token_gate` → `principal_for`, `proxied_principal` for a proxied request; the `?token=` / `POST /api/token` trade sets the cookie, `__Host-chi_token` through the proxy; with `web.public_url` a direct request takes Bearer only, and chi's token-less `/api/info` probe gets `probe_info`), then the route's permission (`Principal#permits?`). It talks to each worker's Bridge (`App#relay`, `bridge_get`; `/stream` proxies it) and reads the session files; no `Engine` of its own. Markdown (`web.markdown`) is rendered here only (`Web::MarkdownRenderer`): the answers it serves, card bodies, and `POST /api/render` for a text the page already shows. `bin/chi web` entrypoint. |
| Sessions | `Samagotchi::Session`, `SessionManager` | File-based `~/.local/state/samagotchi/sessions/<uuid>.json` + sidecar `input/`/`output/`; retention (14d/500) + ordering (`updated_at desc`). |

- `bin/chi` in REPL mode (see `LaunchMode` above) builds `TerminalUI`. `TerminalUI#run` is the single
  dispatch for the REPL, `-p`/`--prompt`, `--non-interactive`, and `--resume`: it
  builds the working session once, runs a single prompt turn when `-p` is given,
  then either exits (`--non-interactive`) or drops into the REPL carrying the
  post-turn conversation.
- A session's `Worker` (spawned by `SessionManager`) builds its `Engine` (no terminal rendering).
- `bin/chi` in attached mode (the default, `--attach`, `--shared`) builds no `Engine`: `TerminalUI::AttachLauncher` finds
  or starts the worker, and `TerminalUI::AttachedLoop` is a client of its Bridge
  (`BridgeClient#follow` for events, `post_turn`/`cancel`/`answer` for input). It
  renders through the same `EventRenderer` as the REPL, on an `AttachedView` that
  draws on a `Screen`: a live region at the bottom of the terminal (activity row,
  prompt, status/notes/hints) under normal scrollback. From a turn's 3rd tool call the
  activity slot gets a second, dim row: the turn's tool tally (`TurnTally`, seeded from the
  snapshot's tool parts on a mid-turn join). Reline still reads the input,
  but `RelineSeam` (prepended to `Reline::LineEditor`) sends its drawing to the
  `Screen`. Without a capable terminal it falls back to `PlainSurface` (append-only).

#### Using the core

```ruby
engine = Samagotchi::Engine.new(model_name: "gemma4", memories: [])
session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd)

engine.run_turn(session, "hello", on_event: nil)   # => LLM::ModelResult (`.output`)
```

#### The `on_event` seam

`run_turn` accepts an optional `on_event:` callable that receives an event stream. It
forwards the raw `KernelLoop` events unchanged (the low-level contract) and adds a few
higher-level events so UIs get clean turn boundaries without inferring them:

- `:turn_started` — `{ session_id:, prompt:, turn_id:, cut_after: }` (`cut_after`: the seconds a cut waits for this
  model's thinking, `0` = never; plus `continue: true` for a continue turn, `resumed: true` for a step-limit Continue,
  `images:` with the prompt's image refs)
- `:turn_completed` — `{ result:, turn_summary:, display_pending: }` (`result`: the final
  `LLM::ModelResult`; Engine event (clients get it without `result`); `display_pending`: `after_turn` hooks may still
  present the answer)
- `:turn_canceled` — `{ cancellation_reason:, cancelled_by:, duration_ms: }` (`cancelled_by`: the bundle or hook label that
  stopped it, for `cancellation_reason: :hook`; else nil)

These are the Engine's raw events. The worker's SSE projection omits `call` from
`:tool_call_started` and `result` from `:turn_completed`; the answer remains in
`turn_summary.output`.

A turn started with `origin:` (a `TurnOrigin`, or its Hash) carries it on each of these (and `:turn_failed`), as
the Hash `{client_id:, enqueued_id:, author:}` with only the fields set (`TurnOrigin#to_h`).

Every event is a `Hash` with a `:type` symbol key; the sink must not raise (the Engine
rescues sink errors). A new UI (web, API) supplies its own `on_event` and
renders whatever it needs from the stream + final `Result`. The public Engine API:

```ruby
engine.run_turn(session, prompt, on_event: nil, max_iterations: nil, cancel_controller: nil, # nil: turn.max_iterations
                max_tool_output_chars: nil, pending_input: nil, continue: false, origin: nil,
                images: [], id: nil, resumed: false, resume_from: nil)   # resumed/resume_from: a step-limit Continue
engine.system_prompt     # fully built system prompt string
engine.session           # current session (Engine owns create/resume)
```

The system prompt (`SystemPrompt#build`, assembled in `#system_prompt_with_index`) is the
base prompt, then the toolkit's "Not loaded in this session" line (only when the toolkit
leaves tools out), rg guidance, the identity, the model notes, the preloaded memories,
AGENTS.md (root → cwd), the appended files (`--append-system-prompt`), the toolkit's
kit prompt (a kit's `prompt:` text, only when it has one), the memory
indexes, and last **the model** (`Model: this session runs on <ref> (host …; model key …)` and a line telling
the model to answer "which model are you" from it, not from training), the working
directory and the session id and log (Gemma's native tool declarations still follow).
The order is for the servers' prompt caches, which reuse only an exact token prefix:
what every session shares first, what changes least before what changes more, the
per-session lines last, so a new session reuses everything above them. It is built
once per loop and thinking level and rebuilt only by a model switch, changed tools or a
toolkit change (`Engine#apply_toolkit!`, at a turn's start), so the model line costs no
KV churn.
The full request layout, what breaks the cache and the rules for changes:
[internals/prompt-caching.md](internals/prompt-caching.md).

#### Subscribing to the live stream (and the bridge)

For an **always-on** consumer (an external SSE client, a second UI), use
`Engine#subscribe` rather than passing `on_event:` to a single turn. It is a thread-safe,
error-isolated fan-out with a monotonic `event_seq` on every event:

```ruby
handle = engine.subscribe(observer: ->(event) { ... })   # observer receives {..., event_seq:}
engine.unsubscribe(handle: handle)
engine.session_state_snapshot   # => { status:, message_count:, last_prompt:, event_seq: }
```

`Engine#subscribe` is the seam the SSE bridge (`Samagotchi::Bridge`) rides on. The bridge
is the **single live transport** and runs **inside the forked session worker** (the same
process that already owns the `Engine`); every worker starts it, and it exposes:

- `GET  /session/:id/stream` — SSE stream of engine + kernel events, each with an
  `id: <event_seq>-<epoch>` cursor (the epoch is drawn per worker's Bridge, since `event_seq` starts
  over in each worker; snapshots and `/state` carry it as `event_id`); resume via `Last-Event-ID` /
  `?from_seq=` (a plain `event_seq` is still accepted); a `: ping` heartbeat keeps idle proxies alive;
  too-old reconnects, and cursors from another worker's epoch, receive a `reset` marker carrying
  `session_state_snapshot`. `?snapshot=1` joins with a snapshot frame instead of a replay;
  `?client_id=` names whose stream it is (`Bridge#open_streams_except`, used by `POST /exit`).
  Each event goes out as clients get it (`Bridge::ClientEvent.project`, in `SSEWriter#write_event`, live
  and replayed alike); `generation_chunk`, `tool_call_started` and `turn_completed` are projected to the
  contracts below. The ring retains raw events for replay and `?raw=1`.
  `?raw=1` writes events as the engine emitted them, for debugging on the worker's port: `chi web`'s
  `/api/sessions/:id/stream` never passes it on (`Web::App#stream_query`).
  An attached terminal's stream (`EventStream` with `rediscover:`) looks for the session's live
  worker whenever it drops: a new one (a restart) is followed from its snapshot, and the terminal
  sends its requests there (`worker_changed`); it gives up after ~12 s, or at once when the session
  was stopped.

  The wire chunk (the contract; the engine's own event keeps the provider's `payload` and the raw `content`):

  ```
  event: generation_chunk
  data: {"type":"generation_chunk","iteration":2,"text":"…","thinking":"",
         "tool_call":true,                                   // only when set
         "counts":{"prompt_tokens":489,"completion_tokens":12,
                   "total_tokens":501,"context_window_tokens":32768},  // only when the server reported counts
         "event_seq":812}
  ```

  A `tool_call_started` frame keeps its row fields but omits the model's `call`:

  ```
  event: tool_call_started
  data: {"type":"tool_call_started","iteration":2,"call_index":1,"tool":"write",
         "params":"path=notes.txt","event_seq":812}
  ```

  A `turn_completed` frame omits `result`; `turn_summary.output` carries the answer:

  ```
  event: turn_completed
  data: {"type":"turn_completed","turn_summary":{"output":"Done."},
         "display_pending":false,"event_seq":813}
  ```

  `counts` is `ContextUsage.normalize` of the provider's payload without `ctx_pct` (normalize computes it
  without the session's LLM context budget; a client counts `total_tokens` against the window or budget, as
  `ContextStatus#generation_done` does for the TUI) and with its nil keys left out: cumulative for the
  request, a missing key means unknown (never 0), `prompt_tokens` includes cached tokens, and
  `context_window_tokens` is there only when the payload reported a window itself (llama.cpp's `/completion`
  doesn't: the client uses `generation_started`'s). Unknown provider fields never cross; a field is added here
  when a client needs it, never as a catch-all bag. Details: [internals/context-telemetry.md](internals/context-telemetry.md).
- `POST /session/:id/turn` — fire-and-forget turn creation; returns `202` with an `enqueued_id`
  (delivery is at-least-once via the worker's file-IPC input path — it never calls `run_turn`
  across the HTTP boundary). Only the bridge's own session: another id, in the path or the body's
  `session_id`, is `404 unknown_session`. Inspect results through the read surface, not the turn response.
  An optional `deadline` (epoch seconds; `BridgeClient` sends 5/6 of its read timeout ahead) makes
  a request read after it (a worker frozen by sleep or SIGSTOP) answer `408 deadline_passed` and
  not run: a client that timed out has said the message was not sent. `/answer`,
  `/question/dismiss`, `/command`, `/turn/dequeue` and `/exit` take the same `deadline` (a command is
  checked with the event log held, as a turn is), and the Bridge logs `turn_expired`, `answer_expired`,
  `dismiss_expired`, `command_expired`, `dequeue_expired` or `exit_expired`. The web app answers either
  kind of timeout with `504 worker_timeout` ("… so the command was not run"). `/cancel` and `/recap` take none.
  The web relays answer, dismiss, command and cancel the same way (`App#relay`): a 408 or a read
  timeout is `504 worker_timeout`; a Bridge 404 for a route an older worker lacks is
  `501 not_supported` with the restart hint; a Bridge `404 unknown_session`, no bridge or a
  refused connection is `503 not_live`.
- `POST /session/:id/cancel` — cancel the running turn; `202`, or `409` when none runs.
- `POST /session/:id/recap` — `/recap` in an attached TUI: `200 {enabled, saved, request,
  min_user_turns}` (`{enabled: false, session_off}` without recaps; `session_off` when the session's own
  `/recap off` turned it off); a new recap is asked for at once and
  arrives as `:recap_ready`. Answers mid-turn too.
- `POST /session/:id/answer` — answer the pending question; `200`, `409` when another client
  answered first or it is gone, `400` for an invalid selection. With `client_id: "cli:answer"`
  (`chi answer`, a parent agent) the answer is checked by `Guardrails::ParentPolicy` in
  `QuestionDesk#answer`: the question carries each option's effect (`effects`, set by its asker:
  `Approval.payload`, `ContinueOffer`, `Relay.card`; derived for an untagged one) and `user_only`,
  and an option beyond the worker's `guardrails.parent_answers` (tightened by the session's own
  `parent_answers`: `ParentPolicy.for_session`) is `403 parent_answer_refused` (with its `reason`),
  the question still open. `chi answer` makes the same check first, from the session file.
- `POST /session/:id/question/dismiss` — leave the question unanswered (an approval: denied);
  `200`, or `409` when it is no longer pending.
- `POST /session/:id/tasks/stop` — `{task_id}`: stop a background task as the user
  (`TaskRuntime.stop_task by: "user"`, the web's stop-task button on a running `task_wait`;
  web route `POST /api/sessions/:id/tasks/:task_id/stop`). Only a task this conversation's
  `task_create` started, or an `execute` handed over as a task at its limit (`TaskRuntime.created_ids_in` on the
  saved messages, or the running turn's accumulator); answers once the
  task is gone: `200 {status, stop_reason, task_id}`, `404 task_not_found`, `409 not_running`.
  The worker names it in its sidecar features (`task_stop`).
- `POST /session/:id/turn/dequeue` — `{enqueued_id, client_id?, deadline?}`: take back a queued message
  (one that waits for the running turn's end: `--queue`, Alt+Enter, `/queue TEXT`, or a message
  with images) before a turn takes it (web route `POST /api/sessions/:id/turn/:enqueued_id/dequeue`,
  the × on a queued bubble; `/unqueue` in the attached TUI). Under the event log, like its enqueue:
  `SessionInbox.take_queued_input` writes a tombstone (`input/removed/<enqueued_id>`, for `ReplyWait`'s
  `turn:`), claims the file as the drain does (one rename wins; a lost claim takes the tombstone back),
  deletes it, and the Bridge announces `:turn_dequeued`. `200 {status: "removed", enqueued_id, prompt}`, `409 already_started`
  (a turn took it), `409 not_queued` (a next-step message: a drain may merge it any moment), `404
  unknown_enqueued_id`. It never wakes the worker. The worker names it in its sidecar features (`unqueue`).
  A worker's start prunes the `input/removed/` and `input/settled/` tombstones older than a week
  (`SessionInbox::TOMBSTONE_MAX_AGE`, log `tombstones_pruned`); otherwise they go with the session dir.
- `POST /session/:id/relay` — the approval relay, on a delegated child's worker
  (`{action, relay_id, question_id}`): `opened` / `closed` (with a `reason`) set or clear the
  pending question's `relayed_to` mark (`QuestionDesk#annotate`, `:question_relay`); `answered`
  makes the child ask its parent's Bridge for the answer (`RelayVerifier`) and take it only for
  this child and the question pending now. `200`, `409` no longer pending, `403` a parent agent's
  pick beyond the child's own `guardrails.parent_answers` and session `parent_answers` (`parent_answer_refused`; the
  relay card in the parent was held to the parent's), `422 relay_unverified` (the question
  stays open).
- `POST /session/:id/relay/status` — on a parent's worker, `{relay_id}`: what its `RelayDesk`
  (memory only) holds for that relay (`child_id`, `child_question_id`, `state`, `answer`, `by`);
  `404` for an unknown id. A POST with a body because routes match exact paths.
- `POST /session/:id/command` — a session command (`/model`, `/models`, `!rollback`, `!cmd`,
  `/continue`) for the worker loop; `202` with a `command_id` its `:command_ran` names, `400` when
  the line isn't one. A `:command_ran` carries `thinking`, `reasoning_history` and `llm_context`
  (the summaries the next turn runs under) when the command changed them or the model, and
  `confirm: {line, text}` when a `/thinking` or `/reasoning-history` change from a `web:` or `tui:`
  client asks first (`CacheConfirm`; nothing changed, `line` applies it).
- `POST /session/:id/exit` — ask the worker to exit now (`{client_id:, delete?, restart?, deadline?}`; `delete`:
  `/exit --delete`, no recap written; `restart: true`: hand the session to a new worker on the newest chi
  installed, `200 {status: "restarting"}`; an empty session's `exiting` carries `discard: true`). The worker checks with
  the event log held (`WorkerIdleExit#hold_for_request`): `200 {status: "exiting"}` and it leaves
  like an idle exit, or `409 {status: "held", reason:}` with `turn_running`, `input_queued`,
  `continue_offered`, `client_connected` (a stream not named by the asker), `reminders`,
  `background_tasks` (with `tasks: [{id, command}]`: the running tasks a finish wake watches) or `starting`.
- `GET  /session/:id/state` — `session_state_snapshot` (JSON).
- `GET  /session/:id/stats` — `Engine#stats_snapshot` for attached `/stats`: the metrics, with the context window and prompt profile asked from the server before the first turn.
- `GET  /session/:id/snapshot` — the snapshot frame's content as one request (the web server renders
  the messages itself, then streams from its `event_seq`). Read by the web's full show
  (`GET /api/sessions/:id`, `?parts=1`) and the plugin's `list_sessions`; every message is copied.
- `GET  /session/:id/tail` — the page's light re-read (`Bridge#tail_frame`): `session_state_snapshot`,
  `working_directory` (the session's folder, which the web checks the answer's file refs against),
  `answer` (the last message a UI shows as an answer, `AnswerTail`: the one message, copied alone),
  `cards` (`CardStore#list`; a card an earlier worker showed during a turn comes back read-only, with no
  actions: its turn no longer runs), `event_seq`, `event_id`, all taken in one event-log hold; no message
  list, so it costs the same however long the session is. `?turn_id=` answers that turn's answer
  (an unknown or missing id: the newest); the only route that reads its query.
- No browser: only chi's own clients talk to a Bridge. A request with an `Origin` header, a `Sec-Fetch-Site`
  other than `none`, or a `Host` that isn't loopback (a DNS-rebound page) is `403 cross_origin`
  (`Bridge#browser_request?`, before any route); there is no CORS and no `OPTIONS` route. The browser reaches a
  worker only through `chi web`. A request carrying any trace a proxy adds (`ProxyTrace`: `X-Forwarded-*`,
  `Forwarded`, `X-Real-IP`, `X-Auth-Request-*`, `Cf-*`…, underscore twins too) is `403 proxied`
  (`Bridge#proxied_request?`): an auth proxy that forwards every local port and adds such a header doesn't reach a
  worker. A heuristic: a forward that adds none still does, until Bridges have a secret (shared-sessions P6).
  `bridge.json` is 0600.

The metrics in `/state`, `/snapshot`, `/stats` and the SSE `snapshot`/`reset` frames
(`SessionMetrics#snapshot`) carry the session's totals and only the recent timing records: the
newest turn the worker finished and any it hasn't saved yet (at most 20 turns), with their tool
calls and the running turn's finished ones. The full history is the session's `analytics.json`,
which `SessionMetrics#persist` rewrites after each turn; the web server merges the two by id.
The totals' `tokens` block adds the cached, cache-write and reasoning sums, the reported cost (`cost_sum`) and the
estimated one (`cost_estimate_sum`, from `hosts.<name>.models` prices; 0 for none), the decode time and tokens
behind the average speed (`avg_decode_tps`) and the last speeds (`last_decode_tps`,
`last_prefill_tps`, `tps_source`: `server` or `estimate`). `model_segments` (always present) splits those sums
by model after a `/model` switch: one row per run of consecutive turns on one model (`SessionMetrics::ModelSegment`,
keyed on the turn records' `model_ref`), in order, with its turns, token and cost sums, speeds and the switch's prefill
(`prefill_tokens`, `prefill_cost_estimate`: the sums of its turn records' `switch_prefill_tokens` and
`switch_prefill_cost_estimate`, [sessions.md](sessions.md)); `[]` with one model, the oldest rows folded into one (`folded_segments`)
past 6; a running turn counts in its model's row (`ended_at` null). The rows add up to `tokens`. They are derived from
the records, never read back. Each `generation_completed` event
carries the generation's `speed` (`{decode_tps, source}`, null without one), its own prompt-cache
counts (`prompt_tokens`, `cached_tokens`, `cache_write_tokens`: null when the server reported no writes) and
those running `tokens` and `model_segments`: the Engine closes the generation in `SessionMetrics#finish_generation` before relaying
it, so the web's info bar updates per generation without parsing chunk payloads.
Side requests (the idle recap, a plugin's `ctx.ask_model` such as `/btw`) are counted apart, in a `side` block
(only when there were any; `SessionMetrics::SideTotals`: requests, token sums, `cost_sum` null until reported,
`cost_estimate_sum` from the target host's price, `by_kind`): `IdleClient` hands each reply's usage to its
`on_usage:` callback, `Engine#note_side_usage`, which folds it (`SessionMetrics#add_side`) and announces
`:side_usage` (`kind`, the whole `side` block) under the event lock, so the blocks arrive in fold order, then saves
`analytics.json` between turns (a running turn's end saves it). `tokens`, `model_segments` and the turn records
stay the turns' only. `SessionMetrics#persist` is serialized (its own mutex, taken before the metrics one), so two
threads' saves land in snapshot order.
A bundle's `ctx.cost` reads the same sums (`SessionMetrics#cost`, a frozen `SessionMetrics::Cost`): the `tokens`
block's `cost_sum` and `cost_estimate_sum` with the running turn's finished generations folded in, plus the `side`
block's, so it counts what earlier workers spent too ([plugins.md](plugins.md)). Its `ctx.usage` reads the work
(`SessionMetrics#usage`, a frozen `SessionMetrics::Usage`): the snapshot's `turns`, `tool_calls_total` /
`tool_calls_by_tool` and `iterations_total`, and `active_ms`, the generations' `gen_ms` plus the finished tool
records' `duration_ms` (tallied per tool as they are counted; `ask_user_question`'s, a wait on the user, left out).

The page's frequent reads of `GET /api/sessions/:id` stay light too:
- `?tail=1&recent=1` (each turn's end, a cancel, an answer display): `{tail, session: {id, status,
  used_memory_names}, messages: [the answer, with its display and display_refs (re-read on an `answer_display` with a display or refs)], markdown_warning, timing}`, from the worker's `/tail`
  alone (no session file parsed, no `analytics.json`); `timing` carries the worker's recent records
  and `turn_count` (finished turns). The page merges the records by id (`timing.js mergeTiming`) and
  finishes the ended turn's own line by its `turn_id` (sent as `&turn_id=`, which also picks that
  turn's answer). A tail read's timing is always the newest turn's; `recent=1` is accepted and not needed.
  The page binds an answer's `display_refs` to its bubble (`answer_refs.js`: on a reload's render and on this
  read's re-render) and pairs them with the bubble's links and text before the `path:line` scan. A question's
  refs (`pending_question.refs`, `:question_asked`) pair the same way (`markdown_place.js` `linkRefsIn`/`pairRefsIn`):
  `question_requested` (or a snapshot's pending question) keeps them on the asking step's gen
  (`turn_model.js` `questionRefs`) before the card draws, so the stage's asking slot (`stage_slots.js`
  `drawAsking(text, refs)`) pairs them on its raw draw and again after its markdown swap; the card pairs its
  question text and its kept reply (`question_cards.js`); the step's closed `.gen-text` takes them
  (`turn_view.js`; on a reload its `data-answer-at`, the message's `display_refs`) and `linkTextRefs` pairs it at
  the turn's end and after a reload. A closed step's text is markdown too with `web.markdown` on: a reload's
  from its message's `html` (`turn_view.js` `textTemplate`), a live turn's from `POST /api/render` on its step's
  first open after the turn's end (`markdown_place.js` `renderStepTexts`, which pairs its refs again after the
  swap); the text as written stays on it as `data-copy-source` (`stepText`, a reloaded card's kept reply). A file ref outside the
  session's folder is dropped, as a reload drops it: the folder `/tail` names, else (an older worker) the hub's
  session list entry's, else (refs to check, no hub entry) the session file's; with no folder known at all, every
  file ref is dropped rather than shown unchecked.
  A plugin tool's row refs (`refs`, `RowRefs`) ride its tool events and, on a reload, its part (saved as
  `tool_refs`); `turn_view.js` binds them to the row's title (`refs.js bindRowRefs`: the first on the title,
  the others in its menu).
- `?timing=1`: the whole timing (`analytics.json` merged with the worker's `/state`) and
  `turn_count`, when the page's merge came up short.
- `?cards=1`: the cards, from `/tail`; the session file is only stat'ed for the 404.

The stage view's working set (`web.working_set`) has its own read, `GET /api/sessions/:id/working_set`: the
`WorkingSet` projection (`{items, at, running}`: each file, memory and URL live, stale or forgotten, with its tokens)
of the worker's `/snapshot` messages, else the session file, under the session's LLM context strategy; while a turn
runs, the snapshot's `working_set` (the running turn's last event, which the messages lag) when it has one. Its live form
is the `:working_set_updated` event, which always wins over a GET's answer it overtook. The page overlays it on the
set it builds from its tool rows ([internals/working-set.md](internals/working-set.md)).

A worker without `/tail` (an older chi; `404 not_found`) is read through `/snapshot` in the same
shape; any other failure (no worker, a 500, a timeout) reads the disk, trimmed to the newest
turn's records.

Every route goes through `Bridge#dispatch`: an id other than the bridge's own session is
`404 unknown_session`, and a handler that raises answers `500 bridge_error` (logged as
`handler_failed`) rather than dropping the connection.

The per-session port is OS-assigned (bound to `0`) and published to a `bridge.json` sidecar
for client discovery. `chi web`'s `GET /api/sessions/:id/stream` proxies this bridge
(503 `not_live` when the worker is not running; full history of any session is served by
`GET /api/sessions/:id/output`), as a byte pipe for the owner: `App#proxy_stream_body` gives `ProxyStreamBody` the
request's frame filter (`App#stream_filter`: nil for the owner; for a participant, and the owner's participant view
`?as=participant`, a `Web::ParticipantStreamFilter`, which cuts the Bridge's chunks into frames and writes each again
from `Web::ParticipantView.event`'s allowlist, dropping every other event; only `from_seq` and `snapshot` reach the
Bridge; [internals/participants.md](internals/participants.md#what-a-participant-sees)). Resume/ring-buffer state is **in-memory**, per worker: a cursor from
an earlier worker gets the `reset` snapshot, not a replay.

**Session hub.** The cross-session layer (which sessions exist, who owns them, what changed)
never pulls from the page: `chi web` runs one `Samagotchi::Web::SessionHub` (a thread inside
the server, no daemon) that keeps an in-memory projection of the session list and pushes
changes to every open tab over `GET /api/events` (SSE: a `snapshot` frame on every connect,
then `session` for an upsert and `session_gone` for a removal, `: ping` while idle, no replay).
The snapshot names chi's version: a tab served by another one (its `<body data-version>`) offers a
reload in a toast, since an open tab keeps its old JS across a `chi web` upgrade. It also names
`installed`, the newest chi on this machine (`InstalledVersions`: the highest `samagotchi-<v>.gemspec`
in RubyGems' specification dirs, or a checkout's `version.rb` on disk; looked at again on each full
probe, every 10 s), and a change is a `chi` frame `{version, installed}`. A newer one than the
server runs is said in chi web's terminal and on the page: restart chi web (its workers already
run the newest chi, [Sessions](sessions.md)). `GET /api/info` carries `installed` too, and the
feature `newest_workers`.
Files stay the source of truth and workers don't know the hub. Its watcher is a 1 s tick that
stats the sessions dir (every session writer goes tmp + rename, which bumps the dir's mtime) and
each `<id>/` folder (recap.json, bridge.json, the stopped and archived markers), re-parsing only the files whose mtime or size
moved through `Session.summary_from_file`. Liveness is probed, since a killed owner leaves no
file trace: the owner lock every tick for the sessions the projection believes owned, and every
session every 10 s, so a `kill -9` shows within a second. The summary (`Web::SessionSummary`,
shared with `/api/sessions` and the session view) carries `owner`, `project_root` and
`bridge_up` (the sidecar is there *and* the lock is held: the page attaches its stream on it), and
from that sidecar `worker_version` (the chi the worker runs) and `worker_features`
(`Bridge::FEATURES`, what a client may ask of it beyond the routes: `restart`, `task_stop`, `reparent`, `unqueue`,
`delivery`, a worker that queues a message for after the turn; `SessionManager.deliver_turn` and
the attached TUI refuse a queue to a worker without it, which would steer; `turn_ids`, a worker whose running
turn's mark, continue turn and Stop carry the turn's `enqueued_id`, which `chi answer`, `chi send --wait` with no
message and `delegate_result` rely on through `ReplyWait.own_turn`). A worker's Bridge snapshot
names its `chi_version` too.
`POST/DELETE /api/sessions` and `/stop` rescan the session before answering (`SessionHub#touch`).
`GET /api/sessions` is the hub's projection too (its sort, paging and total). `Server` always builds
a hub; an `App.new` without one answers both routes `503 no_hub`.

**chi web's routes for the session commands.** chi's session commands (`chi send`, `answer`, `note`, a session's
`context`, `sessions list/stop/restart/archive/unarchive/delete`) run against another machine's sessions through its
chi web (the remote-sessions plan; `SessionAccess::Contract` says which commands and flags may). The page's routes
cover most of it; `Web::SessionAccessRoutes` (`web/session_access_routes.rb`, in `App`'s `ROUTES`) adds the rest, each
calling the `SessionAccess::Local` operation of the same name, so a remote backend maps 1:1 onto them. Every one is
token-gated like the rest (LAN mode: `Authorization: Bearer`), and one that takes an id is a `:session` route (an id
that isn't one, or no such session: 404 `not_found`). Every `ROUTES` row also names who may use it, checked against
the request's `Web::Principal` (`App#principal_for`): `owner`, or `participant` for a route a participant may use too.
A participant (a `Web::Grants` token for one session) may use the page (`GET /`), `GET /api/info`, their session's
show, review and filtered stream, and their turns and waits, each answered as theirs; every other route is `owner` (Permission below, and the participants routes in
[internals/participants.md](internals/participants.md)); `spec/web/principal_spec.rb` fails on a row without one. How a request flows end to end, which checks run where and the trust
model: [internals/remote-sessions.md](internals/remote-sessions.md).

| Route | Permission | Body / params | Answer | Refusals |
|---|---|---|---|---|
| `GET /api/sessions/resolve?id=` | owner | an id or a unique prefix | 200 `{id}` | 404 `not_found`; 400 `ambiguous_id` with `ids` |
| `GET /api/sessions/summaries` | owner | `dir` (a folder: its project; none: every project), `cwd`, `live=1`, `archived=1`, `tests=0`, `sort`, `order`, `limit` | 200: the rows `chi sessions list` prints (`SessionManager.session_summaries`: `status`, `live`, `busy`, `owner`, `recap`, `ctx_pct`, `waiting`, `waiting_id`, `title`, `preview`, …) | 400 `invalid_dir`, `invalid_cwd` |
| `POST /api/sessions` (more fields) | owner | `toolkit`, `tools`, `no_tools`, `parent_answers`; `client_id` (`cli:send`/`cli:answer`: the first line is checked as chi send checks it); `check_vision: true` (images follow) | 201 adds `model_warning` and `parent_answers_warning` (a level looser than config.yml's, capped) | 400 `invalid_toolkit`, `invalid_parent_answers`, `invalid_continues` (beside `continues`); 403 `parent_answers_refused`, `parent_continue_refused`; 422 `no_vision` |
| `POST /api/sessions/:id/turn` (more fields) | owner | `client_id` as above; `check_vision: true` with `images` | as before | 403 `parent_answers_refused`, `parent_continue_refused`; 422 `no_vision` |
| `POST /api/sessions/:id/wait/prepare` | owner | `question_id` (absent: the pending one; `null`: none), `turn`, `created`, `busy` (+ `queue`) | 200 `{session_id, cursor, baseline: {messages, question_id, last_turn}, own_turn, known_turn, running, live, settled, last_turn_id}` (`WaitStart`) | 409 `busy`, `waiting` (`SendCommand::Busy`'s words, and its fields: `question`, `parent_strategy`) |
| `POST /api/sessions/:id/wait` | owner | `cursor`, `baseline`, `turn`, `queued`, `ended_before`, `owner_grace`, `timeout` (capped at 30 s) | 200: `ReplyWait::Result`'s fields (`status`: `done`, `waiting_for_answer`, `no_reply`, `error`, `stopped`, `worker_gone`, or `timeout`: ask again; `text`, `file`, `question` as `PendingQuestion#to_file`, `outcome`, `limit`, `error_kind`, `retryable`, `cancel_reason`, `stopped_by`, `kept_steps`, `turn_id`, `origin`; never the session) and `parent_strategy` `{name, allowed, origin}` (`ParentReport.strategy_for`, this server's config.yml) | 400 `invalid_wait`; 503 `server_stopping` |
| `POST /api/sessions/:id/notes` | owner | `text`, `source` (default `cli`, never `broadcast`) | 200 `{status: queued \| waits, session_id, queued}` (`NoteDelivery`) | 409 `owned_by_tui` (`status: refused`); 400 `note_rejected`, `missing_fields`, `invalid_source` |
| `POST /api/sessions/:id/context` (more bodies) | owner | `{name, push: true, why, hint}` or `{name, cmd, every, why, hint}` beside the page's `{url, why, hint}`; `added_by` `cli`/`agent` (else `web`) | 201 `{status: attached, name}` | 400 `invalid_source`; 409 `exists` |
| `POST /api/sessions/:id/context/:name/push` | owner | `text`, `summary`, `wake`, `hint` (a source's JSON output, checked the same way) | 200 `{status: pushed, name, before, revision, changed}` | 404 `not_found`; 409 `not_push`; 400 `invalid_text` |
| `DELETE /api/sessions/:id/context/:name?own=1` | owner | | 200 `{status: detached}`: the session's own only | 409 `project_source` (chi context rm's words); 404 |
| `POST /api/sessions/:id/stop` | owner | `wait?` (seconds, capped at `SessionManager::STOP_WAIT`, 10: `chi --remote NAME sessions stop` sends it) | 200 `{status: stopped, session_id, released}`: `released`, whether the worker let go within the wait (without one `STOP_WAIT_SECONDS`, 2 s: the page's Stop) | 409 `owned_by_tui` |
| `DELETE /api/sessions/:id?force=` | owner | `force=true` stops a live worker first (the page sends it) | as before | 409 `worker_running` without it |
| `GET /api/sessions/:id?brief=1` | participant (theirs: title, status, participants) | | 200 `{brief, session: {id, status (the file's), title, display_title, project_root, working_directory, model_name, model_typed, parent_answers, owner}, pending_question}` (the file's; no messages): `Remote#show` | 404 |
| `POST /api/sessions/:id/turn` (its 202) | owner | | the ack with `via`: `bridge` or `file` (the input file: a remote `chi send --wait` follows that turn) | |
| `GET /api/sessions/:id/context?full=1`, `…/context/:name?full=1` | owner | | each row with `source` (`Source#to_h`, its command too; the page's rows never carry one), `snapshot` (`Snapshot#to_h`, no text) and `shadowed`, shadowed project sources included | |
| `POST /api/sessions/:id/wake` | owner | `wait` (seconds, default and most 10: `WAKE_MAX_WAIT`) | 200 `{session_id, woke, worker: {epoch, started_at, version, features}, model_name, default_model, parent_strategy, installed}`: the live worker as is (`woke: false`), else resumed and its Bridge waited for (`Local#wake`); `default_model` and `installed` are this machine's | 409 `owned_by_tui`, `scratch` (`LaunchMode::SCRATCH_LEFTOVER`); 504 `worker_timeout` (`LaunchMode::BRIDGE_LATE`); 400 `invalid_wait`; 404 |
| `GET /api/sessions/:id/worker` | owner | | 200 `{session_id, live, stopped, owner: worker \| tui \| null, worker: {epoch, started_at, version, features} \| null, default_model, parent_strategy}` (`Local#worker`; never starts one; `default_model` is this machine's) | 404 |
| `POST /api/sessions/:id/exit` | owner | `client_id` (passed on only when it is an attached TUI's, `tui:…`; any other is dropped), `delete` | 200 the worker's `{status: exiting, session_id, discard}` (`BridgeClient#request_exit`; never wakes one) | 409 `held` with the worker's `{status, reason, tasks, hint}`; 503 `not_live`; 501 `not_supported`; 504 `worker_timeout` |
| `POST /api/sessions/:id/recap` | owner | | 200 the worker's `{enabled, saved, request, min_user_turns, session_off}` (`BridgeClient#request_recap`) | 503, 501, 504 as every relay |
| `GET /api/sessions/:id/stats` | owner | | 200 `{session_id, metrics}`: the worker's stats, its state's metrics for a worker from before the stats route | 503 `not_live`; 504 `worker_timeout`; 502 `bridge_error` |
| `GET /api/sessions/:id/children/counts` | owner | | 200 `{running, waiting, unreported}` (`ChildrenStatus.counts`, the delegates' files here) | 404 |
| `GET /api/sessions/:id/turns/:turn_id/records` | owner | | 200 `{tool_records: […], turn_record: {…} \| null}` (`SessionMetrics.saved_tool_records` / `saved_turn_record`, as saved) | 400 `invalid_turn_id`; 404 |
| `POST /api/sessions/:id/turn` (`no_interrupt`) | owner | `no_interrupt: true`: the turn runs with the raised iteration limit (`SessionManager.deliver_turn(no_interrupt:)`, to the Bridge or the input file) | as before | |
| `POST /api/sessions/:id/command` (its 501) | owner | | | 501 `not_supported` for a builtin the worker lacks adds `command` (`"/title"`) and `message` |
| `GET`/`POST`/`DELETE /api/sessions/:id/participants`, `GET`/`DELETE /api/participants` | owner | `chi share`'s (`name`, `kind`, `ttl`; `?id=p_…`) | the grants, never a token but POST's own once ([internals/participants.md](internals/participants.md)) | 400 `invalid_participant`; 404 |
| `GET /api/sessions/:id/apply[?turn=T]` | owner | `turn`: a turn id or a prefix (none: the latest review turn with a reply) | 200 `{text, turn_id, author, author_name}` (`ReviewApply`): the owner's Apply of a participant's review turn, for the composer, never sent ([internals/participants.md](internals/participants.md)) | 404 `not_found`; 400 `not_review_turn`; 409 `no_reply` |
| `POST /api/sessions` (`review`) | owner | `review: {subjects: [project files], from: a session id}`; never with `prompt`, `preview`, `idle` or `continues` (a `from` takes the source's folder and setup) | 201 as a create's: an idle review session (`ReviewStart.start`, or `ReviewStart.fork` with `from`) | 400 `invalid_review` (`ReviewStart::Refused`'s words: a subject, a gone folder); with `from` also 404 `not_found`, 400 `ambiguous_id` |

`GET /api/info` names the feature `session_commands` (`SessionAccessRoutes::FEATURE`): `SessionAccess::Remote` asks it
once before its first request, and a chi web without it (or `serve_static`'s 404 for a path no route takes) is "remote NAME runs chi X, too
old for this command through --remote: update chi there (chi update)". The feature `remote_attach`
(`SessionAccessRoutes::ATTACH_FEATURE`) names the routes a remote attached TUI needs: wake, worker, exit, recap, stats,
children counts and a turn's records. Their refusals carry `{error, detail, message}`.

`POST …/answer` passes on `client_id` only when it is chi answer's (`cli:answer`), so the worker holds the answer to
its `guardrails.parent_answers`; any other is dropped, so a forwarded id can only tighten. The worker's 403
`parent_answer_refused` (with `reason`) and a dismissal's 409 `not_dismissable` pass through; a 408 (the worker read it
past its deadline) is sent once more, as `SessionAccess::Local#answer` does, and a second is `504 worker_timeout`.

A refusal an exception raises carries, next to `error` and `detail` (the page's words), `message` (the exception's own,
verbatim) and the fields its class is built from, so a remote client raises the same class with the same text:
`owned_by_tui` (`session_id`), `worker_running`/`still_stopping` (`DeleteRefused`: `session_id`, `reason`), `busy`/
`scratch` (`ArchiveRefused`: `session_id`, `reason`, `busy_id`), a restart's `held`/`not_running`/`unsupported`/
`failed` (`RestartRefused`: `session_id`, `reason`, `version`), a continue's `continued`/`open_children`/`folder_gone`
(`SessionContinue::Refused`: `session_id`, `reason`, `ids`) and `ambiguous_id` (`Session::AmbiguousId`: `ids`).

## Model loops and adapters

A model ref (`--model`, `/model`, `default.model`, an alias's target) is parsed
by one pure resolver, `ModelRef.parse` (host prefix, alias), given the configured
hosts and aliases; `HostRegistry` routes a name that names no host (its model
index after `/models`) and builds the `ModelTarget`.

Engine picks the loop from the effective model's host: `EffectiveModel.of` resolves it (`HostRegistry#resolve`)
on every read, never kept, since config.yml and a model listing can move it without a `/model`
([internals/engine.md](internals/engine.md), "EffectiveModel"):

| Loop | Class | Host | Talks through |
|---|---|---|---|
| Raw prompt | `KernelLoop`, wrapped by `LLM::NativeBackend` | no `api:`, or `llama_cpp` | `Client` (llama.cpp `/completion`), chi's own Gemma/Qwen prompt and tool-call parsing |
| Chat | `LLM::ChatLoop` | `api: openai` | `LLM::OpenAIChat` (`/v1/chat/completions`, streamed, native tool calls) |
| Chat | `LLM::ChatLoop` | `api: anthropic` | `LLM::AnthropicMessages` (`/v1/messages`, streamed SSE, native `tool_use`) |

Both return an `LLM::ModelResult` and emit the same stream events; tool calls in
both go through `ToolRunner` (events, hooks, veto, output cap) and
`KernelLoop#dispatch_tool_call`. Every format's built-in calls (Gemma, Qwen,
chat `tool_calls`) are built by one table, `Tools::BuiltinCalls`, from the
parsed `{name, args}` (derived from `TOOL_SCHEMAS`), so a call looks the same to
hooks and tools whichever model made it. Both loops' `generation_chunk` carries
`thinking:`, `text:`, `content:` and the provider's `payload:` (the Bridge projects it for its
clients: `text`, `thinking`, `tool_call` and chi's `counts`, no `payload` or `content`; see the
Bridge's stream above): the chat loop's thinking is the
server's `reasoning_content`; the raw-prompt loop splits each generation's
stream with a fresh `ThoughtStreamSplitter`, seeded with the prompt's prefill (Qwen's `<think>` and Gemma's
`<|channel>thought … <channel|>` are thinking, tool-call bodies are dropped
from `text:`; a saved step's text, as the web history and the attached terminal's join show it,
drops both too: `OutputFormatter.strip_markup`). The chat loop's model turns keep their `tool_calls` and tool results their `tool_call_id`,
so later requests and resumed sessions pair them, and their reasoning (`thinking:`), which goes back as
`reasoning_content` on the running turn's replies (`reasoning_history`; a step-limit Continue's
turn goes on from the run it resumes, `reasoning_since:`). It has its own system prompt
(no raw-prompt tool declarations; the tools go as JSON schemas).

`Engine#build_stream_event_handler` (`EventFanout`'s, which the Engine forwards
to) is the one seam both loops' streams pass through: with a
`:generation_progress` hook registered it feeds a `Hooks::StreamWatch` each
chunk's thinking and text after the UIs had it. A
hook's `stop_generation` cancels the generation's own controller (a child of
the turn's, `CancellationController#generation`), and each loop takes the cut
as an empty answer and asks again.

Both loops keep one `EmptyAnswerRetry` per turn (the `retry.empty_answer`
budget, the hidden nudge, the retry's sampling), and both end each
generation's `:generation_completed` with a `finish_reason`: the chat host's
own, or for the raw-prompt loop what `Client.finish_reason_from`
reads from the stream's last payload (llama.cpp `/completion`'s `stop_type`:
`limit` is `length`, `eos` and a stop word are `stop`). An empty answer with a `length` stop and the context 90 % full or
more is not asked again (a full window, not a thinking loop); with no finish
reason it is. Both also keep one `ContextStatus` per turn: before each request
it estimates how full the window is (the server's last count plus what the turn
appended since), emits `:context_status` on every request (so the web and the
attached TUI get a fresh number each time), and on a rise past the second
threshold puts the model's own `[CONTEXT: …]` line on the tail as a system
message (docs/internals/context-telemetry.md).

**Adapters.** `Client` (raw-prompt servers), `LLM::OpenAIChat` and `LLM::AnthropicMessages` (one per host,
`HostRegistry#adapter_for`, built by `LLM::Adapters` from the host's api) share
`LLM::HTTP`: timeouts, TLS for https, a line reader for streamed bodies, the retry loop (`retry.*`; network errors, 429 and
500/502/503/504/529, honouring `Retry-After`; never after a stream has produced
output; a refused connection and a TLS handshake that can't work, `LLM::TLSError`, fail at once) and cancel. Cancel closes the in-flight socket from the
`CancellationController` listener, so it works on any thread.

`LLM::AnthropicMessages` talks Anthropic's Messages API (`POST {root}/v1/messages`) for the same chat loop:
ChatLoop builds the same OpenAI-shaped wire messages for every chat host, and the adapter translates them
(`LLM::AnthropicWire`: the head system message becomes the top-level `system` blocks, tool calls `tool_use` blocks,
tool messages `tool_result` blocks in one user message, image parts `image` blocks, later system messages user
text; empty text blocks are never sent). Its answer (`LLM::AnthropicAssembly`) is a `ChatResponse` whose
`provider_content` holds the content blocks as received, which ChatLoop saves on the model entry as
`anthropic_content` (string keys, so a resumed session sends the same bytes) and sends back verbatim when the
adapter `replays_content?` (only for entries whose calls are all paired, never for an interrupted one; earlier
entries' thinking blocks left out under `reasoning_history: turn`) (thinking blocks
need their signature and their order among text and `tool_use`). Usage is normalized to the OpenAI shape the rest
of chi reads (the prompt is input + cache reads + cache writes), stop reasons to the loop's finish reasons
(`max_tokens` → `length`, `tool_use` → `tool_calls`, `end_turn` → `stop`). A stream is read by content-block index
from the `data:` lines alone (`event:` lines are not needed); `message_start` / `message_delta` events reach
`on_delta` with that normalized `usage`, pings not at all, and a block's start or delta counts as shown for the
first-token limit. Both adapters share their model-list cache (`LLM::ModelListing`) and their HTTP plumbing
(`LLM::AdapterCommon`: timeouts, the paged model list, the SSE line loop, JSON errors). A host's `dialect:`
(`LLM::Dialect`, `fireworks`) changes the auth header, the thinking `display`, the cache breakpoints and a session
header; [internals/anthropic.md](internals/anthropic.md) covers the adapter.

**Errors.** A failed request raises an `LLM::ProviderError` of one kind:
`ConnectionError` (`RetryExhausted`), `RateLimited` (`CreditsHeld`: a 402 about
credit held by in-flight requests, retried after 20 s), `OutOfCredits` (any other
402), `ServerError`, `AuthError`, `BadRequest` (`context_overflow?`) or `ProtocolError`. Engine keeps the turn's
conversation (the prompt plus completed tool iterations) and emits
`:turn_failed` with `error_kind:`, `retryable:`, `host:` and a one-line
`summary:`, which the REPL, the attached TUI and the web show.

**Usage and models.** A turn's token counts are `SessionMetrics`', read from the
stream events (server counts, else a chars/4 estimate). Model lists are `LLM::ModelInfo`
(`HostRegistry#list_all_models`); the context window comes from the running
server (`/props`), then the host's model list, then config.

**Keys.** A host's API key comes from the environment variable its
`api_key_env:` names, else, on macOS, the login Keychain's item for that name (`HostKeys`, read through
`/usr/bin/security` with a deadline; hits cached per process; `SAMAGOTCHI_KEYCHAIN=off` skips it); it never
reaches config.yml, `chi self`, logs or events.

## Other components

A map of the parts the overview above doesn't name (paths under `lib/samagotchi/`):

| Component | Main file(s) | What it is |
|---|---|---|
| Worker | `worker.rb` (`worker_idle_exit.rb`, `worker_inbound.rb`, `worker_signals.rb`, `worker_wakes.rb`, `worker_task_wakes.rb`, `task_watch.rb`) | A session's background process: builds the `Engine` and `Bridge`, runs queued turns and the wake turns nobody typed (delegate reports, a background task that finished unseen: [Finish wake](internals/background-tasks.md#finish-wake), attached context), exits when idle. A spawned one traps TERM, HUP and INT (`WorkerSignals`, installed by `run_session_loop` when `SAMAGOTCHI_WORKER_PROCESS=1`): the running turn stops as a Stop with reason `signal`, is saved, and the worker leaves (`:signal`, exit 0; a new worker only for input already queued). A running turn is checkpointed at its iteration boundaries (`TurnCheckpoint`, the `interrupted_turn` mark), and the next worker settles a turn its predecessor died in (`TurnCheckpoint.settle`). The session is saved from the turn's thread, Bridge threads and a signal's thread; `Session#save` takes a per-session lock around its snapshot and write, so an older snapshot never lands over a newer one. |
| Config | `config.rb`, `config/restart_watch.rb` | Every setting as an `Entry`: env, config.yml and CLI layers ([configuration.md](configuration.md)); the notice a worker or chi web gets when config.yml changes a setting it reads only at its start. |
| Paths | `paths.rb` (`Paths`) | The XDG base dirs chi's files live under, read from the env on every call: `Paths.state_home` (`$XDG_STATE_HOME`, else `~/.local/state`) and `Paths.config_home` (`$XDG_CONFIG_HOME`, else `~/.config`), both defaults under `Dir.home`; a blank variable counts as unset, a relative one is made absolute from the current directory. `Paths.tilde` shows a path with `~` for the home folder. `SessionManager` hands a spawned worker the spawner's `XDG_STATE_HOME` / `XDG_CONFIG_HOME`, when set, made absolute, so a relative one isn't read from the session's folder. |
| MemoryBundle | `memory_bundle.rb`, `memory_bundle/{installer,builder,installed_bundle,plugin_ref,bundle_hook}.rb` (`Installer`, `Builder`, `InstalledBundle`, `PluginRef`, `BundleHook`) | Installing, building and reading bundles of memories, hooks and plugins. |
| Bundle authoring | `bundle_command.rb` (`BundleCommand`), `bundle_command/{scaffold,check,test_run}.rb`, `bundle_command/try/{run,sandbox,trace}.rb`, `testing.rb` + `testing/` (the test kit) | `chi bundle new`, `check`, `test` and `try`, and the kit a bundle's tests load it with ([bundle-authoring.md](bundle-authoring.md), [internals/bundles.md](internals/bundles.md)). |
| Session config (`--set`) | `session_config.rb` (`SessionConfig`, `SessionConfig::Settings`) | A session's own settings as one value (`Session#settings`, `SessionSetup#settings`): `core`, the `--set KEY=VALUE` values of the core keys marked `session: true` (`Config::Entry`), typed by `Config.coerce!` and read first through `Config.get(key, session:)` (`RecapSetup`; `Engine#session=` rebuilds the recap job, `IdleScheduler#replace_job`), file key `config_settings`; `bundles`, the `--set BUNDLE.KEY=VALUE` values, checked against the manifest's `session_settings:`, laid over `bundles: <name>:` in `ctx.settings` ([plugins.md](plugins.md)), file key `bundle_settings`. `SessionConfig.clash` refuses a bundle setting named like a core one (install, `chi bundle check`). See [configuration.md](configuration.md#per-session-settings). |
| Plugin API | `plugin/api.rb` (`Plugin::Api`), `plugin/tool_spec.rb` (`Plugin::ToolSpec`: a checked tool declaration, how it is registered), `plugin/loader.rb`, `plugin/context.rb` (`ctx`), `plugin/http.rb` + `plugin/http_transport.rb` (`ctx.http`), `plugin/card.rb` (`Plugin::Card`) | What a bundle's plugin registers: tools, commands, annotation actions, hooks, services, toolkits, peer sources; what its handlers get as `ctx` ([plugins.md](plugins.md)). |
| Peer bundles' base | `plugin/peer.rb` (`Plugin::Peer`) | What claude-peer and codex-peer share (the send tool, the command, the cards, payloads); each bundle's subclass sets its strings and transport ([plugins.md](plugins.md#the-claude-peer-bundle)). |
| Shipped bundles | `bundles/` (`mcp`, `github-pr`, `loop-guard`, `skills`, `source-links`, …) | Bundles that ship with chi. |
| Hooks | `hooks/registry.rb` (`Hooks::Registry`), `hooks/loader.rb`, `hook_routes.rb` (`HookRoutes`), `event_routes.rb` (`EventRoutes`) | Hook registration and dispatch; what a hook or plugin does beyond reading its event (notice, question, stop, steer) routed to the UIs (cards and notices through one set of routes) ([hooks.md](hooks.md)). |
| Guardrails | `guardrails.rb`, `guardrails/shell_lex.rb`, `guardrails/data_readers.rb`, `guardrails/rules.rb`, `guardrails/protected_paths.rb`, `guardrails/parent_policy.rb` + `guardrails/parent_approvals.rb`, `guardrail_wiring.rb` | The gate before every tool call: shell lexing (and the commands that only read a heredoc as data), YAML rules, the core checks on chi's own files, approvals, what a parent agent may answer (`guardrails.parent_answers`) ([guardrails.md](guardrails.md)). |
| Delegation | `tools/delegate.rb`, `tools/delegate_result.rb`, `tools/delegate_wait.rb`, `child_reports.rb`, `tools/delegate_relay.rb`, `relay_desk.rb`, `relay_verifier.rb`, `relay_watcher.rb` | Child sessions a session starts and waits on, and their approval relay ([sessions.md](sessions.md#delegating)). |
| send / broadcast | `send_command.rb` (`SendCommand`), `broadcast_command.rb` (`BroadcastCommand`), `broadcast/` | `chi send` and `chi broadcast` ([broadcast.md](broadcast.md), [sub-agent.md](sub-agent.md)). |
| Session access | `session_access.rb` (`SessionAccess`: `NewSession`, `SetupWords`, `WaitStart`, `SessionView`, `Created`, `ContextEntry`, `ContextPush`, the errors `RemoteFailed`, `RemoteTooOld`, `Refused`, `BadRequest`), `session_access/local.rb` (`SessionAccess::Local`), `session_access/remote.rb` (`SessionAccess::Remote`), `session_access/http_transport.rb`, `session_access/web_bridge_client.rb` (`SessionAccess::WebBridgeClient`, a remote attach's worker through chi web), `session_access/dispatch.rb` (`SessionAccess::Dispatch`), `session_access/contract.rb` (`SessionAccess::Contract`), `remotes.rb` (`Remotes`), `remote_command.rb` (`chi remote`), `web/session_access_routes.rb` (`Web::SessionAccessRoutes`) | The seam between the session commands and where the sessions live: `Local` is this machine's (the `SessionManager`, `ReplyWait`, `NoteDelivery`, `ContextSources` and Bridge calls the commands made); `Remote` is another machine's, the same methods as requests to its chi web's routes of the same name (Bearer token, `HTTPTransport`), results as Local's value objects and refusals as the classes Local's callees raise, built from the fields chi web sends; waits and prefixes run on the server, a wait asked again per 30 s slice. `Dispatch` is bin/chi's front for `--remote NAME` / `CHI_REMOTE` (taken off before the subcommand lookup): it refuses what the contract table lists `local_only` (exit 2, one message) and runs the command with a `Remote` on the `Remotes` entry (`$XDG_CONFIG_HOME/samagotchi/remotes.yml`, 0600). chi web's routes answer from `Local` (*chi web's routes for the session commands* above). Checks that read this machine's config or files (vision, parent answers, the cwd's project, `SAMAGOTCHI_PARENT_SESSION`) stay in the commands and are skipped under a `Remote`, where chi web's create, turn and wait routes run the vision, parent-answers and busy checks with the server's config and the worker checks a parent's answer. See [internals/remote-sessions.md](internals/remote-sessions.md). |
| Idle work | `idle_scheduler.rb` (`IdleScheduler`), `idle_recap.rb` (`IdleRecap`), `idle_reminders.rb` | One poller for an idle session's recap and reminders. |
| Attached context | `context_sources.rb` (`ContextSources`), `context_poller.rb`, `context_absorber.rb`, `peer_sources.rb` (`PeerSources`: the sources peer bundles declare) | External sources a session keeps fresh, and the peer loop's wakes ([context.md](context.md)). |
| LLM context strategies | `llm_context_strategy.rb`, `llm_context_view.rb`, `llm_context_stale.rb`, `llm_context_forget.rb` | What a request sends of the history (none, stale, forget) ([internals/llm-context-forget.md](internals/llm-context-forget.md)). |
| Session chains | `session_continue.rb` (`SessionContinue`), `session_chain.rb` (`SessionChain`) | A session that continues an earlier one. `SessionChain.opener_for` gives the text web `continue →` prefills in the new link: the previous link's own first typed message when that link continues one itself, else nil (the 201's `opener`; not saved) ([sessions.md](sessions.md)). |
| Review sessions | `review_start.rb` (`ReviewStart`), `session_review.rb` (`SessionReview`, the session's `review` field), `review_command.rb` (`ReviewCommand`, `chi review`), `review_apply.rb` (`ReviewApply`) | A session made to be shared: idle, its subjects project files checked by `Guardrails::ReviewPaths`, a fork of a working session from its recap (`--from`); Apply quotes a participant's review turn into the owner's composer ([sessions.md](sessions.md#review-sessions), [internals/participants.md](internals/participants.md)). |
| Behind an auth proxy | `web/public_url.rb` (`Web::PublicUrl`: `web.public_url`, `web.proxy.identity_header`, `web.proxy.owner`), `web/proxy_gate.rb` (`Web::ProxyGate`, mixed into App; `RawHeaderNames`, prepended to WEBrick's request by `Web::Server`), `web/link_codes.rb` (`Web::LinkCodes`: the links' one-time codes), `proxy_trace.rb` (`ProxyTrace`), `web/public/token_fragment.js`, `web/public/auth_lost.js`, `web/tunnel.rb` + `web/tunnel/tailscale.rb` (`Web::Tunnel`, `Web::Tunnel::Tailscale`: `chi web --tunnel tailscale`, Tailscale Serve set for one run and the PublicUrl it makes) | Experimental: chi web behind an auth proxy. Every request needs the token; a proxied one's owner also needs the identity header (one clean value under one name); the `__Host-` cookie, an absolute `Location` from the public URL, https links with a one-time code in the fragment; the page's lost-sign-in banner. Bridges refuse proxy traces ([configuration.md](configuration.md#behind-an-auth-proxy)). |
| Participants | `participants.rb` (`Participants`, the `participants.json` sidecar), `share_command.rb` (`ShareCommand`, `chi share`), `session_participants.rb`, `participants_watch.rb`, `web/grants.rb` (`Web::Grants`), `web/principal.rb` (`Web::Principal`), `web/participant_access.rb` (`Web::ParticipantAccess`: the participant's gate and routes), `web/participants_admin.rb` (`Web::ParticipantsAdmin`: the owner's invite, list, revoke, cap and Apply routes), `web/participant_review.rb` + `web/participant_view.rb` (`Web::ParticipantReview`, `Web::ParticipantView`), `web/participant_stream_filter.rb`, `guardrails/review_boundary.rb` + `guardrails/review_paths.rb` | The people or agents an owner invites to review one session through chi web: their grants and gate, what they read, their read-only review turns ([internals/participants.md](internals/participants.md), [guardrails.md](guardrails.md)). |
| Analytics | `analytics_file.rb` (`AnalyticsFile`), `session_metrics/totals.rb` (`SessionMetrics::Totals`), `session_metrics/model_segment.rb` (`SessionMetrics::ModelSegment`) | A session's `analytics.json` (`SessionMetrics#persist`); the sums over its turn records (`Totals`: tokens, cost, speeds, kept as running counters) and their split per model after a `/model` switch (`ModelSegment`: a run of turns on one model, the `model_segments` rows); `session_metrics/cost.rb` (`SessionMetrics::Cost`): the spend `ctx.cost` reads; `session_metrics/usage.rb` (`SessionMetrics::Usage`): the work `ctx.usage` reads. `session_metrics/side_totals.rb` (`SessionMetrics::SideTotals`) and `side_usage.rb` (`SideUsage`): the side requests' sums, apart from the turns'. |
| Images / vision | `image_store.rb` (`ImageStore`), `vision_support.rb`, `vision_context.rb` | Stored prompt images and whether a model takes them. |
| Toolkits | `toolkit.rb` (`Toolkit`), `toolkit_binding.rb` (`ToolkitBinding`, the Engine's seam), `toolkit_command.rb` (`/toolkit`), `tools/registry.rb` (`Registry#toolkit`, `#left_out_names`), `web/public/toolkit_chip.js` | Which registered tools a session's prompts declare: saved in the session, resolved at a turn's start (`Engine#apply_toolkit!`), named in the prompt's not-loaded line, a kit's prompt text after the appended files; `chi.toolkit` and `ctx.use_toolkit` for plugins ([configuration.md](configuration.md#toolkits)). |
| Tool index | `tools/tool_index.rb` (`Tools::ToolIndex`), `tools/deferred_tools.rb` | `find_tools` and `call_tool`: the tools a session knows but doesn't declare one by one (an mcp bundle's servers through `chi.tool_source`, the built-ins its toolkit leaves out), searched and called by name ([plugins.md](plugins.md)). On `api: anthropic` they also go out deferred, a hit loads its matches and the model calls them by name ([internals/anthropic.md](internals/anthropic.md)). |
| Tool output cut | `tool_output_cut.rb` (`ToolOutputCut`), `tool_output_files.rb` (`ToolOutputFiles`) | A tool's output over `max_tool_output_chars`, cut by the tool's policy; an execute's whole output saved in the session's `tool_output/` folder ([internals/tool-guardrails.md](internals/tool-guardrails.md)). |
| Steer delivery | `steer.rb` (`Steer`), `delivery.rb` (`Delivery`), `steer_cut.rb` (`SteerCut`), `generation_phase.rb`, `waiting_steer.rb`, `steer_cut_after.rb` (`SteerCutAfter`), `cut_policy.rb` (`CutPolicy`) | A message for a running turn: at the next boundary, cutting a thinking-only generation, or queued for the turn's end ([internals/engine.md](internals/engine.md)). |
| Prompt files | `prompt_files.rb` (`PromptFiles`) | The AGENTS.md chain (root → cwd) and the appended files the system prompt carries. |
| Model settings | `effective_model.rb` (`EffectiveModel`, `ModelChoice`), `model_profile.rb` (`ModelProfile`), `model_settings.rb`, `sampling_settings.rb`, `model_catalog.rb` (`ModelCatalog`), `model_notes.rb` (`ModelNotes`) | The effective model's settings as one snapshot per read, a model's prompt format, its `models:` entry, its request parameters, the pickable model rows (`chi models`, `/api/models`), the notes its prompt loads. |
| Session settings | `session_setting.rb` (`SessionSetting`), `session_model_settings.rb` (`SessionModelSettings`), `level_setting_command.rb` (`/thinking`, `/reasoning-history`), `llm_context_command.rb`, `toolkit_command.rb`, `thinking_notices.rb` (`ThinkingNotices`) | A session's own llm_context, thinking, reasoning_history and toolkit: their chips (session state, `/stats`, `:command_ran`, the web), the commands that set them, the thinking level's notices. |
| Dialects | `llm/dialect.rb` (`LLM::Dialect`) | What an `api: anthropic` provider's `/v1/messages` does differently (`dialect: fireworks`) ([internals/anthropic.md](internals/anthropic.md)). |
| Logging | `log.rb` (`Log`), `log_subscriber.rb` (`LogSubscriber`), `log_path.rb` (`LogPath`), `log_line.rb` | The debug log: tagged records, a session's event trail, where the file goes ([configuration.md](configuration.md#debug-log-file)). |
| Stores | `reminder_store.rb` (`ReminderStore`), `recap_store.rb` (`RecapStore`) | A session's reminders, and its idle recap (`recap.json`). |
| Setup and update | `bootstrap_command.rb`, `bootstrap/`, `update_command.rb`, `gem_update.rb` | `chi bootstrap` (first config.yml, system bundle, core profile) and `chi update` (the gem, shipped bundles, the macOS helper). |
| Process groups | `process_group.rb` (`ProcessGroup`) | A command in a process group of its own, stopped as a group (TERM, grace, KILL): execute, tasks, context fetches, the mcp bundle's servers. |
| Desktop | `desktop.rb`, `desktop/macos.rb`, `desktop_command.rb`, `desktop/macos/*.swift` | `chi desktop`, the macOS "Send to chi" helper ([desktop.md](desktop.md)). The helper's Swift side: the panel (`Panel.swift`), the chi CLI runner (`ChiRunner.swift`), agent terminals behind `AgentTerminal` (`AgentTerminal.swift`, `Kitty.swift`, `Tmux.swift`; `ChiHelper --agents` is their CLI seam). |
