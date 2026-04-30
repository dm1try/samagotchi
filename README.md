# samagotchi
self evolving agent harness

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

For blank-name reads, the agent can fetch scope indexes separately and inject
them into the system prompt as `Project memories` and `System memories`.

## Llama HTTP Timeouts

Long-running llama.cpp completions can exceed Ruby's default HTTP read timeout.
Configure these environment variables to avoid premature request failures:

- `LLAMA_OPEN_TIMEOUT` (default: `10`) connection timeout in seconds.
- `LLAMA_READ_TIMEOUT` (default: `600`) response read timeout in seconds.

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

### Iteration Limit Behavior

- `max_iterations` remains a hard safety cap on tool-call rounds.
- Tool side effects that already ran before the cap are not rolled back.
- `Samagotchi::KernelLoop#run` now returns a resumable result object with the visible output plus the accumulated conversation.
- If the cap is reached while tool calls are still pending, the result is marked resumable so callers can continue from the saved conversation instead of restarting from scratch.
- In assist mode, the CLI now pauses and requires `/continue` to resume the interrupted turn.

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
