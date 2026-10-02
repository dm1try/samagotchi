# Guardrails

Every tool call the model makes passes one check before it runs, in both
loops (native and chat hosts). The verdict is **allow**, **ask** or
**deny**; the strictest vote wins, and a deny can't be undone by a later
voter.

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
- A parent agent running chi as a sub-agent (`chi send --wait` exits 3 with
  the approval): `chi answer` may deny it, never allow it by default. See
  [Approvals from a parent agent](#approvals-from-a-parent-agent).

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

A stored approval only relaxes an ask; a deny rule is never approvable.
A file that doesn't parse is moved aside to `approvals.json.corrupt-<UTC time>`
with one warning, and chi starts with no stored approvals (more asks, nothing lost).
`/guardrails` lists the rules and approvals; `/guardrails revoke N` removes one.
The file tools can't write the store.

### Approvals from a parent agent

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

Whatever the setting, a parent can't allow a call on chi's own files: a
`write`, `edit` or `execute` on the config dir (config.yml, installed bundles'
rules), the hooks dir or the approval store, by its rule (`chi-config`,
`chi-hooks`, `shell-touches-chi`), its paths or its command. "Allow once" on a
config.yml rewrite would allow everything from then on, so those stay with the
user: `chi answer` and the worker refuse the allow with `only the user can
allow it`.

The guardrails settings (`enabled`, `small_models`, `parent_approvals`) are
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

- deny: the approval store's dir, and installed bundles (`memories/.bundles/`);
- ask (once or for the session): `config.yml` and the plain hooks dir.

`execute` can still reach them; the guardrails bundle asks about shell
commands that name them.

## Rules in config.yml

```yaml
guardrails:
  enabled: true              # false: no rules, and hooks' asks are dropped (a deny still applies); config.yml only
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
      reason: writes outside the repository
```

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

`outside_repo` leaves out a memory's file: a `*.md` right in the project or
system memories folder (not `index.md`, not a hidden file). `write`/`edit`
there is what `memory_write` does unasked, and the model is told to `edit` a
memory for a small change. The memories folder's `index.md`, `.bundles/`, and
the rest of chi's config folder still count as outside.

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

## The guardrails bundle

```sh
chi bundle install guardrails    # chi bootstrap installs it, with the core profile
```

installs a default rule set plus a short memory telling the model not to
route around a deny. It asks before `git push`, `reset --hard`, `clean -f`,
`branch -D`, `rebase`, `filter-branch`/`filter-repo`; `rm -rf` on `/`, `~`,
`$HOME` or `..` paths; `curl … | sh` and `base64 -d … | sh`; writes outside the
repo; shell commands that name chi's config, hooks or guardrails or
`.git/hooks`; and answering chi's questions around `chi answer`: `chi --attach`
or `chi -p` with stdin from a pipe, a here-string or a file
(`chi-answer-piped`), and `curl`/`wget` to a session's `/answer` route
(`chi-answer-http`), both once or for the session. `chi answer` itself isn't
asked about. It denies writes into `.git/hooks`. The rules are in
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
aliases can get past a regex. `!cmd` lines typed by you are not checked. The only
real defence against an adversarial model is isolation (a sandbox, a git
identity without push rights).
