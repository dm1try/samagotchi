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
- `chi web --web-markdown` — opt in to sanitized Markdown rendering for completed assistant messages
- `chi web --no-web-turn-view` — show turns as the classic row of bubbles instead of the default turn view (each turn as one block of steps, the running one at the bottom); `?view=turn|chat` on the page URL overrides it (see [Web turn view](#web-turn-view))
- `chi sessions list|stop|archive|unarchive|delete|prune|clean` — manage persisted sessions; `list` shows this git project's, `list --scope=all` every one, a delegated session with `↳ <parent>`, `list --archived` the archived ones too (see [Sessions](sessions.md))
- `chi note [--source NAME] [-m TEXT] (ID|PREFIX)... | --all` — add a context note (TEXT or stdin) to sessions: background the model sees on its next turn; it starts no turn (see [Sessions: Context notes](sessions.md#context-notes))
- `chi send [-m TEXT] [--image PATH]... (ID|PREFIX)...` — send a message to sessions as if typed there: a turn starts (or a running one picks it up); piped stdin goes above `-m` as quoted context, and `--image` attaches images (see [Sessions: Sending a message](sessions.md#sending-a-message)); `--new` starts a session with it instead, and `--wait` prints the answer (`--wait ID` with no message waits for the next reply without sending; see [Starting a session](sessions.md#starting-a-session))
- `chi desktop install|upgrade|uninstall|status` — the macOS "Send to chi" helper: a Service and a ⌃⌥⌘N hotkey that send text to live sessions as context notes (see [Desktop helper](desktop.md))
- `chi self` — print version, source dir (checkout or installed gem), config/memory/session paths, model/host and bundles
- `chi update [--dry-run] [--no-gem] [--no-bundles] [--no-desktop]` — update an installed chi: the gem, the system bundle, the shipped bundles you installed and the desktop helper, in one table (see [Updating](#updating))
- `chi bundle install|upgrade|uninstall|status|diff|list|build` — manage memory bundles (see [Bundle hooks](hooks.md#bundle-hooks-unified-workflow-bundle)); `list` shows the installed ones and the ones shipped with chi, which `install <name>` installs (see [Guardrails](guardrails.md), [Plugins](plugins.md#the-btw-bundle), [the mcp bundle](plugins.md#the-mcp-bundle) [the loop-guard bundle](plugins.md#the-loop-guard-bundle) and [the check-in bundle](plugins.md#the-check-in-bundle))

### First setup

`chi bootstrap TARGET` names the model server and writes the config for it:

```sh
chi bootstrap 192.168.1.29:8081          # host:port (port 8080 when none)
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

### Updating

`chi update` brings an installed chi up to date and prints one table:

```
component      from   to     status
chi (gem)      0.2.0  0.3.0  updated
system bundle  0.2.0  0.3.0  updated (kept your edits in identity.md: chi bundle diff samagotchi-system identity.md)
btw            0.1.1         up to date
known-names    0.1.0  0.1.1  updated
infra_tools    1.0.0         skipped (not from chi)
Chi Helper     0.2.0         up to date (launch file refreshed)
workers                      2 live on 0.2.0: they move to 0.3.0 at idle exit (30 min) or chi sessions stop 2ea8c1f0 91b0d2aa
Also shipped, not installed: check-in, source-links (chi bundle install NAME)
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
`--read-truncate-at-bytes`. `chi --help` lists them all.

**Which loop runs.** There is no backend flag: the model's host decides. A host with
`api: openai` in config.yml is driven through the OpenAI chat API (streamed; a remote
provider via `url:` and `api_key_env:`); every other host gets chi's own raw-prompt loop. `/model` and `--model host:model` switch hosts, and
the loop with them. See [Configuration](configuration.md) (`hosts:` and `api:`).
`--backend`, `SAMAGOTCHI_BACKEND` and a `backend:` key were removed; chi says so if
it sees one.

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

- `-p` always feeds **and** runs the prompt; there is no feed-and-edit variant. To
  prefill (edit, not execute) the first REPL line, use the
  `SAMAGOTCHI_DEFAULT_INPUT` environment variable instead.
- Prompt history is persisted per session; `--resume` preserves prior messages as
  turn context (a `-p` run on a resumed session never clobbers existing history).
- Non-interactive runs (`-p` with `--non-interactive`, or bare `--non-interactive`)
  print only the final result output — no spinner, status line, or REPL.

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
An empty answer dismisses the question in every UI.

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
  Web UI's composer takes the same commands.
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

### Typing during a turn

The prompt stays open while a turn runs, in an attached terminal and in the plain
REPL alike:

- A line you submit merges into the running turn at its next step (after the
  current tool call or answer), and `(1 message merged into the running turn)`
  says so. An answer the model finished just before the merge is printed first.
  A line that comes after the turn's last step runs as the next turn, and so
  does one sent after Ctrl-C: it doesn't merge into the turn being cancelled.
  Reminder turns take merged lines too.
- `/stats` and `/recap` answer at once. Other commands (`!cmd`, `/model`,
  `!rollback`, `/continue`, `/guardrails`) say `busy: wait for the turn to end`
  and go back into the prompt, so Enter runs them once the turn ends.
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

### Web turn view

The turn view, the default, shows a turn as *one block* where the work
happens (the classic chat view renders a turn with tool calls as a row of
bubbles: one thinking block, one activity panel and one answer bubble per
generation; `web.turn_view: false` brings it back). The running
generation is the live part at the bottom (its thinking, its narration, its
tool rows), the earlier ones stack above it collapsed to one line each
(their narration's first line, else `working with <tools>`, and a call
count), expandable for inspection. The live thinking is one line: the
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

```sh
chi web --no-web-turn-view   # the classic chat view; --web-turn-view is the default
```

The setting also supports `SAMAGOTCHI_WEB_TURN_VIEW=false` or the global config:

```yaml
web:
  turn_view: false
```

`?view=chat` on the page URL forces the classic chat view for that page load
and `?view=turn` the turn view, whatever the config says; the parameter is dropped
when you switch between the project and all-sessions views. The terminal
UIs are not affected.

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

## Runtime Model Switch (Assist Mode)

In interactive assist mode, you can switch the request model without restarting:

- `/model <name>`: set a session-scoped model override.
- `/model host:model` or `/model host/alias`: qualified host routing (`host:alias` expands alias bare, alias may itself be `host:model` — hybrid).
- `/model --default <name>`: set session model and persist as new default in `config.yml` (also updates `SAMAGOTCHI_DEFAULT_MODEL` for future sessions; supports `host:model` full ref).
- `/model <name> --alias <alias>`: create alias for current effective model (alias value may be bare or `host:model`).
- `/model`: show the effective model (and default when diverged: `runtime model: <effective> (default: <default>, profile=<name>, <source>)`, e.g. `profile=qwen36, server (chat_template)`).
- `/model clear` (or `default`/`none`/`off`): clear the session override, reverting to the configured default.
- `/guardrails`: the guardrail rules (by source), what failed to load, and your stored approvals, numbered; `/guardrails revoke N` removes approval N (see [Guardrails](guardrails.md)).
- `/models`: list model ids aggregated across all `hosts:` (grouped `host (host:port):` with per-host `unreachable` warnings, e.g. an unset `api_key_env`; lists cached 60s, 10 minutes for a remote host; lazy — no startup prefill). At most 20 ids per host, then `… and N more`; `/models <text>` lists every id containing `<text>` (any case), e.g. `/models qwen` on OpenRouter.

Notes:

- The switch updates the request `model` field, routes to the matching host (`HostRegistry`, `lib/samagotchi/host_registry.rb:72`), and resolves the prompt profile again (config, the server's chat template, the name; see "Prompt profile" in configuration.md).
- Without `--default` the command is session-scoped and does not rewrite config files.
- With `--default` the new default is written to `~/.config/samagotchi/config.yml` (honoring `XDG_CONFIG_HOME`) and takes effect for all new sessions; the current session's effective model is also updated immediately. Bare aliases and `host:model` are both valid.
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

Assist mode keeps a small persistent prompt history across restarts.

- Default history file: `$XDG_STATE_HOME/samagotchi/history.json`
- XDG fallback when unset: `~/.local/state/samagotchi/history.json`
- Optional override: `SAMAGOTCHI_HISTORY_FILE=/custom/path/history.json`
- Stored entries: most recent `20` prompts
- Format: JSON array of prompt strings

Behavior details:

- Prompt history is loaded on startup before the first `>` prompt.
- Only real user prompts are persisted.
- Continue-flow inputs (`yes`, `no`, `no, <reason>`, `/continue`) are not persisted as prompts.
- In assist mode, pressing `Tab` on an `@`-prefixed token (for example `@lib/sama`) completes project file and directory paths while preserving the `@` prefix.
- Press `Tab` twice to cycle/show multiple matching candidates, similar to IRB completion behavior.
- History read/write errors are ignored so the session continues uninterrupted.

## Status Line

Assist mode can render a compact generalized status line that can include mode,
context estimate, and active memory hints.

Behavior:

- A static status line is printed before the next `>` prompt in assist mode.
- During spinner rendering, status details are rendered in the spinner block.
- When llama.cpp streaming payload includes usage fields, status prefers server-derived token telemetry (`p`, `c`, `t`) and context percent.
- If server usage fields are absent, status falls back to the `:context_status` estimate telemetry.
- When a memory is loaded between tool rounds, the spinner line includes a `loaded: <memory>` notification immediately after the spinner frame.
- After responses, memory details are shown via the same unified `status>` line.
- The legacy standalone `memories>` summary line is no longer emitted.
- With `--mute`, the sticky and idle rows add `muted: <names>` after `mem:` (the
  spinner row doesn't). Attached, `mem:` shows the used memories and the
  session's `--memory` list before the first turn records them.

Configuration:

- `SAMAGOTCHI_STATUS_LINE` (default `on`): set to `off`, `false`, or `0` to disable status-line rendering.
- `SAMAGOTCHI_STATUS_WIDTH_MODE` (default `terminal_cap`): one of `terminal_cap`, `fixed`.
- `SAMAGOTCHI_STATUS_MAX_WIDTH` (default `160`): maximum width used by `terminal_cap`.
- `SAMAGOTCHI_STATUS_FIXED_WIDTH` (default `120`): fixed width used by `fixed` mode.

Width mode behavior:

- `terminal_cap`: use `min(terminal_columns, SAMAGOTCHI_STATUS_MAX_WIDTH)`, single-line with `+N` overflow indicator.
- `fixed`: use `SAMAGOTCHI_STATUS_FIXED_WIDTH`, single-line with `+N` overflow indicator.

Notes:

- Spinner rendering remains app-managed to keep cursor cleanup deterministic.
- Raw terminal auto-wrap is intentionally avoided in the spinner region.

## Tool Tally

A long, tool-heavy turn says what it has been doing. From the turn's 3rd tool call,
a dim row under the activity row tallies its calls, with no model call:

```
12 tool calls (2 failed) · execute ×7 · read_file ×3 · edit_file ×2 · last: execute command=bundle exec rspec
```

It lists the top 3 tools by count (ties go to the tool used first), the failed calls
(a call a guardrail or an approval blocked counts as a call, not as failed) and the last
call with its parameters, cut to the terminal width. It starts over with each turn.

- Attached mode: the second row of the activity slot, shown while the slot is (the
  model generating or a tool running). Joining a turn mid-way seeds it from the turn so far.
- The REPL (`--no-shared`): a row under the spinner row. The spinner stops while tools
  run (the `tool>` lines show them), so the tally shows while the model generates
  between tool rounds; the spinner block is one row taller from then on.
- The web: the activity panel's summary reads `activity · 12 tool calls (2 failed) · execute ×7 · …`
  (without `last:`: the rows show it).

## Thinking Spinner Sentence

While the model generates, the spinner row shows the newest complete sentence of its thinking
(`model> thinking · <sentence> |` in the REPL, `| thinking · <sentence>` in attached mode), or of its
answer (`writing ·`), like the web's thinking ticker: the same sentence rules (a list number such as
`118.` is no sentence end; a newline is one), and the row changes at most once every 1.5 s so it
doesn't flicker. A long sentence is cut with `…`; a Qwen `TURN:` prefix and inline markdown are left
out. Before the first sentence the row reads `thinking...`. With `TERM=dumb` there is no spinner row.

- When a memory entry is loaded during thinking, the spinner line also shows a compact inline preview
  of that tool call (for example `tool: memory_read(name=...)`) for live visibility before end-of-turn
  tool logs; the sentence gets the room left.

## Thinking-Phase Cancellation

During assist-mode thinking (while the spinner is active), you can cancel an in-flight model request without exiting the process:

- Press `Ctrl-C` to cancel the active request.

Behavior notes:

- Cancellation returns control to the prompt immediately; what you typed there stays.
- Visible text the canceled request had streamed stays in the conversation, marked `[interrupted]`, so the next
  message (or a continue) picks up from the half-finished reply; the canceled request's thinking and any unfinished
  tool call are dropped.

## Iteration Limit Behavior

- `max_iterations` remains a hard safety cap on tool-call rounds.
- Tool side effects that already ran before the cap are not rolled back.
- `Samagotchi::KernelLoop#run` now returns a resumable result object with the visible output plus the accumulated conversation.
- If the cap is reached while tool calls are still pending, the result is marked resumable so callers can continue from the saved conversation instead of restarting from scratch.
- In assist mode, the CLI then asks at the `? ` prompt, with the choices listed under it: `yes` (Enter alone, or `/continue`) resumes, `no` cancels, and `no, <explanation>` cancels while keeping the reason in conversation context. Once answered, one line stays: `? The turn ran out of iterations. Continue it? → no, too slow`.
