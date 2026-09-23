# Memory

Samagotchi stores memories in two scopes:

- Project scope: `~/.config/samagotchi/memories/projects/<name>_<hash>/`, one folder per
  git repository (named and hashed by its root), shared by all its worktrees and
  subdirectories; outside a repository, one per working directory
- System scope: `~/.config/samagotchi/memories`

Tool behavior:

- `memory_read`: `scope` is optional.
- If `scope` is provided (`project` or `system`), only that scope is read.
- If `scope` is omitted, read falls back from project to system.
- `memory_write`: `scope` is required (`project` or `system`). The entry name is passed via the `name` parameter (not `path` — the file tools use `path`). On success, the return value includes the full file path, so you can use the `edit` tool directly for targeted updates.

## Model-Specific Memory Overlays

Each memory entry may have a companion file named `<name>.<model-key>.md` in the same scope directory. When the entry is read under a matching model, the overlay body is appended automatically, separated by the standard `---` separator with a `Model-specific guidance (<key>):` header.

- **Key derivation**: The harness normalizes the full model name (lowercase, replace non-alphanumeric with `-`, squeeze dashes) to derive the file key. For example, `qwen3.6-35b-a3b` → `qwen3-6-35b-a3b`.
- **Saving overlays**: Pass `current_model_only: true` to `memory_write` (the harness resolves the model key automatically). This writes the content as `<name>.<model-key>.md` and skips index maintenance.
- **Dormancy**: Overlays are only active under the matching model key; other models see the base entry only.
- **Invariant**: The base entry is the contract. Overlays only add model-specific guidance and never contradict the base protocol.


At startup, the agent reads both scope indexes with blank-name memory reads
and injects them into the system prompt as `Project memories` and
`System memories`.

These startup index reads are harness-injected context assembly and are not
rendered as `tool>` activity lines.
