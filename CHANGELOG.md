# Changelog

All notable changes to samagotchi (the `chi` command) are listed here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/); before 1.0, config
and commands may change between minor versions. How releases are made:
[docs/releasing.md](docs/releasing.md).

## [Unreleased]

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

### Fixed

- `chi update` no longer says running sessions move to the new chi "at idle exit (30 min)": a worker keeps its chi
  until restarted, and idles out only with nothing attached, after `session.idle_exit_minutes` (never with 0). The
  workers row names `chi sessions restart ID` (or `stop` for a worker from before restarts).
- `chi web` no longer leaves exited session workers behind as zombie processes.
- The web's model picker lists a host added to (or changed in) `hosts:` while `chi web` runs, instead of the hosts
  it started with.
- A bundle's model overlay (`tips.<model-key>.md` next to `tips.md`) stays model-only after `chi bundle install`: it
  no longer gets an `index.md` line of its own, which showed it to every model as a memory to read.
  `chi bundle status` reads it `ok (model overlay)` instead of `no-index`, uninstall no longer re-adds its line, and
  `chi bundle build tips.md` brings `tips.md`'s overlays along. An overlay whose base is nowhere, or only among your
  installed memories, installs with a warning. A line an earlier install wrote goes with the bundle's next upgrade.
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

[Unreleased]: https://github.com/dm1try/samagotchi/compare/v0.18.1...HEAD
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
