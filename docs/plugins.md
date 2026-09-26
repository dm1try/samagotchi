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
  sha256: sha256:6a1a7022…   # shasum -a 256 plugin.rb
requires_chi: ">= 0.1.28"    # optional: a gem-style requirement (">= 0.1.28, < 0.2")
needs: [gh]                  # optional: outside commands it relies on (see memory.md#bundles-that-need-outside-commands)
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
      "echo: #{args["text"]}"
    end

    chi.on(:after_turn) do |_event, ctx|
      File.open(File.join(ctx.data_dir, "turns.log"), "a") { |f| f.puts(ctx.session_id) }
    end
  end
end
```

`spec/fixtures/sample_plugin_bundle` is this bundle, plus the `/hello-slow`
of [anytime](#anytime-true) and the `save_note` tool (see `chi.tool` below). Install it with
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

A plugin command works in all three UIs:

- **REPL** (`chi --no-shared`): typed at the prompt, and Tab completes it.
- **Attached TUI** (the default `chi`): the worker's snapshot names the
  session's commands, so the TUI sends `/hello` to the worker and Tab
  completes it. It needs a worker started after the bundle was installed.
- **Web**: typed in the composer; a `/` opens a list of the session's
  commands (arrows move, ⏎ or Tab picks, Esc closes). A card's action button
  runs it too.

A line that is not a known command keeps its old meaning: in the terminal
UIs `/foo` goes to the model as a prompt; the web refuses it and names the
commands it knows.

#### `anytime: true`

A normal command waits for its turn: typed while a turn runs, it is refused
as busy (the REPL puts it back into the prompt). An `anytime: true` command
runs **at once, on its own thread, beside the running turn**, and the turn
goes on:

- In a worker (attached, web) it runs as soon as it arrives. It is never
  queued, so it is never busy, mid-turn or at the turn's end. The UIs show
  its line when it arrives (its `command_queued` says `anytime: true`),
  then its cards and notices **as it shows them**, and its output (the
  `command_ran`) when it finishes. So a card can say "working…" first and
  be replaced by the result.
- In the REPL, typed while a turn runs, it starts on a thread. Its cards
  print as it shows them, above the live region; its output prints there
  too while the turn runs, or at the prompt once the turn has ended.

Between turns an anytime command runs like any other, except that its
cards print as it shows them rather than after its output.

An anytime command's cards and notices belong to the command, never to the
running turn: they are not rows of the turn's step, and their events carry
`anytime: true`.

Its block runs on another thread than the turn, so it must be thread-safe:

- Read the conversation through `ctx.messages`, a frozen copy. While a turn
  runs, a worker's holds that turn so far; the REPL's is the conversation
  **before** that turn (`ctx.messages_partial?` says so).
- Show things only through `ctx` (`ctx.card`, `ctx.notify`), and return
  the text to show.
- Keep your own state (instance variables) behind a `Mutex` if two
  commands, or a command and a hook, may touch it at once.

```ruby
chi.command "/hello-slow", "greet after 2 s, even mid-turn", anytime: true do |args, ctx|
  sleep 2
  ctx.card(title: "slow hello, #{args.empty? ? "there" : args}",
           body: "Ran beside the turn; it saw #{ctx.messages.size} messages.")
  nil
