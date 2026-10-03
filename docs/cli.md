# CLI and REPL

## Commands

- `chi bootstrap [HOST[:PORT]|URL]` — first setup: find the model server (llama.cpp or OpenAI-compatible), pick the model, send a test request and write config.yml, or add a `hosts:` entry to an existing one (see [First setup](#first-setup))
- `chi` — start a session in a background worker and attach the terminal to it, so the Web UI (or another terminal) can share it (see [Sharing a session](#sharing-a-session))
- `chi -p "your prompt"` — run a prompt, then stay attached
- `chi -p "your prompt" --non-interactive` — run a prompt, print the answer, exit
- `chi --resume <session-id>` — resume a prior session (in its worker)
- `chi --no-shared [--resume <session-id>]` — the plain in-process REPL instead, for this run
- `chi scratch [options]` — a one-time session in the plain in-process REPL, in this folder, that leaves nothing behind (see [Scratch sessions](#scratch-sessions))
- `chi --attach <session-id>` — attach the terminal to a session's worker (e.g. one started from the Web UI), waking one if it has exited
- A session id can be shortened to any unique prefix (like git): `chi --attach 2ea8`. `--resume`, `--attach`, `sessions stop`, `sessions archive` and `sessions delete` take one; an ambiguous prefix lists the sessions it matches.
- `chi web [--port 4567] [--open] [--scope=all]` — start the Web UI (single localhost port session control plane) on this git project's sessions (`--scope=all`, or a folder in no repo: every session); if a chi web already runs on the port, print (with `--open`, open) its page for this folder and exit. Something else on the port (an older chi web too) exits 1 with "port N is in use"
- `chi web --web-host lan` — the Web UI on your home network too, for your phone: a link with an access token and its QR code (see [chi web on your phone](#chi-web-on-your-phone)); `chi web --new-token` replaces the token
- `chi web --web-markdown` — opt in to sanitized Markdown rendering for completed assistant messages
- `chi web --web-view turn` — draw turns with the turn view (each turn as one block of steps, the running one at the bottom of the history) instead of the default stage view (the running turn pinned above the composer); `?view=stage|turn` on the page URL overrides it (see [Web views](#web-views))
- `chi sessions list|stop|restart|archive|unarchive|delete|prune|clean` — manage persisted sessions; `list` shows this git project's, `list --scope=all` every one, a delegated session with `↳ <parent>`, `list --archived` the archived ones too (see [Sessions](sessions.md)). A usage error (an unknown subcommand or flag, a flag missing its value, `stop`, `restart` or `delete` with no ids, a bad `list --format` or `--scope`) exits 2; an unknown or refused session exits 1
- `chi note [--source NAME] [-m TEXT] (ID|PREFIX)... | --all` — add a context note (TEXT or stdin) to sessions: background the model sees on its next turn; it starts no turn (see [Sessions: Context notes](sessions.md#context-notes))
- `chi send [-m TEXT] [--image PATH]... (ID|PREFIX)...` — send a message to sessions as if typed there: a turn starts (or a running one picks it up); piped stdin goes above `-m` as quoted context, and `--image` attaches images (see [Sessions: Sending a message](sessions.md#sending-a-message)); `--new` starts a session with it instead, and `--wait` prints the answer (`--wait ID` with no message waits for the next reply without sending; `--format json` prints one JSON object instead; exit 3 a question waits, its options on stderr; exit 4 `--timeout` passed with the turn still running; see [Starting a session](sessions.md#starting-a-session))
- `chi answer ID --question QID (--option N|LABEL)... [--text T] [--timeout S] [--format json]` (or `--dismiss`) — answer the question a session waits on (the one `chi send --wait` exited 3 with), then wait and print what comes next as `chi send --wait` does: the reply (0), the next question (3), still running after `--timeout` (4). `--option` is 1-based or the label, repeated on a multi-select question; `--text` is free text, or a Deny's reason; `--dismiss` leaves it unanswered and the model finishes its reply. A question no longer open (the web answered first) isn't answered again: it waits for that turn's reply. An option the question doesn't offer exits 2; a worker that is gone exits 1 (`send the task again: chi send --wait -m "…" ID`). An approval can be denied, not allowed, unless `guardrails.parent_approvals: once` (a convention, not a security boundary; see [Guardrails](guardrails.md#approvals-from-a-parent-agent))
- `chi desktop install|upgrade|uninstall|status` — the macOS "Send to chi" helper: a Service and a ⌃⌥⌘N hotkey that send text or images to a session (live, stopped or new) as a message (⏎, a turn runs) or a context note (⌘⏎) (see [Desktop helper](desktop.md))
- `chi models [--format text|json] [--timeout S] [TEXT]` — list the models every configured host offers, as the names `--model` takes (see [Listing the models](#listing-the-models))
- `chi self` — print version, source dir (checkout or installed gem), config/memory/session paths, model/host and bundles. Run by a session's `execute`, the `model` row (and host, loop, profile, thinking, served model) is **that session's** model, labelled `(this session <id8>; default …)`; elsewhere it is the default, `(default)`. `model key` is the memory overlay key (`<name>.<key>.md`). `chi self --model` prints only the model a new session starts on, an alias resolved to its target (the desktop helper's hint)
- `chi update [--dry-run] [--no-gem] [--no-bundles] [--no-desktop]` — update an installed chi: the gem, the system bundle, the shipped bundles you installed and the desktop helper, in one table (see [Updating](#updating))
- `chi bundle install|upgrade|uninstall|status|diff|list|build|trash` — manage memory bundles (see [Bundle hooks](hooks.md#bundle-hooks-unified-workflow-bundle)); `list` shows the installed ones and the ones shipped with chi, which `install <name>` installs; `core` and `dev` are profiles that install a set of them (see [Bundle profiles](memory.md#bundle-profiles-core-and-dev),  [Guardrails](guardrails.md), [Plugins](plugins.md#the-btw-bundle), [the mcp bundle](plugins.md#the-mcp-bundle) [the loop-guard bundle](plugins.md#the-loop-guard-bundle), [the check-in bundle](plugins.md#the-check-in-bundle) and [the skills bundle](plugins.md#the-skills-bundle)). `trash` lists and empties the bundle trash (moved files from uninstalls/upgrades). A usage error (an unknown subcommand or flag, a missing argument, a bad `build --scope`) exits 2, as for the other subcommands. Plain `chi` and `chi web` exit 1 on an unknown flag, a flag missing its value or a stray argument

### First setup

`chi bootstrap TARGET` names the model server and writes the config for it:

```sh
chi bootstrap 192.168.1.29:8081          # host:port (an IP or localhost: port 8080 when none; a domain: https 443, then http 80)
chi bootstrap https://openrouter.ai/api/v1 --key-env OPENROUTER_API_KEY
chi bootstrap                            # try localhost 8080, 11434, 1234, 8000
```

- **What it is.** llama.cpp's `/props` answering means the native API (no
  `api:`); otherwise `GET /v1/models` answering means an OpenAI-compatible
  server (`api: openai`). A URL with a path is the API base as given
  (`…/api/v1`); a domain without a scheme is tried over https, then http.
  Each request is tried once, with 5 s timeouts, so a refused port answers
  at once.
- **The key.** A server that answers 401/403 wants an API key: `--key-env VAR`
  names the environment variable holding it (on a terminal chi asks for the
  name). Only the variable's name is written, never the key.
- **The model.** One model is taken; with several, `--model ID` picks one
  (a terminal gets a numbered list, a script the ids and exit 2). A llama.cpp
  server also shows its context size and the prompt profile its chat template
  matches.
- **The test.** One short chat request ("test: answered in 1.1 s"); `--no-test`
  skips it. A failed test still writes the config, says so and exits 1.
- **The file.** With no config.yml it writes a small commented one:
  `default.model` as `<host>:<model>` and one `hosts:` entry named `local`
  (localhost), `lan` (an IP) or after the domain (`openrouter`); `--name`
  sets it. An existing file is left as it is apart from the new entry, added
  at the end of its `hosts:` block (it gets a `hosts:` block, with a
  `default` entry for its `server:` first, when it has none), after a backup
  to `config.yml.bak-<time>`. `default.model` is set only when the file has
  none. A server already in the file writes nothing; a file in YAML flow style
  or with anchors gets the lines printed to paste instead. `--dry-run` shows
  what it would write.
- **The bundles.** Unless writing the config failed, it installs the system
  bundle and the `core` profile (loop-guard, check-in, guardrails), one line
  each; on a terminal it then asks `Also install dev (known-names, mcp, btw,
  skills, source-links)? [y/N]`. Run again, it installs nothing new: a bundle
  you uninstalled stays out ([Bundle profiles](memory.md#bundle-profiles-core-and-dev)).
  A bundle that fails to install makes the exit 1. `--dry-run` says what it
  would install.

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

- A default-host id is bare, except one with a `:` (`qwen3:8b`), which is written `<host>:qwen3:8b` so it can't
  read as a host name. An id that an alias of the same name hides is left out.
- Each run lists anew (no cache); `--timeout S` caps the wait for the hosts (default 4 s). A host that fails or doesn't
  answer in time is noted on stderr (`chi models: box: no answer in 4 s`).
- `--format json` prints one object: `default` (and `default_typed` when it was set as an alias), `default_host`,
  `models` (`name`, `host`, `id`), `aliases` (`name`, `ref`, `host`) and `warnings`. The desktop helper's model
  chooser reads it.
- Exit 0 when any host listed its models, 1 when none did (the default is still printed), 2 on a usage error.

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
workers                      2 live on 0.2.0: they move to 0.3.0 at idle exit (30 min) or chi sessions stop 2ea8c1f0 91b0d2aa
Also shipped, not installed: dev (mcp, skills, source-links) (chi bundle install NAME)
done
```

- **The gem.** It asks rubygems.org for the newest samagotchi (5 s timeout)
  and, when that's newer, runs `gem install samagotchi` with the gem command
  of the Ruby chi runs on (the real one, not a mise/rbenv/asdf shim). Then it
  hands over to the new chi, which does the rest and prints the table. Old
  versions stay installed: running workers and an old `chi web` still use
  them (so don't `gem cleanup` while they run). Offline, the row says
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
  sources changed (or the Ruby it runs moved); otherwise only its launch file
  is refreshed. See [Desktop helper](desktop.md).
- **Running processes** are reported, never stopped: live workers on another
  version, and a `chi web` on `web.port` running an older chi (sessions it
  starts run that version too: restart it).

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

| Flag | Purpose |
|------|---------|
| `-p`, `--prompt TEXT` | Feed `TEXT` as the first turn (also prefill-equivalent; `-p` feeds **and** runs). |
| `--non-interactive` | Run a single turn then exit the REPL (sets a high iteration cap; implies `--no-interrupt`). Harmless no-op when given without `-p`. |
| `--resume SESSION_ID` | Load a prior session's history instead of creating a fresh one. |
| `--shared` | Run the session (new, or `--resume`'s) in a background worker and attach to it: the default, and the way to get it when `session.shared` is off. See [Sharing a session](#sharing-a-session). |
| `--no-shared` | Run the plain in-process REPL for this run. |
| `--attach SESSION_ID` | Attach to a session's worker, waking one if it has exited. |
| `--model NAME` | Use this model for the run (overrides the configured default and a resumed session's model). |
| `--thinking LEVEL` | How much the model thinks this run: `off`, `low`, `medium`, `high` or `default` (env `SAMAGOTCHI_THINKING_LEVEL`), over the config's levels. A session already running keeps its own. See "Thinking" in configuration.md. |
| `--profile NAME` | Prompt profile (`qwen36` or `gemma4`) for every model in this run, over config and the server's template (same as `--model-profile`, env `SAMAGOTCHI_MODEL_PROFILE`). See "Prompt profile" in configuration.md. |
| `--memory NAME` | Preload a memory entry into the system prompt (repeatable; a comma list too). Merged under the config.yml `memories:` baseline. Works attached: the list is stored on the session, so its worker builds the same prompt on every respawn. |
| `--mute NAME` | Hide a memory from this session (repeatable; a comma list too): its index line is not in the prompt, `memory_read` refuses it, the identity auto-load skips it, and it is dropped from the preloads (config baseline or `--memory`). A name matches in both scopes (`gh-helper`, `project/gh-helper` and `gh-helper.md` all hide `gh-helper`). Nothing on disk changes. See [Muting a memory](#muting-a-memory). |
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
  --resume ID` (exit 1). Ctrl-C saves the session with the prompt and a
  cancel note and exits 130.

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
- No child sessions: the `delegate` tools are not offered, and a plugin's
  `ctx.sessions.fork` (btw's side session) refuses, since they would outlive it.

### Sharing a session

Plain `chi` runs the session in a background worker and attaches the terminal
to it (`session.shared`, default `true`). A worker's session can have any number
of UIs at once: the Web UI and attached terminals (`chi`, `--resume`,
`--attach`). They all see the same turns as they happen, and any of them can send
a prompt, also while a turn runs (it merges into that turn as steering). The
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
  attached, or reminders are set. A web tab you just closed can count as
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
older chi (from before an upgrade) takes turns but not commands; the attached
terminal and the Web UI say so, with that restart line.

`chi sessions restart ID...` hands each session to a new worker on the newest
chi installed, without stopping it: an attached terminal and the web's tabs
move to the new worker. It is refused, with the reason, while something would
be lost: a turn running or queued, a question or approval waiting, reminders,
a `/btw` still running, an approval relayed from a delegate, or background
tasks the session started. A session with no running worker needs none (its
next prompt starts one on the newest chi), and a worker from before restarts
needs `chi sessions stop ID`. The Web UI's `POST /api/sessions/:id/restart`
does the same (409 with `reason` and `detail` when it can't).

`chi sessions archive ID...` hides sessions from every list (the terminal's,
the web's, `list_sessions`) and keeps them for good: the retention sweep never
deletes an archived session, nor counts it. Its delegates go with it. A live
worker is stopped first; a session running a turn (or with a delegate running
one), open in a plain REPL, or a `chi scratch` one is refused. `chi sessions
list --archived` shows them too, marked `[archived]` (`archived: true` in
`--format json`); `chi sessions unarchive ID...` brings them back, and so does
a message you send to one (the web, an attached terminal, `chi send`), but not
a delegate's follow-up or a reminder. The web archives from the info bar
(`archive`, before `stop`); "include archived" by the all-sessions search
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
- `--attach ID` or `--resume ID` with either flag: the session's prompt is
  already built, so the flags are ignored with one line,
  `(--mute applies to a new session; <id>'s prompt is already built)`.
- The status row shows `mem: <used and preloaded>` and `muted: <names>`; the
  Web UI's info-bar tooltip shows `memories: … · preloaded: … · muted: …`.
- The `read` tool on `memories/<name>.md` is not refused (a guardrails rule
  can protect the path if wanted).

### Session commands

`/help` lists the commands this session takes, the installed bundles' too, each
with a line on what it does. `/stats` shows the session's numbers: turns, tool
calls (by tool, with errors), iterations, tokens in/out summed over every
request, generation latency, cancellations, retries, context used and window,
the prompt profile and the model the server says it ran. `/recap` is in
[Session recap](#session-recap), `/model` and `/models` in [Runtime Model
Switch](#runtime-model-switch-assist-mode).

### Typing during a turn

The prompt stays open while a turn runs, in an attached terminal and in the plain
REPL alike:

- A line you submit merges into the running turn at its next step (after the
  current tool call or answer), and `(1 message merged into the running turn)`
  says so. An answer the model finished just before the merge is printed first.
  A line that comes after the turn's last step runs as the next turn, and so
  does one sent after Ctrl-C: it doesn't merge into the turn being cancelled.
  Reminder turns take merged lines too.
- `/stats` and `/recap` answer at once, and in an attached terminal so do `/help`
  and a plugin's anytime command (`/btw`). Other commands (`!cmd`, `/model`, `/models`,
  `!rollback`, `/continue`, `/guardrails`) say `busy: wait for the turn to end`
  and go back into the prompt, so Enter runs them once the turn ends. A
  one-word `/word` no command answers (`/modle`) is not steering text either:
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
- **The Web UI**: paste or drop images into the composer. Each shows as a chip
  (× removes it) and is sent with the message; an image alone is sent as
  `[image: name]`. Messages show thumbnails; a click opens one full size.
- **`chi send --image PATH`** (repeatable, up to 20) with a message, from a
  script or another terminal: `chi send --image shot.png -m "why is this red?"
  3fa2`. The attached terminal and the web show it like an image typed there.
- **The desktop panel** (macOS, [Desktop](desktop.md#images)): a screenshot on
  the clipboard, an image selected in Finder, or one dropped on the panel goes
  as an attachment with the message.

Images are downscaled to a 1568 px long side (with `sips` on macOS or
ImageMagick; without either, a larger image is refused with a hint) and stored
next to the session in `<session>/images/`, and the session file keeps small
references to them. Each request sends the newest 20 images of the conversation;
older ones become a line like `[image shot.png 1280×800 not sent: only the
newest 20 images are sent]`.

A model that can't see images (a text-only model, llama.cpp without
`--mmproj`, an mlx host) refuses a turn with images before sending it:
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

The setting also supports `SAMAGOTCHI_WEB_MARKDOWN=true` or the global config:

```yaml
web:
  markdown: true
```

Only finalized assistant messages are rendered; user messages and live streaming
chunks remain escaped text. Generated HTML is sanitized, raw HTML in model output
is not trusted, and unsafe links are removed. If Markdown is enabled without
commonmarker installed, Chi Web keeps the normal escaped-text display and shows a
warning explaining how to install the optional gem.

Every prompt and answer has a copy button (on hover; always shown, dimmed, on a
touch screen), and so does each code block of a rendered answer. An answer
copies its Markdown source, not the rendered text; a code block copies just
its code; a prompt copies the text as you typed it.

### Web views

`web.view` picks how the page draws a turn: `stage` (the default: the
running turn pinned above the composer, below) or `turn` (each turn as one
block of steps in the history, the running one at the bottom, below).

```sh
chi web --web-view turn      # stage is the default
```

The setting also supports `SAMAGOTCHI_WEB_VIEW=turn` or the global config:

```yaml
web:
  view: turn
```

`?view=stage` or `?view=turn` on the page URL picks the view for that page
load, whatever the config says; the parameter is dropped when you switch
between the project and all-sessions views. The terminal UIs are not
affected.

**The stage view** pins the running turn above the composer, in its own
card, so it stays on screen without scrolling: a status row (what it is
doing, the step, the elapsed time), your prompt on one line, the newest
narration sentence (else the newest thinking one, in italics; click it for
the step's reasoning), the running tool with what it does, and the last
three calls. A plugin's or hook's notice and a plugin's nudge ("check-in
nudged the model") show ahead of those calls for about 4 s, as their rows
wait in the closed block. A card that needs you (a question, an approval, check-in)
sits in the stage too. The chip under it, `N steps · M tool calls` with one
tick per call, opens the turn view's block in place (newest step first
while it runs; a tick opens its step). `▾` folds the stage to its status
row, remembered in this browser. When the turn ends the answer shows in
the stage, and the whole turn moves up into the history once you are not
using the stage (the pointer over it, a touch or scroll in the last 4 s,
keyboard focus or a selection keep it) for 1.5 s; sending the next message
moves it at once. The history is never scrolled while a turn runs, and only
follows the hand-off if you were at its end. The `/` command list opens
over the stage's lower edge.

**The turn view** shows a turn as *one block* where the work
happens. The running
generation is the live part at the bottom (its thinking, its narration, its
tool rows), the earlier ones stack above it collapsed to one line each
(their narration's first line, else their first call's title such as
`edit lib/a.rb`, and a call count), expandable for inspection. A tool row
says what the call did: a file's path relative to the session's folder, a
command without its leading `cd … &&` (the full parameters on hover). The live thinking is one line: the
newest complete sentence, changing at most once per 1.5 s. Click it for the
full text; a peek is per step (the next step's thinking starts closed
again). When a step ends its thinking closes to a plain `thinking` line
(unless you opened it); a step that only thought shows that line alone. The
live narration is a box of about three lines that fills sentence by
sentence (a sentence shows once it is complete) and scrolls to the newest
when full. When the turn ends the block collapses to its summary (`3 steps
· 8 tool calls · execute ×7 · read ×1`) and the answer expands from the
box into a normal bubble under it (Markdown, annotate). A plain answer
without tools ends exactly as it does today. Rows the code collapses stay
as you toggled them. A reloaded session shows the same block
from the saved messages (each step's thinking, narration, tool parameters
and output, the output capped at 2000 characters) and the timing records
(status and duration per row). On an `api: openai` host the model's
reasoning is saved with each step for this (never sent back to the model);
steps saved before that have none, so they show no thinking. An `edit` or
`write` row has a closed `diff +3 −1` under it that opens to the change it
made (up to 120 lines or 8 KB), live and after a reload (see
[Guardrails](guardrails.md#ask) for the diff an approval shows first).

### Web annotate presets

Selecting text in an answer, a thinking block, a tool row or one of your
messages shows **Annotate**, which quotes the selection into the composer
for a note under it. Next to it sit quick replies, by default `Agreed` and
`Could you please elaborate?`: a click quotes the selection the same way
with that text already written as the note. It only fills the composer,
never sends, so you can collect several quotes and edit before sending.

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
LAN: http://192.168.1.55:4567/?token=…   ← anyone with this link can run commands as you
Plain http: the link and your traffic can be read by anyone on this Wi-Fi.
<the link's QR code>
```

Scan the QR code with the phone's camera. The page trades the token in the
link for a cookie (kept 400 days) and drops it from the address, so a
bookmark or a home-screen icon keeps working across restarts. A home-screen
web app on iOS has cookies of its own: if it opens on "needs chi web's
access token", paste the token there (the part of the link after
`token=`), or open the link once in it.

- Every request from another machine needs the token (the cookie, or
  `Authorization: Bearer <token>` for curl); this Mac (127.0.0.1) needs none.
  Without it the page says how to get in and the API answers 401.
- The token lives in `$XDG_STATE_HOME/samagotchi/web-token` (0600).
  `chi web --new-token` replaces it: a running chi web takes the new one at
  once, and every phone has to scan the new QR code.
- A second `chi web` prints the LAN link and QR code again. A plain
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

## Runtime Model Switch (Assist Mode)

In interactive assist mode, you can switch the request model without restarting:

- `/model <name>`: set a session-scoped model override.
- `/model host:model` or `/model host:alias`: qualified host routing (only `:` names a host; `openai/gpt-4o` is a model id). `host:alias` applies the alias; an alias whose target names another host is refused (`alias 'tiny' names host 'box', not 'openrouter'`). Aliases apply once: an alias pointing to another alias sends that name as written.
- `/model --default <name>`: set session model and persist as new default (`default.model`) in `config.yml` for future sessions (supports `host:model` full ref). It writes only the file: an exported `SAMAGOTCHI_DEFAULT_MODEL` (or `--model`) still wins over it.
- `/model <name> --alias <alias>`: create alias for current effective model (alias value may be bare or `host:model`).
- `/model`: show the effective model (and default when diverged: `runtime model: <effective> (default: <default>, profile=<name>, <source>)`, e.g. `profile=qwen36, server (chat_template)`).
- `/model clear` (or `default`/`none`/`off`): clear the session override, reverting to the configured default.
- `/guardrails`: the guardrail rules (by source), what failed to load, and your stored approvals, numbered; `/guardrails revoke N` removes approval N (see [Guardrails](guardrails.md)).
- `/models`: list model ids aggregated across all `hosts:` (an alias shows next to its id: a bare alias on every host listing the id, a `host:model` one only under its host; grouped `host (host:port):` with per-host `unreachable` warnings, e.g. an unset `api_key_env`; lists cached 60s, 10 minutes for a remote host; lazy — no startup prefill). At most 20 ids per host, then `… and N more`; `/models <text>` lists every id containing `<text>` (any case), e.g. `/models qwen` on OpenRouter.

Notes:

- The switch updates the request `model` field, routes to the matching host (`HostRegistry#resolve`), and resolves the prompt profile again (config, the server's chat template, the name; see "Prompt profile" in configuration.md).
- Without `--default` the command is session-scoped and does not rewrite config files.
- With `--default` the new default is written to `~/.config/samagotchi/config.yml` (honoring `XDG_CONFIG_HOME`) and takes effect for all new sessions; the current session's effective model is also updated immediately. Bare aliases and `host:model` are both valid.
- `--default` and `--alias` change only their one key's line in `config.yml` (`default.model`, or the alias under `model_aliases:`): comments and the rest of the file stay as written, a symlinked file is written through and keeps its mode. When the edited text wouldn't read back as the expected settings (a flow-style section, anchors), chi writes the whole file out from the parsed data instead, which drops its comments.
- Worker sessions inherit `hosts:` via `SAMAGOTCHI_HOSTS_JSON`.
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
  (`writing a recap…`, then the recap when it comes).
- One written while a continue offer waits (the last turn ran out of steps)
  says that turn stopped before the task was finished. Answering `no` counts
  as activity, so the next recap no longer says so.
- It is 2-4 sentences; `recap.sentences` sets another length (`3`, `5-7`,
  up to 10; `--recap-sentences`, `SAMAGOTCHI_RECAP_SENTENCES`). A change
  shows from the next recap written, and updates keep to it.
- It uses the session's own model unless `recap:` names one;
  `recap: false` turns it off. See configuration.md.

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
status> model=Qwen3.6-35B | ↳ 3f2a1c9e | ctx=12.3% (under20) | mem: notes, cli_usage | muted: gh-helper
```

- `model=`: the model in use, `(default: …)` beside it when it isn't the config's default, and
  `model=<served> (served; asked <name>)` when the server said it served another model.
- `↳ <id>`: the session that delegated this one.
- `ctx=`: the kernel's context estimate and its bucket, updated during a turn (on hosts that
  report none, `api: openai`, at the turn's end).
- `mem:`: the memories the session read, with its `--memory` list; `muted:` its `--mute` list.
  Up to 8 names each, then `+N`.
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
  row changes at most once every 1.5 s so it doesn't flicker. A long sentence is cut with `…`; a
  Qwen `TURN:` prefix and inline markdown are left out.
- `| waiting for the first token… 5s` after 2 s with nothing streamed.
- `| running execute…` while a tool runs (its `tool>` line prints when it ends).
- `| retrying (1/3 in 0.5s): Errno::ECONNREFUSED` while a network error is retried.
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
- The turn ends with one line, `✕ turn canceled (Ctrl-C) · 3.1s`, and for a prompt turn a dim
  `partial progress kept; !rollback restores the pre-turn state` under it (a canceled continue is back where it
  started). A failed turn ends with `✕ turn failed: <summary> · 2.0s` and a dim `prompt restored for retry`. The
  REPL and attached mode say the same; the web says `✕ canceled (Ctrl-C)` (`stopped` for its Stop button,
  `by a hook` for a hook's).
- Visible text the canceled request had streamed stays in the conversation, marked `[interrupted]`, so the next
  message (or a continue) picks up from the half-finished reply; the canceled request's thinking and any unfinished
  tool call are dropped.

## Iteration Limit Behavior

- A turn's step limit (model ↔ tool rounds) is `turn.max_iterations` in config.yml (env
  `SAMAGOTCHI_TURN_MAX_ITERATIONS`, default `100`, an integer of 1 or more). `--no-interrupt` and
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
- Stop keeps the interrupted turn's work in the conversation, as a Ctrl-C or a new prompt does, with a note for the
  model that it wasn't continued (or your reason); `!rollback` still erases it.
- `--non-interactive` (`chi -p`) has nobody to ask: the turn ends there. A `chi send --wait` on a session nobody can
  answer (an older worker) reports `limit` (exit 1) with how to continue it: `chi send ID -m '/continue yes'`.
- The check-in bundle's card closes as the turn ends, before the step-limit question opens, so the two never stand
  together; with check-in's default `after: 50` and the limit of 100 a long turn usually shows a check-in card first.
