# Anthropic Messages provider fixtures

Bodies of `POST /v1/messages` (and `GET /v1/models`, `POST /v1/messages/count_tokens`) for
the `api: anthropic` adapter. `*.sse` are streamed bodies, `*.json` plain bodies; a recorded
`*.json` has its HTTP status in the sibling `*.status`. A hand-written error body's status is
the one in its name (and its `error.type`).

## Recorded: Splash (`splash_*`, no `hand-written` in the name)

Recorded with curl on 2026-10-13 from Splash 1.3.1 (`mlx-community/Qwen3.6-35B-A3B-4bit`, no
key) by the P2b S0 probe. Bodies are byte for byte except the two trimmed streams below; no
key, host address or path is in them (Splash sends none).

| File | Request | What it shows |
|---|---|---|
| `splash_text_sync.json` | no `thinking` | one `text` block, `end_turn`; usage `input_tokens` + `cache_read_input_tokens` + `output_tokens`, no `cache_creation_input_tokens` |
| `splash_thinking_stream.sse` | streamed, `display: summarized` | thinking block (start carries `"signature":""`, **no** `signature_delta`), then text, `end_turn`. **Trimmed**: 1164 `thinking_delta` events recorded; the first and last 8 `thinking_delta` events kept, the middle dropped, everything else as recorded (so `output_tokens` is larger than the deltas left) |
| `splash_thinking_tool_use.json` | tools, not streamed | thinking (`signature: ""`) + two parallel `tool_use` blocks, `tool_use`; no cache read |
| `splash_cache_read.json` | the turn after the tool results | thinking + text; usage with `cache_read_input_tokens` (the prefix reused) |
| `splash_tool_stream.sse` | tools, streamed | thinking, then per call `content_block_start` tool_use (`input: {}`) + three `input_json_delta`, `tool_use` |
| `splash_tool_stream_bad_name.sse` | the same request | the intermittent streaming glitch: both calls named `"get_weather\n</parameter"` (input right). The adapter must treat it as an unknown tool name (a tool error back to the model), nothing special |
| `splash_thinking_max_tokens_stream.sse` | streamed, `enabled` + `budget_tokens: 1024`, `max_tokens: 6000` | thinking runs to `max_tokens` (1.3.1 does not cap at the budget), then Splash opens and closes an **empty text block** (`content_block_start(1, text "")` → `content_block_stop`) → `message_delta` `max_tokens`. The empty text block is no text (the empty-answer / limit path), not an empty answer to show. **Trimmed**: 6000 `thinking_delta` events recorded; the first and last 8 `thinking_delta` events kept, the full ending as recorded |
| `splash_budget_accepted.json` | `enabled` + `budget_tokens: 1024`, not streamed | the budget accepted (no 400) and not enforced: ~1500 tokens of thinking, then a one-word answer |
| `splash_models.json`, `splash_model.json` | `GET /v1/models`, `GET /v1/models/{id}` | OpenAI-shaped list (`data[].context_length`, `max_model_len`, `vision`, `input_modalities`) plus an extra `models` array; no `has_more` |
| `splash_count_tokens.json` | `count_tokens` | `{"input_tokens": N}` |
| `splash_error_400_between_tools.json` | `thinking: {type: "between_tools"}` | 400 `invalid_request_error` "thinking.type must be enabled, disabled, or adaptive" |
| `splash_error_404_unknown_model.json` | an unknown model id | 404 `not_found_error` (mapped like a model not found: not retried) |

## Hand-written (`*.hand-written.*`)

Not recorded: Splash 1.3.1 can't produce them, or they come from Anthropic's API (no key used
for fixtures). Shapes follow Anthropic's documented API (the claude-api skill, cached
2026-10-06) or Splash's source (github.com/incoai/splash main, read 2026-10-13). Ids,
signatures and redacted data are made up; signatures are not valid.