end
```

#### `/help`

`/help` (itself an anytime command) lists every command the session knows:
chi's own, each bundle's with the bundle's name, and the terminal UIs' own
(`/stats`, `/exit`, `/detach` …), marked `terminal only` or `attached only`.
It works in all three UIs.

### `chi.tool(name, description, params:, schema:, label:, preview:, targets:) { |args, ctx| … }`

This adds a tool the model can call. It is declared in the system prompt and
in the chat path's `tools:`, after chi's own tools.

- `name`: a–z first, then a–z, 0–9 and `_`, up to 48 characters.
- `params`: `{ name => property }`, where a property is a JSON Schema
  property (`type:`, `description:`, `enum:`, `items:`, `properties:` …) plus
  `required: true`. The type defaults to `"string"`.
- `schema`: instead of `params`, the parameters as one JSON Schema object
  (`{ type: "object", properties: {…}, required: [...] }`), an MCP server's
  `inputSchema` for example.
- `label`: the activity line's verb (`echoing`). The default is `calling tool`.
- `preview`: `->(args) { "…" }` for the activity line's parameters. The
  default is `key="value"` for each argument (a list or object as JSON). If
  it raises, the default is shown. A web page reloaded later shows the
  default too: the web server doesn't run plugins.
- `targets`: `->(args) { { paths: [...], command: "…", cwd: "…" } }`, each
  key optional, says what a call acts on, for [guardrails](#guardrails).

The block returns the result text. If it starts with `Error:`, it counts as
a failure. If it raises, the model gets `Error: <message>`.

#### `args`

`args` is a frozen Hash with **string keys**: the arguments the model gave,
by name (`args["text"]`). The same Hash goes to `preview` and `targets`.

Each parser gives them structured: Gemma's native values (strings, numbers,
booleans, lists, nested objects), Qwen's `<parameter=…>` text, and the chat
path's JSON. The values are then **typed by the schema**, because Qwen's are
all text and a model may quote a number anyway:

| type | from |
|---|---|
| `integer` | `"3"` → `3`; `3.0` → `3` |
| `number` | `"2.5"` → `2.5` |
| `boolean` | `"true"`/`"false"`, any case |
| `array`, `object` | JSON text → a list or a Hash (string keys), its items or fields typed too |
| `string` | a number or boolean → its text |

A value that doesn't fit its type stays as it came (`"three"` for an
integer), so check it if it matters. Names the schema doesn't have pass
through. `"type": ["integer", "null"]` counts as `integer`.

```ruby
chi.tool "save_note", "Save a note to a file.",
         params: { path: { type: "string", description: "The file to write", required: true },
                   text: { type: "string", description: "The note", required: true },
                   format: { type: "string", enum: %w[plain markdown] },
                   meta: { type: "object", description: "Header fields",
                           properties: { tags: { type: "array", items: { type: "string" } },
                                         priority: { type: "integer" } } } },
         preview: ->(args) { "#{args["path"]} (#{args["text"].to_s.length} chars)" },
         targets: ->(args) { { paths: [args["path"]] } } do |args, ctx|
  File.write(File.expand_path(args["path"], ctx.cwd), args["text"])
  "saved #{args["path"]}"                  # args["meta"]["priority"] is an Integer
