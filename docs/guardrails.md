# Guardrails

Every tool call the model makes passes one check before it runs, in both
loops (native and chat hosts). The verdict is **allow**, **ask** or
**deny**; the strictest vote wins, and a deny can't be undone by a later
voter. Of two asks the first one names the rule, except a rule only the
user may allow (`chi-config`, `chi-home`, `chi-hooks`, `shell-touches-chi`,
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

The card also carries the ask's facts as `approval:` (tool, command or paths, where, rule, scopes, preview…):
`Guardrails::Approval.payload` builds them as a `Guardrails::ApprovalFacts` value, which System 1 and the parent
checks read in the worker; the card and the session file get its `to_h`, the same hash every UI reads, and a saved
card comes back through `ApprovalFacts.from_h` (string or symbol keys, missing fields nil).

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
rules), the hooks dir or the approval store, by its rule (`chi-config`, `chi-home`,
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

If `chi answer` reaches a worker that refuses its Bridge secret (`403
bridge_secret`), it prints a session-specific recovery message rather than
treating that as a refused answer: `"session ID's worker refused this chi's
request (it didn't name its secret): a chi web or terminal started before chi
was updated can't reach it; restart chi web, re-attach with chi --attach ID,
or restart the worker with chi sessions restart ID"`. `chi sessions restart
ID` can also recover when the worker cannot be asked, but only if disk shows
no running turn, pending question or approval, queued prompt, or running
background task; when one exists, stop it explicitly and then send a prompt.

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

Built in, for `write`, `edit` and `memory_write` (symlinks resolved; see
[How paths resolve](#how-paths-resolve)):

- deny: the approval store's dir, installed bundles (`memories/.bundles/`),
  and [attached context](context.md) sources (`<state dir>/context/`: a
  source's command runs later, outside the gate; `chi context` changes them);
- ask (once or for the session): `config.yml`, `home.json` (the [chi home](configuration.md#the-chi-home): the Ruby every chi launch boots) and the plain hooks dir.

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
(`/usr/bin`, `~/.gem`) never ask, nor does a read-only command that writes only
into a tmp dir (`/tmp`, `/var/tmp`, `$TMPDIR`): its `>` / `>>` targets, `cp`'s
destination (the last argument, or `-t` / `--target-directory`) and `tee`'s
files, resolved against its `cwd:` and any `cd` or `pushd` before them, as in
`sqlite3 -readonly -safe ../app/x.db "select 1" > /tmp/rows` or
`cp ../app/x.db /tmp/x.db`. A target that links back out of the tmp dir (a
symlink, a dangling one, a file with another hard link), `cp -l`/`-s`, `mv`,
`&>`, `>|` and `>&file` still ask, as does a target with a `$` or `~` (the
call's `env:` may set it), a `popd`, and a `cd`/`pushd` that isn't one existing
dir spelt `/…`, `.` or `..` joined by `&&` only (it may fail or be skipped and
leave the shell elsewhere); so does every tmp write when the
child's folder is itself in that tmp dir. A `task_create` call's paths resolve under chi's env and
under its own `env:` (its `$TMPDIR`, `$HOME`, `GIT_DIR`, …): either one naming another checkout asks. An `env:` that
redefines the shell (`BASH_ENV`, `BASH_FUNC_cat%%`, `CDPATH`, …, as under `skip_read_only` below) always asks, even
for `cat a.txt` in the child's own folder: what it runs is in no word of the command. The answer is once or for the child's
session only: a repo or rule answer would hold in every worktree, for every
child, so a stored repo or rule approval doesn't let it through either. Its
ask goes before the rules, so with the guardrails bundle in strict mode the
card still names `child-boundary`. The parent (never a delegate), forks and
ordinary sessions don't get it. Like the rules it reads command text: a
`sh -c` body, a script or `$(…)` isn't looked into.

## A participant's review boundary

Built in, for a [participant's](internals/participants.md#turns) turns in a
**review session** only (a turn whose author is `p:<id>`, in a session with a
`review:` key: `ParticipantMode.of` is `:review`; a working session's
participant turns get the [pair boundary](#a-participants-pair-boundary)
instead), in every mode (also with
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
  web token, memories and their `.bundles`, `config.yml`, hooks, and a
  `hooks.hooks_dir` configured outside the config dir), `~/.ssh`,
  `~/.gnupg`, `~/.aws`, and the project's `.env*`, `.netrc`, `*.pem`, `*.key`,
  `*.p12`, anything named `credentials` (`.git-credentials` too), `.npmrc`,
  `.pypirc`, ssh keys (`id_rsa`, `id_ed25519`, …), `*.tfstate`,
  `secrets.yml`/`.json`, `.docker/config.json`, `.kube/config` and any config
  under `.git` (a submodule's too). The path is checked as given and as it
  resolves, so a symlink in the project to `~/.ssh` is `~/.ssh`, and
  `node_modules/foo/../../.config/gh/hosts.yml` with `foo` a link to `~/src/foo`
  is `~/.config/gh/hosts.yml` ([How paths resolve](#how-paths-resolve)). A session
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

## A participant's pair boundary

A participant's turn in a **working session** acts with the session's tools
under the owner's guardrails, as the owner's own turns do: the rules, the
protected paths and every approval the owner already granted apply, and an ask
goes to the owner. It is a pair turn only when all three hold
(`ParticipantMode.for_turn`, decided once at the turn's start:
`GuardrailWiring#turn_mode`): the session has no `review:` key, its worker
names the `pair_turns` feature, and the participant's grant was issued with
`mode: pair`, which chi share and the web's Invite stamp only when the warning
they showed said their turns act. A grant from before, or one issued while an
older worker held the session, keeps review turns until it is invited again.

`Guardrails::PairBoundary` (rule `pair-boundary`, source `core`) sits in the
review boundary's seat in `GuardrailWiring#checks`, in every mode (also with
`guardrails.enabled: false`), and **denies, never asks**, each with its own
message:

- secrets, read or written: the review boundary's denylist (chi's state and
  config dirs, so `grants.json`, the web token and every `participants.json`;
  `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gh`, `~/.config/fish`,
  `~/.config/git`, `~/Library/LaunchAgents`, `~/.local/bin`; the home's shell
  startup files, histories, `.gitconfig`, `.netrc`, `.npmrc`, `.pypirc`, `.claude.json`;
  the project's secret files, any config under `.git`) on every file tool's
  path (`read`, `write`, `edit`, a plugin's `targets:` paths) and on the paths
  a command names (`execute`, and any call whose targets carry a command),
  each word resolved as `touches: chi_dirs` resolves it; a glob that matches a
  secret or whose fixed part leads into a denied folder (`~/.ss?/id_*`,
  `~/.config/*/config.yml`, `.en?`), a `$var` word whose fixed part does
  (`~/.ss${d}h`), with a leading `~`, `$HOME`, XDG dir (its default when
  unset) or `$TMPDIR` expanded (`ls $XDG_CONFIG_HOME/samago*`); after `$TMPDIR`
  the fixed part counts only inside a denied folder, not as the start of one's
  name (an isolated run's state dir is in tmp: `ls $TMPDIR/*` isn't denied);
  and a text match for the rest. A prefix that comes through a
  variable (`x=~/.s; cat ${x}sh/config`) isn't followed: such a command isn't
  denied, it asks (its `$var` word and the assignment's path place it outside
  the project);
- sweeping a folder that holds secrets: `find`, `tar`, `cp`, `rsync`, `scp`,
  `zip`, `ditto`, `grep`/`rg`/`ag` and the like given home or any folder above
  a denied one, and linking to one (`ln -s ~/.config g`, `ln -s ../.. up`);
- the environment, the keychain and stored credentials: `env` or `printenv`
  alone, `set`, `export`, `declare` or `typeset` that list, `launchctl
  getenv`, `ps e`/`ps -E`, `security`, `/proc/*/environ`, and the commands
  that print a credential (`gh auth token`, `git credential fill` and the
  `git credential-*`/`docker-credential-*` helpers, `gcloud … print-access-token`,
  `op`, `aws configure get`/`export-credentials`, `az account
  get-access-token`, `heroku auth:token`, `kubectl config view --raw`;
  `PairCommand::CREDENTIAL_PRINTERS`). On top of it, a pair turn's `execute` runs
  without every variable whose name matches `KEY|TOKEN|SECRET|PASS|CREDENTIAL|AUTH`
  (`PairBoundary::SECRET_ENV_NAME`, case-insensitive) and without the session's
  project env ([Project env](sessions.md#project-env)); a command that runs
  `mise` or `direnv` asks the owner (`ENV_LOADER`: they load the project's env
  files, and `.envrc`, `mise.local.toml` and its kin are secrets like `.env`),
  and so does a write (by a file tool or a command) to mise's config, its
  `.tool-versions` included (`MISE_CONFIG`: the owner's next worker start runs
  its `[env]` and installs what it pins; a command asks when a part of it that
  names one may write: `rm`, `mv`, `find … -delete` and `find … | xargs rm`
  do, a read-only part such as `find . -name mise.toml && make` doesn't, the
  list split at `;`, `&&`, `||` and newlines outside `( … )`; mise's own
  writes, `mise use`/`mise set`, ask as runs of mise; a config that changes
  without being named, by `git checkout`, `git stash pop`, `tar x`, `patch` or
  `cp -r dir/. .`, isn't asked about: the owner's next restart runs it);
  and a command still
  running at the limit is killed, never handed over as a background task;
- git config writes, whatever the key (any may make git run a command later
  in the owner's name: hooks, `core.fsmonitor`, a filter, diff or merge
  driver, a credential or gpg helper, `hook.<name>.command`, an include): a
  pair turn's `git config` only reads, parsed strictly
  (`PairCommand#git_config_read?`: `--get`, `--get-all`, `--get-regexp`,
  `--get-urlmatch`, `--get-color(bool)`, `-l`/`--list`, `get`, `list` or a lone
  key, with `--show-origin`, `--show-scope`, `--name-only`, `-z`, `--type=…`,
  `--default`, `--file F` and the like, every word accounted for; any other
  option, an abbreviation git would take (`--glob`, `--comm`), a short form
  (`-t`) or a word too many is a write). Denied too: `git -c`, `--config-env`,
  a clone's, init's or submodule's `-c`/`--config`, an assignment of
  `GIT_CONFIG_*` or `GIT_TEMPLATE_DIR`, `git` under an alias, `git config` after
  `xargs` or in `find -exec`, and an interpreter's script naming `git config`
  or `git -c`, behind any of git's own options (`--attr-source X`,
  `--shallow-file X`; one chi doesn't know is read both with and without the
  next word as its value, `PairCommand.git_command_starts`), and by a
  builtin's dashed name (`git-config`, `…/git-core/git-submodule foreach`:
  judged as `git config`, `git submodule`). A command git runs now from its text (`git submodule foreach`,
  `rebase --exec`, `bisect run`, a `filter-branch` filter, `--upload-pack`,
  `--receive-pack`, `--extcmd`, an `ext::` URL) is read as a command of its
  own and asks as an outside write. A `.gitattributes` write isn't asked
  about: it only selects a driver, and defining one is what's denied;
  and writing git's hooks: a `write` or `edit` of a path in a `.git/hooks`
  folder, a submodule's `.git/modules/<name>/hooks` too (as given or as it
  resolves), or a command whose part that names one isn't read-only
  (`printf … > .git/hooks/pre-commit`, `cp x .git/hooks/`), and installing
  them: `git init`/`clone --template`, and the hook installers
  (`PairCommand::HOOK_INSTALLERS`: `pre-commit install`, `husky`, `lefthook
  install`, `simple-git-hooks`, `overcommit --install`);
- running chi, by any wrapper (`bin/chi`, `bundle exec chi`, `ruby … bin/chi`,
  `env … chi`, `watch`, `npx`, `sh -c 'chi …'`, `$(chi …)`), in an assignment's
  value or an alias, a function, after `-exec`/`-c`/`-e`, but `chi --version` and
  `chi --help`: its commands act in the owner's name (shares, caps, sends,
  answers, sessions);
- calling chi web on this machine: a command whose text names a loopback name
  (`localhost` and its subdomains, `127.x`, `0.0.0.0`, `[::1]`, `::ffff:127.x`,
  `0:PORT`) or this machine's host name together with chi web's port (the one
  the running chi web recorded in `web.json`, config's `web.port`, 4567), by
  `curl`, `wget`, `nc`, `/dev/tcp`, a script's URL or anything else
  (`PairBoundary::CHI_WEB`): defense in depth, as a LAN chi web asks loopback
  for the token too, and a loopback-only one still takes it as the owner. A
  Bridge answers only with its secret, which sits in chi's state dir;
- opening a URL or a file in the owner's apps (`open`, `xdg-open`, `gio open`,
  a browser, `osascript`'s `open location`, a script's `webbrowser`) and
  listening on a port (`nc -l`, `socat …LISTEN`, `python -m http.server`,
  `ruby -run -e httpd`, `php -S`, a static server, a script's `listen(`/
  `HTTPServer`/`createServer`): the owner's browser sends its cookies (chi
  web's on 127.0.0.1 or the LAN address, kept for every port) to the page
  it opens (`PairBoundary::OPENER`, `PairBoundary::LISTENER`);
- a program whose name the shell expands: a `$var`, a `$(…)` or a glob in a
  command's name (`bin/ch? …`, `e=ch; ${e}i …`, `$CMD x`), whatever it would
  turn out to be (`PairBoundary::VERB`);
- leaving something running: `&` at a command's end, `nohup`, `setsid`,
  `disown`, `screen -d…`, `tmux new -d`, and scheduling it: `crontab`, `at`,
  `batch`;
- owner-voiced tools, which act in the owner's name beyond the turn:
  `delegate` and any `delegate_*` tool, `register_reminder`,
  `cancel_reminder`, `send_note`, `forget_outputs`, `task_create`,
  `task_stop`, `find_tools` (it loads tools into the session), and
  `memory_write` (a memory reaches the owner's later sessions); and the tools
  that read the owner's background tasks and their output, `task_wait`,
  `task_get`, `task_list` (a pair turn starts none);
- `ask_user_question`, with the advice to ask in the reply: nobody on the
  participant's side answers a card.

A script a command hands on is read too (`Guardrails::PairCommand`): one a
shell runs (`sh -c`, `eval`, a heredoc or here-string) as a command of its
own, one another interpreter runs (`ruby -e`, `python - <<EOF`) by its text
(chi, secrets, the environment, detaching). So is a command handed through a
variable a program runs through a shell (`PairCommand::COMMAND_ENV`:
`GIT_EDITOR`, `GIT_SEQUENCE_EDITOR`, `EDITOR`, `VISUAL`, `GIT_EXTERNAL_DIFF`,
`GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_PROXY_COMMAND`, `GIT_PAGER`, `PAGER`,
`MANPAGER`, `GIT_ASKPASS`, `SSH_ASKPASS`), as a prefix, `env`'s or `export`'s:
read as `sh -c` would run it, for the refusals and for an outside write. A heredoc written as data (`cat`,
`tee`, `git commit -F -`) is not looked into: where it goes is checked. A
command the checks can't read is refused, never let through on a text match.

And it **asks the owner** before a `write` or `edit` that may land outside the
session's project root, and before a command that may write there, every time:
the ask is fresh (`Verdict#fresh_ask`: no stored approval answers it, and no
rule lowers it), so it comes even in auto mode. A command fails closed
(`PairCommand#outside_writes?`): it runs unasked only when it

- only reads (`ReadOnlyShell.read_only?`, wherever it reads), or
- only reads but for writes it can name (a `>`/`>>` target, `cp`'s
  destination, `tee`'s files) into the project or a tmp dir
  (`ReadOnlyShell.read_only_but_writes?`), or
- stays inside the project: every part of it runs in the project, and every
  path it names lands in the project or a tmp dir, an option's or an
  assignment's value (`of=`, `--output=`, `GIT_DIR=`), a glob's fixed part
  (`~/oth*`), `git -C`'s folder and the paths in a script it hands on (`sh -c`
  read as a command, `python -c`/`ruby -e`/a heredoc by the paths in its text)
  among them. The program's own word doesn't count (`/usr/bin/sed`), nor does
  `PATH=…`, nor a message's heredoc (`git commit -m "$(cat <<'EOF' … EOF)"`);
  and it runs no program that writes to its own place outside with no word
  naming it (`Guardrails::ImplicitWriters`, examples rather than a closed
  set: `npm`/`pnpm`/`bun`/`deno` global in any spelling (`-g`, `--global=true`,
  `--location global`, `npm_config_global=true`), `npm`/`yarn`/`bun link`,
  `npm config set`/`login` (`~/.npmrc`), `yarn global`, `pip install`/`pip
  config` by any interpreter (`python3.12 -m pip`, `pypy3 -mpip`; with or
  without `--user`: its site-packages is wherever its Python is; a project
  venv's `.venv/bin/pip` and `-t`/`--target`/`--prefix` don't count), `uv pip
  install --system`, `gem install`, `bundle config set` without `--local`,
  `brew` but its reading verbs, `defaults write`, `cargo install`, `go
  install`/`go env -w`, `pipx`, `uv tool`/`uv python install`, `dotnet tool
  install -g`, `corepack enable`, `rustup`/`pyenv`/`rbenv`/`asdf`/`volta`/`nvm`
  installs and globals, `code --install-extension`, `gh auth`/`config
  set`/`extension install`, `launchctl` but its reading verbs, `git maintenance register`/`start`, `git
  lfs install`, `scalar register`/`clone`; a project
  install such as `npm install` or `bundle install` and build caches don't
  count), and no shell or interpreter that reads its script from stdin: one
  on the receiving end of a pipe whatever its options (`… | sh`, `| bash -x`,
  `| sh -e`, `| python3 -c 'exec(input())'`), `< file`, `bash -s`, `python3 -`,
  or with no script at all: chi can't see that script. A shell's `-e`, `-x`
  and `-o …` are flags, only `-c` (or a cluster holding it, `-ec`, `-cx`)
  hands it a script: the first word after its options (`sh -c -- S`, `bash -c
  -x S`); an interpreter's own code flag does (`python -c`, `ruby -e`,
  `node -e`/`-p`/`--eval=`, `perl -e`/`-E`, `php -r`), alone or in a cluster
  (`ruby -we`, `perl -le`, `node -pe`, `python3 -Ic`, `python3 -c'…'`;
  `PairCommand.cluster_code_at`: a letter that takes the rest of the word,
  `ruby -rset`, holds no code). A script file it names (`sh
  run.sh`, `ruby x.rb`) is not read.

  Accepted gaps (an accident guard for a trusted team): a script file the turn
  wrote and then runs; inline scripts read only by their text for paths
  (`find … -exec sh -c '…'`, `flock … sh -c`, `awk 'BEGIN{system(…)}'`,
  `deno eval`); a `GIT_CONFIG_*` set by `printf -v` or `read` and exported
  (it affects that command only); a variable outside `COMMAND_ENV` whose
  value a program runs (`LESSOPEN`, a tool's own `*_EDITOR`); `npx -y`,
  `npm exec`, `pnpm dlx`, `uvx`: they fetch into a cache, which doesn't count,
  and run the package as in-project work.

Anything else asks: `rm -rf ~/x`, `sed -i … ~/x`, `curl -o ~/x`, `dd of=~/x`,
`touch`/`mkdir` outside, `perl -pi … ~/x`, `cd .. && make`, `cd && make`, and
whatever the checks can't place: a `$var` (`rm -rf $DIR`, `> "$OUT"`), a `$(…)`,
`xargs`, a `cd $X`. A path "lands" in the project or a tmp dir every way it
resolves ([How paths resolve](#how-paths-resolve)) and never through a dangling
symlink or onto a file with another hard link (`Outside.inside?`,
`Outside.tmp_write?`, the child boundary's tmp rule): the tmp dirs are
`Dir.tmpdir`, `/tmp` and `/var/tmp`, except the one the project itself is in.
`/dev/null` and the like neither ask nor deny. A script file's body (`ruby
x.rb`, `make`, `sh ./run.sh`) isn't read: it runs as in-project work.
A command that makes a link asks too, wherever it points (`ln`, `link`, `cp
-s`/`-l`, `sh -c 'ln …'`, an interpreter's `symlink`/`link(`): a path through
a link the same command makes is judged before the link exists, so `ln -s ..
up && cat up/…` can't be read for what it reaches.
A session whose folder is the home folder or above it has no project to
keep the turn in (`ReviewPaths.home_root?`, the review boundary's test): every
write there asks.

A participant's ask names them on the owner's card ("Sam's turn asks: approve
tool call?", `approval.author`/`author_name`, `approval.asked_by`, the same
line in the plain question: `Approval::ASKED_BY`) and offers **Allow once**
only: no session, repo or rule approval is made from a participant's call.
System 1 never judges it, and `chi guardrails replay` skips it. A pair turn
stops before its next generation once the participant passed their spending
cap or their link was revoked or expired
([participants](internals/participants.md#limits-and-the-cap)).

The trust model is a team's (everyone invited is trusted): the boundary is an
**accident guard** for secrets and the owner's voice, not containment of a
hostile participant; a review session is. A pair turn can still reach, through
the owner's rules: `web_fetch` (an open egress path: what the turn can read it
can send out in a URL), plugin and MCP tools, `memory_read` and `context_read`,
`list_sessions` (the owner's other sessions' titles), chi web by a name the
check doesn't know (a DNS name or a decimal address for 127.0.0.1, a port
forward, a port spelt in a variable), where a LAN chi web still takes a
token-less loopback request as the owner's, and anything a script
does that the command checks don't read (a script file's body, an interpreter's
`-e` code). Share a working session only with people you would let type in it.

## A Verify fresh child's boundary

A [Verify fresh](internals/participants.md#what-a-participant-sees) child (a
delegate child chi web starts for an unclear verdict) runs a participant's
check under **the boundary that participant has in the parent**. A verdict a
participant recorded is always checked again as them, even when the owner
clicks (the claim is their text; their link must still be live), so it never
runs with the owner's rules or System 1's auto-allows. The mode is decided once,
at the start, from their grant's mode there (`ParticipantMode.live_for`) and
saved on the child (`verify_fresh.mode`): `review` keeps every turn of it
inside `ReviewBoundary` (read only), `pair` inside `PairBoundary`.
`GuardrailWiring#turn_mode` reads the saved mode and never looks it up again,
and every turn of the child carries the participant as its author, whoever
started it, so the boundary can't fall away for a turn the owner typed into it
or for an author lookup that finds nobody (the child has no
`participants.json`; revoke and cap read the parent's). It fails closed: a
`verify_fresh` field that doesn't read is a participant nobody has, under
review, whose turns are refused. `ChildBoundary` applies on top, as for every
delegate child, and its asks go to the owner (once only, as a participant's
do; System 1 skips them). The owner's own fresh child is an ordinary delegate
child: the owner's turns, `ChildBoundary`.

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
git hooks (`core.hooksPath` honoured) or any `.git/hooks` (a submodule's `.git/modules/<name>/hooks` too)
outside a tmp folder.
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
`sqlite3` is read-only only with both `-readonly` and `-safe`; options are
checked even after the database name, and only its read/display options are
allowed (unknown options and dot-command arguments are rejected). `gh` allows
only `run list|view`, `pr list|view|diff|checks`, `issue list|view` and
`repo view`; `--web`/`-w`, `gh api` and `pr checks --watch` are not read-only.
`$(…)`, backticks, `$VAR` (other than `$HOME`, `$XDG_*`, `$TMPDIR` and `$PWD`
at a word's start), an env prefix, `sh -c`, `xargs`, `eval`, `sudo` and the
like make a command not read-only, as does a `task_create` `env:` that sets `BASH_ENV`, `ENV`, `CDPATH`, `IFS`,
`SHELLOPTS`, `BASHOPTS`, `BASH_FUNC_…`, `LD_PRELOAD`, `LD_AUDIT`, `DYLD_INSERT_LIBRARIES`, `GIT_EXTERNAL_DIFF`,
or a git config variable (`GIT_CONFIG`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `GIT_CONFIG_PARAMETERS`,
`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_n`/`VALUE_n`: `ShellGitDirs::CONFIG_ENV`) (they change what its words run; `PATH`
doesn't count; a pair turn's command that assigns a git config variable is denied like `git -c`). It errs
towards asking.

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
absolute path; other globs match the path relative to the repo root. A glob
matches the path as the call gives it (against the cwd, `~` expanded) and as it
resolves (symlinks, `..` the kernel's way: see How paths resolve), a relative
glob then from the repo root as it resolves (`/tmp` is `/private/tmp` on
macOS): `write hl/pre-commit` with `hl` a link to `.git/hooks` matches
`**/.git/hooks/**`. Rules only ask or deny, so the resolved path only ever adds
a vote; were a verdict ever to let a call through, a symlink into its glob
would not count.

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

A path that is or goes through a dangling symlink (a write would create the
link's target) or a file with another hard link (a write changes the other
name too) is always outside, in the repo or a tmp folder alike
(`Outside.resolve`, which the child boundary's tmp writes read as well).

#### How paths resolve

Every path check (protected paths, `outside_repo`, `touches`, `rm`, `memory:
prompt`, the child, review and pair boundaries, System 1's own-files test)
resolves paths with `Guardrails::PathResolve` (the map below):

- `..` is taken the kernel's way (`.expand`): after a symlinked folder it
  climbs out of the link's target, so `repo/link/../x` with `link` pointing
  to `/elsewhere/deep` is `/elsewhere/x`, not `repo/x`;
- symlinks are resolved on the longest part that exists, and a dangling
  symlink is followed to the file a write through it would create (`.real`);
- a check reads the path both ways, the lexical answer (`File.expand_path`,
  stopping at a dangling link) and where the kernel lands (`.reals`): it
  refuses, asks or votes when either is protected, outside or a secret, so
  the kernel's answer only ever adds to the lexical one. A file tool call's
  paths (`Targets#paths`, what approvals show) list both when they differ.

In a shell command a file argument resolves the same way, against the folder
the command is in by then. A `cd` or `pushd` to such a path may land either
way: `cd link/..` is back where it started only while that logical folder
exists (zsh, which chi's shell is on macOS, and bash chdir to the physical one
when it doesn't), and `cd -P`, `set -P` and zsh's `chase_links`/`chase_dots`
always take the physical one. So after it the command counts as in both
folders: each later word is resolved against each (a word that can't be
resolved from one isn't resolved), and judged both ways as above; past eight
folders, or after `cd -`, the folder is unknown. After `cd link` a `../x`
climbs out of the link's target as well. git's `-C`, `--git-dir` and
`--work-tree` (and `GIT_DIR`/`GIT_WORK_TREE`) are counted both ways, from each
folder the command may be in, with a leading `~`, `$HOME`, XDG dir or `$TMPDIR`
expanded as a `cd` expands it (`PathResolve.expand_word`).

On a disk that folds case (macOS), a path is in a protected folder however its
letters are cased, also where the rest doesn't exist yet (`PathResolve.under?`):
a write to `<state dir>/CONTEXT/x` is a write to the attached context dir once it
exists.

For whoever changes these checks, one shared helper per primitive, each surface
keeping its own predicate (`spec/guardrails/path_consistency_spec.rb` pins what
every surface answers for the same paths):

| Primitive | Where | Used by |
|---|---|---|
| expand (`..` the kernel's way), real, lexical_real, reals | `PathResolve` (`ProtectedPaths` keeps the old names) | every surface |
| in a dir: `under?` (case-folded on a folding disk; `fold: false` exact), `strictly_under?`, `within?` (root resolved too) | `PathResolve` | `under?`: ShellPaths, ReviewPaths, PairCommand, ChildBoundary, SelfProtect's words; `Outside.within?` and RmTargets' `strictly_under?` fold only when the dir exists (a missing session root keeps the case it was typed in); `within?`: ProtectedPaths, ScratchWrites, ParentApprovals, SelfProtect's paths |
| tmp dirs and "not one the session is in" | `PathResolve.tmp_roots(session:)` (exact case) | Outside (`Outside.tmp_roots` is the list it and Targets read), RmTargets; `touches_chi?` takes all of them |
| a shell word's `~`, `$HOME`, XDG dirs, `$TMPDIR` | `PathResolve.expand_word` | ShellPaths::Walk, ShellGitDirs; PairCommand has its own `~`/`$HOME` (`expand_tilde`) |
| chi's dirs | `ChiDirs.protected` / `.touches` / `.self_protect` / `.review` | ParentApprovals, Targets, SelfProtect, ReviewPaths (`ProtectedPaths` and `ScratchWrites` get theirs from the wiring) |

Left apart on purpose: `Targets.prompt_memory_path?` compares in any case on
every disk, `PairCommand#leads_into_denied?` matches a partial name (`~/.ss`),
and each surface resolves its root its own way.

`git: outside_repo` (shell tools only) reads the command for git subcommands
that change a checkout: `commit`, `add`, `reset`, `checkout`, `switch`,
`rebase`, `merge`, `push`, `stash` (not `stash list`/`show`), `rm`, `mv`,
`cherry-pick`, `revert`, `pull`, `restore`, `am`. It follows `cd`,
`pushd`/`popd`, `( … )`, `git -C`, `--git-dir`/`--work-tree`, `GIT_DIR`/`GIT_WORK_TREE`
and the call's `cwd:`, and matches when one of them runs outside the session's
repo (the same `outside_repo` as above). `cd /other && git status`, `git -C
/other log` and `cd /other && bundle exec rspec` don't match. A folder the text
doesn't tell (`cd $REPO`, `cd "$(…)"`, `cd -`; a `$XDG_CONFIG_HOME` or
`$TMPDIR` is told) doesn't either; see Limits.

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

Toolkit suggestions are a second use of System 1. When
`toolkit.suggest.mode` is `audit` or `on`, the engine asks a `choice`
question from a background thread after the turn starts. This uses the same
configured host, model and timeout, but is gated by `toolkit.suggest.mode`,
not `guardrails.system_one.mode`. Audit never changes the session's toolkit;
on mode's turn waits for the answer (at most `timeout_ms`, cut by a Stop)
and may start the session on the suggested kit (configuration.md, Toolkits).
Its warnings use the `toolkit` tag and its records are written to
`toolkit_suggestions.jsonl` beside the guardrail logs. To avoid competing
with the session's model, audit skips (one info line) when
the System 1 host is the model's local host: the same `hosts:` name, or
another entry for the same server root (scheme, host and port). There is no
reliable single-slot signal, so this host-identity check is the available
contention guard. The session's own checks come first; the kits and the
suggestion log are read only for a session that can be asked, the log only
after an earlier `undecided`.

### What the audit writes

With a client, `GuardrailWiring#request_approval` asks System 1 one `noul`
question, `allow`, before the user is asked. Its instruction is a constant
in code (`SystemOne::ApprovalQuestion::INSTRUCTIONS`), reviewed like a
prompt; the state is the ask's own facts — the rule and its source, the
reason, the tool, the command (or the paths) cut to 2000 characters
(`ApprovalQuestion::TEXT_CHARS`), the edit's diff, the cwd, the repo and branch, and the session's title when it
has one. A memory ask also names what it is about: the entry and its scope,
and for a removal the description that entry's index line carries
(`Targets#memory`, read into the card by `Guardrails::Approval`): a path
alone tells the judge too little. The state then carries up to five of the
user's **earlier asks they answered** (`SystemOne::Similar`) — this rule in
this repository first, then this rule anywhere, then any answered ask, ranked
by how many words the logged call shares with this one, ties going to the
newest. Reading the log is best-effort, so a log that cannot be read simply
offers no examples. A participant's turn (review or pair) is never judged:
there is no user there to ask, and its asks go to the owner. The judgment runs before the card appears, so an ask is
slower by up to `timeout_ms` (2000 ms by default).

Each judgment is a line in `judgments.jsonl`, beside `approvals.json` in
`$XDG_STATE_HOME/samagotchi/guardrails/` (`SystemOne::Log`): 0600, appended
under an exclusive `flock` (several workers write it), and rewritten —
keeping the newest half of its lines — once it passes 5 MB. A line is never
rewritten to add its label. Its `call` is shorter than the state's: cut to 300
characters (`ApprovalQuestion::CALL_CHARS`), with `call_digest` the SHA256 of
the whole call:

```json
{"kind":"judgment","id":"…","at":"…","session_id":"…","rule":"git-push","source":"config","tool":"execute","call":"git push origin main","call_digest":"<sha256 of the whole call>","repo_name":"samagotchi","p":0.97,"threshold":0.8,"model":"Qwen3.8-Flash","latency_ms":180,"decision":"audit","origin":"live"}
{"kind":"label","id":"…","at":"…","answer":"allow_once","question_id":"…"}
```

`decision` is what the judgment led to: `audit` (audit mode), `asked` (on
mode, the user was asked), `auto` (on mode, System 1 answered for the user).
A judgment that never arrived is logged too, with `p` null, so the failures
count as well. The label line, keyed by the judgment's id, is what the user
did: `allow_once`, `allow_wide` (any scope wider than once), `deny`, or
`none` for an ask that was cancelled. A live label carries the card's
`question_id` when the user answered (the judgment is written before the card
exists), so a replay knows the ask was judged. **A parent agent's answer is not the
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
A turn stopped while the judge is asked is not a failed judgment: the cancel
(`LLM::RequestCancelled`) goes through `SystemOne::Client#ask`, no line is
written, and the call is denied without a card; a turn that stopped as the
judgment came back opens no card either.

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
4. the call does not change chi itself (`SystemOne::SelfProtect.refuse?`), by
   its own set of chi's dirs (`Guardrails::ChiDirs.self_protect`: the dirs whose
   asks only the user may answer, `ParentApprovals.chi_files?`, plus the whole
   state dir), wider than that test: no edit or write whose paths are in chi's
   config dir (config.yml), the hooks dir, the installed bundles dir, the
   guardrails store (where `approvals.json` and `judgments.jsonl` live), the
   attached context dir or anywhere else in chi's state dir (the sessions), and
   no `execute` or `task_create` command naming any of them: a write's paths and
   a `cat` of them answer alike (`SelfProtect.chi_dirs`). `chi_files?` itself
   still applies on top (its text match, the command spelling a dir). A command is checked twice: by its text
   (`ParentApprovals::CHI_TEXT`: `$XDG_CONFIG_HOME/samagotchi/config.yml`,
   `~/.config/samagotchi/…`, a `cd ~/.config` then `samagotchi/config.yml`),
   and by its words resolved as `shell-touches-chi` resolves them
   (`Guardrails::ShellPaths::Walk`: cd chains, `~`, `$HOME` and the XDG dirs,
   symlinks, `..`; under the call's `env:` too), so `cd ~/.config; cd
   samagotchi; cat config.yml` or a symlink into the config dir is refused.
   A call whose `env:` redefines the shell (`Targets#redefines_shell?`:
   `BASH_ENV`, `BASH_FUNC_…`, …) is refused whatever it names. The memories
   dir is deliberately not one of these: reading or appending a memory file
   can be auto-allowed, by a command none of whose words lands in chi's dirs
   outside the memories, whose text shows no climb (`SelfProtect::CLIMB`: a
   `..` segment, any `$` or `$(…)`, backticks, a `~` other than the home one,
   `cd -`), and whose words the walk can't resolve are only data read while
   it knew the dir: a script or heredoc body (`python3 -c '…'`, `cat >> x.md
   <<'EOF'`), a phrase (`echo "- a note"`) or a glob with no `/`. So
   `cd memories; cd ..`, `cd "${PWD%/*}"`, `cd $(dirname $PWD)` or `cd -`
   loses the exemption, and the memories text then refuses it. So does a
   script a shell or interpreter runs that climbs by its own calls
   (`SelfProtect::SCRIPT_CLIMB`: `os.pardir`, `dirname`, `chdir`, `Dir.pwd`,
   `Path.parent`, `rindex`, a slice from the end), and one chi can't see: a
   script file (`cd memories && python3 x.py`) or stdin (`… | python3`,
   `sh < f`, any interpreter or shell a pipe feeds, `| sh -x` too), by any
   version's name (`python3.12`, `pypy3`, `Rscript`, `tclsh`), or a program
   that runs a file (`SelfProtect::FILE_RUNNERS`: `make`, `rake`, `awk -f`,
   `deno run`, `npm run`). A heredoc only written (`cat >> x.md <<'EOF'`) is
   data whatever it says. A script body is not looked into beyond its text:
   an accident guard, not containment (a script can build a path some other
   way: `p.replace("memories", "config.yml")`, `p[0:len(p)-8]`, `.sub`,
   `.slice` aren't caught). The price is some harmless commands the user now
   answers: `python3 scripts/lint.py <memories>/notes.md`, `cat notes.md |
   python3 -c …` from the memories folder, a climb word written as data by a
   script (`File.write(".../notes.md", "dirname")`).
   A protected rule
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
`note: "auto-allowed by System 1 (p=0.97)"`, `judgment_id` and `p`, and the
call's tool row shows it: the terminal's tool line ends in
`· auto-allowed (System 1, p=0.97)`
(`TerminalUI::Formatting#format_tool_guardrail_suffix`, live and when
attaching to a saved turn), and the web's activity row carries
**auto-allowed · System 1** with `rule …, p=…, allowed once` on hover and the
owner's **should have asked** button (below). The stage trail shows no mark.
If the judgment line cannot be written to the log, the ask goes to the user.

A delegate child answers from its own session's settings: its System 1 can
auto-allow a call even when the child's `parent_answers: hard` bars a parent
from allowing it — the record gate is about the rule, not about who answers.

To correct an auto-allow after the fact, run `/guardrails` to see this
session's recent unlabelled auto-allows, newest first, then
`/guardrails wrong [N]` to label one. In chi web, the owner can instead click
**should have asked** on that tool row; participants cannot use that route.
The label is appended, not written over the judgment. `should_have_asked`
makes the rule's record fail the false-allow check, so the rule asks again
until enough later clean asks rebuild its record.

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
approval of its own, a question id a previous replay already logged — so
running it twice adds nothing — and an ask already judged live (audit or on
mode): by the `question_id` its label carries, or, for a live judgment with
none (a cancelled ask, an older line), by its session and `call_digest`, one
card per such line. A parent agent's answer is not the user's: its
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

Within its own turn in a review session a participant's text can't act: the
review boundary leaves it reads of the project only, and an injection that
convinces the model still meets the boundary (containment over detection). In
a working session it acts, by design ([the pair boundary](#a-participants-pair-boundary)):
invite only people you would let type in your session, under your guardrails. What it can do
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
