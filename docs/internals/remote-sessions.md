# Remote sessions

`chi --remote NAME <command>` (or `CHI_REMOTE=NAME`) runs chi's session commands (`send`, `answer`, `note`, a
session's `context`, `sessions list/stop/restart/archive/unarchive/delete`) against another machine's sessions, and
`chi --remote NAME --attach ID` (`--resume ID`, `--dir DIR`, `-p TEXT`) runs the attached TUI on one of them. The
sessions, workers, memories and code stay on that machine; this one only sends requests and prints the answers.
User-facing behaviour is in [cli.md](../cli.md#remote-sessions). This page is the code's shape, for changing it.

**The one rule:** the remote side is that machine's **chi web**, never a worker's Bridge. Bridges stay on loopback,
and answer only a request that names their secret from `bridge.json` ([architecture.md](../architecture.md)).
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
  `:local_only` command, subcommand or long flag, or a run flag `Contract::RUN` lists local-only (`chi --verbose`;
  `--non-interactive` adds "(chi --remote NAME send --new --dir D -m TEXT --wait runs one turn there)"). A flag's
  value (`-p TEXT`, `--model NAME`: `RunOptions.value_switches`) is never read as a flag.
- **Run flags** (`#run_flags?`: no subcommand, the first word a flag or nothing) don't go to `#run`: bin/chi refuses
  the local-only ones, parses the rest with `RunOptions.parse` (the one run-flag parser) and, before any of its own
  checks (`Session.resolve_id`, the scratch check, `--memory`, `--append-system-prompt`, `Toolkit.from_flags`, …: all
  this machine's), runs `RemoteAttachCommand.new(options, access: Remote.new(entry)).run`. A word left over exits 1.
  Without a remote, `--dir` exits 2 ("--dir goes with --remote; cd there instead").
- Otherwise it calls `Remotes.find`, then `Samagotchi.const_get(klass).new(argv, access: Remote.new(entry)).run`.
  `Remotes::Invalid` (including `NotFound`) exits 2. A `RemoteFailed` or `Refused` that escapes the command prints
  `chi <cmd>: <message>` and exits 1; a `BadRequest` (a value chi web refused, e.g. `sessions list --cwd rel/dir`)
  prints the same line and exits 2.

### Contract

`Contract::TABLE` maps `"command"`, `"command sub"` and either one followed by a long flag (`"context add --cmd"`) to
`SUPPORTED` or `LOCAL_ONLY`. A `LOCAL_ONLY` command or subcommand lists no flags. `MACHINE` holds bin/chi's
non-session commands (`bootstrap update models desktop memory bundle remote`). `spec/session_access_contract_spec.rb`
reads bin/chi's `SUBCOMMANDS` and each command's `FLAGS`. It fails when a subcommand, a subcommand of a supported
command, or a flag of a supported command is missing from both lists, or when the table lists something that doesn't
exist. **A new session command or flag fails that spec until you choose one.**

`Contract::RUN` does the same for bin/chi's run flags (`RunOptions.switches`): `SUPPORTED` (`--attach`, `--resume`,
`-p`, `--shared`, `--model`, `--thinking`, `--llm-context*`, `--toolkit`, `--tool`, `--no-tool`, `--set`,
`--parent-answers`, `--no-interrupt`, `--no-default-input`, `--dir`, `--help`, `--version`) or `LOCAL_ONLY`
(`--no-shared`, `--non-interactive` and `--verbose`: the in-process REPL, P4-D4; `--memory`, `--mute`,
`--append-system-prompt`: this machine's memories and files, P4-D2/D3; `chi web`'s flags; `--profile`). A config
registry flag (`--recap-base-url` …) is this machine's config: `LOCAL_ONLY` without being listed
(`Contract.run_status`). The contract spec fails on a run flag in neither.

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
   its own `--timeout` runs out, at which point it builds the `timeout` result itself. Each slice is a fresh `ReplyWait`
   there, so a `timeout` answer carries the slice's `running_look` (`ReplyWait::RunningLook`: the running turn it saw
   with its checkpoint mark, `{last_end, claimed}`, else null) and the client sends it back on the next slice, as is:
   a dead worker's turn settled between two slices ends the wait `canceled` (`worker_stopped`) as it does locally,
   not at the timeout. A 503 `server_stopping` (chi web
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
  refused" (also: no answer within 5 s, a read or write timeout, can't find host, host unreachable, TLS, a broken
  connection, and "it didn't answer HTTP" for a reply that isn't HTTP: `Net::HTTPBadResponse`, `ProtocolError`, as
  another server on that port gives). The attached TUI's `WebBridgeClient` reads each as `Unreachable`.
  `ParentWait#run` catches `RemoteFailed` so that `--format json` still prints its error object. Dispatch catches it for
  the other commands.