end
```

#### Schemas on the native paths

The native prompts (Gemma, Qwen on llama.cpp) declare each parameter with a
type and a description only. A plugin tool's schema is **flattened** for
them, and what doesn't fit goes into the description in words:

- an `enum`: `How the note is written. One of: "plain", "markdown".`;
- an object's fields: `type: object`, and `A JSON object with tags (array),
  priority (integer).`;
- a list's items: `A list of string values.`;
- `additionalProperties` and deeper nesting are dropped.

The chat path (`api: openai` hosts) gets the full schema, nesting and all.
Either way the call's `args` are typed by the full schema. Keep deeply
nested schemas for tools that mostly run on chat hosts.

#### Guardrails

Guardrail rules keyed by a tool's name apply to plugin tools, as they do to
chi's own. Path and command rules need to know what a call acts on, and that
is what `targets:` says:

- `paths:`: files the call reads or writes, absolute or relative to `cwd:`
  (else the session's directory). `path:` globs, `outside_repo` and the
  protected paths (chi's config, …) match them.
- `command:`: a shell command the call runs; `command:` rules match it.
- `cwd:`: where it runs, for the repo root and relative paths.

A tool without `targets:` is matched by its name only. A `targets:` that
raises counts as nothing (it is logged). See [guardrails.md](guardrails.md).

#### When the tools change

The system prompt is built once, after the plugins load, so the server can
keep its cached prompt prefix. A plugin whose tools change later (an MCP
server that answers late) calls `chi.tools_changed!`: the next turn builds
the prompt again, which costs that cache once.

### `chi.on(event, priority: 100) { |event, ctx| … }`

This is a bundle hook, the same as a `hooks/*.rb` file. See
[hooks.md](hooks.md#hook-events) for the events and for what `event[:notify]`,
`event[:ask_user]` and `event[:stop_turn]` do. Its label is
`plugin.rb (bundle my-bundle)`. The block may take only the event. If it
raises, the error is logged and the hook is skipped.

### `chi.service(name, eager: false) { |svc| … }`

A long-lived thing the plugin keeps for the session: a server process, a
connection. The block starts it, and what it returns is the service's value.
Inside the block, `svc.on_stop { … }` says how to stop it.

```ruby
def register(chi)
  server = chi.service(:index, eager: true) do |svc|
    io = IO.popen(["my-indexer", "--stdio"], "r+")
    svc.on_stop { io.close }
    io
  end
  chi.tool("index_query", "…", params: { q: { type: "string", required: true } }) do |args, _ctx|
    server.value.puts(args["q"])
    server.value.gets
  end
end
```

- `chi.service` returns the service. `service.value` starts it on first use
  and returns what the block returned; later calls return the same value.
  With `eager: true` it starts at once, inside `register`, so a raise there
  fails the plugin's load unless the plugin rescues it.
- A block that raises leaves the service unstarted: its `on_stop` callbacks
  so far run, and the next `value` tries again.
- `service.running?`, `service.state` (`:idle`, `:running`, `:stopped`) and
  `service.stop`.
- The services stop when chi leaves: the REPL exits, or the session's
  worker exits (an idle exit, `/exit`, a crash, TERM). See
  [Shutdown](#shutdown). A stopped service never starts again; `value`
  raises `Samagotchi::Plugin::Service::Stopped`.
- A plugin whose load fails after it started services has them stopped.
- `kill -9` runs nothing: a child process is orphaned then. Most stdio
  servers leave when their stdin closes, which it does as chi's process
  ends.

### `chi.ctx`

The plugin's context (the `ctx` its handlers get), for `register` itself:
its settings, log and data_dir, for example. A `ctx.notify` or `ctx.card`
while chi starts (inside `register`) waits for the session's first turn,
where every UI shows it after the plugins' load warnings; no UI is there
before.

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
| `ctx.messages` | the conversation, as a frozen copy, without the system prompt. While a turn runs, a session worker's (attached, web) adds that turn so far: its prompt, the model's text and the lines merged into it (no tool calls or thinking); the REPL's is the conversation before that turn |
| `ctx.messages_partial?` | whether `ctx.messages` leaves out a running turn (the REPL mid-turn), so a plugin can say what its answer is about |
| `ctx.notify(text, level: :info)` | one line to the user, like a hook's `event[:notify]`, labelled by the bundle (`my-bundle> …`). Every UI shows it, during a turn (a tool, a hook) or between turns (a command) |
| `ctx.card(title:, body: "", actions: [], level: :info, id: nil)` | a card in every UI, returning its id: see [Cards](#cards) |
| `ctx.ask_user(question:, options:, header: nil, allow_freeform: false)` | a question, like a hook's `event[:ask_user]` |
| `ctx.cancelled?` | whether the running turn was cancelled (a long tool should stop) |
| `ctx.ask_model(messages:, prompt:, …)` | a side answer from the session's model: see [Side answers](#side-answers-ctxask_model) |
| `ctx.sessions` | fork, send to and read other sessions: see [Other sessions](#other-sessions-ctxsessions) |

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

- `title:` is required. `body:` is markdown in the web. The terminal shows
  it wrapped, with the markdown cheaply stripped: `**bold**` and `__x__`
  lose their marks, backticks and code fences go, headings lose their `#`s,
  and lists stay as they are.
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

An [anytime command](#anytime-true)'s cards show as it shows them, after its
line, in every UI, whether a turn runs or not.

A worker keeps its last 20 cards, and the notices a plugin sent between
turns, for a UI that joins later. The web shows them where they arrived
after a reload; the attached TUI shows the ones since the last turn when it
joins. They live as long as the worker: an idle exit or a restart forgets
them, and they are not saved with the session.

The event is `{type: :card, id:, source:, title:, body:, level:, actions:,
in_turn:}` (`source` is the bundle), logged as `card` with its source, id and
title.

## Side answers: `ctx.ask_model`

```ruby
answer = ctx.ask_model(messages: ctx.messages, prompt: "what did we decide about the cache?",
                       system: "Answer briefly.", timeout: 120, max_tokens: 400)
```

One request to the session's current model on its host, resolved as a turn
resolves them (a `/model` switch counts). It has **no tools**, thinking is
off, and it writes nothing: the conversation, the saved session and the
next turn never see it, and no hook fires. It returns the answer text.

- `messages:` go as a transcript, filtered like the idle recap's: no system
  prompt, tool calls, tool output or thinking, and an image is a line
  naming it (`[image shot.png]`). A long one keeps its tail (32,000
  characters). The transcript and `prompt:` go in one user message.
- `system:` has a short default ("answer about the conversation below,
  briefly, and don't continue its task").
- `max_tokens:` defaults to 1024. An answer cut off by it ends with `…`.
- `cancel:` takes a `Samagotchi::CancellationController`; cancelling it
  aborts the request.
- It blocks until the answer comes, so call it from an anytime command or a
  thread of your own. A local server that runs one request at a time
  (llama.cpp with one slot) answers it after a running turn's current
  request.
- It raises `Samagotchi::Plugin::ModelError` when the request fails or
  times out (the message says why), and `Samagotchi::Plugin::ModelCancelled`
  when cancelled.

It goes through the host's OpenAI API (`/v1/chat/completions`), which
llama.cpp serves on a native host too.

## Other sessions: `ctx.sessions`

```ruby
id = ctx.sessions.fork(messages: ctx.messages + [{ role: "user", content: q }, { role: "model", content: a }],
                       title: "btw: #{q}")
ctx.sessions.send(id, "go on from here")
ctx.sessions.read(id)  # => {id:, title:, status:, parent_id:, running:, messages:}
```

- `fork(messages:, title: nil, prompt: nil)` starts a child session in its
  own worker, from these messages, in this session's folder and model. It
  shows in every list as a child of this one (`↳ parent`), and the user can
  attach to it. It returns the child's id.
  - Without `prompt:` the child waits idle. With one, it runs it as its first
    turn, and counts against `session.max_children` (like `delegate`).
  - `title:` is what the lists show until its first turn (else the prompt, or
    the first user message).
  - An image a message names is copied into the child. One whose file is
    gone is dropped, with `[image x.png was not copied]` in its message.
- `send(id, text)` sends a user message to a session (an id or a unique
  prefix); it runs as a turn, and a stopped session is woken. It waits up to
  5 s for the session's worker, so call it from an anytime command or a
  thread of your own, never from a tool or hook of a running turn. A
  session open in a chi REPL can't take it.
- `read(id)` gives a session now: from its worker when one runs (with a
  running turn so far, `running: true`), else as saved. `messages` has no
  system prompt.
- Each raises `Samagotchi::Plugin::Sessions::Error` with the reason.

## The btw bundle

`chi bundle install btw` installs the bundle shipped with chi. It is written
only against this API (`lib/samagotchi/bundles/btw/plugin.rb`).

- `/btw <question>` asks the session's model a side question about the
  conversation, even while a turn runs. A card `btw: <question>` shows
  "thinking…" at once, and the same card then shows the answer. Nothing else
  sees the answer.
- The card's **Keep as session** runs `/btw keep <id>`. It forks the
  conversation, the question and the answer into an idle child session, and
  shows a card `kept as <id>`.
- The last 10 answers can be kept, while the session's worker (or REPL)
  runs. After that, or after a restart, `keep` says expired.
- In the REPL, a question asked during a turn is about the conversation
  before that turn, and the card says so. In a worker it includes the turn
  so far.
- Settings: `bundles: btw: {max_tokens: 1024, timeout: 120}`.
- It ships no memory, so it adds no line to the prompt's memory index. Its
  0.1.0 shipped `btw.md` as one, and `chi bundle upgrade btw` leaves that file
  (and its index line) behind. Drop it with `chi bundle uninstall btw`, then
  `chi bundle install btw`. After an upgrade already ran, delete
  `~/.config/samagotchi/memories/btw.md` and its `**btw**` line in `index.md`
  there by hand.

## The mcp bundle

`chi bundle install mcp` installs the bundle shipped with chi. It is written
only against this API (`lib/samagotchi/bundles/mcp/plugin.rb`), and adds
tools from [MCP](https://modelcontextprotocol.io) servers. It has no memory
file, so it costs the prompt nothing but its tools. Stdio servers only, for
now.

```yaml
# config.yml
bundles:
  mcp:
    timeout: 60             # seconds per tool call (default 60)
    startup_timeout: 10     # seconds for initialize and tools/list (default 10)
    servers:
      everything:
        command: [npx, -y, "@modelcontextprotocol/server-everything"]
      files:
        command: [npx, -y, "@modelcontextprotocol/server-filesystem", ~/scratch]
        env: {NODE_OPTIONS: "--no-warnings"}   # added to chi's environment
        cwd: ~/scratch                         # default: where chi runs
        tools: [read_*, list_directory]        # optional: only these (globs)
        timeout: 120                           # optional: this server's per-call timeout
```

- **Start.** When a session starts, each server is a service started at
  once, all side by side: the process is spawned, then `initialize`,
  `notifications/initialized` and `tools/list`. A server that doesn't start,
  answer or list its tools within `startup_timeout` is skipped, with a notice
  on the first turn (`mcp> warning: MCP server x didn't start: …`).
  The rest of chi works as usual.
- **Tools.** Each tool is the model's as `mcp_<server>_<tool>`, lower case,
  with anything but a-z, 0-9 and `_` made `_`, cut at 48 characters. A name
  that clashes is left out, with a notice. The tool's `inputSchema` is its
  schema (flattened on the native paths, see
  [Schemas on the native paths](#schemas-on-the-native-paths)); its label is
  `<server>: <tool>` and its preview the arguments, short.
- **Calls.** A call is `tools/call`. The text blocks of the answer are joined;
  an image, audio or a resource without text is a short placeholder
  (`[image: image/png]`). `isError` makes it `Error: …`. A call that takes
  longer than the timeout is an `Error:`, and a cancelled turn stops the
  wait; both send `notifications/cancelled` to the server.
- **A server that exits** fails its calls with `Error: MCP server x is not
  running (…)`, and there is one notice. It is not restarted until chi
  restarts (a new session, or the worker's next start).
- **Stop.** The servers stop with chi ([Shutdown](#shutdown)): stdin is
  closed, then TERM and KILL go to the server's process group.
- **`/mcp`** (anytime) shows a card with the servers, their state (running
  with its pid, failed, stopped) and their tools.
- The server's stderr goes to the debug log (`plugins` records, bundle=mcp).
- **Guardrails.** A rule's `tool:` can be a glob, so one rule covers every
  MCP tool:

  ```yaml
  guardrails:
    rules:
      - id: mcp-ask
        tool: "mcp_*"
        verdict: ask
        reason: an MCP server's tool
  ```

  An MCP tool has no `targets:`, so the question shows its arguments
  (`mcp_everything_get_sum: a=20 b=22`), and "Allow this call for the
  session" (or in this repo) allows that tool with those arguments only.

## Shutdown

When the REPL exits, or a session's worker exits (an idle exit, `/exit`, a
crash, TERM), chi shuts the session's Engine down:

1. The idle jobs (reminders, the recap) stop.
2. The anytime commands still running get up to 3 seconds, all together,
   to finish, so their output reaches the UIs.
3. The plugins' services stop, the newest first.

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
  chi's own tools; path and command rules see what `targets:` says.

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

- `chi.prompt` for sections of the system prompt.
