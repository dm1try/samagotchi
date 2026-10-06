# Guardrails

Every tool call the model makes passes one check before it runs, in both
loops (native and chat hosts). The verdict is **allow**, **ask** or
**deny**; the strictest vote wins, and a deny can't be undone by a later
voter. Of two asks the first one names the rule, except a rule only the
user may allow (`chi-config`, `chi-hooks`, `shell-touches-chi`,
`chi-context-cmd`): it takes over, and only the scopes both asks offer
are offered.

Who votes, in order:

1. `before_tool_call` hooks (Ruby; see [Hooks](hooks.md#guardrails-from-a-hook)).
2. Core checks: a required guardrail that failed to load, then protected paths.
3. YAML rules: `config.yml`'s `guardrails:` section, then installed bundles' rule files (by bundle name).

The UI shows the tool line first, then the approval under it.

## Ask

The REPL, the attached TUI and the web show what would run, where and why:

```
Approve tool call?
! execute: git push origin main
  in /home/me/app (repo app, branch main)
  why: git push publishes commits (rule git-push, bundle guardrails)
  1) Allow once
  2) Allow this call for the session
  3) Allow this call in this repo
  4) Allow rule git-push in this repo
  5) Deny
```

In a terminal, answer with a number, the exact label, `y` (Allow once) or `n`
(Deny); add `; reason` to tell the model why (`n; open a PR instead`). An empty
answer, Ctrl-C, the web's Deny button or a cancelled turn deny it. The prompt stays open during turns: when the question comes up it turns
into a yellow `? `, with the call and the options listed under it; only a line
submitted there answers it (never one typed before), and what you had typed comes back
once it closes. On a short terminal the list shrinks (the hint row, then the `in`/`why`
lines, then the header go, then the options fold onto fewer rows). Once answered, one
line stays in the scrollback: `! execute: git push origin main → Allow once`.

An `edit` or `write` also shows the change it would make, computed without
touching the file: a `change: +3 −1` line in the question (`new file, 12 lines`;
`would fail: old text not found in …` when the edit can't apply), and the
unified diff itself. The web card shows the diff under the path (20 lines,
then "show all"); the terminals print it above the question, green and red,
40 lines at most (the rest is on the web). Binary files and files over 1 MB
say so instead of a diff. After the call runs, its row shows what really
changed: `diff +3 −1` under the row on the web (closed, it survives a
reload) and ` +3 −1` at the end of the terminal's tool line. The model never
sees these diffs.

Who answers:

- REPL (`chi --no-shared`, with or without `-p`): at the `? ` prompt.
- A shared session's worker (plain `chi` and `chi -p …` while `session.shared` is on, the default): any attached TUI or web page. With none attached,
  the approval waits (in the session file) and shows on attach.
- `-p … --non-interactive`: nobody; the call is denied ("No one to approve it
  (non-interactive run)").
- A delegated child session (the `delegate` tool), while its parent waits:
  the parent's user, on the parent's own card (the approval relay; see
  [Sessions: Delegating](sessions.md#delegating)). The child's card stays
  answerable too, the first answer wins. The parent's model sees only the
  outcome.
- A parent agent running chi as a sub-agent (`chi send --wait` exits 3 with
  the approval): `chi answer` may deny it, never allow it by default, or leave
  it for the user. See [Approvals from a parent agent](#approvals-from-a-parent-agent).

The model gets one line on a deny. A rule's or hook's deny reads
`[execute] Error: denied by guardrail (rule git-push, bundle guardrails): git push publishes commits. The user was not asked. Do not retry it or reach the same result another way; ask the user how to proceed.`
When the user picks Deny on an ask, it leads with the user's answer:
`[execute] Error: The user declined this call: "open a PR instead". It needed approval (rule git-push, bundle guardrails): git push publishes commits. Do not retry it or reach the same result another way; ask the user how to proceed.`

## Approvals

Allowing beyond "once" is stored in `$XDG_STATE_HOME/samagotchi/guardrails/approvals.json`
(default `~/.local/state/samagotchi/guardrails/`):

| Scope | Allows |
|---|---|
| session | this exact call (tool + command, or paths) in this session |
| repo | this exact call in this repo (the cwd outside a repo), any session |
| rule | anything this rule asks about in this repo |

"This repo" is the git repository, not the folder: an approval given in one
worktree holds in the main checkout and every other worktree of it (it is
stored with the repository's common git dir as `repo`, and the worktree as
`repo_root`). The ask names the repository (`Allow this call in this repo
(samagotchi)`). An entry stored before chi 0.20 has no `repo` and still only
matches its exact folder.

A stored approval only relaxes an ask; a deny rule is never approvable.
A file that doesn't parse is moved aside to `approvals.json.corrupt-<UTC time>`
with one warning, and chi starts with no stored approvals (more asks, nothing lost).
`/guardrails` lists the rules and approvals; `/guardrails revoke N` removes one.
The file tools can't write the store.

### Approvals from a parent agent

A chi parent's `delegate` children don't need any of this: their approvals go
to the user on the parent's own card (the approval relay). This section is the
path for other agents, and for a chi parent that can't host the relay (a
`--no-shared` REPL, `--non-interactive`): there the model gets the approval
block and the rules below. With the relay, the same rules still hold for a
parent model that answers its own relay card (a piped or marked `chi --attach`
on the parent): that answer is a parent agent's, checked by the parent and
again by the child.

When another agent (Claude Code, Codex, a script) runs chi with
`chi send --wait`, an approval comes back to it as exit 3 with `kind:
approval`, and `chi answer` answers it. A rule with `verdict: ask` means "ask
me", so by default a parent may only deny: `--option Deny --text "why"`,
`--text` alone, or `--dismiss`. An Allow is refused (exit 1, `allowing a tool
call is up to the user: deny it (--option Deny --text WHY), and tell your
user`). The question block chi prints for an approval says the same: its
command is a deny, with no `--option N` and no `chi --attach`.

```yaml
guardrails:
  parent_approvals: once    # default off
```

`once` lets `chi answer --option "Allow once"` through, picked by the
option's scope, not its label; the wider scopes (this session, this repo or
directory, the rule) stay with the web and the terminal. An approval that
doesn't offer "once" can't be allowed from a parent, and neither can one whose
offered scopes are missing or don't fit its options: then only Deny goes.

A child that has to work in another folder (`write-outside-repo`,
`git-outside-repo`) is denied this way too. Start it in that folder instead
(`chi send --new --dir PATH`), or have your user allow "rule … in this repo"
once on the web (it is stored for later sessions in that repo), or switch the
rules off: `guardrails: {disable: [write-outside-repo, git-outside-repo]}`.

Whatever the setting, a parent can't allow a call on chi's own files: a
`write`, `edit` or `execute` on the config dir (config.yml, installed bundles'
rules), the hooks dir or the approval store, by its rule (`chi-config`,
`chi-hooks`, `shell-touches-chi`), its paths or its command. "Allow once" on a
config.yml rewrite would allow everything from then on, so those stay with the
user: `chi answer` and the worker refuse the allow with `only the user can
allow it`.

A turn's step-limit question (kind `continue`) isn't an approval: Continue
grants no permission, so a parent may answer it either way by default.
`turn.parent_continue: false` (config.yml only, like `parent_approvals`)
makes parents stop-only. See [chi as a sub-agent](sub-agent.md#the-step-limit).

The guardrails settings (`enabled`, `mode`, `small_models`, `parent_approvals`) are
read from config.yml only: they have no environment variable, and a worker
chi starts unsets every `SAMAGOTCHI_GUARDRAILS_*` it would inherit. What a
parent's environment does choose is the config dir: `XDG_CONFIG_HOME` picks
which config.yml chi reads, and a worker the parent starts or wakes (`chi
send` to a stopped session) reads the one the parent's `XDG_CONFIG_HOME`
points at. chi doesn't record the config dir per session.

The worker checks it too. `chi answer` marks its answers as a parent's
(`client_id: "cli:answer"`), and the worker's Bridge refuses such an allow
beyond what the *worker's* config.yml permits (`403 parent_approval_refused`;
`chi answer` exits 1 with the reason), checked against the question pending
at that moment. Answers from the web and an attached terminal keep every
scope.

A parent may also type its answer into chi itself: a piped `chi --attach ID`
or `printf '2\n' | chi --no-shared -p …`. So chi treats an answer as a
parent's, held to the same setting, when its input isn't a terminal or an
agent marker is set: `CLAUDECODE` (Claude Code), `AI_AGENT`, `CODEX_THREAD_ID`
(Codex CLI), or `SAMAGOTCHI_PARENT_SESSION`,
which chi's own `execute` and `task_create` export (the session's id) into the
commands they run. The markers survive a PTY wrapper (`script`, `expect`). A
person at a terminal with no marker keeps every scope.

This guards an honest but eager parent, not a hostile one: it is not a
security boundary. The worker's Bridge and the web's answer route on localhost
take an answer from any local process, which can leave the marker out (or
post through the web) and get every scope. chi's instructions for parents ([chi as a
sub-agent](sub-agent.md)) tell them to use `chi answer` only.

## Protected paths

Built in, for `write`, `edit` and `memory_write` (symlinks resolved):

- deny: the approval store's dir, installed bundles (`memories/.bundles/`),
  and [attached context](context.md) sources (`<state dir>/context/`: a
  source's command runs later, outside the gate; `chi context` changes them);
- ask (once or for the session): `config.yml` and the plain hooks dir.

`execute` can still reach them; the guardrails bundle asks about shell
commands that name them.

## Rules in config.yml

```yaml
guardrails:
  enabled: true              # false: no rules, and hooks' asks are dropped (a deny still applies); config.yml only
  mode: auto                 # or strict: also the rules tagged modes: [strict]; config.yml only
  rules:
    - id: git-push
      tool: shell            # execute + task_create; or a tool name, a glob, or a list
      command: '\bgit\s+push\b'   # Ruby regex on the command
      verdict: ask           # ask | deny
      reason: git push publishes commits
      scopes: [once, session, repo]   # optional; default all four
    - id: write-outside-repo
      tool: [write, edit]
      path: outside_repo     # or a glob: "**/.git/hooks/**", "/etc/**", "config/*.yml"
      verdict: ask
      reason: writes outside this session's repo
    - id: git-outside-repo
      tool: shell
      git: outside_repo      # a shell call runs commit/add/reset/… in another checkout
      verdict: ask
      scopes: [once, session, rule]
```

A rule gives at least one of `tool`, `command`, `path`, `git`, `touches` and `rm`.

`rm: outside_tmp` (shell tools) matches a command whose `rm -r -f` reaches
outside the tmp folders (`$TMPDIR`, `/tmp`, `/var/tmp`): every such `rm` in a
chain must name only paths inside one, resolved like `touches` (so
`/tmp/../etc` and a link from `/tmp` to `/` are outside). The tmp folder
itself, a glob (`/tmp/*`), a `$VAR` other than `$HOME`/`$TMPDIR`, an `rm`
behind `sudo`/`xargs`/`sh -c` or in `$(…)`, and the tmp folder the session's
repo is in count as outside.

`touches: chi_dirs` (shell tools) matches a command that names a path in chi's
own folders: the config folder (`config.yml`, `memories/`), the hooks folder,
the approval store, installed bundles (`memories/.bundles`), the session repo's
git hooks (`core.hooksPath` honoured) or any `.git/hooks` outside a tmp folder.
Each word is read as a path against the folder the command is in by then
(`cd`, `pushd`/`popd` and `( … )` followed), with `~`, `$HOME` and
`$XDG_CONFIG_HOME`/`$XDG_STATE_HOME` expanded and symlinks resolved. So
`/tmp/x/config/samagotchi/config.yml` and chi's own source
(`lib/samagotchi/hooks/…`) don't match. A word it can't resolve (another
`$VAR`, `$(…)`, a glob, a relative path after `cd $X`) or one that reads as a
script (`sh -c '…'`, `ruby -e '…'`) is matched as text instead (`.config/samagotchi`,
`samagotchi/config.yml`, `samagotchi/hooks`, `samagotchi/guardrails`,
`memories/.bundles`, `.git/hooks`).

`skip_read_only: true` lets a shell command through when it only reads:
every command in it (split at `;`, `&&`, `||`, `|`) is `ls`, `cat`, `head`,
`tail`, `wc`, `stat`, `du`, `grep`, `rg`, `find`, `tree`, `file`, `sort`,
`uniq`, `cut`, `diff`, `echo`, `cd`, `sed`, `awk` or a reading `git`
(`log`, `show`, `diff`, `status`, `branch` listing, …), with no option that
writes or runs something (`sed -i`, `sed 's/a/b/w f'`, `find -delete`/`-exec`,
`rg --pre`, `sort -o`, `awk` with `>`/`|`/`system(`, `git -c`, `git diff
--ext-diff`, …) and no redirection other than to `/dev/null` or another fd.
`$(…)`, backticks, `$VAR` (other than `$HOME`, `$XDG_*`, `$TMPDIR` and `$PWD`
at a word's start), an env prefix, `sh -c`, `xargs`, `eval`, `sudo` and the
like make a command not read-only. It errs towards asking.

A tool name may be a glob, so one rule covers a plugin's tools (an MCP server's,
say): `tool: "mcp_*"` or `tool: ["mcp_{git,gh}_*", web_fetch]` (`*`, `?`, `[…]` and
`{a,b}`, matched with `File.fnmatch`). `/guardrails` lists the glob as given.
A plugin tool whose `targets:` name no command or path (an MCP tool) is asked
about with its arguments (`mcp_x_sum: a=20 b=22`), and an approval of "this
call" is keyed by them.

```yaml
    - id: mcp-ask
      tool: "mcp_*"          # every MCP tool (the mcp bundle's mcp_<server>_<tool>)
      verdict: ask
      reason: an MCP server's tool
```

All the fields a rule gives must match. Absolute and `**/` globs match the
resolved path; other globs match the path relative to the repo root. Paths
resolve the way the tools resolve them (against the cwd; `~` expanded).

`outside_repo` is measured from the session's repo: the git work tree its
folder is in (a linked worktree is its own), or the folder itself outside a
repo. Not the call's own `cwd:`: an `execute` with `cwd:` in another checkout
is outside. Symlinks are resolved on both sides (`/tmp` and `/private/tmp` are
one folder; a link in the repo that points elsewhere is outside). Never outside:

- a memory's file: a `*.md` right in the project or system memories folder (not
  `index.md`, not a hidden file). `write`/`edit` there is what `memory_write`
  does unasked, and the model is told to `edit` a memory for a small change.
  The memories folder's `index.md`, `.bundles/`, and the rest of chi's config
  folder still count as outside, as does chi's state folder (sessions,
  approvals);
- a tmp folder (`$TMPDIR`, `/tmp`, `/var/tmp`), unless the session's repo is
  itself in that tmp folder: a sandbox there still gets asked about its siblings.

`git: outside_repo` (shell tools only) reads the command for git subcommands
that change a checkout: `commit`, `add`, `reset`, `checkout`, `switch`,
`rebase`, `merge`, `push`, `stash` (not `stash list`/`show`), `rm`, `mv`,
`cherry-pick`, `revert`, `pull`, `restore`, `am`. It follows `cd`,
`pushd`/`popd`, `( … )`, `git -C`, `--git-dir`/`--work-tree`, `GIT_DIR`/`GIT_WORK_TREE`
and the call's `cwd:`, and matches when one of them runs outside the session's
repo (the same `outside_repo` as above). `cd /other && git status`, `git -C
/other log` and `cd /other && bundle exec rspec` don't match. A folder the text
doesn't tell (`cd $REPO`, `cd "$(…)"`, `cd -`) doesn't either; see Limits.

To switch off single rules (a bundle's, say) without editing its files, list
them under `disable:`. A plain id switches off every rule with that id; `bundle:id`
only that bundle's. A single id works without the list (`disable: git-rebase`):

```yaml
guardrails:
  disable: [git-rebase, guardrails:git-push]
```

`/guardrails` marks them `disabled (guardrails.disable)` and names entries that
match no rule. `disable:` only removes rules; hooks and the core checks still vote.

### Rules for some models

`models:` makes a rule vote only for some models: `small`, or a glob on the
model's name (`Qwen3.6-*`, matched on the bare name without the host prefix and
on the model key `qwen3-6-27b`, case-insensitively), or a list of them. Without
`models:` a rule is for every model. With no model name set, a `models:` rule
doesn't vote.

```yaml
guardrails:
  small_models: auto          # the default; or a list of globs, or [] for none
  rules:
    - id: no-force-push-small
      tool: shell
      command: '\bgit\s+push\b.*--force'
      models: small             # or "gemma-*", or [small, "deepseek-*"]
      verdict: deny
```

Which models are small is `guardrails.small_models`. Nothing reports a model's
size, so `auto` reads it from the name: `Qwen3.6-27B` is 27B, `gemma-4-E4B-it`
4B, `Mixtral-8x7B` 56B, and for an MoE the active size counts
(`Ornith-1.5-35B-A3B` is 3B, `Qwen3-235B-A22B` 22B). 32B or less is small. A name
without a size (`deepseek-v4.1-flash`) is not small. A list of globs names the
small models yourself (`auto` may be one of them), and `[]` means no model is
small. It is read on every check, so `/model` and config edits apply at once.

`/guardrails` names the model and whether it is small (`model: Qwen3.6-27B —
small (auto, 27B)`), shows each rule's `models`, and marks a rule that doesn't
vote for the current model `off for this model`.

Rules are read again on the next tool call after `config.yml` or an installed
bundle's rules change, so a long-running worker follows edits without a
restart. A rule that doesn't parse (an unknown key, a bad regex, no
verdict, a `disable:` that isn't an id or a list of ids) makes chi **deny every tool call** and say why, rather than run
without it.

A bundle whose `requires_chi` the running chi doesn't meet (installed by a
newer chi while the session's worker kept running) isn't read again: the
rules the session loaded from it before stay, and a `guardrails>` line says
once per bundle version to restart the session (`chi sessions stop ID`, then
`chi --resume ID`). A chi that never loaded that bundle's rules (it starts
older than the bundle) denies every tool call, as for a rule that doesn't
parse, until chi is updated or the bundle uninstalled.

