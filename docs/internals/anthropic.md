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
          → AnthropicWire.tools             # function schemas → {name, description, input_schema},
                                            #   a deferred one with defer_loading: true
      → POST {base}/v1/messages             # LLM::HTTP: retries, cancel, first-token limit
      → AnthropicAssembly#add per SSE event # → ChatResponse (text, reasoning, tool_calls, usage,
                                            #   finish_reason, provider_content)
      → a signature 400 (Claude 5.x preserved thinking): AnthropicBindingRecovery#advance, then the same
        request with drop_block or the blocks stripped; ChatResponse#thinking_drop names them
      → a 400 it can fix: #refusal_fix, then the same request again (once per kind)
  → ChatLoop#settle_dropped_thinking!       # the dropped blocks leave the stored model entries
```

## Files

Paths are under `lib/samagotchi/llm/`.

| File | Role |
|---|---|
| `adapters.rb` | `Adapters::BY_API` (`openai`, `anthropic`), `.for(entry)`, `.build(api:, …)` for side requests (`IdleClient`) |
| `anthropic_messages.rb` | `AnthropicMessages`: the request body, `#chat` (streamed or not), the 400 fixes, `#list_models`, `#thinking_fields`, `#replays_content?` |
| `anthropic_binding_recovery.rb` | `AnthropicBindingRecovery`: the preserved-thinking recovery (`#advance` picks drop_block or strip for a signature 400, `#recovered_body`, `#with_thinking_drop`); one per adapter |
| `anthropic_wire.rb` | `AnthropicWire`: ChatLoop's wire messages as Messages' `system` and `messages`, the two breakpoints, tool ids and names |
| `anthropic_assembly.rb` | `AnthropicAssembly`: a response from a whole body (`.from_message`) or stream events (`#add`), its usage in the OpenAI shape |
| `dialect.rb` | `Dialect` (`STANDARD`, `FIREWORKS`): what a provider's `/v1/messages` does differently |
| `../tools/deferred_tools.rb` | `Tools::DeferredTools.list`: the tools a request declares deferred (Deferred tools) |
| `prompt_cache.rb` | `PromptCache.control`: the `cache_control` a breakpoint carries (`cache.ttl`) |
| `chat_loop.rb` | `ChatLoop#replay_blocks`, `#reasoning_history`'s floor, `Run#with_thinking` (saves `anthropic_content`), `#settle_dropped_thinking!` |

## The adapter

`AnthropicMessages.for(entry)` takes the host's API root, key variable, `auth:`, `dialect:` and remoteness;
`HostRegistry#adapter_for` keeps one per host for the worker's life, so what it learns from a 400 (below) lasts that
long. Each request posts `{base}/v1/messages` with `anthropic-version: 2023-06-01`, the key (`LLM::ApiKey`: the
variable `api_key_env:` names, else, on macOS, the login Keychain's item for that name, `HostKeys`; configuration.md,
"API keys from the Keychain") in the header the host's
`auth:` names (else the dialect's: `x-api-key` on the standard one), and `Session-Id` (plus the dialect's
`session_header`) when the loop has a session id.

`#request_body` builds, in order: `model`, `max_tokens`, `system` (when there is one), `messages`, `stream`, `tools`
with `tool_choice: {type: "auto"}` (when any), then the loop's options. The options lose chi's OpenAI-only fields
(`DROPPED_OPTIONS`: `reasoning_effort`, `chat_template_kwargs`, `stream_options`, `prompt_cache_key`, `logprobs`,
`top_logprobs`, `max_completion_tokens`); configured sampling passes as written. `max_tokens` is the options'
(`default.max_tokens`), else the model list's `max_tokens` capped at `DEFAULT_MAX_TOKENS` (64000), and never over an
output cap a 400 named. `#with_budget_room` keeps `max_tokens` above a budget-form `budget_tokens` plus `MIN_BUDGET`.

