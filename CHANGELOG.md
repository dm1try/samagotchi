# Changelog

All notable changes to samagotchi (the `chi` command) are listed here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/); before 1.0, config
and commands may change between minor versions. How releases are made:
[docs/releasing.md](docs/releasing.md).

## [Unreleased]

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

[Unreleased]: https://github.com/dm1try/samagotchi/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/dm1try/samagotchi/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/dm1try/samagotchi/releases/tag/v0.2.0
