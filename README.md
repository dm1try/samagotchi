# samagotchi
self evolving agent harness

## Project specific description

If an AGENT.md file is present in the project root, samagotchi injects its
contents into the system prompt under a "Project specific description:" section.

To skip loading AGENT.md, set:

`SAMAGOTCHI_SKIP_AGENT_MD=true`

## Gemma 4 Behavior Contract

This project uses canonical Gemma 4 tool-call parsing and explicit thought-context handling.

### Canonical Tool Calls Only

The kernel loop accepts canonical calls in this format:

`<|tool_call>call:NAME{...}<tool_call|>`

Backward-compatibility formats (legacy thought tags, XML tool tags, declaration-echo parsing) are intentionally not supported.

### Thought Context Rules

Thought handling follows the Gemma guidance:

- Standard multi-turn: prior model thoughts are stripped from conversation history before the next turn.
- Function/tool-calling exception: during a single turn that includes tool calls, thoughts are not stripped between those tool-call rounds.
- Final model output returned to the caller is thought-stripped.

In short, raw thought blocks are treated as in-turn transient context, not durable history.