### Modes

`guardrails.mode` (config.yml only) picks how much is asked:

- `auto`, the default: the rules tagged `modes: [strict]` don't vote. Asks
  are kept for what is hard to undo or reaches chi itself.
- `strict`: every rule votes.

```yaml
guardrails:
  mode: strict
  rules:
    - id: no-docker
      tool: shell
      command: '\bdocker\b'
      modes: [strict]        # or auto, or [auto, strict] (the same as leaving it out)
      verdict: ask
```

A rule without `modes:` votes in every mode, so a rule you add to config.yml
always applies unless you tag it. The core checks (protected paths, hooks)
vote in both modes. In the guardrails bundle, `git-rebase`,
`write-outside-repo` and `git-outside-repo` are strict only; its small-model
rules (`models: small`) are untagged, so they ask a small model in both modes.
`/guardrails` shows the mode on its first lines and marks the rules this mode
leaves out `(strict only)`.

A rule in config.yml that uses a key this chi doesn't know yet (`modes:`,
`touches:`, `rm:`, `skip_read_only:` before 0.20) doesn't parse, and a rule
that doesn't parse denies every tool call (see Failing closed). Bundles say
which chi they need (`requires_chi`), so their rules don't hit this.

## The guardrails bundle

```sh
chi bundle install guardrails    # chi bootstrap installs it, with the core profile
```

