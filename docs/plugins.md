# Plugins

A bundle can ship one Ruby file, its **plugin**, that adds slash commands,
tools, hooks and background setup to every session. Its hooks are ordinary
bundle hooks ([hooks.md](hooks.md)). Its commands and tools work like chi's
own.

This page is the plugin API and its reference. What each shipped bundle does for a user (btw, mcp, cost-cap,
claude-peer…) is in [bundles.md](bundles.md).

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
settings: [greeting]         # optional: the keys config.yml bundles: my-bundle: may have, written the same way
                             # (any also takes a mapping or a list). With it, another key warns; a session
                             # setting needn't be listed twice
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

A config.yml `bundles:` name that no installed bundle has shows a warning when a session starts, in every UI (`config>`…);
so does a key or a value's type the manifest's `settings:` rules out. It warns only: the session goes on, and a
bundle with no `settings:` has its keys left alone. `chi bundle check --set` warns the same way (`settings`).

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

#### Commands that ask: `ctx.cache_confirm`

A command whose change restarts the model server's prompt cache (one that changes the text of a
[prompt section](#chiprompt_sectionname--ctx---and-chiprompt_changed)) asks first, as `/thinking` and `/toolkit` do:
`ctx.cache_confirm(line, changed:)` returns nil when it may apply now, or a confirm to return with the command's
text, `[text, confirm]`, changing nothing. `line` is the command line that applies it (without `--yes`), `changed:`
whether your text would change. chi decides the rest: it asks only a person at a web tab or a TUI (never `chi send`,
a delegate or `chi -p`), only once the session has a model reply, never for a line with `--yes` (or `-y`), and
writes the confirm's text (the conversation's size to read again; on an `api: anthropic` host, that preserved
thinking is dropped). The TUI prefills `line --yes`, the web shows an Apply button that sends it, and the command
then runs again with `--yes` in `args` (drop it from your words). Outside a command (a hook, an init task, your
own thread) it is always nil. A plain String or nil return is unchanged.

A command that asks must not be `anytime: true`: the REPL shows only an anytime command's text, so its Apply would
be lost. Needs chi 0.132.0.

