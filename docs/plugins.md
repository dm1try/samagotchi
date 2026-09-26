# Plugins

A bundle can ship one Ruby file, its **plugin**, that adds slash commands,
tools and hooks to every session. Its hooks are ordinary bundle hooks
([hooks.md](hooks.md)). Its commands and tools work like chi's own.

This is the first version of the plugin API. More of it comes later: see
[Not yet](#not-yet).

## A bundle with a plugin

```
my-bundle/
  manifest.yml
  plugin.rb
  identity.md        # optional, like any bundle's memories, hooks/ and guardrails/
```

```yaml
# manifest.yml
name: my-bundle
version: 1.0.0
plugin:
  file: plugin.rb
  sha256: sha256:54afb01b…   # shasum -a 256 plugin.rb
requires_chi: ">= 0.1.28"    # optional: a gem-style requirement (">= 0.1.28, < 0.2")
```

The file must be a `.rb` name in the bundle's top directory. It defines a
class named like the file (`plugin.rb` → `Plugin`, `my_plugin.rb` →
`MyPlugin`), and that class has a `register(chi)` method:

```ruby
# plugin.rb
class Plugin
  def initialize(settings)        # optional: config.yml bundles: my-bundle:
    @greeting = settings.fetch("greeting", "hello")
  end

  def register(chi)
    chi.command "/hello", "greet, and say what the plugin sees" do |args, ctx|
      who = args.empty? ? "there" : args
      ctx.card(id: "hello", title: "#{@greeting}, #{who}",
               body: "This session has **#{ctx.messages.size}** messages.",
               actions: [{ label: "Again", command: "/hello again" }])
      "#{@greeting}, #{who} (#{ctx.messages.size} messages)"
    end

    chi.tool "echo_args", "Echo the arguments back.",
             params: { text: { type: "string", description: "Any text to echo", required: true } },
             label: "echoing" do |args, _ctx|
      "echo: #{args[:text] || args[:content]}"
    end

    chi.on(:after_turn) do |_event, ctx|
      File.open(File.join(ctx.data_dir, "turns.log"), "a") { |f| f.puts(ctx.session_id) }
    end
  end
end
```

`spec/fixtures/sample_plugin_bundle` is this bundle. Install it with
`chi bundle install spec/fixtures/sample_plugin_bundle`.

Settings work as they do for hooks ([hooks.md](hooks.md#settings)). An
`initialize` that takes an argument gets the bundle's section of config.yml
`bundles:`, as one Hash with string keys.

## The API: `register(chi)`

### `chi.command(name, description, anytime: false) { |args, ctx| … }`

This adds a slash command. `name` is `/name` (a–z, 0–9, `_` and `-`).
`args` is the text after the name, stripped, or `""` when there is none. The
block returns the text to show (a String), or nil to show nothing. If the
block raises, the user sees `/name: <error>`.

For now a plugin command runs in the **in-process REPL** (`chi --no-shared`),
typed at the prompt between turns. The attached TUI and the web don't
offer it yet. They will in a later version, together with `anytime: true`
(a command that runs while a turn runs). Today `anytime:` is stored and
does nothing else.

### `chi.tool(name, description, params:, label:, preview:, targets:) { |args, ctx| … }`

This adds a tool the model can call. It is declared in the system prompt and
in the chat path's `tools:`, after chi's own tools.

- `name`: a–z, 0–9 and `_`, up to 48 characters.
- `params`: `{ name => { type:, description:, required: } }`. The type
  defaults to `"string"`.
- `label`: the activity line's verb (`echoing`). The default is `calling tool`.
- `preview`: `->(args) { "…" }` for the activity line's parameters. The
  default is `key="value"` for each argument.
- `targets`: `->(args) { … }` for guardrail path and command rules. It is
  stored, but nothing uses it yet.

The block returns the result text. If it starts with `Error:`, it counts as
a failure. If it raises, the model gets `Error: <message>`. `args` is the
parsed call as a frozen Hash with symbol keys, without the tool's name. For
now the parsers give **flat** arguments: on the native (Gemma/Qwen) paths the
model's main argument often arrives as `args[:content]`. Structured,
schema-typed arguments come later.

### `chi.on(event, priority: 100) { |event, ctx| … }`

This is a bundle hook, the same as a `hooks/*.rb` file. See
[hooks.md](hooks.md#hook-events) for the events and for what `event[:notify]`,
`event[:ask_user]` and `event[:stop_turn]` do. Its label is
`plugin.rb (bundle my-bundle)`. The block may take only the event. If it
raises, the error is logged and the hook is skipped.

### Names

A command or tool name that the session already has is a **load error**.
That includes a chi built-in and another bundle's name. Bundles load in
name order, so the first bundle keeps the name.

## The context: `ctx`

Every handler gets the plugin's context. There is one per plugin for the
session's life, and each read gives the session as it is now.

| | |
|---|---|
| `ctx.session_id` | the session's id (nil before there is one) |
| `ctx.cwd` | the session's working directory |
| `ctx.repo_root` | the git checkout holding `cwd`, or nil |
| `ctx.settings` | the bundle's settings, frozen |
| `ctx.data_dir` | `$XDG_STATE_HOME/samagotchi/plugins/<bundle>/`, created on first use |
| `ctx.log` | `ctx.log.info(:event, key: value)`: debug-log records tagged `plugins`, with `bundle=<bundle>` |
| `ctx.messages` | the conversation, as a frozen copy. While a turn runs, it is the conversation before that turn |
| `ctx.notify(text, level: :info)` | one line to the user, like a hook's `event[:notify]`, labelled by the bundle (`my-bundle> …`). Every UI shows it, during a turn (a tool, a hook) or between turns (a command) |
| `ctx.card(title:, body: "", actions: [], level: :info, id: nil)` | a card in every UI, returning its id: see [Cards](#cards) |
| `ctx.ask_user(question:, options:, header: nil, allow_freeform: false)` | a question, like a hook's `event[:ask_user]` |
| `ctx.cancelled?` | whether the running turn was cancelled (a long tool should stop) |

The Engine itself is never handed to a plugin.

## Cards

A card is a small framed message with buttons: a title, a body and
actions. Core draws it in all three UIs; a plugin has no JS or CSS of its
own.

```ruby
id = ctx.card(title: "Build finished", body: "**3** warnings in `lib/`",
              actions: [{ label: "Show them", command: "/warnings" }],
              level: :warn)
ctx.card(id: id, title: "Build finished", body: "no warnings left")  # replaces it
```

- `title:` is required. `body:` is markdown in the web and plain text in
  the terminal (wrapped; there is no terminal markdown).
- `actions:` are up to 6 `{label:, command:}`. A command is a line the
  session runs as if the user typed it: `/hello again`, `/model x`, a
  plugin's own command. The web shows a button; the terminal shows
  `→ /hello again`, to type.
- `level:` is `:info` or `:warn` (the warning colour).
- `id:` names an earlier card to replace. Without one a new id is made. The
  web updates the card in place; the terminal prints it again, marked
  `(updated)`. A card that waits for something (a model's answer) shows
  first, then is replaced.
- A bad card (no title, a bad level or action) raises `ArgumentError`.

Where it shows:

| | during a turn (a tool, a hook) | between turns (a command) |
|---|---|---|
| REPL | where it happens, above the live region | at the prompt, after the command's output |
| attached TUI | where it happens | as it arrives |
| web | a row of the running step | between the turns |

A worker keeps its last 20 cards, and the notices a plugin sent between
turns, for a UI that joins later. The web shows them where they arrived
after a reload; the attached TUI shows the ones since the last turn when it
joins. They live as long as the worker: an idle exit or a restart forgets
them, and they are not saved with the session.

The event is `{type: :card, id:, source:, title:, body:, level:, actions:,
in_turn:}` (`source` is the bundle), logged as `card` with its source, id and
title.

## Loading, and when it fails

Plugins load when a session starts (`Engine.new`, in the REPL or a
worker), after the bundle hooks. The steps are:

1. The file must match the sha256 recorded at install.
2. chi must meet `requires_chi`.
3. The file is `module_eval`'d into a new module in the bundle's namespace
   (`Samagotchi::Bundles::<bundle>`).
4. The class is built, and `register(chi)` runs.

What `register` adds takes effect only when it returns. A plugin that raises
halfway adds nothing.

A plugin that fails to load is shown on stderr at start, and in every UI on
the first turn (`plugins> plugin plugin.rb (bundle x) failed to load (…)`). The rest
of chi, including the other plugins, works as usual. Unlike a required
guardrail, a plugin failure does not deny tool calls.

A change needs a restart. A running worker keeps the plugins it started
with. After an install or upgrade, a worker only loads the new code when it
starts again (`chi sessions stop`, or the idle exit).

## Trust

A plugin is Ruby code that runs inside chi with your permissions, just like
a bundle's hooks. **Installing a bundle means trusting it**, as you would a
gem.

- The sha256 is an integrity check, not proof of who wrote the file. A file
  edited after install is not loaded until you reinstall the bundle.
- Install only copies the file. The code first runs at the next session
  start.
- Guardrail rules keyed by a tool's name apply to plugin tools, as they do to
  chi's own tools.

## The bundle commands

- `chi bundle install <dir>`: copies the plugin to
  `<memories>/.bundles/<name>/plugin/`. It records the plugin's sha256 and
  `requires_chi`, and warns about a wrong declared sha256 or an unmet
  `requires_chi`.
- `chi bundle status [<name>]`: shows `plugin=plugin.rb` in the list. For
  one bundle it shows `Plugin: plugin.rb [ok|modified|missing]` and a
  `requires_chi` failure.
- `chi bundle diff <name> [plugin.rb]`: shows the installed base and the
  file on disk.
- `chi bundle build --name <name>`: puts the installed plugin (and
  `requires_chi`) into the built bundle.
- `chi bundle uninstall <name>`: removes the plugin with the bundle.

## Not yet

These are planned (`~/.claude/plans/plugins.md`):

- Plugin commands typed in the attached TUI and the web, completion there,
  and `anytime:` commands. Until then a card's action runs from the web's
  button and typed in the REPL; typed in the attached TUI it goes to the
  model.
- Structured, schema-typed tool arguments, and `targets:` for guardrails.
- `ctx.ask_model` for a side answer, and `ctx.sessions` to fork or send to
  other sessions.
- `chi.service` for long-lived processes, such as MCP servers.
- `chi.prompt` for sections of the system prompt.
