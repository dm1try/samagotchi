# Context status telemetry

The kernel surfaces context-usage telemetry to UI consumers (status line,
web/SSE clients) as a `:context_status` stream event. The telemetry itself is
not injected into the model's conversation; what the model gets is one short
line, as a tail system message (`kind: context`), when usage rises into a bucket
whose guidance asks it to change how it works (from the second threshold, 40%
by default, up; never on a fall or a cadence tick, and not again for a bucket a
resumed session's line already names):

`[CONTEXT: about 55% of the context window is in use (estimated; bucket=40plus). context moderate — prefer targeted and range reads over full-file dumps]`

The native loop only (the chat loop has no context status). The event carries
a `status` string using this prefix:

`CONTEXT_STATUS ...`

Emission behavior:

- A status is emitted when estimated usage crosses configured threshold buckets.
- Optional cadence-based updates can also be enabled every N rounds.
- This is warn-only behavior (no automatic history truncation).
- When the model server reports real `usage` fields in the stream payload, the
  telemetry uses those actual token counts (prefixed `src=server`) instead of the
  synthetic char-based estimate (`src=estimate`). The guidance text is dynamic
  and escalates with the bucket: healthy → proceed normally; moderate → prefer
  targeted/range reads; elevated → be concise, avoid large re-reads; critical →
  summarize aggressively and delegate broad work to subagents. With custom
  `context.status_thresholds` the top bucket reads critical, the one below it
  elevated, the next moderate, and the first bucket (and the rest below) healthy.

Configuration:

- `SAMAGOTCHI_CONTEXT_STATUS` (`true` by default): set to `false` or `0` to disable telemetry.
- `SAMAGOTCHI_CONTEXT_WINDOW_TOKENS` / `context.window_tokens`: context window size for when the server doesn't report one. chi asks llama.cpp for its real window first (`/props`, the per-slot `n_ctx`); this setting only fills in when it can't (mlx, oMLX, server down), and 256000 is the last resort.
- `SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN` (default `4.0`): heuristic ratio for char-to-token estimation.
- `SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS` (default `20,40,60,80`): comma-separated threshold percentages.
- `SAMAGOTCHI_CONTEXT_STATUS_CADENCE` (default `0`): emit every N rounds in addition to threshold crossings.
