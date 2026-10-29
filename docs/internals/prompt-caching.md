# Prompt caching: how a request is laid out, and how to keep it cache-friendly

A model server reuses work only for the **exact token prefix** it has already seen. Change one token and
everything after it is computed again (prefill). The local models we run (hybrid Qwen 3.6 / Ornith on llama.cpp
and Splash) can only resume from a **restore point near the end** of an earlier prompt, not from any shared
prefix. Anthropic (Claude via OpenRouter, or over the Messages API, `api: anthropic`) caches only up to an explicit
`cache_control` breakpoint. So the order of what chi sends decides what a new turn, or a new session, has to pay
for.

Measured with prompt-cache slice 1 (2026-10-04, fresh sessions, ~7.7k-token prompt):

| Server | Before | After |
|---|---|---|
| Ornith on llama.cpp | 0 tokens reused, 6.4 s prefill per session | 94% reused, 0.5 s |
| Splash Qwen 3.6 | 3.8 s | 97% reused from the 3rd session, 0.27 s |
| Sonnet via OpenRouter | full cache write, $0.024 per session | reads the stable part, $0.0035 |

## The layers of a request

From the first token to the last. Every layer is a prefix of the next request's layers, unless something in the
right-hand column happens.

```
 shared by every session ──────────────────────────────────────────────────  breaks it
┌──────────────────────────────────────────────────────────────────────────┐
│ tools        built-ins, then plugin tools sorted by (bundle, name),      │  a tool added/changed,
│              the tool index's find_tools/call_tool as bundle "index"     │
│              (per toolkit; MCP lines from load, the chi line per toolkit)│
│              those the session's toolkit declares (per toolkit)          │  /model, a profile change,
│              (chat: the `tools` field; native: the model's template)     │  a toolkit change
├──────────────────────────────────────────────────────────────────────────┤
│ SYSTEM, stable part                         SystemPrompt#system_prompt_with_index
│   [native thinking token] base prompt                                    │
│   not-loaded line (only when the toolkit leaves tools out:               │
│     not declared / removed)                                              │
│   rg guidance                                                            │  /thinking level,
│   system identity (+ model overlay)                                      │  /model, editing a
│   model notes (model_notes_* matching the model)                         │  memory / AGENTS.md
│   explicit (preloaded) memories                                          │
│   AGENTS.md (root → cwd)                                                 │  (picked up by a new
│   appended files (append_system_prompt:, --append-system-prompt)         │  process or a rebuild)
│   kit prompt (per toolkit: its kit's prompt: text, only when it has one) │
│   project + system memory indexes                                        │
│                ◄── remote Claude / Messages: cache_control breakpoint #1 │
├──────────────────────────────────────────────────────────────────────────┤
│ SYSTEM, volatile tail (per session, least → most changing)               │
│   Participants: … (only while the session has participants)              │  first joins / last leaves
│   Model: this session runs on …                                          │  another session
│   working directory (location)                                           │  (expected: only
│   session id + log                                                       │  this tail differs)
│   [Gemma 4 native only: tool declarations after all of it]               │
└──────────────────────────────────────────────────────────────────────────┘
 shared by every turn of this session ─────────────────────────────────────
┌──────────────────────────────────────────────────────────────────────────┐
│ history      user / assistant / tool messages, APPEND-ONLY               │  !rollback, a failed or
│              (images: up to the newest N, cut in batches; ImagePlan)     │  cancelled turn's tail,
│                ◄── remote Claude / Messages: breakpoint #2 on the last   │  the image cut moving
│                    non-system message (Messages: its last user block)    │  a batch, history
├──────────────────────────────────────────────────────────────────────────┤  sanitizing (thinking
│ tail notes   reminders, turn notes, steers, the working-set note         │  stripped per spec)
│ new prompt   this turn's user message                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

- The system prompt is built **once per key** and kept (`SystemPrompt#build`, keyed by `[chat, thinking, layers]`:
  the loop, the thinking level, the turn's LLM context layers; a `/thinking` change builds under another key). All
  of them are dropped only on `@prompt_builder.reset!`: a model switch (`Engine#switch_model!`), a plugin's
  `tools_changed!`, a profile change, or a toolkit change (`Engine#apply_toolkit!`). A per-turn rebuild would break
  everything below it.
