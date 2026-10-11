# Gemma 4 behavior contract

This project uses canonical Gemma 4 tool-call parsing and explicit thought-context handling.

## Canonical Tool Calls Only

The kernel loop accepts canonical calls in this format:

`<|tool_call>call:NAME{...}<tool_call|>`

XML tool tags and declaration-echo parsing are intentionally not supported.

## Thought Context Rules

Thought handling follows the Gemma guidance:

- Include `<|think|>` in the system instruction to activate thinking mode.
- When thinking mode is active, the model may emit internal reasoning as `<|channel>thought ... <channel|>`.
- Standard multi-turn: prior model thoughts are stripped from conversation history before the next turn.
- Function/tool-calling exception: during a single turn that includes tool calls, thoughts are not stripped between those tool-call rounds.
- A step-limit Continue is that same turn going on: the run it resumes keeps its thoughts (`KernelLoop#run`'s `reasoning_since:`, from the Engine's `resume_from`), from its start, a steer merged inside that run included (nothing re-sanitizes within a run, so the prompt before the limit had them); only a user entry added after the run's last reply (a `!cmd`'s output) starts them past itself. Every other turn (a prompt, a reminder, a wake) strips them as above.
- Final model output returned to the caller is thought-stripped.
- While a generation streams, the thought channel goes to the stream's `thinking:` lane, not `text:` (`ThoughtStreamSplitter.for_profile`, fresh per generation), so the UIs show it as thinking and `:generation_progress` hooks count it in `thinking_chars`.

In short, raw thought blocks are treated as in-turn transient context, not durable history.
