# Hooks

Samagotchi supports pluggable Ruby hooks that fire at key lifecycle points
during agent turns. Hooks let you add external tooling (CI checks, logging,
analytics) or in-process verification (test gates, policy checks).

## Configuration

Add a `hooks:` section to your global config file (`~/.config/samagotchi/config.yml`):

```yaml
hooks:
  hooks_dir: "~/.config/samagotchi/hooks/"
  session_start:
    - path: "analytics.rb"
      on_error: log
  before_turn:
    - path: "audit.rb"
      on_error: skip
  after_tool_call:
    - path: "metrics.rb"
      on_error: skip
```

## Plugin Format

Each plugin is a `.rb` file in the hooks directory. The class name must match
the filename (snake_case → PascalCase):

```ruby
# ~/.config/samagotchi/hooks/metrics.rb
class Metrics
  def call(event)
    # event is a Hash — you can read or mutate fields
    tool = event[:tool]
    output = event[:output]
    # ... record metrics, log, etc.
  end
end
```

The plugin class must respond to `#call(event)` — duck-typed, no base class required.

## Hook Events

| Event | When it fires | Event payload |
|-------|--------------|---------------|
| `:session_start` | First turn of the session | `{ type: :session_start, session_id: "..." }` |
| `:before_turn` | Before each turn starts | `{ type: :before_turn }` |
| `:after_turn` | After each turn completes | `{ type: :after_turn }` |
| `:before_generation` | Before LLM API call | `{ type: :before_generation, iteration: N }` |
| `:after_generation` | After LLM returns | `{ type: :after_generation, iteration: N, response: "..." }` |
| `:before_tool_call` | Before tool dispatch | `{ type: :before_tool_call, iteration: N, call: {...}, params: {...} }` |
| `:after_tool_call` | After tool execution | `{ type: :after_tool_call, iteration: N, tool: "read", output: "..." }` |
| `:session_end` | After every turn (turn-level lifecycle) | `{ type: :session_end, session_id: "..." }` |

## Error Handling

- `on_error: "skip"` (default): silently ignore hook failures
- `on_error: "log"`: emit a `warn` message to stderr

Hook failures never break the engine loop — each hook is wrapped in its own
try/catch.

## Runtime Hook Registration

You can also register hooks programmatically during a turn (they are cleared
automatically after each `run_turn`):

```ruby
engine = Samagotchi::Engine.new(mode: :assist)
engine.register_hook(:before_turn) do |event|
  puts "Turn starting..."
end
engine.run_turn(session, "Hello")
# Hooks cleared automatically — won't fire on the next turn
```

## Example Plugins

**Logging every tool call:**

```ruby
# ~/.config/samagotchi/hooks/audit.rb
class Audit
  def call(event)
    return unless event[:type] == :after_tool_call
    puts "[audit] #{event[:tool]} → #{event[:output][0..100]}"
  end
end
```

**Tracking tool call counts:**

```ruby
# ~/.config/samagotchi/hooks/tool_counter.rb
class ToolCounter
  def initialize
    @counts = Hash.new(0)
    @mutex = Mutex.new
  end

  def call(event)
    return unless event[:type] == :after_tool_call
    @mutex.synchronize { @counts[event[:tool]] += 1 }
  end

  def report
    @mutex.synchronize { @counts.dup }
  end
end
```

**Blocking tool calls with a guardrail (veto):**

```ruby
# ~/.config/samagotchi/hooks/safety.rb
class Safety
  def call(event)
    return unless event[:type] == :before_tool_call
    tool = event[:call][:name]
    if tool == "execute" && event[:call][:content]&.include?("rm -rf /")
      event[:blocked] = true
      event[:block_reason] = "dangerous command denied by policy"
    end
  end
end
```

When `event[:blocked] = true`, the tool is not dispatched. The model receives `Error: blocked by guardrail: <reason>` as the tool output (with `block_reason` or default `blocked by hook`), activity status is `blocked`, and `:after_tool_call` still fires. Only `:before_tool_call` supports veto — `blocked` is ignored on other hooks.

**Mutating params (legacy):**

```ruby
# ~/.config/samagotchi/hooks/safety_legacy.rb
class SafetyLegacy
  def call(event)
    return unless event[:type] == :before_tool_call
    tool = event[:call][:name]
    if tool == "execute" && event[:call][:content]&.include?("rm -rf /")
      event[:call][:content] = "echo 'Safety check: dangerous command blocked'"
    end
  end
end
```

Note: `:before_tool_call` can mutate the `:call` hash to modify tool execution, or set `blocked`/`block_reason` to veto it entirely.

## Bundle Hooks (unified workflow bundle)

Bundles can ship executable guardrails alongside memories. A bundle with hooks lives as a directory with a `hooks/` subdirectory (flat, basename-keyed):

```
my-bundle/
  manifest.yml
  identity.md
  hooks/
    guardrails.rb   # class Guardrails; def call(event); ...; end; end
    audit.rb
```

`manifest.yml` may carry an optional `hooks:` map (both `files:` and `hooks:` are optional; a bundle may carry only one):

```yaml
name: code-review-workflow
version: 1.0.0
scope: project
files:
  identity.md: sha256:abc...
hooks:
  guardrails.rb:
    sha256: 1234...
    event: before_tool_call
    on_error: fail_closed   # default for before_tool_call
    priority: 10
  audit.rb:
    sha256: 5678...
    event: after_tool_call
    on_error: log
    priority: 100
trust_level: reviewed        # reviewed | experimental (default)
```

Notes:

- Hook key = basename (flat under `hooks/`). No subdirs in v1.
- `event` is required for auto-registration; a hook with no event is skipped.
- `sha256` is integrity (not authenticity). No signing in v1.
- Hook code is the bundle author's source of truth: on upgrade, hooks are overwritten; if the installed file was locally modified, a warning is emitted (`was locally modified; overwriting`).
- A raising `:before_tool_call` guardrail respects `on_error`: `fail_closed` sets `event[:blocked]=true` (fail-closed), `log` warns, `skip` is silent.
- Ordering: bundle hooks fire by `(priority, bundle_name, hook_name)` (lower priority first), then plain `config.yml` hooks in registration order.
- Installing a bundle executes its hook code at `Engine` startup. Only install bundles you trust, as you would a gem. Hooks are **not** executed at install time (copy-only); they are `module_eval`'d at `Engine.new` inside per-bundle `Samagotchi::Bundles::<name>` namespaces (no top-level `require` collisions). Keep hook files side-effect-free at load time; do work in `#call` — top-level side effects (require, IO, `at_exit`, global assignment) run once per `Engine.new` (class redefinition is idempotent).

Lifecycle:

- `bin/chi bundle install <source>` copies `hooks/*.rb` to `~/.config/samagotchi/memories/.bundles/<name>/hooks/` and persists metadata + `trust_level` + `source_commit` (git HEAD) to provenance.
- `Engine.new` loads `config.yml` hooks first, then bundle hooks via `Provenance.each_installed_holding_hooks` → `Hooks::BundleLoader.load`. Bundle hooks are process-scoped (they survive the per-turn `clear_hooks`; only plain hooks are cleared). Experimental bundles emit a one-line startup warning.
- `bin/chi bundle status`, `diff`, `uninstall`, `build` are hook-aware (counts, metadata, removal).
