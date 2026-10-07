# Prompt caching: how a request is laid out, and how to keep it cache-friendly

A model server reuses work only for the **exact token prefix** it has already seen. Change one token and
everything after it is computed again (prefill). The local models we run (hybrid Qwen 3.6 / Ornith on llama.cpp
and Splash) can only resume from a **restore point near the end** of an earlier prompt, not from any shared
prefix. Anthropic (Claude via OpenRouter) caches only up to an explicit `cache_control` breakpoint. So the order
of what chi sends decides what a new turn, or a new session, has to pay for.

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
│ tools        built-ins, then plugin tools sorted by (bundle, name)       │  a tool added/changed,
│              (chat: the `tools` field; native: the model's template)     │  /model, a profile change
├──────────────────────────────────────────────────────────────────────────┤
│ SYSTEM, stable part                         SystemPrompt#system_prompt_with_index
│   [native thinking token] base prompt                                    │
│   rg guidance                                                            │  /thinking level,
│   system identity (+ model overlay)                                      │  /model, editing a
│   model notes (model_notes_* matching the model)                         │  memory / AGENT.md
│   explicit (preloaded) memories                                          │
│   AGENT.md                                                               │  (picked up by a new
│   project + system memory indexes                                        │  process or a rebuild)
│                         ◄── remote Claude: cache_control breakpoint #1   │
├──────────────────────────────────────────────────────────────────────────┤
│ SYSTEM, volatile tail (per session, least → most changing)               │
│   Model: this session runs on …                                          │  another session
│   working directory (location)                                           │  (expected: only
│   session id + log                                                       │  this tail differs)
│   [Gemma 4 native only: tool declarations after all of it]               │
└──────────────────────────────────────────────────────────────────────────┘
 shared by every turn of this session ─────────────────────────────────────
┌──────────────────────────────────────────────────────────────────────────┐
│ history      user / assistant / tool messages, APPEND-ONLY               │  !rollback, a failed or
│              (images: up to the newest N, cut in batches; ImagePlan)     │  cancelled turn's tail,
│                         ◄── remote Claude: breakpoint #2 on the last     │  the image cut moving
│                             non-system message                           │  a batch, history
├──────────────────────────────────────────────────────────────────────────┤  sanitizing (thinking
│ tail notes   reminders, turn notes, steers (system/user messages)        │  stripped per spec)
│ new prompt   this turn's user message                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

- The system prompt is built **once per loop** and rebuilt only on `@prompt_builder.reset!`: a model switch
  (`Engine#switch_model!`), a plugin's `tools_changed!`, or a profile change. A per-turn rebuild would
  break everything below it.
- On remote Claude, `LLM::PromptCache.mark` sends the system message as two text parts. The stable part carries
  breakpoint #1, so a **new session** reads it from the cache. The last non-system message carries breakpoint
  #2, so the **next request in the session** reads everything up to it. Mid and tail system messages never take
  a breakpoint. The split point comes from `SystemPrompt#stable_length` via the message's `cache_split:`, which
  never goes on the wire.
- Side requests (idle recap, `/btw`) go through `IdleClient` with their own short system prompt. On a current
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
  llama.cpp, Splash or another gateway may reject an unknown field. Off by default.

## Reading the numbers

- The debug log's `generation_completed` line: `prompt=` (the request's prompt tokens), `cached=` (read from the
  server's cache), `cache_write=` (written to it, where the provider reports writes) and `reprefill=` (of the last
  request's prompt on the same model, what was prefilled again). The `http` line of a
  remote Claude request shows `cache=on` (or `cache=1h`) when it carried breakpoints.
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
   spec forces a rewrite (e.g. stripping previous-turn thinking), accept the re-prefill and note it.
3. **Deterministic order.** Tools, memory lists and anything else that's rendered from a hash or a set needs a
   fixed sort. Plugin tools are sorted by (bundle, name) whatever order their plugins finished starting in
   (R5a).
4. **Don't rebuild the system prompt per turn.** Rebuild only when its content really changed (`reset!`).
5. **Measure.** Every generation logs `prompt=`, `cached=` and, where the provider reports it, `cache_write=`
   on its `generation_completed` log line. `/stats` shows "cached N (P%)" and "cache writes". A change that
   drops `cached=` on the second fresh session is a regression. Update the prompt snapshot fixtures with
   `UPDATE_PROMPTS=1` and read the diff: a cache-friendly change moves sections, it doesn't reorder per run.

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

