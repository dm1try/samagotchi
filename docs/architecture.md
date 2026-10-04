# Samagotchi Architecture

A compact visual overview of the current architecture, then the core API in prose
(see [Core and UI](#core-and-ui)).

## System map

```
                          ┌─────────────────────────────────────────┐
                          │               bin/chi                    │
                          │           (CLI entry point)             │
                          └───────────────────┬─────────────────────┘
                                              │
                     ┌──────────────────────────┴──────────────┐
                     │           TerminalUI                     │  ← REPL (Reline),
                     │   render · status line · REPL commands   │    rendering, commands
                     └──────────────────────────┬──────────────┘
                                                  │ delegates
                      ┌───────────────────────────┴───────────────────────┐
                      │                    Engine (core logic)             │
                      │   system prompt · memory injection                  │
                      │   tool declarations · session lifecycle           │
                      │   model↔tool loop — `run_turn`                    │
                      └───────────────────────────┬───────────────────────┘
                                                  │ delegates
                     ┌────────────────────────────┴──────────────┐
                     │             Web::App (Rack)                │ ← browser UI
                     │   session hub · /api/events · /api/*        │   via SessionManager file IPC
                     └───────────────────────────┬───────────────┘
                                                   │
        ┌───────────────────────────────┬──────────┴───────────────┬──────────────────┐
        │                                 │                          │                  │
  ┌─────┴─────┐                   ┌───────┴───────────┐    ┌────────┴───────┐  ┌───────┴────────┐
  │ KernelLoop │◀── drives────────▶│     Model API      │    │    Session      │  │ SessionManager │
  │  (the loop)│                   │   (LLM HTTP call)   │    │  (state,       │  │  (bg workers)  │
  └─────┬──────┘                   └─────────────────────┘    │  history)      │  └────────────────┘
      │                                                          └──────────────────┘  └────────────────┘
      │ run_turn events (turn_started, turn_completed,
      │ turn_canceled, raw KernelLoop events)
      ▼
  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │                                       Tools                                         │
  │  execute · read · edit · write · memory · web_fetch · task_create/get/list/          │
  │  task_stop/wait                                                                    │
  │  declared via tool_declarations.rb                                                 │
  └──────────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │                                   Persistence                                      │
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
  about the terminal.
- **`TerminalUI`** (`lib/samagotchi/terminal_ui.rb`) owns the REPL and rendering; it
  delegates all core work to an `Engine`.
- The `on_event:` seam on `run_turn` exposes raw `KernelLoop` events plus the
  higher-level turn events, so any new UI can render without terminal coupling.

## Request / turn flow

```
bin/chi ─▶ TerminalUI ─▶ Engine#run_turn ─▶ KernelLoop ──┬─▶ Model API (LLM)
        (builds)          │                            └─▶ Tool call(s) ─▶ Tool
                          │                                 │
                          └── on_event: ─▶ render update ────┘
                                    (turn started / completed / canceled)
```

## Layers at a glance

| Layer | Class(es) | Responsibility |
|-------|-----------|----------------|
| Core | `Samagotchi::Engine` | System prompt, memory injection, tool declarations, session lifecycle, model↔tool loop (`run_turn`). No terminal coupling. |
| UI | `Samagotchi::TerminalUI` | REPL (Reline), rendering, REPL commands. Delegates all core work to an `Engine`. |
| Model loops | `KernelLoop` (via `LLM::NativeBackend`), `LLM::ChatLoop` | The model↔tool loop: raw prompt or OpenAI chat API, chosen per host (see below). |
| Adapters | `Samagotchi::Client`, `LLM::OpenAIChat`, `LLM::HTTP` | Raw-prompt servers, the OpenAI chat API, and the HTTP both share. |
| Tools | `lib/samagotchi/tools/*` | Execute, read, edit, write, memory, task_*, web_fetch, plus runtime/output-guardrails. |
| Background | `Samagotchi::SessionManager` | Builds `Engine` directly (no terminal rendering) for workers. |
| Web | `Samagotchi::Web::App`, `Samagotchi::Web::Server`, `Samagotchi::Web::SessionHub` | Rack+WEBrick single-port `127.0.0.1:4567` (index.html + `/api/*` + SSE). The hub is chi web's projection of the session list, pushed to every tab over `GET /api/events`. |
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
- `bin/chi web` → builds `Web::Server` (Rack+WEBrick on `127.0.0.1:4567`, `--port`/`SAMAGOTCHI_WEB_PORT`, `--open`).
- `bin/chi sessions {list,stop,delete,prune,clean}` (`SessionsCommand`; not the REPL's `SessionCommands`) → retention & ordering (`SessionRetention`, `updated_at desc`, dry-run, test-only); `stop` is `SessionManager.stop_session(wait:)`, which waits for the worker to release `owner.lock`; `delete` (`SessionDeleteCommand`) is `SessionManager.delete_session(stop:)`, which the TUI's `/exit --delete` and the web's `DELETE /api/sessions/:id` use too.
- `--prompt`, `--non-interactive`, and `SessionManager` workers build `Engine` directly.

## Session retention & ordering

- **Files:** `~/.local/state/samagotchi/sessions/<uuid>.json` + `<uuid>/input|output|owner.lock|bridge.json` (XDG-aware), and the `<uuid>/stopped` and `<uuid>/archived` marker files.
- **Single owner:** the process running a session's Engine (worker or in-process TUI) holds a flock on `owner.lock` (`OwnerLock`); a second owner backs off, and the web answers 409 for a TUI-owned session.
- **Status:** `status` is turn state (`idle`/`running`); liveness is the lock. A stop is the `<uuid>/stopped` marker (`Session.mark_stopped`; a resume removes it), which `Session.load` and `.summary_from_file` read as status `stopped`, so no other process rewrites a worker's session file.
- **Retention:** 14 days / 500 cap (env `SAMAGOTCHI_SESSION_RETENTION_DAYS`/`MAX_COUNT`, optional `KEEP_STATUS`), live-owner guard, only when `*.json` present; lazy sweep ≤1/24h from the session hub's full-probe tick (and on `GET /api/sessions`, which the page no longer calls) & `Dashboard#render_list`, manual via `bin/chi sessions prune --dry-run`.
- **Ordering:** `Session.list(sort:,order:,limit:,offset:)` and `GET /api/sessions?sort=&order=&limit=&offset=` default `updated_at desc`; Web UI sort/filter/pagination.
- **Test hygiene:** `test_run` flag when `SAMAGOTCHI_ENV=test`/`RACK_ENV=test`/`CI`, targetable via `prune --test-only` / `clean`.

## Core and UI

Samagotchi is split into a **core engine** and a **terminal UI**. The core holds all
agent logic and can be used without any terminal rendering; the UI is a thin layer on top.

| Layer | Class | Responsibility |
|-------|-------|----------------|
| Core | `Samagotchi::Engine` | System prompt, memory injection, tool declarations, session lifecycle, the model↔tool loop (`run_turn`). No terminal coupling. |
| UI | `Samagotchi::TerminalUI` | Interactive REPL (Reline), rendering (ANSI, spinner, status line), REPL commands. Delegates all core work to an `Engine`. |
| Model loops and adapters | `KernelLoop`, `LLM::ChatLoop`, `Samagotchi::Client`, `LLM::OpenAIChat`, `LLM::HTTP` | The model↔tool loops and the HTTP adapters they talk through (see "Model loops and adapters"). |
| Bridge (SSE/HTTP) | `Samagotchi::Bridge`, `SessionManager` | The **single live client transport**: an SSE read stream + HTTP POST turn/cancel/answer surface that attaches to a worker's existing `Engine` via `Engine#subscribe`. Every session worker starts it (bound `127.0.0.1`, no auth, localhost-only). |
| Web (Rack) | `Samagotchi::Web::App`, `SessionManager` | Single-port `127.0.0.1:4567` control plane via `rack`+`webrick` (serve `index.html` + `/api/*`; `/stream` proxies each session's Bridge). `bin/chi web` entrypoint. |
| Sessions | `Samagotchi::Session`, `SessionManager` | File-based `~/.local/state/samagotchi/sessions/<uuid>.json` + sidecar `input/`/`output/`; retention (14d/500) + ordering (`updated_at desc`). |

- `bin/chi` in REPL mode (see `LaunchMode` above) builds `TerminalUI`. `TerminalUI#run` is the single
  dispatch for the REPL, `-p`/`--prompt`, `--non-interactive`, and `--resume`: it
  builds the working session once, runs a single prompt turn when `-p` is given,
  then either exits (`--non-interactive`) or drops into the REPL carrying the
  post-turn conversation.
- `SessionManager` background workers build `Engine` directly (no terminal rendering).
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

- `:turn_started` — `{ session_id:, prompt: }`
- `:turn_completed` — `{ result: }` (the final `LLM::ModelResult`)
- `:turn_canceled` — `{ cancellation_reason:, cancelled_by: }` (`cancelled_by`: the bundle or hook label that
  stopped it, for `cancellation_reason: :hook`; else nil)

Every event is a `Hash` with a `:type` symbol key; the sink must not raise (the Engine
rescues sink errors). A new UI (web, API) supplies its own `on_event` and
renders whatever it needs from the stream + final `Result`. The public Engine API:

```ruby
engine.run_turn(session, prompt, on_event: nil, max_iterations: nil, cancel_controller: nil) # nil: turn.max_iterations
engine.run(session: nil, prompt: "...", on_event: nil)   # create/resume session + run
engine.system_prompt     # fully built system prompt string
engine.session           # current session (Engine owns create/resume)
```

The system prompt (`SystemPrompt#build`) is the base prompt, then rg guidance, the
identity and the preloaded memories, AGENT.md, the memory indexes, and last **the
model** (`Model: this session runs on <ref> (host …; model key …)` and a line telling
the model to answer "which model are you" from it, not from training), the working
directory and the session id and log (Gemma's native tool declarations still follow).
The order is for the servers' prompt caches, which reuse only an exact token prefix:
what every session shares first, what changes least before what changes more, the
per-session lines last, so a new session reuses everything above them. It is built
once per loop and rebuilt only by a model switch (or changed tools), so the model
line costs no KV churn.
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
  An attached terminal's stream (`EventStream` with `rediscover:`) looks for the session's live
  worker whenever it drops: a new one (a restart) is followed from its snapshot, and the terminal
  sends its requests there (`worker_changed`); it gives up after ~12 s, or at once when the session
  was stopped.
- `POST /session/:id/turn` — fire-and-forget turn creation; returns `202` with an `enqueued_id`
  (delivery is at-least-once via the worker's file-IPC input path — it never calls `run_turn`
  across the HTTP boundary). Only the bridge's own session: another id, in the path or the body's
  `session_id`, is `404 unknown_session`. Inspect results through the read surface, not the turn response.
  An optional `deadline` (epoch seconds; `BridgeClient` sends 5/6 of its read timeout ahead) makes
  a request read after it (a worker frozen by sleep or SIGSTOP) answer `408 deadline_passed` and
  not run: a client that timed out has said the message was not sent. `/answer`,
  `/question/dismiss` and `/command` take the same `deadline` (a command is checked with the event
  log held, as a turn is), and the Bridge logs `turn_expired`, `answer_expired`, `dismiss_expired`
  or `command_expired`. The web app answers either kind of timeout with `504 worker_timeout`
  ("… so the command was not run"). `/cancel`, `/recap` and `/exit` take none.
  The web relays answer, dismiss, command and cancel the same way (`App#relay`): a 408 or a read
  timeout is `504 worker_timeout`; a Bridge 404 for a route an older worker lacks is
  `501 not_supported` with the restart hint; a Bridge `404 unknown_session`, no bridge or a
  refused connection is `503 not_live`.
- `POST /session/:id/cancel` — cancel the running turn; `202`, or `409` when none runs.
- `POST /session/:id/answer` — answer the pending question; `200`, `409` when another client
  answered first or it is gone, `400` for an invalid selection. With `client_id: "cli:answer"`
  (`chi answer`, a parent agent) an allow on an approval beyond the worker's
  `guardrails.parent_approvals` is `403 parent_approval_refused`, the question still open.
- `POST /session/:id/question/dismiss` — leave the question unanswered (an approval: denied);
  `200`, or `409` when it is no longer pending.
- `POST /session/:id/relay` — the approval relay, on a delegated child's worker
  (`{action, relay_id, question_id}`): `opened` / `closed` (with a `reason`) set or clear the
  pending question's `relayed_to` mark (`QuestionDesk#annotate`, `:question_relay`); `answered`
  makes the child ask its parent's Bridge for the answer (`RelayVerifier`) and take it only for
  this child and the question pending now. `200`, `409` no longer pending, `403` a parent agent's
  allow beyond the child's `guardrails.parent_approvals`, `422 relay_unverified` (the question
  stays open).
- `POST /session/:id/relay/status` — on a parent's worker, `{relay_id}`: what its `RelayDesk`
  (memory only) holds for that relay (`child_id`, `child_question_id`, `state`, `answer`, `by`);
  `404` for an unknown id. A POST with a body because routes match exact paths.
- `POST /session/:id/command` — a session command (`/model`, `/models`, `!rollback`, `!cmd`,
  `/continue`) for the worker loop; `202` with a `command_id` its `:command_ran` names, `400` when
  the line isn't one.
- `POST /session/:id/exit` — ask the worker to exit now (`{client_id:}`). The worker checks with
  the event log held (`WorkerIdleExit#hold_for_request`): `200 {status: "exiting"}` and it leaves
  like an idle exit, or `409 {status: "held", reason:}` with `turn_running`, `input_queued`,
  `continue_offered`, `client_connected` (a stream not named by the asker), `reminders` or
  `starting`.
- `GET  /session/:id/state` — `session_state_snapshot` (JSON).
- `GET  /session/:id/stats` — `Engine#stats_snapshot` for attached `/stats`: the metrics, with the context window and prompt profile asked from the server before the first turn.
- `GET  /session/:id/snapshot` — the snapshot frame's content as one request (the web server renders
  the messages itself, then streams from its `event_seq`). Read by the web's full show
  (`GET /api/sessions/:id`, `?parts=1`) and the plugin's `list_sessions`; every message is copied.
- `GET  /session/:id/tail` — the page's light re-read (`Bridge#tail_frame`): `session_state_snapshot`,
  `answer` (the last message a UI shows as an answer, `AnswerTail`: the one message, copied alone),
  `cards` (`CardStore#list`), `event_seq`, `event_id`, all taken in one event-log hold; no message
  list, so it costs the same however long the session is. `?turn_id=` answers that turn's answer
  (an unknown or missing id: the newest); the only route that reads its query.
- `OPTIONS *` — CORS preflight (`Access-Control-Allow-Origin: *`).

The metrics in `/state`, `/snapshot`, `/stats` and the SSE `snapshot`/`reset` frames
(`SessionMetrics#snapshot`) carry the session's totals and only the recent timing records: the
newest turn the worker finished and any it hasn't saved yet (at most 20 turns), with their tool
calls and the running turn's finished ones. The full history is the session's `analytics.json`,
which `SessionMetrics#persist` rewrites after each turn; the web server merges the two by id.
The totals' `tokens` block adds the cached, cache-write and reasoning sums, the cost, the decode time and tokens
behind the average speed (`avg_decode_tps`) and the last speeds (`last_decode_tps`,
`last_prefill_tps`, `tps_source`: `server` or `estimate`). Each `generation_completed` event
carries the generation's `speed` (`{decode_tps, source}`, null without one), its own prompt-cache
counts (`prompt_tokens`, `cached_tokens`, `cache_write_tokens`: null when the server reported no writes) and
those running `tokens`: the Engine closes the generation in `SessionMetrics#finish_generation` before relaying
it, so the web's info bar updates per generation without parsing chunk payloads.

The page's frequent reads of `GET /api/sessions/:id` stay light too:
- `?tail=1&recent=1` (each turn's end, a cancel, an answer display): `{tail, session: {id, status,
  used_memory_names}, messages: [the answer], markdown_warning, timing}`, from the worker's `/tail`
  alone (no session file parsed, no `analytics.json`); `timing` carries the worker's recent records
  and `turn_count` (finished turns). The page merges the records by id (`timing.js mergeTiming`) and
  finishes the ended turn's own line by its `turn_id` (sent as `&turn_id=`, which also picks that
  turn's answer). A plain `?tail=1` (a tab opened before this) gets the whole timing.
- `?timing=1`: the whole timing (`analytics.json` merged with the worker's `/state`) and
  `turn_count`, when the page's merge came up short.
- `?cards=1`: the cards, from `/tail`; the session file is only stat'ed for the 404.

A worker without `/tail` (an older chi; `404 not_found`) is read through `/snapshot` in the same
shape; any other failure (no worker, a 500, a timeout) reads the disk, trimmed to the newest
turn's records with `recent=1`.

Every route goes through `Bridge#dispatch`: an id other than the bridge's own session is
`404 unknown_session`, and a handler that raises answers `500 bridge_error` (logged as
`handler_failed`) rather than dropping the connection.

The per-session port is OS-assigned (bound to `0`) and published to a `bridge.json` sidecar
for client discovery. `chi web`'s `GET /api/sessions/:id/stream` proxies this bridge
(503 `not_live` when the worker is not running; full history of any session is served by
`GET /api/sessions/:id/output`). Resume/ring-buffer state is **in-memory** (v1) — durable
cross-process resume is a staged next step, not part of v1.

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
(`Bridge::FEATURES`, what a client may ask of it beyond the routes). A worker's Bridge snapshot
names its `chi_version` too.
`POST/DELETE /api/sessions` and `/stop` rescan the session before answering (`SessionHub#touch`).
`GET /api/sessions` is the hub's projection too (its sort, paging and total). `Server` always builds
a hub; an `App.new` without one answers both routes `503 no_hub`.

## Model loops and adapters

A model ref (`--model`, `/model`, `default.model`, an alias's target) is parsed
by one pure resolver, `ModelRef.parse` (host prefix, alias), given the configured
hosts and aliases; `HostRegistry` routes a name that names no host (its model
index after `/models`) and builds the `ModelTarget`.

Engine picks the loop from the effective model's host (`HostRegistry#resolve`):

| Loop | Class | Host | Talks through |
|---|---|---|---|
| Raw prompt | `KernelLoop`, wrapped by `LLM::NativeBackend` | no `api:`, or `llama_cpp`/`mlx`/`omlx` | `Client` (`/completion` or `/v1/completions`), chi's own Gemma/Qwen prompt and tool-call parsing |
| Chat | `LLM::ChatLoop` | `api: openai` | `LLM::OpenAIChat` (`/v1/chat/completions`, streamed, native tool calls) |

Both return an `LLM::ModelResult` and emit the same stream events; tool calls in
both go through `ToolRunner` (events, hooks, veto, output cap) and
`KernelLoop#dispatch_tool_call`. Every format's built-in calls (Gemma, Qwen,
chat `tool_calls`) are built by one table, `Tools::BuiltinCalls`, from the
parsed `{name, args}` (derived from `TOOL_SCHEMAS`), so a call looks the same to
hooks and tools whichever model made it. Both loops' `generation_chunk` carries
`thinking:`, `text:` and `content:` (both): the chat loop's thinking is the
server's `reasoning_content`; the raw-prompt loop splits each generation's
stream with a fresh `ThoughtStreamSplitter` (Qwen's `<think>` and Gemma's
`<|channel>thought … <channel|>` are thinking, tool-call bodies are dropped
from `text:`). The chat loop's model turns keep their `tool_calls` and tool results their `tool_call_id`,
so later requests and resumed sessions pair them. It has its own system prompt
(no raw-prompt tool declarations; the tools go as JSON schemas).

`Engine#build_stream_event_handler` is the one seam both loops' streams pass
through: with a `:generation_progress` hook registered it feeds a
`Hooks::StreamWatch` each chunk's thinking and text after the UIs had it. A
hook's `stop_generation` cancels the generation's own controller (a child of
the turn's, `CancellationController#generation`), and each loop takes the cut
as an empty answer and asks again.

Both loops keep one `EmptyAnswerRetry` per turn (the `retry.empty_answer`
budget, the hidden nudge, the retry's sampling), and both end each
generation's `:generation_completed` with a `finish_reason`: the chat host's
own, or for the raw-prompt loop what `Client::Transport#finish_reason_from`
reads from the stream's last payload (llama.cpp `/completion`'s `stop_type`:
`limit` is `length`, `eos` and a stop word are `stop`; `/v1/completions` sends
its own). An empty answer with a `length` stop and the context 90 % full or
more is not asked again (a full window, not a thinking loop); with no finish
reason it is. Both also keep one `ContextStatus` per turn: before each request
it estimates how full the window is (the server's last count plus what the turn
appended since), emits `:context_status` on a bucket change, and on a rise past
the second threshold puts the model's own `[CONTEXT: …]` line on the tail as a
system message (docs/internals/context-telemetry.md).

**Adapters.** `Client` (raw-prompt servers) and `LLM::OpenAIChat` (one per host,
`HostRegistry#adapter_for`) share `LLM::HTTP`: timeouts, TLS for https, a line
reader for streamed bodies, the retry loop (`retry.*`; network errors, 429 and
500/502/503/504/529, honouring `Retry-After`; never after a stream has produced
output) and cancel. Cancel closes the in-flight socket from the
`CancellationController` listener, so it works on any thread.

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

**Keys.** A host's API key comes only from the environment variable its
`api_key_env:` names; it never reaches config.yml, `HOSTS_JSON`, `chi self`,
logs or events.
