# System 1's saved runs

System 1 is the cheap judgment model chi asks small questions: approvals
([guardrails.md](guardrails.md#system-1-experimental)), toolkit suggestions
([configuration.md](configuration.md#toolkits)), context candidates
([context.md](context.md)) and bundles' own ([plugins.md](plugins.md#judgments-chijudgment-and-ctxjudge)). Each use keeps its own mode, gates and log. What they share is
one host (`system_one.host`, `.model`, `.timeout_ms`) and one layer that saves every ask, so a later comparison or fine-tune has what
was sent and what came of it. The runs don't leave the machine; a hosted System 1 host sees each state as it is asked.

## The common layer

`SystemOne::Client` asks. `SystemOne::Recording` wraps it where a use builds its
client (`Engine#system_one_recording`): the same duck type, the same answers and
the same raises. A cancelled ask saves its run, then raises; a run that can't be saved is
one warn and never changes the answer. A use that needs the run's id at once passes it
(`client.ask(..., run_id: id)`); one client serves several threads.

| Judgment | Asked by | Later lines |
|---|---|---|
| `approvals.allow` | `GuardrailWiring#system_one_judge` | gates, acted (the judgment line's decision), labels |
| `toolkit.suggest` | `ToolkitSuggest.judge` | acted (the log's `did`), no labels |
| `context.candidate` | `ContextJudge.ask` | labels |
| `<bundle>.<name>` | `SystemOne::Judgments` (`ctx.judge`, `ctx.judge_later`) | the bundle's: labels, acted |

Not saved: a toolkit warm-up (it goes straight to the backend), `chi guardrails replay`,
chi web's availability check, a scratch session's asks or anything about them, and a participant's turn (never judged by core; a bundle's ask there still goes, unsaved).
An owner's turn in a review session is judged, so it is saved. Test runs are saved with `test_run: true`.

## Bundles' judgments

A bundle declares a judgment with `chi.judgment` and asks through `SystemOne::Judgments`, the Engine's (`Plugin::Host#judgments`), on the
same `Client` and `Recording`: the API is in [plugins.md](plugins.md#judgments-chijudgment-and-ctxjudge), the settings in
[configuration.md](configuration.md#bundles-judgments).

Only bundles' judgments have settings of their own (`JudgmentSettings`). Core's take no host, model or mode here, whatever
`system_one.judgments` says: `Record` and `Similar` are model-blind (`Record#initialize` filters by rule only), so a model swapped
for approvals alone would inherit a clean record and could auto-allow. Before any such swap, `Record` and `Similar` have to go by model.

Core's uses keep their own threads (`ToolkitSuggest::Pending`, `ContextJudge`, the approval path) and contention; only the ask-and-save
seam is common. A bundle's `judge_later` runs on the Engine's `SideJudgments` under its full name as the kind, so `SideJudgments#join`
at shutdown covers it, and a run cut by that one-second limit is lost. Its asks stay out of the session's spend, as all of System 1's do, and no
cost cap covers them on a hosted host.

## The store

`<state dir>/system_one/runs/<judgment>/YYYY-MM-DD.jsonl` (`SystemOne::RunsStore`): one file per UTC day,
0600 in 0700 folders, one append under `flock` per line. Each judgment's questions are stored
once per digest pair in `versions.jsonl` beside them.

A line over 16 KB has its state cut, as a string, and is marked `truncated`.

Agents can't write here: `write`, `edit` and `memory_write` are denied (`system-one-runs`), a shell
command naming the folder is `touches: chi_dirs`, and it is in `ChiDirs.protected`, so only the user
may answer an ask about it. A label here may one day train a model.

### What a run holds

A `run` line: `id`, `judgment`, `at`, `instructions_digest`, `criteria_digest`, `state` as sent, `asked`,
`origin` (`live`), `mode` (the use's own: toolkit and context build an `on` client in audit too),
`host`, `model` (resolved), `served_model`, `answers` (raw, as the backend sent them), `usage`,
`failure` and `failure_text`, `latency_ms`, `session_id`, `chain_link`, `session_model`, `test_run`, `truncated`.
Nil fields are left out. A bundle's run may add `positive` and `negative`, the label values it declared.

A skipped ask is a run too, written at once: `asked: false` and `skipped` (`shared_host`, or `busy` for a `judge_later` whose last one still
runs), with its state, host and model but no answers, so a later replay can answer it with no eviction today.

**That means prompts, commands, diffs and any secret in them are in these files.** A state is whatever the
use sends System 1: an approval's command (up to 2000 chars), diff and earlier examples, a toolkit's
first prompt, a context candidate's owner prompts.

`chain_link` is the session's parent, else the session it continues. It isn't the chain's root: following a
chain takes a session listing (`SessionChain`), too slow on an approval's path. An export splitting by chain
follows the links.

A run's id is `<judgment>/<uuid>`, carrying its judgment. Approvals use it as the judgment line's id in
`judgments.jsonl`, so `verdict.judgment[:id]` and `/guardrails wrong` carry it with no new field; toolkit's
and context's log lines have it as `run_id`. An id from before runs names no judgment and labels no run.

### Later lines

Later lines name their run by `run_id` and may sit in a later day's file, or in theory before
the run: a join happens at read, and a line whose run is gone is dropped.

- `label` {`value`, `by`, `strength`, `question`, `at`}.
  - Approvals (`SystemOne::ApprovalLabel`, the one reading of an answer for the log and the run):
    `allow_once`, `allow_wide`, `deny` by `user`, strong; `should_have_asked` from `/guardrails wrong` or the
    web's **should have asked**, strong; `deny` by `parent`, weak, only where the parent could have allowed; a
    parent's allow is no label; `none` for a cancelled ask, which is not an answer.
  - Context: `attached`, `declined` by `command` (`/context attach|decline`, the card's buttons), `declined`,
    `detached` by `user` (a removal seen at an owner turn's start), on the latest `judged` line's run, question
    `about`. A chip removed after the last turn isn't seen, and an attach by hand is no label.
  - Toolkit has none: `did: chosen` doesn't say what was picked. "Covers" stays derived in `chi toolkit report`.
  - A bundle's: its own word, raw, by `<bundle>` or `<bundle>:<what>`, through `ctx.judgments.label`. A bundle reaches only its own runs.
- `acted` {`what`, `at`}: approvals' decision (`auto`, `asked`, `audit`), toolkit's `did`, a bundle's own word.
- `gates` {`rule`, `rule_listed`, `self_protect_refused`, `threshold`, `at`}: approvals', at ask time,
  since neither can be recomputed later.

Labels are biased, and a later comparison must handle it: an auto-allowed call has no answer unless
flagged, and a stored wide approval never reaches the judge at all.

## Retention and deleting

Runs last as long as sessions. The session sweep deletes day files older than `session.retention_days` (0: forever),
then the oldest until the total is under 100 MB; today's stay. A judgment with no day file left loses its folder.

`chi sessions delete` (and the web's delete, and `/exit --delete`) purges that session's runs and their later lines; a sweep
doesn't, and neither does discarding a session its worker left empty. A purge can't reach text a later run of another session
embedded: an approval's state carries earlier asks as examples.

To stop saving: `system_one.runs: off` in config.yml (what's there still ages out). To delete it all:
`rm -rf <state dir>/system_one`.

## Looking at it

`chi judgments ls` lists each judgment's digests, runs, labels (each run's last, per question), failures, models and size. `chi judgments report NAME
[--days N]` gives one judgment's counts, p histogram and labels by value (each run's last, per question). Both only read.
A use's own report stays: `chi context report`, `chi toolkit report`, `/guardrails`.
