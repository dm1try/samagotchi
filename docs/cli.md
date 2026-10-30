# CLI and REPL

## Commands

- `chi bootstrap [HOST[:PORT]|URL]` — first setup: find the model server (llama.cpp, OpenAI-compatible or Anthropic Messages), pick the model, send a test request and write config.yml, or add a `hosts:` entry to an existing one (see [First setup](#first-setup))
- `chi` — start a session in a background worker and attach the terminal to it, so the Web UI (or another terminal) can share it (see [Sharing a session](#sharing-a-session))
- `chi -p "your prompt"` — run a prompt, then stay attached
- `chi -p "your prompt" --non-interactive` — run a prompt, print the answer, exit
- `chi --resume <session-id>` — resume a prior session (in its worker)
- `chi --no-shared [--resume <session-id>]` — the plain in-process REPL instead, for this run
- `chi scratch [options]` — a one-time session in the plain in-process REPL, in this folder, that leaves nothing behind (see [Scratch sessions](#scratch-sessions))
- `chi --attach <session-id>` — attach the terminal to a session's worker (e.g. one started from the Web UI), waking one if it has exited
- A session id can be shortened to any unique prefix (like git): `chi --attach 2ea8`. `--resume`, `--attach`, `sessions stop`, `sessions archive` and `sessions delete` take one; an ambiguous prefix lists the sessions it matches.
- `chi web [--port 4567] [--open] [--scope=all] [--start-dir DIR]` — start the Web UI (single localhost port session control plane) on this git project's sessions (`--scope=all`, or a folder in no repo: `/?scope=all`, every session); if a chi web already runs on the port, print (with `--open`, open) its page for this folder and exit. Something else on the port (an older chi web too) exits 1 with "port N is in use"
- `chi web --web-host lan` — the Web UI on your home network too, for your phone: a link with an access token and its QR code (see [chi web on your phone](#chi-web-on-your-phone)); `chi web --new-token` replaces the token
- `chi web --start-dir DIR` (config `web.start_dir`) — the folder chi web starts in, in place of the one you run it in (`~` and a relative path work; chi web never changes its own folder): its page opens on that folder's project (the printed link, a bare `/`, the LAN link and its QR code, the Home Screen app), and a new session from the all view starts there; the header's project chip switches projects. One that isn't a folder exits 1; `--start-dir` without `web` exits 2. A chi web already running in another folder keeps it (the second one says so: restart it to change it)
- `chi web --tunnel tailscale` — the Web UI over https on your tailnet, for your phone anywhere: Tailscale Serve (never Funnel) on this machine's `<machine>.<tailnet>.ts.net` name for this run, the owner your Tailscale login, turned off on exit (see [Tailscale Serve](configuration.md#tailscale-serve-your-tailnet)); `--tunnel` without `web` exits 2
- `chi web push ls [--format json]`, `chi web push rm ID`, `chi web push test [ID]` — the phones chi web pushes to (see [Phone notifications](configuration.md#phone-notifications-web-push)): list them (short id, label, origin, added, last delivery, done turns, last error; `stale` for one made on another public URL than chi web's now: never sent to), remove one, or send a test notification to ID or to every device not stale. chi web need not run; nothing printed holds a device's push address or keys. A usage error exits 2; a store others can read, a corrupt one, an unknown device or a failed test push exit 1. This machine only: `chi --remote X web push` exits 2
- `chi web --web-markdown` — opt in to sanitized Markdown rendering for completed assistant messages, the stage's asking text and a resolved question card's reply
- `chi web --no-web-working-set` — turns the stage view's working set off (on by default; `--web-working-set` turns a config's `web.working_set: false` back on): what each turn brought into the model's context, in the stage and under each finished turn; `?working_set=1|0` on the page URL overrides it (see [The working set](#the-working-set))
- `chi sessions list|stop|restart|archive|unarchive|delete|prune|clean|stats` — manage persisted sessions; `list` shows this git project's, `list --scope=all` every one, a delegated session with `↳ <parent>`, `list --archived` the archived ones too (see [Sessions](sessions.md)). `stats ID` prints a session's cost, tokens and progress, and its own settings (`--set`; a `settings:` line), from a live worker's `GET stats`, else its saved `analytics.json` (`--format json` one object, with `settings`), without running a model turn. A usage error (an unknown subcommand or flag, a flag missing its value, `stop`, `restart` or `delete` with no ids, a bad `list --format` or `--scope`, a `--days`, `--keep` or `--limit` that isn't a whole number) exits 2; an unknown or refused session exits 1
- `chi note [--source NAME] [-m TEXT] (ID|PREFIX)... | --all` — add a context note (TEXT or stdin) to sessions: background the model sees on its next turn; it starts no turn (see [Sessions: Context notes](sessions.md#context-notes))
- `chi broadcast [-m TEXT] [--all] [--dry-run]`, `chi broadcast log [--last N] [--format json]`, `chi broadcast deliver BROADCAST_ID (ID|PREFIX)...` — share one piece of information (TEXT or stdin) with every session it may concern, as a context note from `broadcast` (see [Broadcast](broadcast.md))
- `chi context <add|push|ls|show|refresh|rm|mute|unmute> …` — attach live external text to sessions (a command chi runs every so often, or text pushed in); the model gets a short note when it changes and reads it with `context_read`; `chi context add <URL>` attaches a GitHub PR with the github-pr bundle (see [Attached context](context.md))
- `chi send [-m TEXT] [--image PATH]... [--cut | --queue] (ID|PREFIX)...` — send a message to sessions as if typed there: a turn starts (or a running one takes it at its next step; `--cut` asks it to cut long thinking for it; `--queue` runs it as a turn of its own after the running one, and `--queue --wait` waits for that turn's own answer); piped stdin goes above `-m` as quoted context, and `--image` attaches images (see [Sessions: Sending a message](sessions.md#sending-a-message)); `--new` starts a session with it instead (`--new --continues ID|last:ID` the next link of that session's chain, see [Session chains](sessions.md#session-chains)), and `--wait` prints the answer (`--wait ID` with no message waits for the next reply without sending — to an idle session whose last turn already ended, that ended turn's reply or end comes back; `--wait --turn T ID` with no message waits for exactly turn T, whether running, queued or last ended; `--format json` includes its `turn_id` when known, for waiting again after exit 3 or 4; exit 3 a question waits, its options on stderr; exit 4 `--timeout` passed with the turn still running; see [Starting a session](sessions.md#starting-a-session))
- `chi answer ID --question QID (--option N|LABEL)... [--text T] [--timeout S] [--format json]` (or `--dismiss`) — answer the question a session waits on (the one `chi send --wait` exited 3 with), then wait and print what comes next as `chi send --wait` does: the reply (0), the next question (3), still running after `--timeout` (4). `--option` is 1-based or the label, repeated on a multi-select question; `--text` is free text, or a Deny's reason; `--dismiss` leaves it unanswered and the model finishes its reply. A question no longer open (the web answered first) isn't answered again: it waits for that turn's reply. An option the question doesn't offer exits 2; a worker that is gone exits 1 (`send the task again: chi send --wait -m "…" ID`). What a parent may pick follows `guardrails.parent_answers`, or the session's own `parent_answers` when stricter (`soft`, the default: a deny, a plain answer, Continue and "Allow once"; `standard`: no allow; `hard`: no Continue either), never a wider scope or an allow on chi's own config; a refused pick exits 1 with what to answer instead (a convention, not a security boundary; see [Guardrails](guardrails.md#answers-from-a-parent-agent))
- `chi remote add NAME URL [--token-file F | --token-stdin]`, `chi remote ls`, `chi remote rm NAME` — the other machines whose chi web the session commands reach with `--remote NAME` (see [Remote sessions](#remote-sessions))
- `chi review FILE… [--dir DIR] [--model M]`, `chi review --from ID [FILE…]` — start a review session to invite participants to: for files of a project, or as a review of a working session that starts from its recap, not its transcript (see [Review sessions](#review-sessions))
- `chi share ID --name NAME [--identity EMAIL] [--agent] [--expires 3d] [--cap 2]`, `chi share ls [ID]`, `chi share cap ID P DOLLARS`, `chi share revoke ID [P] | --all` — invite a participant to a session through chi web on the LAN (read-only review turns in a review session, pair turns that act under your guardrails in a working session) (a link of their own, 7 days, a $2 spending cap), list them, change one's cap, revoke them (see [Participants](#participants))
- `chi --remote NAME send|answer|note|context|sessions|share|review …` (or `CHI_REMOTE=NAME`) — those commands on that machine's sessions, through its chi web (see [Remote sessions](#remote-sessions))
- `chi --remote NAME --attach ID` (`--resume ID`, `--dir DIR [-p TEXT]`) — the attached TUI on a session of that machine (see [Remote sessions](#remote-sessions))
- `chi memory ls [--scope project|system] [--format text|json]` — the memories of both scopes (this folder's project first), one row each: scope, name, size, date, `from <bundle>`, the index description and its model overlays; `chi memory rm NAME [--scope project|system]` removes one as `memory_write` with `remove: true` does: its file and model overlays go to the bundle trash (the line names the dir; `chi bundle trash` lists and empties it) and its index line is dropped. NAME in both scopes without `--scope` exits 2 naming both; a missing NAME or a bundle's memory (`chi bundle uninstall` removes it) exits 1 (see [Memory: Listing and removing from the shell](memory.md#listing-and-removing-from-the-shell))
- `chi desktop install|upgrade|uninstall|status` — the macOS "Send to chi" helper: a Service and a ⌃⌥⌘N hotkey that send text or images to a session (live, stopped or new) as a message (⏎, a turn runs) or a context note (⌘⏎) (see [Desktop helper](desktop.md))
- `chi models [--format text|json] [--timeout S] [TEXT]` — list the models every configured host offers, as the names `--model` takes (see [Listing the models](#listing-the-models))
- `chi self` — print version, source dir (checkout or installed gem), config/memory/session paths, model/host and bundles. Run by a session's `execute`, the `model` row (and host, loop, profile, thinking, served model) is **that session's** model, labelled `(this session <id8>; default …)`; elsewhere it is the default, `(default)`. `model key` is the memory overlay key (`<name>.<key>.md`), and `model notes` the model notes a prompt of that model loads (`model_notes_deepseek (system, 612 chars)`, `none`; inside a session its `--mute` list is left out). `chi self --model` prints only the model a new session starts on, an alias resolved to its target (the desktop helper's hint)
- `chi update [--dry-run] [--to VERSION] [--json] [--no-gem] [--no-bundles] [--no-desktop]` — update an installed chi: the gem, the system bundle, the shipped bundles you installed and the desktop helper, in one table (see [Updating](#updating))
- `chi home`, `chi home set [--ruby PATH]`, `chi home doctor` — the chi home: the one Ruby (and its gem path) every chi launch boots, whoever launches it. `chi home` shows it (its Ruby, the newest chi in it, gem home and path, `mise`, when and by which chi it was set, and the chi you ran when that is another one; exit 1 with the problem when it can't boot chi), `set` records this chi's Ruby and gem path (or `--ruby PATH`'s own; it must have samagotchi), `doctor` checks it and what should follow it, one row each with `ok`, `warn` or `fail` and what to run (exit 1 on a `fail`; see [Checking it](configuration.md#checking-it-chi-home-doctor)). At a terminal, a chi on another Ruby than the home's says so in one dim line a day. This machine only (see [The chi home](configuration.md#the-chi-home))
- `chi bundle install|upgrade|uninstall|status|diff|list|build|trash|new|test|check` — manage memory bundles (see [Bundle hooks](hooks.md#bundle-hooks-unified-workflow-bundle)); `list` shows the installed ones and the ones shipped with chi, which `install <name>` installs; `core` and `dev` are profiles that install a set of them (see [Bundle profiles](memory.md#bundle-profiles-core-and-dev),  [Guardrails](guardrails.md), [Plugins](plugins.md#the-btw-bundle), [the mcp bundle](plugins.md#the-mcp-bundle) [the loop-guard bundle](plugins.md#the-loop-guard-bundle), [the check-in bundle](plugins.md#the-check-in-bundle) and [the skills bundle](plugins.md#the-skills-bundle)). `trash` lists and empties the bundle trash (moved files from uninstalls/upgrades). A usage error (an unknown subcommand or flag, a missing argument, a bad `build --scope`) exits 2, as for the other subcommands. Plain `chi` and `chi web` exit 1 on an unknown flag, a flag missing its value or a stray argument. `new`, `test` and `check` are for writing one: see [Writing a bundle](#writing-a-bundle-new-test-check)

- `chi guardrails replay [--dry-run] [--threshold T] [--model M]` — seed System 1's record from the approvals this machine's sessions already answered: each ask is judged by the configured model and written to `guardrails/judgments.jsonl` with the answer the user gave, then a per-rule table prints (asks, allowed, denied, would-be auto-allows, false allows, asks with no judgment). A parent agent's answer is not the user's: only its deny is replayed, and only where the parent could have allowed. `--dry-run` judges without writing, `--threshold` overrides `guardrails.system_one.threshold` for the table, `--model` the configured model for this run. Exit 2 when `guardrails.system_one.mode` is off or no `host` is set; a usage error exits 2 (see [System 1](guardrails.md#system-1-experimental))
- `chi toolkit report [--days N]` — grade toolkit suggestions: the kit on mode would have run (the suggested kit when it would have applied it, else the default; an on-mode line's `did` says what it ran) against the tools the session called from that turn on (only that turn when the toolkit was chosen since), `call_tool` targets included, for both the chat and the raw-prompt loop. Each is *covers*, *short of a tool* (naming the tools), *wider than needed* (a narrower kit offered in the same ask would also have covered) or *ungradable* (calls it can't read back); then a per-kit tally with what on mode would have done. Includes archived sessions and caps the report at 14 days and 500 sessions. Reads `toolkit_suggestions.jsonl` (each ask logs every offered kit's rules, expanded against the called tools here); it never runs the model or changes a session. Local only; `--days` must be a positive whole number.

- `chi bundle try PATH -p TEXT [options]` — install a bundle in a temporary, filtered sandbox, run one real model turn,
  and print its trace (see [Trying a bundle](#trying-a-bundle)).

### First setup

`chi bootstrap TARGET` names the model server and writes the config for it:

```sh
chi bootstrap 192.168.1.29:8081          # host:port (an IP or localhost: port 8080 when none; a domain: https 443, then http 80)
chi bootstrap https://openrouter.ai/api/v1 --key-env OPENROUTER_API_KEY
chi bootstrap https://api.anthropic.com --key-env ANTHROPIC_API_KEY
chi bootstrap                            # try localhost 8080, 11434, 1234, 8000
```

- **What it is.** llama.cpp's `/props` answering means the native API (no
  `api:`); otherwise `GET /v1/models` answering means an OpenAI-compatible
  server (`api: openai`). Only when that list is refused with 400, 401 or 403
  does chi ask Anthropic's way (`anthropic-version`, the key in `x-api-key`,
  once more as Bearer after a 401/403): a list there means Anthropic's
  Messages API (`api: anthropic`, the url without `/v1`; `auth: bearer` when
  only Bearer worked). A server that serves both, such as Splash, stays
  `api: openai`. Fireworks (its host, or model ids under `accounts/fireworks/`)
  on the Messages API gets `dialect: fireworks`; direct Fireworks is found as
  OpenAI-compatible first and stays `api: openai`, with a line saying
  `--api anthropic` takes its Messages API instead. `--api openai|anthropic`
  and `--dialect standard|fireworks` (which implies `--api anthropic`) skip the
  detection. A URL with a path is the API base as given
  (`…/api/v1`); a domain without a scheme is tried over https, then http.
  Each request is tried once, with 5 s timeouts, so a refused port answers
  at once.
- **The key.** A server that answers 401/403 wants an API key: `--key-env VAR`
  names the environment variable holding it (on a terminal chi asks for the
  name); on macOS a key only the login Keychain holds under that name counts
  (docs/configuration.md, "API keys from the Keychain"). Only the variable's
  name is written, never the key.
- **The model.** One model is taken; with several, `--model ID` picks one
  (a terminal gets a numbered list, a script the ids and exit 2). A llama.cpp
  server also shows its context size and the prompt profile its chat template
  matches.
- **The test.** One short chat request ("test: answered in 1.1 s"; `POST /v1/messages`
  on `api: anthropic`); `--no-test` skips it. A failed test still writes the config,
  says so and exits 1. A server found as OpenAI-compatible whose `/chat/completions`
  answers 404 gets the hint `try --api anthropic` (a gateway's Messages url that also
  lists the OpenAI way).
- **The file.** With no config.yml it writes a small commented one:
  `default.model` as `<host>:<model>` and one `hosts:` entry named `local`
  (localhost), `lan` (an IP) or after the domain (`openrouter`); `--name`
  sets it. When that name is taken (or a model id starts with it), chi picks
  `name-2` and says why, with `--name` to choose another. An existing file is
  left as it is apart from the new entry, added
  at the end of its `hosts:` block (it gets a `hosts:` block, with a
  `default` entry for its `server:` first, when it has none), after a backup
  to `config.yml.bak-<time>`. `default.model` is set only when the file has
  none. A server already in the file writes nothing; a file in YAML flow style
  or with anchors gets the lines printed to paste instead. `--dry-run` shows
  what it would write.
- **The bundles.** Unless writing the config failed, it installs the system
  bundle and the `core` profile (loop-guard, check-in, guardrails, slow-commands, agents-md, cost-cap, work-cap), one line
  each; on a terminal it then asks `Also install dev (known-names, mcp, btw,
  skills, source-links, github-pr, coordinator, claude-peer, codex-peer, ruby, model-notes)? [y/N]`. Run again, it installs nothing new: a bundle
  you uninstalled stays out ([Bundle profiles](memory.md#bundle-profiles-core-and-dev)).
  A bundle that fails to install makes the exit 1. `--dry-run` says what it
  would install.
- **Markdown in chi web.** Then, on a terminal and unless config.yml has
  `web: markdown: true` already, it asks `Render answers as Markdown in chi web? [Y/n]`
  (a closed stdin is no). Yes installs the `commonmarker` gem when it is
  missing (`gem install commonmarker` through the Ruby chi runs on; it can take
  a while where no precompiled build exists) and writes `web: markdown: true`
  into config.yml, its comments kept ("web: markdown on (config.yml)"). A failed
  install says so in one line with gem's last output line, writes nothing and
  leaves the exit code as it was. Without a terminal it doesn't ask; a new
  config's next steps then name `chi web --web-markdown`. `--dry-run` says it
  would ask.

### Writing a bundle: new, test, check

The loop for a bundle you're writing (the whole path: [bundle-authoring.md](bundle-authoring.md)):

- `chi bundle new NAME [--dir DIR]` writes `DIR/NAME/` (default `./NAME`; refused when it exists; `NAME` is
  `a-z` first, then `a-z`, `0-9`, `-`, `_`, as a slash command): `manifest.yml` (a block-form `plugin:` entry with
  its sha filled, `requires_chi: ">= <this chi>"`), `plugin.rb` (a `/NAME` command and an `after_tool_call` hook),
  `test/NAME_test.rb` (Minitest on the bundle test kit, passing as written) and `README.md`, then prints the next
  steps. Exit 1 when it refuses, 2 for usage.
- `chi bundle test [PATH] [-- ARGS]` runs the bundle's tests on the Ruby and the lib chi runs on, outside any
  Bundler env: `test/**/*_test.rb` on Minitest (`-r samagotchi/testing/minitest`), or else `spec/` on RSpec with
  the kit (`--options /dev/null -r samagotchi/testing/rspec`, as `rake bundles:specs`). `ARGS` go to the runner
  (`-- -n /name/`). Exit status: the tests'; 1 with no tests; 2 for usage, or when minitest / rspec doesn't load on
  chi's Ruby (minitest is one of chi's gems; rspec is optional). The tests run the bundle's code as written, with
  your environment (the kit sandboxes each test's HOME and XDG dirs, not the process).
- `chi bundle install --dev PATH` installs the bundle in the local directory `PATH` (not a git URL, archive or name:
  exit 2) as a link to it: its plugin, hooks, rules and scripts are `PATH`'s own files, so an edit applies at the
  next worker or `chi web` restart with no re-install, and their sha256 isn't checked, for this bundle only (the
  record says `dev`; every other bundle is checked as before). Its memories are copied at install. `chi bundle
  status` shows `NAME vX dev → /abs/path`. `chi bundle upgrade NAME` refuses it (it follows its source already; to
  leave dev mode: `chi bundle uninstall NAME`, then `chi bundle install` without `--dev`), as does a plain install
  over it, and `--dev` over a normal install. `uninstall` removes the links and the record, never `PATH`'s files.
  `check PATH` and `test PATH` are unchanged.
- `chi bundle check [PATH] [--fix] [--set KEY=VALUE]` (PATH defaults to `.`) checks it as an install takes it, one
  finding per line, `error|warn|info CODE file[:line]: message (fix: hint)`, then `ok|failed: N errors, N
  warnings`. Exit 1 on any error, 0 otherwise, 2 for usage. It installs and loads the bundle in a temp sandbox
  (HOME, config and state), not in yours, but in chi's own process: the plugin's and hooks' code runs as written,
  so run it (and `test`) on code you'd install. The codes, in order: `manifest` (a parse error, verbatim; the run
  stops), `missing-file`, `unlisted` (warn: a file an install leaves out, by `MemoryFiles`' rules, so a README
  isn't one), `sha` (a stale or placeholder sha, or a plugin / hook / script entry with no sha line; `--fix`
  rewrites the first two and prints `fixed sha FILE → sha256:…`), `requires-chi` (this chi doesn't satisfy it:
  error; missing on a bundle with code: warn), `requires-chi-floor` (warn: the plugin calls an API newer than the
  oldest chi `requires_chi` admits, from `Plugin::Api::SINCE`), `trust` (warn: `trust_level: reviewed|trusted` on a
  bundle chi doesn't ship), `clash` (warn: a name chi ships, or one installed from elsewhere; the sandboxed install
  then forces), `install` (each Installer warning, a `needs` one as warn, and each plugin or hook load failure at
  the source `file:line`; skipped while a placeholder sha is unfilled), `registered` (info: each command, tool,
  hook with its priority, init, toolkit, tool source and peer source), `hook-event` (warn: a `chi.on` event chi
  never fires), `boundary` (warn: a `Samagotchi::` name outside "Stable for bundles"; a shipped bundle's listed
  exceptions aside) and `tests` (info: how to run them, or "no tests"). `--set KEY=VALUE` (repeatable, typed as
  `chi --set`) goes to `bundles: <name>:` in the sandbox's config.yml.

### Trying a bundle

`chi bundle try PATH -p TEXT [--model NAME] [--memory NAME] [--mute NAME] [--toolkit NAME] [--thinking LEVEL]
[--set KEY=VALUE] [--json] [--keep] [--timeout SECONDS]` installs and runs the bundle in a temporary config, state
and work directory, then prints a trace of tool calls, notices, questions, the answer, token totals and cost. The
child's working directory is outside your repository, so project memories and `AGENTS.md` / `CLAUDE.md` files in
your current directory aren't loaded. Your hosts, API-key environment variables, Keychain and other runtime
settings are retained, but your configured bundles, hooks, guardrails, memories, appended system prompts and
attached context sources are not copied. Chi installs its shipped `guardrails` and `cost-cap` bundles for the run;
the default cap is $1 and `--set cost-cap.cap=N` changes it. Other `--set KEY=VALUE` entries are typed config
values under `bundles: <tried-bundle>:`; unlike `chi --set BUNDLE.KEY=VALUE`, they are not session settings and
aren't checked against `session_settings:`. `--memory` and `--mute` accept comma-separated names and repeat.
`--timeout` defaults to 300 seconds. An ask that no one can answer or a guardrail denial is traced and warned
about without changing the child's exit status; hook questions made with `ctx.ask_user` are invisible in
non-interactive mode. `--keep` retains the temporary sandbox and prints its path and debug log. `--json` writes
one experimental JSON object to stdout and human trace lines to stderr; its keys are `session_id`, `exit_code`,
`answer`, `tools` (`index`, `name`, `args`, `status`, `duration_ms`), `notices`, `cards`, `questions`,
`interactive_blocked`, `used_memories`, `tokens` (`prompt`, `completion`), `cost`, `cost_is_estimate`, `model`,
`sandbox`, `denied` (1-based tool indexes), `stderr_tail` (last 4,000 characters) and `timed_out`. A run past
`--timeout` is interrupted like a Ctrl-C and still prints the trace it got to, with `timed_out: true` (text output:
the trace lines, then `timed out after N seconds` on stderr). That turn keeps its tool calls, as a Ctrl-C does, so
they show with their `args`; a call the interrupt cut short has status `interrupted`. Exit status: 2 for usage,
1 for install/turn failure or timeout, 130 for Ctrl-C, otherwise the child's status.

`try` runs the bundle's code and the model's tools with your real HOME, account and keys. Its temporary working
directory and filtered config do not make untrusted code safe: a plugin, hook or model tool can still access files
and services available to your account. Use it only for code you trust.

Tool arguments are capped to 60 characters in the text trace and 200 in JSON; the text trace shows at most 10 answer
lines, while JSON includes the full answer. Either may contain secrets.

### Listing the models

`chi models` asks every host in `hosts:` for its models, in parallel, and prints the names `--model` (and
`chi send --new --model`, `/model`) takes, one per line:

```sh
$ chi models
gemma-4                          # the default (default.model), first
splash:incoai/Qwen3.8-27B-Splash # another host's id: host:id
openrouter:qwen/qwen3.8-27b
small -> box:gemma-small         # an alias and the ref it resolves to
$ chi models qwen                # only the names containing "qwen" (any case)
```

- A host's ids declared under `hosts.<name>.models` (see
  [configuration](configuration.md#models-a-host-serves-but-doesnt-list)) come first under that host, listed or not,
  as plain names like any other. They stay when the host fails, and its stderr warning says so
  (`chi models: box: connection refused (its declared ids are still listed)`).
- A default-host id is bare, except one with a `:` (`qwen3:8b`), which is written `<host>:qwen3:8b` so it can't
  read as a host name. An id that an alias of the same name hides is left out.
- Each run lists anew (no cache); `--timeout S` caps the wait for the hosts (default 4 s). A host that fails or doesn't
  answer in time is noted on stderr (`chi models: box: no answer in 4 s`).
- `--format json` prints one object: `default` (and `default_typed` when it was set as an alias), `default_host`,
  `models` (`name`, `host`, `id`, and `configured: true` on an id declared under `hosts.<name>.models`,
  `unavailable: true` too when that host failed to list its models), `aliases` (`name`, `ref`, `host`) and `warnings`. The desktop helper's model
  chooser reads it.
- Exit 0 when any host listed its models, 1 when none did (the default and declared names still print), 2 on a
  usage error.

### Updating

`chi update` brings an installed chi up to date and prints one table:

```
component      from   to     status
chi (gem)      0.2.0  0.3.0  updated
system bundle  0.2.0  0.3.0  updated (kept your edits in identity.md: chi bundle diff samagotchi-system identity.md)
btw            0.1.1         up to date
known-names    0.1.0  0.1.1  updated
core           0.1.0  0.2.0  updated (+ new-bundle)
infra_tools    1.0.0         skipped (not from chi)
Chi Helper     0.2.0         up to date (launch file refreshed)
workers                      2 live on 0.2.0: they keep it until restarted (chi sessions restart 2ea8c1f0 91b0d2aa); or they idle out after 30 min with nothing attached
Also shipped, not installed: dev (mcp, skills, source-links) (chi bundle install NAME)
done
```

- `--to VERSION` installs exactly that gem version instead of checking for the
  newest release. It must be newer than the running chi; an equal or older
  version is refused.
- `--json` writes the component rows as one JSON array on stdout. Each row has
  `component`, `from`, `to`, `status`, `failed` and `kept` fields; `kept` is an
  array of edited filenames. Install progress is written to stderr.

- **chi web update notices.** By default, chi web checks RubyGems about 30
  seconds after it starts and every 24 hours after that. Once a stable release
  is at least 24 hours old and newer than both the running chi and the newest
  installed one, the owner's page shows its version and a link to that
  RubyGems release. When the install is unblocked, **Update** installs that
  exact release and opens a progress sheet with component results and any
  edited files kept. A blocked install instead shows the reason and a command
  to copy. After installation, the notice and the sheet's footer offer
  **Restart workers** and **Restart chi web**; the sheet reports worker results
  (a busy worker's refusal says what holds it) and waits for chi web to
  reconnect, and keeps the other restart in reach. The notice is once per version per browser: a reload or a chi
  web restart doesn't repeat it. `update.notify: off` disables checking;
  `update.check_hours` and
  `update.min_age_hours` tune the interval and release age (see
  [configuration](configuration.md#all-settings)). If the gem can't be updated
  in place, the notice gives the blocker and its command instead.

- **The chi home.** With a [chi home](configuration.md#the-chi-home), a `chi
  update` started on another Ruby first says `updating the chi home (<ruby>)`
  and runs the home's chi update instead (the version check, `--to` and the
  rows are the home's); chi web's **Update** runs the home's too. Without
  one, the first `chi update` (not `--dry-run`, not under Bundler, and only
  once its own checks passed) records one: of the desktop helper's Ruby and
  the Ruby it runs on, the one with the newer chi, and says `chi home set to
  <ruby> (chi home set to change)`.
- **The gem.** It asks rubygems.org for the newest samagotchi (5 s timeout)
  and, when that's newer, runs `gem install samagotchi` with the gem command
  of the chi home's Ruby, into the home's gems (`GEM_HOME`/`GEM_PATH` set to
  the home's for that one command, and `mise`'s folder on its PATH when the
  home names one, for mise's reshim plugin); without a home, the Ruby chi runs
  on (the real one, not a mise/rbenv/asdf shim; a chi installed under another
  Ruby is a separate install it doesn't touch). Then it hands over to the new
  chi, which does the rest and prints the table. Old
  versions stay installed: running workers and an old `chi web` still load
  files from them, so a `gem cleanup` while they run breaks them (a
  `LoadError`, missing web assets); restart them first. A chi web, an
  attached terminal or a session worker started before the update may not
  reach a worker the new chi starts (403 `bridge_secret`: its Bridge asks for
  a secret they don't send; an older worker's delegate child is one): restart
  chi web, re-attach, and restart the older workers (`chi sessions restart
  ID...`, as the `workers` row says). Offline, the row says
  "couldn't check" and the rest still runs; a failed install fails the row
  and the rest runs on the current version. Under Bundler (`bundle exec`)
  the row says `bundle update samagotchi` instead.
- **The system bundle** normally updated itself when the new chi started;
  the row says what it did.
- **Shipped bundles**: each one you installed from chi (`chi bundle install
  NAME`) is upgraded when chi ships a newer version. Memory files get the
  3-way merge of `chi bundle upgrade`: an unedited file is updated, an edited
  one that the new version also changes is kept, and the row says so (`chi
  bundle diff NAME FILE` shows it; `chi bundle upgrade NAME --force` takes the
  bundle's). Hooks, rules and the plugin are replaced; an edited one didn't
  load anyway (its sha no longer matched) and the row says it was replaced.
  A bundle of the same name from elsewhere (a zip, git) is skipped ("not from
  chi"), a newer installed one is left, one whose new version needs a newer
  chi is skipped, and bundles you didn't install stay uninstalled.
- **Profiles** (`core`, `dev`): an installed one installs the bundles a new
  chi added to it (`updated (+ name)`), even at the same version, and retries
  one that failed before; one you uninstalled stays out. See [Bundle
  profiles](memory.md#bundle-profiles-core-and-dev).
- **The desktop helper** (macOS) is rebuilt and restarted only when its Swift
  sources changed; otherwise only its launch file is refreshed (a newer chi or
  other terminal settings). It keeps the Ruby, chi and PATH the helper runs (a
  PATH is filled in only when the file has none): `chi desktop install --force`
  and `chi desktop upgrade` bake this shell's (the chi home's boot, when there
  is one). A refresh drops `RUBYLIB` from the launch file, and `GEM_HOME`/`GEM_PATH`
  once it boots the chi home. A helper whose Ruby or chi is gone
  is reported as failed, naming `chi desktop install --force`. See
  [Desktop helper](desktop.md).
- **Running processes** are reported, never stopped. A live worker keeps its
  chi until it is restarted: `chi sessions restart ID` (one from before
  restarts: `chi sessions stop ID`, and the next prompt starts it on the new
  chi); it exits on its own only when nothing is attached (no web tab, no
  terminal, no reminder) and `session.idle_exit_minutes` pass (never with 0).
  A new or woken worker always starts on the newest chi installed. A `chi web`
  on `web.port` running an older chi needs a restart (Ctrl-C, then `chi web`):
  its page says so too. One from before workers started on the newest chi
  also starts its new sessions on its own version until then (the row says so).

`--dry-run` shows the table with "would update" and changes nothing. It is
this version's view: bundles that only a newer gem ships newer show up once
that gem is installed (the real run installs it first and hands over).
`--no-gem`, `--no-bundles` and `--no-desktop` leave a part alone for one run;
`update.gem`, `update.bundles` and `update.desktop: false` in config.yml turn
one off for good. It exits 0 when nothing failed (kept edits and skips are
fine), 1 when a part failed, 2 on a usage error. A second run changes nothing
and ends with "everything is up to date".

From a checkout it refuses (`git pull`, or `chi bundle upgrade NAME` for one
bundle). After a gem update, the first interactive start of the new version
(`chi`, `chi web`; not `-p` or `--non-interactive`) says in one line when
bundles or the helper can be updated.

## Flags

Samagotchi exposes one flag that feeds a prompt (`-p`, `--prompt`) and one that
controls exit behavior (`--non-interactive`); `--resume` composes with both.
Every flag takes its whole name, as the subcommands' flags do: an abbreviation (`--verb`, `--mem x`) is an
invalid option (exit 1).

| Flag | Purpose |
|------|---------|
| `-p`, `--prompt TEXT` | Feed `TEXT` as the first turn (also prefill-equivalent; `-p` feeds **and** runs). |
| `--non-interactive` | Run a single turn then exit the REPL (sets a high iteration cap; implies `--no-interrupt`). Harmless no-op when given without `-p`. |
| `--resume SESSION_ID` | Load a prior session's history instead of creating a fresh one. |
| `--shared` | Run the session (new, or `--resume`'s) in a background worker and attach to it: the default, and the way to get it when `session.shared` is off. See [Sharing a session](#sharing-a-session). |
| `--no-shared` | Run the plain in-process REPL for this run. |
| `--attach SESSION_ID` | Attach to a session's worker, waking one if it has exited. |
| `--remote NAME` | Before a session command (`chi --remote studio send …`) or the run flags (`chi --remote studio --attach ID`, `--resume ID`, `--dir DIR -p TEXT`): run it against that remote's sessions, through its chi web; beats `CHI_REMOTE`. Commands and flags that run on this machine only exit 2. See [Remote sessions](#remote-sessions). |
| `--dir DIR` | With `--remote`: a new session's folder on that machine, its absolute path (required for a new session there). Without `--remote` it exits 2: cd there instead. |
| `--model NAME` | Use this model for the run (overrides the configured default and a resumed session's model). |
| `--thinking LEVEL` | This session's own thinking level: `off`, `low`, `medium` or `high`, saved in the session and first in the order (`default` unsets it). On `--resume` or `--attach` it is set at once, through a `/thinking` on an attached worker. With `chi web` it is instead the default for the sessions its workers run, below a session's own (as env `SAMAGOTCHI_THINKING_LEVEL` is). See "Thinking" in configuration.md. |
| `--toolkit NAME`, `--tool NAME`, `--no-tool NAME` | A new session's toolkit, the tools its prompts declare: `full` (every built-in), `lean`, `child`, one of config's `toolkit.kits` or a bundle's (without `--toolkit`: config's `toolkit.default`), with tools declared on top of it (`--tool`) or left out (`--no-tool`); both repeatable, a comma list too. Saved in the session as given; a respawned worker, a fork and a continue keep it. Ignored with `--attach`/`--resume` (one line, as `--memory`); `/toolkit` changes it. Not on `chi web` (config's `toolkit.default` covers its sessions). See [Toolkits](configuration.md#toolkits). |
| `--parent-answers LEVEL` | A new session's own `guardrails.parent_answers` (`hard`, `standard` or `soft`): what a parent agent may answer on its questions. It may only tighten config.yml's: the stricter of the two applies, and a looser one is saved as given with a warning (`--parent-answers soft is looser than config.yml's guardrails.parent_answers: standard; standard applies`). Saved in the session; a respawned worker, a fork and a continue keep it, a `delegate` child takes its parent's. Ignored with `--attach`/`--resume` (one line, as `--toolkit`); refused with `chi web`. Only you loosen it: `/parent-answers` in the terminal or the web. See [Guardrails](guardrails.md#answers-from-a-parent-agent). |
| `--set KEY=VALUE` | A setting for a new session (repeatable; a later one of the same key wins). A core key a session may set (`recap.enabled`, `recap.sentences`) is typed by the key and goes first, over the CLI, env and config.yml: `--set recap.enabled=false` turns the idle recap off for this session; a value it doesn't take (`recap.enabled=maybe`) or a key no session sets (`guardrails.mode`) is an error, exit 2 (see [Per-session settings](configuration.md#per-session-settings)). Any other name is a bundle's `BUNDLE.KEY`, laid over config.yml's `bundles: <bundle>:` in what the bundle's plugin reads (`ctx.settings`): `--set cost-cap.cap=3`. The value is typed simply: an integer (`3`, `-1`) or a decimal (`2.5`, `.5`, `1e1`) is a number, `true`, `yes` and `on` are true, `false`, `no` and `off` are false (any case, as in config.yml), anything else stays the text as given (`010`, `0x10`, `3:30`, `y`, `null`), and so does every value of a key the manifest types `string`. For cost-cap, `0`, a negative number or `off` is no cap. Only a key the installed bundle's manifest lists in `session_settings:` is taken, with a value of the type it gives the key: a bundle that isn't installed (or whose plugin doesn't load), a key it doesn't list (a record installed before the bundle listed it says to run `chi update` or `chi bundle upgrade NAME`), a value of another type (`--set cost-cap.cap=five`), or another shape (`--set foo`, `--set a.b.c=1`) is an error naming what it takes, exit 2, nothing started. Saved in the session; a respawned worker, a fork and a continue keep it, a delegate child doesn't. Ignored with `--attach`/`--resume` (one line, as `--toolkit`); refused with `chi web`. See [Per-session settings](plugins.md#per-session-settings). |
| `--profile NAME` | Prompt profile (`qwen36` or `gemma4`) for every model in this run, over config and the server's template (same as `--model-profile`, env `SAMAGOTCHI_MODEL_PROFILE`). See "Prompt profile" in configuration.md. |
| `--memory NAME` | Preload a memory entry into the system prompt (repeatable; a comma list too). Merged under the config.yml `memories:` baseline. Works attached: the list is stored on the session, so its worker builds the same prompt on every respawn. |
| `--append-system-prompt FILE` | Put `FILE`'s text into the system prompt, after AGENTS.md and before the memory indexes (repeatable; relative to the shell's directory). Added after the config.yml `append_system_prompt:` list. A missing or unreadable file is an error, exit 1. Saved in the session, so a respawned worker, a fork and a continue keep it; ignored with `--attach`/`--resume` (one line, as `--memory`). See [Appended prompt files](configuration.md#appended-prompt-files). |
| `--mute NAME` | Hide a memory from this session (repeatable; a comma list too): its index line is not in the prompt, `memory_read` refuses it, the identity auto-load skips it, and it is dropped from the preloads (config baseline or `--memory`). A name matches in both scopes (`gh-helper`, `project/gh-helper` and `gh-helper.md` all hide `gh-helper`). Nothing on disk changes. See [Muting a memory](#muting-a-memory). |
| `--llm-context LAYERS` | This session's own LLM context strategy: `none`, or layers such as `stale` or `stale,forget` (comma, space or `\|` separated). Saved in the session, before the model's `llm_context_strategy`. With `--resume` it is set on the resumed session; on an attached or resumed worker it runs as `/llm-context` before the first prompt (after `--model`'s `/model`). A value that isn't one is an error before anything starts. See "LLM context: a session's own strategy" in configuration.md. |
| `--llm-context-apply RULE` | This session's own apply rule: `payoff`, `next_request` or `turn_end`. |
| `--llm-context-budget TOKENS` | This session's own context budget: `64000`, `64k` (4k to 10M), or `off` (wins over the model's budget). |
| `--no-interrupt` | Raise the tool-call limit to 1000 iterations for long tasks. |
| `--no-default-input` | Skip prefilling the first REPL line from `SAMAGOTCHI_DEFAULT_INPUT`. |
| `-v`, `--verbose` | Log at debug level (raw LLM responses, tool call/result payloads) and print every log record to stderr too. |
| `--version` | Print `chi <version>` and exit (`chi self` shows it with the paths). |

Every setting in the config registry (`lib/samagotchi/config.rb`) that exposes a CLI
flag also works as `--kebab-case VALUE`, e.g. `--server-host`, `--server-port`,
`--read-truncate-at-bytes`; an on/off setting is `--[no-]kebab-case` with no value
(`--context-status`, `--no-context-status`). `chi --help` lists them all.

**Which loop runs.** There is no backend flag: the model's host decides. A host with
`api: openai` in config.yml is driven through the OpenAI chat API (streamed; a remote
provider via `url:` and `api_key_env:`); every other host gets chi's own raw-prompt loop. `/model` and `--model host:model` switch hosts, and
the loop with them. See [Configuration](configuration.md) (`hosts:` and `api:`).
`--backend`, `SAMAGOTCHI_BACKEND` and a `backend:` key were removed (`backend:` warns
as an unknown key).

### Entrypoint scenarios

| Command | Behavior |
|---------|----------|
| `chi` | Start a fresh session in a worker and attach to it. |
| `chi -p "refactor this"` | Start a session in a worker, send the prompt, **stay attached**. |
| `chi -p "refactor this" --non-interactive` | Run one turn in this process, save, **exit** (no REPL, no worker). |
| `chi --non-interactive` | Harmless no-op exit; no session created, no error. |
| `chi --resume ID` | Resume session `ID` in a worker (or join the worker already running it) and attach. |
| `chi --resume ID -p "next step" --non-interactive` | Resume `ID`, run the prompt, save, exit. |
| `chi --resume ID -p "next step"` | Resume `ID`, send the prompt, **stay attached** to that session. |
| `chi --no-shared [...]` | The same, in the plain in-process REPL. |
| `chi scratch [-p ...] [--non-interactive]` | A new session in the plain REPL, deleted when it ends. |

Notes:

- Attached `chi -p …` with stdin not a terminal (a script, an agent's shell)
  leaves when its input ends and the turn is done. Exit status: 0 the turn
  ended, 3 a question or an approval waits for an answer (stderr gets the
  whole question as `chi send --wait` prints it, with the
  `chi answer ID --question QID --option N` command; the worker keeps it
  open, and `chi answer` or the web answers it), 1 the turn failed, ended
  with no answer (stderr: `chi: the model gave an empty answer`, as with
  `--non-interactive`) or the worker went away. For a
  script, `chi send --new --wait` is the better entry point: stdout holds the
  answer alone (see [Starting a session](sessions.md#starting-a-session)).
- `-p` always feeds **and** runs the prompt; there is no feed-and-edit variant. To
  prefill (edit, not execute) the first REPL line, use the
  `SAMAGOTCHI_DEFAULT_INPUT` environment variable instead.
- Prompt history (↑) is one file shared by every session (see [Persistent Prompt
  History](#persistent-prompt-history)); `--resume` preserves the session's prior
  messages as turn context (a `-p` run on a resumed session never clobbers its
  conversation).
- Non-interactive runs (`-p` with `--non-interactive`, or bare `--non-interactive`)
  print only the final result output on stdout — no spinner, status line, or REPL.
  Everything else goes to stderr: the `Session: ID` line first, before the turn;
  retry lines and hooks' notices as they come, the after_turn hooks' ones
  (source-links' `sources:`) after the answer; and the error of a failed turn,
  then `chi: the session is kept with your prompt; continue it with: chi
  --resume ID` (exit 1). A turn the iteration limit (`turn.max_iterations`)
  cut short prints what the model wrote so far, then `chi: the iteration limit
  (N) was reached before the turn finished; continue it with: chi --resume ID`
  on stderr (exit 1). Ctrl-C saves the session with the prompt and a
  cancel note and exits 130.
  Nobody can answer there: an approval is denied, and a question the model
  asks (`ask_user_question`) is dismissed at once (one line on stderr), never
  read from stdin. The model is told no one could answer (a non-interactive
  run), not that you dismissed it, and finishes its reply.

### Scratch sessions

`chi scratch` is `chi --no-shared` for a session you won't keep: a quick
question, a try-out. It takes the run options (`-p`, `--non-interactive`,
`--model`, `--profile`, `--memory`, `--mute`, `-v`, …); `--resume`, `--attach`
and `--shared` are refused. Its first line says it is a scratch session.

- The session is deleted however it ends: `/exit`, Ctrl-D, Ctrl-C at the
  prompt, an error, SIGTERM or SIGHUP. There is no recap, and the lines typed
  are not added to the prompt history.
- It never shows in `chi web`. A process killed with `kill -9` leaves its
  session behind, marked `"scratch": true` in its session.json: `chi sessions
  list` shows it as `[scratch]`, and the next sweep or `chi sessions clean`
  deletes it. `chi --resume` and `--attach` refuse it (exit 1), so it never
  turns into a kept session.
- Memories are read and preloaded as usual, but nothing is saved: `memory_write`
  answers "scratch session: nothing is saved", and `write`/`edit` into the
  memories folder are denied (a guardrail, rule `scratch-session`). `execute`
  can still write files anywhere, memories included.
- An approval offers only "Allow once" and "for the session", and a session
  approval is kept in memory, not in the approvals store; approvals stored
  before still apply.
- No child sessions: the `delegate` tools are not offered, and a plugin's
  `ctx.sessions.fork` (btw's side session) refuses, since they would outlive it.
  Nor is `send_note`, whose note would stay in the other session.

### Sharing a session

Plain `chi` runs the session in a background worker and attaches the terminal
to it (`session.shared`, default `true`). A worker's session can have any number
of UIs at once: the Web UI and attached terminals (`chi`, `--resume`,
`--attach`). They all see the same turns as they happen, and any of them can send
a prompt, also while a turn runs (it merges into that turn as steering: the model
is told it is a steer and who sent it). Steering waits for the model's next step
and cuts nothing; a `task_wait` the model is blocked in ends early for it (the task keeps running). `/cut TEXT` in a terminal or the web composer (or `chi send --cut`) asks for a cut:
once the model has streamed only thinking for `steer.cut_after` seconds (per host/model: `steer_cut_after`; default
20), now or while your message waits, that generation is cut and the step starts again with your message, marked
`↪ cut in for your message` (see
[configuration.md](configuration.md#messages-during-a-running-turn-steer-and-cut)). `/queue TEXT`
(terminal or web composer, or `chi send --queue`) keeps TEXT for after the turn: it runs as a turn of its own once the running one ends. The
first answer to an `ask_user_question` wins; the other UIs close their widget.
An empty answer dismisses the question in every UI. The model is then told
not to go ahead with what it asked about, or change anything else, and to wait.

In an attached terminal:

- Ctrl-C cancels the running turn (whoever started it) and leaves what you typed
  in the prompt. At an idle prompt it clears the line; a second Ctrl-C within
  2 s, Ctrl-D or `/detach` detaches. The worker keeps running; the detach line
  prints `chi --attach ID` to come back.
- `/exit` (also `/quit`, `exit`) detaches and asks the worker to exit now, so it
  doesn't wait out the idle timeout. It stays up while something still needs
  it, and the detach line says what: a turn is running (Ctrl-C cancels it
  first), prompts are queued, a continue offer is pending, another UI is
  attached, or reminders are set. When every hold is something you can stop —
  reminders, a background task it watches for a [finish wake](internals/background-tasks.md#finish-wake),
  a delegate with a live worker — it asks instead of refusing, even when that
  is all there is:

  ```
  This session still has:
    • 2 reminders: api_health (every 20m), git push (every 5m)
    • 1 background task: rails s (2m)
    • 1 delegate: c1c1c1c1 "Fix the composer" (running a turn)
    1. Keep running in the background (detach)
    2. Stop them and exit
    3. Back to the session
  ```

  1 is today's detach. 2 cancels the reminders, stops the tasks the same way
  `task_stop` does and stops the delegates the same way `chi sessions stop ID`
  does, then exits as `/exit` does; the line names what it stopped (a child a
  terminal owns, or a task that can't be stopped, is left running and logged).
  Each entry says what it is: a reminder its schedule (`every 20m`, `every 1h`,
  with `, due now` when its next turn has already come), a task how long it has
  run, a child its title and what it is doing. 3 keeps the prompt open, and the
  next `/exit` asks again; Ctrl-D, `/detach` and a line the ask doesn't
  understand are not answers to it (Ctrl-D detaches, a stray line is re-asked).
  A delegate counts only for this ask: it never holds the idle exit, so 1 leaves
  it running and the worker idles out as usual. `/exit --delete` and `/archive`
  don't ask — with nothing else holding the worker, a running child does not
  stop them, as before. A web tab you just closed can count as
  attached for about 30 s. When the worker exits, `chi --resume ID` or
  `chi --attach ID` starts a new one with the conversation. Before it exits
  (here and on the idle exit) the worker writes the session's recap if
  anything new was said, which takes a few seconds; the terminal doesn't
  wait, and an attach or `chi send` meanwhile starts the next worker once it
  is gone. A worker from an
  older chi can't be asked; the line says to use `chi sessions stop ID`.
- `/exit --delete` (also `/quit --delete`, `exit --delete`) does the same and,
  once the worker has agreed to exit (without writing a recap), deletes the session for good. When the
  worker stays up, nothing is deleted and the line says why.
- The prompt stays open while a turn runs; see [Typing during a turn](#typing-during-a-turn).
- `/model`, `/models`, `/guardrails`, `/continue`, `!rollback` and `!commands` run in the
  worker, and every UI sees their output; `/stats` and `/recap` work too. The
  Web UI's composer takes the same commands, and so do `-p "/model x"` and
  `chi send -m "/model x"`. A `/word` the session doesn't know (a path, a
  typo) goes to the model as a prompt; a one-word `/word` that no command
  answers (`/modle`) is not sent: the UI prints `Unknown command /modle. Did
  you mean /model? /help lists the commands.` (the "Did you mean" part only
  when a name is close).
- `!commands` and the model's tools run in the session's directory (where it
  was started), whichever terminal you attach from.
- `-p` sends its prompt once attached, `--model` switches the worker's model
  first, and `--no-interrupt` applies to each prompt this terminal sends.
- History, completion and the idle status line work as in the REPL.
- The attached view needs reline 0.6.x to draw around the open prompt; with
  another version it prints plainly.

A worker nobody uses exits after `session.idle_exit_minutes` (30 by default, `0`
for never): no turn running or queued, no UI attached (an open web tab or an
attached terminal counts, even an idle one) and no reminder registered. The next
prompt or `--attach` wakes a new worker with the conversation intact; `/stats`
keeps counting from the turns before (they are saved in the session's
`analytics.json`, one record per turn), and the recap is saved with the session.

A session you leave with nothing in it (no prompt sent, no `/model` switch, no
note or image) is deleted as its worker exits, and `/exit` says so; set
`session.keep_empty: true` to keep such sessions. See
[Sessions](sessions.md).

`chi sessions stop ID...` stops each session's worker and waits for it to exit, so
a `chi --resume ID` after it starts a fresh one. A worker still running an
older chi (from before an upgrade) takes turns, but not commands, or not the
ones newer than it (`/llm-context`, `--llm-context` on `--attach`); the attached
terminal and the Web UI say so, with that restart line.

`chi sessions restart ID...` hands each session to a new worker on the newest
chi installed, without stopping it: an attached terminal and the web's tabs
move to the new worker. It is refused, with the reason, while something would
be lost: a turn running or queued, a question or approval waiting, a `/btw`
still running, an approval relayed from a delegate, or background tasks the
session started. Its reminders move to the new worker with their schedules
(a worker from an older chi still refuses for them). If the worker cannot be
asked (a refused Bridge, protocol mismatch or stuck start), chi sends it TERM
and resumes only when disk shows no running turn, pending question or
approval, queued prompt, or running background task; otherwise it says to run
`chi sessions stop ID`, then send any prompt. That fallback drops reminders,
and may lose a running `/btw` and other in-memory state. A session with no running worker needs no restart (its next
prompt starts one on the newest chi), and an older worker without restart
support needs `chi sessions stop ID`. The Web UI's
`POST /api/sessions/:id/restart` does the same (409 with `reason` and `detail`
when it can't). An attached
terminal says at the join, in one `chi>` line, when the worker or the terminal
runs an older chi than the newest installed (the worker moves with `chi
sessions restart ID`, the terminal with `/detach` and `chi --attach ID`), and
`chi> the session's worker restarted on chi X` when its worker was replaced.

`chi sessions archive ID...` hides sessions from every list (the terminal's,
the web's, `list_sessions`) and keeps them for good: the retention sweep never
deletes an archived session, nor counts it. Its delegates go with it. A live
worker is stopped first; a session running a turn (or with a delegate running
one), open in a plain REPL, or a `chi scratch` one is refused. `chi sessions
list --archived` shows them too, marked `[archived]` (`archived: true` in
`--format json`); `chi sessions unarchive ID...` brings them back, and so does
a message you send to one (the web, an attached terminal, `chi send`), but not
a delegate's follow-up or a reminder. The web archives from the info bar
(`archive`, before `stop`); the `archived` toggle by the all-sessions search
finds archived sessions. `/archive` in a terminal leaves the session and
archives it (an empty session is discarded instead; `chi scratch` refuses
it). See
[Sessions](sessions.md#archiving-a-session).

`chi sessions delete [--force] ID...` deletes sessions for good: the
session file and its whole directory (notes, images, queued input). Each id
(or unique prefix) gets one line: `deleted`, or `refused` with the reason. A
session whose worker runs is refused unless `--force` stops the worker first;
one open in a plain REPL is always refused ("close it there first"). Exit
status: 0 when all are gone, 1 when any was refused or unknown, 2 on a usage
error. The Web UI deletes too: `delete` in the info bar, or the ✕ on a card in
All sessions; it asks first and stops a live worker.

`chi sessions stats ID [--format text|json]` prints a session's cost, tokens
and progress without running a model turn — the same text `/stats` prints in
a terminal, headed by `<id8>  <status>  <model>`: a live worker answers its
Bridge's `GET stats`, else the snapshot is rebuilt from the session's saved
`analytics.json` (never starting a worker; a worker that does not answer in
time falls back to the disk and the line says so). `--format json` prints one
object `{session_id, status, live, metrics, settings}` (`settings`: the session's own `--set` values, flat as
`--set` names them, `{}` for none); a session with no
`analytics.json` yet reports `metrics: null` (`(no metrics yet)` in text) and
exits 0. An unknown or ambiguous id exits 1 with `chi sessions stop`'s
wording. See [Sessions](sessions.md#cli).

**The plain REPL.** Some launches run the session in this process instead, with
no worker:

- `--no-shared`, for one run, or `session.shared: false` in the config
  (`SAMAGOTCHI_SESSION_SHARED=0`), for every run.
- `--non-interactive`, a one-shot with no REPL.
- `--verbose`, which attached mode can't honor (the worker prints nothing). It
  prints a one-line note, `(session.shared: --verbose runs in a plain REPL)`.

A session the REPL has open can't be shared: `--resume` and `--attach` on it say
"close it there first", and the Web UI shows it read-only. `--attach`/`--shared`
can't be combined with `--non-interactive` or `--verbose`.

### Muting a memory

`chi --mute NAME` runs a session without a memory: for a memory whose
description mixes the context for a small model, or one a bundle owns
(`gh-helper`, `jira-manager`) that is not worth editing locally. The memory's
file and index line stay as they are; only this session doesn't see it.

- `--memory` and `--mute` are session fields (`preloaded_memory_names`,
  `muted_memory_names` in the session's JSON), written before the worker
  starts. A worker respawned by `--resume`, `--attach` or `chi send` builds
  the same prompt, and a REPL `--resume` of that session keeps the lists too
  (merged with the flags it is given).
- A mute wins: `--mute user_preferences` drops that config baseline entry for
  one session, and `--memory x --mute x` is a mute (one warning line).
- Names are checked before the launch, warnings only: `Warning: --memory 'x'
  not found`, `Warning: --mute 'x' matches no memory`, `Warning: 'x' is both
  --memory and --mute; muted`.
- `--attach ID` or `--resume ID` with either flag: the session keeps its
  own, so the flags are ignored with one line,
  `(--mute applies to a new session; <id> keeps its own)`.
- The status row shows `mem: <used and preloaded>` and `muted: <names>`; the
  Web UI's info-bar tooltip shows `memories: … · preloaded: … · muted: …`.
- The `read` tool on `memories/<name>.md` is not refused (a guardrails rule
  can protect the path if wanted).

### Session commands

`/help` lists the commands this session takes, the installed bundles' too, each
with a line on what it does. `/stats` shows the session's numbers: turns, tool
calls (by tool, with errors), iterations, tokens in/out summed over every
request (with the cached tokens, the cache writes, the re-prefilled tokens and the reasoning tokens when the server
reports them),
the decode speed, generation latency, cancellations, retries (the network's),
thinking cuts (generations a plugin such as loop-guard cut) and output cap hits
(generations that ended at the provider's cap), the thinking blocks a Claude 5.x preserved-thinking recovery dropped
(`thinking dropped:`, only when there were any; [configuration](configuration.md)), context used and window (the used figure is counted against the smaller of the window and the session's LLM context budget, and says so: `context used:     16000 tokens (25.0% of the 64000 budget)`), the memory indexes the session's prompt holds ([Memory](memory.md#the-indexs-size)), the model notes it carried (`model notes:      model_notes_deepseek (system, 612 chars)`, none without any; [Memory](memory.md#model-notes)), the toolkit's prompt text (`kit prompt:       coding (~20 tokens)`, only when its kit has one; [Toolkits](configuration.md#toolkits)), the prompt profile and the model the server says it ran, and the
cost when the provider reports one (OpenRouter's `usage.cost`), and the cost
estimated from a price under `hosts.<name>.models` when it reports none or 0,
marked `~` and naming the current model's host (`cost:             $0.42 reported + ~$0.12 from hosts.gw.models prices (this session only)`;
see "Prices" in [configuration](configuration.md#prices)). The speed line is the last generation's and the session's average
(weighted by tokens): llama.cpp reports it exactly (`87 tok/s out, 1.9k tok/s
prompt (last, server)`); for other servers it is estimated from the first
streamed chunk to the end and marked `~` (`~64 tok/s out (last, estimate)`).
Generations under 8 tokens or 100 ms get no speed of their own, nor does a
reply without server token counts or a non-streamed one. A delegated child
keeps its own numbers: a parent's tokens and cost leave them out.

Side requests have their own line, right after `cost:` (in its place without one), only when the session made any:
`side requests:    3 (recap 2, btw 1) · 14.2k in / 380 out · $0.0012 + ~$0.0009 (not in the totals above)`. It
counts the idle recap (`recap`), `/btw` and every other plugin's `ctx.ask_model` (under the asking bundle's name),
with their tokens and cost: a reported cost as is, else estimated from the price of the model they asked, on its
host (as a turn's, `~`). They are never in the tokens, `models:` or `cost:` lines above it, which stay the turns'.
A recap thrown away (stale, overdue) still counts: it was billed. `chi sessions stats` shows the line too (saved
between turns), and the web's ctx tooltip has the same words.

After a `/model` switch (or a hook's) the tokens line becomes a `models:` block, a row per run of turns on one
model, in order (A → B → A is three rows): the model (`host:model` as asked), when (`10:43–now` while it runs; with
the day when the rows span several), turns, tokens in/out, its average speed and cost. Under the row of the model
switched to, `└ switch prefill 58.0k uncached prompt ≈$0.01` says what its first request prefilled on the new model
(the prompt less the cached reads; `≈` an estimate from the new model's configured price, left out without one). A
`total` row ends the block. The speed line names the model of its last speed, and the cost is from `each model's host
prices`. Past 6 rows the oldest fold into one `N earlier segments` row; a session's turns from before chi recorded
their model are one `earlier turns` row. One model: the output is unchanged. `chi sessions stats` prints the same,
also offline (from the saved records). `/recap` is in
[Session recap](#session-recap), `/model` and `/models` in [Runtime Model
Switch](#runtime-model-switch-assist-mode).

`/llm-context` shows the LLM context strategy, apply rule and budget the next
turn runs under, each with where it came from (`the session`, `models: <key>`,
`hosts entry '<name>'`, `llm_context.*`), and the session's own values.
`/llm-context strategy <none|stale|stale,forget> apply <payoff|next_request|turn_end>
budget <tokens|64k|off>` sets the session's own (any of the three, in one line;
`default` unsets one), and `/llm-context reset` unsets them all. A change is
saved with the session and applies from the next turn's start; the reply says
what it costs: `forget` on or off re-reads the whole prompt once, `stale` turned
on stages the reads already superseded as one batch under the apply rule, and a
layer turned off sends its stubs whole again (turning it back on brings them
back). Once the session has a model reply, the two that break the cache now
(`forget` on or off, a layer with applied stubs turned off) ask first and name
the `--yes` line that applies them; `/llm-context reset --yes` works too.
`/llm-context` alone answers mid-turn too; a change sent while a turn runs
waits for the turn's end (see *Typing during a turn*). `/stats` shows
the same values on its `llm context:` line. The web's session bar names the
session's own in its ⚙ chip (`⚙ ctx stale,forget`), whose panel sets them
through `/llm-context … --yes`, one field a tap (its note says what a change costs). See "LLM context: a session's own strategy" in
[configuration.md](configuration.md).

`/working-set` lists the session's working set as the model has it (see [The
working set](#the-working-set)): each file, memory and URL its turns read,
edited or fetched, with its state (`stale`, `forgotten`, `dropped`) and what it
costs as sent, then the changes the next turn starts with. `/working-set drop
KEY…` takes an item out of what the model is sent: every read of it still sent
goes as a stub, `(dropped by the user) — read it again if the task needs it`,
whatever the LLM context strategy (none too), and stays dropped across a
strategy switch. KEY is a path (absolute or the session folder's), `memory:NAME`
or a URL; quote one with spaces (`"my notes/a b.md"`, as the listing shows it). `/working-set undrop KEY…` sends it whole again. A change applies
from the next turn's first request, which also carries one line telling the
model what you dropped or brought back (so it doesn't read it again by reflex);
the reply says what it frees and the tail the server reads again (a drop changes
history, so the prompt cache breaks there once). An undrop before that request
undoes the drop for free. Refused, with why: an item only edited or written
(nothing of it to drop), one not in the set, an older session's output chi
can't name. The model can't undo a drop (`forget_outputs` refuses it). One
`memory_read` of several names is one output: dropping, undropping or pinning
one name acts on that read whole, so on the others too, and the reply names
them (`; the same memory_read holds memory tone: dropped with it`).
`/working-set pin KEY…` keeps an item from the model's `forget_outputs` (the
[forget layer](configuration.md#llm-context-the-forget-layer)): it refuses every
read of it, those to come too, until `/working-set unpin KEY…`. A pin sends
nothing different (no cache break) and is saved with the session, so a respawn,
a continue and a fork keep it, across a strategy switch too; under a strategy
without forget it waits until one has it (the reply says so). The listing marks
it `pinned`, and under forget the next turn's line tells the model. A pinned
item can't be dropped until you unpin it; a pin takes back a drop not yet sent
(free), and asks you to undrop one already sent first.
`/working-set add KEY…` brings an item in: the next turn's line asks the
model to load it before anything else (`read` for a file, `memory_read` for
`memory:NAME`, `web_fetch` for an http(s) URL), so it costs the model one tool
call, and what it reads is an ordinary read (droppable, forgettable, in the
set). Nothing is sent until then, and `/working-set unadd KEY…` takes an add
back for free. On a stale or forgotten item it is a refresh (the model reads
it again). Refused, with why: a file that isn't there (or a directory), a
memory neither scope holds, a URL that isn't http(s), an item the model is
sent whole now, a dropped one (undrop it instead), one already added. The
listing's last line names the pending adds (`added lib/tax.rb`). The model is
asked, not forced: a model may skip the read.
`/working-set` alone answers mid-turn too; `drop`/`undrop`/`pin`/`unpin`/`add`/`unadd`
sent while a turn runs wait for the turn's end.

`/thinking` shows the thinking level the next turn runs at and where it came
from (`session`, `--thinking` / `SAMAGOTCHI_THINKING_LEVEL`, `models: <key>`,
`hosts.<name>`, `thinking.level`). `/thinking off|low|medium|high` sets the
session's own level, which comes first; `/thinking default` unsets it. It is
saved with the session (a `--resume`, a continue and `/model` keep it) and
applies from the next turn's start; the reply says what the change costs the
prompt cache: the whole prompt on Gemma 4 (native, or a local chat server whose
model name says gemma: `<|think|>` starts the prompt), only the tail on Qwen
(native, or a local llama.cpp or Splash server), and the whole conversation on a
remote chat host (OpenRouter, a hosted API). `/thinking` alone answers
mid-turn too; a change sent while a turn runs waits for the turn's end, and
skips that turn's warm-up. `/stats` shows the level on its `thinking:` line.
See "Thinking" in [configuration.md](configuration.md).

`/reasoning-history` shows which of its own reasoning a chat host's model gets
back from the next turn on, and where that came from (`session`,
`SAMAGOTCHI_REASONING_HISTORY`, `models: <key>`, `hosts.<name>`, the default
`turn`). `/reasoning-history drop|turn|all` sets the session's own level, which
comes first; `/reasoning-history default` unsets it. It is saved and carried as
`/thinking`'s is, and a native host ignores it (the reply says so). A change to
or from `all` once an earlier reply has thinking rewrites the earlier replies;
`drop` ↔ `turn` costs nothing. Under `turn` a step-limit Continue keeps the
reasoning of the turn it continues. `/stats` shows it on its `reasoning history:`
line, the web in the session bar's ⚙ panel (`⚙ reasoning all` once the session set its own). See "Reasoning history" in
[configuration.md](configuration.md).

`/toolkit` lists the tools the next turn declares (each with its estimated
tokens), the session's toolkit and the tools it leaves out: `reachable
(find_tools): …` (built-ins the model reaches with find_tools and call_tool)
and `removed: …` (only `/toolkit add` brings one back), or `not loaded: …` when
the toolkit removes call_tool, and its kit's prompt text when it has one (`prompt: <first line> (+N lines, ~T
tokens)`). `/toolkit remove TOOL` is hard: a tool the
toolkit left out reachable becomes unreachable (saved, and asked first once the
session has a model reply), also after an add. `/toolkit NAME` puts
the session on another toolkit (dropping its own adds and removes); `/toolkit
add TOOL` and `/toolkit remove TOOL` change one tool (a tool's name keeps its
case). The change is saved at once and applies from the next turn's start; a
running turn keeps its tools. `/toolkit` alone answers mid-turn too; a change
sent while a turn runs waits for the turn's end. The web shows a session that
isn't on `full` as the `tools` chip. See [Toolkits](configuration.md#toolkits).

`/parent-answers` shows what a parent agent may answer on this session's
questions: the level that applies, the session's own and config.yml's
(`parent answers: standard (this session: standard; config.yml
guardrails.parent_answers: soft)`). `/parent-answers hard|standard|soft` sets the
session's own, `/parent-answers default` drops it; it is saved at once and
holds from the next answer. It never goes looser than config.yml's (the reply
says when config.yml's applies instead). Anyone may tighten it; only you loosen
it, at the REPL, an attached terminal or the web: `chi send`, a piped or marked
attach and `chi -p --non-interactive` are refused. `/parent-answers` alone answers
mid-turn too; a change waits for the turn's end. No chip: its reply is where the
web shows it. See [Guardrails](guardrails.md#answers-from-a-parent-agent).

`/title` shows the session's title (`title: Coordinator`, or without one what names
the session, read from the same `recap.json` the cards read: `title: none (shows the
auto title: …)`, `title: none (shows the recap: …)` when its recap has no title, or
`title: none (shows the first message: …)` with no recap); `/title TEXT` names the session (whitespace collapsed,
cut at 80 characters), `/title --clear` drops the name (anything after `--clear`
is refused with the usage line). It is saved at once,
mid-turn too, and the lists, cards, top bar and tab show it in place of the first
message; a continue's next link keeps it. In the web, `✎` next to the session's
title (its strip card, or the top bar) does it. See [Session titles](sessions.md#session-titles).

A `/model`, `/llm-context`, `/thinking`, `/reasoning-history` or `/toolkit` change that restarts the prompt cache
asks first: the reply says what it costs, changes nothing, and names the line
that applies it (`/thinking low --yes`, `/model qwen --default --yes`). `--yes` (or `-y`) applies it at once.
The terminal puts that line in the next input (Enter applies it); the web's
reply has an Apply button. `chi send ID "/thinking low"`,
`chi -p "/thinking low" --non-interactive` and lines piped into the REPL apply
without asking (a plain `chi -p` opens the REPL, which asks). See "Changes that
restart the prompt cache" in [configuration.md](configuration.md).

### Typing during a turn

The prompt stays open while a turn runs, in an attached terminal and in the plain
REPL alike:

- A line you submit merges into the running turn at its next step (after the
  current tool call or answer): `(goes in at the next step)` at once, then
  `(1 message merged into the running turn)` when it does. It never cuts the
  model's thinking. An answer the model finished just before the merge is printed first.
  A line that comes after the turn's last step runs as the next turn, and so
  does one sent after Ctrl-C: it doesn't merge into the turn being cancelled.
  Reminder turns take merged lines too.
- `/cut TEXT` asks for a cut: a generation that has streamed only thinking for
  `steer.cut_after` seconds (per host/model: `steer_cut_after`) is cut and the
  step starts again with TEXT. The dim
  line says what happened: `(cut in now)`, `(cuts in once the thinking passes
  20 s)` (it waits for the thinking; the step may end first) or `(cutting is
  off; goes in at the next step)` (`steer.cut_after` is 0, per host/model:
  `steer_cut_after`, or no generation to cut).
- `/queue TEXT` runs TEXT as a turn of its own after this one, in an attached
  terminal, the plain REPL and the web composer alike: `(queued: runs after this
  turn)` (the web draws it as a queued bubble until its turn starts). It never
  merges into the running turn, and a plain line sent after it still does.
  Several queued lines run one turn each, in the order sent; they still run
  after a Ctrl-C or a failed turn, and a queued line drops a continue offer as
  any prompt does. Other terminals show someone else's queued line with the same
  note. A session whose worker is older than queueing would steer it instead, so
  it is not sent: `(/queue needs a newer worker: restart it with chi sessions
  restart, then send again)` (the web shows the refusal under the line). A line
  with images works the same way: it waits for the turn's end, and the lines
  sent after it still go in at the next step.
  At the open prompt (no turn running) `/cut TEXT` and `/queue TEXT` run TEXT
  as a normal prompt, and the terminals say so: `(nothing is running: sent now)`.
- `/unqueue` (attached terminal) takes back the newest line this terminal
  queued that hasn't started: `removed: <its first 60 characters>`, and its text
  goes back into the input to change and send again (not over typed text: then
  it is in the input history, ↑; not with input from a pipe; its images don't
  come back), then the one before it on the next `/unqueue`. A command typed
  after that text without clearing it (`fix it/unqueue`, `fix it/queue more`)
  runs as the command (the scrollback shows the command alone), and the text stays in the input. `(nothing queued: …)` when none waits,
  `(not removed: it already started)` when its turn won the race, `(not removed:
  it is already gone)` when another client removed it. Other terminals that
  showed it say `(a queued message was removed)`; the web drops its bubble. A
  worker older than it is not asked: `(/unqueue needs a newer worker: …)`. In
  the plain REPL it answers with a note (its own queue is not touched), and the
  web's composer points at the × on the bubble.
- **The web composer** has a row above the text field in a session (always
  there, so the composer never changes height): the keys while idle, and while
  the turn runs the delivery line, where a message sent now goes in (`↳ goes in after this
  thinking step · 0:42 · 3k chars`, `… after this tool call (execute · 0:12)`,
  `… after this answer; the turn may go on`, `… once the card above is
  answered`), then two links. **Enter** (or Send) is the next step;
  **Alt+Enter** (Option+Enter) or `queue for after the turn` queues it, like
  `/queue TEXT`, and the bubble is dashed (`after this turn`), below the
  running turn's card with the commands queued for its end, until its turn
  starts; its **×** (`Remove from queue`, once the worker acked it) takes it
  back before it runs, in every tab (a toast says why when it can't: it
  already started, it is gone, no live worker), and puts its text back into an
  empty composer to change and send again (a draft stays: the text is then in
  the toast; images don't come back); `cut in now` cuts, like `/cut TEXT` (by click only: it throws the
  thinking away). Cut is enabled only while the step has streamed nothing but
  thinking and cutting is on for the model (the line says `cuts at about 0:25
  if you choose cut in now` until the thinking passes `steer_cut_after`, and
  `cutting is off for <model>` with no cut link when it is 0); the queue link
  is gone for a worker too old to queue (Alt+Enter then sends nothing, keeps the
  text and says to restart the worker). A link clicked with an empty composer
  arms that choice (`cut in now ✓ · Enter sends`); a second click or Esc lets
  go of it. The echo says what it waits for: `waits for the next step` or
  `cutting in…`, then `steered`. A phone shows the short form (`↳ after this
  thinking · 0:42`) with `cut in` and `queue` chips.
- Commands answer, wait or are refused, by what they do:
  - At once, beside the turn: `/stats`, `/recap` (and `/recap on|off|default`), `/help`, `/context`, a
    plugin's anytime command (`/btw`), and the commands that only show
    something: `/models` (with a filter too), and `/model`, `/llm-context`,
    `/thinking`, `/reasoning-history` and `/guardrails` alone.
  - After the turn: the ones that change something (`/model X`, `/model clear`,
    `/llm-context strategy …`, `/thinking LEVEL`, `/reasoning-history LEVEL`, `/guardrails revoke N`) and
    `!cmd`, whose output
    joins the conversation. `(queued: runs after this turn)` says so at once (the
    web draws the command's bubble dashed, with the same words, until it ran);
    when the turn ends they run in the order sent, a prompt sent before one
    running first and one sent after it running after. A `/model X` sent
    mid-turn doesn't change the running turn, nor a line merged into it later.
    After a canceled or failed turn a waiting `!cmd` is dropped
    (`turn canceled: !ls not run; send it again`): running it would close the
    `!rollback` the turn left; the others still run. A command still waiting
    when the session's worker stops is answered `dropped` too.
  - Refused: `!rollback` (`busy: Ctrl-C the turn first, then !rollback`),
    `/continue` and a plugin's command that isn't anytime
    (`busy: wait for the turn to end`). The line goes back into the prompt, so
    Enter runs it once the turn ends.

  A one-word `/word` no command answers (`/modle`) is not steering text either:
  the hint prints and the line is dropped.
- A question (`ask_user_question`, a guardrails approval) turns the prompt into
  a yellow `? ` and lists its choices under it, fitted to the terminal; only a
  line submitted there answers it (a number, `1,3`, a label, `y`/`n` for an
  approval, `; text` for a reason; Enter alone dismisses it), and what you had
  typed comes back once it closes. The choices then go, and one line stays:
  `? Pick a fruit → Banana`.
- Ctrl-C cancels the turn and keeps what you typed.
- In the plain REPL, Ctrl-D on an empty prompt (or `exit`, `/exit`, `/quit`) mid-turn
  exits once the turn ends: `(exits after this turn; Ctrl-C cancels it)`
  (`/exit --delete` deletes the session then too). In an
  attached terminal it detaches at once and the turn goes on in the worker
  (`/exit` then says the worker stays up: a turn is running).
- `/archive` mid-turn archives once the turn ends:
  `(archives after this turn; Ctrl-C cancels it)` in the plain REPL,
  `(archives after this turn)` in an attached terminal, which also waits for
  the commands queued behind the turn.

With stdin that isn't a terminal (a pipe), the REPL reads a line only between
turns.

### Images

A model that can see images gets them these ways:

- **`@path` in a prompt** (REPL, attached terminal, `-p`): `what's wrong in
  @shot.png?`, `@~/Desktop/a.jpg`, `@"my shot.png"`. Each `@` token that names an
  image file (png, jpeg, gif, webp; bmp, tiff and heic are converted) goes with
  the prompt, and a dim line shows it: `[image shot.png 1280×800 · ~1.3k tokens]`.
  The prompt text stays as typed; an `@` token that isn't an image (a source
  file, a missing path, an email address) is just text. A line with images typed
  while a turn runs waits for the next turn (steering merges text only).
- **A path in plain words**: "check /home/me/shot.png and describe it". The
  model calls `read` on it and sees the picture; the tool line ends in
  `→ image 1280×800`.
- **The Web UI**: paste or drop images into the composer, or pick them with
  its image button (left of Start / Send; on a phone it offers the camera and
  the photo library, and is hidden while a turn runs). Each shows as a chip (× removes it) and is sent with the
  message; an image alone is sent as `[image: name]`. A message takes up to 20
  images of up to 20 MB each; a toast names the files left out (over a cap, or
  not an image). Messages show thumbnails; a click opens one full size.
- **`chi send --image PATH`** (repeatable, up to 20) with a message, from a
  script or another terminal: `chi send --image shot.png -m "why is this red?"
  3fa2`. The attached terminal and the web show it like an image typed there.
- **The desktop panel** (macOS, [Desktop](desktop.md#images)): a screenshot on
  the clipboard, an image selected in Finder, or one dropped on the panel goes
  as an attachment with the message.

Images are downscaled to a 1568 px long side (with `sips` on macOS or
ImageMagick; without either, a larger image is refused with a hint) and stored
next to the session in `<session>/images/`, and the session file keeps small
references to them. Each request sends up to the newest 20 images of the
conversation (`image.max_per_request`); past that the oldest are left out ten at
a time (half the limit), so the earlier conversation stays the same between
requests and the server's prompt cache keeps it. A left-out image becomes a line
like `[image shot.png 1280×800 not sent: an older image (chi sends up to the
newest 20)]`.

A model that can't see images (a text-only model, llama.cpp without
`--mmproj`) refuses a turn with images before sending it:
`host main can't take images: …; send text only, or pick a model that can see
images (/model)`, and the typed text (and the web's chips) come back. When chi
can't tell beforehand, the provider's refusal gives the same line. Images already
in the conversation go as placeholder lines after a switch to such a model.
Settings: `image.*` and `vision:` in [Configuration](configuration.md#images).

### Web Markdown rendering

Web responses are escaped text by default. To render completed assistant
responses as HTML, enable the renderer for the web server (it uses
`commonmarker`, which `bundle install` pulls in from the Gemfile; outside
Bundler, `gem install commonmarker`):

```sh
chi web --web-markdown
```

`chi bootstrap` offers to turn it on (and install commonmarker) on a terminal
(see [First setup](#first-setup)). The setting also supports `SAMAGOTCHI_WEB_MARKDOWN=true` or the global config:

```yaml
web:
  markdown: true
```

Only finalized assistant messages are rendered; user messages and live streaming
chunks remain escaped text. The stage's asking text (the whole reply that asked
a waiting question or approval) shows raw at once, then as markdown, its links
opening in a new tab; a resolved question card's copy of that reply renders when
the card is first opened (its summary line stays plain). A text the page already shows and renders later goes
through `POST /api/render` (`{text}` → `{html}`, up to 64 KB; `html` is null
with markdown off), the same renderer and sanitizer. Generated HTML is
sanitized, raw HTML in model output is not trusted, and unsafe links are
removed. If Markdown is enabled without
commonmarker installed, Chi Web keeps the normal escaped-text display and shows a
warning explaining how to install the optional gem. While Markdown is off, the
owner's session view shows a one-line tip saying how to turn it on (and, when
commonmarker isn't installed, how to install it; the text is the server's,
`markdown_tip` in the session payloads, never on a participant's page); its ×
hides it for that browser (`chi_markdown_tip_dismissed` in localStorage).

Every prompt and answer has a copy button (on hover; always shown, dimmed, on a
touch screen), and so does each code block of a rendered answer. An answer
copies its Markdown source, not the rendered text; a code block copies just
its code; a prompt copies the text as you typed it. On a phone or a touch
screen a code block's button sits in a strip above its first line, clear of
the code.

A long answer (over 25 lines or 2,000 characters of its text) can be folded
by hand: a "▾ N lines" row is its top edge once its turn has ended. Click
it and the answer closes to one line in its own box,
"▸ its first line · N lines" (the
first line of what a hook presented in its place, else its first heading,
else its first line); click again to unfold. A delegate report's reply
folds the same way, and so does a long prompt you sent (over the same
threshold; its folded row shows its first line as typed). A delegate
report itself starts folded. Folding is this browser's choice, kept per session in
localStorage (`chi_answer_fold:<session id>`, the last 200 folded answers and prompts;
the keys of sessions gone from the list are dropped when the list loads);
other viewers and the participant page are not affected. A jump into a
folded answer (a claim link, say) unfolds it for that page load.

**Revise** rewrites an answer and stacks the versions. A finished turn's
final answer has a Revise button on its bottom edge (on hover; always shown
on a touch screen), unless it's a Verify turn's answer, a canceled or failed
turn's partial answer, or an earlier version in a stack. Revise arms the
composer with a chip, "Revising: ‹its first line› ✕"; your next message (say
"cut it shorter") is sent as a Revise of that answer. ✕, emptying the box or
opening another session lets go of it. When the Revise turn completes with an
answer, the earlier version folds where it was into one stub row,
"▸ v1 · “its first line” · 84 lines — superseded by v2": its prompt, its
steps and its answer, all behind it (a warn card, a verdict card and the
recap stay on view). Click the stub to unfold that version in place (kept per
browser, with the folded answers); a time divider between two folded stubs
moves into the later stub. The newest version has a chip, "v3 · 2 earlier ▾",
listing every version by its prompt; pick one to jump to its stub. Before
that chip, a "‹ 3/3 ›" switcher reads an earlier version's answer in the
newest one's place (its left edge dashed while it shows; Copy copies the
version on view); › back to the newest. Switching only changes what this
page shows, and a reload shows the newest again. Revise
again on the newest version adds to the stack. Stacks are session data (the
stamp is on the Revise prompt, see [sessions.md](sessions.md), Revise
stacks): every owner's page shows them, live and after a reload; the
participant page doesn't draw them yet. A session whose worker predates
Revise (started by an older chi) disables the button and shows the chip as
"Revise: restart this session to use Revise"; a message sent then is a plain
one. A Revise turn that fails comes back into the composer with its chip.

### How the page draws a turn

**The stage** pins the running turn above the composer, in its own
card, so it stays on screen without scrolling: a status row (what it is
doing, the step, the elapsed time), your prompt on one line, the newest
narration sentence (else the newest thinking one, in italics; click it for
the step's reasoning), the running tool with what it does, and the last
three calls. A plugin's or hook's notice and a plugin's nudge ("check-in
nudged the model") show ahead of those calls for about 4 s, as their rows
wait in the closed block. A card that needs you (a question, an approval, check-in)
sits in the stage too. While a question or approval waits, the stage shows
the whole text of the reply that asked it (in place of its newest
sentence) above the card, until you answer. A long reply that asks the
model's own question (one that doesn't fit that slot) gets more room: the
stage grows to about 85% of the page for the rest of the turn (never above
the session panel), the reply reads from its start in the stage's one
scroll, and while the card is out of view a `❓ Answer ↓` pill at the
stage's bottom edge takes you to it. Once answered, the model's
question or its own approval keeps that reply (a delegate's relayed
approval, a hook's question and the step limit don't): two muted lines
under its `question → answer` line, the whole text when you open the card,
live and after a reload. The chip at the stage's bottom edge, `N steps · M tool
calls` with one tick per call, opens the turn block right above it (newest step first
while it runs; a tick opens its step). Below the chip, past a dashed rule, wait the
messages queued for after the turn and the commands queued for its end; they go into
the history after the turn's answer. `▾` folds the stage to its status
row, remembered in this browser. The stage keeps its height while a turn
runs: it grows, with a short ease, when a card or the answer needs room and gives the room back
only when the turn moves into the history. When the turn ends the answer shows in
the stage, and the whole turn moves up into the history once you are not
using the stage (the pointer over it, a touch or scroll in the last 4 s,
keyboard focus or a selection keep it) for 1.5 s: the stage slides away
under the composer, then the turn appears in the history. Sending the next
message moves it at once. The history is never scrolled while a turn runs, and only
follows the hand-off if you were at its end. The `/` command list opens
over the stage's lower edge.

**The turn block** shows a turn's work as *one block*: in the stage's cloud
while the turn runs (newest step first), in the history after the hand-off
and on a reload. The running
generation is the live part on top (its thinking, its narration, its
tool rows), the earlier ones below it collapsed to one line each
(their narration's first line, else their first call's title such as
`edit lib/a.rb`, and a call count), expandable for inspection. A tool row
says what the call did: a file's path relative to the session's folder, a
command without its leading `cd … &&` (the full parameters on hover). Under it a done row shows its
output's first 300 characters; an `execute` and a `task_wait` with its log's tail show the last ones (a test
run's summary, a failing exit line), without the success `exit: 0` line; a gate-corrected call's `ran as:` line only on hover; all of it on hover. The live thinking is one line: the
newest complete sentence, changing at most once per 1.5 s. Click it for the
full text; a peek is per step (the next step's thinking starts closed
again). When a step ends its thinking closes to a plain `thinking` line
(unless you opened it); a step that only thought shows that line alone. The
live narration is a box of about three lines that fills sentence by
sentence (a sentence shows once it is complete) and scrolls to the newest
when full. When the turn ends the block shows its outline when any of its steps said
something: it stays open on one line per step that wrote text (that text's
first line, so a mid-turn note reads without a click), and each run of steps
that only called tools or thought sits behind one `· N steps` line that
shows them; old turns open the same way after a reload. A turn whose steps
said nothing collapses the block to its summary (`3 steps
· 8 tool calls · execute ×7 · read ×1`). Either way the answer is a normal
bubble under the block (Markdown, annotate). A plain answer
without tools ends exactly as it does today. Rows the code collapses stay
as you toggled them. A reloaded session shows the same block
from the saved messages (each step's thinking, narration, tool parameters
and output, the output capped at 2000 characters) and the timing records
(status and duration per row). On an `api: openai` host the model's
reasoning is saved with each step for this (and sent back to the model
within the turn: see "Reasoning history" in [Configuration](configuration.md));
steps saved before that have none, so they show no thinking. An `edit` or
`write` row has a closed `diff +3 −1` under it that opens to the change it
made (up to 120 lines or 8 KB), live and after a reload (see
[Guardrails](guardrails.md#ask) for the diff an approval shows first).

`web.view`, `chi web --web-view`, `SAMAGOTCHI_WEB_VIEW` and `?view=` were removed with the turn view (the
stage is the only view; a config.yml that still sets `web.view:` warns about an unknown key).

**When things happened**, on the owner's page and on a participant's review page: where 10 minutes or
more of quiet passed between the end of one activity and the start of the next (a turn, a context
note, a reminder), the history has one dim centred line, `── 14:32 · 47 min later ──`; the date is
added when the day changed or the turn wasn't today (`── Sat 24 Oct 09:10 · 13 h later ──`).
Nothing marks active work: a long turn followed at once by the next has no line. Hovering a prompt,
an answer, a note or a reminder shows its full local time, and the recap's label says when it was
written (`recap · 14:32`). The times are the history entries' `at` (see
[sessions.md](sessions.md)); a session saved before them takes its turns' times from their timing
records, and shows no hover times.

### The working set

The stage view shows what a turn brought into the model's context: the files
it read, edited or wrote, the memories it read or wrote and the URLs it
fetched. It is on by default; `web.working_set: false` (or `chi web
--no-web-working-set`, `SAMAGOTCHI_WEB_WORKING_SET=false`; `?working_set=0` on
the page URL for one page load, `?working_set=1` back on) turns it off, and the
session bar shows the `mem N` chip again.

- **The rail**, on the right of the stage's live slots: the running turn's set
  in four lines, folded as it grows (files under one folder become
  `…/web/public/ · 9 files ✎2`, memories `◆ 3 memories`, else `N files · K
  dirs`), with the newest entries marked for a few seconds and the context
  ring once its fill is known. It never changes the stage's height. Its `–`
  folds it to one line (`SET 17 + ◆ name`), kept per browser; a click opens the
  list. In a stage narrower than 760 px it is one line under the last calls;
  on a phone it isn't shown.
- **The footprint**, one line under each finished turn's block, live and after
  a reload: `touched …/web/public/ · 4 files · ◆ 2 memories s2–10 · +1 url ·
  edited 1`, then `n stale`, `n forgotten` or `n dropped` while some are (a file
  changed after the turn read it, even at its very end, says so here). A step
  tag (`s2`) goes to that call's row; the rest opens the turn's list. A turn
  that touched nothing has none.
- **The `set N` chip** in the session bar, in place of the `mem N` chip (whose
  tooltip goes too): the session's whole set, preloaded (`--memory`) and muted
  (`--mute`) memories included; its dot lights when the set changed since you
  last opened it.
- **The list** the three open (a bottom sheet on a phone): this turn or the
  whole session, files grouped by folder (a group opens in place), memories
  (used, preloaded, muted) and URLs, each with what was done to it (`read ×2`,
  `read, edited`, `preloaded`) and a step tag (`s3`, `t2·s3` in the session's
  scope, `prompt` for a preloaded memory) that goes to the call. A file opens
  as its row's title does, a URL in a new tab. A row (on hover or keyboard
  focus) and a folded group offer `drop`, which runs `/working-set drop` (see
  `/working-set` above); a dropped row offers `undrop`, and so does one whose
  drop holds on some reads only (`part dropped` in `/working-set`'s listing:
  an older read stubbed by the stale layer, or a newer read sent). Between turns it
  applies at once; while a turn runs it waits for the turn's end: the row is
  dashed with `drops next turn` and an `undo`, and the list's foot counts the
  pending changes (`undo all`), in every tab and after a reload; the stage's
  rail dashes the item's line too (its tooltip says `drops next turn`). On a phone a
  tap on a row opens its actions under it. `drop` is greyed, with why on
  hover, for an item only edited, a memory only preloaded, or one already
  forgotten. Under a strategy with forget a row also offers `pin`
  (`/working-set pin`, pending as `applies next turn` mid-turn); a pinned row
  shows `📌` and `unpin` (under any strategy), and its `drop` is greyed until
  you unpin it.
  The list's foot (a phone's last row) takes a path, `memory:NAME` or a URL
  and runs `/working-set add`: the item shows as a dashed `+ name` row with
  `reads next turn` and an `undo` until the next turn starts (the model is then
  asked to read it, and it joins the set as the model reads it). A stale or
  forgotten row offers `refresh`, the same add of it. While a turn runs the
  stage's rail shows an add queued for its end as a dashed `+ name · next turn`
  line.

Only `read`, `edit`, `write`, `memory_read`, `memory_write` and `web_fetch`
calls that succeeded count; files an `execute` touched don't.

What the model still has of each item comes from chi, not the page, so it is
the same live, after a reload and in every tab:
- **stale** (faded): the file changed since the model last read, edited or
  wrote it, whatever changed it (a later `execute` such as `sed` or `git
  checkout`, your editor, another session). The model's own successful edit or
  write doesn't make a file stale. Chi checks at each request and when you
  open the list, so a file changed while the session sat idle shows stale on
  opening it. A turn saved before chi kept that record shows its files live.
- **dropped** (struck): you dropped it (`/working-set drop`, the list's
  `drop`); its reads are sent as stubs under every strategy until you undrop
  it.
- **pinned** (`📌`): you pinned it (`/working-set pin`, the list's `pin`);
  `forget_outputs` refuses it.
- **forgotten** (struck): nothing of the item's content is still sent to the
  model under the session's current LLM context strategy (`forget_outputs`
  forgot every read of it; see
  [the forget layer](configuration.md#llm-context-the-forget-layer)). Lines a
  forget kept count as still sent. Under `/llm-context strategy none` nothing
  is cut, so a forgotten item is live again from the next request.

The list says `stale`, `forgotten` or `dropped` in words with each row, and how many
tokens its content costs as sent (`~1.2k`); a folded group shows its forgotten
members as `✂n`, and a footprint adds `n forgotten`.

### Web annotate presets

Selecting text in an answer, a thinking block, a tool row or one of your
messages shows **Annotate**, which quotes the selection into the composer
for a note under it. Next to it sit quick replies, by default `Agreed` and
`Could you please elaborate?`: a click quotes the selection the same way
with that text already written as the note. It only fills the composer,
never sends, so you can collect several quotes and edit before sending.
On a touch screen (a phone, a tablet) the bar sits just above the composer
instead of next to the selection, where the system's own Copy menu and the
selection handles would cover it; several pills wrap to a second row.

A review's participants get the same on their page (a `chi share` / `chi
review` link): selecting text in the Plan or the thread quotes it into
their comment box, labelled `From docs/plan.md:` or `From Sam's comment:`,
with the same presets. Not in the owner's participant view, and no plugin
pills there (a review turn refuses `/` lines).

After the presets, both pages have a built-in **Verify**: the quote, then
an ask to check the claim against the code and end on a line `Verdict:
confirmed|refuted|unclear — <reason>`. Verify is offered only on text in a finished turn's final answer, the
claim a verdict card can come from; elsewhere (an earlier reply, a step, a message, a line added mid-turn, a turn
still running) the bar keeps its other actions. A session whose worker predates Verify (started by an older chi) refuses it (409
`verify_unavailable`); a participant's page disables Verify and Verify fresh with a hint to restart the session. On your page a selection in a turn
also offers **Copy link**: a link to that turn and quote for a participant's
browser (the one their review link was opened in), which opens their page
scrolled to the quote and highlights it; with no one invited, a link to it
on your own page. A secret in the selection goes into the link as
`[redacted]`, as the participant's page shows it. One browser holds one participant link at a time, and
opening a participant's invite link yourself swaps your own sign-in for it
(see [participants.md](internals/participants.md#what-a-participant-sees)).

The list is `web.annotate_presets`, `|`-separated (at most five; a preset
can't contain `|`; a YAML list works too):

```sh
chi web --web-annotate-presets "Yes|No|Why this way?"
chi web --web-annotate-presets ""   # only Annotate
```

```yaml
web:
  annotate_presets: "Agreed|Could you please elaborate?"
```

`SAMAGOTCHI_WEB_ANNOTATE_PRESETS` overrides the file, but an empty value
there means the default, not "none": use `""` in the file or on the command
line. A `chi web` that already runs keeps its list; restart it.

### chi web on your phone

`chi web` listens on 127.0.0.1 only. `--web-host lan` (or `web.host: lan`
in config.yml) also opens it on this machine's private IPv4 address, for a
phone on the same Wi-Fi:

```sh
chi web --web-host lan
```

```
Chi Web on http://127.0.0.1:4567/?dir=/Users/me/projects/app (public: …)
Local: http://127.0.0.1:4567/?dir=/Users/me/projects/app#code=chc_…   ← opens chi web as you once, within 10 minutes (…)
LAN: http://192.168.1.55:4567/?token=…   ← anyone with this link can run commands as you
Plain http: the link and your traffic can be read by anyone on this Wi-Fi.
<the link's QR code>
```

Scan the QR code with the phone's camera. The page trades the token in the
link for a cookie (kept 400 days) and drops it from the address, so a
bookmark or a home-screen icon keeps working across restarts. It opens on
the project chi web starts in (`--start-dir DIR` or `web.start_dir` picks
another; outside a repo it shows every session); the header's `all` shows
every project's. A home-screen
web app on iOS has cookies of its own: if it opens on "needs chi web's
access token", paste the token there (the part of the link after
`token=`), or open the link once in it.

- Every request needs the token (the cookie, or `Authorization: Bearer
  <token>` for curl), this Mac's on 127.0.0.1 too: a participant's pair turn
  runs commands here. Without it the page says how to get in (with a box to
  paste the token) and the API answers 401. On this Mac open the `Local:`
  link (`chi web --open` opens it): its one-time code (10 minutes, once) sets
  the cookie for 127.0.0.1 without the token in the address; the LAN link
  works here too. The cookie for 127.0.0.1 holds a value derived from the
  token, not the token: the browser sends it to a server on any other local
  port too (a dev server that logs headers), and that server can't use it
  from the network (unless something forwards it to this machine's
  loopback), as Bearer, or as the token; `chi web --new-token` ends it. The LAN address's cookie (your phone's, or this Mac's when it opens
  the LAN link) is the token itself. chi's own probe (`GET /api/info` with no token or cookie)
  gets a few fields (version, pid, features, the LAN address, the start
  folder), nothing of the sessions.
- The token lives in `$XDG_STATE_HOME/samagotchi/web-token` (0600).
  `chi web --new-token` replaces it: a running chi web takes the new one at
  once, and every phone has to scan the new QR code.
- A second `chi web` prints the LAN link and QR code again, and a new
  `Local:` link (`--open` opens it). A plain
  `chi web --web-host lan` while a chi web without LAN access runs asks you
  to stop that one first. `chi self` says whether chi web runs on the LAN.
- `lan` picks the first private address (10.x, 172.16–31.x, 192.168.x) on an
  interface that is up, not a VPN tunnel, bridge, VM or container, and names
  the others; `web.host: 10.0.0.3` picks one yourself. An address outside
  those ranges (a Tailscale 100.x one, a public one) works, with a warning.
  After the address changes (a new Wi-Fi), restart chi web. IPv6 isn't
  offered.
- It is plain http: the token and everything you do travel unencrypted on
  the Wi-Fi. Use it on your home network, never on a shared one (a café, an
  office guest network), and run `chi web --new-token` if a link leaks.
- On http the browser has no notifications: the bell is hidden on the phone,
  and the tab title still counts what needs you.
- Off the home Wi-Fi: `chi web --tunnel tailscale` gives chi web an https
  name on your tailnet (Tailscale Serve) for its run and prints its link's QR
  code; see [Tailscale Serve](configuration.md#tailscale-serve-your-tailnet).
- Notifications on the phone, also while chi web isn't open there: on the tunnel's https link, Add to Home Screen,
  open the Chi app, tap its bell and turn on **This device**; approvals, questions and failed turns then push to the
  phone. The same sheet lists the other devices (a long-turns-done switch each, Remove), and `chi web push ls|rm|test`
  does it from the Mac (see [Phone notifications](configuration.md#phone-notifications-web-push)).

### Remote sessions

The session commands also reach another machine's sessions, through its chi
web on the LAN: the sessions, workers, memories and code stay there. On the
other machine (the Studio), run `chi web --web-host lan`; on this one (the
laptop), add it once with its token (the part of its LAN link after
`token=`, or its `$XDG_STATE_HOME/samagotchi/web-token` file):

```sh
chi remote add studio http://192.168.1.29:4567 --token-file studio-token
# studio  http://192.168.1.29:4567  chi 0.103.0, LAN 192.168.1.29
chi --remote studio send --new --dir /Users/me/projects/app --wait -m "fix the flaky spec"
chi --remote studio answer ab12 --question q1 --option 1
CHI_REMOTE=studio chi context push claude-outbox ab12 < answer.json
```

- `chi remote add NAME URL` checks the address and token first (`GET
  /api/info`) and says what it found: the chi it runs and its LAN address, or
  why not: nothing answers (start chi web there with `web.host: lan`), the
  token was refused, or a hostname (chi web answers its LAN IP only: use the
  IP, which changes with the Wi-Fi), or a chi too old for remote sessions.
  Nothing is saved then. The remotes live in
  `$XDG_CONFIG_HOME/samagotchi/remotes.yml` (0600), their tokens inside: a
  token runs commands as you there. `chi remote ls` (`--format json`) never
  prints one; `chi remote add` of an existing name replaces it.
- `--remote NAME` goes before the command (`chi --remote studio note …`),
  `CHI_REMOTE=NAME` in the environment does the same for every command a
  script runs; the flag beats the variable, and there is no default remote.
  An unknown name exits 2.
- What runs there: `send` (every form: `--new`, `--wait`, `--queue`,
  `--cut`, `--image`, a session command), `answer`, `note`, a session's
  `context add|push|ls|show|rm` and `sessions
  list|stop|restart|archive|unarchive|delete`. The rest runs on this machine
  only and exits 2 with `chi <command> runs on this machine only: run it on
  <remote>`: `context refresh|mute|unmute` and `--project`, `sessions
  stats|prune|clean`, `broadcast` and the machine's own commands (`bundle`,
  `memory`, `update`, …). `chi remote`, `--version` and `--help` always run
  here.
- `send --new` needs `--dir`, that machine's absolute path (no folder of this
  one is guessed); `--toolkit`, `--set` and `--parent-answers` are checked
  against that machine's config and bundles. `sessions list` lists every
  project's sessions there (`--scope=project --cwd DIR` one project's) in the
  `--live` text form. `context` takes the session ids (no default session),
  and a URL resolves through that machine's bundles.
- That machine's config.yml decides what it checks for `send` and `answer`:
  a parent agent's `/continue yes` and options (`guardrails.parent_answers`),
  a loosening `/parent-answers`, images to a model that can't see them. Each
  target refuses its own (`ab12  refused: …`), where this machine refuses
  before sending to any.
- Waits run on the server, 30 s at a time, until the answer or your own
  `--timeout`; exit codes are the same. The commands chi prints for what to
  do next work as pasted: they carry `--remote NAME` (`chi --remote studio
  answer ab12 --question q1 --option N`, `chi --remote studio send --wait …`),
  under `CHI_REMOTE` too, an attach as well (`chi --remote studio --attach
  ab12 shows it`, `sessions stop`'s `chi --remote studio --resume ab12`).
- A remote that can't be reached names itself and why (`chi send: remote
  studio (http://192.168.1.29:4567): connection refused`, exit 1; with
  `--format json` an `error` object).
- Plain http, the same as the phone's: use it on your home network.
- The macOS desktop helper's panel lists and sends to a remote's sessions too: see
  [Desktop helper: Remote sessions](desktop.md#remote-sessions).

A session there in this terminal (the attached TUI, through that machine's
chi web; its worker stays there):

```sh
chi --remote studio --attach ab12                      # attach (wakes its worker if it exited)
chi --remote studio --resume ab12 -p "go on"           # resume there, run one turn, stay attached
chi --remote studio --dir /Users/me/app -p "hi"        # a new session there (--dir required), one turn, stay
```

- The same TUI and exit codes (0 detached, 3 a question left waiting with
  input from a pipe, 1 otherwise), every printed command with `--remote
  studio`. Prompts, session commands, `/model`, `!cmd` (a shell command **on
  that machine**, under its guardrails), `/queue`, `/cut`, `/unqueue`,
  `/detach`, `/exit`, `/exit --delete`, `/archive`, `/stats` and `/recap` work
  as here, on that machine's session (`/exit --delete` deletes it there).
  The status row's children segment counts its delegates there, and a join
  shows the steps' durations and a failed or canceled turn's line from its saved records
  there. A chi web too old for one of them says so in one line ("remote
  studio runs chi X, too old for this command through --remote: update chi
  there").
- A new session needs `--dir`, that machine's absolute path; `--model`,
  `--thinking`, `--llm-context*`, `--toolkit`, `--tool`, `--no-tool`, `--set`
  and `--parent-answers` are checked there (exit 2 for a bad one). With
  `--attach`/`--resume` they work as here (`--model`, `--thinking`,
  `--llm-context*` change the session; the others are named as ignored).
  `--non-interactive` (use `chi --remote studio send --new --dir D -m TEXT
  --wait`), `--verbose`, `--no-shared`, `--memory`, `--mute` and
  `--append-system-prompt` run on this machine only (exit 2).
- `@path` images are this machine's files (read and downscaled here, then
  uploaded); Tab completes `/` commands and `@path`, not memory names. The
  prompt history (↑) and `no_interrupt` / `no_default_input` are this
  terminal's.
- When chi web can't be reached the TUI says "(lost the connection to
  studio; reconnecting…)" and tries for about a minute, then "(reconnected)";
  what it missed is replayed or resynced. A prompt typed meanwhile is usually
  accepted there and runs when a worker reads it. A worker that went away
  (not stopped) is woken again. The end is worded by why: "The session was
  stopped on studio. Resume it with: chi --remote studio --resume ab12", the
  token refused, chi web unreachable, the worker gone, the session deleted.
- The version line names both machines: the worker older than what studio
  has installed (`chi --remote studio sessions restart ab12`), this terminal
  older than studio (`chi update` here).

#### Through an SSH tunnel

When that machine's chi web is only reachable over SSH — behind a sign-in proxy
(`chi --remote` through one isn't supported yet), or bound to 127.0.0.1 —
forward its port and add it as a remote like any other:

```sh
ssh -N -L 14567:127.0.0.1:4567 studio          # the host's web.port, 4567 by default
chi remote add work http://127.0.0.1:14567 --token-file work-token
# work-token: the host's $XDG_STATE_HOME/samagotchi/web-token
chi --remote work sessions list
```

- Pick a local port other than 14567 when this machine runs its own chi web.
- Forward only chi web's port, never a worker's: a session's Bridge answers
  only chi's own clients on its machine (they read its secret from the
  session's folder), so a forwarded worker port is of no use.
- A chi web there with `web.host: lan` or `web.public_url` asks every
  request for the token, one through the tunnel too (`chi remote add` without
  `--token-file` says so), and `chi --remote` sends it as Bearer. One on
  127.0.0.1 only takes a request through the tunnel as local, with no token,
  so any process here reaching the forwarded port acts as you there.
- `-L` binds 127.0.0.1 unless you write `-g` or `0.0.0.0:`: don't.
- Attaching works through the tunnel too (`chi --remote work --attach ab12`),
  plain http, no proxy.

SSH can forward a Unix socket as well, which is how claude-peer's pairing makes
a Claude session on this laptop reachable from chi on that machine
(`pair --inbox-socket <path>`): see [plugins.md](plugins.md), "chi on another
machine".

How it works inside (`SessionAccess`, chi web's routes, where each check runs):
[internals/remote-sessions.md](internals/remote-sessions.md).

### Participants

A session's owner can invite **participants**, people or agents, to review it through chi web on the LAN
(`web.host: lan`), each with a link of their own that reaches that one session:

```sh
chi share 3f9a1c2e --name Alex
# p_7c01d2aa  Alex (human, reviewer) · session 3f9a1c2e · expires 2026-10-30 14:02 · cap $2.00
# http://192.168.1.29:4567/?token=chp_…#s=3f9a1c2e-…
# (shown once: chi keeps only its digest; chi share revoke 3f9a1c2e p_7c01d2aa ends it)
chi share ls                    # every session's participants (--format json; never a token)
chi share cap 3f9a1c2e p_7c01d2aa 5   # Alex's turns may cost you $5, from their next one
chi share revoke 3f9a1c2e       # every link to that session; add a participant id for one
chi share revoke --all          # every link to every session
```

- The link is printed once (with a QR code at a terminal): chi keeps only a digest of its token. Send it to the
  participant; opening it sets their browser's cookie, as the owner's LAN link does. `--agent` marks an agent
  participant, which uses the token as `Authorization: Bearer` (e.g. `chi --remote` with that token).
- It works for 7 days (`--expires Nh` or `Nd`, 1 hour to 30 days; `web.participants.expires`), until it is revoked,
  or until the session is archived or deleted. A revoked link shows "This review link was revoked by the session's
  owner.", an expired one "This review link expired: ask the session's owner for a new one."
- **Review turns (experimental).** A participant can ask questions and comment through chi web's `POST …/turn`: each
  message is a turn of its own, queued behind the running one, that the model answers **read-only**. It may read the
  project (never its secret files or chi's own), and proposes changes as text or a diff for you to apply; it can't
  write, run, fetch, send notes or set reminders, and any approval or question is yours. A line starting `!` or `/`
  and images are refused. One running and 3 waiting turns per participant (`web.participants.queue`). You pay: each
  participant has a spending cap (`--cap DOLLARS`, default $2, `web.participants.cap`), counted from their turns'
  cost and the side requests they cause; at the cap their next comment is refused and you get a notice, and `chi
  share cap` raises it. `/stats` shows each participant's spend. Their turns go only to a worker with the review
  boundary: restart an older one. While your turn waits at the step limit (Continue or Stop), their turns wait too
  (still queued, still counted): they run, in order, once you continue, stop or send a turn of your own.
- **Pair turns: sharing a working session.** The read-only review turn is a review session's (`chi review`). Invite
  someone to a working session instead and their turns **act** in it with its tools, writes included, under your
  guardrails: what your rules allow runs, what they ask about comes to you as "Sam's turn asks: approve tool call?"
  with **Allow once** only (nothing session-wide or repo-wide is approved from their calls), and System 1 never
  answers for you. A write outside the project always asks you, whatever you approved before. It can't read or
  write secrets or chi's own files (keys, shell startup files, histories, credential files; by a file tool, a
  command, a glob or a variable), run chi, leave a command running in the background, read the environment or the
  keychain, sweep your home with find/tar/cp/grep, delegate, set or cancel reminders, send notes, start or stop
  background tasks, load tools, forget outputs or write memories, and it asks its questions in its reply, not on a
  card. Its commands run without your secret-named environment variables (`KEY`, `TOKEN`, `SECRET`, `PASS`,
  `CREDENTIAL`, `AUTH` in the name) and are killed at the execute limit rather than left running; a command that
  writes outside the project asks you, as a write does (the tmp dirs aside). A pair turn stops mid-turn once their
  cap is passed or their link ends. `chi share` and the panel's Invite
  warn you with what their turns may do and how many tool outputs the history holds, and only a link issued with
  that warning acts: links from before, or issued while the session's worker predated pair turns (the warning says
  so), stay read-only until you restart the worker and invite them again. Their messages carry a `pair` badge and no
  Apply (they acted already). This is an accident guard for a trusted team, not containment: a pair turn can still
  send what it reads out through `web_fetch` or your MCP tools. A link without `--identity` gets the same access:
  share it only with people you'd let type in your session.
- **The participant page.** Their link opens a page of its own (never yours): the session's title and status, who
  else takes part, and the conversation as a participant sees it: every prompt and reply with who wrote it, each
  step's tools as one line (`read docs/plan.md`: the tool and a project file's path, never arguments or output), and
  the reply streaming in while a turn runs. A "Comment or ask" box sends their comment (your composer's box, with its
  grip to resize or fold it and ↑/↓ over their own earlier comments from that browser; no `/` list, no images yet);
  their queued comments show with **Take back**; "waiting for the owner" shows while you answer a question or an approval of the turn; a refused
  comment (a `!` or `/` line, too many waiting, their cap reached) says why. On a phone it is the thread first with
  the box pinned, tool lines folded. They never see tool output or arguments, thinking, approvals or questions,
  memories, context notes, plugin and delegate input, cards, command output, the working set, cost, timing or host
  paths; secret-shaped text (API keys, tokens, private keys) is redacted too. An agent participant can wait on its
  turns' replies through the API, or with chi: its link's token in a remote, `chi --remote NAME send --wait -m "…" ID`,
  or `send -m`, which prints the turn id `--wait --turn T` takes; that wait exits 3 with `waiting_for_owner` while
  their turn waits on you (a question, an approval, your step-limit Continue) and 1 with `refused` (`cancel_reason`
  `revoked` or `cap_reached`) when their queued turn is refused before it runs. They can't reach anything else: every other route answers them 403, another
  session 404.
- **Apply.** Under each of a participant's review turns that has a reply, your page shows **Apply** (full width on a
  phone): it puts an Apply turn in your composer, not sent, `Apply this proposal from Alex's review turn 3f2a1c0d, as
  far as it fits the plan. It's quoted: …` and the reply quoted line by line. Read it, edit it, send it: the
  participant's text reaches the model as a quote under your line, never as your instruction. Don't send "do what
  Alex said" instead: that hands their words your tools.
- **Your side of it.** In the session bar, the participants chip (`participants · invite` while nobody has a link,
  then `2 participants`, with a green dot while one is on their page) opens the panel: each participant's state, last visit,
  spend against their cap, turns and expiry, with **Cap** and **Revoke** (revoking ends their page and stream and
  drops their queued comments). **Invite** takes a name, person or agent, the expiry and a cap, and shows the link
  once, with Copy, Share (a phone's share sheet) and its QR code. **Participant view ↗** opens their page for this
  session in a new tab, read-only, through the same server filter: exactly what they see. A participant's prompt
  shows their name in their colour, live and after a reload.
- `chi --remote studio share …` invites on studio: the link names studio's LAN address. Locally, the link names
  this machine's running chi web, on the port it listens on (it records it in `$XDG_STATE_HOME/samagotchi/web.json`;
  `web.port` when none answers there); without one on the LAN, chi says the link opens on this machine only (as
  the participant there too: a participant's link never opens as the owner). With `web.public_url` the link is
  `https://<public url>/#code=…`; with `chi web --tunnel tailscale` too (its `ts.net` name, which web.json records
  while that chi web answers on its port: a chi web on another port takes web.json over, and the link falls back to
  127.0.0.1). A tunnel link opens only on a device on your tailnet; the grant still decides.
- **A link for one account.** Behind an auth proxy that names the signed-in user (`web.public_url` with
  `web.proxy.identity_header`, or `chi web --tunnel tailscale`), `--identity EMAIL` binds the link to that account:
  it opens only through the proxy, signed in as EMAIL. A forwarded link opened by anyone else says "This review link
  is for another account …", and its one-time code still works for EMAIL. `chi share` says `· bound to EMAIL`, `chi
  share ls` `alex@corp · bound`, and the panel's Invite has an email field there. Without such a proxy `--identity`
  is refused (the link could never open); with one, an unbound invite gets a warning line. Through `chi --remote`
  it needs that chi web to have bound links (this version or newer), else it is refused before anything is issued.
  See [configuration.md](configuration.md#inviting-colleagues).
- The owner's own token and the `chi web --new-token` rotation are separate: rotating it ends no participant's link.
- **In the attached terminal.** A participant's message reads `Alex ▸ review> is step 3 right?`, the name in that
  participant's own colour (queued, running, and the last exchange when you join); yours stay as they were. A line
  says when someone is invited, revoked or their link expires (`participants> Alex joined (p_7c01d2aa)`,
  `participants> Alex left: their link was revoked`), within a few seconds and between turns, and the status row
  counts who is in the review (`2 participants`). The same commands work from there, on the attached session:
  `/share NAME [--agent] [--expires 3d] [--cap 2]` (the link and its QR code, once), `/participants` (the list),
  `/participants revoke [P]` (one participant, or everyone) and `/participants cap P DOLLARS`. They are `chi share`'s
  own, so under `chi --remote NAME` they reach that machine's chi web, as `chi --remote NAME share` does; an invite or
  a revoke made with them isn't announced again by the `participants>` line. The REPL
  (`--no-shared`) answers them with a note: a participant's turns run on the session's worker.

#### Review sessions

Share a **review session**, not a working one: a working session's history holds its tool outputs, and a review
turn's model may quote them. `chi review` starts one, idle:

```sh
chi review docs/plan.md docs/spec.md          # a fresh session in this project for those files
# 4b7e9a01-…  review · docs/plan.md, docs/spec.md · idle
# open it: chi --attach 4b7e9a01 or the web
# invite someone: chi share 4b7e9a01 --name NAME
chi review --from 3f9a1c2e docs/plan.md       # a review of a working session: its recap, not its transcript
```

- Each FILE is a **subject**: a file in the session's project (the git work tree of its folder, `--dir`, else
  here), relative to that folder or absolute. A missing file, a folder, a file outside the project, a secret
  (`.env*`, keys and certificates, credentials files, a git config) or chi's own refuses the review with one line:
  `chi review: .env can't be a review subject: …`. At most 20.
- `--from ID` (an id, a prefix, `last:ID`) starts a **review fork**: a new session in ID's folder, on its model
  (`--model` to change it) and setup, seeded with a fresh recap of ID (its live worker is asked first, as a continue
  asks), never its transcript. ID keeps running, unarchived, its delegates its own. Its FILEs are relative to ID's
  folder.
- `chi --remote NAME review … --dir /path/there` starts it on that machine; its chi web checks the files there.
- Sharing a working session (one `chi review` didn't start) still works, with a warning on stderr that says how many
  tool outputs its history holds: `chi share: warning: 3f9a1c2e is a working session, not a review session: a
  participant's review turn can quote what its history holds (42 tool outputs so far). … (chi review --from 3f9a1c2e
  starts one)`. On the web the participants panel shows the same words before its Invite, with **Start a review of
  it**, and again above the link an invite gives.

How it works inside (grants, the gate, the routes, the audit trail):
[internals/participants.md](internals/participants.md).

## Runtime Model Switch (Assist Mode)

In interactive assist mode, you can switch the request model without restarting:

- `/model <name>`: set a session-scoped model override.
- `/model host:model` or `/model host:alias`: qualified host routing (only `:` names a host; `openai/gpt-4o` is a model id). `host:alias` applies the alias; an alias whose target names another host is refused (`alias 'tiny' names host 'box', not 'openrouter'`). Aliases apply once: an alias pointing to another alias sends that name as written.
- `/model --default <name>`: set session model and persist as new default (`default.model`) in `config.yml` for future sessions (supports `host:model` full ref). It writes only the file: an exported `SAMAGOTCHI_DEFAULT_MODEL` (or `--model`) still wins over it.
- `/model <name> --alias <alias>`: create alias for current effective model (alias value may be bare or `host:model`).
- `/model`: show the effective model (and default when diverged: `runtime model: <effective> (default: <default>, profile=<name>, <source>)`, e.g. `profile=qwen36, server (chat_template)`). When the session's prompt carries model notes the line ends with `; notes: model_notes_deepseek (system, 612 chars)`; a switch's `runtime model set to …` names the new model's ([Memory](memory.md#model-notes)).
- `/model clear` (or `default`/`none`/`off`): clear the session override, reverting to the configured default.
- Once the session has a model reply, a switch to another model asks first from a web tab or a TUI (the new model
  has no cache of the conversation): the reply names the line with `--yes` that applies it, flags and all
  (`/model qwen --alias q --yes`); `--yes` (or `-y`) applies at once. A typo (an unknown host, a bad alias) is an
  error before any question. See "Changes that restart the prompt cache" in [configuration.md](configuration.md).
- `/guardrails`: the guardrail rules (by source), what failed to load, your stored approvals, and System 1's
  recent auto-allows; `/guardrails revoke N` removes approval N and `/guardrails wrong [N]` flags an auto-allow
  this session should have been asked about (see [Guardrails](guardrails.md)).
- `/models`: list model ids aggregated across all `hosts:` (an alias shows next to its id: a bare alias on every host listing the id, a `host:model` one only under its host; grouped `host (host:port):` with per-host `unreachable` warnings, e.g. an unset `api_key_env`; lists cached 60s, 10 minutes for a remote host; lazy — no startup prefill). Ids the host declares under `hosts.<name>.models` come first, as `rr/x (config)`, and don't count toward the cap; an unreachable host keeps them, under its warning, as `rr/x (config, host down)`. At most 20 ids per host, then `… and N more`; `/models <text>` lists every id containing `<text>` (any case), e.g. `/models qwen` on OpenRouter.

Notes:

- The switch updates the request `model` field, routes to the matching host (`HostRegistry#resolve`), and resolves the prompt profile again (config, the server's chat template, the name; see "Prompt profile" in configuration.md).
- The ctx % follows the switch at once: the last turn's count against the new model's window (the web's info bar, the attached TUI's status row, a client that joins later), recounted at the next generation. When the new window can't be resolved the web shows `ctx ?` and the attached TUI's status row drops its ctx until then ([context telemetry](internals/context-telemetry.md)).
- After a switch `/stats` (and the web's ctx tooltip) splits the session's tokens, cost and speed per model, with what each switch prefilled on the new model: the `models:` block ([Session commands](#session-commands)).
- Without `--default` the command is session-scoped and does not rewrite config files.
- With `--default` the new default is written to `~/.config/samagotchi/config.yml` (honoring `XDG_CONFIG_HOME`) and takes effect for all new sessions; the current session's effective model is also updated immediately. Bare aliases and `host:model` are both valid.
- `--default` and `--alias` change only their one key's line in `config.yml` (`default.model`, or the alias under `model_aliases:`): comments and the rest of the file stay as written, a symlinked file is written through and keeps its mode. When the edited text wouldn't read back as the expected settings (a flow-style section, anchors), chi writes the whole file out from the parsed data instead, which drops its comments.
- A worker reads `hosts:` from config.yml when it starts (not from the chi that started it).
- The idle recap uses the session's current model (a switch counts from the next recap), unless `recap: {host_ref, model}` pins one.

## Session recap

A short recap of the session, for when you come back to it: what you were
working on, what came of it and what is still open, not a turn-by-turn log.

- It is written once the session has sat idle for `recap.inactivity` (180 s)
  after at least `recap.min_user_turns` (2) prompts, and as a worker (or the
  REPL) exits, when something new was said since the last one. Each one
  builds on the previous recap, so it only sends what is new.
- It is saved with the session (`<session>/recap.json`) and shown as a dim
  `recap>` block when you attach or `--resume`, noting how many turns came
  after it (`recap (before the last 2 turns)>`). One written while you sit at
  the prompt prints there.
- `/recap` shows the saved one and asks for a new one when the chat moved on
  (`writing a recap…`, then the recap when it comes). The web answers the bare
  `/recap` with a note (the recap shows there by itself).
- `/recap off` and `/recap on` turn the recap off or on for this session, at
  once and in any UI (the web composer too, and mid-turn); `/recap default`
  goes back to config.yml's. The reply says both: `recap: off (this session;
  config.yml: on)`. It is the session's own `recap.enabled`, as `--set
  recap.enabled=false` gives it (see [Per-session
  settings](configuration.md#per-session-settings)): saved with the session,
  so a respawned worker keeps it, and it beats config.yml (`/recap on` under
  `recap: false` turns it on here). With it off, `/recap` says so.
- One written while a continue offer waits (the last turn ran out of steps)
  says that turn stopped before the task was finished. Answering `no` counts
  as activity, so the next recap no longer says so.
- It is 2-4 sentences; `recap.sentences` sets another length (`3`, `5-7`,
  up to 10; `--recap-sentences`, `SAMAGOTCHI_RECAP_SENTENCES`). A change
  shows from the next recap written, and updates keep to it.
- It uses the session's own model unless `recap:` names one;
  `recap: false` turns it off. See configuration.md.

## Time gaps (terminal)

Both terminals (attached and the REPL) show when things happened without a
time on every line:

- A dim divider marks a quiet gap of 10 minutes or more, before what comes
  next: `── 14:32 · 47 min later ──`, the date added when the day changed
  (`── Sat 24 Oct 09:10 · 13 h later ──`). The gap runs from the end of the
  last activity (a turn's end, a reminder, a context note, a recap) to the
  start of the next (a prompt, yours above its line or another UI's, a
  reminder turn, a note, a recap), so nothing is marked during a turn or
  between turns run back to back. A command (`/stats`, `!cmd`) is no
  activity.
- Attaching to a session whose last activity was 10 minutes ago or more
  says when, after the join block: `── last activity 14:32 · 47 min ago ──`
  (from the newest timed message, else the saved recap's time). With
  `--resume` the REPL marks the gap before the first prompt instead.
- A recap names the local time it was written: `recap 14:32>`, `recap 14:32
  (before the last 2 turns)>`.
- Only live activity and the join: neither terminal replays the history, so
  older gaps aren't marked. `--non-interactive` prints none.

## Tool Activity Log

Samagotchi now prints a concise, human-friendly tool activity log in normal
chat output. Each tool call is summarized as:

`tool> <action> (<tool> <param-preview>): <status>`

Examples:

- `tool> reading file (read path="README.md"): ok`
- `tool> running command (execute command="bundle exec rspec spec/..." ): error`

Parameter previews are normalized to one line and truncated to keep output concise.

This is separate from verbose mode:

- Default output shows short activity status lines only.
- `-v/--verbose` prints the debug log's records (raw LLM responses and full
  tool call/result payloads among them) to stderr as well; see
  [Debug Log File](configuration.md#debug-log-file).

## Persistent Prompt History

Assist mode keeps a persistent prompt history across restarts, one for every
chi prompt: the REPL, attached mode and the `chi web` composer (↑/↓ there)
share it.

- Default history file: `$XDG_STATE_HOME/samagotchi/history.json`
- XDG fallback when unset: `~/.local/state/samagotchi/history.json`
- Optional override: `history.file` in the config, or
  `SAMAGOTCHI_HISTORY_FILE=/custom/path/history.json`
- Stored entries: most recent `100` prompts (and `!commands`; not `/commands`
  or `!rollback`)
- Format: JSON array of prompt strings, mode 0600. Each write holds
  `<file>.lock` and replaces the file whole, so a TUI and the web writing at
  once keep both lines (a symlinked history file becomes a regular file).

Behavior details:

- Prompt history is loaded on startup before the first `>` prompt.
- A running REPL or attached TUI picks up the lines other chi processes (the
  web, another terminal) added: before each `>` prompt and on the first ↑ at
  an open one (Ctrl-P, vi `k` too), when the file changed, its new lines join
  the ↑ list after the ones already there, without a
  restart. A `/command` you typed stays under ↑ too. `chi scratch` keeps its
  own list and writes nothing.
- The web records a prompt once its session's worker took it (a refused or
  timed-out send isn't saved), a `!command` likewise; an image-only message
  isn't saved. `chi send`, `delegate` and plugin turns aren't typed at a
  prompt and aren't saved. With `chi web --web-host lan` the list is served to
  token holders (`GET /api/history`), as the sessions are.
- Only real user prompts are persisted.
- Continue-flow inputs (`yes`, `no`, `no, <reason>`, `/continue`) are not persisted as prompts.
- In assist mode, pressing `Tab` on an `@`-prefixed token (for example `@lib/sama`) completes project file and directory paths while preserving the `@` prefix.
- Press `Tab` twice to cycle/show multiple matching candidates, similar to IRB completion behavior.
- History read/write errors are ignored so the session continues uninterrupted.

## Status Line

The REPL and attached mode show one status row under the prompt, drawn when what it says
changes:

```
status> Coordinator | model=Qwen3.6-35B | ↳ 3f2a1c9e | ctx=12.3% (under20) | mem: notes, cli_usage | muted: gh-helper
status> model=Qwen3.6-35B | ⑂ 2 running · 1 waiting | 2 participants | ctx=8.1% (under20) | mem: skill_coordinator
```

- The session's title first, when it has one (`/title`; not the first message a session without one is named by),
  cut to 32 characters and to a third of a narrow row. It follows `/title` from any client (this terminal, another
  one, the web's `✎`, `chi send`) without a restart: the worker's `command_ran` for it carries the new title.
- `model=`: the model in use, `(default: …)` beside it when it isn't the config's default, and
  `model=<served> (served; asked <name>)` when the server said it served another model (not for one its host's
  `hosts.<name>.models.<id>.served` names; see [configuration](configuration.md#models-a-host-serves-but-doesnt-list)).
- `↳ <id>`: the session that delegated this one.
- `⑂ …`: this session's delegate children (forks aren't counted): how many run and how many wait
  for an answer; only the counts there are, nothing when none does (`/children` has the rest:
  done, failed, whether a reply was reported). The terminal reads them from the children's files
  (the delegates in the session's `delegates.json`): an attached one when it joins, when a turn
  ends and when a delegate's report merges into a turn, the REPL whenever it draws the row. A
  child that starts waiting on an approval (which doesn't wake the parent) shows at the next of
  those.
- `N participants`: who is in the session's review now ([Participants](#participants)), attached only.
- `ctx=`: the kernel's context estimate and its bucket, updated during a turn (on hosts that
  report none, `api: openai`, at the turn's end).
- `mem:`: the memories the session read, with its `--memory` list; `muted:` its `--mute` list.
  Up to 8 names each, then `+N`.
- While a turn runs it ends in `· typing goes in at the next step (/cut, /queue)`; the hint is the first thing dropped
  on a narrow terminal.
- The row is cut to the terminal's width. Without a live region (output or input not a terminal,
  `TERM=dumb`) it prints as a line when it changes.
- `SAMAGOTCHI_STATUS_LINE` / `status.line` (default `on`): `off`, `false` or `0` hides it.

## Tool Tally

A long, tool-heavy turn says what it has been doing. From the turn's 3rd tool call,
a dim row under the activity row tallies its calls, with no model call:

```
12 tool calls (2 failed) · execute ×7 · read ×3 · edit ×2 · last: execute command=bundle exec rspec
```

It lists the top 3 tools by count (ties go to the tool used first), the failed calls
(a call a guardrail or an approval blocked counts as a call, not as failed) and the last
call with its parameters, cut to the terminal width. It starts over with each turn.

- The REPL and attached mode: the second row of the activity slot, shown while the slot is (the
  model generating or a tool running). Joining a turn mid-way seeds it from the turn so far.
- The web: the activity panel's summary reads `activity · 12 tool calls (2 failed) · execute ×7 · …`
  (without `last:`: the rows show it).

## Activity Row

While a turn runs, one row above the prompt says what it is doing, the spinner frame first
(the REPL and attached mode alike):

- `| thinking…` while the model starts, then `| thinking · <sentence>`: the newest complete
  sentence of its thinking, or of its answer (`writing ·`), like the web's thinking ticker: the
  same sentence rules (a list number such as `118.` is no sentence end; a newline is one), and the
  row changes at most once every 1.5 s so it doesn't flicker. A long sentence is cut with `…`, and
  inline markdown is left out.
- `| waiting for the first token… 5s` after 2 s with nothing streamed.
- `| running execute…` while a tool runs (its `tool>` line prints when it ends).
- `| ↻ retrying (ECONNREFUSED) in 0.5s, 1/3` while a failed request is asked again: why (the HTTP status such as
  `503`, the error such as `ECONNREFUSED`, or `stream dropped`), the wait, and the retry of all there will be.
  The web's timing line words it the same.
- `| mcp: starting servers…` while a plugin's slow setup (an init task) runs, between turns too;
  `mcp> ✓ …` prints when it is done.

The spinner turns with time, so a turn that gets no chunks still looks alive. Without a live
region (output or input not a terminal, `TERM=dumb`) there is no activity row; the turn's lines
still print as they end.

## Thinking-Phase Cancellation

While a turn runs, you can cancel it without exiting the process:

- Press `Ctrl-C` to cancel the active request.

Behavior notes:

- Cancellation returns control to the prompt immediately; what you typed there stays.
- The turn ends with one line, `■ turn canceled (Ctrl-C) · 3.1s` (`■`, a stop someone chose, in amber), and for a prompt turn a dim
  `partial progress kept; !rollback restores the pre-turn state` under it (a canceled continue is back where it
  started). A failed turn ends with `✕ turn failed: <summary> · 2.0s` and a dim `prompt restored for retry` when it
  failed before it got anywhere, or on a context overflow (the conversation goes back to before it); one that got to
  tool steps keeps them, as a cancel does, with the dim `partial progress kept; !rollback restores the pre-turn state`
  (the model reads a note saying how many steps ran and why it stopped; `chi send --wait` and a delegating parent
  read `the turn failed after N tool steps: <why>; its work so far stays`). The
  REPL and attached mode say the same; the web ends a failed turn whose steps stayed with `✕ turn failed: <summary>;
  partial progress kept (!rollback restores the pre-turn state)`, after a reload too, and says `■ canceled (Ctrl-C)`
  (`stopped` for its Stop button, `by a hook` for a hook's). A turn a bundle's plugin stopped names it: `■ turn stopped by loop-guard` (the web:
  `■ stopped by loop-guard`).
- Visible text the canceled request had streamed stays in the conversation, marked `[interrupted]`, so the next
  message (or a continue) picks up from the half-finished reply; the canceled request's thinking and any unfinished
  tool call are dropped.

## Iteration Limit Behavior

- A turn's step limit (model ↔ tool rounds) is `turn.max_iterations` in config.yml (env
  `SAMAGOTCHI_TURN_MAX_ITERATIONS`, default `300`, an integer of 1 or more). `--no-interrupt` and
  `--non-interactive` turns get the larger of 1000 and it. Reminder turns follow it too.
- Tool side effects that already ran before the limit are not rolled back.
- `Samagotchi::KernelLoop#run` returns a resumable result object with the visible output plus the accumulated
  conversation. If the limit is reached while tool calls are still pending, the result is marked resumable so callers
  can continue from the saved conversation instead of restarting from scratch. The session's `last_turn` records it
  (`"exhausted": true, "limit": N`).
- In a session's worker (plain `chi`, the web, `chi send`) the offer waits as a question between turns, the
  **step-limit question** (kind `continue`, header "Step limit", options Continue / Stop): the session reads
  `waiting` in the lists, the web shows a card with Continue and Stop and a reason box (a reason goes with Stop), the
  session card's badge reads `out of steps` and the bell rings ("hit its step limit"). `chi send --wait` exits 3 with
  it and `chi answer --option Continue|Stop` answers it (see [chi as a sub-agent](sub-agent.md)). It can't be
  dismissed. A new message instead (or a due reminder) drops it and the partial turn stays; a typed `/continue …`
  answers it too. If the worker exits (a stop, a crash), the offer goes with it.
- In the attached terminal (`chi --attach`) the question's prompt reads the continue words: Enter alone, `yes`, `y`
  or `/continue` continue; `no` stops; `no, <reason>` stops and tells the model why; `1` and `2` pick the options.
- In the plain REPL (`--no-shared`) the CLI asks at the `? ` prompt, with the choices listed under it: `yes` (Enter
  alone, or `/continue`) resumes, `no` stops, and `no, <explanation>` stops while keeping the reason in conversation
  context. Once answered, one line stays: `? The turn ran out of iterations. Continue it? → no, too slow`.
- Continue goes on with the same turn: the model keeps the reasoning (thinking) of the run it continues, on chat and
  native hosts, so a local server's prompt cache stays warm. Continue's text is a steer: on a chat host the reasoning
  starts again from it. See "Reasoning history" in [configuration.md](configuration.md).
- Stop keeps the interrupted turn's work in the conversation, as a Ctrl-C or a new prompt does, with a note for the
  model that it wasn't continued (or your reason); `!rollback` still erases it.
- `--non-interactive` (`chi -p`) has nobody to ask: the turn ends there. A `chi send --wait` on a session nobody can
  answer (an older worker) reports `limit` (exit 1) with how to continue it: `chi send ID -m '/continue yes'`
  (not under `guardrails.parent_answers: hard`, config.yml's or the session's own: a parent agent's `/continue yes`, sent with `chi send` or typed into a
  piped `chi --attach`, is held to it as `chi answer --option Continue` is, and refused there).
- The check-in bundle's card closes as the turn ends, before the step-limit question opens, so the two never stand
  together; with check-in's default `after: 50` and the limit of 300 a long turn shows check-in cards (at 50, 100, …)
  well before it.
