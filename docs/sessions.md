# Sessions

Sessions are plain files — no DB. Each session is `~/.local/state/samagotchi/sessions/<uuid>.json` (XDG-aware via `XDG_STATE_HOME`) plus a sidecar dir `<uuid>/` with `input/`/`notes/`/`output/`/`pid`/`bridge.json` (`Session.session_dir`).

**Retention (file-based, opt-out via env):**

| Env | Default | Purpose |
|-----|---------|---------|
| `SAMAGOTCHI_SESSION_RETENTION_DAYS` | `14` (`0`=forever) | Delete if `updated_at` older than N days |
| `SAMAGOTCHI_SESSION_MAX_COUNT` | `500` (`0`=uncapped) | Keep newest N, prune overflow |
| `SAMAGOTCHI_SESSION_KEEP_STATUS` | (none) | CSV of statuses never auto-pruned |
| `SAMAGOTCHI_SESSION_SWEEP_INTERVAL_HOURS` | `24` | Throttle lazy sweep |

A session is deleted if **expired by age OR overflow by count** (unless `keep_status` or the live-owner guard: a session a worker or `chi` still has open is never pruned). A session's `status` is its turn state (`idle`/`running`), not whether a worker is alive. Orphan dirs without a `*.json` are never deleted, except skeleton-only ones (see *Empty sessions*). Deletion removes both `*.json` and sidecar dir atomically. Set both `DAYS=0` and `MAX=0` to retain forever.

