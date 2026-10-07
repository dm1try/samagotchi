# The forget layer: forget_outputs

`llm_context.strategy` with `forget` (experimental; user docs: configuration.md, "LLM context: the forget layer")
lets the model forget its own tool outputs. The pieces:

- **The tool list is per turn.** `Tools::Registry` entries may name an LLM context layer (`layer: :forget`);
  `#entries/#names/#schemas(layers:)` and `#offered(name, layers:)` leave a gated tool out unless the turn runs under
  its layer. The turn's layers are `LLMContextStrategy::Resolved#active_layers` (`[]` under none): the native system
  prompt declares them (`SystemPrompt#build(layers:)`, `Engine#system_prompt` resolving the target's strategy), the
  chat loop sends them (`ChatLoop#tool_definitions`), the kernel dispatches and lists them (`KernelLoop#dispatch`).
  Under none and `[stale]` the tool list, the system prompt and the wire requests are what they were. A model switch
  that changes the layers changes the tool list; it breaks the prompt cache anyway.
- **Ids** (`LLMContextView`, plan D2): with `:forget` among the view's layers every output with a stored id
  (`ToolIds`, `tool_ids` on the entry) is sent as `[name]` lead, then `[#tN] `, then its text; derived ids of legacy
  entries are never shown or forgettable.
- **The schema** is `ToolDeclarations.forget_outputs_schema(policy:)` (not in `TOOL_SCHEMAS`, which every turn
  declares; `BUILTIN_SCHEMAS` adds it for `BuiltinCalls`). Its description (about 330 tokens by chars/4, 515 with the
  parameters) carries the spike's refined text, `llm_context.policy` (read when the Engine builds its registry), the
  note contract and the cost lesson. Parameters: `ids`, `note`, `keep` (`"t42:12-40"`: forget t42 except
  those lines; a read's are file lines, kept with the edit's `keep_offset`, start_line - 1), `restore`, none required
  (a restore needs no note); `Tools::ForgetOutputs.parse` reads ids and ranges from lists, JSON strings or words.
- **The call** (`KernelLoop#forget_outputs`, through the handler's kctx as ask_user_question does) runs
  `LLMContextForget.call` on the running turn (`KernelLoop#llm_context_turn`, a `LLMContextForget::Turn` of the
  turn's conversation and ContextStatus that both loops set as a turn starts). It names only outputs that pair with
  their calls for sure (`LLMContextStale.paired_runs`: by tool_call_id, or a joined entry's runs by their calls'
  `[name]` leads); the view shows ids only on those. The conversation's last step is the forget's own (both loops
  add the model's entry before its calls run). Per id it refuses (with the reason in the result): an output of the
  `protect_steps` steps before that one; a read `LLMContextStale.protected_ids` names (a file edited or written in
  those steps, counted with the forget's own: `protect_steps + 1`) unless the forget keeps lines of it; a keep
  outside the output's lines, of a preview, or holding all of it; an output of `SMALL` (80) chars or less; an output
  with an edit already; an unknown id. What passes is saved as a staged `LLMContextEdit` of kind `:forget` (`by:
  "model"`, the note, `keep`), and the apply rule runs at once as at a request (`KernelLoop#apply_llm_context!`), so
  the result can say whether the batch goes with the next request or waits for the turn's end. `LLMContextApply`'s
  protect_steps hold covers stale's stubs only: a forget was checked when it was made.
- **Restore** takes the forget off the entry (`LLMContextEdit.remove`, a new edits Hash); the next request sends the
  output again, outside the apply rule (the result says the tail the server reads again, and `ContextStatus#edited!`
  restarts the estimate). A read whose stub was sent isn't restored; a staged one is.
- **Stubs** (`LLMContextView`): `(forgotten) <note>` on the first output of a call's forgets in a row, `(forgotten
  with tN: see its note)` on the rest (a run of the same note, author and stamp, no other output between them),
  ` [restore: tN]` on a non-read with a stored id, then each kept range under `lines A-B kept:`. The entry keeps its
  role, tool_call_id and images bookkeeping as for stale.
- **Offers**: `ContextStatus` (internals/context-telemetry.md).
- **Persistence**: the edits ride on the entries (plan D3), so `--resume`, rollbacks and forks keep the stubs and the
  restores; `/stats` counts each applied batch's re-prefill.
- **Measuring**: the bench's `forget_outputs` strategy (internals/llm-context-bench.md).
