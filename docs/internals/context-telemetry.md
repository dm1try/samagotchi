# Context status telemetry

The kernel surfaces context-usage telemetry to UI consumers (status line,
web/SSE clients) as a `:context_status` stream event. The telemetry itself is
not injected into the model's conversation; what the model gets is one short
line, as a tail system message (`kind: context`), when usage rises into a bucket
whose guidance asks it to change how it works (from the second threshold, 40%
by default, up; never on a fall, and not again for a bucket a
resumed session's line already names):

`[CONTEXT: about 55% of the context window is in use (estimated; bucket=40plus). context moderate — prefer targeted and range reads over full-file dumps]`

Both loops do this, before each request (`ContextStatus`, one per turn). The
chat loop's estimate counts the conversation's text and tool calls, not the
tool schemas it sends, until the host's first count (its `usage`). The event
carries a `status` string using this prefix:

`CONTEXT_STATUS ...`

Emission behavior:

- The estimate is emitted on every request (both loops, before each request),
  so the web and the attached TUI get a fresh number each time.
- The model's own `[CONTEXT: …]` line is still gated: it is left only on a rise
  into a guidance bucket (from the second threshold up), never on a fall or a
  cadence tick, and not again for a bucket a resumed session's line already
  names.
- This is warn-only behavior (no automatic history truncation).
- When the model server reports real `usage` fields in the stream payload, the
  telemetry uses those actual token counts (prefixed `src=server`) instead of the
  synthetic char-based estimate (`src=estimate`). The guidance text is dynamic
  and escalates with the bucket: healthy → proceed normally; moderate → prefer
  targeted/range reads; elevated → be concise, avoid large re-reads; critical →
  summarize aggressively and delegate broad work to subagents. With custom
  `context.status_thresholds` the top bucket reads critical, the one below it
  elevated, the next moderate, and the first bucket (and the rest below) healthy.

Under an LLM context strategy (`ContextStatus.new(llm_context:)`, the turn's `LLMContextStrategy::Resolved`, given by
both loops):

- `llm_context.budget_tokens` (or a model's or host's `llm_context_budget_tokens`): the buckets count against the
  budget instead of the window, the smaller of the two. The event's `window_tokens` and the status line's percentage
  are of it too, and so is `payoff`'s top bucket. Without the forget layer the model's line names it, `[CONTEXT:
  about 62% of the context budget (64k tokens) is in use (…)]` (the window when that is the smaller), and its top
  bucket reads "context budget critical — avoid large outputs and re-reads, delegate broad work to subagents": no
  "summarize", as nothing in the model's hands shrinks the context.
- The forget layer replaces the guidance with tiered offers of `forget_outputs`, each line a readout,
  `[CONTEXT: ~52k/64k tokens in use (bucket=60plus). …]`: the readout alone in the guided buckets below the top two
  (CLM: how-to at low pressure makes a model wipe everything); "Finish the unit of work in flight, then tidy once
  with forget_outputs: …" in the one under the top; "Compact settled outputs now with forget_outputs: keep what
  you'll still edit against; don't wipe." in the top bucket, or over the budget (`observe`'s absolute check). They
  come at a turn's first request (`iteration_index` 0: the turn before answered, its outputs are settled) on a rise,
  again when the conversation's last line was the readout alone, and every turn while over the budget; mid-turn a
  rise offers only in the top tier, a lower one gets the readout alone (the layout check: pushed mid-task, models
  forget at the base rate). See internals/llm-context-forget.md.

Configuration:

- `SAMAGOTCHI_CONTEXT_STATUS` (`true` by default): set to `false` or `0` to disable telemetry.
- `SAMAGOTCHI_CONTEXT_WINDOW_TOKENS` / `context.window_tokens`: context window size for when the server doesn't report one. chi asks llama.cpp for its real window first (`/props`, the per-slot `n_ctx`); this setting only fills in when it can't (mlx, oMLX, server down), and 256000 is the last resort.
- `SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN` (default `4.0`): heuristic ratio for char-to-token estimation.
- `SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS` (default `20,40,60,80`): comma-separated threshold percentages. The buckets' guidance still gates the model's own `[CONTEXT: …]` line; nothing else reads `context.status_cadence` (it was removed once the event streamed on every request).