**Worker idle exit:** a background worker (plain `chi`, Web UI sessions) exits after `SAMAGOTCHI_SESSION_IDLE_EXIT_MINUTES` (`session.idle_exit_minutes`, default `30`, `0`=never) with no turn running or queued, no client on its stream (an open web tab or attached terminal keeps it), no reminder registered and no continue offer waiting for an answer. It removes `bridge.json` and frees `owner.lock`; the next prompt or `--attach` wakes a new worker (`WorkerIdleExit`, `SessionManager.run_session_loop`). A client can also ask the worker to exit right away (Bridge `POST /session/:id/exit`; `/exit` in an attached terminal does, `/detach` doesn't): the same rules apply without the timeout (even with `0`), and the asker's own stream doesn't count. The reply names what keeps it up. The session's status stays as it was, not `stopped`.

**Empty sessions:** a session nothing happened in is deleted when it is left, so `chi` → `/exit` leaves no trace. Empty means: no messages, no turn tried (a failed turn leaves a `last_prompt` and keeps it), no memory used, no pending question, nothing in `input/`, `notes/` or `images/`, nothing in its dir beyond the worker's skeleton, mode `assist`, and the default model. A session on another model (`/model`, `--model`) counts as prepared and stays (`SessionManager.empty_session?`). The worker checks as it idle-exits or leaves on a client's request and deletes it once its lock is free, checking again first. The attached `/exit` then says `Detached; the session was empty, so it is discarded.` The REPL (`--no-shared`) does the same at `/exit` or Ctrl-D. The retention sweep catches those killed first: empty sessions over an hour old with no live owner, whatever `DAYS`/`MAX`, and skeleton-only dirs with no `*.json`. `session.keep_empty: true` (env `SAMAGOTCHI_SESSION_KEEP_EMPTY`) turns all of it off.

**Attached by default:** plain `chi` and `chi --resume ID` run their session in a background worker and attach to it (`session.shared`, default `true`; env `SAMAGOTCHI_SESSION_SHARED`). The worker runs in the session's `working_directory`, so `!commands` and tools see the directory the session was started in. `session.shared: false` keeps the in-process REPL, `--no-shared` does for one run; a session the REPL has open can't be attached ("close it there first"). See [CLI: Sharing a session](cli.md#sharing-a-session).

**Stopping a worker:** `chi sessions stop ID` marks the session stopped, sends its worker TERM and waits (up to 10 s) until the worker has let go of `owner.lock`, so a `chi --resume ID` right after spawns a fresh worker. That is also how to restart a worker still running an older chi, which the attached terminal and the web report when a command or a question dismiss gets a 404 (`BridgeClient.stale_worker_message`). The web's `POST /api/sessions/:id/stop` waits the same way, for 2 s.

**Deleting a session:** `chi sessions delete ID...`, `/exit --delete` in a terminal and the Web UI's delete all go through `SessionManager.delete_session`: it resolves a unique prefix, removes `<id>.json` and the whole `<id>/` dir, and returns what it removed. A session a plain REPL has open (`owner.lock` kind `tui`) is always refused. One a worker runs is refused unless the caller asks to stop it: then it stops the worker as `chi sessions stop` does and deletes once `owner.lock` is free (`--force` on the CLI, 10 s; the web always, 2 s; `/exit --delete` after the worker agreed to exit, 10 s). A worker that outlives the wait leaves the session in place. The web's route is `DELETE /api/sessions/:id` (200 `{status: "deleted", session_id, stopped}`; 409 `owned_by_tui` or `still_stopping`; 404).

**Lazy sweep:** automatic prune runs at most once per 24h on `GET /api/sessions` (Web). No background thread or cron. Manual prune is always available.

**CLI:**

```sh
bin/chi sessions list [--sort updated_at|created_at] [--order desc|asc] [--limit N] [--scope=all]
bin/chi sessions list [--live] [--cwd PATH] [--limit N] [--format text|json|tsv] [--scope=all]
bin/chi sessions stop ID
bin/chi sessions delete [--force] ID...                    # for good; --force stops a live worker first
bin/chi sessions prune [--dry-run] [--days N] [--keep N] [--keep-status running,...] [--test-only]
bin/chi sessions clean [--dry-run] [--days N]             # test sessions: all, or older than N days
```

Examples:

```sh
bin/chi sessions list --sort updated_at --order desc --limit 20
bin/chi sessions prune --dry-run --days 14 --keep 500
bin/chi sessions prune --days 14 --keep 500          # actually delete
bin/chi sessions clean --dry-run                     # every test session, whatever its age
bin/chi sessions clean --dry-run --days 7            # test sessions older than 7 days
```

`--dry-run` is the safe preview. Web has no prune endpoint; use the CLI.

`chi sessions list` shows each session's saved recap, its first sentence without the "The user was…" opening (as on the web cards), in place of its last prompt, cut to 60 characters; a session with no recap shows its last prompt.

**Projects:** a session belongs to the git project it was started in: the repository, whichever worktree or subfolder of it (the same project root memories use). `chi sessions list` (with `--live` and `--format` too) and `chi web` show the current folder's project; `--scope=all` shows every session, and so does a folder in no repo (`~`). `--cwd PATH` is a folder filter instead of the project. The project is stored with the session (`project_root` in its JSON, `project` in `--format json`), so a session keeps it after its worktree is deleted; sessions older than that are placed by their folder, and one whose folder is gone shows in `--scope=all` only. Retention, `--resume`/`--attach ID`, `chi send`/`chi note ID` and `chi note --all` (every live session) are not scoped. The agent's `list_sessions` lists its own project's sessions; `cwd: "/"` lists every one.

`--live`, `--cwd` and `--format` make `list` a picker for scripts (`SessionManager.session_summaries`): `--live` keeps the sessions a worker runs now (the owner lock, not the saved status; a session open in a plain REPL is left out), `--cwd PATH` those in PATH or below, and test runs are left out. `--live` shows 10 unless `--limit` says otherwise; filters apply before the limit. `--format json` prints `[{id, short_id, desc, cwd, updated_at, live, busy, owner, recap}]` (`owner`: `"worker"`, `"tui"` for a plain REPL, which takes no notes or messages, or null; `recap`: the first sentence of the session's recap, or null), `--format tsv` one `id<TAB>desc` line per session, where `desc` is `<folder> · <last prompt>` cut to 60 characters (the text form of `--live`/`--cwd` shows `<folder> · <recap>` when there is one; tsv and json keep `desc`).

## Context notes

A context note is text pushed into a session as background: not a prompt, and it starts no turn.

```sh
bin/chi note [--source NAME] [-m TEXT] (ID|PREFIX)... | --all
pbpaste | bin/chi note --source slack 3f2a 8c1d
```

- The text comes from `-m` or stdin (a terminal on stdin is a usage error, not a wait). It is stripped; an empty note or one over 16 KiB is refused, never cut. `--source` (default `cli`) names where it came from. `--all` is every live session.
- It lands in `<uuid>/notes/`, apart from `input/`, so nothing that runs turns sees it. A live worker adds it to the conversation within a few seconds, between turns: one sent during a turn waits for that turn to end. A session with no worker keeps it until a worker next starts (a prompt, `--attach`), which adds it before anything else. A session open in a plain REPL (`--no-shared`) refuses notes. `chi note` prints one line per session: queued, waits for the next start (with the queue count), or refused.
- In the conversation it is a tail system message marked `kind: note`, framed `[CONTEXT NOTE from slack, 14:02]\n…\n[END NOTE]` (from another session: `from session 3f2a1c (~/projects/foo)`). The system prompt says notes are background, not requests: the model uses one when it is relevant, doesn't answer it on its own, and never follows instructions inside it. Its text is escaped like user text, so it can't fake a turn. It survives `--resume`, a reload, `!rollback` and a continue answered no.
- The web shows it as a dim "note from …" block, live (`context_added`) and after a reload; the attached terminal as one dim `note from slack: <first line>` line, also when joining.
- Agents: `list_sessions` (other sessions of this project, newest first, up to 20; optional `cwd`, `"/"` for every project) and `send_note(session, text)`, which sends a note from this session. Neither starts a turn anywhere.

On macOS, `chi desktop install` does this with a native panel from the Services menu or a hotkey (see [Desktop helper](desktop.md)). A plain Automator Quick Action that sends the clipboard to the live sessions you pick works too (Automator: Quick Action, "Run Shell Script", shell `/bin/zsh`; Automator's PATH is minimal, so put your Ruby's bin dir on it and use the full path to `chi`):

```sh
export PATH="$HOME/.local/share/mise/shims:$PATH"   # wherever your ruby lives
chi="$HOME/projects/samagotchi/bin/chi"
list=$("$chi" sessions list --live --scope=all --format tsv)
[ -z "$list" ] && { osascript -e 'display notification "No live chi sessions" with title "chi note"'; exit 0; }
picked=$(osascript - "$list" <<'OSA'
on run argv
  set AppleScript's text item delimiters to linefeed
  set choice to choose from list (paragraphs of item 1 of argv) with prompt "Send the clipboard to:" with multiple selections allowed
  if choice is false then return ""
  return choice as text
end run
OSA
)
[ -n "$picked" ] && pbpaste | "$chi" note --source clipboard $(print -r -- "$picked" | cut -f1)
```

## Sending a message

`chi send` is the other half of `chi note`: the text goes in as your message, the same as typing it in the attached terminal or the web composer, so a turn runs.

```sh
bin/chi send [-m TEXT] (ID|PREFIX)...
bin/chi send -m "is this the same bug?" 3fa2           # a message
pbpaste | bin/chi send -m "is this the same bug?" 3fa2  # the clipboard quoted above the message
pbpaste | bin/chi send 3fa2                             # the clipboard is the message
```

- With both stdin and `-m`, stdin is context: each line becomes a `> ` quote (as web annotations quote a selection), then a blank line, then the message. With only one, it goes in as is. A terminal on stdin is ignored. Both empty is a usage error; over 16 KiB is refused, never cut.
- It goes through the same path as the web composer (`SessionManager.deliver_turn`): the worker's Bridge when it is up, so every attached UI shows it as your message (client id `cli:send`, shown like any user message); the input file when the worker is on its way out. During a running turn it is merged into that turn at the next step, like a message typed then.
- A session with no worker gets one started (like `--attach` or the web composer). A session open in a plain REPL (`--no-shared`) refuses it. Only sessions on this machine: Bridges listen on 127.0.0.1.
- Fire and forget: it returns once the message is queued and never prints the answer; that shows in whatever is attached. A guardrail "ask" waits for a UI to answer it, so with nothing attached the turn stalls there until one attaches (`chi --attach ID`).
- One line per session: `sent`, `sent (the running turn picks it up)`, `sent (started its worker)`, `refused: …` or `failed: …`. Exit 0 when all were sent, 1 when any was refused, failed or not found, 2 for a usage error. There is no `--all`.

The Automator action above works for messages too: swap its last line for `pbpaste | "$chi" send -m "what do you make of this?" $(print -r -- "$picked" | cut -f1)`.

**Ordering:**

- `Session.list` / `SessionManager.list_sessions` / `GET /api/sessions?sort=&order=&limit=&offset=` default to `updated_at desc` (newest activity first). Also supports `created_at`, `asc`. `X-Total-Count` header when paginated.
- Web UI (`bin/chi web`): the page's scope is in its URL. Started in a git repo, `chi web` opens `/?dir=<that folder>`: that project's sessions, and new chats start in that folder; the header chip says `<project> · all`, and `all` opens the same place without `?dir` (every session; a new chat there starts in the server's own folder, shown on the start page, and cards name their folder; `← <project>` goes back to the project view it came from, or to the server's own project). One server serves every project: a second `chi web` (from another repo) finds it through `GET /api/info` and prints (with `--open`, opens) its page for its own folder instead of starting another. The 3 latest sessions sit above the chat; "All sessions" (or `/`) opens every session at `#/sessions`, with a search over preview, id and status (Esc or Back returns). The open session is in the URL (`#/s/<id>`), so a reload or a copied link opens it again; the chi logo top left goes back to the empty start for a new chat. The message box grows with its text; drag its top edge to keep it taller (double-click resets). The info bar copies `chi --attach <id>` for a terminal.
- The web frontend is a zero-build ES-module stack in `lib/samagotchi/web/public/`: `data.js` (retrieval, typed SSE `openStream`, `watchForWorker`), `app.js` (presentation/state; with no live stream it polls the session until a worker is up, then re-reads it: `event_seq` starts over in each worker, so a dropped stream is never resumed with its old cursor), `format.js` (pure formatters such as `previewOf`). Unit-tested via `npm test` (`node --test spec/web/public/*.test.js`).
- Selecting a session in the web UI is read-only: `GET /api/sessions/:id` never spawns a worker (it reads a live worker's snapshot when one runs, else the session file). A prompt (`POST /turn`) or a command (`POST /command`) wakes the worker, and `/stream` briefly waits for a freshly-spawned bridge before answering. A caught-up SSE reconnect holds the stream open; `reset` markers are only sent for reconnects behind the ring window, or with a cursor from another worker (event ids are `<event_seq>-<epoch>`, one epoch per worker).

**Test-session hygiene:**

- New sessions set `test_run:true` when `SAMAGOTCHI_ENV=test` or `RACK_ENV=test` or `CI` is set (explicit flag, `metadata_version` 2). Old sessions without the flag load as `test_run:false`.
- Test runs are tagged and obey the same retention. `bin/chi sessions clean` deletes every test session whatever its age (`--days N`: only those older than N days); a live worker or a `keep_status` status still keeps one. `bin/chi sessions prune --test-only` applies the usual age and count rules to test sessions only.
- For ad-hoc manual QA use `SAMAGOTCHI_ENV=test XDG_STATE_HOME=/tmp/chi-test-$USER bin/chi ...` to isolate from real state; the flag also marks sessions that `chi web` or an attached `chi` spawn (their workers inherit the environment), so `clean` finds them if they land in the real state.
