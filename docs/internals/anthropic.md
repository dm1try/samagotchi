# Anthropic Messages (`api: anthropic`)

A host with `api: anthropic` (Anthropic itself, a gateway passing Claude through, a local server such as Splash,
Fireworks' Anthropic-compatible API) runs the same chat loop as `api: openai`: `LLM::Adapters::BY_API` maps both apis
to an adapter, `HostRegistry::HostEntry#chat?` is true for either, and `Engine#backend_for` picks `LLM::ChatLoop`
(engine.md, "The model↔tool loop"). Only the adapter differs: `LLM::AnthropicMessages` instead of `LLM::OpenAIChat`.
The user-facing settings (`dialect:`, `auth:`, `max_tokens`, the known limits) are in configuration.md.

```
ChatLoop::Run#generate
  → ChatLoop#wire_messages                  # the OpenAI-shaped wire every chat host gets,
                                            # plus anthropic_content on replayed model turns
  → AnthropicMessages#chat
      → #request_body                       # options as Messages takes them, breakpoints on or off
          → AnthropicWire.translate         # system blocks + messages, cache_control placed
          → AnthropicWire.tools             # function schemas → {name, description, input_schema}
      → POST {base}/v1/messages             # LLM::HTTP: retries, cancel, first-token limit
      → AnthropicAssembly#add per SSE event # → ChatResponse (text, reasoning, tool_calls, usage,
                                            #   finish_reason, provider_content)
      → a 400 it can fix: #refusal_fix, then the same request again (once per kind)
```

## Files

Paths are under `lib/samagotchi/llm/`.

| File | Role |
|---|---|
| `adapters.rb` | `Adapters::BY_API` (`openai`, `anthropic`), `.for(entry)`, `.build(api:, …)` for side requests (`IdleClient`) |
| `anthropic_messages.rb` | `AnthropicMessages`: the request body, `#chat` (streamed or not), the 400 fixes, `#list_models`, `#thinking_fields`, `#replays_content?` |
| `anthropic_wire.rb` | `AnthropicWire`: ChatLoop's wire messages as Messages' `system` and `messages`, the two breakpoints, tool ids and names |
| `anthropic_assembly.rb` | `AnthropicAssembly`: a response from a whole body (`.from_message`) or stream events (`#add`), its usage in the OpenAI shape |
| `dialect.rb` | `Dialect` (`STANDARD`, `FIREWORKS`): what a provider's `/v1/messages` does differently |
| `prompt_cache.rb` | `PromptCache.control`: the `cache_control` a breakpoint carries (`cache.ttl`) |
| `chat_loop.rb` | `ChatLoop#replay_blocks`, `#reasoning_history`'s floor, `Run#with_thinking` (saves `anthropic_content`) |

## The adapter

`AnthropicMessages.for(entry)` takes the host's API root, key variable, `auth:`, `dialect:` and remoteness;
`HostRegistry#adapter_for` keeps one per host for the worker's life, so what it learns from a 400 (below) lasts that
long. Each request posts `{base}/v1/messages` with `anthropic-version: 2023-06-01`, the key in the header the host's
`auth:` names (else the dialect's: `x-api-key` on the standard one), and `Session-Id` (plus the dialect's
`session_header`) when the loop has a session id.

`#request_body` builds, in order: `model`, `max_tokens`, `system` (when there is one), `messages`, `stream`, `tools`
with `tool_choice: {type: "auto"}` (when any), then the loop's options. The options lose chi's OpenAI-only fields
(`DROPPED_OPTIONS`: `reasoning_effort`, `chat_template_kwargs`, `stream_options`, `prompt_cache_key`, `logprobs`,
`top_logprobs`, `max_completion_tokens`); configured sampling passes as written. `max_tokens` is the options'
(`default.max_tokens`), else the model list's `max_tokens` capped at `DEFAULT_MAX_TOKENS` (64000), and never over an
output cap a 400 named. `#with_budget_room` keeps `max_tokens` above a budget-form `budget_tokens` plus `MIN_BUDGET`.

`#thinking_fields(level)` is the thinking level on this wire: `off` is `thinking: {type: "disabled"}`; `low`, `medium`
and `high` are `thinking: {type: "adaptive", display: <dialect's>}` with `output_config: {effort: <level>}`; `default`
sends nothing. `#thinking_off_refused_fields` (low effort) is what `IdleClient` sends a side ask whose model refused
thinking off.

`#list_models` reads `GET {base}/v1/models` page by page (`limit=1000`, `after_id`, `has_more`/`last_id`, at most
`AdapterCommon::MAX_MODEL_PAGES`, as OpenAIChat does); `#window_of` takes `max_input_tokens`, else the OpenAI-shaped fields (`ModelListing`).

## Wire translation (`AnthropicWire.translate`)

ChatLoop builds the same OpenAI-shaped wire messages for every chat host (`#wire_messages`); the adapter translates
them:

- The head system message becomes the top-level `system`, as text blocks: with its `cache_split:` (from
  `SystemPrompt#stable_length`) two blocks, the stable part first. A later system message (a reminder, a turn note,
  the CONTEXT line) becomes user text: a mid-conversation system role is model-gated.
- An assistant message with saved blocks (`anthropic_content`) sends them verbatim, a `tool_use`'s name and id made
  valid (`#valid_tool_use`); without them, a text block and its `tool_use` blocks (arguments parsed into the `input`
  object, `{}` with a warning when they aren't a JSON object). An assistant message with neither is dropped.
- Tool messages become `tool_result` blocks in a user message. Ids are made what Messages takes
  (`AnthropicWire.tool_id`: invalid characters replaced and a short hash appended, the same on both sides), and tool
  names too (`.tool_name`), so a malformed one never fails every later request.
- User parts become text and `image` blocks (a data URL as base64, an http(s) URL as a url source).
- Consecutive messages of one role merge into one, its `tool_result` blocks first. Blank text blocks are never sent;
  a user message left empty says `(empty)`. `reasoning_content` and `cache_split` never go out.

## The response (`AnthropicAssembly`)

A stream is read from its `data:` lines alone (a gateway that drops the `event:` lines works), by content-block
index: `message_start` (served model, usage), `content_block_start` (text, thinking, redacted_thinking, tool_use),
`content_block_delta` (`text_delta`, `thinking_delta`, `signature_delta`, `input_json_delta`), `message_delta`
(stop reason, `stop_details`, usage). `AnthropicMessages#chat_streamed` passes every event but `ping` to `on_delta`,
`message_start` and `message_delta` with the usage so far attached (`#with_usage`); a block's start or delta counts as shown for the first-token limit
(`.shows?`). A 200 whose body is a JSON error instead of a stream raises that error (`#raise_plain_error`).

`#response` is a `ChatResponse`:

- `provider_content`: the blocks as received (string keys). A blank text block is dropped (Messages refuses one sent
  back); a `tool_use` input is an object; a thinking block always has a `signature` (`""` when none came).
- `finish_reason` from `FINISH_REASONS`: `end_turn`/`stop_sequence` → `stop`, `max_tokens` and
  `model_context_window_exceeded` → `length`, `tool_use` → `tool_calls`, `refusal` → `refusal`; anything else as it is.
- Usage in the OpenAI shape the rest of chi reads (`TokenUsage`, `SessionMetrics`, `ContextStatus`, the web's
  `ctx.js`): Messages counts `input_tokens` without the cache, so `prompt_tokens` is input + cache reads + cache
  writes, with `cached_tokens` and `cache_write_tokens` under `prompt_tokens_details`. Every field is optional and the
  later value wins; all zeros is no usage (`#usage_payload`: Fireworks' `message_start` carries only zeros).

## Replaying thinking blocks

Messages wants a model turn's blocks back as they came: a thinking block with its signature, in its place among the
text and `tool_use` blocks (a tool loop with thinking needs the last assistant turn's). So:

- `ChatLoop::Run#with_thinking` saves the response's `provider_content` on the model entry as `anthropic_content`,
  beside `thinking:` (string keys, so a resumed session sends the same bytes).
- `AnthropicMessages#replays_content?` is true, and `ChatLoop#replay_blocks` puts those blocks on the wire message,
  which `AnthropicWire` sends verbatim. Not for an interrupted entry (its partial blocks have no signature) nor for
  one with an unpaired call (it goes as flattened text). Before the reasoning boundary (`#reasoning_boundary`) the
  thinking blocks are left out, so only the front of the history loses them; the conversation's last model entry,
  when it has tool calls, keeps them even there (a run stopped between steps left its `tool_use` last).
- `ChatLoop#reasoning_history` floors the level at `turn` on a replaying adapter: `drop` would remove the running
  run's thinking, which Messages needs. For the same reason a reasoning 400 doesn't ask again without reasoning
  (`Run#generate`: it would resend the same body).
- A 400 about a thinking block's signature (`BadRequest#thinking_signature?`, a Claude 5.x block bound to a
  different conversation) fails the turn for now; configuration.md has the known limit.

## Cache breakpoints

`#request_body` asks `AnthropicWire.translate` for breakpoints (`cache: PromptCache.control`, carrying `ttl: "1h"`
under `cache.ttl: 1h`) only for a chat request (`purpose: "chat"`; a recap, `ctx.ask_model` or a triage sets none),
on a dialect with `cache_breakpoints`, and until the host refused `cache_control`. Unlike `PromptCache.mark` on the
OpenAI path, it doesn't look at the model id or remoteness. The two marks:

1. the first `system` block (with `cache_split:`, the stable part; the per-session tail goes after it unmarked), which
   caches the tools and the system prompt for every session on that prefix;
2. the last user block that can carry one (`#mark_last`): never a thinking block, nor one that came from a later
   system message, which moves every request.

The log line's `cache=` says `on`, `1h` or nothing (`#cache_summary`). prompt-caching.md has the cache rules.

## Dialects

`LLM::Dialect` is a host's `dialect:` (`Dialect.parse` warns once on an unknown name or on a host whose api isn't
`anthropic`): `auth` (the default key header), `thinking_display` (the `display` sent with adaptive or budget
thinking, nil for none), `cache_breakpoints` and `session_header`.

| Dialect | auth | thinking display | breakpoints | session header |
|---|---|---|---|---|
| `STANDARD` (no `dialect:`) | `x-api-key` | `summarized` | yes | none |
| `FIREWORKS` | Bearer | none | no (an automatic prefix cache) | `x-session-affinity` |

## 400 fallbacks

`AnthropicMessages#chat` handles the 400s it can fix itself, once each per request, and remembers the fix for the
adapter's life, so ChatLoop's broader paths never see them (`#refusal_fix`, logged under `http`):

| 400 about | Fix | Remembered |
|---|---|---|
| `thinking.display` (`DISPLAY_RE`) | no `display` from now on (`#without_display`), the thinking kept | per host (`thinking_display_refused`) |
| adaptive thinking or its effort (`ADAPTIVE_REFUSED_RE`) | the budget form: `thinking: {type: "enabled", budget_tokens: BUDGETS[level]}`, no effort (`#budget_form`) | per model (`thinking_form_switched`) |
| `cache_control` | no breakpoints | per host (`cache_control_refused`) |
| `max_tokens: N > M` (`OUTPUT_CAP_RE`) | `max_tokens` capped at M | per model (`output_cap`) |

The display check comes before the adaptive one: its path (`thinking.adaptive.display`) names adaptive too. A context
overflow, a refused sampling field, a signature or a binding-controls 400 is not one of these: it goes on as it is,
to the loop's own handling (ChatLoop's sampling and thinking-fields fallbacks) or to the turn's failure.
