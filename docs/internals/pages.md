# Pages: the builder, the store, the runner

The user side is [pages.md](../pages.md). This is how a run happens and what it leaves.

## The pieces

| File | What |
|---|---|
| `lib/samagotchi/pages.rb` | `Pages`: the limits, the name rule (`check_name!`, the one check before any path), the folders, the resolver (`script_path`, `user_script_path`, `bundled`), the errors (`Refused`, `BadName`, `Missing`, `FromBundle`, `Busy`, each owning its message), the values `Stored` and `Failure` |
| `pages/builder.rb` | `Builder` (the script's `ui`: `text`, `table`, `walk`) and `TableBlock` (columns, formats, key columns, cells, the total) |
| `pages/store.rb` | `Store`: read, list, `record_run`, `record_failure`, `locked`, `remove`, `file_id`, `remove_temporary_outputs` |
| `pages/runner.rb` | `Runner.run(argv)`: the runner process's whole job |
| `pages/runtime.rb` | `Runtime`, a script's `runtime`: `#schedules` (`ScheduleList`, `Schedule`, `Run`, `Unreadable`) |
| `pages/bundled.rb` | `Bundled`: the pages installed bundles ship (a manifest's `pages:`), `Page#refusal` |
| `pages/launch.rb` | `Launch.run(name, timeout:, cancelled:)`: the one launch path |
| `page_command.rb` | `chi page run | list | rm` |

`pages.rb` requires json, digest, time, `inline_widgets`, `paths` and `atomic_file`, and autoloads its parts. Nothing
it reaches at load requires the engine, the config, the web, the plugins, `ChildEnv` or `ProcessGroup`: the runner
loads it alone. `launch.rb` is the only file that needs `ChildEnv` and `ProcessGroup`, and nothing in `pages.rb`
requires it. Two parts load more, and only when used: `Runtime#schedules` requires `schedules.rb` (which reaches the
config, `SessionManager` and `ProcessGroup`; about 70 ms) when a script calls it, and `Bundled` requires
`installed_bundles.rb` (the config) when a name has no script of the user's. `spec/pages_runtime_spec.rb` pins it: a
real runner process running a user's page that never calls `runtime` has loaded no `runtime.rb`, `schedules.rb` or
`config.rb`.

**The resolver.** `Pages.script_path(name)` is the script a name runs: the user's `NAME.rb` when it exists, else the
page of that name an installed bundle ships (`Bundled.find`), else the user's path (no such page). Every read and run
goes through it (`Store.read`/`script_sha`, `Launch`, `Runner`, `PageRoutes`). `Store.remove` never does: it deletes
only `Pages.user_script_path(name)`, and with no user script a bundle's page raises `FromBundle` before anything is
touched (`pages_bundled_spec` checks the bundle's file is still there). `Store.list` is the user's names (the pages
folder) and `Bundled.all`'s, one per name. `Stored#bundle` is the bundle whose script runs (nil when the user's runs,
so a shadowing copy reads as the user's) and `Stored#script` its path.

**Bundle pages** (`Bundled`, from the install records like `BlockRenderers.for_installed`, so chi web loads no plugin):
each usable `InstalledBundles.standings` record's `manifest.pages` (`InstalledBundles::Manifest#pages`: the kept
`manifest.yml` only, never the record's mirror, since a key a later manifest gains is never mirrored), the first
bundle by name winning a name; an unreadable or too-new bundle ships none. Since `pages:` isn't mirrored, a kept
`manifest.yml` that is edited, stale or missing (`InstalledBundles::Manifest#standing`), or a `pages:` that doesn't
parse, ships no page either: `Bundled.unread` logs `bundle_pages_unread` (bundle, why) once per process when the kept
file names `pages:` (or the key failed), and `chi bundle status NAME` says the file is edited. `Page#refusal` is
`InstalledBundles::Dir#file_refusal(:scripts, …)` against the recorded sha: `Launch.run` checks it under the lock and,
on one, records it as the run's failure and starts nothing. A bundle page whose installed script is gone is still
a page (`Pages.exists?`, which `Launch.run` and `GET /api/pages/NAME` ask): its run fails with the `file_missing`
refusal, not "no page". A bundle page's run loads `installed_bundles.rb` in the
runner too (its `Pages.script_path`), accepted: the shipped one loads the schedules anyway.

## The one launch path

`chi page run` does not run the script in its own process. `Launch.run` starts the runner, exactly as chi web's
Refresh will (Build 2), so a page that passes from the terminal passes on Refresh (the spike saw two paths give a
script 152 against 73 preloaded libraries and a stale `PWD`). It costs about 70 ms more per terminal run.

1. `Pages.check_name!`, then the script must exist (`Missing`), then `Store.locked(name)`: a non-blocking `flock` on
   `<state>/samagotchi/pages/NAME.lock`, beside the page's folder so `remove` can delete the folder while holding it.
   Held: `Busy` ("page NAME is already running"). The order means a typo leaves no lock file behind. `locked` yields
   the lock's io.
2. `ProcessGroup.spawn(env, RbConfig.ruby, "-I", <this chi's lib>, "-e", 'require "samagotchi/pages/runner"; exit
   Samagotchi::Pages::Runner.run(ARGV)', NAME, TIMEOUT, DEADLINE, 3 => lock)`, in a group of its own, `chdir:` the
   pages folder, stdin closed, the lock on fd 3. The env is a worker's changes
   (`SessionManager::WorkerCommand#spawn_options`): `ChildEnv.unbundled` (an installed gem's Bundler changes undone),
   `ChildEnv.unset` (the spawner's guardrails settings and session markers), `Launch.cleared_keys` unset
   (`CHI_REMOTE`, every `SAMAGOTCHI_WORKER_*` key and the vendor agent markers `AgentCaller::VENDOR_MARKERS`:
   `CLAUDECODE`, `CODEX_THREAD_ID`, `AI_AGENT`, read from those constants), `Paths.absolute_xdg`, and `PWD` set to the
   pages folder (spawn's `chdir:` doesn't change it). So a run never goes remote, never looks like a worker's child,
   and a script's `chi send` is the owner's even from a chi web started in an agent's pane. "This chi's lib" is
   `File.expand_path("../..", __dir__)` from `pages/launch.rb`: a checkout and an installed gem alike.
3. stdout and stderr are each read by a `ProcessGroup::PipeReader` (64 KB, the tail kept).
4. The wait polls `Process.wait2(pid, WNOHANG)`. At the timeout (30 s) `ProcessGroup.stop` TERMs the group, CONTs it,
   waits a grace, then KILLs, with a `stopped:` that reaps (an unreaped zombie counts as alive to the default check).
   Descendants that moved to a group of their own are found and stopped too (`walk:`); one that left the tree
   (`setsid` and its parent gone) survives: the stated limit. `cancelled:` (a callable, chi web's "am I stopping?")
   is polled in the same loop: true stops the group the same way, recorded as "the run was stopped".
5. After **any** exit the group gets a KILL (a script's background child would hold the pipes open), and the readers
   are bounded (`reader.wait(grace) || reader.kill`).
6. The runner wrote the output file, or the launcher records the failure itself: the cut ("the script was stopped
   after 30 s"), or "the runner ended without a result" (with stderr's last line) when the exit status is not 0 or 1
   or the file is the one that was there before. A timeout cut is skipped when the run wrote its result and exited
   0 or 1; a failure the runner already recorded is never overwritten. "The one that was there before" is the file's
   inode
   (`Store.file_id`): `AtomicFile` renames a new file in for every write, so a run that wrote changes it even within
   one second.
7. An interrupt or an exception stops and reaps the group in `ensure`; the lock is released by the `File.open` block.

**A launcher that dies mid-run** (chi web or a terminal killed with `KILL`) runs no `ensure`. The runner holds the
lock too (the flock is shared through fd 3), so the page stays "already running" while it lives, and it ends itself:
its `DEADLINE` is the timeout + `Launch::GRACE_SECONDS` + `Launch::DEADLINE_MARGIN` (2 s) from its own start, later
than the launcher's cut, which wins whenever the launcher is alive. At the deadline a thread in the runner records
the cut itself ("the script was stopped after N s") and KILLs the runner's group. So a killed launcher leaves at most
one bounded run. A Ruby thread can't fire while a C extension holds the GVL: such a script outlives its deadline
until the call returns (accepted). The runner's stdout and stderr are pipes whose reader died with the launcher: Ruby
ignores SIGPIPE, so the script's next output that reaches the pipe (a large one, or `$stdout.sync`) raises
`Errno::EPIPE`, recorded as the script's failure at that line (the good blocks stay; small output stays buffered and
only fails at the exit, after the result is written). Accepted: the run stays bounded, only the error's words mislead.

`ContextFetch#run_command`, `#wait` and `#stop_group` are the model this follows.

## The runner

`Runner.run(argv)` (requiring `pages/runner.rb` runs nothing) first makes fd 3 close-on-exec, so the lock is the
runner's alone: a program the script execs (`spawn`, `system`, backticks), even one that leaves the group and
outlives the run, never inherits it (it would keep the page "already running" for good). A `fork` without an exec
(`Process.daemon` too) keeps fd 3 and holds the lock while it lives: the stated limit. A script's own `exec` replaces
the runner: the lock goes (close-on-exec) and so does the deadline thread; a live launcher still cuts it (it stays in
the group), but after a dead launcher the exec'd program runs unbounded while the page is runnable again (the same
limit). It arms the deadline when argv carries one (a write of the result and the deadline's record take one mutex,
and the write sets a done flag under it, so a result written before the deadline fires is never overwritten), checks
the
name and the script, then
`load(path, dsl)`: the wrap module is a fresh `Module` defining only `page` and `runtime` (the Collector's
`Runtime`, made on the first call), so the script's own `def`s land in it, not on `Object`. `page(title) { |ui| … }` makes a `Builder`; a second call raises `Refused`. After the load, no `page` call
fails the run too.

It rescues `StandardError`, `ScriptError`, `SystemExit`, `SystemStackError` (endless recursion) and `NoMemoryError` (never a `SignalException`: a TERM is the launcher's cut,
recorded by the launcher). The line is the first backtrace entry inside the script file (the exact path given to
`load`), or for a `ScriptError` the `path:LINE:` at the start of its message's first line, which every Ruby gives; the
message drops that prefix. An `exit 3` is "the script called exit 3". A good run goes through `Store.record_run`, which
refuses an output over 256 KB (`Refused`, recorded as the failure). Exit 0 ran, 1 the script failed, 2 no such page.
The result reaches the launcher through the file only: a `puts` in a script corrupts nothing.

## The output file

`<state>/samagotchi/pages/NAME/output.json`, written with `AtomicFile.write`:

```json
{"name": "usage", "title": "Usage, last 7 days",
 "blocks": [{"type": "text", "text": "…"},
            {"type": "table",
             "columns": [{"key": "model", "label": "Model"},
                         {"key": "cost", "label": "Stored", "format": "money", "key_column": true}],
             "rows": [["claude:sonnet-5-5", 14.221]], "total": ["Total", 18.1252], "dropped": 0},
            {"type": "walk", "data": {"title": "…", "actors": ["…"], "steps": ["…"]}}],
 "ran_at": "2026-11-23T10:00:00Z", "duration_ms": 412, "script_sha": "<sha256 of the script that made the blocks>",
 "error": null}
```

- A failed run rewrites only `error`: `{"message", "line" (Integer or null), "at", "script_sha"}`. The blocks, title,
  `ran_at` and `script_sha` stay those of the last good run, and fields this chi does not know are kept in the file
  (dropped only by `Store.read`). A good run sets `error` to null. `Store.record_failure` is
  the one writer of a failure, for the runner and the launcher alike, always under the page's lock.
- Before any good run there are no blocks and `ran_at` is null.
- A table's `format` is stored, not applied: cells stay raw numbers so the page can sort them. `key_column` marks the
  columns a phone shows besides the first (never marked).
- `Store.read` gives a `Stored`: the fields, `state` (`:never_ran`, `:ok`, `:failed`) and `changed?` (the script's
  sha256 now differs from `script_sha`). "Changed" means only this: the result on screen came from an older script;
  every surface uses `changed?` as it is, never a meaning of its own. A missing or unreadable file reads as never ran; keys this version doesn't
  know are dropped on read (a newer chi's file reads fine).

## The data entry into InlineWidgets

`ui.walk` hands its Hash to `InlineWidgets.check("walk", data)`, the same `Schema` the chat's YAML goes through, so the
same widget draws it ([inline-widgets.md](inline-widgets.md#the-data-entry)).

## chi web

**The routes** (`web/page_routes.rb`, `Web::PageRoutes`, its `ROUTES` splatted into `App::ROUTES` on the models row),
all `:owner`: a participant's token gets 403 `not_permitted` (`participant_gate_spec` sweeps them). The name capture is
`([^/]+)`, checked with `Pages.valid_name?` before any path is built; a name that breaks the rule is no such page.

| Route | Answers |
|---|---|
| `GET /api/pages` | `{pages: [{name, title, state, ran_at, failed_at, changed, error_line, bundle}]}`, by name (`Store.list`) |
| `GET /api/pages/NAME` | the page (below); 404 `page_missing` with no script. Runs nothing |
| `POST /api/pages/NAME/run` | `Launch.run(name, timeout: 30, cancelled: -> { !@server_running.call })` inside the request; the page as after the run, with `stderr` (its last 2 KB) when it failed; 409 `page_busy`, 404 `page_missing`, 503 `server_stopping` (chi web's stop ended it: "the run was stopped") |
| `DELETE /api/pages/NAME` | `Store.remove`: `{removed: NAME}`; 409 `page_busy`, 409 `page_bundled` (a bundle's page, `FromBundle`), 404 `page_missing` |

The page: `{name, title, state, ran_at, duration_ms, changed, bundle, changed_after_failure, script_changed_at, error:
{message, line, at} | null, blocks}`. `bundle` (`Stored#bundle`) makes `page_view.js` leave out `⋯` and its Delete;
an older cached app.js still offers it, and the 409's message shows in its toast. `changed` is `Stored#changed?`; `changed_after_failure` says the script differs
from the one that failed (so the page needs no sha); `script_changed_at` is the script's mtime. A text block carries
`html`, the `MarkdownRenderer`'s sanitised render, when rendering is available (`web.markdown`), else `text` only.
The error codes' `detail` is the exception's own message.

**The capability** `pages` (`Web::Viewer::CAPABILITIES`, never a participant's) makes the pill, the list, the view and
the link handler (`pages_wiring.js`, one call in app.js; the pill is `viewer.control(#pagesBtn, "pages")`); without it
none is made and no page call goes out (`viewer_boot.test.js`).

**The page's modules** (`lib/samagotchi/web/public/`): `page_route.js` (`pageHash`, `pageNameFromHash`, the open rule:
never a participant's, never without `pages`), `views.js` (reads the page hash and the list's `#/pages` before the
session intent: `body.page-view` / `body.pages-list`, `openPage` / `closePage` / `leavePage`, `openPagesList` /
`closePagesList`, where a page or the list was opened from kept in its history entry (`history.pushState({from})`:
`pages`, `sessions`, `back`, `pill`; Back and its label read `history.state.from`, so Back and Forward keep them;
an entry with no state was typed or replaced and leaves for the list, or the session), the pill's `aria-pressed`, the session hash not written while either is open, a session picked
leaving it; a page with nowhere to go back to, or gone, lands on the list), `pages_model.js` (the page's one list of
pages: `load` shares a read that is out, `reload` asks again, a failed read keeps the last list; DOM-free),
`pages_wiring.js` (the model, the pill, the list, the view and the links; when the list is read),
`pages_list.js` (the Pages list, `#/pages`: its hash, its cards in `/api/pages`'s order), `page_view.js` (the header, the states, the calls; an answer for a page no longer open is
dropped, `latest.js`), `page_model.js` (the words: meta, the failed and changed lines, Copy the error), `page_blocks.js`
(text, walk in a widget host with `drawWalk`, an unknown type as one muted line), `page_table.js` and
`page_table_model.js` (cells, sort, the phone's rows), `pages_group.js` (All sessions' former group, kept for an
older cached app.js until after 0.189.0; nothing new imports it), `page_links.js` (the
delegated click on the turn roots and the page view for `#/p/` anchors), `pages.css`. What a script wrote reaches the
page as text or attributes, never as markup, except the server's sanitised `html`.

**The list is live, a page isn't.** chi web's session hub stats the scripts folder (`Pages.scripts_dir`) once a tick
and sends a `pages` event (no data) on `GET /api/events` when its mtime moved: a script made, renamed in or removed
(an editor's temp file or a data file beside the scripts counts too: one extra `GET /api/pages` per open tab). Never on
the first look; a folder that appears or goes is a change. A run changes nothing there (its output is under the state
dir), unless the script writes a file beside itself (it runs with the pages folder as its working folder): then each
run refreshes every open tab's list. The page reads the list again on that event and on every snapshot (the first one
shares the boot read while that is out; a later one is a reconnect: the hub has no replay); with no hub stream (no `EventSource`, the list's fetch fallback) the list is read only when a view opens. A
page's own result has no stream event and no polling: a run from a terminal shows on the next open; two tabs are not
kept in step.

## chi's side: the skill

What chi knows about pages is one memory, the system bundle's `skill_pages.md` (an index line in every prompt, the
text read on demand), and the `chi page` line in `self_map.md`. `spec/pages_skill_spec.rb` runs the skill's example
through `Runner::Collector`'s DSL and pins every command, `ui` call and limit it names to the code; a change to the
skill's text regenerates the turn goldens (`UPDATE_PROMPTS=1`).

The eval behind it (2026-11-23, the local Qwen3.8-Flash-Next, `chi -p … --non-interactive` in isolated dirs, N=5 per
task): 14 of 15 pages ran and showed the reference numbers, no ask was raised, and the task that doesn't name the
skill read it 5 of 5 times; without the skill (`--mute skill_pages`, N=3) 1 of 3 made a page. The archive is the
owner's `~/.claude/plans/evals/0016-pages-skill/`.

## Later builds

- `runtime` has one method, `schedules`, with its first page (the schedules bundle). A method comes with its first
  caller: sessions, a session's stats, a config value are the candidates.
- Not planned yet: picks on a page, parameters, a live install (the hub watches the pages folder only, so a bundle's
  page shows on the next list read).
