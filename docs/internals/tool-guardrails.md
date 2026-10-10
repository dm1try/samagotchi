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
- `SAMAGOTCHI_EXECUTE_TIMEOUT_SEC` (`execute.timeout_sec`, default `120`): a command running longer is stopped and answers `Error: command timed out after …s`.

Implementation note:

- Shared logic lives in `lib/samagotchi/tools/output_guardrails.rb` and is used by `read` and `execute`, and by `edit` (its env switches) and `delegate_wait` (the head+tail preview of a child's long reply).
- Additional tools that can emit large payloads should rely on this shared helper for consistent behavior.
