# Changelog

All notable changes to samagotchi (the `chi` command) are listed here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/); before 1.0, config
and commands may change between minor versions. How releases are made:
[docs/releasing.md](docs/releasing.md).

## [Unreleased]

### Fixed

- `/model X` (and `/model X --default`, `/model clear`, and a successful `/model X --alias NAME`) now carry the
  model's thinking level in the same place the plain `/model` reply does; a switch that fails to persist its alias
  is unchanged.

## [0.52.0] - 2026-10-10

### Added

- `/thinking` shows the thinking level the next turn runs at and where it came from; `/thinking off|low|medium|high`
  sets the session's own level (saved with the session, first in the order), `/thinking default` unsets it. A change
  waits for the turn's end, and the reply says what it costs the prompt cache. `/model` and `/stats` show
  `low (session)`; a continue and a plugin's fork keep the level, a delegate starts without it.
- Web: a `think` chip in the session bar and on the start page shows the thinking level (`think low · session`); a
  click opens a level select that runs `/thinking` (the start page's choice is for the next new chat only).
- `chi send --new --thinking LEVEL` starts the session with its own thinking level (refused beside `--continues`,
  which takes the previous link's).

### Changed

- `chi --thinking LEVEL` on a run that starts or resumes a session sets that session's own level (saved, above
  `SAMAGOTCHI_THINKING_LEVEL`) instead of the process's; `default` unsets it. `chi web --thinking` stays a default for
  the workers it spawns, below a session's own.
- `llm_context.budget_tokens` (and a model's or host's `llm_context_budget_tokens`) takes `64k` and `off` like
  `/llm-context budget`, with the same range (4k to 10M); a budget out of range warns and is ignored.
- Web: a turn's step is one lit-html template for the live page and a reload (lit-html 3.3.3 vendored in
  `web/public/vendor/`, no build step). A live step no longer keeps an empty narration element, and a plain answer's
  thinking block is drawn fresh from the same template.

### Fixed

- Web: the info bar's session clock ticks during a session's first turn (a session started from the start page
  showed a frozen `session 0ms`).
- Web: `/cut TEXT` in the composer sends TEXT as a cut, as in a terminal and `chi send --cut` (it was refused as "not a
  session command"); with no turn running it is TEXT as a normal turn. `/queue TEXT` during a turn says it isn't
  available in the web yet, instead of that error.
- Web: command bubbles (`/help`, `/model`, `/llm-context` …) stay in place when a `!cmd` or `!rollback` redraws the
  conversation; a reload still drops them (only a `!cmd`'s output is saved).
- Web: a reloaded turn whose messages carry no parts keeps "(called as bash)" on its rows (from the tool records).
- A turn posted with `delivery: "queue"` (the Bridge's and the web's `POST …/turn`) is refused with 400
  `delivery_unavailable` until queueing is built, instead of being acked as queued and then merged at the running
  turn's next step. No chi client sends it.
- An attached terminal runs `/queue TEXT` at the open prompt (no turn running) as a turn, as the plain REPL and the
  docs say, instead of refusing it; it is refused only while a turn runs.
- A `hosts:` entry that fails while it is read is ignored on its own with a warning naming it, instead of every host
  silently dropping (in the process and in its workers); a failure outside the entries is logged.
- A `/thinking`, `/model` or `/llm-context` queued during a turn no longer lets the turn-end warm-up prefill a prompt
  the change then throws away.

## [0.51.0] - 2026-10-10

### Added

- `/cut TEXT` in a terminal (plain REPL and attached) and `chi send --cut` ask the running turn for a cut: a
  generation that has streamed only thinking for `steer.cut_after` seconds is cut (now, or once its thinking passes
  that) and the step starts again with the message. The terminal's dim line and `chi send`'s line say what happened
  (`cut in now`, `cuts in once the thinking passes 20 s`, `cutting is off; goes in at the next step`); `--format json`
  adds `delivery` and `cut`. The Bridge's 202 for a turn names its `delivery` and, for a cut, the `cut` outcome.
- `/queue TEXT` in the plain REPL runs TEXT as a turn of its own after the running one.
- A tool call named `bash` (any case) with `execute`'s arguments runs as `execute`; the logs keep the model's
  own spelling, and the tool row says "(called as bash)" (TUI and web, live and after a reload). `/stats` and
  `chi sessions stats` count such calls by that spelling (`called as: bash=N`, `tool_calls_aliased` in JSON).

### Changed

- A message sent during a running turn (typed in a terminal, from the web, `chi send`, a parent agent) goes in at the
  turn's next step and no longer cuts the model's thinking; only a message sent as a cut does. A line typed mid-turn
  says `(goes in at the next step)`, and `chi send` says `sent (goes in at the running turn's next step)`.
- A call for a tool that doesn't exist no longer gets its own wrong name quoted back (seeing it again made the
  model call it again): shell-like names (`bash`, `shell`, …) get `Error: no such tool. Shell commands run with
  execute (same arguments).` when `execute` is offered this turn, every other name the available-tools list; the
  UI's tool row and the logs still show what the model called.
- Web: the open session's title shows once: in its strip card, or in the top bar when the strip is hidden or the
  session has no card there (an older session, a folded delegate). The composer footer's first-message line and the
  banner that appeared at 20 % context are gone; the memory names stay in the footer's `mem N` chip and tooltip.
- Web: the browser tab names the open session (`<first message> · Chi · <project>`), so several chi tabs read apart.
- Web: the hidden strip's "▾ N sessions" pill counts sessions, the number the "All sessions →" tile shows (it
  counted cards, so a folded family made the two disagree).
- Web: the composer's "Cancel" reads "Stop turn" and the footer's "stop" reads "stop session", each saying what it
  ends.
- Web: a toast (the update notice, an archive's Undo) sits above the open session's composer card instead of over
  its footer, so it never covers the footer's controls (a worker badge's Restart); it follows the card as it grows.

### Fixed

- A bare model id, or an alias with a bare target (`splash: incoai/Qwen3.8-27B-Splash`), in a process that hasn't
  listed the hosts yet (`chi --model splash`, `chi send --new --model splash`, a delegate's worker) goes to the host
  whose saved list (`model_lists.json`, at most a week old) has it, instead of always the default host.
- `chi sessions stats ID --format json` for a session no worker runs lists its newest saved turn (and that turn's
  tool calls) in `turn_records` / `tool_records`, as a live worker's snapshot does, instead of empty lists.

## [0.50.0] - 2026-10-09

### Added

- `chi sessions stats ID [--format text|json]`: a session's cost, tokens and progress without running a model turn:
  a live worker's `GET stats` (waiting up to 3 s), else the snapshot its saved `analytics.json` rebuilds (never
  starting a worker); text prints the `/stats` report headed by `<id8>  <status>  <model>`, json one
  `{session_id, status, live, metrics}` object.

### Changed

- A turn record in `analytics.json` says whether the turn was a step-limit Continue (`continue: true`, else `false`),
  and the model-notes report counts Continues from that mark when the file has it, instead of the older guess (its
  turn records with no prompt of their own), which also counted reminder turns and prompts `!rollback` erased.

### Fixed

- TUI: a tool row whose output the runner cut says so with a dim `[cut]`, as the web's row already marks it.
- `/models` is listed as an anytime command (`mid-turn too`) in `/help` and the web's command list, not the
  per-line `depends` label it got while it always runs mid-turn.
- Web: a host added to `hosts:` (or a `hosts.<name>.models` context window changed) in config.yml while `chi web`
  runs now reaches the session cards' ctx % on their next refresh, not only after a restart; the hub's host registry
  is rebuilt when `hosts:` changes, as the model picker's already was.
- A host listing saved to the state dir when the registry was built with its own env (the spawn-time model check, the
  self report) writes under that env's state dir, not `ENV`'s.
- loop-guard: a dropped stream's step asked again (it streams from the start) no longer reads the dropped attempt's
  thinking as part of the new one — the model re-thinking the same opening after a restart could be cut or stopped
  as "thinking repeats itself". The first `:generation_progress` fire after such a restart carries `restarted: true`,
  and the loop-guard thinking watch starts over on it (loop-guard 0.3.7).
- Web: the live timing line counts up from the first second (tenths of a second while under 10 s, ticking every
  200 ms there) instead of reading "0ms" for the turn's first second.
- Web: the stage trail's items hover their whole text — a flash (a hook notice) its whole line, a call its full
  command when it has one, else its whole truncated text.
- Web: a `!cmd`'s output shows once, as a command bubble: the history renders the saved `!(<command>)` message as
  one (not a user bubble), and a live `command_ran` no longer adds a second bubble after the redraw.
- `chi send` refuses a UI-only command (`/stats`, `/exit`, `/recap`, …) instead of passing it to the worker, which
  doesn't run it, so the line reached the model as a prompt and cost a whole turn; the refusal names
  `chi sessions stats` for `/stats` and sends nothing (exit 1, also with `--new` before a session is created).

## [0.49.0] - 2026-10-09

### Added

- Native Gemma 4 on llama.cpp (with `--mmproj`) sees images: `@path`, `read` on an image and the web's pasted images
  reach it, as they do Qwen 3.6. Before, chi refused with "profile gemma4 has no image template yet".
- Plugins: `ctx.frontend` says what runs the session: `:repl` (the REPL, `-p` without `--non-interactive`),
  `:one_shot` (`-p --non-interactive`) or `:worker` (a session worker: the web, an attached TUI).

### Changed

