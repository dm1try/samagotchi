# Bundles

What each shipped bundle does for you, its commands, settings and files. A bundle's code is written only against
the plugin API ([plugins.md](plugins.md)); install, upgrade and the `chi bundle` commands are in
[plugins.md](plugins.md#the-bundle-commands) and [cli.md](cli.md). Two shipped bundles are documented with the
feature they belong to: **source-links** in [hooks.md](hooks.md#the-source-links-bundle) and **known-names** in
[guardrails.md](guardrails.md#the-known-names-bundle).

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
([chi.tool_source](plugins.md#chitool_sourcecall-acts_as-label-wait-prefix), a group
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
  server in an [init task](plugins.md#chiinitlabel-provides_tools-false-quiet-false-timeout-nil-failed-nil--ctx--):
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
  ([Returning images](plugins.md#returning-images): at most 4 per call, a line
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
- **Stop.** The servers stop with chi ([Shutdown](plugins.md#shutdown)): stdin is
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
  `mcp_<server>_<tool>` name ([acts_as:](plugins.md#guardrails)), so `tool:
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

The state is one file per session, `state.json` in `ctx.session_dir` (`{"cap": 3.0, "step": 3.0}`), removed
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

The state is one file per session, `state.json` in `ctx.session_dir` (`{"tool_calls": {"cap": 800, "step":
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
(`plugins/check-in/sessions/<id>/state.json`), so it outlasts a worker's restart
and goes with the session; another session starts from config.yml:

| | |
|---|---|
| `/checkin` | on or off, the mode, the threshold and this turn's count |
| `/checkin on` / `off` | check in, or not |
| `/checkin 30` | check in after 30 tool calls, then every 30 |
| `/checkin mode ask` / `nudge` / `notify` | the mode |
| `/checkin nudge` / `later` / `stop` | the card's actions, also by hand |

**Asking System 1 (audit).** Each check-in also asks the cheap judgment model
`check-in.progress` — "Is this turn still making progress toward what the user
asked?" — on a side thread, with the owner's prompt, the calls since the last
check-in (each cut as it is captured, about 4 KB in all), the count and the
elapsed time. It is off until you give it a mode in
[`system_one.judgments`](configuration.md#bundles-judgments), and nothing is
acted on: the answer is saved, and so is what the user then did with the card
(`nudge`, `keep_going`, `stop`, or `turn_stopped` when the card was still open
when the turn ended), as a label on that run for a later look. The card, the
nudge and the notice are the same either way. See
[System 1's saved runs](system-one.md).

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

Proposes the branch's open GitHub pull request to a session as a candidate
`pr-<n>` when its worker starts (not in a scratch session; quietly nothing
without `gh`, a repository or an open PR): it is attached once you mention it
(`#N`, the branch or its URL; [Candidates](context.md#candidates)). It resolves
PR URLs for `chi context add`. Its script prints the PR as text
and a summary of what changed in counts, authors and states only; it wakes
the session for a review requesting changes, checks turning red, or the PR
merged or closed. In the web, a `path:line` in a worker's answer links to
that line of the session's PR ([Line links](context.md#line-links); `line_links:
always` for the REPL and `chi -p` too), and its ref menu offers the file
here and a "PR diff" action (`event[:refs]`). `auto_attach: attach` attaches
it at once (the old default), `off` does nothing ([Propose, attach or
off](context.md#propose-attach-or-off)).
See [Attached context](context.md#github-prs-the-github-pr-bundle).

## The coordinator bundle

```sh
chi bundle install coordinator    # in the dev profile
```

chi as a coordinator of parallel work, the way you would run several agents
yourself: split the work, one git worktree and child session per task, keep
talking while they run, check each report, and merge only when you allow it. It
works in a session with a worker (plain `chi`, the web). A `--no-shared` REPL
or `-p` gets no delegate reports, so the children's replies wouldn't come back
by themselves there.

- **The skill.** `skill_coordinator` (system scope; its index line says what
  it is for, from the manifest's `description:`) holds the steps. The model
  creates each worktree with `execute` (`git worktree add ../<repo>-<task> -b
  <branch>`), starts a child there with `delegate wait: false, cwd:`, tells
  you what started and ends its turn. When a child's report comes, it checks
  the branch (`git log`, `git diff --stat`, the tests the child names) before
  telling you. Before merging (**Merges** below) it checks that its
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
  and merges as it always does. Experimental: it may go if it doesn't earn its place.
- **The coordinator toolkit.** The bundle declares `coordinator`: `lean`
  plus `delegate`, `delegate_result`, `list_sessions` and `objectives` (the skill records moves with it)
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
- **Merges.** Your approval is chi's own card, not a question from the model. When its verdict on a branch is "done and
  verified" (no doubts) and the branch can fast-forward, and `chi guardrails rule git-merge` prints `asks`, and it read the branch's whole diff in this session, not only the stat, the skill says `Merging <branch>: <verdict>` and runs
  `git merge --ff-only <branch>` alone. You then get the approval card, or, if you allowed the rule in this repo, it
  passes: home projects you trust merge on green, an unknown one still asks. Anything else (tests not run in this
  session, a child that named none, a resumed session's old verdict, the rule off, doubts) goes back to a question
  (`ask_user_question`). With no grant, a yes there is followed by chi's card on the merge, and declining the card is a
  no. A Deny is saved and not retried: the model reports it and leaves the branch until you say otherwise. Under `--non-interactive` no one can answer, so a merge is
  denied and it tells you. A parent agent may give Allow once under `guardrails.parent_answers: soft`, as it may answer
  a question today.

  The bundle's rule `git-merge` (`guardrails/merge.yml`) asks before every `git merge`, whatever the
  branch, including `git -C`, `--git-dir=`, a `cd` before it and `sh -c`. It offers Allow once and **Allow rule git-merge
  in this repo**: that grant holds for every later merge in the repository, in each of its worktrees and sessions,
  and for nothing else. `git merge y && git push` still asks, once ([Approvals](guardrails.md#approvals)). `merge-base`,
  `merge-tree`, `merge-file`, `mergetool` and a merge whose first word is `--abort`, `--continue` or `--quit` don't ask;
  `git pull` and `gh pr merge` are not covered. It votes in every session on a machine with this bundle, in any repo,
  children and background builds too, so a child's `git merge main` raises a card. A `--non-interactive` merge is denied,
  with nobody to ask. It over-asks where the words are data (a commit message, `chi send -m`), and when merging the default branch into
  a feature branch. `guardrails.disable: [git-merge]` switches it off. A grant goes by the repository chi is in, so
  `git -C other merge` or `cd other && git merge` from a granted repo passes: an accident guard, as the rest
  of the rules are. "Rule in this repo" tapped on a child's `git merge main` frees every merge there, as the rule's
  reason says. A `git-merge` rule copied into config.yml votes first and keeps its behaviour; the old snippet,
  `\bgit\s+merge\b`, also matches `git merge-base`, so drop your copy.

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
    ([`chi.annotation`](plugins.md#chiannotationlabel-command-template-quote-send-false)):
    it fills the composer with `/claude validate` and the quote, for you to
    add what needs confirming.
  - `/claude last` sends the model's last completed answer as context. Mid-turn
    it is the answer before the running turn, never the turn's partial text;
    a cancelled or failed turn has no answer, so the one before it goes.
- **The peer loop.** The bundle declares `claude-outbox` a peer's
  ([`chi.peer_source`](plugins.md#chipeer_sourcename-label)), so Claude's answers
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
- **A continue.** The pairing's two sources are pushed, so they stay with
  the old session when you continue it ([Movable
  context](context.md#peers-and-a-continue)). The new session's worker posts
  Claude one message, from a quiet init task, to the socket the old
  `claude-inbox` last had:

  ```
  chi <old> · moved · continued as <new id>
  This chi session was continued as <new id>. Pair with <new id> the way you paired with <old>, then answer there (chi context push claude-outbox <new id>).
  ```

  Claude's skill pairs again with the new id the same way it paired before
  (the same `CHI_REMOTE` and `--inbox-socket`). It is posted once (a marker
  under the bundle's `sessions/<id>/`, so a worker restart doesn't post it
  again); a post that fails (that Claude session ended) is logged and
  dropped. An outbox-only pairing has no inbox to post to: Claude's next
  answer to the old id is refused with the new one (`<old> was continued as
  <id>`), and the skill pairs again and pushes the answer there. The new
  session's note says which: `Left with 3f2a9c1e: claude-inbox, claude-outbox
  (Claude's pairing: chi asks Claude to pair again with this session).`, or
  `(Claude pairs again when it next answers)`.
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
  first answer too (that needs chi 0.63.0; the bundle's `requires_chi` is `>= 0.70.0`).
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
- **A continue** works as claude-peer's: the new session queues Codex the
  `moved` message on the thread the old `codex-inbox` named, once, and
  Codex's skill pairs again with the new id (the same `CHI_REMOTE`, if any).
  A pairing through a remote has no inbox: Codex pairs again when its next
  push is refused. A closed Codex session still takes the message; it waits
  for `codex resume` there.

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

## The model-notes bundle

`chi bundle install model-notes` (or the `dev` profile) installs reviewed
[model notes](memory.md#model-notes) into the system scope: working habits
for one model family, loaded into the prompt only for the models a note's
`models:` line names. It has no plugin or hook. It ships two notes:

| note | models | for |
|---|---|---|
| `model_notes_deepseek` | `*deepseek-v4*` | DeepSeek V4 / V4.1: explore briefly then act, commit one item at a time, stop digging, `memory_read` for memories, file tools rather than heredocs that guardrail rules ask about |
| `model_notes_tone` | `*` | every model: answer first, in plain words; no preambles, restated questions or closing offers; lists only for steps or parallel items |

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
- **Tested.** `lib/samagotchi/bundles/model-notes/spec/model_ids.yml` lists real id forms and the exact notes
  each loads (negative rows included); the spec installs the bundle and
  resolves each through `sandbox.model_notes_for`
  ([Testing a bundle](plugins.md#testing-a-bundle-experimental)). It also checks each
  note's shape, size and that the tools it names are ones chi declares.
- **Your own notes:** a same-name note you have wins and keeps its place
  through upgrades; other notes stack with the bundle's
  ([Model notes](memory.md#model-notes)).

## The decision-card bundle

`chi bundle install decision-card` (or the `dev` profile) installs the bundle shipped with chi. It is a try-out, written
only against this API (`lib/samagotchi/bundles/decision-card/plugin.rb`). It does nothing in a session with no
[objectives](sessions.md#objectives): no request, no card.

In a session with an active objective, an answer that is long and ends in a question gets a card when the turn is over:
a short summary, the question, and the objective it concerns when the model names one. You answer in the composer.
The card has no buttons, so it invents no options, and it is no "needs you": no push, no waiting mark.

- **The gate**: a completed owner's turn (not a stopped one, a participant's or a `--non-interactive` one), at least
  `min_chars` characters, a question mark that ends a word in the last `tail_chars` of the prose (code is left out). All of
  it is read before any request.
- **The request**: one side answer (`ctx.ask_model`) about the turn's prompt and answer, with the list in its prompt. It
  counts in `/stats`' side requests under `decision-card`. If the model says the answer asks nothing, or leaves out the
  summary or the question, there is no card.
- **It may be late.** It runs on a thread, so the turn's end doesn't wait, and a one-slot local server answers it after
  the running request. A new turn cancels it, which frees that slot, and a card still to come is dropped.
- **A shown card folds** to a line (`Asked: …`) when your next turn starts (a reminder's, a child's report's or a participant's turn leaves it open): in the web a row in the same place; the terminals
  print it as an update.
- **A failed request** is only logged (`no_card` in the debug log): no card, no notice, no push.
- **Nothing else changes**: nothing enters the conversation, so the next request is byte for byte what it would be
  without the bundle. The card lives in the session's `cards.json`, as any card. `chi bundle uninstall decision-card` takes
  it all away (a member of a profile you uninstall stays out); a session you have open needs `chi sessions restart ID`.

```yaml
bundles:
  decision-card:
    min_chars: 1200    # how long an answer is long
    tail_chars: 300    # how far from the end the question may be
    model: null        # a cheap configured model ("host:id" or an alias); null is the session's own
    timeout: 120       # seconds the side request may take (a number)
    max_tokens: 300    # the side answer's limit
```