- The tools layer is shared **per toolkit** (configuration.md, "Toolkits"): sessions on the same toolkit share it,
  and a chain's links keep theirs. A session's toolkit is saved when it is created and never resolved again from
  config. A change (`/toolkit`, `ctx.use_toolkit`) is applied only at a turn's start (`Engine#apply_toolkit!`,
  beside `apply_staged_tools!`, then `reset!`): the chat loop builds `tools:` per request, so a mid-turn change
  would differ from the turn's prompt. Under `full` nothing is filtered and no line is added: the bytes are what
  they were before toolkits.
- A toolkit suggestion (`toolkit.suggest.mode: on`) is set before `apply_toolkit!` of the turn it was asked on
  (`Engine#settle_toolkit_suggestion` → `ToolkitBinding#suggest`), and no request goes out before that, so on a
  session's first turn it costs nothing. Its **deferred switch** (a later prompt after `undecided`, within
  `toolkit.suggest.defer_turns` / `defer_tokens`) is engine-side, so `/toolkit`'s CacheConfirm doesn't apply: it
  changes the declared tools at the front of the request, and the server re-reads **system prompt + tools +
  conversation** on that turn. The defer bound keeps that conversation small; its notice says "from this turn".
  When System 1 runs on the model's own single-slot local server (`Engine#toolkit_judge_shares_local_host?`), any
  ask takes the slot and evicts its cached prefix: a first-turn ask costs that cache even when nothing switches
  (there is little cached on a session's first turn), so on mode asks only there, skips the deferred path, and
  sends no worker warm-up.
- A kit's prompt text (`toolkit.kits.<name>.prompt:`, `chi.toolkit … prompt:`) sits after the appended files and
  before the memory indexes (`SystemPrompt#kit_prompt_section`): one prefix per kit, never per-session text, so
  sessions on the kit share it; a memory write (the indexes after it) doesn't move it. It is part of the
  `Toolkit::Resolved` the Registry holds, so a switch that changes only the text is a toolkit change
  (`apply_toolkit!` → `reset!`). `full` and kits without one send the bytes they sent before.
- find_tools' description is a function of the toolkit and the source groups **at load**: `ToolIndex#declare`
  snapshots source group names and description lines (name, summary, callable count). `ToolIndex#refresh!` (from
  `ToolkitBinding#apply!`) filters that snapshot by the new toolkit and rebuilds the `chi` line from the built-ins
  it reaches; it never consults live group names. The same group filter drives searches, deferred MCP tools and
  whether `find_tools`/`call_tool` are declared (`Registry#index_needed?`). An MCP server that finishes booting
  between load and the first turn changes search answers only, so two sessions on the same toolkit with the same
  MCP cache send the same bytes. Kits that omit `groups:` keep their previous request bytes; switching only
  groups changes the prompt key and asks `/toolkit` to confirm the cache cost once the session has history.
- A worker's `execute` and `task_create` descriptions carry the finish wake's sentence ("if you end your turn before
  it finishes, chi tells you when it does"; `Engine.new(task_finish_notes:)`, set once as the worker builds its
  Engine); the `--no-shared` REPL's, and a worker's under `session.task_wakes: off`, don't. A session that moves
  between the two, or whose worker restarts after `task_wakes` changed, misses the cache once.
- On remote Claude, `LLM::PromptCache.mark` sends the system message as two text parts. The stable part carries
  breakpoint #1, so a **new session** reads it from the cache. The last non-system message carries breakpoint
  #2, so the **next request in the session** reads everything up to it. Mid and tail system messages never take
  a breakpoint. The split point comes from `SystemPrompt#stable_length` via the message's `cache_split:`, which
  never goes on the wire. `PromptCache.mark` keys on the model id (`claude`) and runs only for a remote host's chat
  requests (`OpenAIChat#cache_breakpoints`).
- On a Messages host (`api: anthropic`), `AnthropicWire.translate` sets the same two breakpoints on the translated
  request: the first `system` block (the stable part, when `cache_split:` splits it) and the last user block that
  can carry one (never a thinking block, never one from a mid or tail system message). It doesn't look at the model
  id: every chat request carries them, unless the host's dialect has none (`Dialect#cache_breakpoints`: `fireworks`,
  an automatic prefix cache) or the host refused `cache_control` with a 400 (no breakpoints for that worker's life).
  [anthropic.md](anthropic.md) has the details.
- On a Messages host the tools a session reaches but doesn't declare go in `tools` deferred (`defer_loading`), after
  the declared ones, never marked. Their presence is a flat ~93 tokens of the cached prefix, whatever their number
  or names: a request with none and one with some don't share a prefix (measured 2026-10-22: a full + MCP session
  read nothing of the prefix main's chi had cached, then read its own), but the list may grow mid-session (an MCP
  server's `list_changed`, a tool sorted in mid-list) without a re-read. A find_tools hit's load goes in its own
  tool_result (`tool_reference` blocks) with the text beside it, rendered the same in every later request (a
  loaded name stays deferred, a stub once its source is gone), so the request after a load reads the whole prefix;
  the loaded definitions and the new result are the fresh part. A plugin's
  `ctx.load_tools` only appends (a system `tool_addition` after the user message, never a change to `tools`).
- A user's working-set drop (`/working-set drop`, [working-set.md](working-set.md#steering-drop-and-undrop)) changes
  an earlier entry: it is saved between turns, so the next turn's first request is the first to send the stub and
  the cache breaks there once, from the dropped output's entry on (the command's reply says that tail; an undrop
  after the drop was sent breaks it once more). It is sent under every strategy, so it is the one edit that rewrites
  history under `none`; without a drop, `none` sends the stored Array as it is. Its `working_set` note (what the user
  dropped or brought back) is a tail system message after the history, one per turn with ops, escaped as context
  notes are (`Prompt::ESCAPED_KINDS`). The turn-end warm-up never warms a drop sent after the turn: it misses once.
