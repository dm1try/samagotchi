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
| `:before_turn` | Before each turn starts | `{ type: :before_turn, session_id: "...", prompt: "..." (nil on a continue), messages: [...] (the history before this turn) }` |
| `:after_turn` | After a turn completed or was cancelled (not after one that failed) | `{ type: :after_turn, status: "completed" \| "canceled", messages: [...] (the conversation the turn stored; a cancelled or empty turn ends it with a `kind: turn_note` system message, see [sessions.md](sessions.md#notes-a-turn-leaves-for-the-model)) }` |
| `:before_generation` | Before each LLM API call (both loops) | `{ type: :before_generation, iteration: N }` |
| `:after_generation` | After LLM returns (both loops) | `{ type: :after_generation, iteration: N, response: "...", messages: [...] (the conversation as sent) }` |
| `:before_tool_call` | Before tool dispatch (and before `tool_call_started`) | `{ type: :before_tool_call, iteration: N, call: {...}, params: "...", guardrail: Verdict, context: {...}, targets: {...}, blocked: false, block_reason: nil }` |
| `:after_tool_call` | After tool execution | `{ type: :after_tool_call, iteration: N, tool: "read", output: "..." }` |
| `:session_end` | After every turn (turn-level lifecycle) | `{ type: :session_end, session_id: "..." }` |

Every event also carries the hook runtime (next section): `hook:` (the label
of the hook about to run) and the callables `notify:`, `ask_user:`,
`stop_turn:`.

`messages:` is a **read-only copy**: a frozen array of copied message hashes
(`{role:, content:, …}`). A hook that mutates it, or its strings, gets
undefined behaviour. `:before_tool_call` carries no messages (the gate stays
cheap).

## What a hook can do: the runtime

Besides reading (and, on `:before_tool_call`, voting on) its event, a hook
can talk to the user through three callables the registry puts on every
event:

```ruby
class Watchful
  def call(event)
    case event[:type]
    when :after_generation
      # One line in the REPL, the attached TUI and the web ("<bundle>> text",
      # or "hook> text" for a config hook); level: :warn colours it.
      event[:notify].call("the model repeated itself", level: :warn)
    when :before_tool_call
      # A single-select question through the question flow (REPL, attached
      # TUI, web); returns {selected: [...], freeform:, selected_indices:}
      # or nil when there is no one to ask (--non-interactive), the
      # question was dismissed, or the options were not 2-8 strings.
      answer = event[:ask_user].call(question: "#{event[:call][:name]}: #{event[:params]}\nRun it?",
                                     options: ["Run", "Deny"], header: "my guard", allow_freeform: false)
      event[:guardrail].deny!("the user said no") unless answer&.dig(:selected)&.first == "Run"
    when :before_generation
      # Cancel the running turn: a warn notice with the reason, then the
      # turn ends as cancelled (hook). From :before_tool_call it also denies
      # that call, and the rest of the batch is denied; from :after_turn or
      # :session_end it does nothing (false).
      event[:stop_turn].call("too many iterations without progress") if event[:iteration] > 20
    end
  end
end
```

`event[:hook]` is the label the notices carry: `known_names.rb (bundle
known-names)` for a bundle hook, `audit.rb (config)` for a config hook,
`turn hook` for one registered at runtime.

Timing: a notice from `:after_turn` or `:session_end` shows after the turn's
end line. A question from `:before_tool_call` shows **before** the tool
line (the gate runs first), so its text should name the call. The notices
are also logged (`turn` tag, `hook_notice`).

## Settings

A hook class whose `initialize` takes an argument gets its settings: **one
positional Hash with string keys** (`def initialize(settings = {})`;
`initialize(**kw)` is not supported). A class whose `initialize` takes none
is built bare. Defaults belong in the hook.

```yaml
bundles:                 # per bundle, by name, for its hooks
  known-names:
    names: [dzmitrydziadou]
    mode: reject
hooks:
  before_tool_call:
    - path: my_guard.rb  # a config hook: its entry's settings
      settings: { threshold: 2 }
```

Two config entries for the same file with different settings get two
instances. A running worker reads config at start (restart it after a
change), as for every hook.

## Error Handling

