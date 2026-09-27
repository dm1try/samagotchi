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
  The web shows it in place of the tool's name, in its rows, step titles and
  tally (the mcp bundle's `chrome: screenshot`).
- `preview`: `->(args) { "…" }` for the activity line's parameters. The
  default is `key="value"` for each argument (a list or object as JSON). If
  it raises, the default is shown. Both are saved with the call's result, so
  a web page reloaded later shows the same row: the web server doesn't run
  plugins.
- `targets`: `->(args) { { paths: [...], command: "…", cwd: "…" } }`, each
  key optional, says what a call acts on, for [guardrails](#guardrails).

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
  (else the session's directory). `path:` globs, `outside_repo` and the
  protected paths (chi's config, …) match them.
- `command:`: a shell command the call runs; `command:` rules match it.
- `cwd:`: where it runs, for the repo root and relative paths.

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
- **`provides_tools: true`**: the task brings tools (with
  `chi.replace_tools`). A turn sent while it runs starts at once (the user's
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

In the web, a turn's block collapses when the turn ends. A `:warn` card, and
any card of a turn that ended without completing (cancelled, failed, the
worker gone), then moves out of the block, after the turn's end line, so it
stays in sight; a reload puts it in the same place. An `:info` card of a
completed turn stays in its step.

An [anytime command](#anytime-true)'s cards show as it shows them, after its
line, in every UI, whether a turn runs or not.

A worker keeps its last 20 cards and hook notices, for a UI that joins
later. The web shows them where they arrived after a reload (a turn's
notice as a row of its step, above the call it came before); the attached
TUI shows the cards and between-turns notices since the last turn when it
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
      chrome:
        command: [npx, -y, "chrome-devtools-mcp@latest", --slim, --headless]
        attach_image_paths: true               # the default; false leaves a path as text
        start: lazy                            # the default; eager: start it with every session
```

- **Start: from a cache, on the first call.** A server's `tools/list` is
  saved in the bundle's data dir (`$XDG_STATE_HOME/samagotchi/plugins/mcp/
  tools-<server>.json`), keyed by a digest of its `command`, `env` (names
  and values: only the digest is stored) and `cwd`. A session with a saved
  list registers the tools at once and **doesn't start the server**: the
  first call of one of its tools does (the call's row shows the wait). So a
  session that never uses MCP spawns nothing, and a new chat opens without
  waiting for `npx`. If the live list differs from the saved one, the saved
  one is replaced, and so are the tools, from the next turn on.
- **The first run** (no saved list, or the config changed) starts the
  server in an [init task](#chiinitlabel-provides_tools-false-quiet-false-timeout-nil--ctx--):
  every UI shows `Starting MCP server x (first run, saving its tools)`, and
  a turn sent meanwhile waits for its tools. A server that doesn't start,
  answer or list its tools within `startup_timeout` (each step) is a warn
  card, `…: failed`, and its tools are left out. The rest of chi works as
  usual.
- **Freshness.** A saved list older than a day is still used, and a quiet
  background task lists the tools again with a server of its own (then
  stops it), saves them, and replaces the tools if they changed. One worker
  does it at a time.
- **A cached server that doesn't start** (the command is gone, it crashes)
  fails that call with `Error: MCP server x didn't start: …` and one notice;
  later calls answer the same at once, and its tools are left out from the
  next turn. The saved list stays: the next session tries again.
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

- **Tools.** Each tool is the model's as `mcp_<server>_<tool>`, lower case,
  with anything but a-z, 0-9 and `_` made `_`, cut at 48 characters. A name
  that clashes is left out, with a notice. The tool's `inputSchema` is its
  schema (flattened on the native paths, see
  [Schemas on the native paths](#schemas-on-the-native-paths)); its label is
  `<server>: <tool>` and its preview the arguments, short.
- **Calls.** A call is `tools/call`. The text blocks of the answer are joined;
  audio or a resource without text is a short placeholder
  (`[audio: audio/wav]`). `isError` makes it `Error: …`. A call that takes
  longer than the timeout is an `Error:`, and a cancelled turn stops the
  wait; both send `notifications/cancelled` to the server.
- **Images.** An `image` block goes to the model as a picture
  ([Returning images](#returning-images): at most 4 per call, a line
  instead when the model can't see images). Its place in the text is a line,
  `[image 1: image/png, attached]`, so the model knows the order. A text
  block that is **only the absolute path of an image file** is attached too
  (`[image 1: screenshot.png, attached]` after the path), but only when the
  file is under the system temp dir or the server's `cwd`: a server's text
  can't pull in any image on disk. `chrome-devtools-mcp --slim` answers
  `screenshot` that way; without `--slim`, `take_screenshot` returns an image
  block. `attach_image_paths: false` on a server leaves such paths as text.
- **A server that exits** fails its calls with `Error: MCP server x is not
  running (…)`, and there is one notice. It is not restarted until chi
  restarts (a new session, or the worker's next start).
- **Stop.** The servers stop with chi ([Shutdown](#shutdown)): stdin is
  closed, then TERM and KILL go to the server's process group.
- **`/mcp`** (anytime) shows a card with the servers, their state (cached
  (not started), running with its pid, failed, stopped) and their tools.
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

  An MCP tool has no `targets:`, so the question shows its arguments,
  under the tool's label as its row shows it (`everything: get_sum: a=20
  b=22`; any plugin tool with a label is asked about by it), and "Allow this call for the
  session" (or in this repo) allows that tool with those arguments only.

## The loop-guard bundle

`chi bundle install loop-guard` installs the bundle shipped with chi. It is
written only against this API (`lib/samagotchi/bundles/loop-guard/plugin.rb`),
with `chi.on` hooks, and has no memory file.

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
    ignore_tools: [task_wait, task_get, delegate_result, list_sessions, list_reminders]
    mode: deny           # deny | notify: notify only warns, once per call per turn
```

Its hooks run at the default priority (100), after known-names (50), so in
known-names' `correct` mode loop-guard keys the corrected call.

Not caught (yet):

- near-duplicates, such as `find . -name 'config*'` after `'config.yml'`;
- loops across turns;
- alternating calls (A, B, A, B) that each return something new;
- thinking that goes in circles inside one long generation.

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
  `requires_chi`) into the built bundle.
- `chi bundle uninstall <name>`: removes the plugin with the bundle.

## Not yet

These are planned:

- `chi.prompt` for sections of the system prompt.