| File | Source | What it shows |
|---|---|---|
| `text_stream.hand-written.sse` | Anthropic docs | text stream with a `ping`; `message_start` usage with cache creation and read, `message_delta` usage with only `output_tokens` |
| `thinking_tool_use_stream.hand-written.sse` | Anthropic docs | summarized thinking + `signature_delta`, then `tool_use` via `input_json_delta` (first fragment empty) |
| `interleaved_stream.hand-written.sse` | Anthropic docs | thinking, text, tool_use, thinking, tool_use in one message (interleaved thinking) |
| `thinking_budget_capped_stream.hand-written.sse` | Anthropic docs | `enabled` thinking closed within its budget, then the answer, `end_turn`. **Placeholder**: Splash 1.3.1 does not cap thinking at `budget_tokens` (the cap is in Splash main, commit c1e1e3f5, after 1.3.1); re-record from the next Splash release and replace this file (Splash will send no `signature_delta`) |
| `stream_error.hand-written.sse` | Anthropic docs | a mid-stream `event: error` with `{"type":"error","error":{"type":"overloaded_error"}}` (no numeric code: classified by its type) |
| `redacted_thinking.hand-written.json` | Anthropic docs | a `redacted_thinking` block (`data`) beside an omitted thinking block (empty text, signature) and text |
| `refusal.hand-written.json` | Anthropic docs | `stop_reason: refusal` with `stop_details` (`type`, `category`, `explanation`), empty content |
| `context_window_exceeded.hand-written.json` | Anthropic docs | `stop_reason: model_context_window_exceeded` with partial text |
| `models_page1.hand-written.json`, `models_page2.hand-written.json` | Anthropic docs | the Anthropic model list in two pages (`has_more`, `first_id`, `last_id`; `max_input_tokens`, `max_tokens`, `capabilities`); page 2 is a model that takes `enabled` but not `adaptive` |
| `fireworks_text_stream.hand-written.sse` | Fireworks docs (anthropic-compatibility, the Messages API reference) | Fireworks' stream usage: `message_start` usage all 0, every count (`input_tokens` without the cache, `cache_read_input_tokens`, `cache_creation_input_tokens` always 0, `output_tokens`) in the one `message_delta`. Replace with a recording after the gateway probe |
| `fireworks_thinking_tool_use_stream.hand-written.sse` | Fireworks docs (the worst case they leave open) | a thinking block whose `content_block_start` carries **no** `signature` key and no `signature_delta` follows, then a `tool_use` (Fireworks-style id `functions.get_weather:0`); zero usage in `message_start`, counts in `message_delta`. Whether Fireworks sends a signature is unverified (T3): replace after the gateway probe |
| `fireworks_error_404_not_found.hand-written.json` | Fireworks docs (pre-routing errors: the HTTP status is authoritative) | an unknown model: `{"error":{"code":"NOT_FOUND",…},"request_id":…}`, a string code instead of a number (the `type`/`object` fields are a guess) |
| `fireworks_models.hand-written.json` | Fireworks docs (the OpenAI-compatible list; undocumented on the Messages surface, T5) | OpenAI-shaped list with Fireworks' `supports_image_input`, `supports_tools`, `context_length`; one model with images and tools, one without |
| `splash_omitted_thinking_stream.hand-written.sse` | Splash source (`server.py`) | `display: omitted` on Splash: an empty `thinking_delta`, then the reasoning encrypted into a `signature_delta` (not probed in S0) |
| `splash_ping_progress_stream.hand-written.sse` | Splash DEVELOPMENT.md / source | `ping` events carrying `prompt_progress` `{total, cache, processed, time_ms}` (only with `return_progress: true`; S0 saw none), then a plain keep-alive `ping` |
| `error_400_prompt_too_long.hand-written.json` | Anthropic docs | the context overflow 400, "prompt is too long: N tokens > M maximum" |
| `error_400_signature_other_conversation.hand-written.json` | Anthropic docs | a thinking block bound to a different conversation (edited history), without the beta header |
| `error_400_signature_invalid.hand-written.json` | Anthropic docs | a tampered or unreadable signature: the same leading clause, without "bound to a different conversation" |
| `error_400_block_binding_extra.hand-written.json` | Anthropic docs | `block_binding` sent without the binding beta header ("…block_binding: Extra inputs are not permitted"; the path before it is made up) |
| `error_400_binding_beta_unknown.hand-written.json` | Anthropic docs | the binding beta header refused where it is not offered ("Unexpected value(s) … for the `anthropic-beta` header.") |
| `error_400_budget_tokens_refused.hand-written.json` | Anthropic docs | `budget_tokens` (`"thinking.type.enabled"`) refused on a current model |
| `error_400_disabled_refused.hand-written.json` | Anthropic docs | `thinking: {type: "disabled"}` refused on a current model |
| `error_401.hand-written.json` | Anthropic docs | `authentication_error` |
| `error_429.hand-written.json` | Anthropic docs | `rate_limit_error`; the wait comes in the `retry-after` header, not the body (a spec passes it as `retry_after:`) |
| `error_529.hand-written.json` | Anthropic docs | `overloaded_error` (retried) |
| `splash_error_503_overloaded.hand-written.json` | Splash DEVELOPMENT.md | Splash's full queue: 503 `overloaded_error` with `Retry-After: 1` (the header is not in the file) |
