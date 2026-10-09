# Hooks

Samagotchi supports pluggable Ruby hooks that fire at key lifecycle points
during agent turns. Hooks let you add external tooling (CI checks, logging,
analytics) or in-process verification (test gates, policy checks).

A bundle can go further with a plugin: slash commands and tools as well as
hooks. See [Plugins](plugins.md).

## Configuration

Add a `hooks:` section to your global config file (`$XDG_CONFIG_HOME/samagotchi/config.yml`, `$XDG_CONFIG_HOME`
defaulting to `~/.config`):

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
| `:session_start` | The first turn this chi process runs for the session (so again after `--resume`, a worker that idle-exited and woke, or a restart) | `{ type: :session_start, session_id: "..." }` |
| `:before_turn` | Before each turn starts | `{ type: :before_turn, session_id: "...", prompt: "..." (nil on a continue), messages: [...] (the history before this turn) }` |
| `:after_turn` | After a turn completed or was stopped once the model was asked (not after one that failed, was cut short by an interrupt signal (SIGINT), or was stopped before its `:before_turn` hooks) | `{ type: :after_turn, status: "completed" \| "canceled", present: (see [Presenting the answer](#presenting-the-answer-display-only)), messages: [...] (the conversation the turn stored; a cancelled or empty turn ends it with a `kind: turn_note` system message, and a context line is `kind: context`, see [sessions.md](sessions.md#notes-a-turn-leaves-for-the-model)) }` |
| `:before_generation` | Before each LLM API call (both loops) | `{ type: :before_generation, iteration: N }` |
| `:after_generation` | After LLM returns (both loops); not after a generation a hook cut (`stop_generation`) | `{ type: :after_generation, iteration: N, response: "...", messages: [...] (the conversation as sent) }` |
| `:generation_progress` | While the response streams, in batches (see [Watching the stream](#watching-the-stream)) | `{ type: :generation_progress, iteration: N, thinking: "..." (new since the last fire), text: "..." (new visible text), thinking_chars: N, text_chars: N (this generation so far), elapsed_ms: N, restarted: true (only on the first fire after a dropped stream was asked again) }` |
| `:before_tool_call` | Before tool dispatch (and before `tool_call_started`) | `{ type: :before_tool_call, iteration: N, call: {...}, params: "...", guardrail: Verdict, context: {...}, targets: {...}, blocked: false, block_reason: nil }` |
| `:after_tool_call` | After tool execution | `{ type: :after_tool_call, iteration: N, tool: "read", output: "..." (the text the model gets: capped at max_tool_output_chars, a cut one ending in a [cut: N of M chars …] line), status: "ok" \| "error" \| "blocked" \| "stopped" }`; `stopped` is a `task_wait` the turn's Stop ended (the task runs on) or whose task was stopped |
| `:session_end` | After each turn `:after_turn` fires for, after it (turn-level lifecycle) | `{ type: :session_end, session_id: "..." }` |

Every event also carries the hook runtime (next section): `hook:` (the label
of the hook about to run) and the callables `notify:`, `ask_user:`,
`stop_turn:`, `steer:`, `stop_generation:`.

`messages:` is a **read-only copy**: a frozen array of copied message hashes
(`{role:, content:, …}`). A hook that mutates it, or its strings, gets
undefined behaviour. `:before_tool_call` carries no messages (the gate stays
cheap).

## What a hook can do: the runtime

Besides reading (and, on `:before_tool_call`, voting on) its event, a hook
can talk to the user, and to the running turn, through the callables the
registry puts on every event (`stop_generation`, the fifth, is in
[Watching the stream](#watching-the-stream)):

```ruby
class Watchful
  def call(event)
    case event[:type]
    when :after_generation
      # One line in the REPL, the attached TUI and the web ("<bundle>> text",
      # or "hook> text" for a config hook); level: :warn colours it.
      # fallback_for: :display marks a line a UI that renders the answer's
      # display may leave out (below).
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
    when :after_tool_call
      # Put text into the running turn, as the user's steering does: at the
      # loop's next boundary it joins the conversation as its own user
      # message, and every UI shows a nudge line ("<bundle> nudged: …").
      # True when queued; false with no turn, and from :after_turn or
      # :session_end. A steer that arrives after the model's final answer is
      # dropped (logged), not merged: it never keeps a finished turn going.
      event[:steer].call("Say briefly what you have found so far.") if event[:iteration] == 30
    end
  end
end
```

`event[:hook]` is the label the notices carry: `known_names.rb (bundle
known-names)` for a bundle hook, `audit.rb (config)` for a config hook,
`turn hook` for one registered at runtime.

`event[:notify]` also takes `fallback_for:`, what the line stands in for, so
that a UI that already shows it can leave the line out. The one value is
`:display`: the line repeats what the hook's
[`event[:present]`](#presenting-the-answer-display-only) display shows (its
links), for a UI that doesn't render that display. The hook never names a UI;
each decides by what it renders. The web with markdown on (`web.markdown` and
the commonmarker gem) leaves such a line out, live and after a reload; with
markdown off it shows, as it does in the REPL, the attached TUI and
`chi -p`, which print the answer as text. The log keeps the line with
`fallback_for=display`. Another value, or none, shows the line everywhere.
Mark a line only when the display really shows all of it (source-links marks
its note only when the answer links every URL the note names). It needs chi
0.35.0: an older chi's `event[:notify]` raises `ArgumentError` on the keyword,
so a bundle that passes it sets `requires_chi: ">= 0.35.0"`.

A steer is saved in the session as `{role: "user", kind: "steer", source:
"<bundle>", content: "…"}`, its text raw. The model reads it as a user turn
led by one line naming the sender: `[Steer from the <bundle> plugin,
mid-task. Follow it; if it asks for nothing, carry on with the task.]`.
Its `source` is the hook's bundle (a config or turn hook's label otherwise).
Lines typed into a running turn are saved as `{role: "user", kind: "input",
content: "…"}`: part of that turn, not a turn of their own. They carry a
`source` when they are not the user's own: `chi_send` (`chi send -m`),
`parent_agent` (a delegate's follow-up), `plugin_send` (`ctx.sessions.send`),
or `automatic:<client id>` for a client id chi doesn't know (an unknown sender
is never taken for the user). The model reads them with the same kind of
header (`[Steer from the user, …]`, `[Steer sent with chi send, …]`, and so
on; `[Automatic input from <client id>, sent mid-task; not your user's
message. …]` for an unknown one).

Timing: a notice from `:after_turn` or `:session_end` shows after the turn's
end line. A question from `:before_tool_call` shows **before** the tool
line (the gate runs first), so its text should name the call. The notices
are also logged (`turn` tag, `hook_notice`).

## Watching the stream

`:generation_progress` sees a model response **while it streams**: the
thinking and the visible text, on both the raw-prompt path (llama.cpp
`/completion`, `/v1/completions`) and the chat path (`api: openai`). It fires
for the turn's own generations only (not a plugin's `ctx.ask_model`, not a
recap).

When it fires: once 2000 new chars (thinking + text) are pending, or once a
second has passed since the last fire with anything pending. It is checked
as each chunk arrives (there is no timer), so a silent stream fires nothing.
There is no fire at the end of a generation (`:after_generation` sees the
whole response), and none after the turn or the generation was cancelled.
A 240k-char thinking gives about 120 fires.

`thinking` holds what the model streamed as thinking: `reasoning_content`
on the chat path, a Qwen `<think>` block or a Gemma 4
`<|channel>thought … <channel|>` block on the raw-prompt path. Some
thinking arrives as `text` instead: a chat provider's that puts `<think>`
inside the answer's content. Tool-call bodies are left out of `text`. With streaming off
(`stream: false` on a chat host) there are no chunks, so no fires.

When a stream drops mid-generation, the step is asked again and streams
from the start (a `:generation_retrying` event with `restarted: true`);
what the dropped attempt streamed is void. The first `:generation_progress`
fire after that carries `restarted: true`; later fires, and fires after a
normal start, carry no `restarted` key. A watcher of the stream starts
over on it: the thinking a dropped attempt streamed is no part of this
generation's, and counting it would read a re-thought opening as a repeat.

**Keep it fast.** The hook runs on the turn's thread, inside the HTTP read:
while it runs, tokens wait in the socket (nothing is lost). A hook over
100 ms logs `stream_hook_slow` (warn, with its label and the ms) once per
turn. Don't ask questions or call the model from it: `event[:ask_user]`
returns nil at once here, and `ctx.ask_model` would hold the stream for its
whole answer. A hook that never returns hangs the turn, as any hook does. A
plugin's block that raises is logged (`plugin_hook_failed`) at most once a
minute.

Two ways to act:

- `event[:stop_turn].call(reason)`: as anywhere, a warn notice and the turn
  ends cancelled (hook). The socket closes at once.
- `event[:stop_generation].call(reason)`: cut **this generation** only. The
  turn goes on: the model is asked again with a hidden note ("your last
  reply was cut off by <bundle>: <reason>. Don't start the same reasoning
  again; …") at the retry temperature, and the UIs print `↻ cut by
  <bundle>, asking again (1/1)`. True when a streaming generation was cut
  now; false with none streaming, once it was cut, after a cancel, and from
  `:after_turn` / `:session_end`.

What a cut is, in detail:

- It is an empty answer made early: it uses the `retry.empty_answer` budget
  ([configuration.md](configuration.md#llama-network-retry-behavior)). With
  no retry left (`retry.empty_answer: 0`, or already used) and nothing
  queued, the turn ends cancelled (hook): "■ turn canceled (by a hook)".
- It shows nothing by itself: post your own notice (`event[:notify]`) to say
  why. The bundle and the reason go into the note the model reads and the
  log (`generation_stopped`).
- Queued input (the user's line, or a hook's `steer`) goes in place of the
  hidden note, also once the retry budget is spent, and spends no retry;
  then there is no `↻` line.
- The cut generation is not kept: its thinking and any visible text it had
  streamed go with it (the retry answers anew). `:after_generation` doesn't
  fire for it, and its token usage is lost (the stream never sent its last
  chunk). A client that joins the running turn still sees its thinking in
  the turn so far until the turn ends.
- A Stop from the user right after a cut is a plain cancel.
- A cut for a message (a user's, `chi send`'s or a parent agent's line into
  a generation that has streamed only thinking for `steer.cut_after` seconds)
  is not a plugin's cut: it sends no hidden note and spends no retry; the
  message goes in and the UIs print `↪ cut in for your message`. The
  stream's `generation_completed` says `stopped_by: "steer"`, and
  `stop_generation` returns false for a generation a message already cut.
  A plugin's `steer` never cuts.

## Presenting the answer (display only)

`:after_turn` carries one more callable, `present:`. It changes how the
turn's answer is **shown**, never what the model said: the block gets the
current display text (the answer's content until a hook changed it) and
returns the new one.

```ruby
class Shout
  def call(event)
    return unless event[:type] == :after_turn

    event[:present].call { |text| text.gsub(/\bTODO\b/, "**TODO**") }
  end
end
```

- The result is kept as `display` on the answer's model message in the
  session file. The model never sees it: the prompts and chat requests take
  the fields they send, and the copies of the conversation given to hooks
  (`messages:`), plugins (`ctx.messages`) and the recap leave it out.
- Calls chain in hook order (bundle hooks by priority, then config hooks,
  then turn hooks): each block gets what the one before returned. The call
  returns the display text after it.
- A block that raises, returns something other than a String, or returns
  more than 200 000 characters leaves the display as it was (logged as
  `present_rejected` with the hook's label).
- It works on the stored conversation's last message only when that is the
  model's answer: after a cancelled, failed or empty turn there is none, and
  the call returns nil without running the block.
- **The web** renders `display` instead of the answer (markdown, sanitised
  like every answer: raw HTML is escaped, only http(s)/mailto links are
  kept), on a live turn and after a reload. Its copy button copies the
  display text. The page learns about it from an `answer_display` event
  that comes after `turn_completed` (the hooks run after the turn ended).
- **Terminals** (the REPL, the attached TUI) have printed the answer by then
  and do not change it; use `event[:notify]` for something they should show.

A plugin gets the same from `chi.on(:after_turn) { |event, ctx| event[:present].call { … } }`.

## Settings

A hook class whose `initialize` takes an argument gets its settings: **one
positional Hash with string keys** (`def initialize(settings = {})`;
`initialize(**kw)` is not supported). A class whose `initialize` takes none
is built bare. Defaults belong in the hook.

```yaml
bundles:                 # per bundle, by name, for its hooks
  known-names:
    names: [jonathandoe]
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
engine = Samagotchi::Engine.new
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
`{command:, paths:, cwd:, repo_root:, outside_repo:, git_dirs:}`. `outside_repo`
is measured from the session's repo, not the call's `cwd:`; `git_dirs` lists where
a shell call runs git that changes a checkout (`"unknown"` for a folder the
text doesn't tell; `[]` for other tools).

The older flag still works: `event[:blocked] = true` with an optional
`event[:block_reason]`. It is folded into the verdict after each hook (so it
is sticky too), and the model gets `[<tool>] Error: blocked by guardrail: <reason>`
(default reason `blocked by hook`). A verdict's deny reads
`[<tool>] Error: denied by guardrail (<rule or hook>): <reason>. … Do not retry it …`
(after a user's Deny on an ask: `[<tool>] Error: The user declined this call… It needed approval (<rule or hook>): <reason>. …`).
Either way the activity status is `blocked`, and `:after_tool_call` still fires,
with `status: "blocked"`.
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

### The call a hook sees

`event[:call]` is the same hash for every model format (Gemma, Qwen, the
chat path): `name:`, `content:`, `path:`, `scope:`, plus the tool's other
parameters by their own names (symbol keys). `content:` holds the tool's
main argument (`""` when it has none), `path:` the parameter named in its
column, and an argument the model left out is `nil`. Text values are
stripped of surrounding whitespace, except file text, an edit's
`old_text`/`new_text`, `env` and `options`.

| Tool | `content:` from | `path:` from | Own fields |
|------|-----------------|--------------|------------|
| `execute` | `command` | — | `description`, `cwd` |
| `read` | `path` | — | `start_line`, `end_line` |
| `write` | — | `path` | `content` |
| `edit` | — | `path` | `old_text`, `new_text`, `start_line`, `end_line` |
| `memory_read` | `name` | — | `scope` |
| `memory_write` | — | `name` | `content`, `scope`, `description`, `current_model_only`, `remove` |
| `task_create` | `command` | — | `cwd`, `env` |
| `task_get` | `id` or `task_id` | — | — |
| `task_list` | — | — | — |
| `task_stop` | `id` or `task_id` | — | — |
| `task_wait` | `id` or `task_id` | — | `timeout`, `tail_lines`, `done_pattern` |
| `web_fetch` | `url` | — | — |
| `register_reminder` | `name` | — | `description`, `interval_minutes` |
| `cancel_reminder` | `name` | — | — |
| `list_reminders` | — | — | — |
| `list_sessions` | — | — | `cwd` |
| `send_note` | `text` | — | `session` |
| `context_read` | `name` | — | `offset`, `limit` |
| `delegate` | `task` | — | `model`, `session`, `cwd`, `wait`, `timeout` |
| `delegate_result` | — | — | `session`, `timeout` |
| `ask_user_question` | `question` | — | `question`, `options`, `header`, `multi_select`, `allow_freeform` |
| `forget_outputs` | `note` | — | `ids`, `note`, `keep`, `restore` |

A `write`'s `content:` is the file text; an `edit` carries `old_text:` and
`new_text:` (its `content:` is `""`). A plugin or MCP tool's call has its
arguments whole on `args:` (string keys) instead, and its `content:` is those
arguments as JSON. An MCP tool's call is the mcp bundle's `mcp_call`: `tool:
"mcp_call"`, with `args: {"tool" => "<server>/<tool>", "args" => {…}}`.

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
    on_error: fail_closed   # skip (default) | log | fail_closed (before_tool_call only)
    priority: 10
  audit.rb:
    sha256: 5678...
    event: after_tool_call
    on_error: log
    priority: 100
trust_level: reviewed        # reviewed | experimental (default)
requires_chi: ">= 0.12.0"    # optional: a gem-style requirement, as for plugins
needs: [gh]                  # optional: outside commands the memories use (docs/memory.md#bundles-that-need-outside-commands)
```

Notes:

- Hook key = basename (flat under `hooks/`). No subdirs in v1.
- `event` is required for auto-registration; a hook with no event is skipped.
- `sha256` is integrity (not authenticity). No signing in v1. Install records the sha256 of the copied file; at `Engine.new` a hook whose file differs is not loaded (reinstall the bundle after editing one by hand).
- Hook code is the bundle author's source of truth: on upgrade, hooks are overwritten; if the installed file was locally modified, a warning is emitted (`was locally modified; overwriting`).
- `on_error` defaults to `skip` for every event, `:before_tool_call` included: a raising hook is silent and the call goes ahead. `log` warns. `fail_closed` (only on `:before_tool_call`; on any other event it acts as `skip`) denies the call the hook raised on. Choose `fail_closed` for a hook that is a guardrail, whose failure should stop tool calls rather than let them through.
- `requires_chi`: when this chi doesn't meet it, none of the bundle's hooks load (each is reported, `not loaded: it requires chi …`), as for a [plugin](plugins.md#loading-and-when-it-fails).
- A `fail_closed` `:before_tool_call` hook is required: if it is missing, fails to load, its sha256 differs or chi doesn't meet the bundle's `requires_chi`, chi denies every tool call until it is fixed.
- A bundle can also ship YAML rules in `guardrails/*.yml`; see [Guardrails](guardrails.md#the-guardrails-bundle).
- Ordering: bundle hooks fire by `(priority, bundle_name, hook_name)` (lower priority first), then plain `config.yml` hooks in registration order.
- Settings: a hook class with `initialize(settings = {})` gets the bundle's section of `config.yml` `bundles:` (see [Settings](#settings)).
- A bundle can also ship a `plugin.rb` whose `chi.on(event)` blocks are bundle hooks too, next to commands and tools; see [Plugins](plugins.md). There `ctx.notify`, `ctx.steer` and the other `ctx` helpers act as this page's `event[:notify]`… do for the event the block runs for.
- Shipped bundles (each in a profile: `core` or `dev`, see [Bundle profiles](memory.md#bundle-profiles-core-and-dev)): `chi bundle install guardrails` (rules, see [Guardrails](guardrails.md#the-guardrails-bundle)) and `chi bundle install known-names` (a hook, see [Guardrails](guardrails.md#the-known-names-bundle)), `chi bundle install source-links` (a hook: announces source refs, see [The source-links bundle](#the-source-links-bundle)), `chi bundle install btw` (a plugin: `/btw`, see [Plugins](plugins.md#the-btw-bundle)), `chi bundle install mcp` (a plugin: tools from MCP servers, see [Plugins](plugins.md#the-mcp-bundle)) `chi bundle install loop-guard` (a plugin: breaks tool-call loops, see [Plugins](plugins.md#the-loop-guard-bundle)), `chi bundle install check-in` (a plugin: checks on a long turn, see [Plugins](plugins.md#the-check-in-bundle)) and `chi bundle install skills` (a plugin: `/skill`, versions of skills, see [Plugins](plugins.md#the-skills-bundle)).
- Installing a bundle executes its hook code at `Engine` startup. Only install bundles you trust, as you would a gem. Hooks are **not** executed at install time (copy-only); they are `module_eval`'d at `Engine.new` inside per-bundle `Samagotchi::Bundles::<name>` namespaces (no top-level `require` collisions). Keep hook files side-effect-free at load time; do work in `#call` — top-level side effects (require, IO, `at_exit`, global assignment) run once per `Engine.new` (class redefinition is idempotent).

Lifecycle:

- `chi bundle install <source>` copies the hook files its manifest's `hooks:` map lists (only those; with no `hooks:` map, every `hooks/*.rb`) to `$XDG_CONFIG_HOME/samagotchi/memories/.bundles/<name>/hooks/` (`$XDG_CONFIG_HOME` defaults to `~/.config`) and persists metadata + `trust_level` + `source_commit` (git HEAD) to provenance.
- `Engine.new` loads `config.yml` hooks first, then bundle hooks via `MemoryBundle::Provenance.each_installed(holding: :hooks)` → `Hooks::BundleLoader.load`. Bundle hooks are process-scoped (they survive the per-turn `clear_hooks`; only plain hooks are cleared). Experimental bundles emit a one-line startup warning.
- `chi bundle status`, `diff`, `uninstall`, `build` are hook-aware (counts, metadata, removal).

## The source-links bundle

```sh
chi bundle install source-links    # or chi bundle install dev
```

installs one `after_turn` hook and a short memory. When the model's answer
mentions a known source ref — a JIRA ticket, a GitHub issue, an internal
wiki page — the web links it in the answer (below), and every UI shows one
line right after the message:

```
sources: JIRA JIRA-123 → https://myjira.com/browse/JIRA-123, JIRA JIRA-10 → https://myjira.com/browse/JIRA-10
```

The note is **not part of the conversation**: it is an event shown to the
user, never stored in the session file. A UI replays it with the session's
cards (a page reload keeps it, after the worker stopped too). Only the
model's final answer is scanned (the last `role: "model"` message), and only
the first 20 000 characters of it. A ref that is already a link is skipped —
inside a bare URL (`https://x.com/JIRA-123`), in a markdown link's target, or
in a markdown link's label when the target names the same ref
(`[JIRA-123](https://x.com/JIRA-123)`) — while `see https://x.com JIRA-123`
and `[fix for JIRA-123](https://github.com/o/r/pull/9)` still link. A ref
glued to URL punctuation (`/browse/JIRA-1`, `?key=JIRA-1`, `JIRA-1/foo`) is
skipped too; `Ticket:JIRA-5` and `#JIRA-123` are ordinary plain text and do
link. The line names each URL once (compared case-insensitively: `#12` and
`dm1try/samagotchi#12` may be one issue, and with `case_insensitive: true`
`JIRA-1` and `jira-1` are one ticket), in first-occurrence order, whatever
order the sources are configured in. With no sources configured the hook is a
silent no-op.

```yaml
bundles:
  source-links:
    sources:
      - name: JIRA
        prefix: JIRA              # simple form: \bJIRA-(\d+)\b
        base_url: https://myjira.com/browse/
      - name: GitHub
        pattern: '\bGH-(\d+)\b'   # full form: a regex
        url: 'https://github.com/org/repo/issues/{match}'
        case_insensitive: false   # optional, default false
    max: 10                       # optional: refs per line, default 10
    note: false                   # optional: no sources line, default true
```

**In the web** the refs are also links in the answer itself: each
occurrence becomes `[JIRA-123](https://myjira.com/browse/JIRA-123)` through
[`event[:present]`](#presenting-the-answer-display-only), so the model's
text stays as it was, and the links survive a reload and a stopped worker
(they are the answer's `display` in the session file). The same skip rules
apply, and a ref in code (a `` `span` `` or a fenced block) or anywhere in a
markdown link is left as it is; past the first 20 000 characters the answer
is unchanged. The terminals see only the line; `note: false` drops it and
keeps the web links. With markdown on, the web leaves the line out when the
answer links every URL it names, since it would only repeat them as plain
text ([`fallback_for: :display`](#what-a-hook-can-do-the-runtime)); it shows
when it names one the answer doesn't link (a ref only in code, two sources on
one ref) and whenever markdown is off. Bundle 0.4.0 needs chi 0.35.0 for that.

The `prefix:` form compiles to `\b<prefix>-(\d+)\b` and the URL is
`base_url` + the full ref text (`JIRA-123`). The `pattern:` form takes a
regex and a `url:` template with placeholders (below). `case_insensitive:
true` adds the `/i` flag. Past `max` refs the line ends with `… +N more`.

Each regex is compiled with a per-regex timeout (0.5 s, per match attempt),
so a catastrophic pattern is abandoned instead of hanging the turn: that
source is skipped whole (its partial matches are discarded) with a warning,
and the others still report. An entry with neither `prefix:` nor `pattern:`,
or a pattern that does not compile, is skipped with a warning at load. The
hook is `on_error: log`: a bug in it warns and the turn is unaffected. As with
every bundle hook, a running worker picks it up after its next start.

### Placeholders, and the project's own repo

A `url:` template (the `pattern:` form only; `base_url:` is always
`base_url` + the ref) can use:

| placeholder | value | when it can't be filled |
|---|---|---|
| `{match}` | the first capture group, else the whole ref | never: it falls back to the ref |
| `{1}` … `{9}` | a numbered capture group | the group didn't take part: the ref is **not linked** |
| `{name}` | a named capture group `(?<name>…)` | the group didn't take part: **not linked** |
| `{repo}`, `{host}` | the named group `repo` / `host` when the pattern has one and it took part; else the project's git remote | neither: **not linked** |

A ref with a placeholder that can't be filled is left out of both the line
and the answer: no URL is built with a hole in it (another source on the same
ref can still link it). A `{word}` or `{N}` that is none of the above (not a
group of the pattern, or `{7}` in a two-group pattern) stays as literal text,
with one warning when the source is loaded. Every value is percent-encoded
(everything outside `A-Za-z0-9-._~`, `/` included), except that `{repo}`
keeps its `/` between segments (GitLab's `group/sub/proj`); a `{repo}` with an
empty, `.` or `..` segment counts as unfilled.

So one source links both `#12` in this project and a cross-repo ref:

```yaml
bundles:
  source-links:
    sources:
      - name: GitHub
        # `#12` → this project's repo; `owner/repo#12` → that repo
        pattern: '(?<![\w/&])(?:(?<repo>[A-Za-z0-9][\w-]*/[\w.-]*\w))?#(?<num>\d+)\b'
        url: 'https://github.com/{repo}/issues/{num}'
        remote_host: github.com
```

```
sources: GitHub #12 → https://github.com/dm1try/samagotchi/issues/12, GitHub rails/rails#5 → https://github.com/rails/rails/issues/5
```

GitHub redirects `/issues/N` to `/pull/N` and back, so one URL covers issues
and pull requests. The lookbehind keeps `&#123;`, `x/#1` and a partial
`b/c#1` inside `a/b/c#1` out; code and URLs are skipped as always. `PR #12`
links, `PR#12` doesn't (a `#` right after a letter). The pattern is loose on
purpose: a bare `#\d+` also matches "step #2", and `and/or#5` or `TCP/IP#3`
read as qualified refs. A stricter variant wants `PR #`, `issue #` or a
qualified ref:

```yaml
        pattern: '(?<![\w/&])(?:(?<repo>[A-Za-z0-9][\w-]*/[\w.-]*\w)#|\b(?:PR|[Ii]ssue) #)(?<num>\d+)\b'
```

**Where `{repo}` and `{host}` come from.** Without a named group that took
part, they come from `git remote get-url <remote>` run in the session's
working directory (the worker's; the in-process REPL's is the terminal's
current directory). `remote:` picks the remote, default `origin` — a fork
sets `remote: upstream`. Git applies `insteadOf` rewrites and includes, and a
worktree reports its main repo's remote. The URL forms understood are
`https://`, `http://`, `ssh://`, `git://` (credentials and port dropped) and
scp-like `[user@]host:owner/repo`; the repo is the path without a trailing
`.git` or `/`. A local path, `file://`, no git, no repo or no such remote
leaves the ref unlinked, silently (a debug log line only). Git is asked only
when a hit needs it — a JIRA source or a qualified ref never runs it — and
the answer, even "none", is remembered for the worker's life: a remote
changed mid-session counts after the worker's next start.

`remote_host:` (a host or a list, compared case-insensitively) applies the
remote-derived links only when the remote's host is one of them, so a
`https://github.com/{repo}/…` template never points a GitLab project's `#12`
at github.com. A qualified ref is linked whatever the local remote is. An SSH
alias (`git@github-work:o/r.git` from a multi-account `~/.ssh/config`) or an
`insteadOf` mirror reports its own host; list it too:
`remote_host: [github.com, github-work]`.

Two Ruby regex notes. With named groups in a pattern, a plain `(…)` doesn't
capture and gets no number, so `{1}` is the first *named* group, and so is
`{match}` (in the example above `{match}` is the repo part): use either named
or numbered groups in one pattern, and named placeholders with named groups.
And a pattern with a `host` (or `repo`) group lets the model's text choose the
link's domain (or repo): the escaping rules out URL injection, but the choice
of the target is the model's.