`#thinking_fields(level)` is the thinking level on this wire: `off` is `thinking: {type: "disabled"}` (sent as `{type:
"between_tools"}` to a model whose 400 for `disabled` names that form, Claude 5.x: see the 400 fallbacks); `low`, `medium`
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
(`.shows?`). A 200 whose body is a JSON error instead of a stream raises that error (`LLM::AdapterCommon#raise_plain_error`, shared with the OpenAI adapter).

`#response` is a `ChatResponse`:

- `provider_content`: the blocks as received (string keys). A blank text block is dropped (Messages refuses one sent
  back); a `tool_use` input is an object; a thinking block always has a `signature` (`""` when none came).
- `finish_reason` from `FINISH_REASONS`: `end_turn`/`stop_sequence` → `stop`, `max_tokens` and
  `model_context_window_exceeded` → `length`, `tool_use` → `tool_calls`, `refusal` → `refusal`; anything else as it is.
- Usage in the OpenAI shape the rest of chi reads (`TokenUsage`, `SessionMetrics`, `ContextStatus`, and the
  Bridge's chunk `counts` the web's `ctx.js` reads): Messages counts `input_tokens` without the cache, so `prompt_tokens` is input + cache reads + cache
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
- A 400 about a thinking block's signature (`BadRequest#thinking_signature?`) is recovered in the adapter, and the
  blocks it cost leave the history (next section).

## Preserved thinking (Claude 5.x)

Claude 5.x models bind each thinking block to the prefix it was minted after: both `system` blocks (the stable part
and the per-session tail), the tool set, and every earlier message. Sent back after any of those changed, the block
gets a 400 `messages.N.content.M: Invalid signature in thinking block. The block is bound to a different
conversation.`, and its last sentence says what changed ("The `system` prompt differs …"). chi's history is
append-only within a process, so what changes the prefix is:

1. **A system-prompt rebuild** (`SystemPrompt#build` is cached per process and key; `PromptBuilder#reset!` drops it):
   a new process (`--resume`, a respawn after `session.idle_exit_minutes`, a crash) after a memory index line, an
   AGENTS.md, an appended file, a model note or a bundle memory changed; `/model` (the tail's `Model:` line, its
   overlays and notes); `/thinking` (another key); a toolkit or profile change; a plugin's `tools_changed!`.
2. **A tool set change**: the same triggers, plus MCP lines that differ on a respawn.
3. **History edits by design**: the `llm_context` `stale`/`forget` stubs, and the image cut moving a batch.

A model switch never 400s: the API drops blocks another model can't read silently (`model_binding_mismatch`).

**Recover on the 400, then settle.** Normal requests carry no beta header and no `block_binding`, so Fireworks,
Splash and gateways see the same bytes as before. On a signature 400, before anything streamed,
`AnthropicBindingRecovery#advance` (one per adapter, `anthropic_binding_recovery.rb`) picks the next step, once each per request:

- **drop_block**: the same body with `thinking.block_binding: {prefix_mismatch_behavior: "drop_block"}` (the body's
  adaptive or enabled thinking, `display` as sent; adaptive when the level sends none) and the header
  `anthropic-beta: thinking-binding-controls-2026-08-01`. The answer's `input_transformations` (in `message_start`'s
  message, or the body; `AnthropicAssembly#input_transformations`) list the dropped blocks by path into the body
  sent; the adapter maps the `prefix_binding_mismatch` ones to block identities. Any other entry
  (`model_binding_mismatch`: a switch back reads those blocks again) is counted as kept, never settled.