installs a default rule set plus a short memory telling the model not to
route around a deny. In both modes it asks before `git push`, `reset --hard`,
`clean -f`, `branch -D`, `filter-branch`/`filter-repo`; `rm -rf` on `/`, `~`,
`$HOME` or `..` paths, unless every target is inside a tmp folder; `curl … |
sh` and `base64 -d … | sh`; shell commands that name a path in chi's config,
hooks, approvals, bundles or attached context sources, or a `.git/hooks`
(`shell-touches-chi`, `touches: chi_dirs`), unless they only read
(`skip_read_only`); `chi context add … --cmd` (`chi-context-cmd`, once at a
time: a command chi will run every few minutes outside the guardrails; see
[Attached context](context.md#safety)); and answering chi's
questions around `chi answer`: `chi --attach` or `chi -p` with stdin from a
pipe, a here-string or a file (`chi-answer-piped`), and `curl`/`wget` to a
session's `/answer` route (`chi-answer-http`), both once or for the session.
`chi answer` itself isn't asked about. It denies writes into `.git/hooks`.

In strict mode (`guardrails: { mode: strict }`) it also asks before `git
rebase`, writes outside the session's repo (`write-outside-repo`) and git that
changes another checkout (`git-outside-repo`: `cd ../main && git commit`, `git
-C ../main add .`; it offers once, this session and "rule in this repo", the
last stored for later sessions in that repo). The rules are in
`lib/samagotchi/bundles/guardrails/guardrails/rules.yml`.

Small models (`models: small`, see above) get two more asks, in
`guardrails/small-models.yml`: `git checkout -- <path>`, `git checkout <rev> --
<path>`, `git checkout .` and `git restore <path>` (not `--staged` alone), which
discard uncommitted changes, and `git stash drop`/`clear`. They offer only
"once" and "this session", so an approval doesn't silence them for good. To get
them on every model, set `small_models` to `"*"`; to drop them, `[]` (or
`disable:` the ids).

A bundle ships rules as `guardrails/*.yml` (the same `rules:` shape). Install
records each file's sha256; a file changed afterwards, missing, or not parsing
denies every call until the bundle is reinstalled.

## The known-names bundle

```sh
chi bundle install known-names    # or chi bundle install dev
```

installs one `before_tool_call` hook and a short memory. A local model that
once misspells a name inside a path (`jonathandoe` → `jonathndoe`)
keeps copying the wrong spelling from its context, and every call after
that fails. The hook knows the right names and compares strings: the
user's home folder name, login (`$USER`), git `user.name` words and email
local part, the repo folder name, and any names from config. A token in a
call's command, `cwd` or paths (never a write's content) that is within one
edit of a known name shorter than 10 characters, or two edits of a longer
one, is a near miss. Tokens and names shorter than `min_length` (6) are
skipped, as is a token that equals another known name. A token with a shell
glob (`*?[]{}`, as in `ls -d samagotchi*`) is not checked. In `~name` (that
user's home folder) the name after `~` is what is checked.

By default (`mode: reject`) the call is denied with advice in place of the
usual tail, so the model retries it corrected:

```
[execute] Error: denied by guardrail (hook known_names, bundle known-names): "johndeo" in the command is 1 edit away from the known name "johndoe". The user was not asked. Retry with "johndoe". If "johndeo" is really what you meant, say so to the user instead of retrying.
```

and the user sees one line: `known-names> rejected execute: "johndeo" looks like "johndoe"`.

```yaml
bundles:
  known-names:
    names: [jonathandoe]      # protected besides the derived ones
    mode: reject              # reject | correct | ask
    derive: [home, user, git, repo]
    ignore: [jondoe]          # a real name that is near a protected one
    min_length: 6
    max_distance: 2           # default: 1 under 10 characters, else 2
```

`mode: correct` rewrites the call (whole tokens, everywhere they appear in
the command, the `cwd` and the paths; never in file text: a write's content
or an edit's `old_text`/`new_text`) and says so; `mode: ask` shows the call with three choices, *Correct it and
run*, *Run as is*, *Deny*; with no one to ask (`--non-interactive`) or a
dismissed question it rejects. A real near name (a folder `jondoe` next to
user `johndoe`, a login one letter from another) is caught too: list it under
`ignore:`. The hook is `on_error: log`: a bug in it warns and lets the call
through. As with every bundle hook, a running worker picks it up after its
next start.

The system prompt names the home directory once, with the advice to write
it as `~` or `$HOME`, so the model rarely has to spell it.

## Failing closed

- A config hook with `required: true`, or a bundle `before_tool_call` hook with
  `on_error: fail_closed`, that fails to load (missing, syntax error, or for a
  bundle hook a sha256 that differs from the installed one) makes chi deny
  every tool call. One that raises when called denies that call.
- Other hooks stay fail-open; a load failure is a warning.
- Every load failure is shown once, at the start of the first turn
  (`guardrails> …` in the terminal, a red line on the web).

## Limits

Text matching on shell commands stops accidents, not a model set on getting
around it: `sh -c`, base64, a script written earlier, `git -C` variants and
aliases can get past a regex. `outside_repo` covers the file tools and git
only: `sed -i`, `cp` or `cat > file` into another folder from the shell aren't
asked about, and neither is git run through `sh -c`, a script, an alias, `make`
or a folder in a variable. `!cmd` lines typed by you are not checked. The only
real defence against an adversarial model is isolation (a sandbox, a git
identity without push rights).
