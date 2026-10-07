# Plugins

A bundle can ship one Ruby file, its **plugin**, that adds slash commands,
tools, hooks and background setup to every session. Its hooks are ordinary
bundle hooks ([hooks.md](hooks.md)). Its commands and tools work like chi's
own.

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
requires_chi: ">= 0.1.28"    # optional: a gem-style requirement (">= 0.1.28, < 0.2"); the bundle's hooks/ check it too
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

This adds a slash command. `name` is `/name`: a lowercase letter first, then a–z, 0–9, `_` and `-`, at most 32 characters after the `/`.
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
  The web shows it in place of the tool's name, in its rows, step titles and
  tally (the mcp bundle's `chrome: screenshot`).
- `preview`: `->(args) { "…" }` for the activity line's parameters. The
  default is `key="value"` for each argument (a list or object as JSON). If
  it raises, the default is shown. Both are saved with the call's result, so
  a web page reloaded later shows the same row: the web server doesn't run
  plugins.
- `targets`: `->(args) { { paths: [...], command: "…", cwd: "…", acts_as: "…", args: {…}, label: "…" } }`,
  each key optional, says what a call acts on, for [guardrails](#guardrails).

The block returns the result text. If it starts with `Error:`, it counts as
a failure. If it raises, the model gets `Error: <message>`. To return images
too, see [Returning images](#returning-images).

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
  (else the session's directory). `path:` globs, `outside_repo` (measured
  from the session's repo, whatever the call's `cwd:`) and the protected
  paths (chi's config, …) match them.
- `command:`: a shell command the call runs; `command:` rules match it.
- `cwd:`: where it runs, for the repo root and relative paths.
- `acts_as:`: the tool a call stands for, when the tool runs other tools
  (the mcp bundle's `mcp_call`). Rules keyed by that tool's name match the
  call too, as well as rules on the tool's own name. It can't be one of
  chi's own tools or another bundle's tool: that is dropped (and logged).
- `args:`: the arguments it acts with (a Hash), when they aren't the call's
  own (a dispatcher's inner arguments). A call with no `command:` or
  `paths:` is asked about with them, and "allow this call" is keyed by them.
- `label:`: what the approval question names the call by (`github: x`), in
  place of the tool's `label` (or, with `acts_as:`, that tool's). Display
  only: rules and approvals don't read it. One line of at most 80
  characters, else it is ignored (and logged).

```ruby
targets: ->(args) { { acts_as: "mcp_#{args["server"]}_#{args["tool"]}", args: args["args"],
                      label: "#{args["server"]}: #{args["tool"]}" } }
```

An approval of an `acts_as:` call keys on the tool's own name as well
(`mcp_call>mcp_github_x:…`), so it never stands in for an approval of the
tool it acts as, nor that one for it. Hooks see the call's own name, and so
does loop-guard's `ignore_tools`.

A tool without `targets:` is matched by its name only. A `targets:` that
raises counts as nothing (it is logged). See [guardrails.md](guardrails.md).

#### Returning images

A tool can hand the model images too. The block returns a
`Samagotchi::Plugin::ToolResult`, which is the text plus `images:`:

```ruby
chi.tool "screenshot", "Take a screenshot of the page." do |_args, ctx|
  path = take_screenshot(ctx)                          # a PNG file
  Samagotchi::Plugin::ToolResult.new("Took a screenshot.", images: [{ path: path }])
end
```

- An image is `{ path: "/abs/file.png" }` or `{ bytes: png, name: "shot.png" }`
  (raw bytes, not base64). png, jpeg, gif and webp are sent; bmp, tiff and
  heic are converted if ImageMagick or sips is there. A large image is scaled
  down (`image.max_side`, `image.max_bytes`), like one the model `read`s.
- Each image is stored with the session (`images/`) and goes to the model
  after the tool's text, the same way a `read` of an image file does. The
  web tool row and the terminal show it.
- At most **4** images per result are attached; each one past that gets a
  line (`shot5.png is not attached: at most 4 images per tool result`).
- An entry that isn't `{path:}` or `{bytes:}`, or isn't an image, becomes an
  `Error: …` line for that image. The text and the other images still go.
- A model that can't see images (`vision: false`, or known text-only) gets a
  line instead of each image: `shot.png is an image; this model can't see
  images`. Say what the image shows in the text, if it matters then.
- `ToolResult` is a String, so hooks, the log and the activity line see the
  text as before.

#### When the tools change

The system prompt is built once, after the plugins load, so the server can
keep its cached prompt prefix. A plugin whose tools are known only later
declares them with [`chi.replace_tools`](#chireplace_tools--set--),
which rebuilds the prompt for the next turn when the set changed; that
costs the cache once. `chi.tools_changed!` alone says the tools changed
without replacing any.

### `chi.replace_tools { |set| … }`

The plugin's whole tool set, after `register` (from an init task, a
command, a tool call). The block declares tools on `set` with
`set.tool(...)`, which takes `chi.tool`'s arguments:

```ruby
@chi.replace_tools do |set|
  listed.each do |t|
    set.tool("idx_#{t[:name]}", t[:description], params: t[:params]) { |args, ctx| query(t, args) }
  end
end
```

- The set is **staged**: the session applies it at the start of the next
  turn, before that turn's system prompt, on the turn's own thread. So it is
  safe from any thread, and a turn never sees half a set.
- The plugin's tools not in the set go, new ones are added, and one whose
  schema or label changed is registered again. Unchanged ones stay as they
  are. If anything changed, the prompt is built again.
- A later set replaces an earlier staged one.
- A name that another bundle (or chi) has is left out, with a notice. A bad
  tool raises `ArgumentError` at once, as `chi.tool` does, and nothing is
  staged.
- Inside `register`, use `chi.tool`: `replace_tools` raises there.

### `chi.on(event, priority: 100) { |event, ctx| … }`

This is a bundle hook, the same as a `hooks/*.rb` file. See
[hooks.md](hooks.md#hook-events) for the events; on `:after_turn`,
`event[:present]` sets how the answer is shown in the web
([Presenting the answer](hooks.md#presenting-the-answer-display-only)). Its label is
`plugin.rb (bundle my-bundle)`. The block may take only the event. If it
raises, the error is logged and the hook is skipped.

To act from the block, use `ctx`: `ctx.notify`, `ctx.ask_user`,
`ctx.steer`, `ctx.stop_turn`, `ctx.stop_generation`. Inside the block they
act for **this event** (the `event[:notify]`… helpers that plain hooks in
[hooks.md](hooks.md) get are the same thing, and a plugin doesn't need them):

- `ctx.stop_turn` in a `:before_tool_call` block also denies the call the
  event is about.
- From `:after_turn` and `:session_end` there is no turn left:
  `ctx.steer`, `ctx.stop_turn` and `ctx.stop_generation` do nothing and
  return false.
- In a `:generation_progress` block `ctx.ask_user` asks no one (nil).

This holds on the block's own thread while it runs. A thread the block
starts doesn't inherit the event: there the helpers act as from a command,
on the session as it is when called ([The context](#the-context-ctx)), so
`ctx.steer` from it reaches whatever turn is running then.

#### Watching the stream

`chi.on(:generation_progress)` sees a response while it streams, in batches
(2000 chars or a second), and `ctx.stop_generation` cuts it while the turn goes on: the model is asked
again. The rules (the thread it runs on, keeping it fast, what a cut does)
are in [hooks.md](hooks.md#watching-the-stream).

```ruby
class Plugin
  LIMIT = 50_000

  def register(chi)
    chi.on(:generation_progress) do |event, ctx|
      next if event[:thinking_chars] < LIMIT

      # Once per generation: a cut generation fires no more.
      if ctx.stop_generation("it thought for over #{LIMIT / 1000}k chars")
        ctx.notify("thinking too long (#{event[:elapsed_ms] / 1000} s): cut", level: :warn)
      end
    end
  end
end
```

loop-guard's thinking watch is built on this ([The loop-guard
bundle](#the-loop-guard-bundle)).

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

### `chi.init(label, provides_tools: false, quiet: false, timeout: nil, failed: nil) { |ctx| … }`

Slow setup that must not hold chi's start: downloading a model, indexing a
repo, logging in, starting a server for the first time. `register` itself
should return at once (everything in it runs before the session's UI is
up), so it hands the slow part to `chi.init`. The block runs **on its own
thread** once the session can show it: in a worker right after its Bridge
is up (so a new web chat opens at once), in the REPL at its first prompt.

```ruby
class Plugin
  def initialize(settings = {})
    @model = settings["model"] || "small-embedder"
  end

  def register(chi)
    @chi = chi
    chi.init("Downloading #{@model}", provides_tools: true, timeout: 120) do |ctx|
      path = download(@model, into: ctx.data_dir) { ctx.cancelled? }   # stop when chi shuts down
      @chi.replace_tools do |set|
        set.tool("embed_search", "Search the repo by meaning.",
                 params: { query: { type: "string", required: true } }) { |args, _ctx| search(path, args["query"]) }
      end
      "#{@model} ready"
    end
  end
end
```

- **What the UIs show.** Every UI shows a running task (web: a spinner line
  over the composer, `mcp · Starting MCP server chrome (first run, saving
  its tools)…`; the attached TUI: its activity row; the REPL: a line) and a
  line when it is done: `✓` and what the block returned, a short summary
  (`chrome ready, 3 tools`), or `<label>: done` for anything else. A UI that
  joins while it runs sees it too.
- **A raise** is a warn card. Its title is `failed:`, short (`chrome didn't
  start`; the card shows the bundle beside it), and its body the message;
  without `failed:` the title is `setup failed` and the body
  `<label>: <message>`.
- **`provides_tools: true`**: the task provides what the plugin's tools
  need: tools of its own (with `chi.replace_tools`), or what fixed tools
  read (the mcp bundle's index of a first-run server's tools, which
  `find_mcp_tools` searches). A turn sent while it runs starts at once (the user's
  message shows), then waits for it **before its first model request**, so
  the model sees the tools; the UIs keep showing the task meanwhile. The
  wait lasts at most `timeout` seconds from the task's start (default 60).
  A Ctrl-C cancels the turn and ends its wait, but not the task, whose
  tools come with the next turn. A task that fails or ends late leaves the
  turn without its tools. Tasks without `provides_tools` never hold a turn.
- **`quiet: true`**: nothing is shown unless it fails (a background
  refresh).
- **`ctx.cancelled?`** in the block says chi is shutting down: the block
  should stop then. It is the task's own, not the running turn's.
- `ctx.notify` and `ctx.card` from the block show between turns, even while
  a turn runs.
- Each task runs once per session start. A `-p … --non-interactive` run
  starts them with its turn and shows nothing but the answer.

### `chi.ctx`

The plugin's context (the `ctx` its handlers get), for `register` itself:
its settings, log and data_dir, for example. A `ctx.notify` or `ctx.card`
while chi starts (inside `register`) is shown once the session's UI can show
it (a worker's Bridge is up, the REPL's first prompt), after the plugins'
load warnings; a UI that joins later still gets it.

### Names

A command or tool name that the session already has is a **load error**.
That includes a chi built-in and another bundle's name. Bundles load in
name order, so the first bundle keeps the name.

## The context: `ctx`

Every handler gets the plugin's context. There is one per plugin for the
session's life, and each read gives the session as it is now. It is a
plugin's one way to talk to the user and to the turn: the helpers below act
on the session now from a command, a tool, an init task or your own thread,
and for the event inside a `chi.on` block (see `chi.on` above).

Everything a plugin shows (notices, nudges, stop notices, questions) is
named by its bundle in every UI (`my-bundle> …`); the debug log keeps the
full label, `plugin.rb (bundle my-bundle)`.

| | |
|---|---|
| `ctx.session_id` | the session's id (nil before there is one) |
| `ctx.cwd` | the session's working directory |
| `ctx.repo_root` | the git checkout holding `cwd`, or nil |
| `ctx.scratch?` | whether the session is a `chi scratch` one (deleted when it ends) |
| `ctx.delegate?` | whether the session is a delegate child: a task another session handed over |
| `ctx.model` | the model the session runs on now: its resolved ref (`host:id`), right after `/model` too |
| `ctx.model_key` | that model's memory overlay key (`<name>.<key>.md`, what `memory_write current_model_only` writes) |
| `ctx.settings` | the bundle's settings, frozen |
| `ctx.data_dir` | `$XDG_STATE_HOME/samagotchi/plugins/<bundle>/`, created on first use. A session's own state goes in `sessions/<id>.json` or `sessions/<id>/` there: chi removes it when the session is deleted, discarded or pruned |
| `ctx.log` | `ctx.log.info(:event, key: value)`: debug-log records tagged `plugins`, with `bundle=<bundle>` |
| `ctx.messages` | the conversation, as a frozen copy, without the system prompt. While a turn runs, a session worker's (attached, web) adds that turn so far: its prompt, the model's text and the lines merged into it (no tool calls or thinking); the REPL's is the conversation before that turn |
| `ctx.messages_partial?` | whether `ctx.messages` leaves out a running turn (the REPL mid-turn), so a plugin can say what its answer is about |
| `ctx.notify(text, level: :info, fallback_for: nil)` | one line to the user, labelled by the bundle (`my-bundle> …`). Every UI shows it, during a turn (a tool, a hook) or between turns (a command). `fallback_for: :display` marks a line that repeats the answer's display (`event[:present]`), which a UI that renders the display leaves out: see [Hooks](hooks.md#what-a-hook-can-do-the-runtime). The keyword needs chi 0.35.0 (it raises on an older chi) |
| `ctx.card(title:, body: "", actions: [], level: :info, id: nil)` | a card in every UI, returning its id: see [Cards](#cards) |
| `ctx.ask_user(question:, options:, header: nil, allow_freeform: false)` | a single-select question through the question flow: `{selected:, freeform:, selected_indices:}`, or nil (no one to ask, cancelled, bad options) |
| `ctx.cancelled?` | whether the running turn was cancelled (a long tool should stop) |
| `ctx.steer(text)` | put text into the running turn: its own user message at the loop's next boundary, shown as `my-bundle> nudged: …`. The model reads it with a header naming your bundle (`[Steer from the my-bundle plugin, mid-task. …]`); the session keeps the raw text. Returns true when queued, false with no turn running (it never starts one; that is `ctx.sessions`' send). Dropped (logged) if the model answers or the turn ends first. Safe from any thread: an anytime command, a hook (false from `:after_turn`), your own |
| `ctx.stop_turn(reason)` | stop the running turn after a warn notice with the reason; true when it stopped one now. In a `:before_tool_call` block it also denies that call |
| `ctx.stop_generation(reason)` | cut the generation that is streaming: the turn goes on and the model is asked again ([hooks.md](hooks.md#watching-the-stream)). Shows nothing: post your own notice. True when it cut one now |
| `ctx.ask_model(messages:, prompt:, …)` | a side answer from the session's model: see [Side answers](#side-answers-ctxask_model) |
| `ctx.sessions` | fork, send to, read, list and stop other sessions: see [Other sessions](#other-sessions-ctxsessions) |
| `ctx.context` | attach outside text to this session and list it: see [Attached context](#attached-context-ctxcontext) |

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
  `→ /hello again`, to type. A button's command leaves no echo: the web
  sends it with `card: true` (`POST /api/sessions/:id/command`), its
  `command_queued` and `command_ran` carry `card: true`, and no UI shows
  its line; the web shows a bubble only when the command answers with
  text or fails.
- `level:` is `:info` or `:warn` (the warning colour).
- An `:info` card with no actions and a body of one short line (up to 160
  characters) is a notice: the web shows it as a one-line row,
  `▸ check-in: Nudged the model at 105 tool calls.`, that opens on a click,
  like a resolved question. A warn card, one with actions and one with more
  to read stay framed cards.
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

In the web, a turn's block collapses when the turn ends. A `:warn` card, and
any card of a turn that ended without completing (cancelled, failed, the
worker gone), then moves out of the block, after the turn's end line, so it
stays in sight; a reload puts it in the same place. An `:info` card of a
completed turn stays in its step.

An [anytime command](#anytime-true)'s cards show as it shows them, after its
line, in every UI, whether a turn runs or not.

A worker keeps its last 20 cards (questions included) and, apart, its
last 20 hook notices, for a UI that joins later; a question still waiting
for its answer is always kept. The web shows them where they arrived after a reload (a turn's
notice as a row of its step, above the call it came before); the attached
TUI shows the cards and between-turns notices since the last turn when it
joins. The worker saves them in the session's folder (`cards.json`, the same
caps), so they outlive it: the web shows them in place for a stopped
session, and the next worker (an idle exit, a restart, `chi sessions stop`
then a new turn) starts from them. Load warnings and a question still
waiting when the worker went are not saved.

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
ctx.sessions.read(id)      # => {id:, title:, status:, parent_id:, running:, messages:}
ctx.sessions.children      # => [{id:, short_id:, state:, branch:, last_reply:, reported:, ...}]
ctx.sessions.stop(id)      # one of this session's own children
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
- `children(all: false)` lists this session's children, newest first, as
  frozen Hashes: `{id:, short_id:, title:, state:, waiting:, live:,
  delegate:, cwd:, branch:, last_reply:, last_reply_at:, reported:,
  updated_at:, archived:}`.
  - `state` is `waiting` (a question or approval is open; `waiting` says
    which), `running`, `failed` (the last turn failed or the worker
    crashed), `stopped`, `done` (the last turn ended with a reply) or `idle`.
  - `delegate` is true for a `delegate` child, false for a fork. Archived
    children are listed only with `all: true`.
  - `branch` is the branch checked out in the child's folder (read from its
    `HEAD`, a short sha when detached; nil outside git). `last_reply` is the
    first line of its newest reply, and `reported` says whether this session
    was already given that reply (a delegate report or a wait).
  - It reads every session's file: call it on demand, not in a loop.
- `stop(id)` stops one of this session's own children, as
  `chi sessions stop` does, and waits up to 2 s for its worker to let go. It
  returns the child's id. Any other session raises.
- Each raises `Samagotchi::Plugin::Sessions::Error` with the reason.

## Attached context: `ctx.context`

```ruby
ctx.context.attach(url: "https://github.com/acme/app/pull/42", why: "branch feat/x has open PR #42")
ctx.context.attach(name: "ci", cmd: "bin/ci-status", why: "this branch's CI", every_seconds: 120)
ctx.context.list  # => [{name:, scope:, why:, hint:, fetched_at:, error:, provider:}]
```

[Attached context](context.md) for the session the plugin runs in: chi runs
the source's command every so often in the session's worker, and the model
gets a note when its text changes.

- `attach(url:, name: nil, why: nil)` goes through an installed bundle's
  provider (below); `name:` and `why:` replace the provider's.
  `attach(name:, cmd:, why: nil, hint: nil, every_seconds: nil)` attaches a
  command of the plugin's own. A source of that name already attached stays
  as it is. It returns the name, or nil when the user removed that name (or
  that URL) from the session: a plugin doesn't attach it again until the
  user adds it (`ctx.context.declined?(name)` says so).
- The source is the session's (not the project's), marked
  `added_by: plugin:<bundle>`. It is plugin code, so it isn't asked about as
  the agent's `chi context add --cmd` is.
- `list` gives the session's sources, its own then its project's.
- `attach` raises `Samagotchi::Plugin::AttachedContext::Error` with the
  reason (no session yet, no provider for the URL, a bad name).

The [github-pr bundle](#the-github-pr-bundle) attaches the branch's PR from
a quiet `chi.init` task.

### Context providers in the manifest

A bundle can turn URLs into sources for every process, without loading
plugins (`chi context add URL`, the web's "+ URL", `ctx.context.attach(url:)`):

```yaml
# manifest.yml
scripts:
  pr_context.rb: sha256:…        # scripts/pr_context.rb in the bundle
context_providers:
  - match: '\Ahttps://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)'
    name: 'pr-\3'               # \1… are match's groups; the result must be a source name
    cmd: '{ruby} {bundle_dir}/scripts/pr_context.rb {url}'
    why: GitHub PR               # optional
    every_seconds: 300           # optional, at least 30
```

- `scripts:` are files in the bundle's `scripts/` folder. Install copies them
  into the installed bundle (`<memories>/.bundles/<name>/scripts/`) and
  records their sha256; a script changed afterwards fails the source's
  fetch until the bundle is reinstalled. `rake bundles:sha` refreshes their
  lines in a shipped bundle.
- The first installed bundle (by name) whose `match` matches the URL makes
  the source. `{url}` is the part `match` matched, shell-quoted, filled in
  when the source is attached; `{bundle_dir}` stays in the stored command
  and becomes the installed bundle's folder each time it runs, so an
  upgrade moves nothing. `{ruby}` becomes the Ruby chi runs on (a `ruby` on
  the PATH may be another one, such as macOS's 2.6).
- The command follows [the contract](context.md#the-command-contract).

## The btw bundle

`chi bundle install btw` (or the `dev` profile) installs the bundle shipped with chi. It is written
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
  `$XDG_CONFIG_HOME/samagotchi/memories/btw.md` (`$XDG_CONFIG_HOME` defaults to
  `~/.config`) and its `**btw**` line in `index.md` there by hand.

## The mcp bundle

`chi bundle install mcp` (or the `dev` profile) installs the bundle shipped with chi. It is written
only against this API (`lib/samagotchi/bundles/mcp/plugin.rb`), and gives
the model the tools of [MCP](https://modelcontextprotocol.io) servers. It
has no memory file, and the servers' tools aren't declared to the model one
by one: it has two tools, `find_mcp_tools` and `mcp_call` (~250 tokens in
every request plus a line per server, whatever the servers have; `/mcp`
says how many). Stdio servers only, for now.

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
        description: files in ~/scratch        # optional: its line in find_mcp_tools
        timeout: 120                           # optional: this server's per-call timeout
      chrome:
        command: [npx, -y, "chrome-devtools-mcp@latest", --slim, --headless]
        attach_image_paths: true               # the default; false leaves a path as text
        start: lazy                            # the default; eager: start it with every session
```

- **Start: from a cache, on the first call.** A server's `tools/list` is
  saved in the bundle's data dir (`$XDG_STATE_HOME/samagotchi/plugins/mcp/
  tools-<server>.json`), keyed by a digest of its `command`, `env` (names
  and values: only the digest is stored) and `cwd`. A session with a saved
  list can search its tools at once and **doesn't start the server**: the
  first call of one of its tools does (the call's row shows the wait). So a
  session that never uses MCP spawns nothing, and a new chat opens without
  waiting for `npx`. If the live list differs from the saved one, the saved
  one is replaced, and so is what a search finds. The model's tools never
  change, so the prompt cache keeps. The saved file also keeps the first
  sentence of the server's `instructions` (from `initialize`), for its line
  in `find_mcp_tools`.
- **The first run** (no saved list, or the config changed) starts the
  server in an [init task](#chiinitlabel-provides_tools-false-quiet-false-timeout-nil--ctx--):
  every UI shows `Starting MCP server x (first run, saving its tools)`, and
  a turn sent meanwhile waits for its tools. A server that doesn't start,
  answer or list its tools within `startup_timeout` (each step) is a warn
  card, `…: failed`, and its calls fail until chi restarts. The rest of chi
  works as usual.
- **Freshness.** A saved list older than a day is still used, and a quiet
  background task lists the tools again with a server of its own (then
  stops it), saves them, and replaces the searched ones if they changed.
  One worker does it at a time.
- **A server that says its tools changed** (`notifications/tools/list_changed`)
  is asked for its `tools/list` again; the saved list and the searched tools
  are replaced.
- **A cached server that doesn't start** (the command is gone, it crashes)
  fails that call with `Error: MCP server x didn't start: …` and one notice;
  later calls answer the same at once until chi restarts, and a search shows
  its tools as `(failed: …)`. The saved list stays: the next session tries
  again.
- **`start: eager`** on a server starts it with every session (in an init
  task, after the Bridge is up), for a server whose start does something
  you want at once.
- **`npx -y …@latest` checks the npm registry on every start** (~3.4 s for
  `chrome-devtools-mcp`, against ~0.9 s for the installed binary). The cache
  hides it from new chats, but not from the first call. For a faster first
  call, install the server once and run it directly:

  ```yaml
  chrome:
    command: [chrome-devtools-mcp, --slim, --headless]   # after npm i -g chrome-devtools-mcp
  ```

- **Tools: search, then call.** The servers' tools are kept in an index;
  the model has two fixed tools:
  - `find_mcp_tools(query, server?)` searches it by keywords over the
    server's name, the tool's name and its description, and answers up to 5
    tools, each with its name `<server>/<tool>`, its description and its
    whole `inputSchema`. A word counts more the fewer tools have it (a word
    most of a browser server's tools share, "page", counts little), and
    three times as much in a name as in a description. An empty query (and
    a search with no match) lists every server's tool names, without
    schemas. A tool whose `inputSchema` (or a property's schema) isn't an
    object shows
    `(bad schema)` (and is said once, as a notice), a failed server's tools
    `(failed: …)`, a first-run server still starting `(starting, try
    again)`. Its description names each server on one line, never its
    tools: the server's `description:`, else the first sentence of its
    `instructions`, and how many tools it has (`- chrome (26 tools)` with
    neither: tool names there get called blind, without a search; a first
    run's server is just its name until the next session).
  - `mcp_call(tool, args)` calls one: `tool` is `<server>/<tool>`, and
    `mcp_<server>_<tool>` works too (looked up, not parsed). Two tools whose
    `mcp_<server>_<tool>` comes out the same (servers `git-hub` and
    `git_hub`, names alike up to the 48-character cut) are both refused,
    since guardrail rules and approvals couldn't tell them apart: a search
    and `/mcp` mark them `(name clash with …)`, and there is one notice.
    `args` are typed by the tool's
    `inputSchema` (numbers and booleans given as text, JSON text for an
    object). A name it doesn't know answers the closest ones (`Error: no
    MCP tool chrome/open_url. Closest: chrome/new_page, …`). Its row shows
    `mcp chrome/take_screenshot fullPage=true`.
  - A tool turn takes a few more steps than when every tool was declared
    (the P1 spike: about 1.5 more on a 30-tool server), and each request is
    smaller (about half there).
- **Calls.** A call is `tools/call`. The text blocks of the answer are joined;
  audio or a resource without text is a short placeholder
  (`[audio: audio/wav]`). `isError` makes it `Error: …`; it, a JSON-RPC
  error and `args` that aren't an object end with the tool's schema
  (`chrome/click's inputSchema: {…}`), so a call made without a search can
  be fixed on the next step. A call that takes longer than the timeout is
  an `Error:`, and a cancelled turn stops the wait; both send
  `notifications/cancelled` to the server.
- **Images.** An `image` block goes to the model as a picture
  ([Returning images](#returning-images): at most 4 per call, a line
  instead when the model can't see images). Its place in the text is a line,
  `[image 1: image/png, attached]`, so the model knows the order. A text
  block that is **the absolute path of an image file** is attached too
  (`[image 1: screenshot.png, attached]` after the text), and so is an
  absolute path ending in `.png`, `.jpg`, `.jpeg`, `.gif` or `.webp` inside
  a sentence (`Saved screenshot to /tmp/shot.png.`; such a path can't hold a
  space). Either way only when the file is an image by its bytes and is
  under the system temp dir or the server's `cwd`: a server's text can't
  pull in any image on disk. `chrome-devtools-mcp --slim` answers
  `screenshot` that way; without `--slim`, `take_screenshot` returns an image
  block. `attach_image_paths: false` on a server leaves such paths as text.
- **A server that exits** fails the call it was on with `Error: MCP server
  x is not running (…)`, and there is one notice. Its next call starts it
  again (its tools stay), up to 3 times a session; after the third restart
  the notice says so, and its calls fail at once until chi restarts (a new
  session, or the worker's next start).
- **Stop.** The servers stop with chi ([Shutdown](#shutdown)): stdin is
  closed, then TERM and KILL go to the server's process group.
- **`/mcp`** (anytime) shows a card with the servers, their state (cached
  (not started), running with its pid, failed with its count, stopped) and
  their tools as `<server>/<tool>`, the name `mcp_call` takes.
  A cached or running server's line says roughly how many tokens its tool
  definitions take (`~4,232 tokens`), which only a search's answer carries
  now; the last line says what every request carries (`find_mcp_tools` and
  `mcp_call`) and totals the servers'. It is an estimate:
  the definitions' JSON as the chat API gets it (`api: openai`), divided by
  4. The native prompts (Gemma, Qwen) render a flatter schema, so there they
  take less. The log records each server's estimate when it changes
  (`mcp_tools_estimated`).
- The server's stderr goes to the debug log (`plugins` records, bundle=mcp).
- **Guardrails.** A rule's `tool:` can be a glob, so one rule covers every
  MCP tool (a search is `find_mcp_tools`, outside `mcp_*`, so it isn't
  asked about):

  ```yaml
  guardrails:
    rules:
      - id: mcp-ask
        tool: "mcp_*"
        verdict: ask
        reason: an MCP server's tool
  ```

  `mcp_call`'s `targets:` act as the tool it calls, by its
  `mcp_<server>_<tool>` name ([acts_as:](#guardrails)), so `tool:
  "mcp_github_*"` or `tool: mcp_github_merge_pull_request` match an
  `mcp_call` to it, as they matched the tool when it was declared by that
  name. A call made before the server's tools are known (a first run
  still starting) is matched by the name the model gave, so the rule fires
  before the call waits; if the tool it then finds isn't that one, the
  call is refused. The question shows the inner arguments under `<server>: <tool>`
  (`everything: get_sum: a=20 b=22`), and "Allow this call for the
  session" (or in this repo) allows that tool with those arguments only.
  (Approvals stored before 0.6.0, under the old name, don't carry over.)
  Two things see `mcp_call`, not the tool: hooks (a `before_tool_call`
  event's `tool:` is `"mcp_call"`, the tool in its args), and loop-guard's
  `ignore_tools` (`mcp_call` ignores every MCP call; calls to different
  tools, or with different args, stay distinct, since the tool is in the
  args).

## The loop-guard bundle

`chi bundle install loop-guard` installs the bundle shipped with chi (`chi
bootstrap` installs it with the `core` profile). It is
written only against this API (`lib/samagotchi/bundles/loop-guard/plugin.rb`),
with `chi.on` hooks, and has no memory file. It guards two kinds of loop:
repeated tool calls (below) and [thinking that repeats
itself](#thinking-that-repeats-itself).

A local model can run the same tool call again and again in one turn: each
step's thinking starts over, so it never notices it already tried. (A real
one ran `find . -name 'config.yml'` ten times, getting nothing each time.)
loop-guard breaks that:

- A call is keyed by its tool and its arguments (whitespace collapsed), and
  its result by a hash of the output. When a call has already returned the
  same result `deny_after` times this turn (default 2), the next identical
  call is **denied** with advice, so the 3rd one is caught:

  ```
  [execute] Error: denied by guardrail (bundle loop-guard): repeated call. The user was not asked. You already ran this exact call 2 times this turn and it returned the same result each time (exit: 0 (no output)). Don't repeat it. Try a different approach, or tell the user what you're stuck on.
  ```

  The user sees one line per call per turn: `loop-guard> loop: execute find
  . -name 'config.yml' 2>/dev/null repeated, denied`.
- At the `stop_after`-th deny in a turn (default 4) the turn is **stopped**
  (core's own "stopped" notice), and a card lists the repeated calls, so the
  user can say what to try instead.
- A denied call has no result: a deny (loop-guard's, known-names', a rule's)
  never counts as the call's result, so the deny sticks.
- The counts are per turn, and a count is the turn's total, not a run of
  consecutive repeats: the loop usually has other calls in between. A new
  turn (a prompt, a continue, a reminder) starts from zero, since a new user
  message can make an old call right again. A steering message merged into
  a running turn doesn't reset them.
- The polling tools, where repeating is the point, are ignored.

```yaml
# config.yml
bundles:
  loop-guard:
    deny_after: 2        # same call, same result this many times: deny the next one
    stop_after: 4        # stop the turn at this many denies
    ignore_tools: [task_wait, task_get, delegate_result, list_sessions, list_reminders, context_read, forget_outputs]
    mode: deny           # deny | notify: notify only warns, once per call per turn
```

Its hooks run at the default priority (100), after known-names (50), so in
known-names' `correct` mode loop-guard keys the corrected call.

### Thinking that repeats itself

A model can also go in circles inside one generation: its thinking says the
same few sentences again and again ("Wait, let me check once more…") for
minutes, until the provider's output cap ends it with no answer. loop-guard
watches the thinking while it streams ([Watching the
stream](hooks.md#watching-the-stream)) and cuts it:

- The thinking is cut into sentences. Two sentences of `min_words` or more
  count as the same when their words and word pairs mostly match
  (`similarity`), so a reworded round ("Hmm, …", a synonym, a swapped
  clause) still counts.
- A loop is a cycle of 1 to `max_period` sentences seen `repeats` times in a
  row, over at least `min_span_sentences` sentences and `min_span_chars`
  chars; or one sentence `max_same` times anywhere in the generation. One
  sentence over and over must be near-identical (`similarity` + 0.4), and a
  longer cycle must hold different sentences: a list of templated sentences
  ("Now I need to open the file <path> and …" for 14 paths) is no loop.
- Short sentences (under `min_words`) are a loop of their own when
  `short_run` of them come in a row with at most `short_distinct` different
  ones among them ("I'll write it. Go. OK. Writing. Go. OK."). Normal
  thinking has short sentences too ("Hmm.", "Fine."), but spread out or all
  different (code lines); a longer sentence ends the run, and lines inside a
  ```` ``` ```` code block don't count.
- Any `window_sentences` sentences in a row, short or long, holding at most
  `window_distinct` different ones are a loop too: a cycle of 7 or 8 short
  sentences, or one where a longer sentence ("I'll write the spec file
  now.") keeps ending the short run. Real thinking holds 40 or more
  different sentences in any 48; DeepSeek's write loops hold 4 to 9.
- Nothing triggers before `min_chars` of thinking. The watch sees a loop
  within one batch (2000 chars, or a second) of its third cycle.

What happens (`action: retry`, the default):

1. The first loop in a turn: the generation is cut and the model asked
   again, with a hidden note that it was cut off. The user sees the loop's
   first sentence quoted,
   `loop-guard> thinking repeats itself ("Wait, the count of the letter r…", 3 sentences ×3, 4k chars, 8 s): cut`
   (a short run or a window says how many different sentences it held:
   "12 different sentences in 48"), and `↻ cut by loop-guard, asking again (1/1)`.
2. If the retry loops too, the turn is stopped ("stopped the turn: …", "■
   turn stopped by loop-guard") with a card that quotes the repeated
   sentences.
3. A loop is forgotten after `forget_after` good steps in a row (generations
   with no loop): a model that recovered and made progress gets its next
   loop cut and retried again, not the turn stopped. `forget_after: 0`
   never forgets: the turn's second loop stops it.

The cut uses the `retry.empty_answer` budget: with `retry.empty_answer: 0`
the first loop ends the turn as stopped by loop-guard, with the notice and
no card. `action: stop` stops the turn at the first loop; `action: notify` only
warns, once per generation.

The cut thinking never goes back to the model, but its last 20k chars are kept
in the session's folder, `thinking_tails.jsonl` (with a generation that ran to
the provider's output cap, or that a stop_turn ended): an archived session
keeps them. A turn's record counts its cuts and cap hits (`cuts`, `capped` in
`analytics.json`; `/stats` shows "thinking cuts" and "output cap hits").

```yaml
bundles:
  loop-guard:
    thinking:
      watch: true             # false: the tool-call guard only
      action: retry           # retry (cut, ask again; then stop) | stop | notify
      min_chars: 2000         # thinking this long before anything triggers
      repeats: 3              # a cycle seen this many times is a loop
      max_period: 6           # cycles of up to this many sentences
      similarity: 0.5         # 0..1, how alike two sentences must be to count as the same
      min_span_sentences: 6   # a loop spans at least this many sentences…
      min_span_chars: 600     # …and this many chars
      max_same: 8             # one sentence this many times in one generation is a loop
      min_words: 5            # shorter sentences only count toward a short run
      short_run: 24           # this many short sentences in a row…
      short_distinct: 6       # …with at most this many different ones is a loop
      window_sentences: 48    # any this many sentences in a row…
      window_distinct: 12     # …with at most this many different ones is a loop
      forget_after: 10        # good steps in a row that forget a loop; 0: never
```

Not watched:

- thinking that arrives as answer text: Gemma 4 on the raw-prompt path (no
  close marker), a chat provider that puts `<think>` in the content;
- a chat host with streaming off (no chunks);
- loops in the visible answer;
- a runaway without sentences, such as an endless comma list of numbers: it
  ends at the output cap as an empty answer, which `retry.empty_answer`
  retries after the fact.

A real small model's circular re-checking that repeats one sentence 8 times
is cut even if it would have found an answer later; `max_same` sets how
patient that is.

Not caught (yet):

- near-duplicates, such as `find . -name 'config*'` after `'config.yml'`;
- loops across turns;
- alternating calls (A, B, A, B) that each return something new.

## The check-in bundle

`chi bundle install check-in` installs the bundle shipped with chi (`chi
bootstrap` installs it with the `core` profile). It is
written only against this API (`lib/samagotchi/bundles/check-in/plugin.rb`):
`chi.on` hooks, `ctx.card`, `ctx.steer`, `ctx.stop_turn` and one anytime
command. It has no memory file.

A turn can run a long time on its own, reading and searching, without saying
what it has found. check-in counts the turn's tool calls, and when there are
`after` of them with no answer yet (then every `every` more) it checks in:

- **`mode: ask`** (the default): a card, one per turn, updated in place at
  each check-in: "50 tool calls, no answer yet", how long the turn has run
  and its last few tools, and three actions:
  - **Nudge** (`/checkin nudge`): puts `message` into the running turn
    (`ctx.steer`); the model reads it at its next step and answers or says
    what is left. Every UI shows `check-in> nudged: …`.
  - **Keep going** (`/checkin later`): closes the card until the next
    check-in.
  - **Stop** (`/checkin stop`): stops the turn.

  When the turn ends the card loses its actions ("The turn ended after N tool
  calls"), so no stale buttons stay. In the attached terminal the actions are
  `→ /checkin nudge` lines to type; the command runs beside the turn.
- **`mode: nudge`**: nudges the model by itself, with a notice line.
- **`mode: notify`**: a notice line only.

The count is per turn: a new turn (a prompt, a continue, a reminder) starts
from zero; steering merged into the running turn doesn't reset it. The polling
tools are not counted. A nudge that arrives after the model's final answer is
dropped (logged), never restarting a turn that is done; the card's "Nudged the
model at N tool calls" then becomes "The answer came first; nudge not sent."

```yaml
# config.yml
bundles:
  check-in:
    after: 50          # tool calls in one turn before the first check-in
    every: 50          # then again every this many more
    mode: ask          # ask | nudge | notify
    message: "You've made {calls} tool calls in this turn without answering. Say briefly what you've found so far and what's left, then answer now or continue."
    ignore_tools: [task_wait, task_get, delegate_result]
```

`{calls}` in `message` is the count. The default asks for what has been found
and what is left, not "how's it going?": a small model tends to answer that
with a line and carry on unchanged.

`/checkin` (anytime) for this session. What it changes (on/off, the mode,
the threshold) is saved with the session, in the bundle's data dir
(`plugins/check-in/sessions/<id>.json`), so it outlasts a worker's restart
and goes with the session; another session starts from config.yml:

| | |
|---|---|
| `/checkin` | on or off, the mode, the threshold and this turn's count |
| `/checkin on` / `off` | check in, or not |
| `/checkin 30` | check in after 30 tool calls, then every 30 |
| `/checkin mode ask` / `nudge` / `notify` | the mode |
| `/checkin nudge` / `later` / `stop` | the card's actions, also by hand |

## The skills bundle

`chi bundle install skills` (or the `dev` profile) installs the bundle shipped with chi
(`lib/samagotchi/bundles/skills/plugin.rb`): one anytime command, `chi.on`
hooks, `ctx.sessions.send`, `ctx.notify` and `ctx.steer`. It has no memory
file; skills themselves work without it ([docs/memory.md](memory.md#skills)).

| | |
|---|---|
| `/skill save [name] [--system]` | sends this session a request to save what was just done as `skill_<name>` (chi picks a name when none is given), project scope unless `--system`. The request holds the skill's shape, so the result is the same with a model that never read the memory guide. It runs as a turn; sent while a turn runs, it joins that turn at its next step (the request says to finish the task first). An existing skill is updated. In a `--no-shared` REPL, which takes no messages, the command shows the request to send yourself |
| `/skill list` | the `skill_*` memories of both scopes, with the date and description from the index |
| `/skill show <name>` | one skill as saved (project first, as `memory_read` looks) |
| `/skill diff <name> [N]` | the skill now against its N-th newest older version (default 1: before the last change), unified |

**History.** Before `memory_write`, `write` or `edit` changes a
`skill_<name>.md` in a memories folder, the file as it was is kept under
`$XDG_STATE_HOME/samagotchi/plugins/skills/history/<scope>/<name>/` (`system`,
or `project-<project folder>`), the newest `history_keep`. It is state, not a
memory: `chi bundle build` and a synced `~/.config` never see it. After the
call a line says what happened:

```
skills> skill release saved (project, 14 lines)
skills> skill release updated (+2 −1): 1. Run `scripts/verify.sh`; stop if it fails. · /skill diff release
```

The line is the file on disk changing, whatever the tool answered; a denied
write shows nothing.

A skill read in the turn is also watched for changes made another way (an
`execute` running `sed`, a script): after each other tool call, and at the
turn's end, its file is compared with the content last seen (at the read, or
after the last write). A change shows the same line, keeps the content last
seen as a version (so `/skill diff` has it) and counts as the skill updated.
A plain read keeps no version.

**The nudge** (`nudge: true`). Some models, finding a skill's step broken,
skip it and go on without fixing the skill. In a turn that read a skill
(`memory_read` of a `skill_*` name, or `read` of its file), the first failing
tool call after it (an `execute` that exited non-zero, a tool error) steers
the model once (a call a guardrail or the user denied doesn't count as a
failed step): *"A step of skill release failed. Find out why before skipping
it; if the skill is out of date, fix it now: edit the step that changed in
its file (or memory_write the whole skill) and add a Changelog line."* No
steer once a skill read this turn has changed, by any tool. If the turn ends
with a failed step and no skill read changed, one line says so: `skill
release was followed, a step failed, the skill wasn't updated`. A failure
unrelated to the skill (a test
meant to fail) can set it off too: once per turn, and only after a skill was
read.

```yaml
# config.yml
bundles:
  skills:
    history_keep: 20   # older versions kept per skill
    nudge: true        # steer once when a followed skill's step fails
```

## The github-pr bundle

```sh
chi bundle install github-pr      # in the dev profile; needs gh, logged in
```

Attaches the branch's open GitHub pull request to a session as `pr-<n>` when
its worker starts (not in a scratch session or a delegate child; quietly
nothing without `gh`, a repository or an open PR), and resolves PR URLs for
`chi context add` and the web's "+ URL". Its script prints the PR as text
and a summary of what changed in counts, authors and states only; it wakes
the session for a review requesting changes, checks turning red, or the PR
merged or closed. In the web, a `path:line` in an answer links to that line
of the session's PR ([Line links](context.md#line-links)). See [Attached
context](context.md#github-prs-the-github-pr-bundle).

## The coordinator bundle

```sh
chi bundle install coordinator    # in the dev profile
```

chi as a coordinator of parallel work, the way you would run several agents
yourself: split the work, one git worktree and child session per task, keep
talking while they run, check each report, and merge only with your OK. It
works in a session with a worker (plain `chi`, the web). A `--no-shared` REPL
or `-p` gets no delegate reports, so the children's replies wouldn't come back
by themselves there.

- **The skill.** `skill_coordinator` (system scope; its index line says what
  it is for, from the manifest's `description:`) holds the steps. The model
  creates each worktree with `execute` (`git worktree add ../<repo>-<task> -b
  <branch>`), starts a child there with `delegate wait: false, cwd:`, tells
  you what started and ends its turn. When a child's report comes, it checks
  the branch (`git log`, `git diff --stat`, the tests the child names) before
  telling you. It asks before each merge (`ask_user_question`), checks that its
  own folder is on the default branch and that branch's log first (another
  agent may have merged the branch already), merges `--ff-only` and never
  pushes unless you ask. After a merge it stops the
  child and removes only the worktrees and branches it made.
- **A handoff memory.** The conversation is lost when the session ends, so
  the skill keeps a project memory `handoff_<epic-slug>` with only what git
  and the session list can't rebuild: the split (branch, worktree, child id
  per task), your decisions, its verdicts and the follow-ups. Its index
  description is the status, descriptive only and naming the session that
  owns it ("OPEN coordinator handoff calc-v2 (session ab12cd34): 2/3 merged",
  later "DONE: …"): every session in the repo sees that line. The model saves
  a decision there before acting on it, and changes the status with
  `memory_write`'s description-only form. When everything is done it marks
  the handoff DONE and asks whether to remove it (`memory_write remove:
  true`, which the guardrails bundle asks you to confirm). Children are told
  not to touch it.
- **Resume.** A new coordinator session (or one asked "where were we?")
  reads the open handoff, checks it against git and the session list (git
  wins; mismatches are reported) and goes on from the first open step.
- **`/coordinate <goal>`** sends this session a turn asking the model to
  follow the skill for the goal (in a `--no-shared` REPL it shows the text to
  send yourself). Asking "do this in parallel" works too: the index line leads
  the model to the skill. **`/coordinate resume`** asks it to resume this
  project's open handoff; with several open it shows a card with a Resume
  action each (`/coordinate resume <name>` picks one), with none it says so.
- **`/children [all]`** shows the session's children as a card, newest first,
  one line each: `` `ab12cd34` · running · fix/flaky · "fix the flaky spec" ``,
  `` `9a8b7c6d` · done · feat/x · reported · "All 12 specs pass" `` (`not
  reported yet` when the parent wasn't given that reply), `` `77aa66bb` ·
  waiting (approval) · open it: chi --attach 77aa66bb ``. A fork is marked
  `fork`; `all` adds archived children. It runs during a turn too. The card
  has Refresh and a `Stop <id>` per running or waiting child (up to 5);
  `/children stop <id>` stops one of this session's own children (by session
  id, as `chi sessions stop` does) and shows the card again.
- **Children stay in their worktree.** A child asks before it changes
  anything outside its worktree (your checkout, a sibling's), in every
  guardrails mode and without the guardrails bundle ([a delegate child's
  boundary](guardrails.md#a-delegate-childs-boundary)); you answer on its
  card, or on the parent's while it waits.
- **Merges.** The parent's merge in its own checkout is a plain `git
  merge`; to be asked before every merge, add a rule ([Rules in
  config.yml](guardrails.md#rules-in-configyml)):

  ```yaml
  guardrails:
    rules:
      - id: git-merge
        tool: shell
        command: '\bgit\s+merge\b'
        verdict: ask
        reason: merging a child's branch
  ```

## Shutdown

When the REPL exits, or a session's worker exits (an idle exit, `/exit`, a
crash, TERM), chi shuts the session's Engine down:

1. The idle jobs (reminders, the recap) stop.
2. The plugins' init tasks are cancelled (`ctx.cancelled?` turns true).
   They and the anytime commands still running get up to 3 seconds, all
   together, to finish, so their output reaches the UIs; an init task
   announces nothing after this.
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

A plugin that fails to load is shown on stderr at start, and in every UI as
soon as the session's UI is up (`plugins> plugin plugin.rb (bundle x) failed
to load (…)`); a UI that joins later gets it too. The rest
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
  `requires_chi`, its `scripts/` and `context_providers:`) into the built
  bundle.
- `chi bundle uninstall <name>`: removes the plugin with the bundle.

## Not yet

These are planned:

- `chi.prompt` for sections of the system prompt.