- `on_error: "skip"` (default): silently ignore hook failures
- `on_error: "log"`: emit a `warn` message to stderr
- `required: true` (config hooks): the hook is a guardrail. If it fails to load
  (missing file, syntax error), chi denies every tool call and says why; if it
  raises as a `before_tool_call` hook, that call is denied. See
  [Guardrails](guardrails.md#failing-closed).

A hook that fails to load is reported as a `[samagotchi:hooks]` warning and
once in the UI.

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

<a id="guardrails-from-a-hook"></a>
**Guardrails from a hook (allow / ask / deny):**

```ruby
# ~/.config/samagotchi/hooks/safety.rb
class Safety
  def call(event)
    return unless event[:type] == :before_tool_call
    command = event[:targets][:command].to_s   # execute / task_create
    if command.include?("rm -rf /")
      event[:guardrail].deny!("dangerous command denied by policy")
    elsif event[:targets][:outside_repo]
      event[:guardrail].ask!("writes outside the repo", scopes: %w[once session])
    end
  end
end
```

`event[:guardrail]` is the call's verdict. `deny!(reason, rule: nil, source: nil, advice: nil)`
and `ask!(reason, scopes: nil, rule: nil, source: nil)` vote; the strictest
vote wins (deny > ask > allow) and a vote never relaxes it, so a later hook
can't undo a deny. An ask goes to the user (see [Guardrails](guardrails.md#ask)).
`advice:` replaces the fixed "Do not retry it…" tail of the deny text with
the voter's own (a guard that wants the model to retry a corrected call:
`Retry with "…".`).

`event[:context]` is `{cwd:, repo_root:, branch:, session_id:, interface:, origin:}`
(`interface` is `:repl`, `:worker` or `:non_interactive`). `event[:targets]` is
what the call acts on, resolved as the tools resolve it:
`{command:, paths:, cwd:, repo_root:, outside_repo:}`.

The older flag still works: `event[:blocked] = true` with an optional
`event[:block_reason]`. It is folded into the verdict after each hook (so it
is sticky too), and the model gets `[<tool>] Error: blocked by guardrail: <reason>`
(default reason `blocked by hook`). A verdict's deny reads
`[<tool>] Error: denied by guardrail (<rule or hook>): <reason>. … Do not retry it …`
(after a user's Deny on an ask: `[<tool>] Error: The user declined this call… It needed approval (<rule or hook>): <reason>. …`).
Either way the activity status is `blocked`, and `:after_tool_call` still fires.
Only `:before_tool_call` votes.

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

Note: `:before_tool_call` can replace the `:call` hash to change what runs; `tool_call_started` (what the UIs show) and the rules see the final call.

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
- `sha256` is integrity (not authenticity). No signing in v1. Install records the sha256 of the copied file; at `Engine.new` a hook whose file differs is not loaded (reinstall the bundle after editing one by hand).
- Hook code is the bundle author's source of truth: on upgrade, hooks are overwritten; if the installed file was locally modified, a warning is emitted (`was locally modified; overwriting`).
- A raising `:before_tool_call` guardrail respects `on_error`: `fail_closed` denies the call (fail-closed), `log` warns, `skip` is silent.
- A `fail_closed` `:before_tool_call` hook is required: if it is missing, fails to load or its sha256 differs, chi denies every tool call until it is fixed.
- A bundle can also ship YAML rules in `guardrails/*.yml`; see [Guardrails](guardrails.md#the-guardrails-bundle).
- Ordering: bundle hooks fire by `(priority, bundle_name, hook_name)` (lower priority first), then plain `config.yml` hooks in registration order.
- Settings: a hook class with `initialize(settings = {})` gets the bundle's section of `config.yml` `bundles:` (see [Settings](#settings)).
- Shipped bundles: `chi bundle install guardrails` (rules, see [Guardrails](guardrails.md#the-guardrails-bundle)) and `chi bundle install known-names` (a hook, see [Guardrails](guardrails.md#the-known-names-bundle)).
- Installing a bundle executes its hook code at `Engine` startup. Only install bundles you trust, as you would a gem. Hooks are **not** executed at install time (copy-only); they are `module_eval`'d at `Engine.new` inside per-bundle `Samagotchi::Bundles::<name>` namespaces (no top-level `require` collisions). Keep hook files side-effect-free at load time; do work in `#call` — top-level side effects (require, IO, `at_exit`, global assignment) run once per `Engine.new` (class redefinition is idempotent).

Lifecycle:

- `bin/chi bundle install <source>` copies `hooks/*.rb` to `~/.config/samagotchi/memories/.bundles/<name>/hooks/` and persists metadata + `trust_level` + `source_commit` (git HEAD) to provenance.
- `Engine.new` loads `config.yml` hooks first, then bundle hooks via `Provenance.each_installed_holding_hooks` → `Hooks::BundleLoader.load`. Bundle hooks are process-scoped (they survive the per-turn `clear_hooks`; only plain hooks are cleared). Experimental bundles emit a one-line startup warning.
- `bin/chi bundle status`, `diff`, `uninstall`, `build` are hook-aware (counts, metadata, removal).
