# The llm_context replay benchmark

`script/llm_context_bench.rb` replays stored chi sessions offline and reports what an LLM context strategy
(`llm_context.strategy`) would have changed in them. Every strategy or policy change gets a number from it before it
becomes a default. It is a development tool: it lives under `script/`, isn't shipped with the gem, and no spec runs
it on real sessions (the specs use small synthetic ones).

```sh
ruby script/llm_context_bench.rb [SESSIONS_DIR] [options]     # --help lists the options
```

`SESSIONS_DIR` is a folder of `<session id>.json` files: an argument, else `$LLM_CONTEXT_BENCH_SESSIONS`, else chi's
own (`~/.local/state/samagotchi/sessions`). The benchmark only reads it. Sessions with fewer than two turns are
skipped; `--top N` keeps the N heaviest, `--session PREFIX` picks some.

It measures what chi would send: sessions load through `Session.from_h`, a native batch's joined result splits into
its runs as `LLMContextView` splits it (calls read by chi's `ToolCallParser`), every output is named by its
`ToolIds` id, and a strategy's edits are saved as `LLMContextEdit` records on copies of the entries and rendered
through `LLMContextView`. Tokens are chars/4 throughout, which undercounts code-heavy prompts by about 1.25x.

## What it reports

**The profile (none, every session):** the resent tokens by category (tool outputs, call arguments, the system
prompt, prose, user messages, context notes, a native session's inline thinking; stored thinking apart, since chi
never resends it), tool outputs by tool and size, turns, how much of a turn's output a later turn refers to, and
repeat reads.

**A row per strategy × model × policy**, summed over the cases. A case is the end of a turn that has a next turn,
scored at the next turn's first request. Cases are named `<first 8 of the session id>_t<turn>`; they come from a
`--cases FILE` (one name per line), else from the picks given, else every turn with at least `--min-turn-tool`
(3000) tokens of its own tool output.

| Column | Meaning |
|---|---|
| forgot/outputs | outputs the strategy edits / outputs in context at the case |
| freed/tool | what the prompt loses, stubs counted / the tool output tokens in context |
| wrong strict (base) | edited outputs a later step needs: from the step the edit reaches through the end of the next turn, a call re-reads the file or re-runs the command. In brackets the base rate: the share of all outputs in context that are needed, what a random pick scores |
| wrong loose (base) | the same, counting a mention of the output's path or of an identifier it brought in |
| 1-step | edited outputs the step the edit reaches re-reads or re-runs. Offline that step is the session's own, made without the stub, so it is a floor, not the stub's effect |
| re-prefilled | what the server prefills again because an edit broke its prompt cache: from the earliest changed entry to the end of what the previous request left cached |

The proxies are the context-edit spike's (lexical and lenient: a basename mention counts).

## Strategies

- `none`: nothing changes. The base.
- `forget_all`: at the turn's end, forget every output in context with an empty note. The spike's base rate; about
  what a model told "free context now" does.
- `stale` (P2) and `forget_outputs` (P4): slots. They print "not built yet" until their phase adds them to
  `LLMContextBench::Strategies`; a strategy answers `#plans(kase)` with `Plan`s of `PlannedEdit`s (the output id, the
  edit kind, the note, the request it first reaches), and the scorer and the report take it as is.
- `--picks LABEL=DIR`: model picks recorded as responses, one file per pick, `<case>.<variant>.json` (the spike's
  `out/<model>/` files, or what `--live` saves). The variant is the row's policy, the label its model.

```sh
ruby script/llm_context_bench.rb "$SESSIONS" --strategy none,forget_all --per-case
ruby script/llm_context_bench.rb "$SESSIONS" --picks deepseek=picks/deepseek --picks splash=picks/splash --json
```

## Live picks (the D7 tool-name A/B)

The one part that calls a model, and only with `--live MODEL`: at each case it asks the model which of its tool
outputs to forget, through chi's own chat client (the model must be on an `api: openai` host), and saves each
answer under `--out DIR` for `--picks` to score. A saved pick is never asked for again. The request is the
session's conversation up to the turn's end (thinking dropped, every tool result led by its id `[#tN]`), chi's
built-in chat tools plus the forget tool, and the policy's tail line; a model that doesn't call the tool is asked
once more with it forced.

- `--tool-name forget_outputs|forget_llm_context`: the name under test; the description stays the same.
- `--policy subtask|soft|now`: `subtask` offers the tool and puts the plan's policy line in its description;
  `soft` and `now` are the spike's selective and "free context now" lines.
- `--samples N`, and `--dry-run` to count the requests and prompt tokens without calling anything.

```sh
ruby script/llm_context_bench.rb "$SESSIONS" --cases cases.txt --live openrouter:deepseek/deepseek-v4.1-flash \
  --tool-name forget_llm_context --policy subtask --out picks/deepseek --dry-run
```