- **Auth.** `Remote.access_error`, keyed by chi web's error code on any route: a 401 `unauthorized` → "the token was
  refused (… chi remote add NAME URL --token-file FILE)"; a participant's token's own conditions (401 `token_revoked`,
  `token_expired`, 403 `not_permitted`, P3b's 429 `too_many_turns`, `cap_reached`) → one class and message each
  ([participants.md](participants.md#errors-through---remote)). A 403
  `forbidden` (the Host check) → "chi web answers its LAN IP only: use the LAN IP <ip>, not a hostname", with the IP
  taken from the 403's detail. `chi remote add` uses the same words through `Remote.info_problem`.
- **A remote attach.** Before the loop runs (resolve, create, wake, the feature check) every failure is
  `AttachLauncher::Error` or the command's own line, exit 1 (`BadRequest`: exit 2): the wake's 409 `owned_by_tui`
  is `OwnedByTUI` (its message is the one `chi --attach` prints here too: `AttachLauncher.connect` now uses it), its
  409 `scratch` and 504 `worker_timeout` are `Refused` with `LaunchMode::SCRATCH_LEFTOVER` / `BRIDGE_LATE`'s words
  (`Remote#attach_wake`). Once the loop runs, `WebBridgeClient` turns every `RemoteFailed` into `Unreachable`
  (an `IOError`), so the loop's rescues catch it and `AttachedLoop#worker_down` prints its message as is ("could not
  send the prompt (remote studio (http://…): the token was refused …)"); the stream's end is worded by its reason
  (*Remote attach*, below). A refused token is `AuthRefused < RemoteFailed`, so rediscovery can tell it apart.
- **Version skew.** The check is by feature, not by version: `/api/info`'s `features` must include `session_commands`
  (`SessionAccessRoutes::FEATURE`, mirrored as `Remote::FEATURE` so chi web needn't be loaded). If it's missing,
  `RemoteTooOld` says "remote NAME runs chi X, too old for this command through --remote: update chi there (chi
  update)": no release number, which would be a guess before the release. A 404 counts as a missing route
  only when its detail starts with `not found: /` (the 404 from `serve_static`, for a path no route takes). A route's
  own 404 (no such session or source) stays a refusal. **Keep that rule:** a new route's 404 must never use the
  `not found: /…` wording.
- **A field an older chi web would ignore.** A body field whose meaning is a restriction (`share --identity`'s
  `identity`: an older chi web drops it and issues a link anyone could open) gets a feature of its own
  (`bound_grants`, `App::BOUND_FEATURE`), and `Remote` requires it before sending the field (`require_feature!`):
  never a silent downgrade.

## Which checks run where

Some checks read this machine's config or files, which would be wrong against a remote. Most are marked in the code
with a "Machine-local" comment; the rest branch on `@access.remote?` (`SendCommand#run_wait`'s busy check,
`#remote_new_options`, `#run_new`'s `capped_note`, `ContextCommand#add_url`).

| Check | Local (in the command) | Under `--remote` |
|---|---|---|
| Images to a model that can't see them (`SendCommand#vision_refusal`) | client | server: `check_vision: true` on the create and turn routes → 422 `no_vision` |
| A parent's `/continue yes`, a loosening `/parent-answers` (`SendCommand::ParentGate`) | client, before any target | server: `App#parent_gate` (`Web::SessionCreate`) on create/turn for a `cli:send`/`cli:answer` `client_id` → 403; each target refuses its own |
| `--parent-answers` looser than config.yml (`Guardrails::ParentPolicy.capped_note`) | client | server: the create's `parent_answers_warning` |
| A parent's option on `chi answer` (`AnswerCommand#parent_refusal`) | client, then the worker | skipped on the client; the worker checks (the answer route forwards `cli:answer`), and its 403 `parent_answer_refused` passes through |
| What a parent may pick, for the report (`ParentReport.strategy_for`) | client | server: the wait route's `parent_strategy` |
| `send --wait` busy check (`SendCommand::Busy`) | client | server: `wait/prepare` with `busy: true` → 409 `busy`/`waiting` with the `Busy` fields (`question`, `parent_strategy`); the client words it (`Busy#message(via:)`) |
| `--continues`' previous link and model (`SendCommand#continued_model`) | client | server: `handle_continue` (`Web::SessionCreate`) |
| `--toolkit`, `--tool`, `--set` (`Toolkit.from_flags`, `SessionConfig.from_flags`) | client | server: sent as `SetupWords` → 400 `invalid_*` → exit 2 |
| `--dir` (default: the cwd) | client, `File.directory?` | required and absolute on the client (`remote_new_options`); chi web's `scope_dir` checks it exists |
| `sessions list`'s default project (`ProjectScope.root_for(Dir.pwd)`) | client | every project's; `--scope=project` needs `--cwd` (a folder there) |
| `context`'s default session (`SAMAGOTCHI_PARENT_SESSION`, `ContextCommand#inside_session`) | client | no default: ids are required (`added_by` still reads it) |
| A context URL's provider (`ContextProviders.resolve`) | client's bundles | server's bundles (`Remote#context_add_url`) |
| UI-only slash commands (`SessionCommands.ui_only_entry`), `--image` ingest, note text (`SessionInbox.checked_text`), push text (`ContextSources.parse_output`) | client | client too (the server checks note and push text again) |
| A remote attach's `--attach`/`--resume` id (`Session.resolve_id`), the leftover scratch check, the "open in a chi REPL" refusal | client (bin/chi, `AttachLauncher.connect`) | server: `Remote#resolve`, then `POST …/wake`'s 409s |
| A new attached session's `--toolkit`, `--set`, `--thinking`, `--llm-context*`, `--parent-answers`, `--model` | client (bin/chi) | server: `POST /api/sessions` with `idle: true` and `SetupWords`; its warnings printed as `send --new` prints them |
| The status row's default model, the newest chi for the version line, what a parent may pick (exit 3) | client | server: the wake's `default_model`, `installed`, `parent_strategy` (the last read again from `GET …/worker` at report time) |
| `@path` images (ingest, convert, downscale) | client, into the session's `images/` | client, into a scratch dir, then uploaded (`POST …/images`) |
| Prompt history (↑), the `no_interrupt` / `no_default_input` baselines, Tab's `@path` | client | client (this terminal's; `history: false` on every POST); no memory-name completion remotely (P4-D11) |

## Trust model

- **The token is the owner.** In LAN mode (`web.host: lan`) every non-loopback request needs the `Web::Token` access
  token, as the `chi_token` cookie or `Authorization: Bearer` (`App#token_gate`). This runs over plain http, which is
  fine on a home LAN, the same as the phone page. A loopback chi web without LAN mode needs no token
  (`Remotes::Entry#token` is nil, and no header is sent). Behind an auth proxy (`web.public_url`, experimental) every
  request needs it, loopback too, and a proxied owner also the configured identity header
  ([configuration.md: Behind an auth proxy](../configuration.md#behind-an-auth-proxy), `Web::ProxyGate`); `chi
  --remote` through such a proxy isn't supported yet (the CLI can't pass its sign-in, and streams need TLS).
- **Every request has a principal.** `App#principal_for` resolves who a request is, as a `Web::Principal`
  (`web/principal.rb`): `Principal::OWNER` for a peer the gate doesn't ask (no LAN mode, or a loopback peer) and for
  the access token; a participant for a live grant's `chp_` token; nil (a 401) for anyone else (`token_revoked` /
  `token_expired` for an ended grant's). `#token_gate` uses it, and `#route` keeps it in the request's env
  (`App#principal(req)`), so a handler reads the principal and never trusts the body for it. Each `ROUTES` row names
  who may use it (its permission column, `:owner` or `:participant`; `Principal#permits?`; any other answers 403
  `not_permitted`). The owner passes every route (`local_viewer?` only hides `editor_url`). A participant, a
  `Web::Grants` token for one session, reaches only the `:participant` rows, and another session's id is a 404
  ([participants.md](participants.md)). A turn's author comes from the principal
  (`Principal#author`, nil for the owner) and rides with the turn (`SessionManager.deliver_turn(author:)` →
  `BridgeClient#post_turn` → `Bridge#handle_post_turn` → the input file, the fallback's too → the turn's `origin`);
  an owner's turn carries none, so its input file and session are byte for byte as before.
- **The token at rest.** `remotes.yml` is written through `AtomicFile.write(perm: 0o600)`, its read-modify-write (`Remotes.put` / `remove`) under `remotes.yml.lock`. `Entry#inspect` / `#to_s`
  redact the token. `chi remote ls` never prints it (JSON shows `token: true|false`). `HTTPTransport#inspect` and
  `Remote#inspect` show only the label.
- **The Host check.** `local_host_header?` accepts only the loopback names and the exact LAN IP (and, with
  `web.public_url`, its host exactly, port included). `http://studio.local`
  gets a 403 `forbidden`, which the client words as "use the LAN IP". The check guards against DNS rebinding.
  `cross_site?` lets CLI clients through because they send no `Origin` or `Sec-Fetch-Site`.
- **`client_id` only tightens.** `handle_question_answer` (`Web::SessionControl`) forwards `client_id` only when it is `ClientId::CLI_ANSWER`
  and drops any other value, so a remote answer is held to the parent rules and can't pass for the user's own. On
  create and turn, a `cli:send` / `cli:answer` id adds checks (`CLI_SEND_IDS`) and never removes any.
- **A remote attach's `client_id`** (`tui:<pid>@<host>`, P4-D6) is forwarded as given on `/turn` and `/command`, as
  the page's is: the token is the owner. Only the cli ids (`cli:send`, `cli:answer`) add checks there; a parent
  agent driving the TUI from a pipe answers as `cli:answer`, held to that machine's `guardrails.parent_answers`.
  `POST …/exit` passes on only a `tui:` id: any other is dropped, so the worker counts every stream as a UI, which
  only keeps it up. `POST …/wake` spawns a worker, which `/turn` already did. `!cmd` typed in a remote TUI runs on that machine, under
  its guardrails.
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
- A remote attach: `spec/session_access/web_bridge_client_spec.rb` (the mapper's rows and `Unreachable`, through
  `RackTransport`; the stream's request bytes, a chunked reply), `spec/bridge_client/event_stream_options_spec.rb`
  (the idle timeout, which a local follow never sets; epoch_watch; retries; reasons), and one end-to-end spec,
  `spec/remote_attach_stream_spec.rb`: a real `Bridge` behind `Web::App` on WEBrick at 127.0.0.1:0
  (`spec/support/web_server.rb`) followed through a `WebBridgeClient` (join, a turn, a restart, a stop). It runs
  over loopback, so chi web's token gate is skipped there; `spec/web/lan_auth_spec.rb` covers the gate on the
  stream, wake and worker routes.
- The remote TUI: `spec/terminal_ui/remote_link_spec.rb` (rediscovery reasons, the wake on a reconnect, images, the
  join's reads, `HANDLED_COMMANDS` covering every attached terminal command), `spec/terminal_ui/attached_loop_remote_spec.rb`
  (the loop's `--remote` lines, `/exit`, `/exit --delete`, `/archive`, `/stats`, `/recap`, a join with that machine's
  saved records, `Unreachable` mid-session, the reasons' and reconnect lines),
  `spec/terminal_ui/remote_connector_spec.rb`, `spec/remote_attach_command_spec.rb`,
  `spec/session_access/remote_attach_spec.rb` (wake, worker, feature check through `RackTransport`), and bin/chi's
  branch in `spec/session_access_dispatch_spec.rb`.
- By hand: the smoke-run skill (`.claude/skills/smoke-run`, kept in the checkout, not in git) covers chi web; its
  cli-tui recipe has remote attach on one machine (two isolated envs, `chi remote add self http://<LAN IP>:PORT`, the
  terminal's commands through chi web). The real lane is laptop → Studio over the LAN: `chi remote add`, `send --new --wait`,
  an exit-3 `answer`, `context push`, `note`, then `CHI_REMOTE=studio sh scripts/pair <id>` from the laptop's Claude.

## Remote attach

`chi --remote NAME --attach ID`: the attached TUI (`AttachedLoop`) on a session of another machine. The TUI still
talks to a worker's Bridge interface; chi web relays each request to that Bridge on loopback.

```
bin/chi ── RunOptions.parse ── a remote, run flags ──> RemoteAttachCommand ── AttachLauncher.run(connector: RemoteConnector)
                                                                                        │ POST …/wake
                                                         AttachedLoop.new(link: RemoteLink) ── link.client: WebBridgeClient
                                                                                        │ one-shots and the stream
                                                                       chi web (that machine) ── the worker's Bridge
```

### The plumbing

**chi web's routes** (tabled in [architecture.md](../architecture.md)): `POST …/wake` (`Local#wake`: the live worker
as is, else `SessionManager.resume_session` and `WorkerLink.await`, at most `WAKE_MAX_WAIT` 10 s, the attach's
`BRIDGE_WAIT` here, after waiting for a worker still leaving to let go of its lock, `OwnerLock.await_release`: its
recap on leave's timeout plus 5 s; a leftover scratch session is refused in `LaunchMode::SCRATCH_LEFTOVER`'s words, a late Bridge
in `LaunchMode::BRIDGE_LATE`'s; a worker on a newer sidecar protocol is refused, 409 `worker_newer`, never resumed over) and `GET …/worker` (`Local#worker`: live, the stop marker, the owner, `leaving` and `leave_seconds` when its worker
is leaving, `WorkerState#leaving?`, `stuck` for a worker that never published its Bridge, `skew` for a newer protocol; it never starts one; it also names that machine's `default_model`), both answering the worker as `{epoch, started_at, version,
features}`; `POST …/exit` (the worker's exit, `client_id` passed on only when it is a `tui:` one), `POST …/recap`,
`GET …/stats` (the stats, else an older worker's state metrics), `GET …/children/counts` (`ChildrenStatus.counts`)
and `GET …/turns/:turn_id/records` (`SessionMetrics`' saved tool records and turn record), every refusal with
`{error, detail, message}`; `POST …/turn` takes `no_interrupt`
(`SessionManager.deliver_turn(no_interrupt:)`, to the Bridge or into the input file); `POST …/command`'s 501 for a
builtin the worker lacks names it (`command`). `/api/info`'s feature `remote_attach`
(`SessionAccessRoutes::ATTACH_FEATURE`, mirrored as `Remote::ATTACH_FEATURE`) says a chi web has them.

**One worker identity.** The Bridge's epoch (`Bridge#epoch`, the `<seq>-<epoch>` in every event id) is in its sidecar
(`WorkerSidecar#epoch`; an older worker's reads nil, and the client keys it by `started_at` instead). A local
`BridgeClient` is keyed by its port; a remote one stays one object and its `worker_key` changes.

**`SessionAccess::WebBridgeClient`** (`session_access/web_bridge_client.rb`, built by `Remote#attach_client(id,
worker:)` from a wake's or worker read's `worker`): `post_turn` (`no_interrupt`, `history: false`), `post_command`,
`answer`, `dismiss_question`, `dequeue`, `cancel`, `request_exit`, `request_recap`, `stats`, `children_counts`,
`turn_records`, `follow`, `open_stream`, `session_id`, `worker_key`, `port` (nil). One-shots go through
`Remote#route_request` (the server check, the auth and missing-route mapping), a new connection each, with a 45 s
read timeout (chi web's 30 s Bridge read plus its wait for a waking Bridge; 75 s for answer and dismiss, which chi web
sends twice on a 408; 5 s, `JOIN_READ_TIMEOUT`, for the join's reads: the children counts and a turn's records, L9). Every reply goes through **one status mapper**,
`WebBridgeClient::Mapping.response(route, reply, …)`:

| chi web's answer | What the loop gets |
|---|---|
| 503 `not_live`, 404 `not_found` | raises `Unreachable` (< `IOError`): "no live worker for session ID on NAME" (`NO_WORKER`) |
| 502 `bridge_secret` (stream) | `Refused(:bridge_secret)`; `EventStream` ends with `stream_closed bridge_secret` |
| 504 (any) | `Response(408, {error: deadline_passed})`: the loop's late line |
| 501 with `command` (`/command`) | `Response(400, {error: unknown_command, command})`: the loop names the command |
| any other 501 | `Response(404, {error: not_found})`: the stale-worker line |
| anything else | unchanged: 202 acks, 409s, a route's own 404 (`unknown_enqueued_id`), 403 `parent_answer_refused`, 502 |

Every `RemoteFailed` (a transport failure, `RemoteTooOld`, a 401 or a 403 `forbidden`) becomes `Unreachable` with its
message, so a loop that rescues `IOError` around Bridge calls never crashes on one mid-session.

**The stream.** `open_stream` writes `GET /api/sessions/:id/stream…` through `BridgeClient::StreamRequest` (the
GET a local stream writes, with `Authorization: Bearer` and `Last-Event-ID`; `Host` is the entry's host and port).
An IPv6 entry (`http://[::1]:4567`) connects on the bare address (`URI#hostname`, as `HTTPTransport` does) and keeps
the brackets in `Host`.
Its connect is bounded by the header timeout (`StreamRequest::CONNECT_TIMEOUT`, 5 s, without one): a dead host's
SYN isn't waited on for the OS's minutes on every reconnect.
chi web proxies the Bridge's bytes unchanged (under WEBrick a hijacked body is raw, `Connection: close`). No chunked
decoding in v1: a `Transfer-Encoding: chunked` reply (a proxy in between) and an https entry are logged
(`stream_refused`, `chunked_unsupported` / `tls_unsupported`) and read as unreachable; decoding and TLS plug into
`StreamRequest`. `WebBridgeClient#open_stream` returns typed outcomes: chi web's 502 `bridge_secret` is a refusal
(`stream_closed bridge_secret`), 503 is unreachable and retried with rediscovery, and 404 is an unknown-session
refusal. `follow` starts `EventStream` with three options a local stream never sets (`BridgeClient#follow`
passes none):
- `idle_timeout:` 40 s (`STREAM_IDLE_TIMEOUT`: two of the Bridge's 15 s pings plus margin): no byte for that long is a
  half-open connection (Wi-Fi gone, a sleeping laptop), reconnected with the cursor.
- `epoch_watch:` a frame whose id carries another epoch than the cursor's is a new worker answering the old cursor:
  `worker_changed {"port" => nil, "epoch" => new}` comes before it (the `reset` the new Bridge sends), and the
  client's `worker_key` is updated in place. A restart reaches the stream this way because `Bridge#stop` removes its
  sidecar before it ends the open streams: the reconnect finds no sidecar, chi web waits for the next worker's
  (`await_worker_link`) and proxies the cursor to it. A sidecar still naming a dead port now gets 503 `not_live`;
  a secret refusal gets 502 `bridge_secret`, and no refusal is sent as SSE frames. The stream moves by rediscovery
  (`worker_changed`, then a `snapshot`).
- `announce_retries:` `stream_retrying` once a reconnect fails and rediscovery neither moved the stream nor ended it
  (a stop prints its stopped line alone), `stream_resumed` once a stream answers again (a replay may bring no frame).

`EventStream` compares a rediscovered client's key with the key it last followed, not with the client object's, so a
rediscovery that updates the same client in place is a move. Rediscovery may give a reason with its answer
(`[nil, reason]` while it retries, `[:gone, reason]` to stop, `AttachLink#live_worker`'s shape), and `stream_closed`
carries the last one (`unreachable` without). `AttachedLoop#live_worker` passes the link's pair on; on this machine
the closing line reads `stopped` as `unreachable`, the words it always had.

### The remote TUI

- **`RemoteAttachCommand`** (`remote_attach_command.rb`) takes RunOptions' parsed options: `LaunchMode.attached_conflict`
  (exit 1, the same words); `--attach`/`--resume` resolved there (`Remote#resolve`); without them a new session,
  which needs `--dir`, that machine's absolute path (exit 2, before anything is asked): `Remote#create` with
  `NewSession(idle: true)` and the setup flags as typed (`SetupWords`), its warnings printed as `send --new` prints
  them, its `-p` sent once attached. An existing session prints the ignored-flags line (`--dir` among them) and gets
  `--model`/`--llm-context*`/`--thinking` as first commands, as here. `Remote#require_feature!("remote_attach")` comes
  first (without it, `Remote.too_old_message`). Then `AttachLauncher.run(connector: RemoteConnector)` and
  `AttachLauncher.exit_status`.
- **`RemoteConnector`** (`terminal_ui/remote_connector.rb`): `#connect` is `Remote#attach_worker` (a worker there
  still leaving prints `LaunchMode::RECAP_WAIT`, as a local attach does, and the wake's read timeout grows by its
  `leave_seconds`), then `Remote#attach_wake` (`POST …/wake`, `WakeReply`) and the `RemoteLink`; `#client_id` is `tui:<pid>@<short hostname>` (P4-D6).
- **`RemoteLink`** (`terminal_ui/remote_link.rb`), the `AttachLink`:
  - `client`: one `WebBridgeClient` for the attach; `switched(event)` keeps it (its key the event's epoch) and reads
    the new worker's features (`GET …/worker`).
  - `live_worker`: `Remote#attach_worker` (`WorkerReply`) with a reason (M5): `stopped` and `unknown_session` (gone),
    `auth_failed` (`AuthRefused`) and `too_old` (`RemoteTooOld`) end at once; `unreachable` (a transport
    `RemoteFailed`) and `worker_gone` (chi web answers, no live worker, not stopped) retry through
    `RECONNECT_DELAYS` (about a minute, P4-D5; up to two with a 5 s connect timeout per try on a dead host). A worker gone for `WAKE_AFTER` (3 s, so a restart's new worker isn't
    raced) is woken once per outage with `POST …/wake` (P4-D9). `failure` keeps the last message for the closing line.
  - `queues?`/`unqueues?`: the worker's `features`. `ingest_images`: `ImageStore.ingest` into a scratch dir here, then
    `Remote#upload_images`; `close` (`AttachLauncher.run`'s `ensure`) removes the dir.
  - `installed_version`: the wake's (that machine's). `default_model_name`: the wake's, then the one `GET …/worker`
    names after a worker change (the loop forgets its copy on `worker_changed`). `parent_strategy`: `GET …/worker`'s,
    read at report time (L4), the wake's when that fails.
  - `completions`: `@path` (this machine's files: images are ingested here), no memory names (P4-D11).
  - `via`: `Remote#invocation`, so every printed command reads `chi --remote NAME …` (`ChiInvocation#attach` and
    `#resume` have their remote forms; `shows`/`open_it` name the attach too).
  - The terminal's own commands through chi web: `/exit` is `WebBridgeClient#request_exit` (`POST …/exit`, this
    TUI's `tui:` id); `/exit --delete` adds `Remote#delete(id, force: true)` and `/archive` `Remote#archive` once the
    worker answered (their refusals the classes `SessionManager` raises here, a transport failure `Unreachable`);
    `/stats` is `GET …/stats` and `/recap` `POST …/recap`. A failure the loop shows in its own words through a
    remote: "(no metrics: …)", "(no recap: …)", the exit lines' "could not ask the worker to stop: …". A chi web
    with `remote_attach` but without one of these routes (`serve_static`'s 404) reads as `RemoteTooOld`, so the line
    carries `Remote.too_old_message`'s words.
  - The join's reads swallow every failure (a debug log line): `saved_tool_records` / `saved_turn_record` are one
    `GET …/turns/:turn_id/records` per join (the second call takes what the first read) and give `[]` / nil;
    `children_counts` gives `Counts.none`.
  - `HANDLED_COMMANDS` must list every `local: true` command shown in the attached TUI (`remote_link_spec`), so a new
    terminal command can't silently fall through remotely.
- **The loop's lines.** `stream_retrying` → "(lost the connection to NAME; reconnecting…)", `stream_resumed` →
  "(reconnected)". `stream_closed`, by reason: "The session was stopped on NAME. Resume it with: chi --remote NAME
  --resume ID"; "Lost the session: <the auth or too-old words>"; "Lost the connection to NAME (connection refused).
  Re-attach with: chi --remote NAME --attach ID"; "The session's worker on NAME is gone. Resume it with: …"; "The
  session is gone from NAME (deleted)." A restart is one "chi> the session's worker restarted on chi X" (the epoch's
  `worker_changed`, then the new Bridge's `reset`). The version line across machines (P4-D10,
  `VersionLines.across_machines`): "chi> the session's worker runs chi W; NAME has I installed: chi --remote NAME
  sessions restart ID" and "chi> this terminal runs chi T (NAME has I): chi update here".

## Extension points (not built yet)

- **Remote attach** is built (*Remote attach*, above); its seams, for another kind of link:
  - `TerminalUI::AttachLink` (terminal_ui/attach_link.rb): what `AttachedLoop` knows about *where* the session is,
    beside its client: `live_worker` (`[client, nil]`, `[nil, nil]`, `[:gone, reason]`) and `switched(event)` for
    the stream's rediscovery and a restart; `queues?` / `unqueues?`; `stats_metrics` (may raise `IOError`: the loop
    shows a remote's message); `ingest_images`; the saved
    records and `children_counts`; `delete_session`, `archive_session`; `installed_version`, `default_model_name`,
    `parent_strategy`; `completions` (Tab's `@path` and `#memory`); `reconnect_delays`; and `via`, the
    `ChiInvocation` every printed command is spelled with. `LocalLink` is this machine's; `AttachedLoop.new` makes
    one of `client:` and its keywords, and takes `link:` instead.
  - The connector: `AttachLauncher.run(connector:)` asks its `#connect` for the `AttachLink` instead of `.connect`
    (which a local run still calls, returning a `BridgeClient`); a connector whose `#connect` answers nil is
    `AttachLauncher::Error` (`NOTHING_CONNECTED`), never an attach here. Its `#client_id`, when it has one, names the
    TUI (`tui:PID` otherwise). `report_unanswered` takes the link's `strategy:` and `via:`.
  - The client the loop and `BridgeClient::EventStream` use: `follow`, `post_turn`, `post_command`, `answer`,
    `dismiss_question`, `dequeue`, `cancel`, `request_exit`, `request_recap`, `session_id`, and for the stream
    `open_stream(query:, last_event_id:, header_timeout:, attempts:)` and `worker_key` (a new worker is a client with
    another key; a Bridge's is its port). `EventStream` reads the opened socket; `BridgeClient::StreamRequest`
    writes the stream's GET (host, port, path, extra headers) and reads its headers, for a stream through chi web too.
  - `RunOptions.parse(argv)` is bin/chi's one run-flag parser (`RunOptions.switches` lists its flags), so a remote
    branch can take the parsed options before bin/chi's local checks; `LaunchMode.attached_conflict` and
    `LaunchMode::SCRATCH_LEFTOVER` / `BRIDGE_LATE` are the words both would print.

  An https chi web (a pod behind a proxy) needs TLS and chunked decoding in `StreamRequest`.
- **Shared sessions (guests, roles).** The only access point is `App#token_gate`: one token, the owner's. Roles would
  attach there and to the routes. The claude-peer / codex-peer inbox leg (chi → this machine's Claude or Codex) would
  need a relay through chi web.
- **Invariants to keep:** Bridges stay loopback, and remote access goes through chi web. A forwarded `client_id` can
  only tighten. One condition has one message on both backends: the route sends `message` plus the class's fields, and
  `Remote` raises the same class. A route's own 404 never looks like a missing route.

## Known gaps

- A prompt typed while a remote stream reconnects is usually accepted (chi web's `/turn` resumes the worker, else
  writes an input file) where a local one fails "could not send the prompt". A POST whose reply is lost reads as
  "could not send", yet ran: sending it again runs it twice (no idempotency key yet).

- Through a remote the pair scripts (`bundles/{claude,codex}-peer/scripts/pair`) detect `CHI_REMOTE` or `--remote` in
  `CHI` the way Dispatch does, and attach only `*-outbox`: chi there can't reach this machine's Claude socket or Codex
  thread, so chi's replies reach Claude only when relayed.
- The peer skills (`skill_claude_peer`, `skill_codex_peer`) have no remote recipe. The `/claude` card says "not paired" for
  an outbox-only (remote) pair, because it reads `claude-inbox`.
