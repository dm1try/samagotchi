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
answer, Ctrl-C, the web's Deny button or a cancelled turn deny it. During a
reminder turn, when the question comes up while you are typing at the prompt, a line
that isn't an answer goes back into the prompt and the question asks at
`choice>`.

Who answers:

- REPL (`chi --no-shared`, `-p` without `--non-interactive`): at `choice>`.
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
      tool: shell            # execute + task_create; or a tool name, or a list
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

All the fields a rule gives must match. Absolute and `**/` globs match the
resolved path; other globs match the path relative to the repo root. Paths
resolve the way the tools resolve them (against the cwd; `~` expanded).

Rules load when chi starts (a long-running worker picks up changes after its
next start). A rule that doesn't parse (an unknown key, a bad regex, no
verdict) makes chi **deny every tool call** and say why, rather than run
without it.

## The guardrails bundle

```sh
chi bundle install guardrails
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