- **strip**: the block the 400 names (else the first replayed thinking block) and every thinking or
  redacted_thinking block after it removed from the body (a trailing run, which Messages takes). For a bad
  signature (the 400 without "bound to a different conversation": drop_block doesn't apply), thinking `disabled`
  (block_binding goes only with adaptive or enabled), a model on the budget form with no thinking field, a host
  that refused the controls (`binding_controls`, remembered), or a second signature 400 after drop_block.

A third signature 400 fails the turn. The extra requests are 400s, rejected before generation and not billed. The
step is request state that `#request_body`'s rebuild keeps, so a later `#refusal_fix` (display, cache_control,
output cap) in the same request keeps the binding or the strip. The response carries `thinking_drop`
(`LLM::ThinkingDrop`: `identities`, `how`), and the adapter logs `thinking_recovered` (`how`, `dropped`, `kept`,
`why`: the 400's last sentence).

A block's identity (`AnthropicWire.block_identity`, shared by the adapter and ChatLoop) is its `signature`, a
redacted block's `data`, or, when that is empty (Splash's `signature: ""`), `text:` + the SHA256 of its text.

`ChatLoop::Run#generate` hands those identities to `ChatLoop#settle_dropped_thinking!` before the step adds its own
entry, whatever the finish reason: each model entry holding one is replaced in place (same index) with a copy
without those blocks (`thinking:` stays; an entry left with none loses `anthropic_content`). That is the edit the
API made, so the next request is valid with no beta (a pruned history is valid: removing exactly the dropped set
leaves no gap), and the session file keeps it, since `Engine#kept_messages` and `#failed_messages` take the run's
conversation whole. It emits `:thinking_dropped` (`count`, `how`) and `thinking_dropped` on `:generation_completed`,
which `SessionMetrics` sums for `/stats`. A drop that settles nothing (blocks already settled came back, e.g. a
rolled-back turn's) logs `thinking_recovery_repeated` once per run. A cancelled, cut or dropped generation settles
nothing; the next request recovers again.

Each break costs one free 400, one cache write of the prefix from the edit point, and the reasoning the dropped
blocks carried. Whether the request after a drop_block one reads the cache that request wrote (it no longer carries
`block_binding`) is unverified.

Why not send drop_block on every request: it needs adaptive or enabled thinking on the body (`default` sends no
thinking field, `off` sends disabled), it would put a beta header on every request to every host, and it would drop
the same blocks again on every request until something pruned them. The reactive form does the same work in one
place, for one extra 400 round trip per break. The `anthropic-thinking-prefix-mismatch` diagnosis header (on the
400, undocumented) is named by the adapter to its `LLM::HTTP` (`diagnosis_header:`, from
`AnthropicBindingRecovery::DIAGNOSIS_HEADER`), which keeps it on the provider error; it is logged as `diagnosis` on
`thinking_recovered`. The shared transport reads no provider header of its own.

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
thinking, nil for none), `cache_breakpoints`, `session_header` and `tool_loading` (deferred tools, below).

| Dialect | auth | thinking display | breakpoints | session header | tool loading |
|---|---|---|---|---|---|
| `STANDARD` (no `dialect:`) | `x-api-key` | `summarized` | yes | none | yes |
| `FIREWORKS` | Bearer | none | no (an automatic prefix cache) | `x-session-affinity` | no |

## Deferred tools

A session declares its toolkit's tools; the ones it reaches but doesn't declare (the built-ins its toolkit leaves out
without removing them, an MCP server's tools in the tool index) are found with `find_tools` and called with
`call_tool` on every host. On a Messages host they also go in `tools` with `defer_loading: true`, after the declared
ones: the model sees their names only when something loads them, and the API accepts a call of one by its own name.
`AnthropicMessages#loads_tools?(model)` says whether a request does this: the dialect's `tool_loading`, unless the
host refused it for that model.

`ChatLoop#tool_definitions(conversation, model:)` appends them (`Tools::DeferredTools.list`) only on such an
adapter, and only with at least one tool declared (Messages wants one). The list, per request:

1. the built-ins the toolkit reaches (`Registry#reachable_names`), in registry order;
2. the tool index's source tools while `call_tool` is declared (`ToolIndex#deferrable`, via
   `Registry::Index#deferrable`): callable, the only tool with its acts_as, a name Messages takes, no registered
   tool's name; by acts_as (`mcp_<server>_<tool>`), sorted by name;
