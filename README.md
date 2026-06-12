# samagotchi
self evolving agent harness

Samagotchi is the full engine name. Chi (pronounced "chee") is the short friendly name and CLI command.

Run with:

- `bin/chi`

## Global Config File

Chi can preload a global config file and expose those entries as environment
variables before the app boots.

Default path:

- `$XDG_CONFIG_HOME/samagotchi/config.yml`
- Fallback when `XDG_CONFIG_HOME` is unset: `~/.config/samagotchi/config.yml`

Example:

```yaml
SAMAGOTCHI_MODEL_PROFILE: qwen36
LLAMA_HOST: 192.168.1.29
LLAMA_PORT: 8081
SAMAGOTCHI_THINKING_UI: spinner
```

Behavior:

- The file is optional.
- Entries must be a flat YAML mapping of scalar values.
- Real environment variables still win over config-file values.

This lets you run `bin/chi` without repeating common defaults such as model
profile or llama host/port on every invocation.

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
- `-v/--verbose` still prints detailed debug logs (raw LLM responses and full
	tool call/result payloads) to stderr.

## Debug Log File

Samagotchi also writes internal debug events to a file so you can inspect runs
without enabling `--verbose` in the terminal.

Default path:

- `./tmp/samagotchi.log`

This file receives verbose-equivalent internal events (for example raw LLM
responses and full tool call/result payloads). It is append-only and intended
for workflows like:

- `tail -f tmp/samagotchi.log`

Configuration:

- `SAMAGOTCHI_LOG_FILE`: override log file path.
- `SAMAGOTCHI_DISABLE_LOG_FILE=true` (or `1`): disable file logging.

Behavior notes:

- `--verbose` still controls stderr output only.
- File logging remains enabled even when `--verbose` is off.

## Project specific description

If an AGENT.md file is present in the project root, samagotchi injects its
contents into the system prompt under a "Project specific description:" section.

To skip loading AGENT.md, set:

`SAMAGOTCHI_SKIP_AGENT_MD=true`

## Memory Scopes

Samagotchi stores memories in two scopes:

- Project scope: `./memories`
- System scope: `~/.config/samagotchi/memories`

Tool behavior:

- `memory_read`: `scope` is optional.
- If `scope` is provided (`project` or `system`), only that scope is read.
- If `scope` is omitted, read falls back from project to system.
- `memory_write`: `scope` is required (`project` or `system`).

At startup, the agent reads both scope indexes with blank-name memory reads
and injects them into the system prompt as `Project memories` and
`System memories`.

These startup index reads are harness-injected context assembly and are not
rendered as `tool>` activity lines.

## Llama HTTP Timeouts

Long-running llama.cpp completions can exceed Ruby's default HTTP read timeout.
Configure these environment variables to avoid premature request failures:

- `LLAMA_OPEN_TIMEOUT` (default: `10`) connection timeout in seconds.
- `LLAMA_READ_TIMEOUT` (default: `600`) response read timeout in seconds.

## Llama Network Retry Behavior

Transient network failures are retried automatically with exponential backoff.

- Default retries: `5` (up to `6` total attempts including the first call).
- Default backoff: `0.5s`, `1s`, `2s`, `4s`, `8s`.
- Retry scope: transient network errors only (timeouts, refused/reset connections, EOF/socket reachability failures).
- Cancellation (`Ctrl-C`) is never retried.

Configuration:

- `SAMAGOTCHI_RETRY_MAX` (default `5`): number of retries after the first failed attempt.
- `SAMAGOTCHI_RETRY_BASE_DELAY` (default `0.5`): backoff base delay in seconds.
- `SAMAGOTCHI_RETRY_MAX_DELAY` (default `8.0`): cap for backoff delay in seconds.

Assist-mode UX:

- While waiting, retry notices are rendered in the existing thinking spinner area as a red `network error: retrying ...` status.
- If retry attempts are exhausted, the submitted prompt is restored into the input editor so you can edit and resubmit.

## Gemma 4 Behavior Contract

This project uses canonical Gemma 4 tool-call parsing and explicit thought-context handling.

### Canonical Tool Calls Only

The kernel loop accepts canonical calls in this format:

`<|tool_call>call:NAME{...}<tool_call|>`

XML tool tags and declaration-echo parsing are intentionally not supported.

### Thought Context Rules

Thought handling follows the Gemma guidance:

- Include `<|think|>` in the system instruction to activate thinking mode.
- When thinking mode is active, the model may emit internal reasoning as `<|channel>thought ... <channel|>`.
- Standard multi-turn: prior model thoughts are stripped from conversation history before the next turn.
- Function/tool-calling exception: during a single turn that includes tool calls, thoughts are not stripped between those tool-call rounds.
- Final model output returned to the caller is thought-stripped.

In short, raw thought blocks are treated as in-turn transient context, not durable history.

### Thinking Spinner Preview

When `SAMAGOTCHI_THINKING_UI=spinner`, the preview renderer uses a deterministic layout:

