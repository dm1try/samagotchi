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

**Worker idle exit:** a background worker (Web UI sessions, `--shared`) exits after `SAMAGOTCHI_SESSION_IDLE_EXIT_MINUTES` (`session.idle_exit_minutes`, default `30`, `0`=never) with no turn running or queued, no client on its stream (an open web tab or attached terminal keeps it) and no reminder registered. It removes `bridge.json` and frees `owner.lock`; the next prompt or `--attach` wakes a new worker (`WorkerIdleExit`, `SessionManager.run_session_loop`).

**Lazy sweep:** automatic prune runs at most once per 24h on `GET /api/sessions` (Web). No background thread or cron. Manual prune is always available.

**CLI:**

```sh
bin/chi sessions list [--sort updated_at|created_at] [--order desc|asc] [--limit N]
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
- The web frontend is a zero-build ES-module stack in `lib/samagotchi/web/public/`: `data.js` (retrieval + typed SSE `openStream` with an `onStreamError` backoff retry), `app.js` (presentation/state, retry cap + terminal stream-error state), `format.js` (pure formatters such as `previewOf`). Unit-tested via `npm test` (`node --test spec/web/public/*.test.js`).
- Selecting a session in the web UI eager-resumes its worker: `GET /api/sessions/:id` spawns the worker + bridge when stopped (no `/turn` needed to wake it), and `/stream` briefly waits for a freshly-spawned bridge before answering. A caught-up SSE reconnect holds the stream open; `reset` markers are only sent for reconnects behind the ring window (or across a worker restart).

**Test-session hygiene:**

- New sessions set `test_run:true` when `SAMAGOTCHI_ENV=test` or `RACK_ENV=test` or `CI` is set (explicit flag, `metadata_version` 2). Old sessions without the flag load as `test_run:false`.
- Future `CI`/test runs are tagged and obey the same retention but can be targeted via `bin/chi sessions prune --test-only` or `bin/chi sessions clean`.
- For ad-hoc manual QA use `XDG_STATE_HOME=/tmp/chi-test-$USER bin/chi ...` to isolate from real state.
