# Changelog

All notable changes to samagotchi (the `chi` command) are listed here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/); before 1.0, config
and commands may change between minor versions. How releases are made:
[docs/releasing.md](docs/releasing.md).

## [Unreleased]

### Fixed

- Web: switching sessions no longer briefly shows the previous session's "delegated by" link in the info bar.
- The web's `POST /api/sessions/:id/turn` refuses more than 20 images in one message, as a live worker already did.
- A web page joining (or re-syncing with) a live session gets its status and pending question as of the same moment
  as the messages; they could be a step newer.
- The web's answer, dismiss, command and cancel calls fail the same way: a worker that doesn't answer in time is
  504 ("did not answer, so ... was not ..."; cancel said "not running"), a worker running an older chi is 501 with
  how to restart it (an answer said "not running").
- `execute` with a `cwd` now runs in that directory with Gemma and Qwen native tool calls too (the directory was
  dropped and the command ran in the project root).

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

[Unreleased]: https://github.com/dm1try/samagotchi/compare/v0.9.0...HEAD
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