```ruby
chi.command "/tone", "show or set this session's tone" do |args, ctx|
  word = (args.split - %w[--yes -y]).join(" ")
  ask = ctx.cache_confirm("/tone #{word}", changed: word != current_tone)
  next ["Switching to #{word} restarts the prompt cache.", ask] if ask

  save_tone(word)
  @chi.prompt_changed!
  "tone: #{word} from the next turn"
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
raises, the error is logged and the hook is skipped; the first failure per
event in a worker also shows once in every UI (`plugins> plugin.rb (bundle x) before_turn hook failed (…)`).

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
bundle](bundles.md#the-loop-guard-bundle)).

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
  [The mcp bundle](bundles.md#the-mcp-bundle), Stop).

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
restarts the prompt cache for the whole conversation, so a command that changes it asks first
([Commands that ask](#commands-that-ask-ctxcache_confirm)) and calls `chi.prompt_changed!` only once it applies.
Keep `chi` from `register` for that (`@chi = chi`). `/stats` names the sections the prompt holds
(`prompt sections: tone (tone)`). The test kit runs them as a build does (`bundle.prompt_text`,
`bundle.prompt_sections`) and counts `chi.prompt_changed!` (`bundle.prompt_changes`). Needs chi
0.132.0: a bundle using it sets `requires_chi`.

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

### `chi.judgment(name, questions:, positive: nil, negative: nil)`

A cheap System 1 question this bundle asks with `ctx.judge` or `ctx.judge_later`: see
[Judgments](#judgments-chijudgment-and-ctxjudge).

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
| `ctx.review?` | whether the session is a review session (`chi review`): one its participants read, not the owner's working session |
| `ctx.frontend` | what runs the session, read now: `:repl` (the REPL, `-p` without `--non-interactive`), `:one_shot` (`-p --non-interactive`: one turn, then exit) or `:worker` (a session worker: the web, an attached TUI). Only a worker's answers reach the web while it runs; a REPL's show there once the session is opened. Until the host sets it (while the plugins load, inside `Engine.new`) it reads `:one_shot`, so read it in hooks and init tasks, not in `register` |
| `ctx.continues` | the id of the session this one continues (a [continue](sessions.md#session-chains)'s new link), else nil |
| `ctx.fork?` | whether the session is a fork (`ctx.sessions.fork`): it has a parent but isn't a delegate child, and started from a conversation, so its first prompt isn't its first user message |
| `ctx.model` | the model the session runs on now: its resolved ref (`host:id`), right after `/model` too |
| `ctx.model_key` | that model's memory overlay key (`<name>.<key>.md`, what `memory_write current_model_only` writes) |
| `ctx.model_names` | the names chi's own per-model config looks that model up under (a `models:` map in config.yml): as typed (an alias), the alias's target, the resolved ref, without the host, the bare id; deduped, most specific first, frozen (`[]` when it doesn't resolve). Match a map of yours over them downcased, first hit, as chi does. Needs chi 0.132.0 |
| `ctx.cost` | the session's spend so far, read now, as a frozen value: `total` (USD, reported + estimated, side requests included; 0.0 before any), `reported` (by providers, `usage.cost`), `estimated` (from `hosts.<name>.models` prices; a generation is one or the other, never both), `side` (recap, `/btw`, `ask_model`: their share of `total`) and `known?` (false while generations or side requests ran but none was reported or priced, so a limit on it can't be enforced; a session with some priced generations reads known, the unpriced ones counting 0). It includes the running turn's finished generations and what earlier workers of the session spent. Use its methods, not its class. Needs chi 0.83.0 |
| `ctx.usage` | the session's work so far, read now, as a frozen value: `turns` (finished ones and the running one), `tool_calls` and `tool_calls_by_tool` (every call, running ones included; canonical names: an alias counts under its tool, a `call_tool` call under the inner tool), `steps` (the loop rounds that dispatched tools, `/stats`' iterations) and `active_ms` (`active_minutes` too): work time, the generations' time plus the finished tool calls' time, never the waits between them (a question, an approval, the user's answer to `ask_user_question`), with `tool_ms_by_tool` its tool part by tool, so a waiting tool's time (`task_wait`) can be left out. Its counts are the ones `/stats` and `chi sessions stats` show, earlier workers' included. Use its methods, not its class. Needs chi 0.100.0 (guard it with `ctx.respond_to?(:usage)`) |
| `ctx.turn_author` | who wrote the running turn when it isn't the session's owner: a participant's `"p:<id>"` (`chi share`); nil for the owner's turns and between turns. Every hook event of such a turn carries the same as `author:`. The handler runs with the owner's power whatever the author ([hooks](hooks.md#participants-turns)). Needs chi 0.105.0 (guard it with `ctx.respond_to?(:turn_author)`) |
| `ctx.settings` | the bundle's settings, frozen: config.yml's `bundles: <bundle>:` with the session's own `--set` values laid over it ([Per-session settings](#per-session-settings)); the config alone until the session is bound (in `register` and `chi.ctx`) |
| `ctx.data_dir` | `$XDG_STATE_HOME/samagotchi/plugins/<bundle>/`, created on first use: what the bundle keeps across sessions |
| `ctx.session_dir` | this session's own folder there, created on use, read now; nil with no session yet. chi removes it when the session is deleted, discarded or pruned, so don't build the path yourself. A `sessions/<id>.json` an older version of your bundle kept moves in as `state.json` (chi still removes one left there). Needs chi newer than 0.142.0 |
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
| `ctx.judge(name, state:)`, `ctx.judge_later(name, state:) { |result| … }`, `ctx.judgments` | a cheap System 1 question this bundle declared, saved as a run: see [Judgments](#judgments-chijudgment-and-ctxjudge) |
| `ctx.http` | an HTTP client for calling services (`get`, `post_json`, `request`): see [Calling services](#calling-services-ctxhttp) |
| `ctx.sessions` | fork, send to, read, list and stop other sessions: see [Other sessions](#other-sessions-ctxsessions) |
| `ctx.toolkit` | the name of the session's toolkit (`full` for a session from before toolkits); nil with no session |
| `ctx.declared_tools` | the tool names the session's next turn declares (its toolkit resolved, with its own adds and removes): ask this, not the name, whether a tool is there |
| `ctx.use_toolkit(name)` | put the session on toolkit `name` (yours from `chi.toolkit`, or chi's): saved, applied at the next turn's start and announced (`toolkit> toolkit: NAME from the next turn's start`, the web's tools chip follows). Only before the session's first model reply and outside a turn (the declared tools start every request, and a plugin doesn't ask first); otherwise it returns false and changes nothing: tell the user to run `/toolkit NAME`. An unknown name raises ArgumentError. Needs chi 0.66.0 |
| `ctx.load_tools(names)` | load tools the session reaches but doesn't declare, so the model calls them by name: built-ins (`"delegate"`, `"chi/delegate"`), MCP tools (`"mcp_fs_read"`, `"fs/read"`). Returns the names it staged (the wire names); a declared tool, one loaded before, a removed or unknown one is skipped (an unknown one logged), so calling it every turn is fine. From a `before_turn` hook it loads for that turn; anywhere else (mid-turn too) from the next turn's start. Call it from a hook: before the session's first turn its toolkit isn't applied yet and nothing resolves. **A hint, not access**: the tools keep their guardrails and approvals, and only a host that takes tool changes (`api: anthropic`, not Fireworks) gets one, as a system message after the user's (`[tools loaded: delegate (your-bundle)]` in the session, a notice line live); elsewhere nothing is sent or saved, and the tools stay reachable with `call_tool`. A hook may switch the model after you call it, so the return value can't promise delivery. Raises ArgumentError for anything but an Array. Needs chi 0.99.0 |
| `ctx.context` | attach outside text to this session and list it: see [Attached context](#attached-context-ctxcontext) |
| `ctx.cache_confirm(line, changed:)` | inside a command: nil to apply a prompt-cache-restarting change now, or a confirm to return as `[text, confirm]`: see [Commands that ask](#commands-that-ask-ctxcache_confirm). Needs chi 0.132.0 |

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

## Judgments: `chi.judgment` and `ctx.judge`

A judgment is a small question for [System 1](system-one.md), the cheap judgment model: a yes/no with a probability, a
choice, or a score, in about the time a tool call takes. Where `ctx.ask_model` gets free text from the session's model,
a judgment gets a number from the model the user set for this, and every ask is saved, so a later comparison or
fine-tune has what was sent and what came of it. It is chi's own layer (approvals use the same `Client` and runs) and
gives a bundle no new power. Needs chi 0.142.0 (guard it with `chi.respond_to?(:judgment)`).

```ruby
def register(chi)
  chi.judgment "progress", questions: { "progress" => { type: "noul", instructions: "Is this turn still making progress?" } },
                           positive: "keep_going", negative: "stop"

  chi.on(:after_tool_call) do |_event, ctx|
    @run = ctx.judge_later("progress", state: { prompt: @prompt, calls: @calls }) do |result|
      next if result.no_judgment? || result.audit?

      ctx.notify("this turn looks stuck") if result.p < 0.2
    end
  end

  chi.command("/going", "Say the turn is fine") do |_args, ctx|
    ctx.judgments.label(@run, "keep_going", by: "command")
    nil
  end
end
```

**It is off until the user says so.** The full name is `<bundle>.<name>` (`check-in.progress`), and it asks nothing until
config.yml's [`system_one.judgments`](configuration.md#bundles-judgments) gives it a mode, `audit` or `on`, which it can
also give a host and a model of its own. Neither `audit` nor `on` changes anything by itself: `result.audit?` is the bundle's
to honour (in audit, look and don't act). A full name is dot-separated words of a-z, 0-9, `_` and `-`, so a bundle whose
name has a capital or a dot fails to load on this call. `approvals`, `context`, `guardrails` and `toolkit` as a first word and
`.replay` at the end are core's.

`chi.judgment`:

- `questions:` is a map of id to `{type:, instructions:, criteria:}`: `"noul"`, `"choice"` (criteria: `{name => description or
  nil}`) or `"score"` (criteria: a list of levels). Or a callable given `ctx`, called at each ask, where they vary per
  session. A plain map is checked when declared, a bad one failing the plugin's load; a callable's result at each ask, raising there.
- `positive:` and `negative:` name the label values that say the answer was right and wrong (a word or a list). They
  are saved in each run for a later comparison, and don't limit `label`.

`ctx.judge(name, state:)` asks and waits, at most `system_one.timeout_ms`. `name` is as declared, without the bundle.
`state:` is a String, Hash or Array: what the question is about, sent to the System 1 host and saved as sent (bytes that
aren't UTF-8 replaced). It stops when the turn is stopped, as `ctx.http` does. **It returns a Result, and doesn't raise for
anything that goes wrong on the way:**

| On the Result | |
|---|---|
| `no_judgment?` | no answers |
| `answers` | `{id => answer}`: `.noul`, `.choice`, `.score` (a score is the probability-weighted level index, not a level number), `.level` (the name of the most likely level, when the response has a legend), `.confidence`, `.probabilities` |
| `p(id)` | a `noul` question's probability of yes (nil for no answer, or another type); no id: the only question's |
| `audit?`, `mode` | the judgment's mode: `"off"`, `"audit"` or `"on"` |
| `run_id` | for `ctx.judgments`; nil when no run was saved |
| `reason` | why there's no answer, below; nil with answers |

| `reason` | When | A run? |
|---|---|---|
| `:off` | no mode set | no |
| `:no_host` | no `system_one.host`, nor one of its own, or a config still on the moved `guardrails.system_one` keys | no |
| `:no_session` | no session bound yet | no |
| `:failed` | the host couldn't be reached, timed out, refused, or sent something unusable | yes, with `failure` |
| `:cancelled` | the turn was stopped during the ask | yes, with `failure: "cancelled"` |
| `:busy` | `judge_later` only: this judgment's last one still runs | yes, `asked: false` |

An undeclared name or a bad `state:` (not a String, Hash or Array, or nested too deep) raises `ArgumentError`, as `ask_model` does for a bad model, and so does `ctx.judge` in a
`:generation_progress` handler, whose stream it would hold.

`ctx.judge_later(name, state:) { |result| … }` asks on its own thread and **returns the run's id at once** (nil when no run will be
saved). One per judgment runs at a time. The block is optional, and gets the Result once, on another thread, however
the ask went, also when nothing was asked. A block that raises is logged.

- **The block's `ctx.*` act on the session as it is then**, not as the handler's event: the turn may have ended, or the
  worker moved to another session. Compare `ctx.session_id` with the one you started from before acting.
- A `judge_later` still running when chi shuts down gets a second, then it and its run are lost. On `chi -p
  --non-interactive` this is the usual end of a slow ask.
- Snapshot what you need: the block sees only what it closes over.

`ctx.judgments.label(run_id, value, by: nil, strength: nil, question: nil)` saves what came of a run, as a later line on it;
`ctx.judgments.acted(run_id, what)` saves what the bundle did about it. Both return whether they saved anything. `value`
and `what` are the bundle's own words (up to 200 characters), mapped only at analysis. `by:` says what said it, always after
the bundle's name (`check-in:card`). `strength:` is `"strong"` (the user said so) or `"weak"` (they may have clicked out of habit).
A `nil` id saves nothing and isn't an error, so a run that wasn't saved needs no check; an id of anything this bundle didn't declare raises `ArgumentError`.

**What's saved.** A run holds the state as sent: prompts, commands and whatever else the bundle put there, in the
user's state dir, for as long as sessions last ([System 1's saved runs](system-one.md)). Nothing is saved for a scratch
session or in a participant's turn, later lines included (those asks still go to the host). `system_one.runs: off` stops all of it.

**Cost.** A judgment stays out of the session's spend, as all of System 1's do, and **a bundle's judgments on a hosted host aren't under a
cost cap**. At about $0.000015 a question that's accepted; ask at a human pace all the same, not per stream batch. The tokens a host reports are
saved in the run (`usage`).

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
  - This session's movable attached context goes too, with a note naming it
    (see [Movable context](context.md#movable-context)).
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
ctx.context.propose(url: "https://github.com/acme/app/pull/42", title: "#42 Make the thing", mentions: ["#42", "feat/x"])
ctx.context.candidates  # => [#<data Candidate name="pr-42", url="https://…", title="#42 Make the thing", …>]
ctx.context.withdraw("pr-42")  # => true
ctx.context.left_behind  # => [#<data Left name="claude-inbox", hint="/tmp/…sock", from="3f2a9c1e-…">]
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
  declined marker, by the name and by the URL. `movable: true|false` says
  whether a continue or a fork takes the source to the new session (by
  default a command source does; see [Movable context](context.md#movable-context)).
- `decline(url:)` or `decline(name:)` marks the source declined in this
  session, as the user's removal does: `attach` skips it from then on. With
  `url:`, the name and hint come from the bundle's provider (`name:`
  replaces the name). It returns the name. A source attached already stays
  attached (`chi context rm` removes it).
- `propose(url:, title:, name: nil, describe: nil, mentions: [])` or
  `propose(name:, cmd:, title:, describe: nil, mentions: [])` records a
  [candidate](context.md#candidates): a source proposed for this session,
  not attached. chi attaches it when the session's owner mentions one of its
  `mentions` in a prompt (the matching rules are in context.md), with the
  why "you mentioned …". `title` is what a person reads (no probabilities or
  place facts: "#42 Make the thing"), `describe` more of it. A candidate of
  that name stays as first proposed (a worker restart proposing again
  changes nothing). Nothing is proposed (nil) in a review session, for a
  source attached already (its name or its URL, at any scope), or for one
  the user removed from the session. A new candidate that an owner prompt
  already in the session mentions is attached at once: an init task's
  proposal usually lands while the first turn runs, and that turn's prompt
  still counts (its note comes with the next turn).
- `candidates` lists them (`ContextSources::Candidate`: `name`, `url`,
  `cmd`, `title`, `describe`, `mentions`, `proposed_by`, `at`), by name.
  Whether one is attached or declined is never stored on it: `chi context
  ls` and `/context` derive it from the session's sources and declined
  markers. `withdraw(name)` takes a candidate back (true when there was
  one); a source attached from it stays attached. Neither an attach nor a
  decline removes a candidate; deleting the session does.
- `left_behind` (read-only) lists what the continue that started this
  session left with the previous link ([Movable
  context](context.md#movable-context)): `ContextSources::Left` values with
  `name`, `hint` (the last pushed one, else the source's) and `from` (the
  previous link's id); `[]` for a session that isn't a continue's. The peer
  bundles read it to ask their peer to pair again (below).
- The source is the session's (not the project's), marked
  `added_by: plugin:<bundle>`. It is plugin code, so it isn't asked about as
  the agent's `chi context add --cmd` is.
- `list` gives the session's sources, its own then its project's (`[]` before
  the session has an id or its file is saved: a command before the first turn). `hint` is the
  one the last text gave (else the source's), `summary` that text's summary
  (nil before any text; chi 0.63.0).
- Two attaches of one source at once (a double click) both return its
  name.
- `attach`, `decline` and `propose` raise
  `Samagotchi::Plugin::AttachedContext::Error` with the reason (no session
  yet, no provider for the URL, a bad name).

The [github-pr bundle](bundles.md#the-github-pr-bundle) proposes the branch's PR from
a quiet `chi.init` task.

### Context providers in the manifest

A bundle can turn URLs into sources for every process, without loading
plugins (`chi context add URL`, `ctx.context.attach(url:)`):

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

**New API ships with its first caller:** a `chi.*` or `ctx.*` method arrives in the same change as a shipped bundle
that calls it, or for a real external bundle that does. No method on the chance that someone will want it.

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
   read as `self.class::X`. See the [claude-peer](bundles.md#the-claude-peer-bundle) and
   [codex-peer](bundles.md#the-codex-peer-bundle) bundles.
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
fails on a reference in neither (docs/testing.md). In `chi update`'s re-check of
an installed bundle the same scan warns only for a name this chi no longer has
(`Boundary.gone?`): a reference that still resolves gets no row.

**Used by shipped bundles today, but internal** (may change without notice; a
bundle that needs one should ask for an API instead):

- `Samagotchi::Tools::MemoryRead.memories_dir` and `Samagotchi::MemoryPaths.scope_dir`.
- `Samagotchi::Ref` / `Samagotchi::RefAction` constants and
  `Samagotchi::TokenUsage::CHARS_PER_TOKEN`.
- `Samagotchi::ProcessGroup.stop`, `Samagotchi::ProjectEnv`, `Samagotchi::Guardrails::ShellLex` and
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
bundle.command("/tone x", confirm: true)                 # sent from a web tab or a TUI: ctx.cache_confirm may ask
bundle.set(history: true, context_tokens: 900)           # a model reply to restart (ctx.cache_confirm), its size
bundle.set(model_names: %w[tiny box:gemma gemma])       # ctx.model_names (default: model_name and its id)
bundle.prompt_text                                       # the prompt sections' text, as a build runs them
bundle.tool("my_tool", path: "a.txt")                    # → the text the model reads
verdict = bundle.tool_call({ name: "execute", content: "rm -rf /" })
verdict.deny?                                            # a real Guardrails::Verdict (votes: verdict.votes)
bundle.notices.map(&:text)                               # also cards, steers, stops, generation_stops, questions
bundle.questions.last.effects                            # an ask_user's tags as given: { "Continue" => :spend }
bundle.answer({ selected: "yes" })                       # the next ask_user's answer
bundle.model_answers << "a summary"                      # the next ask_model's answer
bundle.judgments.answer("progress", noul: 0.9)           # ctx.judge's answer from now on; question: for one of several, or a block given the state
bundle.judgments.fail("progress")                        # a failed backend; mode("progress", "off"), no_host("progress") too
bundle.judgments.wait                                    # judge_later's threads and blocks are done
bundle.judgments.asks.last.state                         # the asks that reached System 1: name, state, questions, cancel
bundle.judgments.runs("progress").last["asked"]          # the runs as chi saves them; labels("progress"), acted_lines("progress") too
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
  instead of raising, for a wait whose timeout is fine; `process_gone?(pid)`; `time_bound(seconds, below: nil)`, a
  wall-clock upper bound scaled the same way and kept under `below:` (the unscaled deadline it tells apart from). Every deadline is multiplied by
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