- **Participants** ([participants.md](participants.md#attribution)). A participant's message carries a wire-only
  header line (`Steer.review_header`), a pure function of the saved message (its `author_name` and its
  `participant_mode` stamp included: a review or a pair header), so a replay sends the same bytes; the owner's
  messages are sent as before (`spec/review_contribution_spec.rb`, per loop and on a Messages host). The
  participants line opens the system prompt's volatile tail, after breakpoint #1: a new session's cache is
  untouched. Its words follow the session's `ParticipantMode` (a review or a working session's line), which never
  changes for a session. The Engine checks the sidecar at each turn's start and rebuilds (`reset!`) only when the
  first participant joins and when the last leaves or expires: one history re-read each, then stable. Under D3(a)
  the declared tools stay the session's, so an author switch costs nothing: the review and pair boundaries are
  gates on the calls, not a toolkit switch. The forged-header mark (`(quoted) `) is a pure function of the text too.
- Side requests (idle recap, `/btw`) go through `IdleClient` with their own short system prompt (the recap's also
  asks for its auto title line, `RecapPrompt::TITLE`: static text, still that one request). On a current
  llama.cpp they don't evict the session (see the server settings below); chi never pins them to a slot.

## The turn-end warm-up

The next turn's prompt differs from the turn's last request at its tail: the previous answer's thinking is
stripped (the models' specs require it). A hybrid model on llama.cpp can only resume from a restore point, so the
next turn prefills from well before the end, more with every turn. `PromptWarmup` moves that work into the time
the user reads: after a completed turn, `Engine#warm_up_next_turn` formats the next prompt up to where the new
user message starts (`KernelLoop#warmup_prompt`) and sends it in a thread (`Client#warm_up`: native
`/completion`, `n_predict: 1`, not streamed, no retries, log purpose `warmup`, then a `model warmup` line with
`cached=`, `prefilled=` and `prefill_ms=`).

- Only on a local llama.cpp host on the native loop, with `cache.warmup: auto` (the default). Never a remote or
  paid host, never the chat loop (Splash keeps its own cache; llama.cpp's chat path is not measured).
- Not after a failed, cancelled or step-limited turn, nor when a reminder is due, a steer is carried or input
  waits (the next turn starts at once), nor in a `--non-interactive` run.
- **Slot rule.** The warm-up runs on the slot the turn's last request used (`id_slot` from its stream). The next
  request is pinned to that slot only while the warm-up still runs, so it queues behind it; once the warm-up is
  done nothing is pinned. Pinning across an idle gap is the one thing that hurts: a pinned request to a slot the
  server has since cleared skips its prompt cache and prefills everything (measured 0.5 s → 12 s). For the same
  reason `id_slot` is a reserved sampling key.
- What breaks it (the warm-up simply misses): a system-prompt rebuild (`/thinking`, `/model`, a tool change),
  the image cut moving a batch, `!rollback`.

## The image window

A request sends at most `image.max_per_request` images (20 by default); older ones become placeholder lines
(`[image a.png 1280×800 not sent: an older image (chi sends up to the newest 20)]`). If the window slid by one
image per new image, every new image would turn the oldest sent one into a placeholder and rewrite history from
there. So the cut is a pure function of the image count (`ImagePlan.dropped_count`): nothing is dropped up to
the limit, then the oldest in whole steps of half the limit (21–30 images drop 10, 31–40 drop 20). Between two
step boundaries the earlier messages stay byte-identical; at a boundary the history from the newly cut image on
is prefilled once. The native and the chat loop use the same plan.

## Remote caches: TTL and routing

- **TTL.** Anthropic keeps a breakpoint 5 minutes after its last read; a session the user comes back to later
  writes its prompt again. `cache.ttl: 1h` sends `cache_control: {type: "ephemeral", ttl: "1h"}` on both
  breakpoints (the log line shows `cache=1h`). Off by default: a 1h write costs 2× the input price, a 5m write
  1.25×, a read 0.1× either way, so 1h pays off only when pauses of 5–60 minutes are common.
- **Routing.** Every chat request carries a `Session-Id` header, which OpenRouter uses to keep a conversation on
  one provider. `cache.key: session` also sends the session id as `prompt_cache_key` in the body, the field
  OpenAI's API routes and caches by (OpenRouter honours it too); the log line shows `cache_by=session`. Only
  `api.openai.com` and OpenRouter get it, and only the session's own chat requests (not recap or `/btw`): a local
  llama.cpp, Splash or another gateway may reject an unknown field. Off by default. A Messages host never gets
  `prompt_cache_key` (`AnthropicMessages::DROPPED_OPTIONS`); its dialect may add a header of its own beside
  `Session-Id` (`Dialect#session_header`: `x-session-affinity` under `dialect: fireworks`, which keeps a session on
  the replica that has its cache).

## Reading the numbers

- The debug log's `generation_completed` line: `prompt=` (the request's prompt tokens), `cached=` (read from the
  server's cache), `cache_write=` (written to it, where the provider reports writes) and `reprefill=` (of the last
  request's prompt on the same model through the same host, what was prefilled again; a `/model` to the same bare
  model on another host is the switch's prefill, not a re-prefill). The `http` line of a
  remote Claude or Messages request shows `cache=on` (or `cache=1h`) when it carried breakpoints.
- The warm-up logs `model warmup` with `cached=`, `prefilled=` and `prefill_ms=`.
- `/stats`: "cached N (P%)", "cache writes" and "re-prefilled" for the session.
- A healthy session: from the second request on `cached=` is close to `prompt=`; a second fresh session in the
  same project reads everything up to the volatile tail.

## Rules for changes

1. **Stable first, volatile last.** Anything that differs between sessions or turns (ids, paths, times, the
   model line, counters) goes at the very end of the system prompt, ordered by how often it changes. Never put
   a per-session value in the stable part. A guard spec checks that model, location and session are the last
   sections (`spec/system_prompt_model_spec.rb`).
2. **History is append-only.** Never rewrite an earlier message. Add a note at the tail instead. If a model's
   spec forces a rewrite (e.g. stripping previous-turn thinking), accept the re-prefill and note it. Within a
   turn both loops keep the turn's replies as sent across a mid-turn steer, a plugin's nudge and a Continue's text
   (`ReasoningHistory.run_start` fixes where the run's reasoning starts), so the request after a steer is the one
   before plus the steer; a new turn drops the previous turn's reasoning under `turn` (one re-prefill from its
   first reply, on a server that renders it; a stock Qwen template without `preserve_thinking` re-renders from the
   reply before every user message whatever chi sends). A worker's
   mid-turn checkpoint (`TurnCheckpoint`) is append-only too (the history plus what the loop appended) and
   never changes the request bytes. On Messages with Claude 5.x a change to the prefix (the system prompt, the
   tools, an earlier message) also costs the thinking blocks after it: one 400, then chi drops them for good
   (internals/anthropic.md, "Preserved thinking").
3. **Deterministic order.** Tools, memory lists and anything else that's rendered from a hash or a set needs a
   fixed sort. Plugin tools are sorted by (bundle, name) whatever order their plugins finished starting in
   (R5a).
4. **Don't rebuild the system prompt per turn.** Rebuild only when its content really changed (`reset!`).
5. **Measure.** Every generation logs `prompt=`, `cached=` and, where the provider reports it, `cache_write=`
   on its `generation_completed` log line. `/stats` shows "cached N (P%)" and "cache writes". A change that
   drops `cached=` on the second fresh session is a regression. Update the prompt snapshot fixtures with
   `UPDATE_PROMPTS=1` and read the diff: a cache-friendly change moves sections, it doesn't reorder per run.
6. **Ask before a setting change that restarts the cache.** A session setting whose change makes the server read
   the conversation again asks a person at a web tab or a TUI first (`CacheConfirm`: the reply carries the
   `--yes` line, `SessionCommands::Result#confirm` and the `command_ran` event's `confirm`). Each setting has a
   classifier: `Thinking.cache_cost` (`:full` for Gemma, `:provider` for a remote chat host, `:tail` otherwise) and
   `ReasoningHistory.cache_cost` (`:history` for a change to or from `all` once an earlier reply has thinking).
   `CacheConfirm.needed?` asks only for `:full`, `:provider` and `:history`, when the effective level changes and
   the session has a model reply. The confirmation estimates the reread size from the latest known context count:
   the whole conversation for `:full` / `:provider`, or up to the first changed reply for `:history`; it omits the
   estimate when no count is known. On `api: anthropic`, a `:full` / `:provider` change also warns that preserved
   thinking in replies is dropped from then on. A new setting with a cost (a `/model` across templates,
   `/llm-context` turning forget on) adds its classifier and goes through the same step.
7. **No wall-clock time rendered at wire time.** A history entry's `at` (`MessageTime::KEY`, when it happened) is
   display-only: no wire format reads it, and a guard spec checks that `ChatLoop#wire_messages` and
   `Prompt.format_with_images` give the same bytes with and without it (`spec/message_time_history_spec.rb`). A
   time the model should read is baked into the message's content when the message is made (a context note's
   frame, the reminders' header), so a replay sends the same bytes whatever the time zone or DST.

## Server-side settings worth knowing

- **Splash:** `--persistent-cache` (with `--max-cache-disk`) keeps restore points across restarts. Splash learns
  a new branch point on the 2nd session, so the 3rd one gets the full reuse.
- **llama.cpp:** `--cache-ram` (the host-memory prompt cache, 8 GiB by default in recent builds) is what keeps
  sessions apart: when a task starts on a slot, the idle slots' state goes to that cache, and an unpinned request
  restores the best match on whatever slot it gets. So a recap or another session between two turns costs
  nothing (measured on Ornith: the next turn still reuses 11.9k of 12.3k tokens). Raise it for many or long
  sessions (roughly 0.25–0.3 GB per 12k-token Ornith session). `--parallel` matters little; pinning a request to
  a slot (`id_slot`) is the hazard. With `--cache-ram 0` or an old single-slot build, a recap does evict the
  session. `--ctx-checkpoints` controls how many restore points a hybrid model keeps. chi sends
  `cache_prompt: true` on every native request.
- **OpenRouter / Anthropic:** the default cache TTL is 5 minutes (`cache.ttl: 1h` for an hour, see above).
  Provider routing (which upstream serves a request) also decides whether a cache is there to hit.