3. every other name the conversation loaded (a find result's `loaded:`, a tool change's `add:`) that isn't declared,
   as a stub ("Not available right now; find_tools finds it when it is.", an empty object schema): its server is
   gone or still starting, and the reference in the history must name a tool in `tools`.

A deferred tool never carries `cache_control`, and the list sits after the declared tools, so the cached prefix holds
(prompt-caching.md). A session with nothing to defer (full, no MCP server) sends the bytes it always did.

### Loading by reference

A `find_tools` keyword hit loads its callable matches (`ToolIndex::FoundText#loaded`, at most `FIND_RESULTS`: a
built-in by its name, a source tool by its acts_as when it is deferrable; an empty query, a miss or the names listing
load nothing). `KernelLoop#dispatch` passes them on (`dispatched[:loaded]`), `ToolRun#loaded` carries them and
`ToolResponse.single` saves them on the result as `loaded:` (every chat host; `ToolResponse.joined` doesn't).
`ChatLoop#wire_messages` copies them onto the tool message only for an adapter that loads tools.
`AnthropicWire.translate(wire, cache:, deferred:)` takes the names this request declares deferred and renders a
result's `loaded:` names among them as a tool_result holding only
`{"type": "tool_reference", "tool_name": …}` blocks (Messages takes no other content beside a reference), followed by
a sibling text block: `Loaded: a, b. Call them directly by these names.`, then the result's text without its
`Call one with call_tool(…)` line (`ToolIndex::CALL_HINT`; the saved result keeps it). With that line and a trailing
"(call_tool works too)", Sonnet and Haiku 5.5 went through `call_tool` 2/2 live; without, 5/5 called the tool by
name. A result whose names aren't deferred here (declared since, or no tool loading) goes as plain text. The sibling
text is never marked; when breakpoint #2 falls on such a tool_result, it goes on its last reference.

### Tool changes (`ctx.load_tools`)

A plugin's `ctx.load_tools(names)` stages wire names (`Engine#load_tools`: `ToolIndex#deferred_name`, idempotent
against the staged names and the history's earlier changes, `ToolLoads`). `Engine#turn_messages` appends them after
the turn's user message (on a turn with none, after its trailing results or notes; a conversation ending with a reply
keeps them staged) as one `ToolLoads.entry` per bundle (`kind: "tool_change"`), only when the turn's host
`tool_changes?` (`AnthropicMessages#tool_changes?`: `loads_tools?`, unless the host refused changes for the model);
otherwise the staged names are dropped and logged (`tool_loads_not_sent`). `ChatLoop#wire_messages` sends the entry
only to such an adapter, `Prompt.format*` skips it. `AnthropicWire.translate` turns it into a `role: "system"` message
of its own, `{"type": "tool_addition", "tool": {"type": "tool_reference", "name": …}}` per name deferred in this
request (none: no message; note `name` here, `tool_name` in a result's reference), held until the run of user-role
messages it sits in ends: before the next assistant message, or last. `AnthropicMessages` adds
`INLINE_TOOLS_BETA` (`inline-tools-2026-09-15`) to `anthropic-beta` when the body has such a message, comma-joined with
the binding beta on a drop_block step. A 400 naming `tool_addition`, the beta or a system role (`TOOL_CHANGES_RE`)
sets `:tool_changes` for the model: the retry and every later request drop the system messages and the beta.

A direct call of a deferred tool runs whether something loaded it or not (the API doesn't check): the Engine sets
`TurnSettings#loads_tools` from the turn's final model (after the before_turn hooks), and then `ToolRunner#run` and
`KernelLoop#dispatch` take a reachable built-in by its own name (`Registry#indexed`) through the normal gate, and wrap
an MCP tool's acts_as into the `call_tool` call it stands for (`ToolIndex#wrap`): `call_tool`'s row, rules and
approvals. A reload rebuilds that wrapped call from the saved one (`BuiltinCalls.wrap_saved`). Each such call is
logged (`tool_direct_deferred`, with `loaded:` whether the conversation had loaded it). On `api: openai` and the
native loop nothing is deferred, and a direct call of a reachable built-in is refused with the `call_tool` route as
before.

## 400 fallbacks

`AnthropicMessages#chat` handles the 400s it can fix itself, once each per request, and remembers the fix for the
adapter's life, so ChatLoop's broader paths never see them (`#refusal_fix`, logged under `http`; kept in an
`LLM::RefusalMemo`, locked, since the turn thread and the model-list reads share the host's adapter; `IdleClient`,
whose recap, side answers and triage each build their own adapter (`Adapters.build`), keeps what it learned for that
client's life only):

| 400 about | Fix | Remembered |
|---|---|---|
| `thinking.display` (`DISPLAY_RE`) | no `display` from now on (`#without_display`), the thinking kept | per host (`thinking_display_refused`) |
| adaptive thinking or its effort (`ADAPTIVE_REFUSED_RE`) | the budget form: `thinking: {type: "enabled", budget_tokens: BUDGETS[level]}`, no effort (`#budget_form`) | per model (`thinking_form_switched`) |
| `thinking: {type: "disabled"}` where the 400 names `between_tools` (`THINKING_OFF_FORM_RE`; Claude 5.x) | `thinking: {type: "between_tools"}` wherever `disabled` was asked (`#thinking_between_tools`), so a recap or side answer (`IdleClient` step 0) and a `--thinking off` session never fall back to adaptive low or to no thinking fields; a model that refuses `between_tools` too raises the 400 as before | per model (`thinking_off_form_switched`) |
| `cache_control` | no breakpoints | per host (`cache_control_refused`) |
| `max_tokens: N > M` (`OUTPUT_CAP_RE`) | `max_tokens` capped at M | per model (`output_cap`) |
| `block_binding` or the binding beta, on a drop_block retry (`thinking_binding_unsupported?`) | the strip instead (Preserved thinking) | per host (`binding_controls_refused`) |
| `tools.N.input_schema` (`TOOL_SCHEMA_RE`) where tool N is deferred | that tool leaves the deferred list (`call_tool` still reaches it); one fix per tool (the fix value is `[:tool_schema, name]`), at most `MAX_SCHEMA_FIXES` (5) per request; the names kept by `RefusalMemo#add` | per model (`tool_schema_refused`) |
| `tool_addition`, the inline-tools beta or a system role (`TOOL_CHANGES_RE`) on a request with a tool change | no system messages and no beta from then on (`#tool_changes?` false); the tools stay deferred and callable | per model (`tool_changes_refused`) |
| `defer_loading` or `tool_reference` (`TOOL_LOADING_RE`) on a request that carries either | no deferred tools from then on (`#loads_tools?` false, loads go as text); a direct call of a reachable tool is refused again from the next turn (`TurnSettings#loads_tools`) | per model (`tool_loading_refused`) |

The display check comes before the adaptive one: its path (`thinking.adaptive.display`) names adaptive too. A context
overflow, a refused sampling field, a signature or a binding-controls 400 is not one of these (`#refusal_fix` keeps
excluding them, so `ADAPTIVE_REFUSED_RE` never reads a binding 400's "adaptive" as a form refusal): a signature 400
goes to the binding recovery above, the rest on as they are, to the loop's own handling (ChatLoop's sampling and
thinking-fields fallbacks) or to the turn's failure. A tool-loading fix's retry that breaks a replayed thinking
block's binding gets a signature 400 like any other request, and the binding recovery takes it. These refusals come on
the first request that carries the feature, normally a turn's first.
