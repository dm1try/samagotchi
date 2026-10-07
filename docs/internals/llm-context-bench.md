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

Each case says how its turn ends: `answer` (the model's final prose, no calls), `tool_result` (it stopped mid-task on
a tool's output), `turn_note` (chi's note on a turn that ended without an answer), `tool_call` (calls never
answered) or `empty`. The report's second line tallies them, `--per-case` has an `ends` column, and the JSON has
`case_ends` (name => ending) and `ends` on each case. `--ends answer|any` picks which turns make cases: by default the
turn-size rule keeps only `answer` ends, the point where a forget-at-turn-end offer would come (the layout check
found a model behaves differently mid-task), and named cases (`--cases`, picks) are kept as named. `--ends answer`
drops named cases that end otherwise and says how many; `--ends any` takes every turn.

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
- `stale`: chi's own stale layer (`Samagotchi::LLMContextStale`) as chi runs it: each read a later read covering its
  lines superseded is stubbed from the request after that read (chi applies it at the next request), so a case's
  numbers count every stub since the session began. An edit or write of the file supersedes nothing, nor does a read
  that came back as a preview or cut. A relative
  path is taken against the session's working directory.
- `forget_outputs` (P4): a slot. It prints "not built yet" until its phase adds it to
  `LLMContextBench::Strategies`; a strategy answers `#plans(kase)` with `Plan`s of `PlannedEdit`s (the output id, the
  edit kind, the note, the request it first reaches), and the scorer and the report take it as is.
- `--picks LABEL=DIR`: model picks recorded as responses, one file per pick, `<case>.<variant>.json` (the spike's
  `out/<model>/` files, or what `--live` saves). The variant is the row's policy, the label its model.

```sh
ruby script/llm_context_bench.rb "$SESSIONS" --strategy none,forget_all,stale --per-case
ruby script/llm_context_bench.rb "$SESSIONS" --picks deepseek=picks/deepseek --picks splash=picks/splash --json
```

## Live picks (the D7 tool-name A/B)

The one part that calls a model, and only with `--live MODEL`: at each case it asks the model which of its tool
outputs to forget, through chi's own chat client (the model must be on an `api: openai` host), and saves each
answer under `--out DIR` for `--picks` to score. A saved pick is never asked for again. The request is the
session's conversation up to the turn's end (thinking dropped, every tool result led by its id `[#tN]`), chi's
built-in chat tools plus the forget tool, and the policy's tail line; a model that doesn't call the tool is asked
once more with it forced (`--no-force` asks once).

A pick record holds the answer (`unforced`), the forced one when it took that (`forced`) and why it was forced
(`forced_because`: `no_call`, or `length` when the unforced reply was cut off at `max_tokens`, finish reason
`length`, before it could call anything), how it was asked (`bench`), and `cost`: what the server reported for the
pick's requests, summed (OpenRouter's `usage.cost`, asked for with `usage.include`; absent when the server sends
none). The run's last line counts the picks written, the forced ones, those forced after a cut, the errors, and sums
the cost.

A request that fails is saved as an error record and the run goes on to the next case, except a payment error: a
402, or an error that mentions credits or balance, stops the run at once (exit 1), saves nothing for that case, and
says how many picks it wrote before it. A rerun with the same `--out` asks only for the rest.

- `--tool-name forget_outputs|forget_llm_context`: the name under test; the description stays the same.
- `--policy subtask|soft|now`: `subtask` offers the tool and puts the plan's policy line in its description;
  `soft` and `now` are the spike's selective and "free context now" lines.
- `--layout tail_system|tail_user|boundary`: where the tail line goes. `tail_system` (the default) is a system
  message after the case's last entry; `tail_user` the same line as a user message; `boundary` a system message
  worded as a stopping point. A layout other than the default names its picks `<policy>_<layout>`.
- `--samples N`, and `--dry-run` to count the requests and prompt tokens (and the cases' endings) without calling
  anything.

Case selection matters here: at a turn that ends with the model's answer the forget offer reads as a real turn end,
while mid-task (a `tool_result` or `turn_note` end) a model mostly carries on with the task, or, worded as a
stopping point, forgets at the base rate. A forget-at-turn-end test should run on `answer` cases, the default for
the turn-size rule; give `--ends answer` with a `--cases` file to hold one to that too.

```sh
ruby script/llm_context_bench.rb "$SESSIONS" --cases cases.txt --live openrouter:deepseek/deepseek-v4.1-flash \
  --tool-name forget_llm_context --policy subtask --out picks/deepseek --dry-run
```
