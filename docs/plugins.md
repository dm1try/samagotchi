# Plugins

A bundle can ship one Ruby file, its **plugin**, that adds slash commands,
tools, hooks and background setup to every session. Its hooks are ordinary
bundle hooks ([hooks.md](hooks.md)). Its commands and tools work like chi's
own.

This is the first version of the plugin API. More of it comes later: see
[Not yet](#not-yet).

Writing a bundle? Start with [bundle-authoring.md](bundle-authoring.md): the `chi bundle new` / `test` / `check`
loop, the event shapes, the kit, the pitfalls.

## A bundle with a plugin

```
my-bundle/
  manifest.yml
  plugin.rb
  identity.md        # optional, like any bundle's memories, hooks/ and guardrails/
  README.md          # never a memory (nor CHANGELOG, LICENSE, ...): see memory.md#what-a-bundle-owns
```

```yaml
# manifest.yml
name: my-bundle               # the bundle's name for every source (a git URL too): a plain name, no / (not . or ..)
version: 1.0.0
plugin:
  file: plugin.rb
  sha256: sha256:6a1a7022…   # shasum -a 256 plugin.rb
requires_chi: ">= 0.1.28"    # optional: a gem-style requirement (">= 0.1.28, < 0.2"); the bundle's hooks/ check it too
# requires_chi_next: true    # shipped bundles only, ignored by chi: rake release:bump raises requires_chi
                             # to the chi being released (docs/releasing.md)
session_settings: [cap]      # optional: the settings a session may set (chi --set my-bundle.cap=3);
                             # {cap: number} types them: number (or off), boolean, string or any
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
`bundles:`, as one Hash with string keys. It runs once, when the plugin loads, before any session: it never
sees a session's own `--set` values. A value a session may set is read from `ctx.settings` in the handler or
command that uses it (see [Per-session settings](#per-session-settings)).

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

Any whitespace may follow the name, a newline too: `/hello` on its own line
with text under it runs `/hello` with that text as `args` (its inner lines,
blank lines and indentation as typed; only the ends are stripped).

#### `anytime: true`

A plugin's normal command waits for its turn: typed while a turn runs, it is
refused as busy (the REPL puts it back into the prompt, the web into an empty composer; a plugin command can't
ask to run after the turn, as the built-in `/model X` does). An `anytime: true` command
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
(`/stats`, `/exit`, `/detach` …), marked where they run: `terminal only`,
`attached only`, `repl only`, or `terminal and web only` (`/cut`).
It works in all three UIs.

### `chi.annotation(label, command:, template: "{quote}", send: false)`

This adds a pill to the web's selection bar. Selecting text in an answer, a
thinking block, a step, a tool row or your own message shows
`[ Annotate | <presets> ┊ <plugin pills> ]`; a plugin pill prepares a command
line of the plugin from the selection:

```ruby
chi.command "/claude", "…", anytime: true do |args, ctx| … end
chi.annotation "Confirm with Claude", command: "/claude validate"
```

Clicking it on a thinking line fills the composer with

```
/claude validate
From your thinking:
> the quoted line

```

and the caret goes under the quote, for your note; Send runs `/claude` with
everything after the name as `args`.

- `label`: the pill's text, 1–40 characters. Its tooltip adds the bundle.
- `command:`: `/name` or `/name words`, and `/name` must be a command **this
  plugin** registers (checked once `register` returns, so the order of the
  calls doesn't matter; another one's is a load error). At most 5 per plugin.
- `template:` goes on the lines under the command line, filled in the
  browser: `{quote}` the labelled quote block Annotate makes, `{text}` the
  selection alone, `{source}` where it came from (`answer`, `thinking`,
  `step`, `tool`, `user`). Another `{x}` stays as written. Each line's
  trailing blanks and the blank lines at either end are dropped, and
  indentation is kept (code stays indented).
- **Fill** (the default) never sends: an empty composer gets the line; a
  composer that already starts with the same command line gets the quote
  appended (several selections collect under one command); any other draft
  stays, under the command line and the quote.
- `send: true` sends the line at once (the pill is marked ↗). While a turn
  runs, such a pill is disabled unless its command is `anytime`: it would
  come back busy. A fill pill always works; a typed command refused as busy
  comes back into the composer.

Pills ride on their command's listing (the worker's snapshot): a muted
bundle's go with its command, and a session's pills need a worker started
after the bundle was installed. Up to 3 show inline, the rest behind `⋯`.
Web only: the terminals type the command (`/claude validate <text>`).

### `chi.tool(name, description, params:, schema:, label:, preview:, targets:, refs:) { |args, ctx| … }`

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
- `refs`: `->(args) { [{ kind:, target:, label:, actions: [] }, …] }`, what the call's row traces to in the web
  (display only, the model never sees them). See [Refs on a tool's row](#refs-on-a-tools-row).

The block returns the result text. If it starts with `Error:`, it counts as
a failure. If it raises, the model gets `Error: <message>`. To return images
too, see [Returning images](#returning-images).

#### `args`

`args` is a frozen Hash with **string keys**: the arguments the model gave,
by name (`args["text"]`). The same Hash goes to `preview`, `targets` and `refs`.

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
  (chi's `call_tool`, which calls a tool a [source](#chitool_sourcecall-acts_as-label-wait-prefix) published). Rules keyed by that tool's name match the
  call too, as well as rules on the tool's own name. It can't be one of
  chi's own tools or another bundle's tool: that is dropped (and logged).
  The "another bundle's tool" drop doesn't apply to chi's `call_tool`: its
  `acts_as` is always a tool its sources published.
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
(`call_tool>mcp_github_x:…`), so it never stands in for an approval of the
tool it acts as, nor that one for it. Hooks see the call's own name, and so
does loop-guard's `ignore_tools`.

A tool without `targets:` is matched by its name only. A `targets:` that
raises counts as nothing (it is logged). See [guardrails.md](guardrails.md).

#### Refs on a tool's row

`refs:` gives the call's web row its refs: a ticket the tool looked up, the PR it opened, a file it wrote.
Each is a ref as on the answer ([Refs on the answer](hooks.md#refs-on-the-answer-display-only), without
`match:`):

```ruby
chi.tool "ticket", "Look up a Jira ticket", params: { id: { type: "string", required: true } },
         refs: ->(args) {
           [{ kind: "issue", target: { id: args["id"] }, label: "#{args["id"]} in Jira",
              actions: [{ id: "open", label: "Open in Jira", url: "https://jira.example/browse/#{args["id"]}" }] }]
         } do |args, ctx|
  # …
end
```

- `kind`: `"file"` with `target: { path:, line:, end_line: }`, or any short lowercase word (`issue`,
  `commit`, …) with `target: { id: }`.
- A file's `path` is absolute or relative to the session's folder, and must be **under** it (its own
  spelling or its real path: `/tmp/x` or `/private/tmp/x`): a file elsewhere is dropped. It is kept under
  the folder's real path.
- `actions`: up to 8 `{ id:, label:, url: }`, each URL `http(s)` only. A file ref keeps the editor, show in
  turn and copy; its actions add to them.
- The web puts the row's **first** ref on its title (a click runs its first action) and the others in the
  title's `▾` menu, each as `<its label> · <action>` with the URL on hover. URL actions show for every viewer,
  the phone too; a file's "Open in editor" only where the editor opens (this machine).
- It runs **once per call, on the tool path**, before the call runs: keep it cheap, with no I/O (no
  network, no file reads); build the refs from `args` alone.
- If it raises or returns something other than a list, the row gets no refs and the tool still runs; a bad
  ref (an unknown kind, a `javascript:` URL, a file outside the folder) is dropped. Both are logged (tag
  `plugins`, `tool_refs_failed` / `tool_refs_rejected`).
- At most 20 refs per row (64 KiB of them). They are saved with the result (`tool_refs`), so a reload shows them without the
  plugin, checked again.
- `chi.replace_tools` swaps a kept tool's block, `preview:`, `targets:` and `refs:` in place: none of them is a
  change to the prompt.

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
([Presenting the answer](hooks.md#presenting-the-answer-display-only)) and `event[:refs]`
attaches refs to it ([Refs on the answer](hooks.md#refs-on-the-answer-display-only)); on
`:question_asked`, `event[:refs]` attaches refs to the reply that asks a question
([Refs on a question](hooks.md#refs-on-a-question-display-only)). Its label is
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
  ends. The mcp bundle also stops a server that doesn't (see
  [The mcp bundle](#the-mcp-bundle), Stop).

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
  `find_tools` searches). A turn sent while it runs starts at once (the user's
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

### `chi.toolkit(name, base:, add: [], remove: [], prompt: nil, groups: nil, description: nil)`

A toolkit sessions can be put on: `base`'s tools (`full`, `lean`, `child`, a
config or bundle toolkit) with `add` declared and `remove` left out, and
`prompt`: text the sessions on it get in their system prompt, verbatim (nil
inherits the base's, `""` clears it; at most 2000 characters, and one that
isn't a String or is longer is a load error). `groups` selects the source
groups the toolkit reaches (names or globs, sorted and deduplicated; nil
inherits the base's, `[]` reaches none, and `:all` reaches every group; anything
else, a map say, is a load error). `description` is optional classifier text
(up to 300 characters); it is not included in the session prompt.
Groups match against the tool index's load-time names. Users pick
it like chi's own (`chi --toolkit NAME`, `toolkit.default`, `/toolkit NAME`),
and the plugin with `ctx.use_toolkit` (below). Names are `a-z`, `0-9`, `_` and
`-`; one chi has (`full`, `lean`, `child`) or another bundle declared is a
load error. A session saved on a toolkit whose bundle is gone declares every
tool (full) until it comes back, with a warning at its first turn. See
[Toolkits](configuration.md#toolkits). `prompt:` needs chi 0.72.0 (an older
chi refuses the keyword, a load error: a bundle that passes it sets
`requires_chi: ">= 0.72.0"`). `groups:` needs chi 0.121.0: an older chi refuses that keyword
too, so a bundle passing it sets `requires_chi: ">= 0.121.0"` (`chi bundle check` warns on a lower one).

```ruby
chi.toolkit "review", base: "lean", add: %w[delegate delegate_result]
chi.toolkit "coding", base: "child", prompt: "- Be concise in your responses"
chi.toolkit "web", base: "lean", groups: %w[chrome db*]
```

### `chi.prompt_section(name) { |ctx| … }` and `chi.prompt_changed!`

Text the session's system prompt carries, from a plugin: the block gets the Context and returns a String (at most
2000 characters, stripped) or nil for no section. Each goes into the prompt's stable part right after the
toolkit's prompt text and before the memory indexes, as `From <bundle> (<name>):` and the text, sorted by
(bundle, name). With no section (every block nil, or no plugin uses it) the prompt is exactly what it was without.
`name` is `a-z`, `0-9`, `_` and `-` (at most 32), once per bundle.

The block runs when the prompt is built: a session's first turn, after `/model` (so `ctx.model` and
`ctx.model_key` are the new model's), after `chi.prompt_changed!` or a tools change. Never per request, and on
whatever thread builds, so keep it quick and thread-safe (no I/O beyond reading a small file). **Same inputs, same
text**: anything that differs (a time, a random pick, a count) breaks the model server's prompt cache at the next
build. A block that raises, returns something other than a String or nil, or text over the limit keeps that
section's last good text for the session (one warn in the debug log, `prompt_section_failed`); with none yet the
section is left out. A deliberate nil removes it.

`chi.prompt_changed!` says your section would give other text now (the user picked another setting): the prompt is
built again at its next build, the next turn's start (a running turn keeps the prompt it started with). That
restarts the prompt cache for the whole conversation, so call it only once a change applies.
Keep `chi` from `register` for that (`@chi = chi`). `/stats` names the sections the prompt holds
(`prompt sections: tone (tone)`). The test kit runs them as a build does (`bundle.prompt_text`,
`bundle.prompt_sections`) and counts `chi.prompt_changed!` (`bundle.prompt_changes`). Needs a chi newer than
0.130.1: a bundle using it sets `requires_chi`.

```ruby
def register(chi)
  @chi = chi
  chi.prompt_section("tone") { |ctx| preset_text(ctx.model_key) }   # nil: no section
end
```

### `chi.tool_source(call:, acts_as:, label:, wait:, prefix:)`

Tools the model reaches through a search instead of declaring them one by
one: the plugin publishes them into chi's **tool index**, and chi declares
two tools in all, whatever the number of sources: `find_tools(query,
group?)` (a keyword search that answers each match's `inputSchema`) and
`call_tool(tool, args)` (calls one as `<group>/<tool>`; its row label is the
first source's `label`). The index has one group of its own, **`chi`**: the
built-ins the session's toolkit leaves out but doesn't remove
([toolkits](configuration.md#toolkits)), each with its registered schema.
The two tools are registered once, after the plugins load, and declared per
toolkit when it reaches a source group or has a reachable built-in (`full`
with no source declares neither). Nothing a
source publishes later changes the request's tools, only what a search
answers, so the prompt cache keeps: the search tool's description lists the
source groups as they were at load, and a `chi` line first, per toolkit.
The mcp bundle is the only source so far (a group per server). `groups:`
filters the groups find_tools searches, the source descriptions in the
request, and the MCP tools `call_tool` can reach. Its group snapshot is
filtered again at each toolkit change; new groups published after load do
not alter that prompt description. An unreached MCP tool call is refused
before the guardrails without starting the server; a deferred stub says to
switch to a toolkit that reaches its group. `/mcp` marks servers outside the
session's toolkit. A source's
group named `chi`, or named like an earlier group, is left out of search,
lookup and the description, with one warning per name.

**A built-in through `call_tool` runs as that built-in.** `call_tool(tool:
"chi/delegate", args: {…})` (or a bare `delegate` while it's reachable) is
turned into the `delegate` call itself before the guardrails, so rules on
`delegate`, approvals (keyed `delegate:…`, the same as a direct call's),
`before_tool_call`/`after_tool_call` hooks and the row see `delegate`, with
`call[:via] == "call_tool"`; the row reads "delegate (via call_tool)", live
and after a reload. `tool: call_tool` rules see MCP calls and misses only. A
`chi/` name the toolkit removes or declares, or any built-in once
`call_tool` itself is removed, is refused by its name before the guardrails
(no hook, no card).

**On a Messages host the model calls them by name too.** With `api:
anthropic` (not Fireworks' dialect), every tool `call_tool` reaches goes in
the request's tools deferred (`defer_loading`: its name only, until
something loads it): a built-in by its name, a source's tool by its
`acts_as` (`mcp_fs_read`; one with a refusal, an acts_as two tools share, or
a name another tool has stays out). A direct call of one runs whether
anything loaded it or not: a built-in as itself (as if declared), a
source's tool as the `call_tool` call it stands for, so its rules,
approvals, hooks and row are `call_tool`'s. Elsewhere such a call is
refused with the `call_tool` route, as before.

```ruby
@source = chi.tool_source(label: "mcp", prefix: "mcp_",
                          call: ->(tool, args, ctx) { run(tool, args, ctx) },  # the result, as a tool block's
                          acts_as: ->(group, tool) { "mcp_#{group}_#{tool}" }, # what rules match
                          wait: ->(group) { start_of(group).value })           # a :starting group's start
index = Samagotchi::Tools::ToolIndex
@source.publish([index::Group.new(name: "fs", summary: "files in ~/scratch", tools: [
                   index::Tool.new(group: "fs", name: "read", description: "Read a file.", schema: read_schema,
                                   acts_as: "mcp_fs_read")
                 ]),
                 index::Group.new(name: "chrome", state: :starting)])
```

- **`publish(groups)`** swaps in the plugin's whole list, from any thread, at
  any time (a server that started, `list_changed`): a search sees the old
  list or the new one, never half. A `Group` has a `summary` (its line in
  `find_tools`' description), a `state` (`:ready`; `:starting`, its tools may
  still come: a call to it waits on `wait`, a search says "starting, try
  again"; `:failed` with its `error`) and its tools. A group exists before its
  tools do. A `Tool`'s `refusal` says why `call_tool` refuses it (nil: it can
  be called), its `mark` what a search shows beside its name: the plugin
  decides both (the mcp bundle: a bad schema, a name clash) and publishes
  them again when they change.
- **`call`** gets a call chi looked up and checked: the `Tool`, its `args`
  typed by its `inputSchema`, and the plugin's `ctx`. It returns what a tool's
  block returns (a String, a `ToolResult` with images).
- **Guardrails** see a `call_tool` as the tool it calls: its `acts_as`, its
  arguments and `"<group>: <tool>"` as the question's label
  ([acts_as:](#guardrails)), even when another bundle has a tool of that
  name (only the core-tool drop applies). A call made before its tool is published is
  named by `acts_as` from the names alone; a bare name with `prefix` is
  taken as an `acts_as` as given (without `prefix`, a bare name is refused:
  call it as `<group>/<tool>`). The `acts_as:` hook must give exactly the
  `acts_as` the source publishes for that tool: a call whose tool isn't the
  one guardrails were given is refused ("the tool list changed while the call
  waited"), so a hook that disagrees refuses every call.
- **The row** shows `label` (default: the bundle's name) and
  `<group>/<tool> args…`. `@source.declared_names` and `declared_tokens` say
  what the two tools take in every request (none when other tools had both
  names). A `Group` in a state other than the three, holding another group's
  tool, or a `Tool` with a blank `acts_as` raises `ArgumentError`.
- `find_tools` and `call_tool` aren't chi's own tools: a toolkit that needs
  them declares them (unless its `remove:` names one; `call_tool` stays
  usable with `find_tools` removed). A bundle that declares tools of other
  names itself (an mcp bundle before 0.7.0 has `find_mcp_tools` and
  `mcp_call`) keeps them; with no source, `full` declares neither of chi's.

### `chi.peer_source(name, label:)`

Declares a context source as a peer agent's answers: the peer bundles'
`claude-outbox` and `codex-outbox`. Such a source, when it is a pushed source
of the session's own, wakes the session by the peer loop's rules instead of
the 10-minute window: up to `context.peer_turns` wake turns in a row, one
closing wake (outside that count) for an answer whose verdict is `VERDICT OK`,
and a wake line that names the peer and keeps the turn within the user's task (see [Waking: peer
sources](context.md#peer-sources-the-peer-loop)).

```ruby
chi.peer_source "codex-outbox", label: "Codex"
```

- `name`: a context source name (as `chi context add` takes it). Another
  bundle's is a load error.
- `label:`: the peer's name, said in chi's own lines ("your peer agent
  Codex"): a capital letter, then up to 23 letters and spaces.

The declaration lives in the session's process only, like a tool: a source
file can't make itself a peer's, and uninstalling the bundle ends it.
Subclasses of `Samagotchi::Plugin::Peer` (below) declare their `OUTBOX`
source. Needs chi 0.67.0 (guard it with `chi.respond_to?(:peer_source)`).

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
| `ctx.frontend` | what runs the session, read now: `:repl` (the REPL, `-p` without `--non-interactive`), `:one_shot` (`-p --non-interactive`: one turn, then exit) or `:worker` (a session worker: the web, an attached TUI). Only a worker's answers reach the web while it runs; a REPL's show there once the session is opened. Until the host sets it (while the plugins load, inside `Engine.new`) it reads `:one_shot`, so read it in hooks and init tasks, not in `register` |
| `ctx.fork?` | whether the session is a fork (`ctx.sessions.fork`): it has a parent but isn't a delegate child, and started from a conversation, so its first prompt isn't its first user message |
| `ctx.model` | the model the session runs on now: its resolved ref (`host:id`), right after `/model` too |
| `ctx.model_key` | that model's memory overlay key (`<name>.<key>.md`, what `memory_write current_model_only` writes) |
| `ctx.cost` | the session's spend so far, read now, as a frozen value: `total` (USD, reported + estimated, side requests included; 0.0 before any), `reported` (by providers, `usage.cost`), `estimated` (from `hosts.<name>.models` prices; a generation is one or the other, never both), `side` (recap, `/btw`, `ask_model`: their share of `total`) and `known?` (false while generations or side requests ran but none was reported or priced, so a limit on it can't be enforced; a session with some priced generations reads known, the unpriced ones counting 0). It includes the running turn's finished generations and what earlier workers of the session spent. Use its methods, not its class. Needs chi 0.83.0 |
| `ctx.usage` | the session's work so far, read now, as a frozen value: `turns` (finished ones and the running one), `tool_calls` and `tool_calls_by_tool` (every call, running ones included; canonical names: an alias counts under its tool, a `call_tool` call under the inner tool), `steps` (the loop rounds that dispatched tools, `/stats`' iterations) and `active_ms` (`active_minutes` too): work time, the generations' time plus the finished tool calls' time, never the waits between them (a question, an approval, the user's answer to `ask_user_question`), with `tool_ms_by_tool` its tool part by tool, so a waiting tool's time (`task_wait`) can be left out. Its counts are the ones `/stats` and `chi sessions stats` show, earlier workers' included. Use its methods, not its class. Needs chi 0.100.0 (guard it with `ctx.respond_to?(:usage)`) |
| `ctx.turn_author` | who wrote the running turn when it isn't the session's owner: a participant's `"p:<id>"` (`chi share`); nil for the owner's turns and between turns. Every hook event of such a turn carries the same as `author:`. The handler runs with the owner's power whatever the author ([hooks](hooks.md#participants-turns)). Needs chi 0.105.0 (guard it with `ctx.respond_to?(:turn_author)`) |
| `ctx.settings` | the bundle's settings, frozen: config.yml's `bundles: <bundle>:` with the session's own `--set` values laid over it ([Per-session settings](#per-session-settings)); the config alone until the session is bound (in `register` and `chi.ctx`) |
| `ctx.data_dir` | `$XDG_STATE_HOME/samagotchi/plugins/<bundle>/`, created on first use. A session's own state goes in `sessions/<id>.json` or `sessions/<id>/` there: chi removes it when the session is deleted, discarded or pruned |
| `ctx.log` | `ctx.log.info(:event, key: value)`: debug-log records tagged `plugins`, with `bundle=<bundle>` |
| `ctx.messages` | the conversation, as a frozen copy, without the system prompt. While a turn runs, a session worker's (attached, web) adds that turn so far: its prompt, the model's text and the lines merged into it (no tool calls or thinking); the REPL's is the conversation before that turn. An entry may carry `at`, when it happened (docs/sessions.md, Message times) |
| `ctx.messages_partial?` | whether `ctx.messages` leaves out a running turn (the REPL mid-turn), so a plugin can say what its answer is about |
| `ctx.prompt_files` | the files whose text is in the session's system prompt now: the AGENTS.md chain (the work tree top down to the cwd) and the appended files (`append_system_prompt:`, `--append-system-prompt`); absolute paths, in prompt order, `[]` before the first build |
| `ctx.notify(text, level: :info, fallback_for: nil)` | one line to the user, labelled by the bundle (`my-bundle> …`). Every UI shows it, during a turn (a tool, a hook) or between turns (a command). `fallback_for: :display` marks a line that repeats the answer's display (`event[:present]`), which a UI that renders the display leaves out (`fallback_for: :editor`: a file the viewer could open from a ref in its editor): see [Hooks](hooks.md#what-a-hook-can-do-the-runtime). The keyword needs chi 0.35.0 (it raises on an older chi) |
| `ctx.card(title:, body: "", actions: [], level: :info, id: nil)` | a card in every UI, returning its id: see [Cards](#cards) |
| `ctx.ask_user(question:, options:, header: nil, allow_freeform: false, effects: nil)` | a single-select question through the question flow: `{selected:, freeform:, selected_indices:}`, or nil (no one to ask, cancelled, bad options or effects). `effects:` tags the options a parent agent's answer is held to (label => `:spend`, `:permit`, `:permit_wide` or `:deny`; untagged = `:answer`): tag every option that spends or permits, and never let text alone or a dismissal do either ([hooks.md](hooks.md#what-a-hook-can-do-the-runtime)). It needs a chi newer than 0.85.0 |
| `ctx.cancelled?` | whether the running turn was cancelled (a long tool should stop) |
| `ctx.steer(text)` | put text into the running turn: its own user message at the loop's next boundary, shown as `my-bundle> nudged: …`. The model reads it with a header naming your bundle (`[Steer from the my-bundle plugin, mid-task. …]`); the session keeps the raw text. Returns true when queued, false with no turn running (it never starts one; that is `ctx.sessions`' send). Dropped (logged) if the model answers or the turn ends first. Safe from any thread: an anytime command, a hook (false from `:after_turn`), your own |
| `ctx.stop_turn(reason)` | stop the running turn after a warn notice with the reason; true when it stopped one now. In a `:before_tool_call` block it also denies that call |
| `ctx.stop_generation(reason)` | cut the generation that is streaming: the turn goes on and the model is asked again ([hooks.md](hooks.md#watching-the-stream)). Shows nothing: post your own notice. True when it cut one now |
| `ctx.ask_model(messages:, prompt:, …)` | a side answer from the session's model: see [Side answers](#side-answers-ctxask_model) |
| `ctx.http` | an HTTP client for calling services (`get`, `post_json`, `request`): see [Calling services](#calling-services-ctxhttp) |
| `ctx.sessions` | fork, send to, read, list and stop other sessions: see [Other sessions](#other-sessions-ctxsessions) |
| `ctx.toolkit` | the name of the session's toolkit (`full` for a session from before toolkits); nil with no session |
| `ctx.declared_tools` | the tool names the session's next turn declares (its toolkit resolved, with its own adds and removes): ask this, not the name, whether a tool is there |
| `ctx.use_toolkit(name)` | put the session on toolkit `name` (yours from `chi.toolkit`, or chi's): saved, applied at the next turn's start and announced (`toolkit> toolkit: NAME from the next turn's start`, the web's tools chip follows). Only before the session's first model reply and outside a turn (the declared tools start every request, and a plugin doesn't ask first); otherwise it returns false and changes nothing: tell the user to run `/toolkit NAME`. An unknown name raises ArgumentError. Needs chi 0.66.0 |
| `ctx.load_tools(names)` | load tools the session reaches but doesn't declare, so the model calls them by name: built-ins (`"delegate"`, `"chi/delegate"`), MCP tools (`"mcp_fs_read"`, `"fs/read"`). Returns the names it staged (the wire names); a declared tool, one loaded before, a removed or unknown one is skipped (an unknown one logged), so calling it every turn is fine. From a `before_turn` hook it loads for that turn; anywhere else (mid-turn too) from the next turn's start. Call it from a hook: before the session's first turn its toolkit isn't applied yet and nothing resolves. **A hint, not access**: the tools keep their guardrails and approvals, and only a host that takes tool changes (`api: anthropic`, not Fireworks) gets one, as a system message after the user's (`[tools loaded: delegate (your-bundle)]` in the session, a notice line live); elsewhere nothing is sent or saved, and the tools stay reachable with `call_tool`. A hook may switch the model after you call it, so the return value can't promise delivery. Raises ArgumentError for anything but an Array. Needs chi 0.99.0 |
| `ctx.context` | attach outside text to this session and list it: see [Attached context](#attached-context-ctxcontext) |

The Engine itself is never handed to a plugin.

### Per-session settings

A bundle's settings are config.yml's, for every session. A setting a session may have of its own (a child's cap,
say) is one the manifest lists in `session_settings:`; `chi --set BUNDLE.KEY=VALUE` and `chi send --new --set …`
(which also take a few core keys, `--set recap.enabled=false`: see
[Per-session settings](configuration.md#per-session-settings)) then give it to a new session, saved with it (a respawn, a fork and a continued link keep it; a delegate child
doesn't). chi refuses a bundle that isn't installed (or whose plugin doesn't load) and a key the manifest doesn't
list, so a typo isn't saved. A manifest that types a key (`session_settings: {cap: number}`: `number`, which
takes off too, `boolean`, `string`, or `any`) gets only a value of that type: `--set my-bundle.cap=five` is refused,
exit 2, as a key it doesn't list is (a mapping needs a chi newer than 0.91.0). Values are typed simply: an integer (`3`, `-1`) or a decimal (`2.5`, `.5`, `1e1`)
is a number, `true`, `yes` and `on` are true, `false`, `no` and `off` are false (any case, as config.yml's YAML reads
them), and anything else stays the text as given (`010`, `0x10`, `3:30`, `y`, `null`; YAML would read the first
three as numbers and `null` as nothing); a key typed `string` keeps its text as given (`yes`, `5`, `1.10`); `POST /api/sessions` `settings` (`{"my-bundle.cap": 3}`) types its strings the same way and
keeps JSON numbers and booleans. A name that is a core session setting is always chi's: a manifest whose
`session_settings:` key `K` makes `NAME.K` one (a bundle `recap` offering `enabled`) is refused at install, and
`chi bundle check` reports it as an `error clash`, in the same words. `ctx.settings` is the config's section with the session's values laid over it (one level: a session's
`cap` replaces the config's `cap`). Read such a key from `ctx.settings` where it is used, not in
`initialize(settings)`: that runs once at load, before any session, and gets the config only.

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
- `model:` names a configured model instead of the session's: `"host:id"` for a host in config.yml `hosts:`, an
  alias from `models:`, or a bare id one of the hosts lists or declares. The host's own key and settings are used;
  a plugin never names a URL or a key here (that is [`ctx.http`](#calling-services-ctxhttp)). A ref that names
  nothing configured raises `ArgumentError`, asking nothing: a typo never goes to another model.
- It blocks until the answer comes, so call it from an anytime command or a
  thread of your own. A local server that runs one request at a time
  (llama.cpp with one slot) answers it after a running turn's current
  request.
- It raises `Samagotchi::Plugin::ModelError` when the request fails or
  times out (the message says why), and `Samagotchi::Plugin::ModelCancelled`
  when cancelled.

It goes through the host's OpenAI API (`/v1/chat/completions`), which
llama.cpp serves on a native host too.

Each call counts in the session's side requests, under the bundle's name: `/stats`' `side requests:` line and the
web's ctx tooltip (`2 (btw 1, recap 1) · …`), with its tokens and its cost (reported, else estimated from the target
model's price), never in the session's own totals.

## Calling services: `ctx.http`

```ruby
# The http-echo bundle (spec fixture, docs/plugins.md "Calling services"):
# one tool that asks a local HTTP service and returns its answer.
class Plugin
  def initialize(settings)
    @url = settings.fetch("url", "http://127.0.0.1:9000/ask")
  end

  def register(chi)
    chi.tool "ask_service", "Ask the local question service and return its answer",
             params: { question: { type: "string", description: "What to ask", required: true } },
             label: "asking" do |args, ctx|
      res = ctx.http.post_json(@url, { question: args["question"] }, timeout: 5)
      if res.ok?
        res.json["answer"].to_s
      else
        ctx.log.warn(:ask_failed, status: res.status)
        "the service answered #{res.status}"
      end
    rescue Samagotchi::Plugin::HttpError => e
      "the service is not reachable: #{e.message}"
    end
  end
end
```

That is `spec/fixtures/http_echo_bundle` (a spec keeps the two the same; `chi bundle install` it to try it): the
shape to copy for a plugin that calls a service, tested on `bundle.http` as in
`spec/samagotchi/plugin/http_echo_bundle_spec.rb`.

One way to call an HTTP service, with timeouts, errors, logging and Stop handled the same for every bundle.
`Net::HTTP` stays available for what this doesn't do (streaming, multipart, redirects, connection reuse).

| | |
|---|---|
| `ctx.http.get(url, headers: {}, timeout: 10)` | GET |
| `ctx.http.post_json(url, body, headers: {}, timeout: 10)` | POST `body` encoded as JSON, with `Content-Type` and `Accept: application/json` (unless `headers` names them) |
| `ctx.http.request(method, url, body: nil, headers: {}, timeout: 10)` | GET, POST, PUT, PATCH, DELETE or HEAD; `body` is a String sent as is (set your own `Content-Type`) |

Every call also takes `cancel:`, a `Samagotchi::CancellationController`, which replaces the default (below).

- `url` is a String or URI, `http` or `https`. A bad URL, another scheme, an unknown method, a bad header, a
  `timeout` that isn't a positive number, or a body `post_json` can't encode as JSON raises **ArgumentError**
  before any request.
- `timeout` (seconds) is the connect, the write and the **per-read** timeout, not a total deadline: a server that dribbles
  bytes can take longer.
- It returns a `Samagotchi::Plugin::Http::Response`: `status` (Integer), `headers` (frozen, lower-case names,
  repeated values joined with `", "`), `body` (a String, `""` for HEAD or no body), `ok?` (2xx) and `json`. A
  **4xx or 5xx is returned, not raised**: check `ok?`. A redirect is not followed: the 3xx comes back with its
  `location` header.
- `body` is tagged UTF-8 when its bytes are valid UTF-8, else left binary: `body.scrub` it before handing unknown
  text to the model. There is no size limit: don't read an endpoint you don't trust to be small.
- `json` parses the body on each call and raises `HttpError` ("not JSON: …") when it isn't JSON.
- **One error type.** `Samagotchi::Plugin::HttpError` means the request didn't complete: refused, timed out, DNS,
  TLS, reset, a malformed response, a bad compressed body, or `json` on a body that isn't JSON. No raw `Errno`,
  `Net::` or `Zlib` error escapes (the original is the error's `cause`). The message says what and where
  (`"POST 127.0.0.1:9000: connection refused"`), never headers or a body. `Samagotchi::Plugin::HttpCancelled`
  (a subclass) means the call was cancelled.
- `http_proxy`, `https_proxy` and `no_proxy` are honoured as for chi's model calls (loopback is never proxied).
  chi's own `User-Agent` is always sent: yours is replaced.
- **Stop.** A call made for the turn (a tool, a hook's handler) stops when the turn is stopped, and a call inside an
  init task when chi shuts down; a call from your own thread, a `chi.service` or an anytime command has only its
  timeout unless you pass `cancel:`. After the turn has ended (an `:after_turn` or `:session_end` hook of a
  stopped turn) a call is not cancelled by that stop. A service's start block counts as the service's even when its
  first `value` comes from a handler.
- **The log.** Each call writes one `http` line to the debug log: INFO (ERROR when it fails) with `bundle=`,
  `purpose=plugin`, the method, the URL **without its query**, the status and the time. Never headers or bodies.
  A plugin that polls a dead service therefore logs an ERROR per poll.

`ctx.http` is experimental until 1.0, like the test kit.

## Other sessions: `ctx.sessions`

```ruby
id = ctx.sessions.fork(messages: ctx.messages + [{ role: "user", content: q }, { role: "model", content: a }],
                       title: "btw: #{q}")
ctx.sessions.send(id, "go on from here")
ctx.sessions.send(id, "then the docs", delivery: :queue)  # after its running turn
ctx.sessions.read(id)      # => {id:, title:, status:, parent_id:, running:, messages:}  (title: its /title, else its preview)
ctx.sessions.children      # => [{id:, short_id:, state:, branch:, last_reply:, reported:, ...}]
ctx.sessions.stop(id)      # one of this session's own children
ctx.sessions.review(subjects: ["docs/plan.md"], seed: handoff)  # => a review session's id (chi review --from)
```

- `fork(messages:, title: nil, prompt: nil)` starts a child session in its
  own worker, from these messages, in this session's folder and model. It
  shows in every list as a child of this one (`↳ parent`), and the user can
  attach to it. It returns the child's id.
  - Without `prompt:` the child waits idle. With one, it runs it as its first
    turn, and counts against `session.max_children` (like `delegate`).
  - `title:` is its preview: what the lists show for it (else the prompt, or
    the first user message). It stays after the first turn; it is not a
    `/title` of its own (see [Session titles](sessions.md#session-titles)).
  - An image a message names is copied into the child. One whose file is
    gone is dropped, with `[image x.png was not copied]` in its message.
  - A child chi won't start raises `Error` with chi's reason: the session's
    model is gone from the config, or its toolkit is a config kit with an
    invalid `groups:` (`toolkit.kits`, `Toolkit.check_new!`).
- `review(subjects: [], seed: nil, recap_wait: 0)` starts a review session of
  this one, as `chi review --from` does (see [Review sessions](sessions.md#review-sessions)):
  a new session in this session's folder, on its model and setup, seeded with
  its recap (never its transcript) and `seed:` (more context, a handoff say),
  idle, to share with participants (`chi share ID`). This session keeps
  running, unarchived; the review isn't its child. `subjects:` are project
  files relative to its folder (a secret or a file outside the project raises
  `Error` with chi review's one message). It uses the recap already saved: the
  worker is asked for a fresh one but not waited on unless `recap_wait:` (in
  seconds) says so, as it runs in this session's own worker. It returns the
  review session's id. The test kit's `bundle.sessions` answers `review-1`,
  `review-2`…
- `send(id, text)` sends a user message to a session (an id or a unique
  prefix); it runs as a turn, and a stopped session is woken. It waits up to
  5 s for the session's worker, so call it from an anytime command or a
  thread of your own, never from a tool or hook of a running turn. A
  session open in a chi REPL can't take it.
  - A running turn takes it at its next step. `delivery: :queue` runs it as
    a turn of its own after that turn instead (as `/queue TEXT` does; to an
    idle session it simply runs). A plugin never cuts the running turn's
    thinking: `delivery: :cut` raises `Samagotchi::Plugin::Sessions::Error`,
    as does an unknown value. A worker older than queueing refuses a queue
    (it would steer): `Error` with its reason; nothing is sent.
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
ctx.context.list  # => [{name:, scope:, why:, hint:, fetched_at:, error:, provider:, summary:}]
ctx.context.decline(url: "https://github.com/acme/app/pull/42")    # => "pr-42"
ctx.context.mark_offered("pr-42", "https://github.com/acme/app/pull/42", why: "branch feat/x has open PR #42")
ctx.context.offered("pr-42")  # => #<data Offer name="pr-42", hint="https://…", why="branch…", at="2026-10-08T…Z">, or nil
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
  user adds it (`ctx.context.declined?(name, url: nil)` says so, by the
  name or by the URL). `force: true` is for the user's own explicit choice
  (a click on the plugin's card): it attaches anyway and clears the
  declined marker, by the name and by the URL.
- `decline(url:)` or `decline(name:)` marks the source declined in this
  session, as the user's removal does: `attach` skips it from then on. With
  `url:`, the name and hint come from the bundle's provider (`name:`
  replaces the name). It returns the name. A source attached already stays
  attached (`chi context rm` removes it).
- `mark_offered(name, hint, why: nil)` records that the plugin offered a
  source here (the hint is usually its URL; `why:` is kept for the attach
  that may follow); `offered(name)` returns that record
  (`ContextSources::Offer`: `name`, `hint`, `why`, `at`) or nil. A plugin that asks
  before it attaches uses it so a worker restart doesn't ask again. Neither
  an attach nor a decline clears it; deleting the session does.
- The source is the session's (not the project's), marked
  `added_by: plugin:<bundle>`. It is plugin code, so it isn't asked about as
  the agent's `chi context add --cmd` is.
- `list` gives the session's sources, its own then its project's (`[]` before
  the session has an id or its file is saved: a command before the first turn). `hint` is the
  one the last text gave (else the source's), `summary` that text's summary
  (nil before any text; chi 0.63.0).
- Two attaches of one source at once (a double click) both return its
  name.
- `attach`, `decline` and `mark_offered` raise
  `Samagotchi::Plugin::AttachedContext::Error` with the reason (no session
  yet, no provider for the URL, a bad name).

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

## Stable for bundles

Bundles normally use only `chi.*` and `ctx`; the constants and helpers below
are the rest of the surface they may use. A change to any of them gets a
CHANGELOG line and bumps the shipped bundles that use it. Anything else under
`Samagotchi::` is internal.

**Stable**

1. `Samagotchi::Plugin::Api` / `chi.*` and `ctx` as documented above (`ctx.cost`'s and `ctx.usage`'s values by their methods), including
   `Samagotchi::Plugin::ToolResult`, `Samagotchi::Plugin::ModelError` (and its
   subclass `Samagotchi::Plugin::ModelCancelled`),
   `Samagotchi::Plugin::Service::Stopped`, `Samagotchi::Plugin::Sessions::Error`
   and `Samagotchi::Plugin::AttachedContext::Error`. `ctx.http` and its
   `Samagotchi::Plugin::HttpError` (with the subclass `HttpCancelled`) and
   `Samagotchi::Plugin::Http::Response` are **experimental until 1.0**, like the test kit.
2. `Samagotchi::Plugin::Peer` as a base class. A subclass defines `post`,
   `check_hint!`, `paired_lines`, `transport_line`, `peer_dir` and
   `setup_paragraph` (optionally `skill_substitutions`), and sets `NAME`,
   `APP`, `COMMAND`, `USAGE`, `OUTBOX` and `SCRIPTS_DIRS`. These constants are
   read as `self.class::X`. See the [claude-peer](#the-claude-peer-bundle) and
   [codex-peer](#the-codex-peer-bundle) bundles.
3. `Samagotchi::Tools::ToolIndex::Tool` and `Samagotchi::Tools::ToolIndex::Group`
   values, `Samagotchi::Tools::ToolIndex.schema_note` and
   `Samagotchi::Tools::ToolIndex.spec_tokens` (used by the mcp bundle).
4. `Samagotchi::Tools::Execute::NAME`, `TIMEOUT_PREFIX`, `HANDED_OVER` and
   `Samagotchi::Tools::Execute.timeout_seconds`.
5. `Samagotchi::Tools::TaskRuntime::TASKS_DIR` and `EXIT_CODE_FILENAME`.
6. `Samagotchi::AtomicFile.write`, `Samagotchi::Log.warn` /
   `Samagotchi::Log.debug`, `Samagotchi::Config.get` and
   `Samagotchi::VERSION`.

`Samagotchi::Testing::Boundary::ALLOWED` is the checked copy of this list,
and `Boundary::EXCEPTIONS` the per-bundle list of what each shipped bundle
(and its specs) reaches beyond it, each with why: the APIs to design before
that bundle could leave chi's repo. `spec/samagotchi/testing/boundary_spec.rb`
fails on a reference in neither (docs/testing.md).

**Used by shipped bundles today, but internal** (may change without notice; a
bundle that needs one should ask for an API instead):

- `Samagotchi::Tools::MemoryRead.memories_dir`, `Samagotchi::MemoryPaths.scope_dir`,
  `Samagotchi::ConfigFile.global_path` and
  `Samagotchi::Config.validate_yaml_sections`.
- `Samagotchi::Ref` / `Samagotchi::RefAction` constants and
  `Samagotchi::TokenUsage::CHARS_PER_TOKEN`.
- `Samagotchi::ProcessGroup.stop`, `Samagotchi::Guardrails::ShellLex` and
  `Samagotchi::Guardrails::GitInfo`.
- `Samagotchi::Tools::Execute.const_get` reflection.

## Testing a bundle (experimental)

`samagotchi/testing` loads a bundle the way chi does and records what it does at chi's edges, so a test
needs no fake `chi` or `ctx`. It is **experimental**: it may change in any release before 1.0.0 and is not
part of "Stable for bundles".

```ruby
require "samagotchi/testing"

bundle = Samagotchi::Testing::Bundle.load("path/to/my-bundle", settings: { "every" => 3 },
                                          host: { session_id: "s1", cwd: Dir.pwd })
bundle.fire(:after_turn, status: "completed")            # → the event, after the hooks
bundle.question_asked("Fix JIRA-1?", question: { question: "Go?" })   # → the refs, as chi's seams fire it
event = bundle.before_tool_call_event({ name: "read", path: "a.txt" }, params: "read a.txt")
bundle.command("/mine stop")                             # → what the command returned
bundle.tool("my_tool", path: "a.txt")                    # → the text the model reads
verdict = bundle.tool_call({ name: "execute", content: "rm -rf /" })
verdict.deny?                                            # a real Guardrails::Verdict (votes: verdict.votes)
bundle.notices.map(&:text)                               # also cards, steers, stops, generation_stops, questions
bundle.questions.last.effects                            # an ask_user's tags as given: { "Continue" => :spend }
bundle.answer({ selected: "yes" })                       # the next ask_user's answer
bundle.model_answers << "a summary"                      # the next ask_model's answer
bundle.sessions.on(:children) { |all:| [] }              # ctx.sessions, scripted and recorded
bundle.http.stub(:post, "http://127.0.0.1:9000/classify", json: { label: "safe" })   # ctx.http, never the network
bundle.set(running: false)                               # the session's values: cwd:, messages:, cancelled: …
bundle.set(cost: 2.5)                                    # ctx.cost: reported USD, or { reported:, estimated:, side:, known: }
bundle.set(usage: { tool_calls: 40, active_ms: 600_000 }) # ctx.usage: { turns:, tool_calls:, tool_calls_by_tool:, steps:, active_ms:, tool_ms_by_tool: }
bundle.set(turn_author: "p:p_0123abcd")                  # a participant's turn: ctx.turn_author, and author: on every event
bundle.set(session_settings: { "cap" => 1 })             # the session's --set values (Bundle.load takes session_settings: too)
bundle.tool_loads.last.names                             # ctx.load_tools calls; set(load_tools_staged: [...]) limits what they stage
bundle.shutdown
```

- **Real seams.** The plugin loads through `Plugin::Loader.register_file` (the real `chi` API and a real `ctx`),
  the hook files through `Hooks::BundleLoader.load_hook_file`, into registries that already hold chi's own
  commands and tools: a name chi has fails the load as it would in chi. `tool_call` runs a real
  `Guardrails::Gate` (context and targets computed for the call; `verdict:` starts from one with a vote in it).
  Only the edges are recorded: the session (`Testing::Host`), the hook helpers (`Testing::Runtime`),
  `ctx.sessions`, `chi.init` tasks (`bundle.run_inits`) and `chi.replace_tools` sets
  (`bundle.apply_staged_tools!`). No sha256 or `requires_chi` check: it loads the source as it is.
- **More:** `bundle.plugin` (the instance `register` ran on, for its own methods), `bundle.declarations` (the
  `chi.*` calls `register` made, in order, as made), `bundle.namespace`, `bundle.hook_names(event)`,
  `bundle.run_inits`, `sandbox.write_memory(name, text, scope:)` / `memory_dir`, `sandbox.fake_executable(name,
  body)` (first on `PATH`).
- **Waiting:** `wait_for(what, timeout: 5, seen: nil) { … }` polls the block until it is truthy and returns that
  value, or raises `Samagotchi::Testing::Waiting::TimedOut` ("timed out after 5 s waiting for <what>", plus
  `; last saw: <value>` from the `seen:` callable). `join!(thread, what)` and `pop!(queue, what)` are
  `Thread#join` and `Queue#pop` with that deadline and message; `wait_until { }` returns the block's last value
  instead of raising, for a wait whose timeout is fine; `process_gone?(pid)`. Every deadline is multiplied by
  `SPEC_TIME_SCALE` (default 1, at least 1; chi's CI sets 2), so a slow runner gets headroom.
- **Model notes:** `sandbox.model_notes_for(model_id, small: nil, cwd: nil)` lists the model notes chi would load
  into the prompt for a bare model id (`deepseek/deepseek-v4.1-flash`, no host prefix), from the sandbox's
  memories (an installed bundle's included), matched as chi matches them: each `models:` glob against the id and
  its model key; `small:` says whether the model counts as small for a `small` entry (nil: chi's own rule). The
  notes come in prompt order, and each answers four methods, its whole contract: `name`, `scope` (`"system"` or
  `"project"`), `chars` (the body's length) and `body` (what the prompt carries, the `models:` line left out). `sandbox.model_note_limits` gives the sizes chi
  warns over (`note:`, `total:`).
- **`ctx.http` is faked.** `bundle.http.stub(method, url_or_regexp, status: 200, headers: {}, body: nil, json: nil,
  error: nil) { |request| … }` answers it: a String URL matches exactly (query included), a Regexp the full URL, later
  stubs win, and a stub answers every matching call (a block that counts makes a sequence). `error: :refused` or
  `:timeout` raises the `HttpError` the real client would; `bundle.http.requests` lists what the plugin sent
  (`method`, `url`, `headers`, `body`, `json`) and `bundle.http.unmatched` what no stub answered. A request no stub
  answered raises `Samagotchi::Testing::UnstubbedRequest` (not an `HttpError`, but a plugin may rescue it anyway) and
  **fails the test at teardown** (RSpec and Minitest adapters: after the cleanup, and only a test that passed), so a
  spec can't reach the network. With plain `Bundle.load` there is no teardown: check `bundle.http.unmatched`.
  `bundle.set(cancelled: true)` makes a call without `cancel:` raise `HttpCancelled`.
- **`ctx.cost`** is zero and known unless the test sets it: `bundle.set(cost: 2.5)` (reported USD), a Hash of the
  parts (`reported:`, `estimated:`, `side:`, `known:`; `total` is reported + estimated) or a callable giving either,
  called at each read (a counting lambda shows whether the bundle read it).
- **`ctx.usage`** is zero unless the test sets it: `bundle.set(usage: {...})`, a Hash of the parts (`turns:`,
  `tool_calls:`, `tool_calls_by_tool:`, `steps:`, `active_ms:`, `tool_ms_by_tool:`; zeros for the rest, an unknown
  part raises; `tool_calls` defaults to the sum of `tool_calls_by_tool`, `active_ms` to the sum of
  `tool_ms_by_tool`) or a callable giving one, called at each read.
- **`session_settings:`** (on `Bundle.load` and `bundle.set`) are the session's own `--set` values for the bundle,
  keys its manifest lists in `session_settings:` (another key, or a value of another type than the manifest gives
  it, raises `ArgumentError`, as chi refuses it). `ctx.settings`
  lays them over `settings:` through chi's own `Context#settings`; the plugin's `initialize(settings)` gets
  `settings:` only. `bundle.set(session_settings:)` moves the session to a new id (`test-session-2`, or the
  `session_id:` given beside it): chi never changes them within a session, and builds `ctx.settings` once per id.
- **`question_asked(text, kind: "question", question: {}, cwd: nil)`** fires `:question_asked` through
  `QuestionAsked.fire`, as chi's two seams do: a step whose text is `text` asks a question (or `kind: "approval"`)
  with the `question` fields, and the refs the hooks attach come back checked (the question caps, a file ref under
  `cwd:`, default the session's folder), as the step and its pending question keep them; `[]` for none.
- **A hook that raises fails the call** (`Testing::HookFailed`, with the hook's error) where chi would log it and
  go on; `bundle.lenient { … }` collects them in `bundle.errors` instead.
- **Sandbox.** A test runs with temp config, state, data and cache homes (config.yml, memories, `ctx.data_dir`, the
  debug log), `HOME`, `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, no git config of yours, no Keychain and none of your
  `SAMAGOTCHI_*` settings; `sandbox.config(hash)` writes its config.yml.
- **RSpec:** `require "samagotchi/testing/rspec"`; example groups tagged `:bundle` (a spec under a bundle's own
  `spec/` is tagged by itself) get `load_bundle(dir)`, `shipped_bundle(name)` and `sandbox`, each example in its
  own sandbox, its bundles shut down after it (chi's shipped bundles keep theirs in `<bundle>/spec/`,
docs/testing.md). **Minitest:** `require "samagotchi/testing/minitest"` and subclass
  `Samagotchi::Testing::Case` (the same helpers).
- **Installed, not loaded from source:** `Samagotchi::Testing::Install.run(dir, settings: {})` (or
  `bundle.install`) installs the bundle into the sandbox as `chi bundle install` does (sha256 and `requires_chi`
  checked) and loads the installed copy with chi's own loaders. It returns `warnings` (the Installer's),
  `plugin_failures` / `hook_failures` (each with the `location` in your source, `plugin.rb:12`) and `registered`
  (commands, tools, hooks per event, inits, toolkits, tool and peer sources). A name chi ships raises
  `MemoryBundle::Installer::InstallError` unless `force: true`.
- **From the command line:** `chi bundle test [PATH]` runs a bundle's `test/**/*_test.rb` (or `spec/`) on the
  Ruby and lib chi runs on, and `chi bundle check [PATH] [--fix]` runs `Install` (and the manifest, sha and
  `requires_chi` checks) in a sandbox ([cli.md](cli.md#writing-a-bundle-new-test-check)). `chi bundle new NAME`
  writes a test to start from. `chi bundle try PATH -p TEXT` runs it against a real model for one turn
  ([cli.md](cli.md#trying-a-bundle)), and `chi bundle install --dev PATH` links it into your own sessions.

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
by one: the bundle publishes them into chi's tool index
([chi.tool_source](#chitool_sourcecall-acts_as-label-wait-prefix), a group
per server), and the model has its two tools, `find_tools` and `call_tool` (~250 tokens in
every request plus a line per server, whatever the servers have; `/mcp`
says how many). On `api: anthropic` each tool also goes out deferred as
`mcp_<server>_<tool>`, so a `find_tools` hit loads it and the model calls it
by that name, as `call_tool` would run it. Stdio servers only, for now.

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
        description: files in ~/scratch        # optional: its line in find_tools
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
  session that never uses MCP spawns nothing, and a new session opens without
  waiting for `npx`. If the live list differs from the saved one, the saved
  one is replaced, and so is what a search finds. The model's tools never
  change, so the prompt cache keeps. The saved file also keeps the first
  sentence of the server's `instructions` (from `initialize`), for its line
  in `find_tools`.
- **The first run** (no saved list, or the config changed) starts the
  server in an [init task](#chiinitlabel-provides_tools-false-quiet-false-timeout-nil-failed-nil--ctx--):
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
  task, after the Bridge is up), even when that session's toolkit does not
  reach its group. A first-run init task still blocks the first turn until
  it finishes, even for an unreached group. A stale-cache refresh likewise
  starts its short-lived server regardless of the toolkit. Switching away
  from a group refuses its calls without starting a lazy cached server, and
  does not stop a server already running; switching back reuses it.
- **`npx -y …@latest` checks the npm registry on every start** (~3.4 s for
  `chrome-devtools-mcp`, against ~0.9 s for the installed binary). The cache
  hides it from new sessions, but not from the first call. For a faster first
  call, install the server once and run it directly:

  ```yaml
  chrome:
    command: [chrome-devtools-mcp, --slim, --headless]   # after npm i -g chrome-devtools-mcp
  ```

- **Tools: search, then call.** The servers' tools are kept in chi's tool index;
  the model has two fixed tools:
  - `find_tools(query, group?)` searches it by keywords over the
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
  - `call_tool(tool, args)` calls one: `tool` is `<server>/<tool>`, and
    `mcp_<server>_<tool>` works too (looked up, not parsed). Two tools whose
    `mcp_<server>_<tool>` comes out the same (servers `git-hub` and
    `git_hub`, names alike up to the 48-character cut) are both refused,
    since guardrail rules and approvals couldn't tell them apart: a search
    and `/mcp` mark them `(name clash with …)`, and there is one notice.
    `args` are typed by the tool's
    `inputSchema` (numbers and booleans given as text, JSON text for an
    object). A name it doesn't know answers the closest ones (`Error: no
    tool chrome/open_url. Closest: chrome/new_page, …`). Its row shows
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
  closed, then TERM and KILL go to the server's process group. A chi
  killed with `kill -9` (or crashing past Ruby) stops nothing itself; a
  server that ignores its stdin's EOF would live on then. So each server's
  group also holds a watchdog, a `/bin/sh` waiting on a pipe only chi
  holds: when that pipe closes without chi letting it go, it gives the
  server a second, then TERMs and KILLs its group (the server's helpers
  too). A server that leaves its group (`setsid`) is out of its reach.
- **`/mcp`** (anytime) shows a card with the servers, their state (cached
  (not started), running with its pid, failed with its count, stopped) and
  their tools as `<server>/<tool>`, the name `call_tool` takes.
  A cached or running server's line says roughly how many tokens its tool
  definitions take (`~4,232 tokens`), which only a search's answer carries
  now; the last line says what every request carries (`find_tools` and
  `call_tool`) and totals the servers'. It is an estimate:
  the definitions' JSON as the chat API gets it (`api: openai`), divided by
  4. The native prompts (Gemma, Qwen) render a flatter schema, so there they
  take less. The log records each server's estimate when it changes
  (`mcp_tools_estimated`).
- The server's stderr goes to the debug log (`plugins` records, bundle=mcp).
- **Guardrails.** A rule's `tool:` can be a glob, so one rule covers every
  MCP tool (a search is `find_tools`, outside `mcp_*`, so it isn't
  asked about):

  ```yaml
  guardrails:
    rules:
      - id: mcp-ask
        tool: "mcp_*"
        verdict: ask
        reason: an MCP server's tool
  ```

  `call_tool`'s `targets:` act as the tool it calls, by its
  `mcp_<server>_<tool>` name ([acts_as:](#guardrails)), so `tool:
  "mcp_github_*"` or `tool: mcp_github_merge_pull_request` match a
  `call_tool` to it, as they matched the tool when it was declared by that
  name. A call made before the server's tools are known (a first run
  still starting) is matched by the name the model gave, so the rule fires
  before the call waits; if the tool it then finds isn't that one, the
  call is refused. The question shows the inner arguments under `<server>: <tool>`
  (`everything: get_sum: a=20 b=22`), and "Allow this call for the
  session" (or in this repo) allows that tool with those arguments only.
  (Approvals stored before 0.6.0, under the old name, don't carry over, nor
  ones stored before 0.7.0 under `mcp_call`: each MCP tool is asked about once more.)
  Two things see `call_tool`, not the MCP tool: hooks (a `before_tool_call`
  event's `tool:` is `"call_tool"`, the tool in its args; a built-in reached
  through `call_tool` is the exception, it fires as that built-in), and loop-guard's
  `ignore_tools` (`call_tool` ignores every MCP call; calls to different
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

## The cost-cap bundle

`chi bundle install cost-cap` installs the bundle shipped with chi (`chi bootstrap` installs it with the `core`
profile; an existing install gets it with `chi update`). It caps what one session spends, so neither you nor the
model has to watch `chi sessions stats`: the harness watches the money and the model never sees any of it (no tool,
no steer, no prompt text). It is inert without a cap, and there is none by default.

```yaml
# config.yml
bundles:
  cost-cap:
    default: 5.00     # USD cap for a session with none set; absent/0/off: no cap
    child: 2.00       # for delegate children; absent: default
    warn_at: 0.8      # tell the user (only) once at this share of the cap; 0/off: no warning
```

- **What counts:** `ctx.cost`'s total: what the provider reported (`usage.cost`), else the estimate from the
  model's configured price (`hosts.<name>.models.<id>.price`), plus side requests (the idle recap, `/btw`,
  `ask_model`), including what earlier workers of the session spent.
- **When it checks:** before each generation, so before the money is spent. A generation that crosses the cap is
  caught at the start of the next one: the overshoot is at most one generation (plus any side requests between).
  A turn whose last generation crossed it ends normally, and the next turn's first generation asks.
- **At `warn_at` of the cap** you get one notice, `cost-cap> $2.41 of $3.00 spent (80%)`; a raised cap warns again.
- **At the cap** the turn pauses on a question (header "Cost cap"): `Cost cap reached: $3.04 spent of $3.00.
  Continue raises it to $6.00.` with **Continue** (another cap's worth: $3 → $6 → $9, as many steps as it takes to
  pass the spend, saved for the session) and **Stop** (the turn stops, `canceled` with `stopped_by: cost-cap`, and a
  card shows the spend, reported, estimated and side). With no one to ask (`--non-interactive`) it stops. A parent
  agent answering it (`chi answer`) may Continue under `guardrails.parent_answers: soft` or `standard`, and only Stop
  under `hard` (config.yml's, or the session's own when stricter) (Continue is tagged `:spend`; see [Guardrails](guardrails.md#answers-from-a-parent-agent)). `/cap N` is
  a command, not an answer: a parent that sends it (`chi send ID -m '/cap 10'`) raises the cap under any strategy.
- **The cap of a session:** the one `/cap` or a Continue set for it, else its own `cap:` (`chi --set
  cost-cap.cap=3`, `chi send --new --set cost-cap.cap=3`; `--set cost-cap.cap=off`, `0` or a negative number for none), else `child:` for a
  delegate child, else `default:`. A cap is a number (`3`, `.5`, `1e1`; in config.yml and `/cap`, `"$2"` too, which `--set` refuses). `--set` refuses
  another value (`cost-cap.cap=five`: exit 2); one in config.yml (or set before this check) that doesn't read
  (`default: five`) gets one notice, `cost-cap: default: "five" isn't a number or off; no cap`, and a `cap:` or
  `child:` that doesn't read gives way to the next key (`…; using default: ($5.00)`), never a silent no cap. Delegates and continued links each have their own cap (a continued link keeps
  the `--set` cap, not a `/cap` or Continue); there is no family cap.
- **A host it can't watch:** a model that reports no cost and has no configured price (a local server, a free
  model that reports 0) reads unknown: one notice, `the $3.00 cap can't be enforced: <model> reports no cost and has
  no price`, and it never stops for an unknown cost. A session with some priced generations counts the unpriced
  ones as $0.

**`/cap`** (works while a turn runs; the next generation reads it):

- `/cap`: `cost-cap: $1.20 spent of $3.00 (reported $1.10, estimated $0.10, side $0.02)`, or `cost-cap: no cap
  ($1.20 spent)`, with `(can't be enforced: no cost reported or priced)` when it can't be.
- `/cap 5`, `/cap $5` or `/cap .5`: the cap (and what Continue adds) becomes $5.00 for this session. A cap at or under the
  spend is allowed: the next generation asks.
- `/cap off` (or `/cap 0`): no cap for this session, over the config's `default:`.

A parent agent starts a session with a cap of its own with `--set` (`chi send --new --set cost-cap.cap=3 -m "task"`;
`cost-cap.cap` is the bundle's one session setting), or by sending `/cap N` as a first message
(`chi send --new -m '/cap 3'`).
At the cap, `chi send --wait` exits 3 with a question of kind `hook` (header "Cost cap"); `chi answer ID --question
Q --option Continue` (or `--option 1`) goes on, `--option Stop` stops the turn ([sub-agent.md](sub-agent.md)). A
parent may Continue: nothing restricts it, as with the step limit. A background delegate child at its cap waits on
its own card and doesn't wake its parent ([sessions.md](sessions.md#delegating)).

The state is one file per session, `<data_dir>/sessions/<session id>.json` (`{"cap": 3.0, "step": 3.0}`), removed
with the session. A file that is there but doesn't read (not JSON, or not a mapping) is logged
(`costcap_state_unreadable`) and gets one notice, `cost-cap: <path> doesn't read, its /cap cap is ignored; using
default: ($5.00)`: the settings' cap is used, never a silent drop; the next `/cap` or Continue rewrites it, logged
(`costcap_state_replaced`) and said (`cost-cap: <path> didn't read; replaced with the new cap`).

Its sibling for work instead of money, tool calls and active minutes across the session's turns, is
[the work-cap bundle](#the-work-cap-bundle): the cap a local model (no cost) can have.

## The work-cap bundle

`chi bundle install work-cap` installs the bundle shipped with chi (`chi bootstrap` installs it with the `core`
profile; an existing install gets it with `chi update`). It caps the work one session does across its turns: tool
calls and active minutes. The per-turn meters reset every turn (the step limit, check-in, loop-guard), and a
Continue on the step-limit question starts the next 300 steps; a parent agent may answer that Continue itself
(`chi answer`), so a child it keeps continuing has no overall bound but cost-cap's `$`, and on a local model none.
work-cap is that bound, with cost-cap's shape: the harness watches, the model never sees any of it. It is inert
without a cap, and there is none by default.

```yaml
# config.yml
bundles:
  work-cap:
    child: {tool_calls: 500, minutes: 90}   # delegate children with no own value
    default: {}         # every other session (and a delegate without child:); empty: no cap
    warn_at: 0.8        # tell the user (only) once at this share of a cap; 0/off: no warning
    ignore_tools: [task_wait, task_get, delegate, delegate_result]   # not counted: waiting
```

- **What counts** (`ctx.usage`): **tool calls**, the session's own across its turns and workers, less
  `ignore_tools` (the waiting tools by default, `delegate` among them since it blocks on its child, so a session
  waiting on a long task or a child isn't capped for waiting); and **active minutes**, work time: the generations' time plus the finished tool calls' time (less
  `ignore_tools`' time), never a wait (a question, its own included, an approval, the user's answer to
  `ask_user_question`), so idle time and a Continue answered hours later don't count.
- **When it checks:** before each generation, like cost-cap: the overshoot is at most one generation's tool calls.
  When the step limit and a work cap fall in the same turn, the work cap asks first, and its Stop ends the turn.
- **At `warn_at` of a cap** you get one notice per meter, `work-cap> 320 of 400 tool calls (80%)`; a raised cap
  warns again.
- **At a cap** the turn pauses on a question (header "Work cap") that names the session's totals, so a parent
  answering it decides on the whole picture: `Work cap reached: 412 tool calls of 400 (6 turns, 47 min active,
  $1.20). Continue raises it to 800.` **Continue** raises the cap by another cap's worth (as many steps as it
  takes to pass the work, saved for the session), **Stop** stops the turn (`canceled` with `stopped_by: work-cap`)
  with a card showing the totals. Both meters at once: one question naming both, Continue raises each. With no one
  to ask (`--non-interactive`) it stops. Continue is tagged `:spend`, as cost-cap's: a parent agent may Continue
  under `guardrails.parent_answers: soft` or `standard`, only Stop under `hard` (see
  [Guardrails](guardrails.md#answers-from-a-parent-agent)).
- **The caps of a session**, each meter on its own: the one `/workcap` or a Continue set, else its own value (`chi
  --set work-cap.tool_calls=400`, `work-cap.minutes=60`, `chi send --new --set …`; `off`, `0` or a negative number
  for none), else `child:`'s for a delegate child, else `default:`'s. Minutes in config.yml read `90`, `90m` or
  `1.5h`. A value that doesn't read (`tool_calls: many`, a `default:` that isn't a mapping) gets one notice,
  `work-cap: tool_calls: "many" isn't a number or off; using default.tool_calls: (400)`, and the next value is used,
  never a silent no cap.

**`/workcap`** (works while a turn runs; the next generation reads it):

- `/workcap`: `work-cap: 320 of 400 tool calls (6 turns, 47 min active, $1.20)`, or `work-cap: no cap (…)` with the
  totals.
- `/workcap 400`: the tool-call cap (and what Continue adds) becomes 400 for this session; `/workcap 90m` or
  `/workcap 2h`: the active-minutes cap.
- `/workcap off` (or `/workcap 0`): no work cap for this session, over the config.

The state is one file per session, `<data_dir>/sessions/<session id>.json` (`{"tool_calls": {"cap": 800, "step":
400}}`, a meter's `"cap": null` for off). A file that is there but doesn't read (not JSON, or not a mapping) is
logged (`workcap_state_unreadable`) and gets one notice, `work-cap: <path> doesn't read, its /workcap caps are
ignored; using default.tool_calls: (400)`: the settings' caps are used, never a silent drop; the next `/workcap` or
Continue rewrites it, logged (`workcap_state_replaced`) and said (`work-cap: <path> didn't read; replaced with the
new cap`).

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
    what is left. Every UI shows `check-in> nudged: …`. One nudge per
    check-in: another click (or a typed `/checkin nudge`) answers
    "check-in: already nudged at N tool calls".
  - **Keep going** (`/checkin later`): closes the card until the next
    check-in.
  - **Stop** (`/checkin stop`): stops the turn.

  When the turn ends the card loses its actions ("The turn ended after N tool
  calls"), so no stale buttons stay; a card left by a worker that exited
  mid-turn comes back without them too. In the attached terminal the actions are
  `→ /checkin nudge` lines to type; the command runs beside the turn.
- **`mode: nudge`**: nudges the model by itself, with a notice line.
- **`mode: notify`**: a notice line only.

The count is per turn: a new turn (a prompt, a continue, a reminder) starts
from zero; steering merged into the running turn doesn't reset it (a cap
across the session's turns is [the work-cap bundle](#the-work-cap-bundle)). The polling
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

## The slow-commands bundle

`chi bundle install slow-commands` installs the bundle shipped with chi (`chi
bootstrap` installs it with the `core` profile). It is written only against
this API (`lib/samagotchi/bundles/slow-commands/plugin.rb`), with `chi.on`
hooks and a `/slow-commands` command, and has no memory file.

At its limit (120 s, `execute.timeout_sec`) `execute` hands a command still
running over as a background task (`execute.on_timeout: task`, the default),
or kills it (`kill`). A full test suite or a build takes longer, so each run
first blocks the turn for those two minutes (and, in kill mode, loses them,
then starts again with `task_create` and `task_wait`); the next session does
the same. slow-commands remembers such a command for the project:

- An `execute` that **timed out** or was **handed over** at the limit, or ran **`warn_ratio` of the limit** or
  longer (default 0.8, so 96 s of 120), is recorded as slow. A later run of
  it under half the limit **with exit 0** drops the entry; a fast failure (a
  load error) doesn't, since it says nothing about how long the suite takes.
  Nor does one through a filter the key leaves out (`rspec 2>&1 | tail -30`
  exits with `tail`'s 0, and a `| head` can end it early).
  A call the user stopped, or that was denied, records nothing.
- The **next identical `execute`** is **denied** with advice:

  ```
  [execute] Error: denied by guardrail (bundle slow-commands): slow command. The user was not asked. This command ran past the execute limit (120 s) here on 2026-10-09. Start it with task_create, then task_wait (timeout 600). A finished task of this command took 4m10s.
  ```

  The last sentence is there when a task of the same command (and cwd)
  finished with exit 0 in the project's `tmp/tasks`; a longer one raises the
  `task_wait` timeout it suggests. The user sees one line:
  `slow-commands> execute bundle exec rspec: ran past 120 s before, denied`.
- **Once per command per turn**: the same `execute` again in that turn runs.
  The model insisting is a signal (maybe the suite got faster), and that run
  records the new truth. A new turn denies again.
- In kill mode (`execute.on_timeout: kill`), a **`timeout N` past the limit**
  is denied up front, with no history: execute stops the command first, so
  `timeout` never fires. In task mode it runs on as a task until `timeout`
  fires. `timeout`'s exit codes (124, 137) mean nothing special here.

A command is the same when its project and its text match. The project is
the session's git checkout (else its working directory). The text is the
command's words and operators (`a && b` is not `a b`), the call's `cwd:`
folded in as `cd web && …`, and a trailing `2>&1`, `| tail …`, `| head …`
or `| grep …` dropped (they don't change how long it runs). Arguments stay:
`bundle exec rspec` (the suite) is slow, `bundle exec rspec
spec/foo_spec.rb` isn't the same command, and stays the fast path. A
command that ends inside a quote, `$(` or heredoc is never recorded, nor
one with a `$(…)`, backticks or a heredoc `cat` or `tee` reads (the key
can't tell two of those apart). A heredoc script (`python3 - <<'EOF'`)
keeps its body in the key, so each script is its own command.

Wrappers a model adds by habit don't make a new command: at the start of
each simple command (so after a leading `cd X &&` too), `time [-p]` and
`timeout`/`gtimeout` with its options and duration are left out, so
`timeout 300 bundle exec rspec` and `bundle exec rspec` are one entry. `X=…`
assignments stay, sorted (`SPEC=… rake spec` is not `rake spec`), except
`NO_COLOR`, `FORCE_COLOR` and `TERM` (`CI` stays: jest or vitest without it
can sit in watch mode); a plain `env X=… cmd` is `X=…
cmd`, and an `env` with an option (`-C`, `-i`, `-u`) stays as typed. The
list shows each entry as it was last typed.

Since 0.2.0 (chi 0.59.0) a hand-over counts as timed out, and the advice's
duration also reads a handed-over task, whose `exit_code` file is in the
state dir (the record's `exit_code_path`).

Entries live in `$XDG_STATE_HOME/samagotchi/plugins/slow-commands/commands.json`,
shared by every session (another session's record counts at once) and
forgotten after `ttl_days`.

```yaml
# config.yml
bundles:
  slow-commands:
    mode: deny        # deny | notify (warn the user, never deny)
    warn_ratio: 0.8   # a run this share of the execute limit or longer is slow
    ttl_days: 14      # entries older than this are forgotten
```

| | |
|---|---|
| `/slow-commands` | this project's slow commands, numbered |
| `/slow-commands forget 2` / `forget all` | drop one (a wrong entry) or all of them |

## The agents-md bundle

`chi bundle install agents-md` (or the `core` profile) installs the bundle shipped
with chi (`lib/samagotchi/bundles/agents-md/plugin.rb`): two `chi.on` hooks
(`:before_turn` rebuilds the steered set, `:after_tool_call` steers), and no memory file.

chi's system prompt holds only the `AGENTS.md` chain from the checkout top down
to the session's cwd, so an `AGENTS.md` in a directory the session doesn't run
in (say `pkg/inner/` while the session runs in `pkg/`) is never seen. The
bundle closes that gap in history, not in the system prompt: the first `read`,
`write` or `edit` (its `tools` setting) of a file under a directory with an
`AGENTS.md` steers that file into the running turn, at the loop's next
boundary, as its own user message — with a first line that says which
directory it belongs to:

```
AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):
<content>
```

- It steers the **outermost candidates first** (each directory from the
  touched file's directory up to, but not including, the checkout top), so a
  deep file can bring in several `AGENTS.md`s at once, outermost to nearest.
- It **never re-injects**: each directory steers once per session, and a
  `before_turn` pass over the conversation rebuilds that set from the steers
  already there. A steer the model answered past (never injected) is absent,
  so it fires again on the next touch; a resume, a woken worker or a fork
  pick the set up from their messages. It never stops generation or thinking.
- **Scope:** the touched file's own git root must be the session's checkout:
  a file in another repository, a nested repository or a submodule is
  ignored. Paths compare by `File.realpath`, so a symlinked cwd (a macOS
  `/tmp`) still matches.
- Directories whose `AGENTS.md` is already in the system prompt (`ctx.prompt_files`:
  the chain and appended files) are skipped, as is a file at the checkout top
  (its `AGENTS.md` is the chain's first).

```yaml
# config.yml
bundles:
  agents-md:
    tools: [read, write, edit]   # the calls that count as a touch
    max_chars: 16000            # the content is cut here, with a "[cut at N
                                # of M chars: read <absolute path> for the rest]" last line
```

`skip_agents_md: true` disables the bundle, as it does the chain's loading
(see [Configuration](configuration.md#project-specific-description)).

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
tool call after it (an `execute` that exited non-zero, except a grep-family
search that found nothing, a tool error) steers
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
merged or closed. In the web, a `path:line` in a worker's answer links to
that line of the session's PR ([Line links](context.md#line-links); `line_links:
always` for the REPL and `chi -p` too), and its ref menu offers the file
here and a "PR diff" action (`event[:refs]`). `auto_attach:
offer` asks with a card first (`/pr-attach N`, `/pr-decline N`), `off`
attaches nothing ([Attach, offer or off](context.md#attach-offer-or-off)).
See [Attached context](context.md#github-prs-the-github-pr-bundle).

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
  **`/coordinate end`** ends the day: the model checks each branch, brings
  its handoff up to date (state per branch, decisions, verdicts,
  follow-ups, each open child's id, branch and worktree), keeps it OPEN unless everything is done, and gives a short
  report ending with the `/coordinate resume <slug>` to pick it up next
  time. It starts, merges and stops nothing: running children stay running
  and are named in the report.
- **Sprint review (experimental, 0.6.0).** **`/coordinate review [name]`**
  starts a review session of this coordinator session (`ctx.sessions.review`:
  its recap, never its transcript; this session keeps running) seeded with the
  open handoff's body (the one named, the only one, or a card with a Review
  action each when several are open; with none, the recap alone), and prints
  the `chi share <id> --name NAME` line. A participant (a manager, a teammate)
  brings new context there; the skill's Sprint review section (copied into
  the seed: a participant's turn reads project memories only, and the skill
  is a system one) has the review's model answer it with a **hand-off diff** (the handoff's lines as
  they would change, in a `diff` block, and what it means per branch), in a
  turn that may only read. Your **Apply** under it (the web's) quotes the
  diff in your turn there: the model brings the handoff up to date and
  re-plans in words, and starts, stops or merges nothing from the review
  session: the coordinator session picks the change up from the handoff,
  merges still asked. Experimental: it may go if it doesn't earn its place.
- **The coordinator toolkit.** The bundle declares `coordinator`: `lean`
  plus `delegate`, `delegate_result` and `list_sessions`
  ([Toolkits](configuration.md#toolkits)). `/coordinate` puts a fresh session
  on it before it asks the model (`ctx.use_toolkit`). When chi refuses (a reply
  or a turn already there) and the session's toolkit has no `delegate`, the
  reply says to run `/toolkit coordinator`. A continue of a coordinator link
  keeps the toolkit.
- **The coding toolkit.** The bundle (0.5.0) also declares `coding`: `child`
  with the prompt text `- Be concise in your responses` / `- Show file paths
  clearly when working with files`. The skill starts build and fix children
  on it (`delegate` with `toolkit: "coding"`); reviews, research and plans
  stay on `toolkit.child`, as they need the length.
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

## The claude-peer bundle

```sh
chi bundle install claude-peer    # in the dev profile
```

A live link between a chi session and a Claude Code session you already work
with: chi sends it a part of the work (a plan step, a diff, a finding) to
validate or as context, and Claude's answer comes back into chi. This is
Claude with the context it has, not a fresh review run. Nothing runs until a
Claude pairs; without one the bundle costs one tool declaration.

- **Pairing is Claude's.** chi can't see Claude's inbox, so Claude attaches
  two pushed sources to the chi session: `claude-inbox`, whose hint is its
  per-session inbox socket (`CLAUDE_CODE_MESSAGING_SOCKET`, Claude Code
  2.1.224 or later), and `claude-outbox`, where its answers come. You never
  run that yourself:
  1. `/claude install-skill` (once) shows a card with the target,
     `$CLAUDE_CONFIG_DIR/skills/chi-peer/SKILL.md` (else `~/.claude/…`),
     whether one is there and, when it differs, a short diff; its Install (or
     Replace) button runs `/claude install-skill --yes`, which copies the
     bundle's `scripts/chi-peer-SKILL.md` there with the installed
     `scripts/pair` path written in. The copy happens inside chi, where no
     guardrail sees it: the button is your consent. The card also offers the
     Claude Code permission rule `Read(~/.local/state/samagotchi/plugins/claude-peer/**)`
     (your state folder), so Claude isn't asked before reading a long part's
     file; chi never writes Claude's settings.
  2. In Claude Code you say "pair with chi <id or chi web URL>". The skill runs
     `sh <bundle>/scripts/pair <id or URL>`, which attaches `claude-inbox` (the
     socket as its hint, pushed as JSON so a re-pair after a Claude restart
     refreshes it) and `claude-outbox`, and lists the session's context. A
     re-pair keeps Claude's last answer.
  3. Claude answers a validate or a question with a JSON push to
     `claude-outbox` (`text`, `summary`, `wake: true`), which wakes chi, the
     first answer too (on chi 0.62 the first one arrives as a note without
     waking); the model reads it with `context_read claude-outbox`.
- **The tool `claude_send(kind, title, text)`**, `kind` being `validate`,
  `context` or `question`, writes one JSON line to that socket. The message
  starts with a header, `chi <id> · <kind> · <title>`. A text up to 4,000
  characters follows inline; a longer one goes to a file,
  `$XDG_STATE_HOME/samagotchi/plugins/claude-peer/sessions/<id>/<HHMMSS>-<slug>.md`
  (removed with the session), and the message names it (`payload: <path>`).
  The tool is declared whether or not a Claude is paired, so pairing doesn't
  change the prompt. Its errors say what to do: no `claude-inbox` (pair from
  Claude), the socket gone or refusing (that Claude session ended or
  restarted: pair again), a text over 200,000 characters.
- **`/claude`** (an anytime command, so it works mid-turn) sends without
  the model:
  - `/claude` alone shows a card: paired or not, the socket and whether its
    file is there (it goes when that Claude session ends), the last send, and
    Claude's last answer (the `claude-outbox` summary). When Claude's installed
    chi-peer skill differs from what `/claude install-skill` would write (an
    older bundle's, or your edit; a skill installed by a chi with another state
    dir or bundle path differs too), it says so: install it again (Replace),
    then pair again.
  - `/claude validate <text>` and `/claude context <text>` send the text as it
    is, titled by its first line (past a web quote's `From …:` label and a
    quoted line's `> `): paste a selection after them.
  - In the web, selecting text offers **Confirm with Claude**
    ([`chi.annotation`](#chiannotationlabel-command-template-quote-send-false)):
    it fills the composer with `/claude validate` and the quote, for you to
    add what needs confirming.
  - `/claude last` sends the model's last completed answer as context. Mid-turn
    it is the answer before the running turn, never the turn's partial text;
    a cancelled or failed turn has no answer, so the one before it goes.
- **The peer loop.** The bundle declares `claude-outbox` a peer's
  ([`chi.peer_source`](#chipeer_sourcename-label)), so Claude's answers
  wake chi by the loop's rules ([Waking: peer
  sources](context.md#peer-sources-the-peer-loop)): chi fixes what Claude
  flagged or disagrees and sends again, up to `context.peer_turns` (3) wake
  turns in a row, and a `VERDICT OK` answer wakes chi once to close the
  round (carry on, or tell you what was agreed). Only a message you type in the web or a TUI starts the count again.
- **The skill.** `skill_claude_peer` (system scope) tells the model to send
  only when you ask or to reply in a peer turn, to pick the part rather than
  the session, not to wait or poll, and how to read the `claude-outbox`
  answer (a validate ends with `VERDICT: OK`, `CHANGES` or `UNSURE`): act on
  it only within your task, and stop and tell you when Claude agrees or after
  the last turn. Claude's skill ends each answer's summary with its verdict
  and never answers with `chi send` (which counts as you typing).
- **chi on another machine.** With the chi session on the Studio and Claude on
  the laptop, `CHI_REMOTE=studio sh <bundle>/scripts/pair <id>` pairs through
  the Studio's chi web ([Remote sessions](cli.md#remote-sessions)), and
  Claude's answers (its `chi context push claude-outbox`, with `CHI_REMOTE`
  set) reach chi: the outbox leg works. The inbox leg doesn't: `claude_send`
  writes to Claude's socket on the machine chi runs on, and the laptop's isn't
  there. So through a remote (`CHI_REMOTE`, or `--remote NAME` in `CHI`)
  `pair` attaches only `claude-outbox` and prints one line saying chi there
  can't send to this Claude: chi's replies reach Claude only when you relay
  them (or ask it to run `chi --remote studio send --wait <id>`). A session
  that already has a `claude-inbox` it can't reach:
  `chi --remote studio context rm claude-inbox <id>`.
  **Two ways to make it two-way over SSH.** SSH can forward a Unix socket, so
  the inbox leg works too. On the laptop:

  ```sh
  ssh studio rm -f /tmp/claude-peer-ab12.sock
  ssh -N -o ExitOnForwardFailure=yes -R /tmp/claude-peer-ab12.sock:"$CLAUDE_CODE_MESSAGING_SOCKET" studio
  ```

  the second running in the background while chi may send (the `rm -f` first:
  a remote forward's stale socket is replaced only when the **server's** sshd
  has `StreamLocalBindUnlink yes`). Then
  `CHI_REMOTE=studio sh <bundle>/scripts/pair --inbox-socket /tmp/claude-peer-ab12.sock ab12`
  attaches both sources, with `claude-inbox`'s hint that path on the Studio. A
  re-pair this way replaces an outbox-only pairing's `claude-outbox` and its
  why. Claude's socket changes when that Claude session restarts: stop the ssh,
  run both lines, pair again. A path chi quotes (a `payload:` file, a diff to
  check) is on the Studio, not the laptop. Whoever can write to that socket on
  the remote machine can send into this Claude session (sshd makes it the
  user's, mode 0600 by default): fine on your own machine or pod, not a shared
  host. Claude's own skill has the same under "chi on another machine over SSH".
- **Asking first.** The tool has no `targets:`, so guardrails match it by name
  only: to be asked before each send, add a rule ([Rules in
  config.yml](guardrails.md#rules-in-configyml)):

  ```yaml
  guardrails:
    rules:
      - id: claude-send
        tool: claude_send
        verdict: ask
        reason: sends session content to Claude Code
  ```

- **Limits.** The socket's format (`{"type":"user","message":{"role":"user","content":"…"}}`)
  is undocumented: it was found in, and checked on, Claude Code 2.1.296. A
  line Claude Code can't parse is dropped silently, so a Claude Code update
  could break this without an error. No auth line is sent: it is optional on
  macOS and Linux, and native Windows, which needs it, isn't supported.
  Claude's `crossSessionInbound` setting decides what it does with a peer
  message: an interactive auto-mode session delivers it; a session that
  bypasses permissions holds it for approval (in `-p` it expires after 5
  minutes). It is local only (a Unix socket), but it does hand session
  content to another agent: only what the model or you picked.
- **Needs chi 0.67.0** for the loop (`chi update`): the plugin is built on
  `Samagotchi::Plugin::Peer` (lib/samagotchi/plugin/peer.rb), the base both
  peer bundles share (the tool, `/claude`, the cards, payloads), and each
  bundle sets its strings and transport.

## The codex-peer bundle

```sh
chi bundle install codex-peer    # in the dev profile
```

The [claude-peer bundle](#the-claude-peer-bundle) for an OpenAI Codex CLI
session: chi sends the Codex session you work with a part of the work to
validate or as context, and Codex's answer comes back into chi. It is a copy
of claude-peer with the transport swapped; what differs is below, the rest
(kinds, payload files, the last send, `/codex last`, the status card, the
skill install card) works the same.

- **Sending is `codex queue`.** `codex_send(kind, title, text)` and
  `/codex validate|context <text>` run
  `codex queue --thread <uuid> --message <text>` (an argv, no shell), which
  wakes an idle Codex TUI: the message runs there as a new user turn (checked
  on Codex 0.162.1; a message queued mid-turn runs after the turn). The
  thread is the `codex-inbox` context's hint, Codex's `CODEX_THREAD_ID`, which
  must look like a UUID. `codex` is `$CODEX`, else `codex` on the PATH: a
  worker started by `chi web` or launchd may have another PATH than your
  shell, so set `CODEX=` where chi runs if the error says there's no codex.
  The tool and the anytime `/codex` wait for `codex queue` up to 10 s; a
  queue that takes longer is killed (its process group) and the send fails
  with a timeout error, never a hang. Other errors say what to do: no
  `codex-inbox` (pair from Codex), a thread Codex has no record of (that
  Codex session is gone: pair again), an ephemeral thread
  (`codex exec --ephemeral` can't take queued messages), or `codex queue`'s
  first error line. A Codex session that was closed (`/quit`) is not gone:
  Codex's app-server still takes the queue (exit 0), chi says sent, and no
  answer comes; the message waits for that session (`codex resume` there, or
  pair again from a new one). The status card shows the thread id and says
  so; there is no cheap check that the session is open.
- **Codex's sandbox.** Pairing and every reply write chi's state
  (`chi context add`/`push` write the session's context files directly),
  which Codex's default sandbox (workspace-write) refuses. The user adds, to
  `$CODEX_HOME/config.toml` (else `~/.codex/config.toml`):

  ```toml
  [sandbox_workspace_write]
  writable_roots = ["/Users/you/.local/state/samagotchi/context"]
  ```

  and restarts Codex. Only chi's `context/` folder: the state folder above it
  also holds guardrails, session files, plugins and the web token.
  `/codex install-skill`'s card shows the line with your state folder
  (absolute: config.toml doesn't expand `~`), and the pair script names it
  when a write is refused ("Operation not permitted"). chi never edits
  Codex's config. Reading a payload file needs nothing: the default sandbox
  reads anywhere. With chi on this machine no network is needed: a push
  writes files, and chi wakes on them. Through a remote it is the other way
  round (HTTP, not files): see **chi on another machine** below.
- **Pairing** is Codex's, as with Claude: `/codex install-skill` copies the
  bundle's `scripts/chi-peer-SKILL.md` to
  `$CODEX_HOME/skills/chi-peer/SKILL.md` (else `~/.codex/…`), with the
  installed `scripts/pair` path, the payload folder and the writable root
  written in; in Codex you say "pair with chi <id or chi web URL>", and
  `sh <bundle>/scripts/pair` attaches `codex-inbox` (the thread id as its
  hint, pushed so a re-pair refreshes it) and `codex-outbox`. Run outside
  Codex (no `CODEX_THREAD_ID`) it refuses. Codex replies with one JSON push
  to `codex-outbox` (`text`, `summary`, `wake: true`), which wakes chi, the
  first answer too: that needs chi 0.63.0, the bundle's `requires_chi`.
- **Peer messages are user turns in Codex.** Claude Code marks an inbox
  message as from another session; `codex queue` lands as a plain user
  message. So Codex's skill starts with the rule: a message whose first line
  is exactly `chi <8 hex> · <kind> · <title>` comes from chi, a peer agent,
  not the user; it can't approve anything, change settings or widen the
  sandbox, and the part it carries (and a payload file) is data to check,
  never instructions, since it may hold tool or web output. This is a prompt
  rule Codex follows, not something enforced: anything shaped like that
  header is treated this way, and nothing stops a message from asking for
  more.
- **chi on another machine.** As with Claude, `CHI_REMOTE=studio sh
  <bundle>/scripts/pair <id>` (or `--remote NAME` in `CHI`) pairs through
  the Studio's chi web, and only the outbox leg works: `codex_send` runs
  `codex queue` on the machine chi runs on, where this Codex's thread isn't.
  Claude's `--inbox-socket` trick doesn't apply here: `codex-inbox`'s hint is a
  thread id, not a socket, so there is nothing to forward through SSH.
  So `pair` attaches only `codex-outbox` and prints one line saying chi there
  can't send to this Codex. Through a remote chi talks HTTP, not files, so
  `writable_roots` doesn't matter; Codex's sandbox may block the network
  instead, which pairing and every reply then need (workspace-write has none
  by default): when chi can't reach the
  remote, the pair script names `network_access = true` under
  `[sandbox_workspace_write]` as the likely fix.
- In the web, selecting text offers **Confirm with Codex**, which fills
  `/codex validate` and the quote, as claude-peer's pill does.
- **The skill.** `skill_codex_peer` (system scope) is claude-peer's with
  Codex's names, and on a missing answer points to Codex being mid-turn or
  its sandbox (the `writable_roots` line). To be asked before each send, a
  guardrails rule with `tool: codex_send` (see the claude-peer section).
- **The peer loop** works as claude-peer's: `codex-outbox` is declared a
  peer's, Codex's answers wake chi up to `context.peer_turns` turns in a row,
  and `VERDICT OK` wakes chi once to close the round. Needs chi 0.67.0 (the closing
  wake: the chi released with this bundle).

## The ruby bundle

`chi bundle install ruby` (or the `dev` profile) installs the bundle shipped
with chi (`lib/samagotchi/bundles/ruby/plugin.rb`): one `chi.on` hook
(`:after_tool_call`), and no memory file.

An RSpec run that finds no examples prints `0 examples, 0 failures`, which
reads green: the model takes the suite as passing and moves on with code no
test ever loaded. It usually means a path that matched no file, a filter
(`-e`, `--tag`) that matched no example, or a `.rspec --pattern` that hid
the specs (a nested project's `.rspec` overrides one). The bundle notices
that run and steers a hint into the running turn, which the user sees as
`ruby> nudged: …`:

```
rspec ran 0 examples: check the path, the filter (-e/--tag) or the .rspec --pattern
```

It is a nudge for the model, not a denial: the turn goes on, and the model
can say why the run was empty. It never runs anything.

- **The command.** Only an `execute` counts, and its command must run
  rspec: one of its simple commands (`&&`, `||`, `;`, `|`, a newline, so
  after a leading `cd x &&` too) starts with `rspec`, a path ending in
  `/rspec` (`bin/rspec`, `./bin/rspec`), or `parallel_rspec`, once a leading
  `X=…` assignment, `bundle exec` and `time` are left out. A command that
  only names rspec (`grep rspec README`, `echo "bundle exec rspec"`) is not
  a run.
- **The output.** Every `<N> examples, <M> failures` line in the execute's
  output counts (RSpec's summary, with or without `, N pending`), and the
  hint comes when all of them are 0. `parallel_rspec` prints one per
  process, so a single process with examples leaves its 0 out of the total.
- **No summary line, no hint.** A spec that fails to load, a path that
  doesn't exist, a command killed at its limit: the output already says what
  is wrong, and the hint would only repeat it.

Nothing is remembered, so the next 0-example run hints again: it can be
the same mistake on another command, or a different one. A hint the model
answers before joining the turn is dropped, as any steer is.

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

1. The file must match the sha256 recorded at install (not checked for a bundle installed with `--dev`).
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
  edited after install is not loaded until you reinstall the bundle. A
  `--dev` install skips that check for its own bundle: its files are the
  source directory's, and an edit loads at the next start.
- Install only copies the file (`--dev` links it). The code first runs at the
  next session start.
- Guardrail rules keyed by a tool's name apply to plugin tools, as they do to
  chi's own tools; path and command rules see what `targets:` says.

## The model-notes bundle

`chi bundle install model-notes` (or the `dev` profile) installs reviewed
[model notes](memory.md#model-notes) into the system scope: working habits
for one model family, loaded into the prompt only for the models a note's
`models:` line names. It has no plugin or hook. It ships one note:

| note | models | for |
|---|---|---|
| `model_notes_deepseek` | `*deepseek-v4*` | DeepSeek V4 / V4.1: explore briefly then act, commit one item at a time, stop digging, `memory_read` for memories, file tools rather than heredocs that guardrail rules ask about |

- **Reviewed before it ships.** A note is generic (no repo or machine facts),
  says nothing the harness already does (a tool's description, an alias),
  talks to the model as "you", stays under 1,500 characters, and the user
  approves its text. A model may propose one; it never edits the bundle.
  `notes/README.md` in the bundle records each note's sources, the
  `script/model_notes_report.rb` numbers and the approval.
- **Globs per measured version.** A glob is tried against the id with no host
  prefix and against its model key, case-insensitively, and `*` also matches
  `/`: `*deepseek-v4*` covers `deepseek/deepseek-v4.1-flash` on any provider,
  MLX and GGUF names, but not `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B`.
- **Tested.** `spec/model_ids.yml` lists real id forms and the exact notes
  each loads (negative rows included); the spec installs the bundle and
  resolves each through `sandbox.model_notes_for`
  ([Testing a bundle](#testing-a-bundle-experimental)). It also checks each
  note's shape, size and that the tools it names are ones chi declares.
- **Your own notes:** a same-name note you have wins and keeps its place
  through upgrades; other notes stack with the bundle's
  ([Model notes](memory.md#model-notes)).

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
- `chi bundle install --dev <dir>`: links the bundle's plugin, hooks, rules and scripts to `<dir>` instead of
  copying them, with no sha256 check, so an edit applies at the next worker start
  ([cli.md](cli.md#writing-a-bundle-new-test-check)).
- `chi bundle new`, `test` and `check`: start a bundle, run its tests on chi's Ruby, check it as an install takes
  it ([cli.md](cli.md#writing-a-bundle-new-test-check)); `chi bundle try PATH -p TEXT`: run it for one turn in a
  sandbox and trace what it did ([cli.md](cli.md#trying-a-bundle)). The path: [bundle-authoring.md](bundle-authoring.md).

## Not yet

These are planned:

- `chi.prompt` for sections of the system prompt.