- Preview lines use a fixed-width app-managed wrapper.
- Status lines use a configurable width mode (terminal-aware by default).
- Wrapping is done by the app (not terminal auto-wrap).
- The preview area always renders a fixed number of logical lines.

Configuration:

- `SAMAGOTCHI_THINKING_PREVIEW_LINES` (default `1`): number of preview lines to render under the spinner. Values are clamped to `1..3`.

Notes:

- Default behavior remains compact (`1` preview line).
- Setting `2` or `3` enables multi-line preview while keeping spinner redraw height stable.
- When a memory entry is loaded during thinking, the spinner line also shows a compact inline preview of that tool call (for example `tool: memory_read(name=...)`) for live visibility before end-of-turn tool logs.

### Thinking-Phase Cancellation

During assist-mode thinking (while the spinner is active), you can cancel an in-flight model request without exiting the process:

- Press `Ctrl-C` to cancel the active request.

Behavior notes:

- Cancellation returns control to the next prompt immediately.
- Partial model output from the canceled request is not committed as a completed model turn.

### Iteration Limit Behavior

- `max_iterations` remains a hard safety cap on tool-call rounds.
- Tool side effects that already ran before the cap are not rolled back.
- `Samagotchi::KernelLoop#run` now returns a resumable result object with the visible output plus the accumulated conversation.
- If the cap is reached while tool calls are still pending, the result is marked resumable so callers can continue from the saved conversation instead of restarting from scratch.
- In assist mode, the CLI now pauses at a compact continue prompt (`continue(yes/no/no_with_reason)>`), where `yes` (or `/continue`) resumes, `no` cancels, and `no, <explanation>` cancels while keeping the reason in conversation context.

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

## Context Status Telemetry

The kernel can emit synthetic system telemetry messages to help the model plan under context pressure.
Telemetry messages use this prefix:

`CONTEXT_STATUS ...`

Emission behavior:

- A status is emitted when estimated usage crosses configured threshold buckets.
- Optional cadence-based updates can also be enabled every N rounds.
- This is warn-only behavior (no automatic history truncation).

Configuration:

- `SAMAGOTCHI_CONTEXT_STATUS` (`true` by default): set to `false` or `0` to disable telemetry.
- `SAMAGOTCHI_CONTEXT_WINDOW_TOKENS` (default `256000`): estimated context window size.
- `SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN` (default `4.0`): heuristic ratio for char-to-token estimation.
- `SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS` (default `20,40,60,80`): comma-separated threshold percentages.
- `SAMAGOTCHI_CONTEXT_STATUS_CADENCE` (default `0`): emit every N rounds in addition to threshold crossings.

## Status Line

Assist mode can render a compact generalized status line that can include mode,
context estimate, and active memory hints.

Behavior:

- A static status line is printed before the next `>` prompt in assist mode.
- During spinner rendering, status details are rendered in the spinner block.
- When llama.cpp streaming payload includes usage fields, status prefers server-derived token telemetry (`p`, `c`, `t`) and context percent.
- If server usage fields are absent, status falls back to synthetic `CONTEXT_STATUS` estimate telemetry.
- When a memory is loaded between tool rounds, the spinner line includes a `loaded: <memory>` notification immediately after the spinner frame.
- After responses, memory details are shown via the same unified `status>` line.
- The legacy standalone `memories>` summary line is no longer emitted.

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

## Read Tool Size Guardrails

The `read` tool now applies adaptive limits to avoid accidental context exhaustion
when opening very large files (for example, VCR cassettes).

Behavior:

- Small files: return full file content.
- Large files: return a head+tail preview plus truncation metadata.
- Extremely large files: return an error indicating the hard size limit.

Configuration:

- `SAMAGOTCHI_READ_TRUNCATE_AT_BYTES` (default `65536`): files above this size return a preview instead of full content.
- `SAMAGOTCHI_READ_PREVIEW_BYTES` (default `12288`): total preview budget split across head and tail.
- `SAMAGOTCHI_READ_HARD_MAX_BYTES` (default `2097152`): files above this size return `Error: file too large`.

Optional preview telemetry:

- `SAMAGOTCHI_READ_TELEMETRY_THRESHOLD_PCT` (default `80`): include estimated preview token impact only when preview payload is at or above this percentage of the configured context window.

Telemetry uses existing context estimation settings:

- `SAMAGOTCHI_CONTEXT_WINDOW_TOKENS`
- `SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN`

## Execute Tool Output Guardrails

The `execute` tool applies the same guardrail model to command output:

- Small stdout/stderr: returned in full.
- Large stdout/stderr: returned as head+tail previews with truncation metadata.

Configuration:

- `SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES` (default `65536`): output above this size is truncated.
- `SAMAGOTCHI_EXECUTE_PREVIEW_BYTES` (default `12288`): total preview budget split across head and tail.
- `SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT` (default `80`): include estimated output token impact only when threshold is crossed.

Implementation note:

- Shared logic lives in `lib/samagotchi/tools/output_guardrails.rb` and is used by both `read` and `execute`.
- Additional tools that can emit large payloads should rely on this shared helper for consistent behavior.
