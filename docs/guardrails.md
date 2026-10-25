# Guardrails

Every tool call the model makes passes one check before it runs, in both
loops (native and chat hosts). The verdict is **allow**, **ask** or
**deny**; the strictest vote wins, and a deny can't be undone by a later
voter. Of two asks the first one names the rule, except a rule only the
user may allow (`chi-config`, `chi-hooks`, `shell-touches-chi`,
`chi-context-cmd`, `chi-broadcast`): it takes over, and only the scopes both asks offer
are offered.

Who votes, in order:

1. `before_tool_call` hooks (Ruby; see [Hooks](hooks.md#guardrails-from-a-hook)).
2. Core checks: a required guardrail that failed to load, then protected paths, then (a delegate child only)
   [the child boundary](#a-delegate-childs-boundary).
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
answer, Ctrl-C, the web's Deny button or a cancelled turn deny it (on the web card, Enter in the reason box or
on an option submits, never denies). The prompt stays open during turns: when the question comes up it turns
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
  the approval): `chi answer` may deny it, give "Allow once" under
  `guardrails.parent_answers: soft` (the default; never a wider scope), or
  leave it for the user. See [Answers from a parent agent](#answers-from-a-parent-agent).

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
`/guardrails` lists the rules and approvals; `/guardrails revoke N` removes
approval N. When System 1 is enabled or has judgments, it also shows this
session's recent auto-allows and each rule's record summary. In System 1 `on`
mode, `/guardrails wrong [N]` flags the Nth newest auto-allowed call in this
session as one System 1 should have asked about (default 1). The flag is
appended to the judgments log; the rule asks again until its record is rebuilt.
The file tools can't write the store.

### Answers from a parent agent

A chi parent's `delegate` children don't need any of this for approvals: they
go to the user on the parent's own card (the approval relay), as do the hook
questions (the cost cap's Continue/Stop, a bundle's `ctx.ask_user`) where the
parent may pick nothing but a deny under the child's `parent_answers`; the
others come back to the parent's model with the block below. A dismissal
always passes (the hook decides what no answer means): the strategy is a
convention for an honest parent, not a barrier. This section is
the path for other agents, and for a chi parent that can't host the relay (a
`--no-shared` REPL, `--non-interactive`): there the model gets the question
block and the rules below. With the relay, the same rules still hold for a
parent model that answers its own relay card (a piped or marked `chi --attach`
on the parent): that answer is a parent agent's, checked by the parent and
again by the child.

When another agent (Claude Code, Codex, a script) runs chi with
`chi send --wait`, a question comes back to it as exit 3 and `chi answer`
answers it. Every question's options carry an **effect**, set by whoever asks:

- `answer`: a plain choice (the model's own questions, an untagged plugin or
  hook option);
- `deny`: Deny on an approval, Stop on the step-limit question or a plugin's
  stop option;
- `spend`: more time and tokens, no new permission (Continue on the step-limit
  question, cost-cap's and work-cap's Continue);
- `permit`: one tool call (an approval's "Allow once");
- `permit_wide`: more than one call (this session, this repo or directory,
  the rule).

One setting says which effects a parent may pick:

```yaml
guardrails:
  parent_answers: soft    # hard | standard | soft (the default)
```

- `hard`: `deny` and `answer` only. A parent can deny an approval
  (`--option Deny --text "why"`, `--text` alone or `--dismiss`), Stop a
  step-limit question and answer plain questions.
- `standard`: also `spend`: a parent may Continue a turn (or cost-cap's or work-cap's cap).
- `soft` (the default): also `permit`: `chi answer --option "Allow once"`
  goes through, picked by the option's scope, not its label.

A parent never picks `permit_wide`: the wider scopes stay with the web and the
terminal. An approval that doesn't offer "once" can't be allowed from a
parent, and neither can one whose offered scopes are missing or don't fit its
options: then only Deny goes. A refused pick exits 1 with what to do instead
(`only Allow once (guardrails.parent_answers: soft) can be given here: deny it
(--option Deny --text WHY), and tell your user`), never how to allow it. The
question block chi prints says what the parent may give: under `soft` an
approval's block lists the Allow once command next to the deny; under
`standard` and `hard` it says allowing is up to the user. An invalid value
warns and is `hard`.

#### A session's own level

A session may carry its own `parent_answers`, set when it is created (`chi
--parent-answers LEVEL`, `chi send --new --parent-answers LEVEL`) and kept by
its respawns, forks and continues; a `delegate` child starts with its parent's,
as it is then. It can only tighten: config.yml's value is the ceiling, and the
stricter of the two applies, in `chi answer`'s check (from the session file),
the worker's (from its session) and in what the question block offers. A refusal
then names it: `a parent agent may only stop this turn here (parent_answers:
hard (this session))`. A looser one is saved as given with a warning
(`soft is looser than config.yml's guardrails.parent_answers: standard;
standard applies`) and takes effect only if config.yml is loosened later. A
value that isn't a level reads as `hard`.

`/parent-answers` shows the level that applies, the session's own and
config.yml's; `/parent-answers LEVEL` sets the session's own, `/parent-answers
default` drops it (config.yml's applies). Anyone may tighten it, a parent too
(`chi send ID -m "/parent-answers hard"`). Loosening it (toward `soft`, or
`default`) is yours alone: the line must come from you at the REPL, an attached
terminal or the web composer. chi refuses it (`loosening parent_answers is the
user's: …`) from `chi send` (a parent's or yours: the worker can't tell them
apart), from a piped or marked `chi --attach` or REPL, from `chi -p
--non-interactive`, from a delegate's follow-up and from a plugin; `chi answer`
has no command route. `--parent-answers` on `--attach`/`--resume` is ignored,
never sent as the command.

config.yml is read each time an answer is checked; a session's own value stays
as saved and binds whenever it is the stricter of the two. A session saved as
`standard` under a `hard` config.yml follows `hard`, and `standard` again once
config.yml is loosened. A `delegate` child keeps the value it started with,
whatever its parent changes later.

A parent agent on a real terminal (a PTY: tmux, a kitty window) with no agent
marker set looks like you, and can loosen it; so can one that edits a session
file (`<id>.json`, read again by the next worker that wakes for it). That is
not a security boundary either: config.yml still caps the result.

A setting form waits for a running turn to end, as `/toolkit`'s does: a
tightening typed while a child's question is pending applies after that turn,
and a parent may answer the question meanwhile under the level before it.

`soft` suits a capable parent model: it can let a child run one more command
it asked about, still with every guardrail rule in force. For a weak or
unknown parent model, set `standard` or `hard` (and see
[chi-nah](#an-external-guard-chi-nah) for a deterministic guard on the calls
themselves).

A child that has to work in another folder (`write-outside-repo`,
`git-outside-repo`) gets at most Allow once per call this way. Start it in that folder instead
(`chi send --new --dir PATH`), or have your user allow "rule … in this repo"
once on the web (it is stored for later sessions in that repo), or switch the
rules off: `guardrails: {disable: [write-outside-repo, git-outside-repo]}`.

Whatever the setting, a parent can't allow a call on chi's own files: a
`write`, `edit` or `execute` on the config dir (config.yml, installed bundles'
rules), the hooks dir or the approval store, by its rule (`chi-config`,
`chi-hooks`, `shell-touches-chi`), its paths or its command. "Allow once" on a
config.yml rewrite would allow everything from then on, so those questions are
the user's alone (`user_only`): `chi answer` and the worker refuse the allow
with `only the user can allow it`. The same holds for the guardrails bundle's
other user-only rules (`chi-context-cmd`, `chi-broadcast`,
`prompt-memory-write`, `model-overlay-write`, and `chi-answer-piped` /
`chi-answer-http`, which answer a grandchild's question as the user).

A plugin's or a hook's question (`ask_user`) tags its options the same way
(`effects:`, see [Plugins](plugins.md)); an untagged one is a plain `answer`.

The guardrails settings (`enabled`, `mode`, `small_models`, `parent_answers`) are
read from config.yml only (a session's own `parent_answers` can only tighten it): they have no environment variable, and a worker
chi starts unsets every `SAMAGOTCHI_GUARDRAILS_*` it would inherit. What a
parent's environment does choose is the config dir: `XDG_CONFIG_HOME` picks
which config.yml chi reads, and a worker the parent starts or wakes (`chi
send` to a stopped session) reads the one the parent's `XDG_CONFIG_HOME`
points at (a relative one made absolute from the parent's directory). chi
doesn't record the config dir per session.

The worker checks it too. `chi answer` marks its answers as a parent's
(`client_id: "cli:answer"`), and the worker's Bridge refuses such a pick
beyond what the *worker's* config.yml permits (`403 parent_answer_refused`
with its `reason`; `chi answer` exits 1 with the line), checked against the
question pending at that moment. Answers from the web and an attached
terminal keep every option.

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
post through the web) and get every scope. In the same way a parent can
loosen a session's own level by posting `/parent-answers` with a forged
`tui:<pid>` or `web:<tab>` client id to the Bridge or the web's command route,
by editing the session file, or by running `chi --attach` on a PTY with the
markers cleared. chi's instructions for parents ([chi as a
sub-agent](sub-agent.md)) tell them to use `chi answer` only.

## Protected paths

Built in, for `write`, `edit` and `memory_write` (symlinks resolved):

- deny: the approval store's dir, installed bundles (`memories/.bundles/`),
  and [attached context](context.md) sources (`<state dir>/context/`: a
  source's command runs later, outside the gate; `chi context` changes them);
- ask (once or for the session): `config.yml` and the plain hooks dir.

`execute` can still reach them; the guardrails bundle asks about shell
commands that name them.

## A delegate child's boundary

Built in, for [delegate](sessions.md#delegating) children only, in every
mode (also with `guardrails.enabled: false`) and without the guardrails
bundle: a child asks before it changes anything outside its folder, the work
tree top of the folder it was started in (a worktree from `delegate cwd:`,
else the parent's checkout). Rule `child-boundary`, source `core`; it asks when

- `write` or `edit` names a path outside it (tmp dirs and memory files don't count);
- `execute` or `task_create` runs mutating git in another dir (`git -C`, `cd`,
  `GIT_DIR`: what `git: outside_repo` matches), or a command that isn't
  read-only starts outside it (its `cwd:`) or names a path in the repository's
  other checkouts (the main one and sibling worktrees, read from
  `<common git dir>/worktrees/*/gitdir`) or in its common git dir;
- `execute` or `task_create` runs git that changes what every checkout shares,
  even from its own worktree: a `git config` write (not `--get`, `--list`,
  `--worktree`), `update-ref`, `worktree add|remove|move|prune`, `stash
  drop|clear|pop`, creating or deleting a tag, and deleting, forcing or
  overwriting a branch other than its own.

Read-only commands (`git -C ../app log`, `cat ../app/x`) and paths elsewhere
(`/usr/bin`, `~/.gem`) never ask. The answer is once or for the child's
session only: a repo or rule answer would hold in every worktree, for every
child, so a stored repo or rule approval doesn't let it through either. Its
ask goes before the rules, so with the guardrails bundle in strict mode the
card still names `child-boundary`. The parent (never a delegate), forks and
ordinary sessions don't get it. Like the rules it reads command text: a
`sh -c` body, a script or `$(…)` isn't looked into.

## A participant's review boundary

Built in, for a [participant's](internals/participants.md#turns) turns only (a
turn whose author is `p:<id>`), in every mode (also with
`guardrails.enabled: false`) and without the guardrails bundle:
`Guardrails::ReviewBoundary`, rule `review-boundary`, source `core`. It comes
right after the load-failure check (rules that don't load deny every call) and before the hooks' asks, the
protected paths and the rules (`GuardrailWiring#checks`; a deny is sticky, so no later vote turns it into a
question), and it
**denies, never asks**: nobody on the participant's side may approve, and the
owner's approval would give the participant's text the owner's tools. A
participant's turn may call only the `review` kit's tools:

- `read`, under the session's project root (the work tree top of its folder)
  and never a secret: chi's state and config dirs (sessions, the grants, the
  web token, memories and their `.bundles`, `config.yml`, hooks), `~/.ssh`,
  `~/.gnupg`, `~/.aws`, and the project's `.env*`, `.netrc`, `*.pem`, `*.key`,
  `*.p12`, anything named `credentials` (`.git-credentials` too), `.npmrc`,
  `.pypirc`, ssh keys (`id_rsa`, `id_ed25519`, …), `*.tfstate`,
  `secrets.yml`/`.json`, `.docker/config.json`, `.kube/config` and any config
  under `.git` (a submodule's too). The path is checked as given and as it
  resolves, so a symlink in the project to `~/.ssh` is `~/.ssh`. A session
  whose folder is the home folder or above it reads nothing.
- `memory_read` with `scope: project` (a read without a scope would fall back
  to the system memories). The prompt's preloaded memories and the memory
  index are in the system prompt anyway: a review session should start
  without personal ones.

Everything else is denied with "a participant's review turn may only read …",
and the model is told to propose the change as text or a diff for the owner
to apply: `write`, `edit`, `memory_write`, `execute`, the task tools,
`delegate`, `send_note`, `list_sessions`, `register_reminder` (it would fire
an owner turn later), `web_fetch`, `context_read`, `ask_user_question`,
`forget_outputs` (it would replace the owner's earlier tool outputs with the
participant's note, which later owner turns would read as their own), and
every plugin or MCP tool, including through `call_tool` (a built-in reached
through `call_tool` is checked as that built-in). The session's declared tools
stay its own (no prompt rebuild per author), so the model may still try a
write; the turn's header ("This turn may only read") keeps that rare.

The kit is `Toolkit::REVIEW`, a frozen built-in: config's `toolkit.kits.review`
is refused with one message ([configuration](configuration.md#toolkits)), so
config can't widen the boundary. Hooks still run on a participant's turn, with
the owner's power ([hooks](hooks.md#participants-turns)); a hook that rewrites a
call is checked on the call it leaves.

## Rules in config.yml

```yaml
guardrails:
  enabled: true              # false: no rules, and hooks' asks are dropped (a deny still applies); config.yml only
  mode: auto                 # or strict: also the rules tagged modes: [strict]; config.yml only
  rules:
    - id: git-push
      tool: shell            # execute + task_create; or a tool name, a glob, or a list
      command: '\bgit\s+push\b'   # Ruby regex on the command (data heredoc bodies left out)
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

A rule gives at least one of `tool`, `command`, `path`, `git`, `touches`, `rm` and `memory`.

`command:` reads the command without the body of a heredoc its command
only reads as data: `cat` or `tee` to stdout, `git commit`/`git tag` with
`-F -`/`--file -`, `gh pr|issue`/`gh release` with `--body-file -`/
`--notes-file -`, and a `"$(cat <<'EOF' … EOF)"` given to `-m`, `--body`
or another message option. Each counts only when its command ends at a
newline, `;`, `&&` or `||` and sits outside any `( … )` or `{ … }` group;
the `<<TAG` word and the terminator line stay in the text, so a rule on
`<<` or on what follows the terminator still matches. A heredoc fed to
anything else (`bash`, an interpreter, `ssh`, a wrapper), an unquoted one
whose body holds `$(…)` or backticks, a piped one, a file-writing
`cat`/`tee` (a `>&2` or `>&-` writes no file; `>& file` does), a
here-string and an unterminated heredoc all stay in it, and so does every
`cat`/`tee` body after an `exec` that sent the shell's output to a file
(`exec >r.sh; cat <<E`, `exec 3>r.sh; cat <<E >&3`). Approvals, the
approval question and hooks see the whole command.

`memory: remove` matches a `memory_write` with `remove: true` (it moves a
memory into the bundle trash). Nothing else asks about it: a memory's file is
never outside the repo (below), so without such a rule any session, a delegate
child included, removes a memory unasked. `memory: overlay` matches a
`memory_write` of a model overlay (`current_model_only: true`). `memory:
prompt` matches a `memory_write`, `write` or `edit` of a memory file that
reaches the system prompt (`identity.md`, `model_notes_*.md` and their
overlays) right in a memories folder (the system scope's or a project's),
resolved: symlinks, `..` and the case the disk has; the name in any case.

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
about with its arguments (`x: sum: a=20 b=22`), and an approval of "this
call" is keyed by them.

A plugin tool that runs other tools for the model (a dispatcher such as
`call_tool`) can say, in its `targets:`, which tool a call acts as (`acts_as:`)
and with which arguments (`args:`). A rule's `tool:` then matches the call's
own name **or** the tool it acts as: `tool: mcp_github_*` fires for a
`call_tool` that acts as `mcp_github_merge_pull_request`, and `tool: call_tool`
fires whatever MCP tool it acts as. The question names the tool it acts as (by the
`label:` its `targets:` gives, if any: display only) and shows its arguments, and an approval of "this call" is keyed by the real name, the
alias and those arguments (`/guardrails` lists it as
`call_tool>mcp_github_merge_pull_request:number=7 …`), so it never covers a
direct call of that tool, nor a direct call's approval it. A tool can't act as
one of chi's own tools or another bundle's tool: that `acts_as:` is dropped
(and logged as `plugin_acts_as_dropped`), and the call is matched by its own
name only. Hooks and loop-guard's `ignore_tools` still see the call's own
name.

chi's `call_tool` is exempt from the "another bundle's tool" drop (not the
core-tool one): its `acts_as` is always a tool its sources published, so a
bundle tool that happens to share an MCP tool's `mcp_<server>_<tool>` name
can't take `call_tool` calls of that MCP tool out of your `mcp_*` rules. The
trade-off, when such a clash exists:
- an `allow` or `ask` rule by that name matches both the bundle tool and the
  MCP call;
- a `rule`-scope approval ("always for this rule") covers both, because it
  matches by rule, source and place, not by tool;
- `session` and `repo` approvals stay distinct (`call_tool>mcp_x:…` vs
  `mcp_x:…`);
- deny rules cover both, which is the point.

A `call_tool` of one of chi's own tools (`chi/delegate`: a built-in the
session's toolkit leaves out, [toolkits](configuration.md#toolkits)) is
gated **as that tool**: it is turned into the `delegate` call before the
guardrails run, so every rule on `delegate` (or `execute`'s `command:`, the
`rm` check, a delegate child's boundary) gives the same verdict as for a
direct call, and an approval is keyed `delegate:…` either way. `tool:
call_tool` rules no longer see such calls, only MCP calls and misses. A
`chi/` name the toolkit removes is refused before the gate, with no card.

On a Messages host (`api: anthropic`) those tools are also callable by their
own names (they go out deferred): a direct `delegate` call is gated as any
declared tool's, keyed `delegate:…` (the same approval as through
`call_tool`); a direct call of an MCP tool's `mcp_<server>_<tool>` name is
gated as the `call_tool` call it stands for: `mcp_*` rules match it, and its
approval is `call_tool>mcp_x:…`, the same as the `call_tool` route's. A tool
the toolkit removes stays refused before the gate.

```yaml
    - id: mcp-ask
      # every MCP call (call_tool, acting as mcp_<server>_<tool>); not a find_tools search.
      # Before the rename (mcp_call) it also matched that tool's own name, for a call whose
      # tool resolved to nothing; call_tool refuses such a call anyway.
      tool: "mcp_*"
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
on the model key `qwen3-6-27b`, case-insensitively), or a list of them (a YAML list or
`|`-separated, `"small|deepseek-*"`; model notes take the same grammar, see
[Memory](memory.md#model-notes)). Without
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
`touches:`, `rm:`, `skip_read_only:` before 0.20, `memory:` before 0.36) doesn't parse, and a rule
that doesn't parse denies every tool call (see Failing closed). Bundles say
which chi they need (`requires_chi`), so their rules don't hit this.

## System 1 (experimental)

System 1 is a cheap classifier that judges an approval — "would the user
allow this?" — before it reaches them, so the asks they always allow stop
reaching them. With `mode: audit` every ask a person is about to see is
judged and logged and **nothing about the ask changes**: the user is asked
exactly as they would have been, and their answer is what settles the call.
With `mode: on` an ask that passes every gate is allowed **once** without
reaching them — see [Answering for the user](#answering-for-the-user-on-mode).

`Samagotchi::SystemOne` (lib/samagotchi/system_one/) speaks the TypeSafe
"System One" judgment API: `POST <host>/v1/systemone` with
`{model, state, questions}` and answers of type `noul` (a probability),
`choice` or `score`. The host is a `hosts:` entry with `api: openai` — a
local Splash server, or the hosted Jev API — and its key is that host's own
`api_key_env:`.

```yaml
guardrails:
  system_one:
    mode: off                # off (default) | audit (judge, log, never decide) | on
    host: splash             # the hosts: entry serving /v1/systemone
    model: Qwen3.8-Flash-Next-GSQ-RCO-GGUF:Q2_0   # else the host's first model
    rules: [git-push, git-rebase]                  # the rule ids it may answer for
    threshold: 0.8           # the probability an auto-allow needs
    min_record: 5            # clean records a rule needs before it is trusted
    timeout_ms: 2000         # a slower judgment is no judgment
```

`SystemOne::Client.from_config(host_registry: ...)` reads these on every
call, so a config.yml change takes effect on the next ask. `mode: off` (the
default) or no `host` means there is no client at all. Anything else is no
judgment and one `Log.warn(:guardrails, "system_one_failed", …)`: an
unreachable host, a host that isn't `api: openai`, a status other than 200,
a body that isn't JSON, a question with no answer, a request longer than
`timeout_ms`. A nil means "ask the user", which is what the caller would
have done anyway.

### What the audit writes

With a client, `GuardrailWiring#request_approval` asks System 1 one `noul`
question, `allow`, before the user is asked. Its instruction is a constant
in code (`SystemOne::ApprovalQuestion::INSTRUCTIONS`), reviewed like a
prompt; the state is the ask's own facts — the rule and its source, the
reason, the tool, the command (or the paths) cut to 2000 characters, the
edit's diff, the cwd, the repo and branch, and the session's title when it
has one. A memory ask also names what it is about: the entry and its scope,
and for a removal the description that entry's index line carries
(`Targets#memory`, read into the card by `Guardrails::Approval`): a path
alone tells the judge too little. The state then carries up to five of the
user's **earlier asks they answered** (`SystemOne::Similar`) — this rule in
this repository first, then this rule anywhere, then any answered ask, ranked
by how many words the logged call shares with this one, ties going to the
newest. Reading the log is best-effort, so a log that cannot be read simply
offers no examples. A participant's review turn is never judged: there is no
user there to ask. The judgment runs before the card appears, so an ask is
slower by up to `timeout_ms` (2000 ms by default).

Each judgment is a line in `judgments.jsonl`, beside `approvals.json` in
`$XDG_STATE_HOME/samagotchi/guardrails/` (`SystemOne::Log`): 0600, appended
under an exclusive `flock` (several workers write it), and rewritten —
keeping the newest half of its lines — once it passes 5 MB. A line is never
rewritten to add its label:

```json
{"kind":"judgment","id":"…","at":"…","session_id":"…","rule":"git-push","source":"config","tool":"execute","call":"git push origin main","call_digest":"<sha256 of the whole call>","repo_name":"samagotchi","p":0.97,"threshold":0.8,"model":"Qwen3.8-Flash","latency_ms":180,"decision":"audit","origin":"live"}
{"kind":"label","id":"…","at":"…","answer":"allow_once"}
```

`decision` is what the judgment led to: `audit` (audit mode), `asked` (on
mode, the user was asked), `auto` (on mode, System 1 answered for the user).
A judgment that never arrived is logged too, with `p` null, so the failures
count as well. The label line, keyed by the judgment's id, is what the user
did: `allow_once`, `allow_wide` (any scope wider than once), `deny`, or
`none` for an ask that was cancelled. **A parent agent's answer is not the
user's: its allow labels nothing. Its deny is a label only where the parent
could have allowed instead** — the ask is not `user_only` and the session's
parent level permits a permit (`Guardrails::ParentPolicy`); a parent that was
not allowed to allow says nothing about what the user would have done. An
auto-allow has no label at all, since nobody was asked.
`SystemOne::Log#entries` reads the file and returns the judgments joined with
their last label.

Everything about the log is best-effort: a write that fails is one
`Log.warn(:guardrails, "system_one_log_failed", …)` and the approval goes on
as if System 1 were not there.

`ruby script/system-one-probe HOST [MODEL]` asks three fixed approval-like
questions through the client and prints each probability and the latency of
the call — how a host is checked before any of this is turned on.

### Answering for the user: `on` mode

In `on` mode an ask is allowed **once**, without reaching the user, when every
gate below passes, in this order:

1. the mode is `on` (in `audit` the judgment decides nothing);
2. the ask's rule is in `guardrails.system_one.rules` — `"git-push|git-rebase"`
   or a YAML list, read like `guardrails.small_models`. Nothing is auto-allowed
   by default: the user names the rules they want;
3. the rule is not one of the three that let an agent answer chi's own
   questions — `chi-answer-piped`, `chi-answer-http`, `chi-broadcast` — which
   are never auto-allowed, even when listed
   (`SystemOne::SelfProtect::NEVER_AUTO`);
4. the call does not change chi itself (`SystemOne::SelfProtect.refuse?`): no
   edit or write whose paths include config.yml in chi's config dir, anything
   under the hooks dir, the installed bundles dir or the guardrails store (where
   `approvals.json` and `judgments.jsonl` live), and no `execute` or
   `task_create` command naming any of them — the `~/.config/samagotchi`
   spelling counts too. The memories dir is deliberately not one of these:
   reading or appending a memory file can be auto-allowed. A protected rule
   (`Verdict::PROTECTED_RULES`) may be listed by name and System 1 may answer
   it, but a call that really writes config.yml or the hooks is refused here;
5. the judgment's `p` is at least `guardrails.system_one.threshold` (0.8);
6. the rule's record is clean (`SystemOne::Record`, read from the log once per
   ask): at least `guardrails.system_one.min_record` (5) of its asks judged at
   or above the threshold that the user allowed, and none of its **last 20
   labelled** asks judged at the threshold that the user denied or later
   flagged as one System 1 should have asked about. Asks with no label, no
   probability, or a `none` label count for neither side.

Then the judgment's `decision` is `auto`, the verdict settles as
`settle!(:allow, decided_by: "system one")` with scope `once`, and nothing is
written to `approvals.json` — the next call is judged again. **No question is
opened, so no card appears, no `:question_asked` hook fires, and no
notification is sent.** The verdict's activity carries
`note: "auto-allowed by System 1 (p=0.97)"`, `judgment_id` and `p`; the line
that shows it in the terminal and the web is P3b, and is not rendered yet, so
today an auto-allowed call simply looks like a call that never needed
approval. If the judgment line cannot be written to the log, the ask goes to
the user.

A delegate child answers from its own session's settings: its System 1 can
auto-allow a call even when the child's `parent_answers: hard` bars a parent
from allowing it — the record gate is about the rule, not about who answers.

To correct an auto-allow after the fact, run `/guardrails` to see this
session's recent unlabelled auto-allows, newest first, then
`/guardrails wrong [N]` to label one. The label is appended, not written over
the judgment. `should_have_asked` makes the rule's record fail the false-allow
check, so the rule asks again until enough later clean asks rebuild its record.

### Seeding the record: `chi guardrails replay`

A rule's record starts empty, so `chi guardrails replay` (this machine only)
judges the asks the sessions here already answered and writes them to the same
log, with the user's answer as the label:

```sh
chi guardrails replay [--dry-run] [--threshold T] [--model M]
```

It reads every session's sidecar, `$XDG_STATE_HOME/samagotchi/sessions/<id>/cards.json`
(the file `Bridge::CardStore` saves), and takes the entries of type `question`
whose `pending_question.approval` is there and that have an `answer` or were
`cancelled`. A label is the scope the user took — `allow_once` for "Allow once",
`allow_wide` for a wider one, `deny` for anything else, `none` for a cancelled
ask. Skipped: a question no one answered, a relay card, which carries no
approval of its own, and a question id a previous replay already logged — so
running it twice adds nothing. A parent agent's answer is not the user's: its
allow is skipped, and its deny is replayed only where the parent could have
allowed (the card is not `user_only` and the session's parent level permits a
permit). A cards file that doesn't parse is skipped with one warning line,
never a failed run.

Each ask is judged exactly as a live one is (`SystemOne::ApprovalQuestion`),
and written as a `judgment` line with `decision` and `origin` both `replay`,
its `question_id` and the card's `created_at` as `asked_at`, followed by its
label. Then a table, one row per rule sorted by how many asks it had, and a
total: the asks, how many the user allowed, denied, how many at the threshold
System 1 would have auto-allowed, how many of those the user denied (the false
allows), and how many got no judgment. `--threshold` overrides
`guardrails.system_one.threshold` for the table; `--model` overrides the model
for this run; `--dry-run` judges and prints without writing a line. Without a
client (`mode: off`, or no `host`) it exits 2 saying what to set.

Two limits on what the replay can see: `CardStore` keeps only the last 20
questions per session, and a `--no-shared` REPL session never writes a
`cards.json` at all, so its asks are not replayable.

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
[Attached context](context.md#safety); the rule also sees `chi --remote NAME context add`, and a remote's `context push`
reaches its session with the trust of its chi web token, as your own `chi context push` does there); `chi broadcast` (`chi-broadcast`,
once at a time and only by the user: it is the user's command, which also
refuses to run inside a session; see [Broadcast](broadcast.md)); removing a
memory with `memory_write remove: true` (`memory-remove`, once at a time:
a delegate child could otherwise remove its parent's handoff unasked; see
[Memory](memory.md)); writing the identity memory, a model note or an overlay
of either with `memory_write`, `write` or `edit` (`prompt-memory-write`), or a
model overlay of any memory (`model-overlay-write`), each once at a time and
only by the user: these change a model's system prompt for later sessions (see
[Model notes](memory.md#model-notes); a shell command reaches them only under
`shell-touches-chi`'s text heuristic); and answering chi's
questions around `chi answer`: `chi --attach` or `chi -p` with stdin from a
pipe, a here-string or a file, not `/dev/null` (`chi-answer-piped`, which also sees
`chi --remote NAME --attach|--resume|-p` and `CHI_REMOTE=NAME chi …`), and `curl`/`wget` to a
session's `/answer` route (`chi-answer-http`), both once or for the session, and only by the
user (a parent agent allowing one would answer as the user).
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

## An external guard: chi-nah

[chi-nah](https://github.com/dm1try/chi-nah) is a bundle kept in its own repo (`chi bundle install
https://github.com/dm1try/chi-nah`). Its `before_tool_call` hook asks
[nah](https://github.com/manuelschipper/nah)'s deterministic guards about every `execute`, `task_create`,
`read`, `write` and `edit`: a call nah blocks (secret exfiltration, `rm -rf ~`, `git reset --hard`,
`curl | sh`…) is denied with the guard's name and how the user pauses it (`nah nap <guard>`); everything
else goes to chi's own rules. It needs nah installed; see its README for the settings.

## Failing closed

- A config hook with `required: true`, or a bundle `before_tool_call` hook with
  `on_error: fail_closed`, that fails to load (missing, syntax error, or for a
  bundle hook a sha256 that differs from the installed one) makes chi deny
  every tool call. One that raises when called denies that call.
- Other hooks stay fail-open; a load failure is a warning.
- Every load failure is shown once, at the start of the first turn
  (`guardrails> …` in the terminal, a red line on the web).

## Participants' text in later turns

A participant's message (a review contribution, see
[internals/participants.md](internals/participants.md#attribution)) stays in
the history, so later **owner** turns read it. chi marks it: the wire header
above it says it is a participant's and not the owner's instruction, and the
system prompt says the same while the session has participants. Owner turns
keep every guardrail. But an owner turn that says "do what Alex said" hands
Alex's text the owner's tools: the model will act on it as the owner asked.
That is the residual risk, documented rather than engineered away: on a
session with sensitive tools, quote the proposal you want applied in your own
turn instead: the web's **Apply** under a review turn does that (it puts your
line and the reply quoted line by line in your composer, for you to read and
send; [internals/participants.md](internals/participants.md#apply)). A quote
lowers the risk, it doesn't remove it: your line still asks the model to act
on what it quotes, with your tools, so read the quote before you send it.

Within its own turn a participant's text can't act: the review boundary
leaves it reads of the project only, and an injection that convinces the
model still meets the boundary (containment over detection). What it can do
is make the model *say* what the history holds: a review turn's model sees the
whole conversation, earlier tool outputs included, so start a review in a
fresh session (or a continue), not on a working session full of outputs. A
line of a participant's text that looks like one of chi's own headers goes
out quoted (`(quoted) [Steer from the user, …]`), under the real one, in any
case and after any spaces (chi's context-note and task frames too). The owner's
due reminders wait for the owner's next turn: they never go into a
participant's.

## Limits

Text matching on shell commands stops accidents, not a model set on getting
around it: `sh -c`, base64, a script written earlier, `git -C` variants and
aliases can get past a regex, and these rules are built for trusted models (a
model set on getting around them is chi-nah's job). A heredoc counts as data
only for the consumers listed under [Rules in config.yml](#rules-in-configyml)
(`cat`/`tee` to stdout, `git commit`/`git tag` `-F -`, `gh`'s body and notes
files, a `"$(cat <<'EOF' … EOF)"` message): anything else keeps its body in
the text a rule sees, and a function or alias shadowing a reader in the same
command isn't seen at all. `outside_repo` covers the file tools and git
only: `sed -i`, `cp` or `cat > file` into another folder from the shell aren't
asked about, and neither is git run through `sh -c`, a script, an alias, `make`
or a folder in a variable. `!cmd` lines typed by you are not checked. The only
real defence against an adversarial model is isolation (a sandbox, a git
identity without push rights).
