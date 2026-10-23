# Remote sessions

`chi --remote NAME <command>` (or `CHI_REMOTE=NAME`) runs chi's session commands (`send`, `answer`, `note`, a
session's `context`, `sessions list/stop/restart/archive/unarchive/delete`) against another machine's sessions. The
sessions, workers, memories and code stay on that machine; this one only sends requests and prints the answers.
User-facing behaviour is in [cli.md](../cli.md#remote-sessions). This page is the code's shape, for changing it.

**The one rule:** the remote side is that machine's **chi web**, never a worker's Bridge. Bridges stay on loopback.
chi web answers each request by calling the same `SessionAccess::Local` operation the CLI would call there.

## The seam: `SessionAccess`

Each session command takes an `access:` backend (default `SessionAccess::Local`) and sends every session read or write
through it. Both backends have the same methods and raise the same errors with the same words.

| Piece | File | Role |
|---|---|---|
| `SessionAccess` | `lib/samagotchi/session_access.rb` | The module: value objects and error classes (below) |
| `Local` | `session_access/local.rb` | This machine: the `Session`, `SessionManager`, `ReplyWait`, `NoteDelivery`, `ContextSources` and `BridgeClient` calls the commands used to make, moved here |
| `Remote` | `session_access/remote.rb` | Another machine: each method is one request (or a loop of them) to chi web's route of the same name |
| `HTTPTransport` | `session_access/http_transport.rb` | `Net::HTTP`, one connection per call, `Authorization: Bearer <token>`; returns `HTTPTransport::Reply` (`status`, `body`, `json`, `#error`) |
| `Dispatch` | `session_access/dispatch.rb` | bin/chi's front for `--remote` / `CHI_REMOTE` |
| `Contract` | `session_access/contract.rb` | Which commands, subcommands and flags are `:supported` remotely and which are `:local_only` |
| `Remotes` | `lib/samagotchi/remotes.rb` | `remotes.yml`: `Remotes::Entry` (`name`, `url`, `token`, `#label`) |
| `RemoteCommand` | `lib/samagotchi/remote_command.rb` | `chi remote add / ls / rm` |
| `Web::SessionAccessRoutes` | `lib/samagotchi/web/session_access_routes.rb` | The chi web routes the page didn't already have, each calling `Local` (included in `Web::App`) |

The value objects (`Data.define`, no hashes across files) are `NewSession` (what `send --new` asks for), `SetupWords`
(the `--new` setup flags as typed, for the server to check), `SessionView` (`Remote#show`; `Local#show` returns the
`Session` itself, which has the same fields but `owner`: both backends answer `#owner(id)`), `Created` (`Remote#create`; Local returns the `Session`), `WaitStart` (the
pre-send state for a wait), `ContextEntry` and `ContextPush`. `Remote` also returns the existing callee types
(`SessionManager::DeliverResult`, `NoteDelivery::Result`, `ReplyWait::Result`, `BridgeClient::Response`,
`SessionManager::Restarted`) so that the commands can't tell the backends apart. A command checks `@access.remote?` where the backends must
differ.

### Dispatch: choosing the backend

`bin/chi` calls `Dispatch.from(ARGV)` **before** its `SUBCOMMANDS` lookup, because `--remote` comes before the
subcommand:

- It strips any leading `--remote NAME` / `--remote=NAME` words (if there are several, the last one wins). A missing,
  blank or dash-led name raises `Dispatch::Usage` (exit 2). Then it reads `CHI_REMOTE` (trimmed). The flag beats the
  env. There is no default remote.
- `here?`: `chi remote …` (`ALWAYS_HERE`), and a bare `--version` / `-h` / `--help`, run locally as usual.
- `#run`: an unknown command exits 1. `#refusal` is the single local-only message, `chi <words> runs on this machine
  only: run it on <remote>` (exit 2). `<words>` comes from `Contract`: a `MACHINE` command, an unlisted command, a
  `:local_only` command, subcommand or long flag, or a run flag (`RUN_FLAGS`: `--attach`, `--resume`, `-p`,
  `--shared`, `--no-shared`; with no command at all it reads "(a session in this terminal)").
- Otherwise it calls `Remotes.find`, then `Samagotchi.const_get(klass).new(argv, access: Remote.new(entry)).run`.
  `Remotes::Invalid` (including `NotFound`) exits 2. A `RemoteFailed` that escapes the command prints
  `chi <cmd>: <message>` and exits 1.

### Contract

`Contract::TABLE` maps `"command"`, `"command sub"` and either one followed by a long flag (`"context add --cmd"`) to
`SUPPORTED` or `LOCAL_ONLY`. A `LOCAL_ONLY` command or subcommand lists no flags. `MACHINE` holds bin/chi's
non-session commands (`bootstrap update models desktop memory bundle remote`). `spec/session_access_contract_spec.rb`
reads bin/chi's `SUBCOMMANDS` and each command's `FLAGS`. It fails when a subcommand, a subcommand of a supported
command, or a flag of a supported command is missing from both lists, or when the table lists something that doesn't
exist. **A new session command or flag fails that spec until you choose one.**

## One request, end to end

`chi --remote studio send ab12 -m "fix it" --wait`:

1. **bin/chi → Dispatch.** The flag is removed. `send` and `send --message` / `--wait` are `SUPPORTED`. `Remotes.find("studio")`
   reads `$XDG_CONFIG_HOME/samagotchi/remotes.yml`. Then `SendCommand.new(argv, access: Remote.new(entry)).run`.
2. **SendCommand.** The client-side checks (UI-only slash commands, image ingest) run. The machine-local ones are
   skipped (next section). `run_wait` → `ParentWait#resolve` → `Remote#resolve`.
3. **Remote → HTTPTransport.** The first request on a `Remote` is preceded by `check_server!`, which sends
   `GET /api/info` and needs `app: "chi-web"` plus the `session_commands` feature. Next come
   `GET /api/sessions/resolve?id=ab12` and `POST …/wait/prepare {busy: true, queue:}` (`Remote#busy`), then
   `POST …/wait/prepare {turn, created}` for the `WaitStart`. `deliver` calls `Remote#show` and `#owner` (each
   `GET /api/sessions/:id?brief=1`), then
   `POST …/turn {prompt, client_id: "cli:send", history: false}`. A 202 ack becomes a `DeliverResult` with `via`
   (`bridge` or `file`).
4. **chi web.** `Web::App#route` runs the Host check (`local_host_header?`), then `cross_site?`, then in LAN mode for a
   non-loopback peer `token_gate`. Then comes the `ROUTES` match. An id that isn't `Session.valid_id?` gets a 404
   before any handler runs. A `:session` route turns an `ArgumentError` into its unknown-session 404. The handlers in
   `SessionAccessRoutes` call `session_access`, a `SessionAccess::Local` on chi web's own state dir. The page's older
   routes (`/turn`, `/answer`, `/stop`, …) call `SessionManager` and the Bridge directly, as before.
5. **The wait.** `ParentWait#wait_for_reply` → `Remote#wait_reply` loops on `POST …/wait` with
   `timeout: min(time left, WAIT_SLICE)` (30 s). The server runs `ReplyWait.call` for at most `WAIT_MAX_SECONDS` (30 s)
   and returns the `ReplyWait::Result` fields plus `parent_strategy`. On a `timeout` status the client asks again until
   its own `--timeout` runs out, at which point it builds the `timeout` result itself. A 503 `server_stopping` (chi web
   shutting down mid-wait: `ReplyWait`'s `cancelled:` returns `:canceled`) is retried after `RETRY_AFTER` (1 s).
   `HTTPTransport::READ_TIMEOUT` (75 s) is set above the longest answer, a wait slice or a create's wait for its worker.
6. **The report.** `ParentReport.report` prints it as it does locally. It uses `Remote#parent_strategy`, which
   is the last wait's `parent_strategy` (the server's config.yml tightened by the session's own), or `HARD` if no wait
   has returned one. The exit codes match the local ones (3 for a question, 130 for Ctrl-C). The commands it prints
   are spelled by `via:`, the backend's `invocation` (a `ChiInvocation`): `chi --remote NAME answer …` remotely, and
   what runs here only (`--attach`, `--resume`) gives way to "chi web on NAME". The commands pass it to each text that
   prints a command (`ParentReport`, `SendCommand::Busy#message`, `sessions stop`, `AnswerCommand`).

The routes, their bodies and their refusals are tabled in [architecture.md](../architecture.md), *chi web's routes for
the session commands*. Keep that table in step with `SessionAccessRoutes`.

## Errors: one condition, one message

- **Refusals.** `SessionAccessRoutes#refusal_response` (and the page routes that raise) send
  `{error, detail, message, …fields}`: `detail` is the page's wording, `message` is the exception's own text, and the
  fields are those the class is built from (`session_id`, `reason`, `ids`, `busy_id`, `version`).
  `Remote#raise_refusal` rebuilds the class that Local's callee raises: `ArgumentError`, `Session::AmbiguousId`,
  `SessionManager::OwnedByTUI` / `DeleteRefused` / `ArchiveRefused` / `RestartRefused`, `SessionContinue::Refused`,
  and `ModelProfile::MissingModel` for `invalid_model` (no model there, or `--model`'s host unknown there: "could not
  start a session: …", exit 1, as here).
  Checks the client would make locally come back as `SessionAccess::Refused` (`parent_answers_refused`,
  `parent_continue_refused`, `no_vision`, exit 1) or `BadRequest` (the other `invalid_*`, `missing_fields`, `bad_images`,
  exit 2, the usage-error path). That is for the routes `raise_refusal` reads (create, uploads, …). `POST …/turn` is
  mapped in `Remote#deliver_turn`: any 4xx but 404 and `owned_by_tui` becomes a refused `DeliverResult` with the
  server's `ack`, which `SendCommand` prints as `<id>  refused: <detail>` (`refused_word`, `REMOTE_REFUSALS`), exit 1.
  A per-method mapping covers the rest (`Remote#deliver_turn`, `#note`, `#context_push`, `#context_remove`,
  `#bridge_reply` for answer/dismiss: chi web's 503 `not_live` or 404 `not_found` → nil, i.e. no worker; 504 → the
  Bridge's 408; 501 → its 404). Anything unmapped becomes `RemoteFailed` "remote NAME (URL) answered STATUS code:
  message".
- **Transport.** `HTTPTransport#call` turns socket errors into `RemoteFailed` "remote studio (http://…): connection
  refused" (also: no answer within 5 s, a read timeout, can't find host, host unreachable, TLS, a broken connection).
  `ParentWait#run` catches `RemoteFailed` so that `--format json` still prints its error object. Dispatch catches it for
  the other commands.
- **Auth.** `Remote.auth_failure`: a 401 → "the token was refused (… chi remote add NAME URL --token-file FILE)". A 403
  `forbidden` (the Host check) → "chi web answers its LAN IP only: use the LAN IP <ip>, not a hostname", with the IP
  taken from the 403's detail. `chi remote add` uses the same words through `Remote.info_problem`.
- **Version skew.** The check is by feature, not by version: `/api/info`'s `features` must include `session_commands`
  (`SessionAccessRoutes::FEATURE`, mirrored as `Remote::FEATURE` so chi web needn't be loaded). If it's missing,
  `RemoteTooOld` says "remote NAME runs chi X; this needs `Remote::NEEDS` or later". A 404 counts as a missing route
  only when its detail starts with `not found: /` (the 404 from `serve_static`, for a path no route takes). A route's
  own 404 (no such session or source) stays a refusal. **Keep that rule:** a new route's 404 must never use the
  `not found: /…` wording.

## Which checks run where

Some checks read this machine's config or files, which would be wrong against a remote. Most are marked in the code
with a "Machine-local" comment; the rest branch on `@access.remote?` (`SendCommand#run_wait`'s busy check,
`#remote_new_options`, `#run_new`'s `capped_note`, `ContextCommand#add_url`).

| Check | Local (in the command) | Under `--remote` |
|---|---|---|
| Images to a model that can't see them (`SendCommand#vision_refusal`) | client | server: `check_vision: true` on the create and turn routes → 422 `no_vision` |
| A parent's `/continue yes`, a loosening `/parent-answers` (`SendCommand::ParentGate`) | client, before any target | server: `App#parent_gate` on create/turn for a `cli:send`/`cli:answer` `client_id` → 403; each target refuses its own |
| `--parent-answers` looser than config.yml (`Guardrails::ParentPolicy.capped_note`) | client | server: the create's `parent_answers_warning` |
| A parent's option on `chi answer` (`AnswerCommand#parent_refusal`) | client, then the worker | skipped on the client; the worker checks (the answer route forwards `cli:answer`), and its 403 `parent_answer_refused` passes through |
| What a parent may pick, for the report (`ParentReport.strategy_for`) | client | server: the wait route's `parent_strategy` |
| `send --wait` busy check (`SendCommand::Busy`) | client | server: `wait/prepare` with `busy: true` → 409 `busy`/`waiting` with the `Busy` fields (`question`, `parent_strategy`); the client words it (`Busy#message(via:)`) |
| `--continues`' previous link and model (`SendCommand#continued_model`) | client | server: `handle_continue` |
| `--toolkit`, `--tool`, `--set` (`Toolkit.from_flags`, `SessionConfig.from_flags`) | client | server: sent as `SetupWords` → 400 `invalid_*` → exit 2 |
| `--dir` (default: the cwd) | client, `File.directory?` | required and absolute on the client (`remote_new_options`); chi web's `scope_dir` checks it exists |
| `sessions list`'s default project (`ProjectScope.root_for(Dir.pwd)`) | client | every project's; `--scope=project` needs `--cwd` (a folder there) |
| `context`'s default session (`SAMAGOTCHI_PARENT_SESSION`, `ContextCommand#inside_session`) | client | no default: ids are required (`added_by` still reads it) |
| A context URL's provider (`ContextProviders.resolve`) | client's bundles | server's bundles (`Remote#context_add_url`) |
| UI-only slash commands (`SessionCommands.ui_only_entry`), `--image` ingest, note text (`SessionInbox.checked_text`), push text (`ContextSources.parse_output`) | client | client too (the server checks note and push text again) |

## Trust model

- **The token is the owner.** In LAN mode (`web.host: lan`) every non-loopback request needs the `Web::Token` access
  token, as the `chi_token` cookie or `Authorization: Bearer` (`App#token_gate`). Passing the gate grants everything,
  because no route checks roles (`local_viewer?` only hides `editor_url`). This runs over plain http, which is fine on
  a home LAN, the same as the phone page. A loopback chi web without LAN mode needs no token
  (`Remotes::Entry#token` is nil, and no header is sent).
- **The token at rest.** `remotes.yml` is written through `AtomicFile.write(perm: 0o600)`. `Entry#inspect` / `#to_s`
  redact the token. `chi remote ls` never prints it (JSON shows `token: true|false`). `HTTPTransport#inspect` and
  `Remote#inspect` show only the label.
- **The Host check.** `local_host_header?` accepts only the loopback names and the exact LAN IP. `http://studio.local`
  gets a 403 `forbidden`, which the client words as "use the LAN IP". The check guards against DNS rebinding.
  `cross_site?` lets CLI clients through because they send no `Origin` or `Sec-Fetch-Site`.
- **`client_id` only tightens.** `handle_question_answer` forwards `client_id` only when it is `ClientId::CLI_ANSWER`
  and drops any other value, so a remote answer is held to the parent rules and can't pass for the user's own. On
  create and turn, a `cli:send` / `cli:answer` id adds checks (`CLI_SEND_IDS`) and never removes any.
- **Context push is an inbound path.** A remote `context push` writes text that can wake a session. It carries the same
  trust as a local `chi context push` on that machine, the owner's token ([guardrails.md](../guardrails.md)). A remote
  `context add --cmd` runs its command on the session's machine.
- **Guardrails see through `--remote`.** The `chi-context-cmd` and `chi-broadcast` regexes in
  `bundles/guardrails/guardrails/rules.yml` allow `--remote NAME` / `--remote=NAME` (quoted, continued) between `chi`
  and the subcommand. `chi-answer-piped` already allowed any words there, and `chi-answer-http` matches any
  curl/wget/http/xh line naming `/answer`, chi web's route included. `CHI_REMOTE=…` leaves the command words unchanged. Specs:
  `spec/guardrails/shipped_bundle_spec.rb`.

## Testing

- `spec/support/remote_backend.rb`: `RemoteBackend.both(self) { … }` runs a group's examples once per backend
  (`backend` is `:local` or `:remote`). The command gets `access: backend_access(state_dir)`. On the remote side,
  `RackTransport` calls `Web::App#call` in-process on the same state dir, in LAN mode, from another peer, with the LAN
  IP as Host and a Bearer token, so the token gate and the Host check run on every request, and the spec's sessions and
  stubs belong to the server too. Used in the send, send `--new`, answer, note, context, sessions list/archive and
  delete specs.
- An example tagged `local_only: "why"` is skipped on the remote side, with the reason. Use this tag only when the
  words or the check are genuinely this machine's (`PARENT_CHECK`, `--project (Contract)`, image ingest, …), never to
  hide a divergence.
- `spec/session_access_contract_spec.rb` (the table), `spec/session_access_dispatch_spec.rb`,
  `spec/session_access_remote_spec.rb`, `spec/session_access/http_transport_spec.rb`, `spec/remotes_spec.rb`,
  `spec/remote_command_spec.rb`, `spec/web/session_access_routes_spec.rb`, and the pair-script specs in
  `spec/samagotchi/bundles/{claude,codex}_peer_pair_spec.rb`.
- By hand: the smoke-run skill (`.claude/skills/smoke-run`, kept in the checkout, not in git) covers chi web.
  It has no remote recipe yet. The real lane is laptop → Studio over the LAN: `chi remote add`, `send --new --wait`,
  an exit-3 `answer`, `context push`, `note`, then `CHI_REMOTE=studio sh scripts/pair <id>` from the laptop's Claude.

## Extension points (not built yet)

- **Remote attach.** `--attach`, `-p` and `--resume` are refused today (`Dispatch::RUN_FLAGS`). `TerminalUI::AttachedLoop`
  and `AttachLauncher` talk to a `BridgeClient` (`follow`, `post_turn`, `post_command`, `answer`, `dismiss_question`,
  `dequeue`, `cancel`, `request_exit`, `request_recap`, `get_json`) and `session_id`, `host`. They also make Bridge
  clients themselves: `AttachLauncher` through `BridgeClient.wait_for` / `.discover`, and `AttachedLoop#live_worker`
  (`follow`'s `rediscover:`) and `#switch_worker` (`BridgeClient.new` on a restart). A web-backed client needs those
  seams too. A remote attach would plug a web-backed client with
  that interface into them, on its own Bearer transport. chi web has no route for exit, recap, stats or state, and none
  that wakes an idle session for a stream: `handle_stream` waits at most 2 s for a Bridge, then answers 503 `not_live`.
  `POST …/turn` does not forward `no_interrupt`.
- **Shared sessions (guests, roles).** The only access point is `App#token_gate`: one token, the owner's. Roles would
  attach there and to the routes. The claude-peer / codex-peer inbox leg (chi → this machine's Claude or Codex) would
  need a relay through chi web.
- **Invariants to keep:** Bridges stay loopback, and remote access goes through chi web. A forwarded `client_id` can
  only tighten. One condition has one message on both backends: the route sends `message` plus the class's fields, and
  `Remote` raises the same class. A route's own 404 never looks like a missing route.

## Known gaps

- Remote `sessions stop` always prints "Stopped session …": `Remote#stop` returns true because chi web's stop doesn't
  say whether the worker released the session.
- `send -m /stats` is refused (UI-only) with "use chi sessions stats ID", which is local-only under a remote.
- Through a remote the pair scripts (`bundles/{claude,codex}-peer/scripts/pair`) detect `CHI_REMOTE` or `--remote` in
  `CHI` the way Dispatch does, and attach only `*-outbox`: chi there can't reach this machine's Claude socket or Codex
  thread, so chi's replies reach Claude only when relayed.
- The peer skills (`skill_claude_peer`, `skill_codex_peer`) have no remote recipe. The `/claude` card says "not paired" for
  an outbox-only (remote) pair, because it reads `claude-inbox`.
