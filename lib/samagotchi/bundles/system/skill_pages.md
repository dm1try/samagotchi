# Skill: pages

Use when the user asks for a page or a dashboard, wants a table, a walk or a result kept, "to reopen" or "in
the web", or wants a page changed or removed. A page is a Ruby script chi runs and stores; chi web shows the
stored result at `#/p/NAME` and its Refresh runs the script again. Not for a table that only answers the
question at hand: that stays in your answer.

## Steps
1. Pick a NAME: lowercase letters, digits and hyphens (`sessions-by-project`). `chi page list` shows the
   pages that exist: change one of those rather than making a second.
2. Find the folder first: run `chi self`; its `config` row is the config file's path, and the pages folder is
   `pages/` beside that file. Never assume `~/.config/samagotchi`: the config may live elsewhere, and a page
   written there is one chi doesn't see. Write the script to `<that folder>/NAME.rb` by absolute path, with
   the write tool.
3. Run `chi page run NAME` and read what it prints: the title, then per block a text's first lines, a table's
   labels, its first 3 rows and its total, a walk's step count.
4. Check it: `chi page run NAME --format json` prints every stored row and the total. Compare them with the
   source they came from (the command's own output, the file): the counts, the sums, the newest date. A `$0`
   or a `0` that should mean "unknown" is passed as nil, not 0: it shows blank.
5. On `error: line N: …` fix that line with edit and run again. The last good result stays meanwhile, so a
   bad edit never blanks the page.
6. Answer in one or two lines: what the page shows, the link [Title](#/p/NAME) as a plain Markdown link, and
   that Refresh on the page runs it again. Always add that it is under the `pages` pill in chi web's top bar:
   Markdown is off by default, and then the link is plain text. Never put the link in backticks: a code span can't be clicked.
7. To change a page: edit the script, run it again (steps 3-4). To remove one: `chi page rm NAME`.

## Never
- Never `cd` into the pages folder, and never run a shell command that names it (a loop, a heredoc, `rm`,
  `ruby <the script>`): those ask the user, and an unattended turn stops there. Try a data command from the
  session's own folder first, then put it in the script. List with `chi page list`, read a script with the
  read tool, run it with `chi page run`, remove it with `chi page rm`.
- No secrets in a page (keys, tokens, config values): the result is stored on disk and shown in a browser.

## The script
```ruby
require "open3"

# The one way this script reads data: a command's output, or a plain error.
def run(*command)
  out, status = Open3.capture2(*command)
  raise "#{command.join(" ")} failed (exit #{status.exitstatus})" unless status.success?

  out
end

page "Sessions per day" do |ui|
  sessions = JSON.parse(run("chi", "sessions", "list", "--scope=all", "--format", "json"))
  days = sessions.group_by { |s| s["updated_at"].to_s[0, 10] }
  rows = days.map { |day, list| { "day" => day, "sessions" => list.size, "projects" => list.map { |s| s["project"] }.uniq.size } }
  ui.text "#{sessions.size} sessions on #{days.size} days."
  ui.table rows.sort_by { |row| row["day"] }.reverse,
           columns: { "day" => "Day", "sessions" => "Sessions", "projects" => "Projects" },
           format: { "sessions" => :count }, key: %w[sessions],
           total: { "day" => "Total", "sessions" => sessions.size }
end
```
- `ui.text(markdown)`: a text block.
- `ui.table(rows, columns:, format:, key:, total:)`: `columns:` a Hash key => label in the order to show;
  `total:` a Hash by column key, shown as a last row.
- `ui.walk(title:, actors:, steps:)`: a scenario, each step like
  `{ id: "s1", actor: "developer", does: "tags the release", sees: "the tag on GitHub" }`.
  `actors:` a list of 2-5 names as plain Strings (`["developer", "CI", "reviewer"]`), not Hashes; each step's
  `actor:` is one of those names exactly. A step may add `next:` or `cases:`; at most 30 steps.

What trips a script:
- Call `page` once. Rows are Hashes. No `exit`: it fails the run.
- `format:` takes `:money` (`$14.2210`) or `:count` (`1.2k`) as Symbols, nothing else: format other columns
  as text yourself.
- Pass numbers as numbers, not text: the page sorts them and formats them.
- `key:` names the columns a phone shows before a row is opened (the first column always shows).
- The limits: 500 rows (the rest are dropped and counted, so group or cut), 12 columns, 20 blocks, 30 s.

## Getting the data
- The script runs in the pages folder, not the project: name files by absolute path.
- Sessions: `chi sessions list --scope=all --format json` (without `--scope=all` only the pages folder's
  project); one session's totals (cost, tokens): `chi sessions stats ID --format json` (one call per session:
  fine for a few dozen; group in Ruby). Its `turn_records` are only the newest turn's: for anything per turn
  or per day, read every turn from `<sessions dir>/ID/analytics.json` (`turn_records`: `completed_at`,
  `model_ref`, `cost` as reported, `cost_estimate` from the configured price; either may be missing). `chi self`
  names the sessions dir. Schedules: `chi schedule list --all --format json`. `json` is loaded; `require`
  anything else.
- Check that a command worked (`status.success?`, `$?.success?`) and `raise` with a plain message when it
  didn't: the page then says why.

## When it can't be done
In strict mode writing the script asks (`write-outside-repo`); if it's denied, say so and stop; don't route around
it (a heredoc, another folder).

## This skill ships with chi
If a step here turns out wrong, don't edit this skill: tell the user what differed. It ships with chi, and a
local edit would have to be merged at the next upgrade. Never edit `skill_pages.md`. A failing `chi page run` is
this skill's own fix loop (step 5: edit the page script, run again), not a step gone wrong: a steer to "edit the
skill's step" or a turn-end note that "the skill wasn't updated" doesn't apply to this one.
