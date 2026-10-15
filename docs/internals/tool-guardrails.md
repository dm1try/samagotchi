# Tool output guardrails

## Read Tool Size Guardrails

The `read` tool applies adaptive limits to avoid accidental context exhaustion
when opening very large files (for example, VCR cassettes).

Behavior:

- Small files: return full file content.
- Large files: return a head+tail preview plus truncation metadata.
- Extremely large files: return an error indicating the hard size limit.

Configuration (each is also a config.yml key, `read.truncate_at_bytes` and so on, and a CLI
flag such as `--read-truncate-at-bytes`; see docs/configuration.md):

- `SAMAGOTCHI_READ_TRUNCATE_AT_BYTES` (default `65536`): files above this size return a preview instead of full content.
- `SAMAGOTCHI_READ_PREVIEW_BYTES` (default `12288`): total preview budget split across head and tail.
- `SAMAGOTCHI_READ_HARD_MAX_BYTES` (default `2097152`): files above this size return `Error: file too large`.

Optional preview telemetry:

- `SAMAGOTCHI_READ_TELEMETRY_THRESHOLD_PCT` (default `80`): include estimated preview token impact only when preview payload is at or above this percentage of the configured context window.

Telemetry uses existing context estimation settings:

- `SAMAGOTCHI_CONTEXT_WINDOW_TOKENS` (`context.window_tokens`)
- `SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN` (`context.chars_per_token`)

## Execute Tool Output Guardrails

The `execute` tool applies the same guardrail model to command output:

- Small stdout/stderr: returned in full.
- Large stdout/stderr: returned as head+tail previews with truncation metadata.

Configuration (config.yml `execute.*` keys and CLI flags too, as for `read`):

- `SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES` (default `65536`): output above this size is truncated.
- `SAMAGOTCHI_EXECUTE_PREVIEW_BYTES` (default `12288`): total preview budget split across head and tail.
- `SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT` (default `80`): include estimated output token impact only when threshold is crossed.
- `SAMAGOTCHI_EXECUTE_TIMEOUT_SEC` (`execute.timeout_sec`, default `120`): what a command still running then gets is `execute.on_timeout`.
- `SAMAGOTCHI_EXECUTE_ON_TIMEOUT` (`execute.on_timeout`, default `task`): `task` hands the command over as a background task, not killed; the result starts `Still running at the 120s limit: moved to a background task, not killed.` (`Execute::HANDED_OVER`), then its `task_id:` and the tails of stdout and stderr so far, and `task_wait` waits for it. `kill` stops it and answers `Error: command timed out after …s` (`Execute::TIMEOUT_PREFIX`) with the hint to use `task_create`. The `!cmd` bang always kills. See [Background tasks](background-tasks.md).

Implementation note:

- Shared logic lives in `lib/samagotchi/tools/output_guardrails.rb` and is used by `read` and `execute`, and by `edit` (its env switches) and `delegate_wait` (the head+tail preview of a child's long reply).

## The runner's cut (`max_tool_output_chars`)

After a tool's own limits, `ToolRunner` caps every result at `max_tool_output_chars` (default `10000`
characters, both loops). How a longer one is cut is the tool's policy, `ToolOutputCut::POLICIES` (by the
built-in name; a tool with none gets `:head`):

| Tool | Policy | What the model gets |
| --- | --- | --- |
| `execute` | `:head_tail_file` | a short head, a long tail, one gap line between them; the whole output saved in the session's folder |
| `task_wait` | `:head_tail_ref` | the same head and tail, the gap line naming the task's log (`output_path`, `Tools::RefText`); nothing saved |
| `delegate`, `delegate_result` | `:head_tail_ref` | the same, the gap line naming the child's reply file (its `output/<timestamp>.txt`); nothing saved |
| `read` and every other tool (`task_get`/`task_list`/`task_create`/`task_stop`, `web_fetch`, `memory_read`, `context_read`, plugin and MCP tools) | `:head` | the first chars, then `[cut: N of M chars; read it in parts]` |

`:head_tail_file` is for output whose end matters: a test run's summary, an error, the `exit:` line. The head is
`execute.cut_head_chars` at most (default `1000`) and never more than a quarter of the room; the tail gets
everything else the cap leaves, so a larger `max_tool_output_chars` keeps a longer tail. Both are snapped to whole
lines when that keeps at least half of each. execute's stdout and stderr blocks are cut each on its own (stdout gets
about two thirds of the room when both are long, a block that needs less gives the rest to the other); the `exit:`
line is always kept. The whole stays within the cap; a cap too small for a tail of `ToolOutputCut::MIN_TAIL` (200)
characters gets the `:head` cut, and so does one whose gap lines leave no room for that tail (checked with the
file's planned path before anything is written): nothing is saved then, and the event has no `output_file:`.

The gap line says what was left out and where the whole output is:

```
[cut: lines 24-1871 of the saved file not shown (41230 of 48211 chars); the whole output is saved in /…/sessions/<id>/tool_output/execute-3f9a1c2b7d10.txt (48211 bytes, 1902 lines): read it with start_line/end_line or rg it; don't rerun the command]
```

A second cut block (stderr) gets a short line, `[cut: lines A-B of the saved file not shown (N chars)]`. The line
numbers are the saved file's. When the output was already a preview (execute's own head+tail above
`execute.truncate_at_bytes`), the line says the preview is what's saved and the full output wasn't kept; for a
command that didn't finish (killed at the limit, stopped) it says the output it printed is saved, and neither says
not to rerun.

**The saved file** (`ToolOutputFiles`): `sessions/<id>/tool_output/<tool>-<sha256[0,12]>.txt`, the output exactly as
the runner had it (its `[execute]` lead and a `ran as:` line included). Not `output/`, the session's reply outbox
(`chi send --wait` and `delegate` take the newest file there as the reply). The name comes from the content, and the
cut text from the content alone (no clock): the same output gives the same text, for the prompt cache and for
loop-guard's repeat check (which still catches fewer exact repeats than a head cut did, since a tail carries
timings). The file goes with the session's folder (deleting the session, the retention sweep); a session keeps its
newest 50 (`ToolOutputFiles::MAX_FILES`, by mtime), so a pruned file named in an old result is "file not found". A
fork or a continue doesn't copy them: its results point at the parent's folder. The whole output, secrets included,
sits on disk as long as the session does. Reading it (`read`, `rg`, `sed -n`) asks no approval: sessions aren't among
the guardrails' chi dirs (keep the folder's name off `context`, which `shell-touches-chi` matches).

**When it can't be saved** (no session: a bare kernel; a write that fails: the error's class, logged as
`tool_output_save_failed`; a session-folder lookup that raises: `no session`), the gap line says so and how to see the
rest: `[cut: N of M chars not shown; the whole output wasn't saved (Errno::ENOSPC); to look past this, rerun with the
output sent to a file (cmd > /tmp/out.txt 2>&1) and read that]`. The turn goes on.

`:head_tail_ref` cuts the whole text as one block, the same way, and saves nothing: the tool returns its text as a
`Tools::RefText` whose `ref_path` is the file the whole of it is in (a reply's file holds only the reply, not the
`session:`/`status:` header) (`KernelLoop#dispatch` passes it on as the
result's `ref_path:`), and the gap line names it: `[cut: N of M chars not shown; the task's whole output is in
<output_path>: read it with start_line/end_line or rg it]`.

The model, the `:tool_call_completed` event and the `after_tool_call` hook get the same cut text; the event and
the runner's result carry the saved file's path as `output_file:`, and the log's `tool_call_completed` line has
`saved=true`.
