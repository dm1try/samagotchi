# Pages: scripts that say what to show

A page is a Ruby script that gets its data any way a script can (another program's `--format json`, a file, the
session files) and hands rows and text to `ui`. `chi page run NAME` runs it and stores what it built; what shows a
page draws from that stored result, so showing it runs nothing. Pages run from the terminal and show in chi web, where
Refresh runs them again ([In chi web](#in-chi-web)).

**A page is code you trust.** It runs as you, with your files and your network, like any Ruby script chi writes for
you. There is no sandbox.

## Asking chi for a page

Say what you want to see and that you want it kept: "make me a page of …", "I'd like to reopen this in the web: …",
"keep this as a page". chi follows its shipped pages skill (`skill_pages`, [docs/memory.md](memory.md#skills)): it
finds the pages folder with `chi self`, writes `NAME.rb` there, runs `chi page run NAME`, compares the stored rows
with where they came from, fixes what failed, and answers in a line or two with the link `[Title](#/p/NAME)` (with
Markdown off, the link is plain text: the page is in All sessions, under Pages). "Change the page …" edits the script
and runs it again; "remove the page …" is `chi page rm NAME`.

- It uses `chi page list`, the read tool, `chi page run` and `chi page rm`, never a shell command that names the pages
  folder (those ask you, and a turn nobody watches stops there).
- **Strict mode** (`guardrails.mode: strict`): writing the script asks (`write-outside-repo`: you, or whoever may
  answer for the session, such as a parent agent or System 1); if it is denied, chi says so and stops.
- A participant's turn ([chi share](cli.md)) can't write chi's config folder or run chi commands: a page asked for
  there is refused.

## A page

```ruby
# ~/.config/samagotchi/pages/usage.rb
page "Usage, last 7 days" do |ui|
  data = JSON.parse(`chi-usage --days 7 --format json`)
  ui.text "Stored cost per model. #{data["totals"]["turns"]} turns."
  ui.table data["groups"].map { |model, g| g.merge("model" => model) },
           columns: { "model" => "Model", "turns" => "Turns", "cost" => "Stored" },
           format: { "cost" => :money }, key: %w[turns cost],
           total: { "model" => "Total", "turns" => data["totals"]["turns"], "cost" => data["totals"]["cost"] }
end
```

```
$ chi page run usage
page usage: "Usage, last 7 days" (0.4 s)
- text: Stored cost per model. 412 turns.
- table, 3 rows, columns: Model, Turns, Stored
    claude:sonnet-5-5 | 96 | $14.2210
    openrouter:deepseek-v4 | 141 | $3.9042
    splash:qwen3.8-flash-next | 175 | $0.0000
    total: Total | 412 | $18.1252
```

The file is `NAME.rb` under `~/.config/samagotchi/pages/` (`$XDG_CONFIG_HOME/samagotchi/pages/`). A name is lowercase
letters, digits and hyphens, a letter or a digit first, at most 40. `json` is loaded; `require` anything else you use.

## What `ui` takes

A script calls `page "Title" do |ui| … end` once: a second call, or none, fails the run. The blocks show in the order
the script adds them, at most 20.

- **`ui.text(markdown)`**: a text block, Markdown. At most 16 KB.
- **`ui.table(rows, columns:, format: {}, key: nil, total: nil)`**: a table.
  - `rows`: a list of Hashes (string or symbol keys). At most 500 are kept; the rest are dropped and the page says how
    many.
  - `columns:` (required) a Hash `key => label` in the order to show, or a list of keys (the label is the key). At most
    12.
  - `format:` `key => :money` (`$14.2210`) or `:count` (`1.2k`, `3.4M`). Nothing else: format other columns as text
    yourself. The stored cell stays the number, so the column still sorts as numbers.
  - `key:` the columns a phone shows before a row is opened, besides the first column, which always shows. Without it:
    the first two columns whose cells are all numbers or empty.
  - `total:` a Hash by column key, shown as a last row.
  - A cell: a number stays a number, `nil` shows blank (`—` in the terminal), `true`/`false` stay, anything else is
    its text (NaN and Infinity too). A cell over 300 characters is cut with `…`.
- **`ui.walk(title:, actors:, steps:)`** (or one Hash): a scenario walk, the same data and rules as a `chi-ui` walk in
  an answer ([inline widgets](internals/inline-widgets.md#the-schemas)), drawn by the same widget. A walk the schema
  refuses fails the run with its reason.

A rule broken fails the run with a message naming the block and the limit: `table 2: column "cost" has format
:percent (use :money or :count)`, `table 1 has 13 columns (at most 12)`.

## Running

- `chi page run NAME` runs the script in a Ruby process of its own and prints a summary of each block: a text's first
  lines, a table's labels, first rows and total, a walk's step count. `--format json` prints the stored page.
- A run that fails (the script raised, has a syntax error, called `exit`, broke a limit, or printed more than 256 KB of
  blocks) prints `error: line 9: undefined method 'fetch' for nil`, the last lines of what the script wrote to stderr,
  and exits 1. **The result of the last good run is kept**: a bad edit never blanks the page.
- A run still going at **30 s** is stopped, with everything it started; the error says so. If what started the run
  dies first (a killed terminal or chi web), the run stops itself a few seconds after its 30 s and records the same
  error. Its output then has nowhere to go: a script that prints a lot may fail with `Broken pipe` instead (the last
  good result is kept).
- One run of a page at a time: a second `chi page run usage` meanwhile exits 1 with `page usage is already running`.
- `chi page list` shows each page's title and `ran 2 min ago`, `failed 1 h ago (line 9)` or `(never ran)`, with
  `changed` when the script changed since its result was made (the result came from an older script; nothing ran). `chi page rm NAME` removes the script and its result.

Exit codes: 0 ran, 1 failed (or no such page, or already running), 2 the command line itself (an unknown flag, a name
that breaks the rule). See [the CLI](cli.md#commands).

## In chi web

- **Finding a page.** All sessions has a **Pages** group at its top, in every project scope (pages are global): one row
  of cards that scrolls sideways, each with the page's title and `ran 2 min ago`, `failed 1 h ago` or `never ran`. The
  search field filters it too, by name and title. With no page (or none the search matches) there is no group. A
  `#/p/usage` link in chi's answer opens the page in the same tab; a reload or a copied `…/#/p/usage` link opens it
  too.
- **The page** shows in place of the session area: Back (to where it was opened from, else All sessions), the title,
  when it ran and how long it took, **Refresh** and `⋯` with Delete (it asks once, then removes the script and its
  result). Opening it shows the stored result at once and runs nothing.
- **Refresh** runs the script as `chi page run` does and redraws when the run ends; the button reads "Running…" and
  can't be pressed twice. A run already going (from a terminal, another tab) says "already running". Stopping chi web
  stops a Refresh. A Refresh holds its request until the run ends, up to about 32 s (the 30 s cut and its grace): behind
  an auth proxy ([configuration.md](configuration.md#behind-an-auth-proxy)), its timeout must allow that.
- **A failed run** keeps the last result, dimmed, under "The script failed at line 9: … Showing the result from 21
  Nov, 14:02." with **Copy the error** (the line, the message and the script's last words on stderr).
- **The script changed** since the result on screen was made: a line says so; nothing has run. "Changed" means the
  result came from an older script.
- **A table**: a column header sorts by it (numbers as numbers, blanks last, the total stays at the bottom); a wide
  table scrolls sideways in its own box. On a phone each row shows the first column and the key columns (`key:`);
  a tap opens the rest as label and value lines; rows keep the script's order there.
- **A walk** is drawn by the same widget as in an answer; its lanes scroll sideways inside it.
- **Markdown off** (`web.markdown`, the default): a text block shows as plain text, and a link in chi's answer is plain
  text too, so the Pages group is the way in. A fenced block inside a text block (a `chi-ui` or a mermaid one) stays
  source on a page.
- **Not live**: the group is read when All sessions opens, a page when it opens and after its own Refresh or Delete.
  A run from a terminal shows after the next open or a reload.
- Pages are the owner's: a participant ([chi share](cli.md)) sees no Pages group, no page, and no page route answers
  their link.

## Where a run happens

- **The working folder is the pages folder.** A chi command a script runs sees that folder's project: if
  `~/.config` sits in a git repository, that repository. Pass `--scope=all` to the session commands
  (`chi sessions list --scope=all --format json`) for every project.
- **The environment is yours**, as a session's worker gets it: the XDG folders absolute, chi's own session markers and
  guardrails settings left out, and `PWD` the pages folder; chi web's Refresh runs chi web's own chi. `CHI_REMOTE`, a worker's `SAMAGOTCHI_WORKER_*` keys and
  the agent markers (`CLAUDECODE`, `CODEX_THREAD_ID`, `AI_AGENT`) are left out too: a run is always on this machine,
  and a `chi send` from a script is yours, even when chi was started from an agent's pane. Name `chi` plainly; name other programs by absolute path:
  a Refresh in chi web runs with chi web's `PATH`, which may not be your shell's.
- What the script prints to stdout is its own: the result goes through the stored file. Its stderr shows under a
  failure.
- **A child that leaves the process group survives the 30 s cut** (a `setsid` or a daemon). A program the script
  starts (`spawn`, `system`, backticks) never keeps the page "already running"; a Ruby `fork` (or `Process.daemon`)
  that lives on does, until it ends. A script that `exec`s another program hands the run to it: the 30 s cut still
  applies, but if what started the run dies, nothing stops that program. Anything that stays in the group is stopped.

## Where things are stored

- The script: `~/.config/samagotchi/pages/NAME.rb`.
- The result: `~/.local/state/samagotchi/pages/NAME/output.json` (`$XDG_STATE_HOME`): the title, the blocks of the last
  good run, when it ran, how long it took, the sha256 of the script that made it, and the last failure since, if any.
  Its shape is in [internals/pages.md](internals/pages.md).
