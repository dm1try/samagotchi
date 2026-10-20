# Model notes: provenance and evidence

This folder is not installed: an install takes only the top-level files the manifest lists. It records where each
shipped note came from, what it was measured against and who approved its text.

A note ships only after the review in docs/memory.md ("Shipped notes: the model-notes bundle"): generic (no repo or
machine facts), not already the harness's job, written to "you", at most 1,500 characters, no first-person lines,
and its final text approved by the user. A model may propose a note in a plan or a diff; it never edits this
bundle itself.

## model_notes_deepseek

- **models:** `*deepseek-v4*`: DeepSeek V4 and V4.1 (`deepseek/deepseek-v4.1-flash`, `deepseek/deepseek-v4-flash`,
  `deepseek/deepseek-v4.1-flash-1017`, a GGUF such as `unsloth/DeepSeek-V4-Flash-GGUF:Q4_K_M`). The note that ran
  before had `deepseek/*|deepseek-*`, which also caught `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` (a Qwen
  distill). Widen the glob to another version only on evidence for it. `spec/model_ids.yml` pins which ids load it.
- **Origin, 2026-10-03:** written by hand after a DeepSeek run of about 100 steps with no commit: explore briefly
  then act, one item at a time with a commit each, stop digging after a few failed attempts, read memories with
  `memory_read`.
- **Guardrail line, 2026-10-18:** written by DeepSeek itself (`memory_write`) in chi build #60, after guardrail rules
  asked about its heredoc writes and commit messages. It was in the first person and named this repo's paths
  (`tmp/commit-msg.txt`); rewritten generically for this bundle.
- **Dropped:** the "never background with `&`" line. The `execute` tool's description already says it ("Don't background with &;
  use task_create"),
  and the report counts 2 bare `&` calls (one session) without a note and none with it.
- **Approved:** the text as shipped, by the user, 2026-10-20 (the plan's P0).
- **Evidence:** `ruby script/model_notes_report.rb --model '*deepseek*'` (read-only, chi's sessions folder,
  2026-10-20). Medians in tool calls:

  | DeepSeek V4.1 Flash via OpenRouter | n | 1st edit | 1st commit |
  |---|---|---|---|
  | no note (2026-10-03 to 10-08) | 11 | 47.5 | 81.5 |
  | the note before this rewrite, pinned to DigitalOcean (2026-10-15 to 10-17) | 11 | 12 | 25 |

  The dates and tasks differ, so this is a hint, not an A/B: an A/B is the same kind of task with the note on and
  muted (`chi send --new --mute model_notes_deepseek`). The shipped text is shorter than the one measured (795
  characters against 1,519) and keeps its habits.
