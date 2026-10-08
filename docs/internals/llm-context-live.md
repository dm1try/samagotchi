# The llm_context live runs

`script/llm_context_live.rb` runs chi itself on real coding tasks under each LLM context strategy and scores the
sessions. The replay benchmark ([llm-context-bench.md](llm-context-bench.md)) scores stored sessions offline. These
runs close the loop: the model lives with the strategy for a whole task, so they measure what the replay can't, such
as whether a forgotten output comes back as a re-read and whether a note narrows the scope (context strategies P6).
It is a development tool under `script/` and isn't shipped with the gem. It calls a paid model, so it is opt-in: the
specs drive it with fakes on synthetic data.

```sh
ruby script/llm_context_live.rb validate TASKS ROOT                     # no model
ruby script/llm_context_live.rb run TASKS ROOT --model openrouter:deepseek/deepseek-v4.1-flash \
     [--tasks T1,T3] [--arms none,stale,stale_forget] [--samples 3] [--budget 64000|off] [--cap 8] [--jobs 3] [--limit 9]
ruby script/llm_context_live.rb report ROOT [--json]
ruby script/llm_context_live.rb grade|collect TASKS ROOT RUN...          # again, for runs already done
```

`TASKS` (a YAML file) and `ROOT` (where the runs and results go) live outside the repo. They hold task prompts and
session files, and no session text goes into the repo, scrubbed or not.

## Tasks

A task is a real merged fix, replayed from its parent commit. The fix's spec changes are held back and graded
afterwards.

```yaml
source_repo: /path/to/samagotchi
tasks:
  T1:
    fix: 545a3562            # the run's repo is its parent
    size: S
    turns:                   # one chi turn each; {repo} is the run's repo path
      - "In {repo} … find the cause and plan the fix. Don't edit yet."
      - "Implement the plan and run the specs."
    hidden: [spec/broadcast/triage_spec.rb]       # optional: the fix's *_spec.rb
    regression: [spec/broadcast/triage_spec.rb]   # optional: the hidden ones' paths
    fix_files: [lib/samagotchi/broadcast/triage.rb, spec/broadcast/triage_spec.rb]  # optional: what the fix changed
```

A file at `hidden/<task id>/<path>` beside the tasks file stands in for that hidden spec. Use it when the fix's spec
pins a detail that another correct fix would get differently, such as an exact page size; the override keeps only the
contract.

`validate` checks each task's hidden specs: they must fail at the fix's parent and pass at the fix.

## A run

Each task × arm × sample is a run in `ROOT/runs/<task>-<arm>-s<n>/`:

1. **prepare:** `git archive <fix>^` into `repo/`, then a fresh git repo with one base commit. It writes chi's config
   in `config/` (the model's host copied from `--hosts-config`, default the user's config.yml; `turn.max_iterations:
   150`; `recap: false`; `llm_context.apply: payoff`, no `stale_edits`). State goes in `state/`, and it runs `chi
   bundle install loop-guard`. Every chi and rspec command gets `SAMAGOTCHI_ENV=test`, the run's `XDG_STATE_HOME`
   and `XDG_CONFIG_HOME`, and no inherited `SAMAGOTCHI_HOSTS_JSON` (the smoke-run isolation).
2. **run (Driver):** `chi send --new --wait --format json --dir repo --model M --llm-context <arm>
   --llm-context-budget <N|off>` with the first turn, then each later turn into the same session. The arms are
   `none`, `stale` and `stale_forget` (`stale,forget`). The tasks use two turns, because forget is offered at turn
   ends. The driver answers questions as a parent agent would:
   - the model's first question gets "use your judgement" (option 1 when it takes no text), and later ones are
     dismissed;
   - an approval is denied;
   - the step-limit question gets Stop: there is no Continue, since the limit is part of the task.

   A turn waits at most 45 minutes. Afterwards the session is stopped with `chi sessions stop`, then `pkill -f
   <the run's state dir>`. Nothing is ever killed by a pid read from a file.
3. **collect:** the numbers below, read before grading, and `diff.patch` (the work against the base commit).
4. **grade (Grader):** the hidden specs are copied in as `<name>_p6hidden_spec.rb` and run in one `bundle exec rspec`
   with the regression specs (the model's own copies), then removed. Pass means rspec exits 0 with at least one
   example. The working tree is graded: nothing needs committing.

The result goes to `ROOT/results/<run>.json`. A rerun skips runs that have a result, and starts over any run that
has none.

## Cost

Each run's cost (OpenRouter's reported `cost`, summed over the turn records) goes to `ROOT/ledger.jsonl`. No run
starts once the ledger reaches `--cap` (default $8). With `--jobs N` the runs in flight can pass the cap by what they
spend. A payment error (chi send's `error_kind` `credits` or `credits_held`, or a 402 / over_budget in the detail)
ends that run at once and writes `ROOT/STOP`, and no further run starts until someone removes it. The account's own
key limit stays the hard stop.

## What it scores

Per run (`Collector`), from the session file, `analytics.json` and the repo:

- **success:** the grade, plus a manual 0/1/2 in `ROOT/grades.yml` (`T1-none-s1: {grade: 2, note: …}`);
- **steps, tool calls, edits, commits:** `ModelNotesReport::SessionReader`;
- **reads, re-reads, re-reads after a stub** (by kind): `LLMContextBench::Replay#read_counts`. A re-read reads a
  path the session read before. It counts as after a stub when an earlier read of that path had an applied stub
  whose cause came before it: a forget's cause is its `forget_outputs` call, a stale stub's the read that superseded
  it;
- **stale stubs, forget calls, forgotten ids and their tokens:** `Replay#stubs` (chars/4);
- **tokens:** prompt tokens sent (summed over requests), cached, re-prefilled and completion tokens, and the cost,
  from the turn records;
- **peak context:** the largest prompt of any turn (`prompt_tokens_max` on the turn record);
- **scope:** distinct files read, files read and files changed outside the fix's set, and diff lines;
- **wall time.**

`report` gives each task × arm its pass count, manual grades, step-limit stops, and every metric's median with its
min–max spread. It also gives the gate: `stale_forget` against `none`. Per task, a metric is better when
`stale_forget`'s median is below `none`'s whole spread, worse when above it, and the same otherwise. The gate passes
when, on both re-reads and scope (files read + files changed outside), the better tasks outnumber the worse, and
`stale_forget` passed at least as many runs as `none`.

## Limits

- Three samples a cell is little. Read nothing into a difference inside one arm's spread.
- Tokens from `Replay` are chars/4, and those from the turn records are the server's.
- A Splash host may not report cached tokens or cost (they read 0).
- The fix's spec file is copied in whole, so its old examples run twice: once hidden and once as the model left
  them.