- github-pr 0.4.0: line links read the PR's files (`gh api`) only in a session worker (the web, an attached chi), not
  in the REPL, `chi -p` or a scratch session, whose answers no web page shows while they run. `bundles: github-pr:
  line_links: always` reads in the REPL and `-p` too; `false` still turns it off. The PR lookup and attach are
  unchanged. See [Line links](docs/context.md#line-links).

### Fixed

- Web: a command queued mid-turn (`/model X`) shows its bubble after the turn's answer once it runs, not among the
  turn's rows above the answer.
- A background task whose process exited and whose pid another process reused since no longer reads as running in
  `task_list`, `task_get` and `task_wait` until a `task_stop`: each read checks the process's start time.
- A continue that died after noting its moved delegates no longer notes them again when the new link's worker
  finishes the move: `move.json` records who was told.
- An attached chi watching a `-p --non-interactive` run says a question there was dismissed because no one could
  answer it (`(dismissed: no one to answer in a non-interactive run)`), as the run itself does, not
  `(question cancelled)`.

Update with `chi update`: it updates github-pr (0.4.0: line links only where the web can show them). If you set
`line_links: true` to get links in the REPL, set `line_links: always` instead.

## [0.48.0] - 2026-10-09

### Changed

- Continuing a session moves its open delegates to the new link instead of refusing: running, waiting, live or with
  an unreported reply, at any depth below. They stay unarchived, fold under the new link, and their reports (one
  each, none lost or repeated) reach it; each gets a note naming its new parent. Only a delegate on an older chi's
  worker (restart it) or open in a chi REPL still refuses the continue. See
  [docs/sessions.md](docs/sessions.md#session-chains).
  - Web: the continue toast counts the delegates that moved (`1 open delegate moved`); `POST /api/sessions` with
    `continues` answers `moved: [ids]`.
  - CLI: `chi send --new --continues` prints `started (continues 3fa2c1d0; 2 delegates moved)`.

Update with `chi update` (no bundle changed), then restart `chi web`. A delegate whose worker started on an older
chi refuses to move until it is restarted.

## [0.47.0] - 2026-10-09

### Added

- Session chains: a session can be continued as the next link of its chain (a day's work after yesterday's, say).
  The next link starts in the same folder, on the same model and LLM context, with a visible note that carries the
  previous link's recap (asked for fresh from a live worker), and the previous link is archived with its delegates.
  A continue is refused while one of those delegates is still open, for a link continued already (no forks), and for
  a folder that's gone. See [docs/sessions.md](docs/sessions.md#session-chains).
  - Web: `continue →` in the info bar starts the next link and opens it with `Continue where we left off.` in the
    composer, not sent. A link continued already links to its neighbours (`← date` / `date →`), and a continue
    refused for open delegates names them, each a link. A chain is one card in the lists, the latest link's, whose
    `↩ day N` chip lists the earlier links (day, date, recap) in a popover; a link titled with the opener shows its
    chain's first title.
  - CLI: `chi send --new --continues (ID|PREFIX|last:ID) [-m TEXT]` (idle without a message); `last:ID` follows the
    chain to its latest link, for a script or a scheduled job.
  - API: `POST /api/sessions` takes `continues: <id>` (with `idle: true` or a `prompt`); a link continued already
    answers 409 `continued` with `next_id`, an open delegate 409 `open_children`. Sessions carry `continues`
    (`chi sessions list` ends such a row with `↪ <previous short id>`; `--format json` and the web summaries too).
- coordinator 0.3.0: `/coordinate end` ends the day. The model brings its `handoff_*` memory up to date (state per
  branch, decisions, verdicts, follow-ups, each open child's id, branch and worktree), keeps it OPEN unless everything
  is done, and gives a short end-of-day report that names the children still running and says
  `/coordinate resume <slug>` for next time. It starts, merges and stops nothing.

### Fixed

- A web message that ended (or began) with whitespace stayed in the composer after it was sent: one sent right
  after Annotate (its quote ends in a blank line), or with a trailing newline or space. The sent text is trimmed,
  and the composer was cleared only when it held exactly that text; it is now compared trimmed too.

Update with `chi update`: it updates coordinator (0.3.0: `/coordinate end`).

## [0.46.1] - 2026-10-09

### Changed

- The terminal and the web word a retry line the same: `↻ retrying (503) in 4.0s, 2/5`, why in parens (the HTTP
  status, the error's short name such as `ECONNREFUSED`, or `stream dropped`), the wait with one decimal, and the
  retry of all there will be. The terminal said `retrying (2/5 in 4.0s)`, the web `↻ retrying (503) in 4 s, 2/5`.

### Fixed

- A question the model asks in a `chi -p --non-interactive` run no longer tells the model the user dismissed it:
  it is told no one could answer (a non-interactive run). The question closes with reason `non_interactive`.
- The web's card for a question closed that way reads "No one could answer (non-interactive run)", not
  "Cancelled (non_interactive)".
- A delegate's report read by a turn that ended canceled is no longer brought a second time when the Engine's
  post-turn work then fails (a full disk, say).
- github-pr 0.3.3: a `path:line` into a vendored copy (`vendor/lib/foo.rb:21`, or `/abs/repo/vendor/lib/foo.rb:21`)
  is no longer linked to the PR's `lib/foo.rb` in the web: an absolute path's part before the PR path must be a
  worktree's root (a directory with `.git`), or no directory on this machine. An absolute path into a worktree, or
  one up from a subdir (`../lib/foo.rb`), still is.
- A step whose stream kept dropping now fails saying how many requests it made ("after 3 attempts"), not
  "after 1 attempts"; one attempt is said in the singular.
- A step that ends on another error after its stream dropped (a 503) counts the dropped requests in that
  error's attempts too, and a step asked again without thinking fields (a host refused them) keeps its count of
  stream drops: it no longer gets two more ask-agains of its own.
- A host that is down is named once in the models list's warning and in `/models` (`gw: connection refused`, not
  `gw: gw: connection refused`).
- A host whose model listing kept failing on network errors is named once too, in the models list's warning, the
  web's and `/models` (`gw: request failed after 3 attempts: …`, not `gw: gw request failed after …`).
- `/stats`' estimated cost names the host whose prices it used (`from hosts.gw.models prices`), not a literal
  `hosts.<name>.models`.
- The config warning for a model price's old `cached` key suggests `cache_read`, its new name.
- The web's ⚠ for a model the server served instead of the one asked now shows on a session opened with no
  worker running too (from its saved analytics), not only while its worker runs.
- A host whose `/v1/models` fails no longer drops the ids declared under `hosts.<name>.models` from `chi models`,
  `/models` and the web model picker: they stay, marked `host down` (greyed in the picker, still pickable;
  `unavailable: true` in the JSON), next to the host's warning. Ids only the host itself lists still drop out.

Update with `chi update`: it updates github-pr (0.3.3: no links from a vendored copy to the PR's file).

## [0.46.0] - 2026-10-09

### Added

- `hosts.<name>.models:` declares the model ids a host serves whatever its `/v1/models` lists (a gateway's
  round-robin ids), as a map of ids or a plain list. A declared `host:id` is never warned about or re-listed at
  `chi send --new` and delegate spawns, and a bare id routes to its declaring host as if listed, before any
  `/models` and in workers too. Two hosts declaring one id warn at start. See "Models a host serves but doesn't
  list" in [docs/configuration.md](docs/configuration.md).
- Declared `hosts.<name>.models` ids show first under their host in `/models` (as `rr/x (config)`, outside the 20
  per host, also on a host that lists nothing), `chi models` (plain names; `--format json` adds `configured: true`)
  and `GET /api/models` (`configured: true`). A host that doesn't answer shows none of them.
- `hosts.<name>.models.<id>.price: {input, output, cache_read?, cache_write?}` (USD per 1M tokens) estimates the
  cost of a generation whose provider reports none, or reports 0. A reported non-zero cost always wins. The estimate
  is saved apart (`cost_estimate` per turn, `cost_estimate_sum` in the totals). See "Prices" in
  [docs/configuration.md](docs/configuration.md).
- `hosts.<name>.models.<id>.served: [ids]` (or `any`) names the models a gateway may answer a round-robin id with.
  Those are no longer marked as served by another model (the web's `⚠`, the status line's `(served; asked …)`,
  `/model`'s `served:`, `/stats`' "(asked for …)"); one it doesn't name still is.
- An estimated cost shows with `~`: `/stats` (`$0.42 reported + ~$0.12 from hosts.<name>.models prices`) and the
  ctx tooltip on the info bar and the session cards (`cost: ~$0.54 ($0.42 reported, ~$0.12 estimated)`).
- The web model picker lists a host's declared ids first under it, noted `config` (the default model keeps
  `default`), with `served by config (hosts.<name>.models)` in the row's tooltip.

### Fixed

- A chat generation whose stream dropped mid-answer (a read timeout or a reset after deltas had shown) failed the
  whole turn: the chat loop now drops the partial reply and asks again for the same step, from the same
  conversation, at most twice, reporting each ask-again as `generation_retrying`, as the transport's retries do.
  A cancel, a provider error, a first-token timeout and a connection refused still fail as before, and a step whose
  retries run out fails the turn with the same error. Each ask-again waits the transport's backoff (`retry.*`),
  which a cancel cuts short, and `retry.max` caps the asks-again (`retry.max: 0` turns them off). Its
  `generation_retrying` carries `restarted: true`: the web's live step, the TUI's activity line, a reload in the
  middle of the turn and the stream hooks drop the partial reply, so the answer shows once.
- `task_stop` could signal an unrelated process group whose leader reused a finished task's pid. A task now records
  its process's start time, and a pid that started at another time is not signalled (the task ends as failed).
- A delegate's report merged into a reminder or continue turn was lost when the turn failed past its loop (the
  turn's own end, say): the turn kept only its start, yet the report counted as read. Its ring now stays, and the
  next turn brings it.
- A delegate wait that relayed a child's approval ran to its timeout when the child ended its turn with no reply
  while the answer was being posted; it now ends there.
- Chi Helper: a send that ended after the panel was reopened wrote its "sent"/"failed" line into the new panel, and
  a success could close it; like a broadcast, it now leaves the new open alone.
- `chi -p … --non-interactive` hung forever when the model asked a question (`ask_user_question`) while its stdin
  was a pipe that stayed open (`sleep 30 | chi -p …`, a parent holding stdin): it waited for an answer line. Nobody
  can answer there, as for an approval: the question is dismissed at once (one line on stderr), the model finishes
  its reply, and stdin is never read. Piped answers without `--non-interactive` (`printf '2\n' | chi --no-shared -p
  …`) work as before.

## [0.45.0] - 2026-10-08

### Added

- Plugins: `ctx.fork?` says whether the session is a fork (`ctx.sessions.fork`: it has a parent and isn't a
  delegate child). See [docs/plugins.md](docs/plugins.md).

### Changed

- Commands sent while a turn runs no longer all answer `busy`. Those that only show something answer at once
  (`/models`, and `/model`, `/llm-context` and `/guardrails` alone). Those that change something (`/model X`,
  `/llm-context strategy …`, `/guardrails revoke N`) and `!cmd` run after the turn, in the order sent with the
  prompts: the terminals say `(queued: runs after this turn)`, the web draws the command's bubble dashed until it
  ran (after a reload too), and the web's `llm ctx` chip can Set mid-turn. A `!cmd` waiting after a canceled or
  failed turn is dropped, so the turn's `!rollback` stays open, and one still waiting when the worker stops is
  answered `dropped`. `!rollback` and `/continue` stay refused (`busy: Ctrl-C the turn first, then !rollback`).
  `/archive` typed during a turn archives once it ends, in the REPL and an attached terminal. `chi --attach ID
  --model X` on a running turn waits for its end. See "Typing during a turn" in [docs/cli.md](docs/cli.md).

### Fixed

- `/stats`, `/model` and the web named no model notes for a fresh session (a REPL's before the first turn, a new
  web or worker session), though its first turn's prompt carries them; they now name the notes that prompt will
  load. A session whose prompt carried none keeps saying so.
- `chi self`'s `model notes` row resolved a note's model overlay from the process's `XDG_CONFIG_HOME` while it
  read the note itself from the env it was given, so the row could count no overlay (or another config's); it now
  reads both from the same env, and passes the fallback key the session's prompt does, so a model typed as an
  alias whose note overlay is keyed by the alias's name shows it — the row agrees with the notes the session's prompt loads.
- In the plain REPL a session command typed at a continue offer (other than `/continue`) was read as an invalid
  answer and lost; it now runs and the offer stays open, as in a worker.
- A session command sent as a message behind queued prompts (`chi send -m "/model x"` after `chi send -m "task"`)
  could be answered `busy` by the next queued prompt's turn instead of running before it; it now runs once its
  own message's turn comes.
- The web's ctx meter under an LLM context budget smaller than the window (`llm_context.budget_tokens`) read the
  percentage of the window after a reload (`ctx 12%`) where live it read the budget's (`ctx 25%`); it now counts
  against the budget both ways, as the `[CONTEXT: …]` line and the status line do, and a generation's final counts
  no longer flip it back to the window mid-turn. The ctx tooltip's context line says so: `context: ~16.0k of the
  64.0k budget, 128.0k window (server)`.
- The web's strip of latest sessions, back from All sessions with the pointer still on it, could keep a waiting
  family behind other cards until the pointer moved: an update that came while All sessions opened was drawn in
  the order held for the pointer.
- github-pr 0.3.1: in `auto_attach: offer` mode a forked session (`/btw keep`, a plugin's fork) now gets its
  `first_prompt` row in `offers.ndjson` (its first prompt after the conversation it started from), as a new
  session does; it got none.
- A resumed or attached session (`chi --resume`, `chi --attach`) drew a turn that failed with its steps kept as its
  prompt and tool rows followed by an earlier step's text, as if that were the answer; the join now draws the line
  the live view left (`✕ turn failed: HTTP 500: boom · 2.0s`, then `  partial progress kept; !rollback restores the
  pre-turn state` when the steps stayed) after the rows, with no answer text, as the web does.
- The web's stage trail: when the ✂ row of an applied LLM context edit landed in its step inside the
  closed cloud it was out of sight and, unlike a hook's notice, flashed nothing. It now flashes in the
  trail for a few seconds, as its row reads (`✂ forgot 2 outputs, stubbed 1 stale read · frees ~4.1k
  tokens (paid off)`), as a hook notice does.
- The web's stage trail: when a message cut a generation that was still thinking, its row (`↪ cut in
  for your message`, `… a message sent with chi send`, `… the parent agent's message`) landed in its
  step inside the closed cloud and, out of sight, flashed nothing. It now flashes in the trail for a
  few seconds, as its row reads, as the ✂ row and a hook notice do.
- `chi send --new --model` and `delegate` warned `host 'h' doesn't list model 'x'` for an id the host serves, when
  the on-disk model list still named the model a one-model server served before it was reloaded: a saved list
  older than 10 minutes that misses the id now re-lists that one host once (bounded at 5 s) and judges again
  against what it lists now, saving the fresh ids. A list from the last 10 minutes is taken at its word, so a host
  that serves ids it never lists (a gateway's round-robin aliases) is not asked on every launch; a re-list that
  fails, times out or lists nothing warns from the saved list.
- The session lists' `ctx %` (the web's session cards, `chi sessions list` and its `ctx 12%` column, the
  `list_sessions` tool's `ctx_pct`) and `/stats`' `context used:` still divided by the window when the session's
  LLM context budget (`llm_context.budget_tokens`) was smaller, where the live meter counts the smaller of the
  two; they now count the same way, and `/stats` says so: `context used:     16000 tokens (25.0% of the 64000
  budget)`.

## [0.44.0] - 2026-10-08

### Added

- LLM context edits are visible: each batch of stubs that reaches the prompt gets a ✂ row in its step, in the web
  and the terminal (`✂ forgot 2 outputs, stubbed 1 stale read · frees ~4.1k tokens (paid off)`), whose web hover
  lists the outputs, a stale stub's reason, a forget's note and kept lines, and the cost. After a reload a stubbed
  output's tool row carries a ✂ mark (`✂ stubbed: superseded by a later read · ~1.0k tokens`, `✂ forgotten: <note>`,
  `✂ forget staged`). The stream has a new event, `llm_context_edited`. See
  [docs/configuration.md](docs/configuration.md) ("LLM context: what you see (✂)").

### Fixed

- Under an `llm_context.budget_tokens` budget without the forget layer (strategy `none` or `stale`), the model's
  `[CONTEXT: …]` line said "of the context window" for a percentage of the budget; it now reads "about 62% of the
  context budget (64k tokens) is in use", and its top bucket no longer asks the model to "summarize aggressively"
  ("context budget critical — avoid large outputs and re-reads, delegate broad work to subagents").

## [0.43.0] - 2026-10-08

### Added

- A new web chat can start under its own LLM context: the start page has an `llm ctx` chip beside the model
  picker that shows the picked model's strategy, and its form (as the info bar's, titled "new chat") sets a
  strategy, apply rule and budget for that chat's first turn on (`llm ctx stale · new chat`). The choice is not
  remembered: it resets after a create, on a reload and when you open a session, and an untouched chip sends
  nothing. `POST /api/sessions` takes
  `llm_context` (`{strategy, apply, budget}` as `/llm-context` words them; anything else answers
  `400 invalid_llm_context`), and `GET /api/models` rows carry each model's `llm_context`. See
  [docs/configuration.md](docs/configuration.md) ("LLM context: a session's own strategy").
- The web's `ctx` chip shows the context window and where it came from: its tooltip gains `context: ~41.0k of
  128.0k tokens (server)`, and the chip reads `ctx ~12%` when the window is chi's 256k default, a guess no server,
  model list or setting gave (the tooltip says to set `window_tokens` for the model).
- github-pr 0.3.0: `bundles: github-pr: auto_attach:` says what happens to the branch's open PR when a worker
  starts: `attach` (the default, as before), `offer` (a card, "PR #42 for branch feat/x", with **Attach** and **Not
  here**, shown once per session; `/pr-attach 42` and `/pr-decline 42`) or `off` (nothing). In `offer` mode the
  offers, what you clicked and each session's first prompt go to a local log, `plugins/github-pr/offers.ndjson` in
  the state dir. See [docs/context.md](docs/context.md) ("Attach, offer or off").
- For plugins: `ctx.context.decline(url:|name:)`, `declined?(name, url:)`, `attach(…, force: true)` (the user's
  explicit choice, past a decline) and `mark_offered(name, hint)` / `offered(name)`, a per-session record that a
  plugin offered a source. See [docs/plugins.md](docs/plugins.md) ("Attached context").

Update with `chi update`: it updates github-pr (0.3.0: `auto_attach`; needs chi 0.43.0).

## [0.42.0] - 2026-10-08

### Added

- Which model notes a session's prompt carried: each prompt build (and `/model`) records them in the session file
  (`prompt_notes`: name, scope, size and a short digest), and they are shown in `/stats` (`model notes:
  model_notes_deepseek (system, 612 chars)`), at the end of `/model`'s line (`; notes: …`, after a switch the new
  model's), as a `notes: deepseek` chip in the web's info bar and as a `model notes` row in `chi self`. Nothing shows
  without notes. See [docs/memory.md](docs/memory.md) ("Model notes").
- For development: `script/model_notes_report.rb`, which groups stored sessions by model and by the model notes
  their prompt carried and compares the calls to the first edit and commit, commits per 100 steps, bare `&` in
  `execute`, the longest run without an edit and the Continues and steers each session needed (`--model`,
  `--since`, `--min-steps`, `--json`). It isn't part of the gem. See [docs/testing.md](docs/testing.md).

### Fixed

- The web showed no failure line after a reload for a failed turn whose steps stayed (new in 0.41.0), so the turn
  looked unfinished; it ends with the same `✕ turn failed: <why>; partial progress kept (!rollback restores the
  pre-turn state)` line as live (from the turn record, which keeps the failure now; a turn recorded before this
  shows none).
- A delegate report could reach the parent's model twice: a reminder or continue turn that failed before any
  progress kept the report it had read, and the next turn brought it again. A canceled continue turn's report was
  never delivered. A report's ring now goes only when the turn that read it stays in the conversation.
- `/llm-context` (the web's `llm ctx` chip, `--llm-context` on `--attach`) against a worker on an older chi answered
  `400 not a session command`; the web (`501 not_supported`) and the attached terminal say the worker runs an older
  chi, with the line that restarts it.

## [0.41.0] - 2026-10-08

### Added

- Model notes: a memory named `model_notes_<name>` whose first line is `models: <globs>|small` goes into the system
  prompt of every session on a matching model, in its own section after the identity memory (all matching notes,
  system scope then project). The habits of one model (or a family, or every small model) no longer ride on an
  identity overlay keyed to one provider's id. `--mute model_notes_<name>` drops one for a session; `memory_write`
  refuses a note without the `models:` line. See [docs/memory.md](docs/memory.md) ("Model notes").
- The guardrails bundle (0.9.0) asks, once at a time and only the user may allow it, before a model writes a memory
  that reaches the system prompt: the identity memory, a model note or an overlay of either, by `memory_write`,
  `write` or `edit`, through a symlink or in any case of the name (`prompt-memory-write`), or a model overlay of any
  memory (`model-overlay-write`). A rule's `memory:` takes `overlay` and `prompt`. Run `chi update` to get it.
- A session's own LLM context strategy, apply rule and budget, before the model's: `chi --llm-context stale,forget
  --llm-context-apply turn_end --llm-context-budget 64k` at start (also `chi send --new`, and `--resume`),
  `/llm-context` in the session (no arguments: each value and where it came from; `strategy`, `apply`, `budget`,
  `default` to unset one, `reset`), and the web's `llm ctx` chip in the info bar. Saved with the session (kept by
  `--resume` and forks, not by delegates); a change applies from the next turn's start, and its reply says what it
  costs (forget on or off re-reads the prompt once; stale turned on stages the reads already superseded as one
  batch; a layer turned off sends its stubs whole again). `/stats` and the turn log show the effective strategy and
  its source. See [docs/configuration.md](docs/configuration.md) ("LLM context: a session's own strategy").
- The memory indexes' size, which every prompt carries in full: `chi self` has a `memory index` row (`system ~2.0k
  tokens (54 lines), project ~1.4k tokens (35 lines)`), and `/stats` and the web's ctx tooltip show what the
  session's prompt holds (`memory index: ~3.4k tokens in this session's prompt (system 2.0k, project 1.4k)`). A
  `memory_write`, `write` or `edit` that takes a scope's index over `memory.index_warn_tokens` (new; default 2500 per
  scope, `0` off) gets one note asking the model to tighten long index descriptions when it has a moment, and not to
  remove or merge memories unless the user asks; a write while already over gets none. See
  [docs/memory.md](docs/memory.md) ("The index's size").

### Changed

- A guardrails rule's `models:` also takes a `|`-separated string (`"small|deepseek-*"`), as
  `guardrails.small_models` does.
- The system prompt's `Model:` line says guidance for this model goes in a model note (it said a memory overlay).
- `memory_write` refuses a memory name with a comma (`memory_read` reads a comma list of names).

### Fixed

- A turn that failed partway (out of credits, a server error, any provider error but a context overflow) after tool
  calls lost them: the saved session held only the failure note, and the prompt went back for a retry that would
  run the task again over files it had already changed. Such a turn now keeps its steps, as a cancel does: the model
  reads that it failed after N tool steps and that its work stays, the prompt is not handed back, and `!rollback`
  still erases the turn (`partial progress kept` in the terminal and on the web; `chi send --wait` and a delegating
  parent read `the turn failed after N tool steps: <why>; its work so far stays`). A turn that failed before it got
  anywhere, or on a context overflow (kept, the conversation would stay too long for the window), is rolled back and
  its prompt restored, as before. Since 0.2.0.
- On a case-insensitive disk a write to the memories' `INDEX.md` (any case) was taken for a memory and added a bogus
  line to the index.

Update with `chi update`: it updates guardrails (0.9.0: asks before a model writes a memory that reaches the system
prompt; needs chi 0.41.0).

## [0.40.0] - 2026-10-08

### Added

- Experimental: the `forget` layer of `llm_context.strategy` (`[stale, forget]`, per model or host as ever). That
  model gets a tool, `forget_outputs`, to forget its own tool outputs: each output shows an id (`[#t41]`), and a
  forget replaces the outputs named with a stub holding the model's note (required; the session keeps the outputs).
  `keep` keeps lines of an output, `restore` brings a non-read one back; outputs of the last `protect_steps` steps,
  and reads of files edited in them unless lines are kept, are refused. The stubs reach the prompt under
  `llm_context.apply`. `llm_context.policy` is the sentence the tool's description carries. Off, the tool list and the
  prompt are what they were. See [docs/configuration.md](docs/configuration.md) ("LLM context: the forget layer").
- `llm_context.budget_tokens` (and per model or host `llm_context_budget_tokens`), off by default: a soft context
  budget the `[CONTEXT: …]` lines count against instead of the window. Under `forget` those lines show
  `~N/M tokens in use` and offer the tool in tiers (a readout, then "tidy once", then "compact settled outputs now"),
  at a turn's start, mid-turn only in the top tier.
- The replay bench's `forget_outputs` strategy asks a model at chi's forget offer and scores its picks, call rate and
  notes (`--forget-model`, `--out`, `--budget`, `--max-cost`).

### Changed

- Web: session cards no longer show the "mem N" chip, leaving room for the delegate chip; the card's tooltip and the
  open session's info bar still list the memories used.

### Fixed

- Web: a session card's hover tooltip (id, update time, status, memories) was empty since 0.35.0.

Update with `chi update`: it updates loop-guard (0.3.6: ignores `forget_outputs`).

## [0.39.0] - 2026-10-07

### Added

- `llm_context.strategy` (default `none`), and per model or host `llm_context_strategy`. `stale` sends a file read
  that a later read of the same lines superseded as a one-line stub; the session keeps the output. With
  `llm_context.stale_edits: true` (opt-in, experimental) a read a later edit or write of the file superseded is
  stubbed too; on the replay bench these cost about 5x the tokens they free in re-prefill, and 26% were needed again
  (against a 6% base rate). No read of a file edited in the last `llm_context.protect_steps` (3) steps is stubbed.
  `llm_context.apply` (and per model or host `llm_context_apply`) says when stubs reach the prompt: `payoff` (the
  default) sends them at a request when they free at least the tail the server reads again, else at the end of a
  turn the model answered, which in practice is usually where they go; `next_request` and `turn_end` are the
  others. See [docs/configuration.md](docs/configuration.md).
- `/stats` shows the re-prefilled tokens for every session (what the server prefilled again of the previous
  request's prompt, 128 tokens or more), and the log's `generation_completed` line has them as `reprefill=`.
- For development: `script/llm_context_bench.rb`, a replay benchmark for the LLM context strategies over a folder of
  stored sessions (offline; `--live` asks a model, for picks). It isn't part of the gem. See
  [docs/internals/llm-context-bench.md](docs/internals/llm-context-bench.md).

### Fixed

- Answering a step-limit question with Continue and then sending a prompt runs the continue turn first, even when
  both arrive while the worker is between turns (the prompt could run first and drop the offer). A session started
  from another session's `execute` (`chi send`) no longer inherits that session's `SAMAGOTCHI_PARENT_SESSION` and
  `SAMAGOTCHI_SESSION_MODEL`, so your `!chi context add` there attaches to it, not to the other one. `context_read`
  pages within `max_tool_output_chars` whatever its header holds, so a page is never cut a second time behind its
  "Pass offset". The mcp bundle (0.6.1): `mcp_call` with a mistyped `<server>/<tool>` waits only for that server's
  start, and `find_mcp_tools` names a server with no `description:` or instructions by its tool count, not its first
  tool names (a model called those without searching).

Update with `chi update` (mcp 0.6.1).

## [0.38.0] - 2026-10-07

### Added

- The desktop helper's panel has an **Everyone it concerns** row (⌘B): ⌘⏎ there runs `chi broadcast` with the note
  (your line, then the selection; a first line like `shopfront/checkout` keeps it to that project), instead of a
  note to the sessions you pick. The panel shows "broadcasting…", then the summary line, and stays open; `chi
  broadcast log` has the details. It may take `broadcast.triage_deadline` + 10 s: after changing the deadline, run
  `chi update`. Rebuilt by `chi update`. See [docs/desktop.md](docs/desktop.md#everyone-it-concerns).

### Changed

- The mcp bundle (0.6.0) no longer declares every MCP tool to the model. It gets two fixed tools: `find_mcp_tools`
  searches the servers' tools by keywords and answers the best 5 with their schemas, and `mcp_call` calls one as
  `<server>/<tool>`. Requests get smaller (about half on a 30-tool server, in a spike on a local model), and the
  model's tools no longer change when a server starts, refreshes or fails, so the prompt cache keeps; a tool turn
  takes a few more steps (search, then call). A failed call answers the tool's schema, so a call can be fixed on the
  next step. A server's new optional `description:` names it in the search tool, else the first sentence of its
  instructions. Guardrail rules on `mcp_<server>_<tool>` names still match (`mcp_call` acts as that tool), and the
  question names `<server>: <tool>`; approvals stored under the old names don't carry over. Hooks and loop-guard's
  `ignore_tools` see `mcp_call`. `/mcp` lists the tools as `<server>/<tool>` and says what every request carries.
  Needs chi 0.37.0. See [docs/plugins.md](docs/plugins.md#the-mcp-bundle).

### Fixed

- `chi broadcast`'s triage ends at most a second after `broadcast.triage_deadline` (requests that ignore the cancel
  could hold it up to ~4 s past it), turns logprobs off for a host only when its 400 was about them, and two broadcasts
  at once no longer both rotate the triage log (one failed, or the old lines were lost). A scope card's folder is right
  under a symlinked path (`/tmp` on macOS read `../../../tmp/…`), and the summary line shortens a reason that quotes a
  setting (`3 unchecked: no triage model: broadcast.triage_host_ref`).
- `max_tool_output_chars` caps the tool outputs the model gets back on the native loop too (a host without
  `api: openai`): it fed each output whole, so one long result could fill the context. On both loops a cut output now
  ends with `[cut: N of M chars; read it in parts]`, so the model knows it didn't get it all (the chat loop cut it
  silently); the tool row shows the same text.

Update with `chi update` (mcp 0.6.0; it also rebuilds the desktop helper for the new row).

## [0.37.0] - 2026-10-07

### Added

- For plugin authors: a tool's `targets:` may return `acts_as:` (the tool a call stands for, like an MCP tool behind
  a dispatcher), `args:` (the arguments it acts with) and `label:` (the name the approval question shows). A guardrail
  rule's `tool:` then matches either name, and "allow this call" is keyed by both names and those arguments. It can't
  name one of chi's own tools or another bundle's (dropped and logged). See [docs/plugins.md](docs/plugins.md#guardrails).
- `chi broadcast` asks a small triage model about the sessions no tag matched, instead of skipping them: it reads the
  note and each session's scope card and answers yes or no ("model: yes (p 0.91)" when the host gives logprobs,
  graded by `broadcast.threshold`). The model is `broadcast.triage_model` (with `triage_host_ref` or
  `triage_base_url`), else the recap's, else `default.model`; a ~9B instruct model or larger works well. Up to
  `broadcast.triage_parallel` (4) requests run at once, all within `broadcast.triage_deadline` (20 s): a session not
  judged by then, or whose request failed, gets the note anyway, and the summary line counts it ("1 unchecked: triage
  deadline"). A first line naming one project ("shopfront/checkout") keeps the note to that project's sessions.
  `--dry-run` runs triage too. See [docs/broadcast.md](docs/broadcast.md#triage).
- `chi broadcast` prints the broadcast's id and logs each recipient's verdict (`~/.local/state/samagotchi/broadcast/log.jsonl`,
  rotated at 2 MiB). `chi broadcast log [--last N] [--format json]` shows the last broadcasts and who got them, and
  `chi broadcast deliver BROADCAST_ID ID...` gives one to sessions it skipped, after all. See
  [docs/broadcast.md](docs/broadcast.md#the-triage-log).

Update with `chi update` (mcp 0.5.1).

## [0.36.0] - 2026-10-07

### Added

- `memory_write` with `name`, `scope` and `description` but no `content` changes only that memory's index line and
  leaves its file as it is (see [docs/memory.md](docs/memory.md)).
- `memory_write` with `name`, `scope` and `remove: true` removes a memory: its file (and model overlays) move to the
  bundle trash, which `chi bundle trash` lists and empties, and its index line goes; a line left after the file was
  deleted by hand goes too. A memory a bundle installed is refused (`chi bundle uninstall` owns it).
- The coordinator bundle (0.2.0) keeps a project memory `handoff_<epic>` with what git and the session list can't
  rebuild (the split, your decisions, its verdicts, follow-ups), its status in the index description, and resumes
  from it in a new session after checking git and the session list; `/coordinate resume` picks up an open handoff.
  When the work is done it marks the handoff DONE and asks whether to remove it. See
  [docs/plugins.md](docs/plugins.md#the-coordinator-bundle).
- The guardrails bundle (0.8.0) asks before every memory removal (`memory-remove`, once at a time). Guardrail rules
  take `memory: remove`.
- In the web, a file reference in an answer (`lib/foo.rb:28`, `lib/foo.rb:28-34`, in inline code too) links to that
  line of the pull request the session reviews: the PR attached to it or named in your messages (a delegate child's
  task too). Inside a changed hunk it opens the PR's Files changed view at the line, highlighted; elsewhere the file
  at the PR's head. Display only; `bundles: github-pr: line_links: false` turns it off (github-pr 0.2.0; run
  `chi update`). See [docs/context.md](docs/context.md#line-links).
- `/mcp` shows roughly how many tokens each MCP server's tool definitions take in every request, and the total
  (mcp 0.5.0; run `chi update`). See [docs/plugins.md](docs/plugins.md#the-mcp-bundle).

### Fixed

- `memory_write` with a blank `description` keeps the stored one instead of wiping it; a multi-line description is
  written on one line (it left orphan lines in `index.md`), and one longer than 200 characters is refused.

Update with `chi update` (coordinator 0.2.0 and guardrails 0.8.0, which need chi 0.36.0; github-pr 0.2.0, mcp 0.5.0).

## [0.35.0] - 2026-10-06

### Added

- `chi broadcast -m TEXT` (or stdin) shares a note with every session it may concern, without picking them: your
  own sessions a worker or a chi REPL runs, or that ended a turn in the last 8 hours (`broadcast.active_hours`),
  delegate children and scratch sessions left out. One gets it when the note shares a tag with it: a ticket id
  (`broadcast.ticket_pattern`) in its branch or your prompts there, a pull request attached to it, a link. The rest
  are listed as skipped; `--all` reaches every one, `--dry-run` shows who would get it and why. The model mentions a
  broadcast briefly when it affects its current work and doesn't act on it unless asked. For you, not for an agent:
  refused inside a session, and the guardrails bundle's `chi-broadcast` rule asks. See
  [docs/broadcast.md](docs/broadcast.md).
- `chi sessions list --format json` has `delegate`: true for a child the `delegate` tool started, false for a fork.
- A parent session shows its delegate children at a glance: a `⑂ 3` chip in its web info bar (how many run, wait,
  are done or failed in the tooltip; the waiting ones in the attention colour; a click opens all sessions), and
  `⑂ 2 running · 1 waiting` in the terminal's status row.
- A hook's `event[:notify]` and a plugin's `ctx.notify` take `fallback_for: :display`: the line repeats what the
  answer's display (`event[:present]`) shows, so a UI that renders the display leaves it out. The web with markdown
  on does; the REPL, the attached TUI, `chi -p` and the web with markdown off still show it. See
  [docs/hooks.md](docs/hooks.md#what-a-hook-can-do-the-runtime).
- Web, all sessions: each card has an archive button (unarchive on an archived one), and Select picks many cards
  (click, Shift-click a range, "Select all shown") for Archive N / Unarchive M. A session with a running turn is
  skipped with the reason on its card; one toast at the end has Undo.

### Changed

- source-links 0.4.0 (needs chi 0.35.0; run `chi update`): with markdown on, the web no longer shows the
  `sources:` line under an answer that links every ref it names; it still shows when a ref is only in code or
  markdown is off, and the terminals print it as before.
- `chi note --source broadcast` is refused: that source is `chi broadcast`'s.
- Web: a parent's delegates fold into its card, on the strip and in all sessions, instead of being cards of their
  own. A `▸ 3 delegates · 1 live · 1 waiting` chip opens their list (in the card in all sessions, a popover on the
  strip); it opens by itself while one of them waits on you, and the card then wears the warning colour. A family
  takes one strip slot, a search finds a parent by its delegates, and select mode picks cards. A fork and a delegate
  whose parent isn't listed stay cards of their own.
- guardrails 0.7.0: the `chi-broadcast` rule asks before an agent runs `chi broadcast`.

### Fixed

- Web: a tool row shows how long the call took while you watch the turn, as it does after a reload.

Update with `chi update` (guardrails 0.7.0, source-links 0.4.0).

## [0.34.0] - 2026-10-06

### Added

- `delegate cwd:` starts a child in another folder of the session's repository: a worktree the model made with
  `git worktree add`, or a subfolder. Another repository is refused.
- Plugins: `ctx.sessions.children` lists the session's children (state, branch, last reply and whether the parent
  was given it), and `ctx.sessions.stop(id)` stops one of its own children.
- Bundles: a `files:` entry in `manifest.yml` may carry a `description:`, which the install writes into the
  memory's `index.md` line.
- The `coordinator` bundle: chi coordinates parallel work. `/coordinate <goal>` (or asking for it) has chi split
  the work into tasks, each in a child session in its own git worktree, check each report and ask you before each
  merge. `/children` shows the session's children: state, branch, last reply and whether it was reported, with a
  Stop button each.
- Guardrails: a delegate child asks before it changes anything outside its folder (its worktree): a write there,
  git that changes the main checkout or a sibling worktree, a command run from or naming one of them. It's built in,
  in every mode and without the guardrails bundle, and answered once or for the child's session.

### Changed

- The `delegate` and `delegate_result` tools tell the model to start a child with `wait: false` unless its turn
  can't go on without the reply, then end its turn or keep talking with you: the reply comes back by itself as a
  delegate report. `delegate_result` is only for a reply the turn needs now.

### Fixed

- A wake turn (a context source's change, a delegate's report) that fails no longer tells the model the user's
  message went unanswered: it says the wake wasn't answered, and that no other wake turn starts until you write.
  For a delegate's report it adds that the report comes again with your next message.
- A delegate wait that timed out or was canceled says the child's reply still comes as a delegate report, instead
  of steering the model into waiting again with `delegate_result`; so does a question's result.
- `delegate` with `wait: false` in a session that gets no delegate reports (a `--no-shared` REPL, `-p`) says
  `delegate_result` waits for the reply, instead of promising a report that never comes.
- In a linked git worktree the system prompt no longer names the repository's main checkout ("Project root"), which
  led a model to work and commit there: it names this checkout's top and says to work only in it. Project memories
  and session lists still follow the repository.
- `delegate` refused for too many running children tells a session that gets delegate reports to end its turn (a
  report frees a slot), instead of to wait with `delegate_result`.
- At a repository's root the system prompt names the checkout the project's commands run in, and calls the project
  memories folder your notes about the project, not its files: a model no longer goes looking for the repository
  in the memories folder.

Update with `chi update`: it installs the new `coordinator` bundle for the `dev` profile (dev 0.3.0) and updates mcp
(0.4.5: stops an MCP server through chi's own process-group handling).

## [0.33.0] - 2026-10-06

### Changed

- Input from a client chi doesn't know (a script calling the web API with its own id, say) is no longer taken
  for the user's: the model reads it as automatic input, not your message, and it never cuts in on a thinking
  model. The TUI and the web label a prompt by its sender: "chi send", "chi answer", "plugin", or "automatic";
  "user" is left for your own lines.

### Fixed

- `task_stop` no longer signals a process group chi didn't start: a missing or reused pid in a task record could
  stop chi or other processes.
- A delegate child that crashes still wakes its idle parent.
- `chi send <id> --wait` to a stopped session with attached context prints the answer instead of "no answer".
- `chi bundle build` keeps a bundle's `scripts:` and `context_providers:`, so a rebuilt bundle still attaches its URLs.
- A context source's wake is no longer lost when a later update that doesn't ask to wake comes in before the
  session reads it.
- A failed wake turn leaves a plain note in the conversation; a reload no longer draws an empty turn for it.
- Web: the info bar no longer swallows a click on "copy chi --attach" or Restart while a turn runs, and its
  tooltips stay up.
- Web: an image the server refuses shows why; a 409 that isn't "open in a chi REPL" no longer switches the page to
  the REPL notice.
- Web: an answer equal to an earlier turn's ("Done." twice) is shown.

Update with `chi update`.

## [0.32.0] - 2026-10-06

### Added

- Attached context: `chi context add NAME --cmd CMD` (or `--push`) attaches live external text to a session or,
  with `--project`, to every session of the repository. A session's worker runs the command every so often
  (`--every`, else the new setting `context.every_seconds`, 300) and leaves the model a short note when the text
  changes; the model reads it with the new `context_read` tool when the user's request is about it. A command may
  print plain text or JSON `{text, summary, wake, hint}`. Also `chi context push|ls|show|refresh|rm|mute|unmute`,
  `/context` in every UI, and chips in the web's session bar (name · age, a dot for a change the model hasn't read,
  red for a failing refresh) with a popover to read the text, detach or mute. Nothing reaches a session before its
  first turn. The guardrails protect the store: the file tools can't write it, the shell asks (`shell-touches-chi`),
  and the guardrails bundle (0.6.0) asks before each `chi context add --cmd` (`chi-context-cmd`, once at a time;
  only the user may answer it).
- Attached context, part 2. A source whose update says `"wake": true` starts a turn in a live, idle session
  (labelled "context <name> changed") that only tells the user what changed: the new setting `context.wake`
  (default on), one wake per source per 10 minutes, within `session.max_wakes`. `chi context add <URL>` and a
  "+ URL" chip in the web attach a URL through a bundle's provider (manifest `context_providers:` and `scripts:`);
  plugins attach with `ctx.context` and can check `ctx.scratch?` / `ctx.delegate?`. The new `github-pr` bundle (in
  `dev`; needs `gh`) attaches the branch's open PR when a session starts and wakes it for a review requesting
  changes, checks turning red, or the PR merged or closed; its summaries carry counts, authors and states, never
  comment text; a PR you detach stays detached until you add it again. See [docs/context.md](docs/context.md).

### Changed

- Web: in a session the composer is one compact row (the text field, then Cancel and Send); its box starts at one
  line and the placeholder carries the key hint. The session footer keeps the first message to one line and shows the
  end of a long path.

### Fixed

- `chi bootstrap --key-env VAR` with `VAR` unset printed a TypeError backtrace; it now exits 1 with just its message.
- Attached context: a fetch no longer writes back a source removed while it ran; `chi context push` takes the
  source's lock and refuses a command source; a project source runs in the session's folder when the project root
  is a bare git dir.

Update with `chi update` and restart `chi web`: it installs the new `github-pr` bundle for the `dev` profile (dev
0.2.0) and updates guardrails (0.6.0: asks before `chi context add --cmd`, protects attached context) and loop-guard
(0.3.5: ignores `context_read`).

## [0.31.0] - 2026-10-06

### Added

- Delegate reports: a child started with `delegate` (`wait: false`) brings its reply to its parent by itself when
  it ends its turn, fails or asks the parent something. A parent mid-turn gets it at the next step; an idle parent
  runs a turn for it and tells its user, waking its worker when that had exited. The report carries the reply, so
  the model doesn't poll with `delegate_result`. The web shows a "delegate report" bubble, the attached terminal
  `delegate report> <child> answered: …`, and the bell rings when such a turn ends. A stopped or archived parent
  isn't woken: its reports join its next turn. New settings `session.delegate_reports` (`wake`, `queue`, `off`) and
  `session.max_wakes` (default 10 turns in a row with no human input; then reports wait for your next message).

### Changed

- The parent's record of which delegate replies its model already had is kept on disk (`delegates.json`), so a
  restarted worker no longer hands the model a reply again; `delegate_result` asked again about a question it
  already reported waits for its answer instead of repeating it.
- A delegated child does only what its task asks: a question gets a report with the change it would make, not
  file edits; it edits files only when the task asks for a change, and then only the files that takes.
- `task_get`, `task_stop` and `task_wait` say they take a task id (from `task_create` or `task_list`, with an example),
  not a session id: models passed session ids to them.

### Fixed

- A message sent while a reminder turn ran was lost when that reminder turn was the session worker's first turn
  (a fresh or restarted worker): the turn took the message and dropped it. It now joins the turn as steering does.
- `chi -p … --non-interactive` (and a fresh REPL session's first turn without a worker) could not use the `delegate`
  tool: the session was not saved until its turn ended, so the child failed with "Session not found". A fresh
  session is now saved before its first turn.
- `task_get`, `task_stop` and `task_wait` given a session id say so: `task not found: <id> (that is a session id; task
  ids come from task_create, and task_list lists them)`.
- `task_get`, `task_stop` and `task_wait` take only an id shaped like task_create's (`20261005093000-1a2b3c4d`): an id
  such as `../x` could read a `task.json` outside `tmp/tasks`. Anything else is `task not found`.
- `task_wait` for an unknown task said `Error: Error: task not found: …`; it now says it once.
- A corrupt Gemma 4 generation on a llama.cpp host (a tool call never closed, or a fresh thought header after the
  answer text) was saved as the answer, and a delegate report passed it on to the parent. A poisoned llama.cpp prompt
  cache produced one with another session's answer in it (ggml-org/llama.cpp#27148). chi now logs
  `generation_malformed`, shows `↻ malformed answer, asking again (1/1)` and asks once more without the prompt cache;
  a second corrupt generation fails the turn ("malformed generation from host …"). The half tool call never runs.
- On llama.cpp, a parent's turn-end warm-up no longer waits behind a delegate child generating on the same slot, and
  its next turn no longer waits behind that warm-up: the warm-up is skipped when `/slots` says the slot is busy.

Update with `chi update` and restart `chi web`.

## [0.30.0] - 2026-10-05

### Added

- chi saves the model ids each host last listed (`~/.local/state/samagotchi/model_lists.json`), so a command that
  starts a session without listing the hosts itself knows what they serve.
- `chi send --new --model` and the `delegate` tool's `model:` warn about a model id the named host's saved list
  doesn't have: `host 'box' doesn't list model 'gemma-smal' (did you mean: gemma-small?); started it anyway`, on
  stderr / in the tool's result. The session still starts: some hosts serve ids they don't list (a one-model
  llama.cpp server takes any name, OpenRouter's `:nitro`). A name that names no host, a host with no saved list, and
  a list over a week old are not checked.

### Changed

- Web: an open step whose label is its narration's first line or its first call's title shows only its call count,
  so it doesn't repeat the words its body starts with; closed, the label is unchanged.
- Web stage: an answered turn says its step count once (in the cloud's chip) and its time once (in the status row).
- Web stage: `execute` and the task tools are blue in the running-tool row and the ticks, as in the tool rows under
  them; purple is thinking's colour only (other tools' ticks are a quieter blue-grey).
- Web stage: `edit` and `write` are blue in the running-tool row and the ticks too, as in the tool rows; green is a
  finished call's `✓` and an answered turn's only.

### Fixed

- A command the user's Stop killed (or kept from starting) is saved as `stopped`, not `error`: the web shows it with
  ■ and `stopped`, and the turn's `(N failed)` and the session's tool errors no longer count it.
- Web: the stop-task confirm names a task from an earlier turn by its command (the wait row's title), not its id.
- Web: a canceled turn's end line (the Stop, Ctrl-C, a hook, the session's stop) reads `■ canceled (stopped)` in the
  stopped calls' amber, live and after a reload, not as a red error; a worker that exited mid-turn stays red `✕`.
- Web stage: a call the Stop cut has an amber tick and an amber `■` in the trail, as its `■ STOPPED` row, instead of
  its tool kind's colour.
- A call still running when its turn is canceled is saved in the session's tool records as `stopped` (was
  `canceled`), the word its row uses; one cut by a failed turn stays `canceled`.
- A canceled turn's last step keeps the thinking it streamed, so reloading it shows the thought instead of an empty
  step (both loops).
- A plain REPL (`--no-shared`) keeps its session's `pending_card.json` as a worker does, so `chi web` marks a session
  waiting on an open card it showed.
- source-links: a ref that names its own repo (`other/repo#12`) takes `{host}` from the git remote only when the
  source's `remote_host:` lists that host, so it can't link to the local checkout's host.
- Web stage: the running-tool row no longer reads `thinking…` once the turn has ended (answered, canceled or
  failed): it is idle, with no word.
- The REPL and attached mode end a canceled turn with an amber `■` (`■ turn canceled (Ctrl-C)`, `■ turn stopped by
  loop-guard`), as the web does, instead of `✕`: a stop someone chose, not an error; a failed turn keeps `✕`.
- Web stage: a call a guardrail blocked has a red tick and a red `✕` in the trail, as its `✕ BLOCKED` row, instead
  of its tool kind's colour.
- A command step with more than one heredoc (`-f body="$(cat <<EOF …)" -f title="$(cat <<EOF …)"`) cuts every body
  out of its text, and its chip says so: `EOF · 3 lines +1`, with all of them on hover.
- A session worker survives a failed save between turns too (its first prompt, a command, taken notes, a dropped
  question): it logs it and keeps going; notes whose save failed are kept and saved on the next pass.

Update with `chi update` (source-links 0.3.4, mcp 0.4.4) and restart `chi web`.

## [0.29.0] - 2026-10-05

### Added

- Web: a session card shows `looped` when loop-guard stopped its last turn (`stopped by <name>` for another hook),
  like `chi sessions list`'s `[looped]`; the all-sessions search finds them by those words.
- `chi bundle install` warns when a bundle needs a newer chi and its guardrail rules won't load (it already warned
  about its hooks and plugin).

### Changed

- Web: a tool row shows its status as a mark (✓, ✕, ■, a spinner while it runs) instead of the word, so its command,
  output and diff start right under the tool name; error, stopped and blocked calls keep their word after the title.
  An open step's body sits indented under its summary.
- Web: a step with a failed call says so in its collapsed label, `3 tool calls (1 failed)`, with a red chevron; the
  turn's summary counts failed calls below 3 calls too.
- Web: a `task_wait`, `task_get` or `task_stop` row names its task by the task's command instead of its id, a wait with
  how long it waits (`bundle exec rspec · up to 600s`), also for a task started in an earlier turn; the id line stays
  on hover.

### Fixed

- Guardrails: `> /tmp/x cat <<EOF` (a redirection written with a space before the command) is read as a heredoc of
  data like `cat > /tmp/x <<EOF`, and a `)` inside quotes or a heredoc body no longer ends a `$(…)` early.
- `!cmd` no longer hands a `--model` worker's model to a chi it runs as the default model.
- A session worker survives a failed save at the end of a turn (it logs it) instead of crashing.
- A turn that ends with an empty answer removes only its own retry note, not an earlier turn's cancel or failure note.
- Web: streamed chunks from llama.cpp no longer carry its whole echoed prompt to every web client.

## [0.28.0] - 2026-10-04

### Added

- Desktop: the panel's footer says where its text and images came from, "from clipboard" (the hotkey) or "from
  selection" (Send to chi); run `chi desktop upgrade`.
- `cache.ttl: 1h` keeps a Claude model's prompt-cache breakpoints for an hour instead of 5 minutes (a write costs 2×
  the input price instead of 1.25×; off by default), and `cache.key: session` sends the session id as
  `prompt_cache_key` to OpenAI's API and OpenRouter (off by default).
- `chi sessions list` marks a session whose last turn loop-guard stopped with `[looped]` (another hook:
  `[stopped by <name>]`); `--format json` carries `stopped_by`.

### Changed

- Past `image.max_per_request` images, the oldest are left out in batches of half the limit instead of one per new
  image, so the earlier conversation stays a cacheable prefix; the placeholder reads "an older image (chi sends up
  to the newest N)".
- After loop-guard cuts a runaway reply, chi's retry note tells the model to continue the task with its next tool
  call (or answer if it's done) instead of "answer briefly", which made models wrap up in the middle of a task.

### Fixed

- REPL: a line typed ahead during a turn no longer starts a turn-end warm-up that the next turn throws away.
- Web: when one of a task's stop buttons is clicked, the other one (the stage's step list) disables too.
- Desktop: `chi desktop install` starts the helper with a bare env, so `SAMAGOTCHI_*` settings (and anything else)
  from the install shell no longer stick to the helper and the chi it runs until a relaunch; run `chi desktop upgrade`.
- Desktop: ⌘⏎ on the panel's "New session" row says "A note needs a session" instead of only beeping, and the Note
  button is off on that row; run `chi desktop upgrade`.
- Desktop: the panel lists live sessions in the order they started, so ⌘1…⌘9 no longer shift when a session runs a
  turn (a new session comes last); run `chi desktop upgrade`.

Update with `chi update`, then `chi desktop upgrade` if you use the desktop helper.

## [0.27.0] - 2026-10-04

### Added

- Web: a "stop task" button on a running `task_wait` stops the background task; the turn goes on and the model is
  told the user stopped it (Cancel still cancels the turn and leaves the task running).

### Changed

- `/mcp` lists each server's tools alphabetically, not in the order the server sent them (mcp bundle 0.4.3).

### Fixed

- A stopped background task ends as `stopped`, not `failed`, and records who stopped it (the user or the model).
- Code blocks in the web follow the light theme too: their highlighting comes from the page's palette instead of one
  fixed dark theme.

Update with `chi update` (mcp 0.4.3).

## [0.26.0] - 2026-10-04

### Added

- The web has a light theme: with the system set to light it follows (`prefers-color-scheme`). There is no
  in-page switch yet. Native radios, inputs and scrollbars now follow the theme, so they are dark in dark mode.
- On a local llama.cpp host, the next turn starts faster: when a turn ends, chi sends the next turn's prompt (up to
  your next message) in the background, so the server has it ready while you read. `cache.warmup: off` turns it
  off; remote and paid hosts never get it.

### Changed

- `execute`'s `description` parameter now says it is shown to the user as the step's title and asks for it on
  every call (still optional), so models, Sonnet in particular, now label execute steps.
- loop-guard (bundle 0.3.4) words a loop its short run or its window found by the different sentences it held,
  `12 different sentences in 48`, instead of `12 sentences ×4`, which read as a cycle of 12.
- `sampling:` can't set llama.cpp's `id_slot` (pinning a session to a slot made the next turn re-read the whole
  prompt).

### Fixed

- `thinking_tails.jsonl` names the plugin that stopped a turn instead of "hook".

Update with `chi update` (loop-guard 0.3.4).

## [0.25.0] - 2026-10-04

### Added

- The web shows an `execute` command as the steps a person reads: `cd X &&` becomes an "in X" tag, `| head -20` a
  chip, `echo "=== x ==="` a label, a heredoc a collapsed "EOF · N lines" chip; the collapsed row's title is the
  first step `+N`. A `raw` toggle shows the whole command; anything the parser can't read shows as before.
- `execute` takes an optional `description` ("what the command does, in a few words"), written by the model; it
  becomes the tool row's title in the web and replaces the cut command in the terminal's tool line. Turn it off
  with `execute.description: false`.
- Every generation logs its prompt-cache counts (`prompt=`, `cached=`, `cache_write=`), and `/stats` shows cache
  writes next to cached tokens.
- A generation cut mid-thinking (loop-guard, a plugin's stop, a steer) or ended at the provider's output cap keeps
  the last 20k chars of its thinking in the session's folder, `thinking_tails.jsonl`, so an archived session holds
  the loop it was archived for. The model never sees it.
- Turn records count `cuts` (generations a plugin cut) and `capped` (generations that hit the output cap), and
  `/stats` shows them as "thinking cuts" and "output cap hits": `retries` counts network retries only.

### Changed

- On macOS, `execute`, `task_create` and `!cmd` run commands in `/bin/zsh` emulating sh (with bash's `{1..3}`,
  `[[ =~ ]]` groups and echo escapes kept) instead of `/bin/sh`, which is bash 3.2 there and failed on an apostrophe
  in a heredoc inside `"$( )"`: `git commit -m "$(cat <<'EOF' … it's … EOF )"` now works. Linux keeps
  `/bin/sh`; see [background tasks](docs/internals/background-tasks.md).
- loop-guard's cut notice (bundle 0.3.3) quotes the looping sentence: `thinking repeats itself ("Let me write the
  tool call.", one sentence ×8, 33k chars, 63 s): cut`.
- The system prompt puts what every session shares first and the per-session lines (model, working directory,
  session) last, and plugin tools come in a fixed order, so a new session reuses the server's prompt cache: on a
  local llama.cpp or Splash server its first answer starts in about 0.5 s instead of 4–6 s, and on Claude via
  OpenRouter a new session reads the shared part from the cache (about 7× cheaper to start).
- Chat hosts (`api: openai`) are no longer asked for `temperature: 0.0`: chi sends no temperature unless one is
  configured, so each model runs at its provider's default (as native llama.cpp hosts already did). Greedy decoding
  made DeepSeek v4.1-flash loop in its thinking. The idle recap and `/btw` follow suit. Set `sampling: {temperature:
  …}` on a `hosts:` or `models:` entry to pin one; the empty-answer retry still runs at 0.6 unless one is set.

### Fixed

- loop-guard (bundle 0.3.3) cuts thinking that loops in a cycle of 7 or 8 short sentences, or with a longer
  sentence ("I'll write the spec file now.") in the cycle: 48 sentences in a row with 12 or fewer different ones are
  a loop. New settings `thinking.window_sentences` (48) and `thinking.window_distinct` (12).
- A steer row names chi's senders in words: the web's row and trail flash and the terminal's nudged line say
  `parent agent`, `chi send` and `plugin` instead of the raw `parent_agent` / `chi_send` / `plugin_send`.
- Thinking off on Gemma 4 no longer warns that off wasn't honoured: its empty thought (whitespace alone) is not
  counted as thinking.
- An OpenRouter 402 whose `metadata.reason` is `weight_exceeds_budget` (the request alone is larger than the
  key's credit budget) fails at once as `request too large for the credit budget on host <name>: …; lower
  max_tokens (default.max_tokens) or raise the key's credit limit`, instead of being retried as credit held by
  in-flight requests. Other 402s are unchanged.

Update with `chi update`: loop-guard moves to 0.3.3 (the window rule and the quoted cut notice). Restart `chi web`
and running sessions afterwards (`chi sessions restart ID`).

## [0.24.0] - 2026-10-04

### Added

- `steer.cut_after` (default 20 s, `0` = never): a message for a running turn from you, `chi send` or a parent
  agent cuts a generation that has streamed only thinking for that long (counted from its first thinking token;
  a message that came earlier cuts once the thinking gets there).
  The model starts the step again with the message, and a `↪ cut in for your message` row marks it. Plugins'
  steers never cut. Only the cut thinking is lost (llama.cpp re-reads the few tokens after its cached prompt).

### Changed

- The web shows an `execute` / `task_create` call's full command: an expanded tool row has it as a block above the
  output (whitespace kept, a copy button, `in <cwd>` when the call gave one), and the row's and the stage's hovers
  show the whole command instead of the 80-character `command="…"` line. The terminal is unchanged.
- A message that joins a running turn (a line typed in the terminal or the web, `chi send -m`, a delegate's
  follow-up, `chi answer --option Continue --text`, a plugin's `ctx.steer`) reaches the model with a one-line
  header naming its sender and asking it to follow the message, or carry on if it asks for nothing, so the model
  can tell who is steering it. Sessions keep the raw text.
- The `generation_stopped` log line names who cut the generation as `by=` (was `bundle=`), as a message can cut
  it now too.

### Fixed

- Guardrails read heredocs (`cat <<'EOF' … EOF`): a heredoc's body no longer asks needlessly (an `rm -rf` or
  `git push` written into a file by `cat`/`tee`), and an apostrophe in a body no longer hides the commands after it
  from the strict-mode check for git outside the repo. A body fed to `bash`, `sh` and the like still counts.
- A `chi send -m` or delegate follow-up merged into a running turn is saved with its sender (`source: chi_send` /
  `parent_agent`) instead of reading as the user's own words.
- The idle recap keeps the text of a `chi answer --option Continue --text` (or a continue card answered with
  text); it was dropped as a plugin's prod.
- check-in no longer says a nudge was not sent when a user line was merged after it (bundle check-in 0.2.3).
- A plugin's cut of a generation (loop-guard) with a message or a plugin's steer waiting now delivers it even after
  `retry.empty_answer`'s budget is spent; the turn used to end cancelled and drop a waiting plugin steer.

Update with `chi update`: check-in moves to 0.2.3 (the nudge-not-sent fix). Restart `chi web` and running sessions
afterwards (`chi sessions restart ID`).

## [0.23.0] - 2026-10-04

### Changed

- chi no longer strips the blank lines Splash before 1.2.0 put at the start of an answer (incoai/splash#254, fixed
  in Splash 1.2.0): upgrade Splash with `brew upgrade incoai/tap/splash`.
- Requests to OpenRouter send `max_tokens: 32768` (a request's own limit, as a recap's, still wins). OpenRouter
  holds each running request's estimated cost against the balance, counting the output `max_tokens` allows (a
  fixed per-request cap without one), so concurrent requests hit "would exceed your available credits given your
  current in-flight requests" (402) sooner without a limit. `default.max_tokens` raises or lowers that limit.
- `default.n_predict` is renamed `default.max_tokens` (env `SAMAGOTCHI_DEFAULT_MAX_TOKENS`, flag
  `--default-max-tokens`), with no alias: an old `n_predict:` in config.yml warns as an unknown key. It now
  limits chat turns on OpenAI-compatible hosts too, sent as `max_tokens` on any host; it was used only by native
  hosts (where it is still sent as llama.cpp's `n_predict`).

### Fixed

- A Ctrl-C (or SIGTERM) while chi loads bundle hooks and plugins stops chi again; before, it was logged as a
  failed hook and chi carried on. A hook's or plugin's own error, `exit` or syntax error is still only reported.
- A continue turn that fails before it begins (its session save, say) asks the step-limit question again
  instead of crashing the session's worker.
- Native Gemma 4 prompts follow Gemma 4's chat template: turns end with `<turn|>` (not Gemma 3's
  `<end_of_turn>`, which Gemma 4 reads as plain text), so the stop sequence matches; tool results stay
  inside the model's turn as `response:NAME{value:…}` blocks, one per call; tools are declared in the
  template's compact form at the end of the system turn; an answer's thought is dropped once the next
  user turn starts; and thinking off prefills Gemma's empty thought channel.

Update with `chi update`: btw 0.1.2, check-in 0.2.2, known-names 0.1.5, loop-guard 0.3.2, mcp 0.4.2, skills 0.1.6 and
source-links 0.3.3 move (code style only, no behaviour change). If your config.yml has `default: n_predict:`, rename it
to `max_tokens:`. Restart `chi web` and running sessions afterwards (`chi sessions restart ID`).

## [0.22.0] - 2026-10-04

### Added

- Claude models on OpenAI-compatible hosts (OpenRouter) use Anthropic's prompt cache: chat requests mark the
  system message and the last message with `cache_control`, so each step reads the earlier prompt from the
  cache (about a tenth of the price) instead of paying for all of it again. The log line shows `cache=on`.

### Changed

- An HTTP 402 is no longer a "rejected the request" bad request. OpenRouter's "would exceed your available
  credits given your current in-flight requests" (credit reserved by another running request) is retried like a
  429, 20s apart (about 100s with the default `retry.max`), instead of failing the turn at once; any other 402
  fails as `out of credits on host <name>: …; add credits, then send again`, with `error_kind` `credits`.
- `chi answer --option Continue --text "…"` is accepted: the text joins the continued turn as a steer (marked as the parent agent's for `chi answer`), instead of being refused.
- The Continue answer's text keeps its line breaks in the continued turn's steer, and it is dropped (logged
  `steer_dropped why=not_begun`) when the continue turn fails before it begins or a typed `/continue no` answered
  the offer first, instead of joining whatever turn ran next.
- `chi answer --format json` says `"answered_here": false` when the question was no longer open (answered
  elsewhere, or another one waits now): it still waits for what comes next, but the JSON no longer reads as if
  the given answer went in.
- `chi send --wait` and `chi answer` with `--format json` say why a turn stopped: a failed turn adds `error_kind`
  (the provider error's kind, e.g. `credits`, `server`) and `retryable`, a canceled one `cancel_reason` (`user`,
  `hook`, `ctrl_c`, `manual`) and `stopped_by` (the hook, e.g. `loop-guard`), when known. The session's
  `last_turn` records them.

Update with `chi update` (no bundle versions moved). Restart `chi web` and running sessions afterwards (`chi sessions restart ID`).

## [0.21.0] - 2026-10-04

### Added

- The debug log's generation_completed line names the OpenRouter provider that served it (provider=).

### Fixed

- loop-guard cuts thinking that loops in short sentences ("I'll write it. Go. OK. Writing."),
  which it skipped before: such a loop ran for minutes to the provider's output cap. New settings
  `thinking.short_run` (24) and `thinking.short_distinct` (6).
- loop-guard's thinking watch no longer goes blind for the rest of a generation after an empty thinking
  chunk (a FrozenError, logged as `plugin_hook_failed`), so it now sees every generation's thinking.
- loop-guard no longer stops a whole turn for a thinking loop that comes long after the model recovered from
  its first one: after `thinking.forget_after` (10) steps with no loop, the next loop is cut and retried again.
- A turn a plugin stopped now says who did it, `✕ turn stopped by loop-guard` (the web: `✕ stopped by
  loop-guard`), instead of `✕ canceled (by a hook)`, also after a reload of the web page.
- An attached `/exit` the worker reads only after the TUI stopped waiting (a frozen or sleeping worker) no
  longer stops it later: the request is dropped, as late turns and commands are.
- The attached `/exit` (and `/exit --delete`, `/archive`) in an empty session no longer claims the session is
  already gone: a note arriving before the worker stops keeps it, so it says it will be discarded if nothing
  arrives.
- Archiving a session (`/archive`, `chi sessions archive`, the web) with a prompt still queued or a step-limit
  question open is refused with a message saying so, instead of stopping the worker and leaving the queued
  prompt to run on the next resume.
- `/exit` right after a `/detach` and `chi --attach` no longer says "another UI is attached" and leaves the worker
  up: the worker notices a closed stream at once instead of at its next 15-second heartbeat.
- Leaving chi's terminal UI (`/exit`, `/detach`, Ctrl-D) no longer can leave a stray cursor report such as
  `^[[12;1R` at the shell prompt: input nobody read is dropped before the terminal is handed back.
- Joining a running turn (web or `chi --attach`) while the model is holding before its first token now shows
  the step it's on, as a live view does, instead of the previous step still live.
- Web: sending into a session whose worker was already up (but the page didn't know) no longer draws
  that worker's earlier turns a second time: the page re-reads the session instead.
- Web without the session events stream (fetched list): a re-fetched list now badges and notifies like the
  live list does.
- Web: a session deleted while the page had lost the session events stream (or between two fetches of the
  list) no longer keeps its question or card counted in the tab title's badge until the tab comes to front.
- Web on a phone: the session footer's archive, stop and delete buttons are icons (the words stay as their
  accessible names and tooltips), so the status and `mem N` chips beside them are in sight again.
- Web: with several chi tabs in the background, a session that needs you shows one OS notification, not one
  per tab (every tab still counts it in its title).
- chi web: a session stream whose worker took the connection and froze before answering no longer holds the
  request forever; it gives up after 5 s per attempt.

Update with `chi update`: loop-guard moves to 0.3.1 (short-sentence loops, forget_after, the blind-watch fix). Restart `chi web` and running sessions afterwards (`chi sessions restart ID`).

## [0.20.0] - 2026-10-03

### Added

- `guardrails.mode` (config.yml only): `auto`, the new default, or `strict`. Rules can be tagged `modes: [strict]`
  to vote only in strict mode; a rule without `modes:` (every rule you wrote in config.yml) votes in both.
  `/guardrails` shows the mode and marks the rules it leaves out `(strict only)`. See docs/guardrails.md#modes.
- New guardrail rule keys: `skip_read_only: true` (a shell command that only reads, such as `ls`, `cat`, `rg`,
  `sed -n` or `git log`, doesn't match), `touches: chi_dirs` (a shell command names a path in chi's real config,
  hooks, approvals or bundles dir, or a `.git/hooks`) and `rm: outside_tmp` (an `rm -rf` reaches outside the tmp
  dirs). A config.yml rule that uses one fails closed on an older chi.
- Model speed and token stats. `/stats` has a speed line (the last generation's decode speed and the
  session's average: exact from llama.cpp, estimated and marked `~` elsewhere), cached and reasoning
  tokens, and the cost when the provider reports it (OpenRouter). The web's info bar shows the speed
  next to `ctx`, updated after each generation, and the `ctx` tooltip there and on session cards lists
  tokens in / cached / out (+ reasoning) and the cost, for that session only.

### Changed

- [BEHAVIOUR] Guardrails ask less by default (auto mode). The guardrails bundle (0.5.0) no longer asks before
  `git rebase`, writes outside the session's repo (`write-outside-repo`) or git in another checkout
  (`git-outside-repo`); `guardrails: { mode: strict }` in config.yml brings those back. Everything else still asks
  in both modes, as do the small-model rules and chi's own protected paths.
- [BEHAVIOUR] `shell-touches-chi` matches chi's real folders instead of text, and lets read-only commands through:
  `ls ~/.config/samagotchi`, `rg samagotchi/hooks lib` and a scratch copy under `/tmp` no longer ask; `echo x >>
  <config dir>/config.yml` and `cp hook .git/hooks/pre-commit` still do. A word it can't resolve falls back to the
  old text match.
- [BEHAVIOUR] `rm-rf-wide` no longer asks when every `rm -rf` target is inside a tmp dir (`rm -rf /tmp/x`);
  `/tmp` itself, `/tmp/*`, a `$VAR` and a link out of tmp still ask.
- [BEHAVIOUR] "Allow … in this repo" approvals hold for the whole repository, in every worktree of it, and the
  ask names the repository (`in this repo (samagotchi)`) instead of the worktree folder. Approvals stored
  before keep matching their exact folder.
- `chi bundle status` shows a bundle whose recorded scope this chi doesn't know (one a newer chi wrote, or a hand
  edit) as `scope=team (unknown)`, counted as one issue, instead of checking its files in the system memories;
  the shipped-bundle update skips it (upgrade chi or reinstall), and `chi bundle diff` refuses it with a one-line
  error instead of a stack trace.
- The web model picker shows a model's configured sampling (`temperature=0.6 (hosts.work)`) as its row's tooltip;
  `GET /api/models` has it as `sampling` on the models that have some.
- The web shows a plugin card that is only a notice (info level, no buttons, one short line, such as check-in's
  "Nudged the model at 105 tool calls.") as a one-line row, `▸ check-in: Nudged …`, that opens on a click, like the
  tool rows and resolved questions; warn cards, cards with buttons and longer ones stay framed cards.
- On a phone (a window under 900 px wide) the sessions strip's `hide` is in the top bar, where the `▾ N sessions`
  pill comes back, with a finger-sized target, instead of the last column of the sideways-scrolling strip.
- On a phone the web info bar shows `mem N` (the memories the session used; their names in the tooltip) after the
  session's status, since the `mem: …` line is hidden there.
- The web info bar's chips (model, ctx, speed, session time) are tinted over the card's glass instead of solid, and
  the empty-history cover is see-through like the session panel.

### Fixed

- An MCP server that exits without a wait status no longer raises `NoMethodError`; its waiting calls fail with
  "the server exited" instead of hanging.
- A hook that raises is now logged (`hook_failed`) instead of being swallowed silently; the turn still goes on.
- A hook's card (check-in, skills) now prints under its tool call's row: `tool_call_completed` is emitted before
  `after_tool_call` fires.
- When a hook corrects a tool call (known-names), the model is told what actually ran with a leading
  `ran as: <tool> <args>` line.
- MCP image content is described with a neutral `[image N: …]` line instead of claiming it was attached, which
  was wrong for a model that can't see images.
- An MCP `resource` block carrying an image `blob` is now attached like an `image` block instead of being
  dropped to its URI text.
- check-in's `nudge` mode no longer says "nudged" when the steer was dropped later; it says "nudge not sent" at
  the turn's end.
- A session started with an annotation (a web quote) is previewed by the note typed under the quote, not
  `From your thinking: > …`; a quote with no note previews by its words.
- A session that has only context notes so far (`chi note`, `send_note`) is previewed on its card and in the
  lists as `note: …` instead of `—`, until a message is typed.
- A web turn of images alone names each image once in the transcript a recap is written from, not twice.
- `chi bootstrap` no longer says "loading the model?" for a slow test on a remote provider (OpenRouter and the
  like); the hint is for a local server, where a slow answer is a model loading.
- `chi bootstrap` says why it saved a host as `name-2` when the derived name is already taken (or a model id
  starts with it), instead of silently picking another name.
- `chi bundle upgrade` reports a hook or plugin file that is byte-identical to the installed one as "already up
  to date" instead of "Updated".
- `chi bundle upgrade --agent` from a git/zip/tar source no longer hands the agent an `incoming:` path that was
  already deleted: the extracted source is kept until the agent step is done, then cleaned up.
- `chi self` now checks a local `api: openai` host's reachability (a `GET <base>/models` with the same short
  probe timeouts) and reports up/down with the ids it serves, instead of always saying "reported per turn".

Update with `chi update`: guardrails moves to 0.5.0 (auto mode and the new rule keys; it needs chi 0.20.0), mcp to 0.4.1 (exit status, image lines, image blobs) and check-in to 0.2.1 (a dropped nudge says so). Restart `chi web` and running sessions afterwards (`chi sessions restart ID`).

## [0.19.0] - 2026-10-03

### Changed

- A new or woken session worker runs the newest chi installed, whoever starts it: a `chi web`, `chi send` or
  terminal left on an older chi no longer starts workers on its own version. A worker already running keeps its
  version until it is restarted.

### Added

- `chi web` notices a newer chi installed (`chi update`, `gem update`, a `git pull` in a checkout) and says to
  restart it, in its terminal and once in each open page.
- The web's info bar marks a session whose worker runs an older chi than the newest installed, with a Restart button
  (or, for a worker from before restarts, the `chi sessions stop ID` to run); the page and the draft in the
  composer stay as they are and follow the new worker.
- An attached terminal says in one line when the session's worker or the terminal itself runs an older chi than
  the newest installed, and how to move each (`chi sessions restart ID`; `/detach`, then `chi --attach ID`). When
  the worker restarts, the terminal stays attached and says so.
- `chi sessions restart ID...` moves a running session to a new worker on the newest chi installed, keeping its
  attached terminal and web tabs on it; it is refused, with the reason, while a turn, a question, reminders or
  background tasks would be lost.
- A bundle can ship per-model memory overlays (`tips.<model-key>.md` beside `tips.md`): they load only for that
  model, as a `memory_write current_model_only` overlay does, and `chi bundle build tips.md` brings them along.

### Fixed

- `chi update` no longer says running sessions move to the new chi "at idle exit (30 min)": a worker keeps its chi
  until restarted, and idles out only with nothing attached, after `session.idle_exit_minutes` (never with 0). The
  workers row names `chi sessions restart ID` (or `stop` for a worker from before restarts).
- `chi web` no longer leaves exited session workers behind as zombie processes.
- The web's model picker lists a host added to (or changed in) `hosts:` while `chi web` runs, instead of the hosts
  it started with.
- A bundle's model overlay no longer gets an `index.md` line of its own after `chi bundle install`, which showed it
  to every model as a memory to read; `chi bundle status` reads it `ok (model overlay)`, uninstall no longer re-adds
  its line, and an overlay whose base is nowhere, or only among your installed memories, installs with a warning. A
  line an earlier install wrote goes with the bundle's next upgrade.
- source-links (0.3.2): a `case_insensitive: true` source no longer lists a ref in its `sources:` note when the ref
  is a markdown link's label whose target names it in another case (`[jira-1](…/JIRA-1)`). Run `chi update` to get it.
- An `@path` image in a prompt takes backslash escapes, as a Finder drag into the terminal types them:
  `@my\ shot.png` and `@a\ \(1\).png` attach the file instead of stopping at the first space.
- An `http` host named by a public name (`gpu.example.com`) counts as a remote provider (120-second first-token
  limit, no llama.cpp `/props`), as a public IP address already did. Names without a dot and local suffixes
  (`.local`, `.lan`, `.home.arpa`, `.internal`, `.ts.net`, `fritz.box`, …) stay local; `hosts.<name>.remote` decides
  either way.
- `chi web` no longer logs `ERROR HTTPRequest#fixup: WEBrick::HTTPStatus::LengthRequired occurred.` after a POST
  without a body.
- The web's delete confirm no longer promises a running worker from a stale list: it says the worker is stopped
  first if it is still running.
- The web's scope links (`all`, `← project`) keep the page's `?view=stage|turn`.
- An approval card's verdict (`Allowed (scope)` / `Denied`) reads above the command it decided, so it no longer
  looks like part of the tool call when the card's details are expanded.
- Answering or dismissing a question no longer says "Session is not running" when the worker is live but failed the
  request: the server answers 502 with the worker's detail and the card shows it. 503 stays for a session with no
  live worker.
- A turn that failed to send no longer leaves its prompt waiting to be restored into the composer later; and text
  typed while a fast-failed turn's prompt was coming back is kept, with the restored prompt going under it.
- A worker that dies between a turn's end and its after-turn display no longer leaves the turn's answer bubble
  waiting: the page stops waiting when the worker goes away, or after 20 s.
- A first web message the page answers itself (`/stats`, `/exit` …) or that is a typo of a command (`/modle`) no
  longer leaves an empty session behind.
- A question card reopened after a reload shows its result once, in the collapsed summary, not twice.
- After a mid-turn reload, this tab's own prompt is still recognized as its own instead of being labelled `web`.
- A `chi scratch` session no longer offers `send_note`, so it leaves no note behind in another session.
- A `chi scratch` session's tool approvals offer only "Allow once" and "for the session", and keep a session
  approval in memory: no "in this repo" or rule approval from it stays in the approvals store.
- A message sent (web, `chi send`, a delegate) to a session whose worker is slow to start no longer starts a second
  worker beside it.
- The note a cancelled turn leaves for the model says "the reply above ends where it was cut off", not "the
  answer", so narration cut off before a tool call isn't taken for an answer.
- A session worker that wakes again shows the model the server last said it served (`/stats`, the status row,
  the web's info bar) right away, instead of none until its first generation.
- A tool call still running when its turn is cancelled (or fails) is saved in the session's analytics as
  `canceled`, so the session's tool totals (`/stats`) count it as the turn did instead of dropping it.
- A session's `analytics.json` `session_duration_ms` runs from the session's `started_at`, not from when its current
  worker started.
- A session started with `chi --model X` no longer hands X to the commands it runs as the default model: a `chi
  self` (or other chi) run there reports and uses the configured default, with X as this session's model. A
  `SAMAGOTCHI_DEFAULT_MODEL` you export yourself still passes.
- A preloaded memory that can't be loaded is warned about once, not again each time the prompt is rebuilt (another
  thinking level, a `/model` switch).

Update with `chi update`: source-links moves to 0.3.2 (case-insensitive link targets). Restart `chi web` afterwards; from now on it tells you when a newer chi is installed.

## [0.18.1] - 2026-10-03

### Fixed

- The `execute` tool no longer hangs when a command leaves a process in the background (`server &`, or
  `cd DIR && nohup server > log 2>&1 &`) that keeps its output open: after a short grace it stops that process and
  returns the output, with a note to start servers and long jobs with `task_create`. Stop and
  `execute.timeout_sec` work during the wait too.
- A running session no longer denies every tool call after an installed bundle's rules are upgraded to a version
  that needs a newer chi (`requires_chi`): it keeps the rules it loaded before and says once to restart the session
  (`chi sessions stop ID`, then `chi --resume ID`).
- `chi -p … --non-interactive` keeps stdout for the answer alone: the `Session:` (or `Resumed session:`) line goes
  to stderr, before the turn. A failed turn now says after its error that the session is kept with the prompt and
  how to continue it (`chi --resume ID`).
- Ctrl-C in `chi -p … --non-interactive` keeps the session: the prompt and a cancel note are saved, so
  `chi --resume ID` has them, and stderr says so instead of a Ruby backtrace. The exit status stays 130.
- `chi -p` shows the after_turn hooks' notices (source-links' `sources:`, any notifier), which it lost: with
  `--non-interactive` on stderr after the answer; attached (input from a pipe) it waits for them and shows them
  before it detaches.
- `chi -p … --non-interactive` prints the retry lines on stderr (`↻ empty answer, asking again (1/1)`, `retrying
  (1/5 in 0.5s): …`), as the REPL shows them, instead of nothing.
- A native llama.cpp turn sends `GET /props` once, not twice.
- After a failed `/props` probe, a server that then answers is probed again at the next turn, instead of the
  failure being reused for 30 s.
- A request to a model server is sent only as many times as chi's own retries say: Ruby's hidden extra retry is off.
- The served-model notice no longer treats `gpt-4` and `gpt-4o` as the same model: a served name counts as the
  asked one only when what follows starts with `:`, `-`, `@` or `/` (`qwen3` = `qwen3:latest`).
- A Gemma thought channel (`<|channel>thought` … `<channel|>`) is stripped as a whole block, so the model's
  reasoning no longer shows up in the answer.
- An unknown model profile name falls back to `qwen36`, the same default as everywhere else, instead of `gemma4`.

Update with `gem update samagotchi` (or `chi update`); no bundle changed.

## [0.18.0] - 2026-10-03

### Added

- The guardrails bundle (0.4.0) asks before git that changes another checkout: `cd ../main && git commit`,
  `git -C ../main add .`, an `execute` with `cwd:` there (commit, add, reset, checkout, switch, rebase, merge, push,
  stash, rm, mv, cherry-pick, revert, pull, restore, am). Read-only git and tests there still run unasked. Its card
  offers once, this session, or "rule in this repo" (stored, so later sessions there don't ask); switch it off with
  `guardrails.disable: [git-outside-repo]`. Run `chi update` (or `chi bundle upgrade guardrails`) to get it.
- Web: a tab left open across a `chi web` upgrade says so: when its event stream reconnects to a newer chi, a toast
  `chi was updated to X` offers a Reload button (it never reloads by itself; ✕ dismisses it).
- `chi bundle trash` lists the bundle trash (moved files from uninstalls/upgrades) oldest first, with file count,
  size, and age; `--empty` deletes all folders, `--older-than DAYS` keeps only recent ones, `--dry-run` previews.
- A turn that runs out of iterations now waits as a question (kind `continue`, the step-limit question):
  `chi send --wait` exits 3 with it, `chi answer --option Continue|Stop` answers it, and the web badge and bell show
  it. The web draws it as a card with Continue, Stop and a reason for Stop; `chi --attach` reads the continue words
  at its prompt (Enter continues). A parent agent may Continue unless `turn.parent_continue: false` (config.yml only);
  a delegate's goes back to the parent model.
- `turn.max_iterations` (default 100, env `SAMAGOTCHI_TURN_MAX_ITERATIONS`) sets the per-turn step limit;
  `--no-interrupt` turns get the larger of 1000 and it.

### Changed

- `write-outside-repo` and any `path: outside_repo` rule measure from the session's repo (not a plugin call's own
  `cwd:`), with symlinks resolved: `/tmp/x` and `/private/tmp/x` are the same
  folder, and a link in the repo that points elsewhere counts as outside. Writes into tmp folders (`$TMPDIR`, `/tmp`)
  no longer ask, unless the session itself lives there. Hook events' `targets` gain `git_dirs`.
- A one-word `/word` that no command answers (`/modle`) is no longer sent to the model as a prompt: every UI
  (the REPL, the attached TUI, the web composer) prints `Unknown command /modle. Did you mean /model? /help lists
  the commands.` instead, with the "Did you mean" part only when a command name is close. Lines that are prompts
  (`/foo bar`, `/usr/bin/env is missing`) still go to the model.
- `chi send --wait` reports `limit` instead of `no_answer` when a turn ran out of iterations and nobody can answer
  (an older worker), with how to continue it.
- Stop at the step limit (`/continue no`) keeps the turn's work, with a note for the model, instead of erasing the
  prompt and everything the turn did; `!rollback` still erases it. Reminder turns follow `turn.max_iterations`.
- The web page's end-of-turn and card re-reads fetch only what they show: the session's state, the last answer,
  that turn's timings and the cards, from a new light worker read (`GET /session/:id/tail`) instead of the
  whole conversation and timing history, so they stay the same size however long the session runs.
- `execute` gives a command 120 s by default (was 30 s) before it is killed; `execute.timeout_sec` /
  `SAMAGOTCHI_EXECUTE_TIMEOUT_SEC` still set it.
- An `execute` command killed at its time limit says how to run a long one: a second line
  `(killed at the limit; for a long command use task_create, then task_wait)` follows `Error: command timed out after Ns`.
- `read` with only `end_line` reads from line 1 instead of failing with "start_line must be provided". A range
  `edit` with only `end_line` still refuses (it would overwrite the top of the file) and now says what to pass:
  `pass start_line too (1-based, the first line to replace)`.
- In a worktree or subfolder, the system prompt's "Project root" line now says it is only where shared project
  memories come from, and to read, edit, run and commit in the current working directory; a model took the root for
  its workspace and committed to the main checkout.

### Fixed

- Web: a session waiting on a plugin card (check-in's Nudge / Keep going / Stop) shows its "needs you" badge as a
  pill on its session card again; it was drawn as a large empty circle over the card.
- Web: with a prompt queued behind a turn, the next turn's live timing line no longer freezes or takes the
  previous turn's number when the previous turn's re-read lands late.
- `chi sessions list` shows the first message of a session that has no turn yet, such as one started with
  `chi send --new -m "/model x"` or from the web start page; its row was blank.
- Web: a terminal-only command (`/stats`, `/exit`, `/recap` …) typed as the start page's first message is answered on
  the start page; it no longer starts a session just to show that reply.

Update with `chi update`: the guardrails bundle moves to 0.4.0 (the `git-outside-repo` rule; it needs chi 0.18.0).

## [0.17.0] - 2026-10-03

### Added

- The system prompt names the model the session runs on: `Model: this session runs on box:gemma-small (host box,
  box.test:8080; model key gemma-small).`, plus a line to answer "which model are you" from it, not from training
  (a fine-tune often knows only its base model's name), and that model-only guidance goes in
  `memory_write current_model_only: true` overlays. A local llama.cpp host whose `/props` names another model adds
  `; the server says it serves <name>`. The line changes only with `/model`.
- `execute` and `task_create` export `SAMAGOTCHI_SESSION_MODEL`, the session's model ref (it follows `/model`; the
  model's `env` can't set it).
- Plugins: `ctx.model` (the session's model ref, right after `/model` too) and `ctx.model_key` (its memory overlay
  key).
- `chi self` has a `model key` row: the memory overlay key of the model it reports.

### Changed

- `chi self` run by a session's `execute` reports **that session's** model, and its host, loop, profile, thinking and
  served model: `model  splash:… (this session abcd1234; default main:…)`. Before, it showed the config default
  (or the `--model` the worker started with), wrong after `/model`, for web-picker and `chi send --new --model`
  sessions and delegate children. Elsewhere the row reads `main:… (default)`. `chi self --model` is still the default.
- The identity memory and the preloaded memories (`--memory`, config `memories:`) get their model overlays
  (`<name>.<key>.md`) in the system prompt, as `memory_read` gives them.
- A session's live state (what the web and an attached terminal read from its worker) no longer carries every turn's
  and tool call's timing record, only the newest turn's: reads stay the same size however long the session runs. The
  full history stays in the session's `analytics.json`.
- A memory a bundle installed says so in its `index.md` line, and so in the prompt's memory index:
  `- **memory_guide** · system · 2026-10-03 · 5120 · from samagotchi-system — …`. `memory_write` and `write`/`edit`
  keep the tag; a same-name memory the install skipped gets none. Bundles installed earlier get it on their next
  install or upgrade (the system bundle: with the next chi version).
- `chi bundle uninstall` (and an upgrade dropping a file the new version no longer ships) moves the bundle's memory
  files to `<memories>/.bundles/.trash/<bundle>-<time>/` instead of deleting them, and says where:
  `Moved to the trash: notes.md (…/.trash/notes-bundle-20261003-120000)`. Nothing empties the trash; delete it by hand.
- `chi bundle build` leaves out the memories an installed bundle owns (the system bundle's `identity.md`, a shipped
  bundle's memory), one line each: `Left out identity.md: installed by bundle samagotchi-system (name it to include
  it)`; naming a file in `FILES...` includes it. It now prints the builder's warnings.
- An `index.md` line a bundle install, upgrade or uninstall couldn't write or remove is now a warning
  (`index.md: line for notes not updated (…)`) instead of passing silently; `chi bundle uninstall` of a profile
  prints its bundles' warnings too.
- Web: a composer line is a command only when it names one of the session's commands (or is `!…`); an unknown
  `/word` (a path like `/usr/bin/env …`, a typo) goes to the model as a prompt, as in a terminal, instead of being
  refused with `not a session command`.
- Web: a window under 700 px tall hides the latest-sessions strip by itself (the `▾ N sessions` pill shows it again
  until the window is tall), so a question or approval card in the turn's stage has room for its choices and
  buttons. Taller windows and phones are unchanged.

### Fixed

- `chi self`'s `served model` row for a chat host (`api: openai`), or a server without `/props`, says
  `reported per turn (the server has no /props)`; it said `unknown (no answer from the server's /props)`, which a
  model took to mean the server never said what it served.
- `chi bundle uninstall` no longer deletes a memory the user had before the install. A bundle now records (and
  so upgrades and removes) only the files it wrote; a same-name file that was already there is reported
  `Skipped` and stays the user's, on install, re-install and upgrade. Before, it was recorded with the user's
  content as its base, so uninstall removed it without `--force`: a third-party bundle shipping `notes.md`, or
  `chi bundle build` then installing the result on the same machine. An upgrade no longer reports such a file as
  a conflict (or `chi update --dry-run` as kept). Bundles installed before this fix may still list such a file;
  uninstall now moves it to the trash (below) rather than deleting it.
- A memory file two installed bundles list (one an older install adopted, like `identity.md` under both
  `samagotchi-system` and a `chi bundle build` of your memories) stays when one of them is uninstalled, or drops it
  in an upgrade: `Kept identity.md: bundle samagotchi-system has it too`. It goes with the last one.
- Web: after a reload, a turn with an empty retry mid-turn shows each tool row's own duration; the rows took their
  records by iteration, so every call after the retry showed the wrong one, or none.
- Attached TUI: `/detach` typed at a question's `?` prompt detaches (the question stays open), as Ctrl-D does; it
  was read as an answer and refused as an unknown option.
- Attached TUI: joining a turn while a tool call runs (a long `delegate`, a slow command), its row's duration counts
  from the call's start, not from the join.
- Web: in a short window a question or approval card that opens in the turn's stage is scrolled into view (its
  choices and buttons); it sat below the prompt and headline, out of sight.
- A session command sent as a message runs as the command, as typed in a terminal: `chi send -m "/model x" ID`,
  `chi send --new -m "/model x"`, `chi -p "/model x"` (attached and `--non-interactive`) and the web start page's
  first message went to the model as a prompt. `chi send` says `sent as a session command`; with `--wait` there is
  no reply to wait for (exit 0, `--format json` status `command`). An unknown `/word` still goes to the model.
- macOS 26: a dead worker's leftover `bridge.json` no longer counts as a live worker. Ruby's `Socket.tcp` with a
  connect timeout returns the socket of a refused connect there, so the check said live: clients tried its port
  first, `chi update` listed the dead worker as running, and an approval relay kept watching a parent that was gone.
- REPL with piped input: when the input ends at a question or approval, no bare `? ` line is left above its
  `(denied)` / `(cancelled)` summary.
- Web: an approval from a delegate its parent isn't waiting on directly rings once (the parent's relayed card), not
  twice: a child's approval now waits 3.5 s (was 1.5 s) for the relay before it notifies on its own. Only delegated
  children's approvals wait; one nobody relays rings that much later.

Update with `chi update` (no bundle changes; the system bundle upgrades itself with chi).

## [0.16.0] - 2026-10-03

### Added

- A delegated child's guardrail approvals go to the parent session's user (the approval relay): while the parent
  waits (`delegate`, `delegate_result`), the child's approval opens as the parent's own approval, in the parent's web
  page and attached terminal, with the same facts and diff and a line naming the delegate (linked) and its task. The
  user answers once there; the parent's model sees only an outcome line in the tool's result (`approval relayed to
  your user: execute: git push → allowed once`). The child verifies each answer with the parent's own worker before
  taking it, and holds a parent agent's answer to its own `guardrails.parent_approvals`. The child's card stays
  answerable (first answer wins) and says it waits in the parent too; `chi sessions list` shows it as
  `waiting (in parent ab12)` (json `relayed_to`), and the web's bell rings once, for the parent's card. The other
  running children's approvals are relayed during a wait too, one card at a time (`+1 more delegate waiting`), and a
  grandchild's hop by hop. The time a card is open doesn't count against the wait's timeout.
- For other parents (`chi send --wait`, `chi answer`), an approval's question block also offers to leave it open for
  the user: `chi send --wait --format json ID` waits until they answer it in chi.

### Changed

- A turn that ends with no answer (the empty-answer retries used up) saves the same shape from both loops: the hidden
  turn note alone. The native loop no longer saves the empty thinking-only reply and a literal `[No response]` (the
  next prompt had two assistant turns in a row), and the chat loop's `(the model returned an empty answer)` is no
  longer the answer text (`chi send --wait` saw it as an answer). The note carries a marker the UIs draw from, never
  sent to the model. Older sessions keep their `[No response]`.
- A parent agent's answer (`chi answer`, a marked `chi --attach`) no longer brings an archived session back to the
  lists; only a human's does.

### Fixed

- A turn with no answer shows one muted line in the attached TUI and the REPL,
  `no answer: the model returned nothing (after 1 retry)`, like the retry row, and so does `chi --resume` when it was
  the last turn (it showed `[No response]` or an earlier step's text as the answer, or nothing).
- The web shows a turn with no answer as the same muted notice where the answer would go, before the timing line,
  live and after a reload; the reload keeps the turn's steps (both thinkings, the retry row inside them). Live it
  showed nothing (native hosts) or an answer bubble below the timing line (`api: openai`); a reload showed
  `[No response]` as the answer with one step fewer, or lost the steps and turned the retry row into a bubble of
  its own.
- Attached `chi -p` from a script exits 1 with `chi: the model gave an empty answer` on stderr when its turn ends with
  no answer, as `chi -p --non-interactive` does; it exited 0 with a blank line (native hosts) or the placeholder text
  (`api: openai`) as the answer. `chi send --wait` reports such a turn as `no_answer` from both kinds of host (an
  `api: openai` host's placeholder was reported as the answer).
- `chi --resume` and `--attach` give the last exchange's replayed tool rows their durations, as the live rows show
  them (`ok (1.3s)`), from the session's saved tool records; a session from before turn ids keeps them bare.
- The web stage's status row reads `∅ no answer` (muted, with a warn edge) for a turn that ended with no answer; it
  said `✓ answered`.

Update with `chi update` (no bundle changes).

## [0.15.0] - 2026-10-02

### Added

- The hidden session strip's pill counts the sessions that wait for you (`▾ 5 sessions · 1 live · 1 waiting`, in the
  warn colour).
- The all-sessions search finds the sessions that wait for you: `waiting`, `question`, `approval` or `needs you`.

### Fixed

- `chi --resume ID` (and `--attach`) shows the last exchange's tool calls as the live tool rows
  (`tool> running command (execute command="true"): ok`) between the prompt and the answer, not the prompt and the
  answer alone.
- A `--no-shared` REPL keeps the session's `cards.json` as a worker does: its turns count, so the cards and notices an
  earlier worker showed stay where they were in the web, and the REPL's own are saved too.
- A deleted, discarded or retention-pruned session takes its plugins' state with it: a bundle's
  `plugins/<bundle>/sessions/<id>.json` (or `<id>/`) under the state dir, such as check-in's `/checkin` settings, no
  longer stays behind.
- `chi self`'s context window row shows the current model's configured window: its `models.<key>.window_tokens`, else
  its host's `hosts.<name>.window_tokens`, else `context.window_tokens` or the default, and says which.
- The web pairs each prompt with its own turn's timing: a failed turn (its prompt went back to you) no longer shifts
  the timing lines and turn numbers of the turns after it. chi saves a turn id on each prompt; prompts saved before
  this still pair by their place.

Update with `chi update` (no bundle changes).

## [0.14.0] - 2026-10-02

### Added

- The web marks a session that waits for you: its card gets a warn border, a pulsing dot and a `question`,
  `approval` or `needs you` badge, and it moves to the top of the strip and the all-sessions view until answered
  (the order holds while the pointer is over the list).
- `models.<key>.window_tokens` and `hosts.<name>.window_tokens` in config.yml set a model's or a host's context window
  for when the server and its model list report none (the model's wins over the host's, and both over
  `context.window_tokens`); the server's `n_ctx` still wins over all of them.

### Fixed

- chi starts under `LC_ALL=C` (or another US-ASCII locale): `chi -p` crashed with `Encoding::CompatibilityError` while
  building the system prompt from a memory index with non-ASCII text. chi and its workers read their files as UTF-8
  whatever the locale.
- The `mcp` bundle (0.4.0, `chi update`) attaches an image an MCP tool names inside its text
  (`Saved screenshot to /tmp/shot.png.`), not only a text that is the bare path; the same checks apply (an image by
  its bytes, under the temp dir or the server's `cwd`).
- An MCP server that sends `notifications/tools/list_changed` has its tools listed again (`mcp` 0.4.0): its saved list
  and the model's tools are replaced from the next turn on. They were only logged.
- An MCP server that exits mid-session starts again on its next call (`mcp` 0.4.0), up to 3 times a session; its tools
  failed until chi restarted.
- A burst of plugin notices no longer pushes cards and questions out of what a reloaded web page or a joining
  `chi --attach` shows: the worker keeps the last 20 of each apart, and never drops a question still waiting for its
  answer.
- `/checkin off`, `/checkin mode …` and `/checkin 30` last for the session across a worker's restart (an idle exit,
  `chi send` waking it): the `check-in` bundle (0.2.0, `chi update`) saves them per session and reads them back.
- `printf '2\n' | chi --attach ID` on a session already waiting on a question answers it: the piped line could be read
  before the question arrived and go in as a new prompt, and the attach then hung.
- A REPL reading its answers from a pipe shows each answer line once (`? 2`), not `? ? 2`, above why it was refused
  or invalid.
- A plugin's cards and a turn's hook notices (loop-guard's "stopped the turn" card and its `loop: … denied` rows,
  check-in's, any bundle's) stay after the worker goes: the worker saves them in the session's folder
  (`cards.json`, the same last-20 caps), the web shows them in place for a stopped session, and a later worker starts
  from them. They used to vanish with an idle exit, a restart or `chi sessions stop`.
- The web marks a tool call a guardrail denied (loop-guard, the `guardrails` bundle, a parent's or the user's Deny)
  `blocked` in red, as the TUI does, live and after a reload; it showed a green `done`.

### Changed

- A host is remote by its address, not by its API key: an `https` url or a public IP address. A llama.cpp on the LAN
  started with `--api-key` (`api_key_env:`) is now local again: chi asks its `/props` for the context window and the
  served model, keeps its model list for 60 s, and gives it no first-token limit. `hosts.<name>.remote: true|false`
  decides it for a host chi gets wrong (an http host named by a public DNS name counts as local).
- Codex CLI counts as a parent agent: an answer typed into `chi --attach` or the REPL from a command Codex runs
  (`CODEX_THREAD_ID` set) is held to `guardrails.parent_approvals`, as one from Claude Code is.
- `delegate` and `delegate_result` report a child's wait with the status words of `chi send --wait --format json`:
  `answered` (was `done`), `question` (was `waiting_for_answer`), `failed`, `canceled` or `no_answer` (was `no_reply`),
  and `running` when the parent's turn is canceled (was `canceled`).

Update with `chi update` (bundles: mcp 0.4.0, check-in 0.2.0).

## [0.13.0] - 2026-10-02

### Added

- `chi send --wait --format json` prints one JSON object on stdout however the wait ends: the reply, a question with its
  options and the `chi answer` command for it, or the status and a detail line, for scripts and parent agents.
- `chi answer ID --question QID --option N` (or `--text`, `--dismiss`) answers the question a session waits on and
  waits for what comes next, as `chi send --wait` does, so an agent running chi as a sub-agent can answer chi's
  questions itself. `chi send --wait -m` to a session waiting for an answer is refused with the `chi answer` command
  for it.
- An approval answered with `chi answer` can be denied, not allowed: allowing is the user's (the web, `chi --attach`).
  `guardrails.parent_approvals: once` in config.yml (no environment variable) lets "Allow
  once" through, never a wider scope, and never on a call that changes chi's own config, hooks or guardrail rules; an approval whose offered scopes are missing lets only Deny through. The worker
  checks it again with its own config (`chi answer` marks its answers); the web and `chi --attach` keep every scope.
- `chi sessions list` shows a session waiting for an answer as `waiting`; `--format json` has `waiting` (`question`,
  `approval` or `hook`) and `waiting_id`, the question's id for `chi answer --question`.
- docs/sub-agent.md: running chi as another agent's sub-agent, with instructions to paste into its `CLAUDE.md` /
  `AGENTS.md`.

### Changed

- The `guardrails` bundle (0.3.0) asks before answering chi's questions around `chi answer`: `chi --attach` / `chi -p`
  with stdin from a pipe, a here-string or a file, and `curl`/`wget` to a session's `/answer` route.
- An answer typed into `chi --attach` or the REPL counts as a parent agent's, held to `guardrails.parent_approvals`,
  when stdin isn't a terminal or `CLAUDECODE`, `AI_AGENT` or `SAMAGOTCHI_PARENT_SESSION` is set: a piped `y` no
  longer allows an approval at any scope. chi's `execute` and `task_create` export `SAMAGOTCHI_PARENT_SESSION` (the
  session's id) into the commands they run, and the model's `task_create` env can't set it.
- `guardrails.enabled` and `guardrails.small_models` are config.yml only: `SAMAGOTCHI_GUARDRAILS_ENABLED=false` no
  longer switches guardrails off, and a worker unsets every `SAMAGOTCHI_GUARDRAILS_*` it inherits, so a parent agent
  starting or waking a session can't switch its guardrails off. `XDG_CONFIG_HOME` still picks the config dir.
- `chi send --wait` exits 4 (not 1) when `--timeout` passes with the turn still running.
- Attached `chi -p` from a script exits 3 (not 1) when it leaves a question or an approval waiting for an answer,
  and prints the whole question on stderr with the `chi answer` command for it, as `chi send --wait` does.
- For an approval, the question block, `answer_with` and the refusal tell a parent agent to deny it and tell its
  user (`--option Deny --text WHY`), not `--option N` or `chi --attach`; other questions keep their wording.
- `chi send --wait`'s exit 3 prints the whole question on stderr: its text, numbered options and how to answer it.
- `delegate` / `delegate_result` on a child waiting for an answer give the whole question: its text, numbered options
  and the `chi answer` command for it.
- `chi send --image` with a missing file or one that isn't an image exits 1 (not 2, which is for usage errors), and
  with `--wait --format json` prints the JSON error line.

### Fixed

- The web no longer notifies about, or draws, a question a chi REPL is asking: the web can't answer it there.
- `delegate_result` on a child whose worker died says `worker_gone` instead of waiting for, or reporting, a question
  nobody can answer; `chi send --wait` and `chi answer` no longer report such a question as waiting either.
- Answers from Splash no longer start with two blank lines (a workaround until Splash drops them itself).
- An error in chi's work after a turn's answer no longer also reports the answered turn as failed.
- A Stop while a turn is still starting (chi asking the model server about the model) now ends the turn there: no before-turn hooks run and a due reminder stays due.
- `recap.model` set to a model id without a host no longer turns the recap off: it asks the host a bare `--model` goes to.
- AGENT.md is found at the top of the git work tree when chi runs in a subdirectory (one in the current directory still wins).
- `execute.timeout_sec` in config.yml (or `--execute-timeout-sec`) sets how long an `execute` command may run, like `SAMAGOTCHI_EXECUTE_TIMEOUT_SEC`; it no longer warns as an unknown key.
- A bundle's `requires_chi` now applies to its hooks too, not only its plugin: on a too-old chi they don't load, with a notice.
- `chi bundle install` and `chi bundle status` say when a bundle's hooks won't load because chi is older than its `requires_chi`, also for a bundle without a plugin.
- A model named with a disabled host's prefix (`box:model` where `hosts.box` has `enabled: false`) is refused with "host 'box' is disabled" instead of going to the default host as a model id.
- A Stop while a turn is still starting no longer uses up the warning about guardrails or plugins that failed to load: the next turn shows it.
- A plugin or MCP tool call reads the same in logs, rows and hooks' `content` whatever the model format or Ruby version: its arguments as JSON (Qwen calls showed Ruby's Hash#inspect, which changed in Ruby 3.4). A plugin tool returning a Hash or Array gives the model JSON too.

Update with `chi update` (bundles: guardrails 0.3.0).

## [0.12.0] - 2026-10-02

### Added

- `chi models [--format json] [--timeout S] [TEXT]` lists the names `--model` takes from every host (default first,
  then `host:id`, then aliases), waiting at most 4 s for the hosts; exit 1 when no host listed.
- The desktop helper chooses the model for a new session: ⌘M (or a click on the new row's model) opens a searchable
  chooser of every host's models and aliases; the pick and five recent ones are remembered. Run `chi desktop upgrade`.

### Changed

- `chi self --model` prints an alias default as the ref it resolves to (`box:gemma-small`, not `small`).

### Fixed

- A failed turn's messages and its `turn_failed` event reach a joining client together (a snapshot taken in between
  could show one without the other).
- A Ctrl-C while an `after_turn` or `session_end` hook runs no longer cancels the turn that already answered: the
  answer stays in the session (it was replaced with a cancel note and a second end event).
- A web Stop sent right as a turn starts (while chi asks the model server for its settings, a first turn's /props
  probe) cancels the turn at once; it used to answer "not running" and the turn ran on. A failed probe there now ends
  the turn as failed instead of leaving the session marked running.
- Reminders keep firing on their own while a session is idle. A reminder that a prompt's turn delivered just as the
  idle check found it due, or a reminder turn that failed before it started, could stop them until the next prompt.

Update with `chi update` (no bundle changes); run `chi desktop upgrade` for the desktop helper's model chooser.

## [0.11.0] - 2026-10-01

### Added

- The web composer has the TUI's prompt history: ↑/↓ walk the prompts typed in either (↑ with the caret on the first
  line; ↓ past the newest brings your draft back). A running TUI picks up lines typed in the web, or in another
  terminal, without a restart.
- Hooks and plugins: `:after_tool_call` carries the call's `status` (`ok`, `error`, `blocked` or `stopped`), the one its
  activity line shows, worked out from the full output (`output:` is capped).
- The `skills` bundle (0.1.5) tells a failed step by that `status` instead of matching the output's wording: an
  execute killed by a signal now counts as failed, and an `Error:` line in the output of a command that exited 0 no
  longer does. It needs this chi.

### Changed

- The prompt history keeps 100 entries (was 20), is written under a lock and replaced whole (no lost lines when two
  chi processes write at once), and is now mode 0600.
- With an OpenAI-compatible chat host (`api: openai`), the context value in the REPL's status line and the web's ctx
  meter now moves during a turn, before each request, and the model gets the same short `[CONTEXT: …]` line the
  llama.cpp loop gives it once usage rises past 40 % (`context.status_thresholds`). Before the host reports its first
  token counts, the value is an estimate.
- Model aliases apply once (an alias pointing to another alias sends that name as written; chi warns at start), and a
  session stores the resolved model (`box:gemma-small` for `tiny`) plus the name it was typed as (`model_typed`), so a
  resumed session keeps its model when an alias is retargeted. With a `default.model` alias, memory overlays and the
  guardrails' `models:` rules now go by the alias's target (an overlay saved under the alias is still read).
- Breaking: only `:` names a host in a model ref. `/` is part of the id, so `openai/gpt-4o` (an OpenRouter id) goes to
  the default host as written even when a host is named `openai`. chi always wrote `host:`; a hand-written
  `host/model` in `default.model`, an alias or a saved session warns at start (fix it with `host:model`).
- `/models` shows a `host:model` alias only under its own host.
- Breaking: an unqualified model name is routed by exact id only. It goes to the default host when that host lists it,
  else to the first host in `hosts:` order that does (it was whichever host answered `/models` first), else to the
  default host; substring routing is gone (`/model gemma` no longer picks a local host listing `gemma-…`: use
  `box:gemma` or the exact id). chi warns at start about a host named like a model family (`qwen3`, `llama`, …).
- `recap.model` is a model ref like any other: an alias is applied, and `recap: {model: box:x}` with no `host_ref` recaps
  on `box` (it turned recap off). Breaking: `recap: {host_ref: a, model: b:x}` now warns and turns recap off instead of
  silently asking `a` for `x`.

### Fixed

- `recap: {host_ref: openrouter, model: openai/gpt-4o}` sent `gpt-4o`.
- An alias in `default.model`, the web's new-session model, `chi send --new --model` or a plugin fork was sent to the
  server as the alias, not its target; `chi self` named a different model than the worker sent.
- `/model box:tiny` (an alias for `box:gemma-small`) sent `box:gemma-small` to box; `/model openrouter:tiny` is now
  refused (the alias names host `box`), in the TUI and as a web 400.
- `models: {small: …}` now applies after `chi --model small` and after resuming such a session.
- A TUI already waiting at `>` shows a prompt just typed in the web (or another terminal) at the first ↑, instead of
  only from the next prompt on.
- The `known-names` bundle checks the name in `~name` (that user's home folder): `ls ~myname` is no longer rejected
  as a near miss of `myname`, and `ls ~mynmae` is caught.
- `chi sessions` usage errors exit 2, as every other command's: an unknown subcommand, `stop` with no ids, a bad
  `list --format` or `--scope`, and now also an unknown flag or a flag missing its value for `list`, `prune` and
  `clean` (they were ignored). Each prints what was wrong and the usage on stderr. A session that is unknown or
  refused still exits 1.
- With a llama.cpp, mlx or oMLX server (no `api: openai`), an empty answer cut short because the context is full
  (90 % or more) is no longer asked again, as `retry.empty_answer` documents and as with OpenAI-compatible chat
  hosts; a thinking loop cut by the output cap still is. These loops' `generation_completed` events and log lines now
  carry the `finish_reason` too.
- With an OpenAI-compatible chat host, an answer of only whitespace is an empty answer, as with llama.cpp: asked again
  (`retry.empty_answer`) instead of saved, and with no retry left the turn says the model returned an empty answer.
- `--no-interrupt` (and `no_interrupt: true`) now raises the tool-call limit to 1000 in the in-process REPL with an
  OpenAI-compatible chat host too; it only applied to llama.cpp, mlx and oMLX hosts there.

Update with `chi update` (bundles: known-names 0.1.4, skills 0.1.5).

## [0.10.1] - 2026-10-01

### Fixed

- The `known-names` bundle no longer rejects a shell glob of a known name, such as `ls -d myrepo*` in a repo named
  `myrepo`: a token with `*?[]{}` is not checked.
- The `skills` bundle no longer counts a call that a guardrail or the user denied as a failed skill step, so it
  doesn't steer the model to fix the skill or say "a step failed" at the turn's end.

Update with `chi update` (bundles: known-names 0.1.3, skills 0.1.4).

## [0.10.0] - 2026-10-01

### Changed

- Built-in tool calls are built the same way for every model format (Gemma and Qwen native, OpenAI-style chat), so
  they no longer differ by format. As part of that:
  - `edit` takes the old and new text as two fields (`old_text`, `new_text`), so old text that contains `</old>` is
    no longer cut short; `edit` without `new_text` is an error (it deleted the matched text; pass `""` to delete).
  - `write` without `content` is an error with every model format (Gemma and Qwen emptied the file).
  - `register_reminder` from a Qwen model without an interval no longer always fails.
- Plugins: `ctx.notify`, `ctx.ask_user`, `ctx.steer`, `ctx.stop_turn` and `ctx.stop_generation` are the one way a plugin
  acts; inside a `chi.on` block they act for that event as `event[:x]` does (`ctx.stop_turn` in `:before_tool_call`
  denies the call, `ctx.steer` from `:after_turn` is false), and as before anywhere else (commands, your own threads).
  Plain hook files keep `event[:x]`.
- Attaching to a session mid-turn (`chi --attach`) shows the turn's finished tool calls as they looked live, with
  what each did and how long it took (`tool> running command (execute …): ok (1.3s)`), when the worker runs this chi.
- `chi bundle` usage errors (unknown subcommand or flag, a missing argument) exit 2 like every other command, not 1.
- A config hook with `on_error: log` warns as `[samagotchi:hooks] <file> (config) failed: <error>`, the same shape as a
  bundle hook's warning; a fail-closed bundle guardrail's deny reason reads `... (bundle <name>) raised <error>`.
- Bundles (`chi update`):
  - known-names 0.1.2: corrects a near-miss name only in paths, `cwd` and commands, no longer inside text being
    written to a file (`write`/`memory_write` content, `edit`'s old and new text, where a correction could stop the
    edit matching).
  - loop-guard 0.2.2: tells repeated `edit` calls apart by their old and new text; acts through `ctx`.
  - skills 0.1.3 and mcp 0.3.2 (mcp now needs chi 0.8.0): write a skill's history and the MCP tool cache through a
    unique temporary file, so two workers saving at once no longer collide.
  - check-in 0.1.3 acts through `ctx`; source-links 0.3.1 drops dead code. They behave as before.

### Fixed

- Web: a Gemma model on a native llama.cpp host streams its answer into the reply as it writes (it showed only when the
  turn ended), with its thoughts in the thinking block; the attached terminal shows them as thinking and the answer as
  writing.
- `execute` with a `cwd` now runs in that directory with Gemma and Qwen native tool calls too (the directory was
  dropped and the command ran in the project root).
- `/model … --default` and `/model … --alias` keep the comments and layout of `config.yml`: they change one line
  (or add one) instead of rewriting the whole file.
- `chi sessions stop` marks the session with a `stopped` file in its folder instead of rewriting its session file, so
  a worker saving at that moment can no longer undo the stop (or lose its own save); a resume removes the file.
- The web's answer, dismiss, command and cancel calls fail the same way: a worker that doesn't answer in time is
  504 ("did not answer, so ... was not ..."; cancel said "not running"), a worker running an older chi is 501 with
  how to restart it (an answer said "not running").
- A web page joining (or re-syncing with) a live session gets its status and pending question as of the same moment
  as the messages; they could be a step newer.
- The web's `POST /api/sessions/:id/turn` refuses more than 20 images in one message, as a live worker already did.
- Web: switching sessions no longer briefly shows the previous session's "delegated by" link in the info bar.
- The terminal's "retrying (1/3 …)" line counts retries as the web does (it said "1/4", counting the first try).
- `chi self`'s thinking line finds a `models:` entry under the model an alias points at, as a turn does.
- A `required: true` config hook that raises something other than a StandardError (e.g. `NotImplementedError`) denies
  the tool call like any other raise, instead of escaping the guardrail check.

Update with `chi update` (bundles: known-names 0.1.2, loop-guard 0.2.2, skills 0.1.3, mcp 0.3.2, check-in 0.1.3,
source-links 0.3.1).

## [0.9.0] - 2026-10-01

### Changed

- A small change to a memory or skill can go through `edit` on its file instead of rewriting it all with
  `memory_write`; the prompt, the memory guide and the nudge below say so. `write`/`edit` on a memory's file
  refresh its line in `index.md` (date, size; the description is kept), and the default guardrails no longer ask
  before them as "writes outside the repository".
- The system prompt no longer tells the model to keep `index.md` updated (`memory_write` does it); its result
  says "Index line refreshed automatically." instead of naming the index file.
- `skills` bundle 0.1.1 (`chi update`; needs chi 0.9.0): a skill changed some other way (an `execute` running `sed`) counts as
  updated: you get the usual "skill X updated" line, `/skill diff` has the old text, and the nudge and the turn-end
  "wasn't updated" line no longer fire for it. The nudge asks to `edit` the changed step rather than rewrite the
  whole skill.

### Fixed

- `chi bundle install` of a bundle that's already installed no longer says "Skipped X (already exists; use --force
  to overwrite)" for a file that's the same as the bundle's; it skips it quietly and says once that
  `chi bundle upgrade NAME` updates the bundle and keeps local edits. A file skipped for a local edit no longer
  also reports a checksum mismatch.
- `chi bundle install` and `upgrade` no longer list a bundle's unchanged guardrail rule files as "Installed"; they
  are skipped as already up to date like its memory files.
- A memory file you edited, then `chi bundle install` of its bundle again (skipped for the edit), no longer gets
  overwritten by the next `chi bundle upgrade`: the re-install kept your edit as the bundle's base, so the upgrade
  took it as unedited.
- `chi sessions list --sort/--order` is no longer ignored with `--live`, `--cwd` or `--format`.
- A tool's time in the web's turn timing and the debug log's `tool_call_completed ms:` no longer counts the wait for
  a guardrail approval; the log line shows the wait as `waited_ms:`.

Update with `chi update` (bundles: `skills` 0.1.1).

## [0.8.1] - 2026-10-01

### Added

- Guardrail rules can name the models they apply to (`models: small`, or globs on the model name). The guardrails
  bundle (0.2.0, `chi update`; needs chi 0.8.1) adds two asks only small models get: `git checkout -- <file>` /
  `git restore` (discards uncommitted changes) and `git stash drop`/`clear`. Small is `guardrails.small_models`:
  `auto` (the default: 32B or less by the size in the model's name, an MoE's active size counting), a list of
  globs, or `[]` for none. A chi older than 0.8.1 that shares the bundles dir (a checkout next to the gem, or a
  worker still running after a gem update) doesn't know `models:` and denies every tool call until it is
  restarted on the new chi.

### Fixed

- A tool row's time in the REPL and the attached TUI no longer counts the wait for a guardrail approval
  (`blocked (2m 54s)` for a call denied at once).
- docs/guardrails.md: rules are read again on the next tool call after config.yml or a bundle's rules change, with
  no restart.

## [0.8.0] - 2026-10-01

### Added

- Bundle profiles: `core` (loop-guard, check-in, guardrails) and `dev` (known-names, mcp, btw, skills,
  source-links) install a set of the shipped bundles, `chi bundle install core`. A bundle you uninstall stays
  out when the profile is installed or upgraded again, and `chi update` installs a bundle a new chi adds to a
  profile you have. `chi bundle uninstall core` removes its bundles, `chi bundle list` and `status` show them.
- `chi bootstrap` installs the system bundle and the `core` bundles, and on a terminal offers `dev`. Existing
  installs get neither by themselves.

### Changed

- Dismissing a question (Esc, an empty answer, or no one to answer in `-p`) now tells the model not to do what it
  asked about, or anything else that changes files or state, and to wait, instead of "go on with your best
  judgement".
- The system bundle tells chi to stop and ask on anything unexpected while following a skill (a failing check,
  output that differs from a step, a warning the skill doesn't mention) instead of improvising a fix.
- `chi bundle list` and `chi update`'s footer list the shipped bundles that aren't installed under their
  profile (`core (…)`, `dev (…)`).
- `chi bundle status` without a name lists a bundle whose `manifest.json` doesn't parse as unreadable instead of
  failing.
- The web stage view flashes a plugin's nudge ("↪ check-in nudged the model") and a hook's info notice in its
  trail for about 4 s, as it already did a warn notice, so they are seen while the turn runs with the block
  closed. chi's own "asking again" row does not flash (the status line says it).
- A turn a hook stops (loop-guard, check-in's Stop) tells the model which hook stopped it and why.
- With custom `context.status_thresholds`, the context guidance follows them (the top bucket reads critical)
  instead of calling every bucket healthy.

### Removed

- `POST /api/sessions/:id/answer` no longer takes the unused aliases `question_id`, `selection`, `other` or
  a nested `answer` object: only `id`, `selected` and `freeform`, as the web page sends them.
- Sessions no longer write plain-text input for a worker from before 2026-09-23 (one that advertises no input
  format) or refuse images to one that predates them (`images_unsupported`), and a worker no longer reads
  `input/*.txt`: every chi since then writes and reads JSON input. A worker that old never exits by itself;
  restart it (`chi sessions stop ID`, then send to it) before upgrading.
- A worker from before the owner lock (2026-09-22) no longer counts as a session's owner through its pid file:
  only the lock holder does, so a stale pid file whose pid was reused no longer makes a session look busy.

### Fixed

- A hook or plugin that fails while watching the stream is logged once a minute instead of on every batch
  (it printed to stderr on every fire).
- The web stage view's headline skips lines inside a code fence.
- A question left open when a session's worker died no longer stays pending: the web and the hub stop showing
  it (and the "needs you" badge) at once, and the next worker drops it.

### Security

- Session ids from outside (the worker's Bridge, the web routes, `chi send` / `note` / `sessions`,
  `--resume` / `--attach`, the delegate and send_note tools) are checked in one place, so an id such as
  `../x` can no longer reach a path outside the sessions folder. The Bridge answers 400, the web 404.

Update with `chi update`. New bundles: `core` 0.1.0 and `dev` 0.1.0 (install with `chi bundle install core`,
`chi bundle install dev`); existing installs don't get them by themselves.

## [0.7.0] - 2026-09-30

### Added

- The desktop helper also sends to agent CLIs (claude, codex, …) in kitty windows: with `kitty.listen_on` copied
  from kitty.conf (and `chi desktop upgrade`), the panel lists them in a "kitty" group next to the sessions; ⏎
  pastes the quote, message and image paths and presses Enter, the new ⌥⏎ only pastes (so several screenshots
  can pile up), and one send can go to chi sessions and kitty windows together. ⌥⏎ no longer inserts a newline
  in the panel (⇧⏎ does). See docs/desktop.md "Agents in kitty".

Update with `chi update`. No bundle versions changed.

## [0.6.0] - 2026-09-30

### Added

- Plugins can watch a response while it streams: the `:generation_progress`
  hook gets the new thinking and text in batches (2000 chars or a second),
  and `event[:stop_generation]` / `ctx.stop_generation` cut the generation
  while the turn goes on: the model is asked again (`↻ cut by <bundle>,
  asking again (1/1)`), using the `retry.empty_answer` budget. See
  docs/hooks.md, "Watching the stream".
- loop-guard 0.2.0 watches the model's thinking while it streams: thinking
  that goes round in the same few sentences is cut and the model asked
  again; if the retry loops too, the turn stops with a card. On by default
  (`bundles: loop-guard: thinking: watch: false` turns it off); upgrade the
  bundle with `chi bundle upgrade loop-guard`.
- The desktop helper shows the model a new session will use, next to "New
  session" (from the new `chi self --model`, which prints the resolved default
  model).

### Changed

- `chi web` draws turns with the stage view by default (`web.view: stage`:
  the running turn pinned above the composer). `web.view: turn`
  (`--web-view turn`, `?view=turn`) brings back one block per turn in the
  history.
- In the stage view, a plugin card with buttons (check-in's Nudge / Keep going
  / Stop) sets the status to "waiting for you" while it's unanswered, and the
  headline shows plain text while the answer streams (no `|`, `**` or `#`).
- On a phone, the session footer hides the "copy chi --attach" chip.
- `delegate` and `delegate_result` with `timeout: 0` look once and return at
  once (a negative timeout counts as 0) instead of waiting 600 s.

### Removed

- The web chat view (`web.view: chat`, `--web-view chat`, `?view=chat`): the
  stage and turn views draw every turn. A config that still says
  `web.view: chat` warns about the invalid value and uses the default;
  `?view=chat` in a page URL is ignored.

### Fixed

- A reload of the web page, or joining a running turn, shows the turn's own
  rows where they were live: the "↻ empty answer / cut by <bundle>, asking
  again" row (also when `chi --attach` joins), an answered or dismissed
  question card, and a line sent while the turn ran (a "steered" bubble in
  that turn; it no longer splits the turn in two, which shifted the timing
  lines of later turns). A guardrail or plugin load warning comes back above
  the turns after it instead of at the end, and a canceled turn's timing
  line says "· canceled" live too. Rows and cards of finished turns last as
  long as the session's worker.
- A cancel racing a web page's refresh while a question was open could
  freeze the session's worker (a lock-order deadlock).
- `chi bundle upgrade --dry-run` on a bundle that isn't installed wrote the
  files anyway; it now writes nothing.
- `chi bundle install` / `upgrade` with a source that doesn't exist says
  "Install failed: source does not exist: …" instead of a Ruby backtrace.
- `chi sessions prune --keep N` counts only the sessions that stay: a
  leftover scratch session as the newest one no longer makes `--keep 1`
  delete every session.

Update with `chi update` (loop-guard 0.2.0: the thinking watch).

## [0.5.1] - 2026-09-30

### Fixed

- `chi desktop install` / `upgrade` builds the helper again on Macs whose
  Command Line Tools lack SwiftUI's macro plugin ("plugin for module
  'SwiftUIMacros' not found", since 0.5.0's image thumbnails).
- After updating chi and restarting `chi web`, the browser loads the new page
  code on the next reload instead of running the old one for up to an hour.
- A plugin's warning card stays in sight when its step closes while the turn
  goes on.
- Sessions on OpenAI-compatible hosts no longer fail to send a request when a
  message with an image also carries text with broken UTF-8 bytes.
- `delegate` and `delegate_result` return as soon as a delegated session's
  turn fails, instead of waiting out the 10-minute timeout when it failed
  quickly.

Update with `chi update`. No bundle versions changed.

## [0.5.0] - 2026-09-30

### Security

- `chi web` and the worker Bridge refuse requests from other websites. Before,
  a page open in your browser could start a session that runs commands, or
  read your sessions and their output. Please update if you run `chi web`.

### Added

- Skills: a memory named `skill_<name>` holds the steps of a task you did with
  chi. Say "let's memorize this" and chi saves it; next time it reads and
  follows it, and fixes a step that turned out different in the same turn
  (docs/memory.md, Skills). The system bundle's identity and memory guide
  teach it.
- The `skills` bundle (`chi bundle install skills`): `/skill save [name]
  [--system]`, `/skill list`, `/skill show`, `/skill diff`; older versions of
  each skill kept (`history_keep`) with a one-line diff after every update;
  a nudge when a followed skill's step fails and the model goes on without
  fixing it (docs/plugins.md, The skills bundle).
- `chi web --web-host lan` (`web.host: lan`, or one of this machine's IPv4
  addresses): the web UI on your phone. chi web also listens on the LAN
  address and prints a link with an access token and its QR code; every
  request from another machine needs the token, which the page keeps in a
  cookie. `chi web --new-token` replaces it; `chi self` says when chi web runs
  on the LAN. Plain http: for a home network only. New runtime dependency:
  `rqrcode_core`.
- A third web view, `web.view: stage` (`--web-view stage`): the running turn
  sits above the composer, its tool calls in an expandable cloud, and hands
  off smoothly into the history when it ends. `web.view: turn | stage | chat`
  replaces `web.turn_view` (turn stays the default).
- The start page's model picker is searchable: models grouped by host, your
  last 5 picks first, every typed word matched ("deepseek4.1 fla" finds
  `openrouter · deepseek/deepseek-v4.1-flash`), arrow keys, Enter and Esc.

### Changed

- config.yml edits apply without restarting `chi web`: new sessions read the
  file, and running ones pick up settings they read each time (retries,
  limits, log level). Old flat `UPPER_CASE` keys and `backend:` are no longer
  read; they warn as unknown keys.
- The terminal REPL (`chi --no-shared`, `chi scratch`) shows turns the way
  the attached terminal does, and all three UIs end a turn with the same
  words ("✕ turn canceled (Ctrl-C) · 3.1s", "✕ turn failed: …"); a provider
  retry shows as a dim line. The REPL-only settings `thinking.ui`,
  `thinking.render_interval` and `status.width_mode` / `max_width` /
  `fixed_width` are gone.
- `session.keep_status` defaults to none: a session left "running" by a
  crashed worker is cleaned up like any other; a session with a live worker
  is never removed.
- `chi send --image` to a model that can't take images is refused before
  anything is sent, with the reason, instead of failing in the session.
- A low/medium/high thinking level on a llama.cpp chat host whose template
  ignores it says so once.
- The web answers `/stats`, `/recap` and `/detach` itself (they're terminal
  commands) instead of showing a worker error.
- Piped input to an attached chi (`echo "do X" | chi`, `chi -p X` with no
  terminal) waits for its turns to end and exits 1 if one failed, instead of
  detaching at once.

### Fixed

- OpenRouter's "overloaded" error sent inside an HTTP 200 is retried like a
  503 instead of failing the turn.
- The context line the model sees during a long tool loop counts the tool
  output added since the last request, so the model knows when to wrap up.
- `chi send --wait` no longer hangs when the turn fails very fast (for
  example right after an earlier failure); it says the turn failed and why.
- On Linux the system prompt now gets the "prefer rg" hint when rg is
  installed (the check only worked on macOS).
- `chi sessions list --live` shows the test sessions of a test run.
- `chi -p` with no terminal (stdin from a pipe or /dev/null) sends its prompt
  once: a failed turn re-sent it in a loop (hundreds of requests a second),
  and an attached `chi -p` didn't send it at all.

Update with `chi update`. Bundle added: skills 0.1.0 (`chi bundle install
skills`).

## [0.4.0] - 2026-09-30

### Added

- `chi update`: brings an installed chi up to date in one command: the gem
  from rubygems, then the system bundle, the shipped bundles you installed and
  the desktop helper (rebuilt only when its sources changed), shown in one
  table. Your edits to bundle files are kept and reported, running workers and
  an old `chi web` are only reported, `--dry-run` shows the plan, and
  `--no-gem` / `--no-bundles` / `--no-desktop` (or `update.*` in config.yml)
  skip parts. The first start of a new chi version says in one line when
  something can be updated.
- A thinking level per model, host or run: `thinking: off | low | medium |
  high | default` (`models.<key>.thinking`, `hosts.<name>.thinking`,
  `thinking.level`, `--thinking LEVEL`). Chat hosts get the matching request
  fields; native Qwen and Gemma turn thinking off. chi says once when a level
  can't work on a host, and a host that refuses the thinking fields (gpt-oss
  on OpenRouter) is asked again without them. `/model` and `chi self` show
  the level.
- Edit previews: an edit/write approval shows the diff it would make, in the
  web card and in the terminal, and every edit/write row gets a
  "diff +3 −1" that opens to the change (live, after a reload and on a join).
- `chi send --image PATH` (repeatable, up to 20): images go with the message
  as attachments, the same as the web composer's chips; converted and
  downscaled once, then copied into each session. Works with `--new` (the
  session starts idle, then gets the message with its images) and `--wait`.
  A missing file or a non-image stops the send before anything goes out.
- The desktop helper takes images: a clipboard screenshot, image files from
  Finder's Send to chi, other apps' image data, or a drop on the panel; they
  show as thumbnails and go with the message.
- source-links 0.3.0: `#12` links to the current project's repo (from its git
  remote) and `owner/repo#12` to that repo; `url:` templates take `{1}`,
  `{name}`, `{repo}` and `{host}`, with `remote:` and `remote_host:` per
  source, and the note lists each link once.
- The web shows when the provider is asked again after an error ("↻ retrying
  (503) in 3 s, 1/2") or a turn waits for a plugin's setup.

### Changed

- A model named with a host that isn't configured (`nosuch:org/model`, or a
  provider's name like `openrouter:x`) is an error that names the host and
  lists the configured ones, in the CLI, `chi send --new`, the web and
  `/model`, instead of going to the default host.
- The terminal no longer rewrites `#word` into a memory reference: "PR #1"
  and "#ff0000" reach the model as typed (Tab still completes `#name`).
- A question you dismiss reaches the model as dismissed, not as a tool
  error, so it keeps asking when it should.
- `/quit` works in the REPL like `/exit`, and the web answers it too;
  `/stats` and `/recap` take trailing words in both terminals.
- A delegated session gets reworded rules: the answer first, then evidence,
  then what's unverified; follow-up messages arrive as new turns.

### Fixed

- A llama.cpp server started with `--api-key` works: the key in
  `api_key_env` is sent on every request (it got 401). A 401/403 from any host
  now says which variable to check or to set `api_key_env`.
- A bundle upgrade that keeps your edited file no longer disables the
  bundle's plugin, and the system bundle stops warning about the same edit on
  every start.
- One bundle with a broken manifest.json no longer stops the hooks of the
  bundles after it from loading.
- A long-running worker picks up edited guardrail rules.
- `write` without content fails instead of emptying the file.
- Per-model `vision:` follows a model alias, like `profile:` and `sampling:`.
- A timeout of 0 in config means the default on llama.cpp hosts too (it was a
  0-second timeout).
- A reminder turn drops a pending continue offer, so a later "no" can't roll
  the reminder back.
- More than 8 options in `ask_user_question` is always an error (one path
  silently used the first 8).
- A memory read with a comma list counts each name in the REPL and the web.
- `/archive` or `/quit` typed during a REPL turn no longer goes to the model
  as text; `EXIT --DELETE` works in any case in an attached terminal.
- `chi bundle status` finds index lines again (it said "no-index" for every
  file).

Update with `chi update` (new in this version: from 0.3.0, run
`gem install samagotchi` once, then `chi update`). Bundle moved:
source-links 0.3.0.

## [0.3.0] - 2026-09-29

### Added

- `chi bootstrap [HOST[:PORT]|URL]`: the first setup in one command. It finds
  out whether the server is llama.cpp or OpenAI-compatible (with no target, it
  looks on localhost's usual ports), picks the model, sends a test request and
  writes config.yml; an existing config gets a `hosts:` entry added after a
  backup, its other lines untouched. `--key-env VAR` for a server that wants a
  key, `--model`, `--name`, `--no-test`, `--dry-run`. The first-run "no model
  configured" line points at it.
- Web notifications: a session that needs you (a question or approval, a
  failed turn, a turn done after 10 s or more) while the tab is in the
  background counts in the page title, `(N) Chi`, and with the new bell in the
  top bar on, shows an OS notification that opens the session.
- `chi scratch`: a one-time session in the terminal that leaves nothing behind.
  It is deleted however it ends, saves no memories and starts no other
  sessions; one left by a killed process goes at the next sweep or
  `chi sessions clean`.
- Archiving a session: `chi sessions archive ID`, `/archive` in a terminal or
  `archive` in the web's info bar hides it (and its delegates) from every list
  and keeps it for good; `chi sessions list --archived` and "include archived"
  in the web's all sessions find it, and a message you send to it brings it
  back.
- `chi send --new` starts a session with the message, the way the web does, so
  it shows in the web at once (`--dir`, `--model`); `chi send --wait` (new or
  one existing session) blocks and prints the answer, exit 3 when the turn
  waits for your answer.
- The `check-in` bundle (`chi bundle install check-in`): after 50 tool calls
  in one turn with no answer (then every 50 more) a card asks you to nudge
  the model, let it keep going or stop the turn; `mode: nudge` nudges it by
  itself. `/checkin` shows and changes it for the session.
- Plugins can steer the running turn: `ctx.steer(text)` and a hook's
  `event[:steer]` put text into the turn as its own message at the loop's
  next step, shown as `<bundle>> nudged: …`; `ctx.stop_turn(reason)` stops it.
- The `source-links` bundle (`chi bundle install source-links`): refs like
  `JIRA-123` or `GH-45` in an answer become links in the web, and a one-line
  `sources:` note follows the turn in the terminal. Sources are patterns in
  `bundles: source-links:`.
- Plugins can change how an answer is shown without changing what the model
  sees: an after_turn hook's `event[:present]` sets a display version of the
  answer, which the web renders (and keeps after a reload).
- Annotate presets: selecting text in an answer offers quick replies next to
  Annotate (default "Agreed" and "Could you please elaborate?"); a pill puts
  the quote and the text in the composer without sending.
  `web.annotate_presets` (`|`-separated or a YAML list; `""` turns them off).
- `sampling:` on a `hosts:` or `models:` entry (temperature, top_p, top_k,
  min_p, penalties, …) is sent with every request to that host or model;
  `temperature: null` sends none, so the provider's default applies.
- `retry.empty_answer` (default 1): when the model returns an empty answer
  (or runs out of tokens while thinking), chi asks again once in the same
  turn; the terminal and the web show "↻ empty answer, asking again".
- The context fill is saved with the session: `chi sessions list` and the web
  list show it (`ctx 12%`), and `/stats`, the status line and the web meter
  show it right after a restart or a reload. Token totals now cover the whole
  session across worker restarts.
- `chi send --wait ID` with no message waits for the session's next reply
  without sending anything (also on a running session), e.g. after `--wait`
  exited 3 for a question.
- The desktop panel has a "New session in <folder>" row (⏎ starts a session
  with the selection there).
- Web notifications also cover a check-in card waiting for you, and a chi tab
  in front keeps the tabs behind it from notifying twice.

### Changed

- Stop ends a turn that is waiting in `task_wait` or running `execute` within
  about a second, and a Stop right after a turn starts ends it at once. A
  background task keeps running: the model is told it's still running and how
  to continue or stop it, and the cancel note lists the session's tasks still
  running. A stopped wait shows as "stopped".
- config.yml: a nested key now wins over its legacy flat `SAMAGOTCHI_*` key
  (one warning names both); an unknown key warns with a did-you-mean;
  top-level keys like `max_tool_output_chars` no longer warn; `no_interrupt`
  and `no_default_input` work from config and env.
- A refused connection to a host fails at once with "can't reach host … — is
  the server running?" instead of retrying for half a minute.
- A host whose `/props` doesn't answer costs one probe per 30 s, not a wait
  at every turn.
- `chi -p … --non-interactive` with an empty answer says so on stderr and
  exits 1.
- docs/configuration.md uses nested keys throughout and lists every setting;
  the README starts with `chi bootstrap`.

### Removed

- The unused config keys `bridge.enable` and `thinking.preview_lines` (they
  now warn as unknown).

### Fixed

- The web keeps a failed turn's prompt and reason after a reload, and a failed
  turn's prompt comes back to the composer, also for a first message from the
  start page.
- Web answer links appear with the answer instead of being swapped in after it.
- The title badge clears when you switch to the tab in Safari, and drops a
  question answered from another tab or client.
- `/archive` and `/exit` typed in the web composer get a short reply instead
  of an error.
- An approval card for a tool without a command or path shows its arguments.
- A hook notice from before the turn stays in its step after a reload.
- Card actions (check-in's Nudge, …) no longer leave a command bubble or line.
- A 404 from a native (llama.cpp) host hints at `api: openai`.
- A config `memories:` entry that can't be loaded is no longer called `--memory`.
- `chi --resume`/`--attach` refuse a leftover scratch session.
- `chi sessions list --live/--cwd/--format` show `[scratch]` too.
- The legacy-key warning names the right nested key.

### Bundles

- New: `check-in` 0.1.1 (`chi bundle install check-in`, needs chi 0.3.0) and
  `source-links` 0.2.0 (`chi bundle install source-links`). No other bundle
  changed since 0.2.0.

## [0.2.0] - 2026-09-27

The first public release. chi is an agent harness for local models
(llama.cpp, mlx-lm, oMLX) and OpenAI-compatible servers, built around memory
and long-lived sessions.

### Added

- One session, three UIs: the terminal REPL, an attached terminal and a web UI
  (`chi web`) join the same session and see the same turn live; a session keeps
  running in a background worker when you detach (`chi --attach ID` comes back).
- Saved sessions (`chi sessions list`, `chi --resume ID`) and a short recap of
  what happened when you come back to one.
- Memory in plain Markdown files, per project and system-wide, with
  model-specific overlays; memory bundles to share and upgrade them
  (`chi bundle install`, `chi bundle list`, `chi bundle upgrade`).
- Plugins (commands, tools, cards, hooks) and an MCP bundle that brings in the
  tools of MCP servers; shipped plugins: `btw` (a side question mid-turn),
  `loop-guard` and `mcp`.
- Guardrails: every tool call can be allowed, denied or asked about first, with
  approvals per session, repo or rule; `chi bundle install guardrails` adds a
  default set.
- `delegate`: the model hands a task to a child session that runs in parallel
  and reports back.
- Images: `@shot.png` in a prompt, or a pasted or dropped image in the web UI,
  for models that can see them.
- `chi note` (background context for a session, no turn) and `chi send` (a
  message into a session, which wakes it if it was stopped).
- A macOS desktop helper (`chi desktop install`): a "Send to chi" Service and a
  hotkey panel that send selected text or the clipboard to your sessions.

[Unreleased]: https://github.com/dm1try/samagotchi/compare/v0.52.0...HEAD
[0.52.0]: https://github.com/dm1try/samagotchi/compare/v0.51.0...v0.52.0
[0.51.0]: https://github.com/dm1try/samagotchi/compare/v0.50.0...v0.51.0
[0.50.0]: https://github.com/dm1try/samagotchi/compare/v0.49.0...v0.50.0
[0.49.0]: https://github.com/dm1try/samagotchi/compare/v0.48.0...v0.49.0
[0.48.0]: https://github.com/dm1try/samagotchi/compare/v0.47.0...v0.48.0
[0.47.0]: https://github.com/dm1try/samagotchi/compare/v0.46.1...v0.47.0
[0.46.1]: https://github.com/dm1try/samagotchi/compare/v0.46.0...v0.46.1
[0.46.0]: https://github.com/dm1try/samagotchi/compare/v0.45.0...v0.46.0
[0.45.0]: https://github.com/dm1try/samagotchi/compare/v0.44.0...v0.45.0
[0.44.0]: https://github.com/dm1try/samagotchi/compare/v0.43.0...v0.44.0
[0.43.0]: https://github.com/dm1try/samagotchi/compare/v0.42.0...v0.43.0
[0.42.0]: https://github.com/dm1try/samagotchi/compare/v0.41.0...v0.42.0
[0.41.0]: https://github.com/dm1try/samagotchi/compare/v0.40.0...v0.41.0
[0.40.0]: https://github.com/dm1try/samagotchi/compare/v0.39.0...v0.40.0
[0.39.0]: https://github.com/dm1try/samagotchi/compare/v0.38.0...v0.39.0
[0.38.0]: https://github.com/dm1try/samagotchi/compare/v0.37.0...v0.38.0
[0.37.0]: https://github.com/dm1try/samagotchi/compare/v0.36.0...v0.37.0
[0.36.0]: https://github.com/dm1try/samagotchi/compare/v0.35.0...v0.36.0
[0.35.0]: https://github.com/dm1try/samagotchi/compare/v0.34.0...v0.35.0
[0.34.0]: https://github.com/dm1try/samagotchi/compare/v0.33.0...v0.34.0
[0.33.0]: https://github.com/dm1try/samagotchi/compare/v0.32.0...v0.33.0
[0.32.0]: https://github.com/dm1try/samagotchi/compare/v0.31.0...v0.32.0
[0.31.0]: https://github.com/dm1try/samagotchi/compare/v0.30.0...v0.31.0
[0.30.0]: https://github.com/dm1try/samagotchi/compare/v0.29.0...v0.30.0
[0.29.0]: https://github.com/dm1try/samagotchi/compare/v0.28.0...v0.29.0
[0.28.0]: https://github.com/dm1try/samagotchi/compare/v0.27.0...v0.28.0
[0.27.0]: https://github.com/dm1try/samagotchi/compare/v0.26.0...v0.27.0
[0.26.0]: https://github.com/dm1try/samagotchi/compare/v0.25.0...v0.26.0
[0.25.0]: https://github.com/dm1try/samagotchi/compare/v0.24.0...v0.25.0
[0.24.0]: https://github.com/dm1try/samagotchi/compare/v0.23.0...v0.24.0
[0.23.0]: https://github.com/dm1try/samagotchi/compare/v0.22.0...v0.23.0
[0.22.0]: https://github.com/dm1try/samagotchi/compare/v0.21.0...v0.22.0
[0.21.0]: https://github.com/dm1try/samagotchi/compare/v0.20.0...v0.21.0
[0.20.0]: https://github.com/dm1try/samagotchi/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/dm1try/samagotchi/compare/v0.18.1...v0.19.0
[0.18.1]: https://github.com/dm1try/samagotchi/compare/v0.18.0...v0.18.1
[0.18.0]: https://github.com/dm1try/samagotchi/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/dm1try/samagotchi/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/dm1try/samagotchi/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/dm1try/samagotchi/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/dm1try/samagotchi/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/dm1try/samagotchi/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/dm1try/samagotchi/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/dm1try/samagotchi/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/dm1try/samagotchi/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/dm1try/samagotchi/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/dm1try/samagotchi/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/dm1try/samagotchi/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/dm1try/samagotchi/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/dm1try/samagotchi/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/dm1try/samagotchi/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/dm1try/samagotchi/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/dm1try/samagotchi/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/dm1try/samagotchi/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/dm1try/samagotchi/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/dm1try/samagotchi/releases/tag/v0.2.0
