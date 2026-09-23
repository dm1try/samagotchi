# Sessions

Sessions are plain files — no DB. Each session is `~/.local/state/samagotchi/sessions/<uuid>.json` (XDG-aware via `XDG_STATE_HOME`) plus a sidecar dir `<uuid>/` with `input/`/`output/`/`pid`/`bridge.json` (`Session.session_dir`).

**Retention (file-based, opt-out via env):**

| Env | Default | Purpose |
|-----|---------|---------|
| `SAMAGOTCHI_SESSION_RETENTION_DAYS` | `14` (`0`=forever) | Delete if `updated_at` older than N days |
| `SAMAGOTCHI_SESSION_MAX_COUNT` | `500` (`0`=uncapped) | Keep newest N, prune overflow |
| `SAMAGOTCHI_SESSION_KEEP_STATUS` | (none) | CSV of statuses never auto-pruned |
| `SAMAGOTCHI_SESSION_SWEEP_INTERVAL_HOURS` | `24` | Throttle lazy sweep |

A session is deleted if **expired by age OR overflow by count** (unless `keep_status` or the live-owner guard: a session a worker or `chi` still has open is never pruned). A session's `status` is its turn state (`idle`/`running`), not whether a worker is alive. Orphan dirs without a `*.json` are never deleted. Deletion removes both `*.json` and sidecar dir atomically. Set both `DAYS=0` and `MAX=0` to retain forever.

**Worker idle exit:** a background worker (plain `chi`, Web UI sessions) exits after `SAMAGOTCHI_SESSION_IDLE_EXIT_MINUTES` (`session.idle_exit_minutes`, default `30`, `0`=never) with no turn running or queued, no client on its stream (an open web tab or attached terminal keeps it) and no reminder registered. It removes `bridge.json` and frees `owner.lock`; the next prompt or `--attach` wakes a new worker (`WorkerIdleExit`, `SessionManager.run_session_loop`).

**Attached by default:** plain `chi` and `chi --resume ID` run their session in a background worker and attach to it (`session.shared`, default `true`; env `SAMAGOTCHI_SESSION_SHARED`). The worker runs in the session's `working_directory`, so `!commands` and tools see the directory the session was started in. `session.shared: false` keeps the in-process REPL, `--no-shared` does for one run; a session the REPL has open can't be attached ("close it there first"). See [CLI: Sharing a session](cli.md#sharing-a-session).

**Stopping a worker:** `chi sessions stop ID` marks the session stopped, sends its worker TERM and waits (up to 10 s) until the worker has let go of `owner.lock`, so a `chi --resume ID` right after spawns a fresh worker. That is also how to restart a worker still running an older chi, which the attached terminal and the web report when a command or a question dismiss gets a 404 (`BridgeClient.stale_worker_message`). The web's `POST /api/sessions/:id/stop` waits the same way, for 2 s.

**Lazy sweep:** automatic prune runs at most once per 24h on `GET /api/sessions` (Web). No background thread or cron. Manual prune is always available.

**CLI:**

```sh
bin/chi sessions list [--sort updated_at|created_at] [--order desc|asc] [--limit N]
bin/chi sessions stop ID
bin/chi sessions prune [--dry-run] [--days N] [--keep N] [--keep-status running,...] [--test-only]
bin/chi sessions clean [--dry-run] [--days N] [--keep N]   # alias to prune --test-only
```

Examples:

```sh
bin/chi sessions list --sort updated_at --order desc --limit 20
bin/chi sessions prune --dry-run --days 14 --keep 500
bin/chi sessions prune --days 14 --keep 500          # actually delete
bin/chi sessions clean --dry-run --days 7            # only test sessions
```

`--dry-run` is the safe preview. Web has no prune endpoint; use the CLI.

**Ordering:**

- `Session.list` / `SessionManager.list_sessions` / `GET /api/sessions?sort=&order=&limit=&offset=` default to `updated_at desc` (newest activity first). Also supports `created_at`, `asc`. `X-Total-Count` header when paginated.
- Web UI (`bin/chi web`) has sort select (Updated/Created), order toggle (Desc/Asc), filter input (preview/id/status), `localStorage` persistence, and pagination (first 100 + Show all) to avoid 10k-row jank.
- The web frontend is a zero-build ES-module stack in `lib/samagotchi/web/public/`: `data.js` (retrieval, typed SSE `openStream`, `watchForWorker`), `app.js` (presentation/state; with no live stream it polls the session until a worker is up, then re-reads it: `event_seq` starts over in each worker, so a dropped stream is never resumed with its old cursor), `format.js` (pure formatters such as `previewOf`). Unit-tested via `npm test` (`node --test spec/web/public/*.test.js`).
- Selecting a session in the web UI is read-only: `GET /api/sessions/:id` never spawns a worker (it reads a live worker's snapshot when one runs, else the session file). A prompt (`POST /turn`) or a command (`POST /command`) wakes the worker, and `/stream` briefly waits for a freshly-spawned bridge before answering. A caught-up SSE reconnect holds the stream open; `reset` markers are only sent for reconnects behind the ring window, or with a cursor from another worker (event ids are `<event_seq>-<epoch>`, one epoch per worker).

**Test-session hygiene:**

- New sessions set `test_run:true` when `SAMAGOTCHI_ENV=test` or `RACK_ENV=test` or `CI` is set (explicit flag, `metadata_version` 2). Old sessions without the flag load as `test_run:false`.
- Future `CI`/test runs are tagged and obey the same retention but can be targeted via `bin/chi sessions prune --test-only` or `bin/chi sessions clean`.
- For ad-hoc manual QA use `XDG_STATE_HOME=/tmp/chi-test-$USER bin/chi ...` to isolate from real state.
