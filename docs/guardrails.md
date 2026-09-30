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

- REPL (`chi --no-shared`, `-p` without `--non-interactive`): at the `? ` prompt.
- A shared session's worker: any attached TUI or web page. With none attached,
  the approval waits (in the session file) and shows on attach.
- `-p … --non-interactive`: nobody; the call is denied ("No one to approve it
  (non-interactive run)").

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

## Protected paths

Built in, for `write`, `edit` and `memory_write` (symlinks resolved):

- deny: the approval store's dir, and installed bundles (`memories/.bundles/`);
- ask (once or for the session): `config.yml` and the plain hooks dir.

`execute` can still reach them; the guardrails bundle asks about shell
commands that name them.

## Rules in config.yml

```yaml
guardrails:
  enabled: true              # false: no rules, and hooks' asks are dropped (a deny still applies)
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

To switch off single rules (a bundle's, say) without editing its files, list
them under `disable:`. A plain id switches off every rule with that id; `bundle:id`
only that bundle's:

```yaml
guardrails:
  disable: [git-rebase, guardrails:git-push]
```

`/guardrails` marks them `disabled (guardrails.disable)` and names entries that
match no rule. `disable:` only removes rules; hooks and the core checks still vote.

Rules load when chi starts (a long-running worker picks up changes after its
next start). A rule that doesn't parse (an unknown key, a bad regex, no
verdict, a `disable:` that isn't a list of ids) makes chi **deny every tool call** and say why, rather than run
without it.

## The guardrails bundle

```sh
chi bundle install guardrails    # chi bootstrap installs it, with the core profile
```

installs a default rule set plus a short memory telling the model not to
route around a deny. It asks before `git push`, `reset --hard`, `clean -f`,
`branch -D`, `rebase`, `filter-branch`/`filter-repo`; `rm -rf` on `/`, `~`,
`$HOME` or `..` paths; `curl … | sh` and `base64 -d … | sh`; writes outside the
repo; and shell commands that name chi's config, hooks or guardrails or
`.git/hooks`. It denies writes into `.git/hooks`. The rules are in
`lib/samagotchi/bundles/guardrails/guardrails/rules.yml`.

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
skipped, as is a token that equals another known name.

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

`mode: correct` rewrites the call (whole tokens, everywhere they appear) and
says so; `mode: ask` shows the call with three choices, *Correct it and
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
