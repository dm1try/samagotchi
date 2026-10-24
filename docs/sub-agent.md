# chi as a sub-agent

Another agent (Claude Code, Codex, a script) can hand a task to chi and get the
answer back, the way you would from a terminal: `chi send --new --wait` starts a
session in a background worker and prints its reply. The session is an
ordinary one, so you (the human) can watch it live in `chi web` or join it with
`chi --attach ID`.

When chi's model asks a question (`ask_user_question`), a hook asks one, or a
guardrail wants an approval, chi stops and hands the question up: the wait ends
with exit 3 and the question, its options and the command that answers it. The
worker keeps the turn paused. The parent answers with `chi answer`, from what it
knows or after asking its own user, and chi goes on from there. The model gets
the answer as its tool result, as if you had answered in the web.

A chi parent's own `delegate` children work the same way, with one shortcut:
their approvals, and the hook questions the parent may only deny under the
child's `guardrails.parent_answers`, go to the parent's user as a card in the
parent's UIs instead (the relay, [Sessions](sessions.md#delegating)). When an
agent runs that parent with `chi send --wait`, the relay card is the parent's
own question: exit 3 with its text (`delegate ab12 … asks:`), options and
`answer_with`; the JSON has no `relay` key. Its `chi answer` is held to the
parent's setting, then to the child's.

The other direction, chi sending a part of its work to a Claude Code session
you already work with (to validate, as context, or with a question), is the
[claude-peer bundle](plugins.md#the-claude-peer-bundle): Claude pairs with the
chi session, chi's `claude_send` tool or `/claude` writes to Claude's inbox,
and Claude's answer comes back as attached context. The
[codex-peer bundle](plugins.md#the-codex-peer-bundle) does the same with a
Codex CLI session (`codex_send`, `/codex`, through `codex queue`). The peer's
answers wake chi in a short loop (fix or disagree, send again) until it says
`VERDICT OK` (one closing wake: chi carries on or tells you what was agreed)
or after `context.peer_turns` turns: [Waking: peer
sources](context.md#peer-sources-the-peer-loop).

## The commands

```sh
chi send --new --wait --format json [--dir D] [--model M] [--timeout S] -m "task"
chi send --wait --format json [--timeout S] [-m "follow-up"] ID
chi send --wait --format json [--timeout S] --turn T ID
chi send --queue --wait --format json [--timeout S] -m "follow-up" ID
chi answer ID --question QID (--option N|LABEL)... [--text T] [--timeout S] [--format json]
chi answer ID --question QID --dismiss [--timeout S] [--format json]
```

A child with a bundle setting of its own, such as a $ cap (the [cost-cap bundle](plugins.md#the-cost-cap-bundle)):
`chi send --new --wait --format json --set cost-cap.cap=3 -m "task"`. At the cap the wait exits 3 with the cost-cap
question; `chi answer ID --question QID --option Continue` (or `Stop`) answers it. A cap on the child's work across
its turns (the [work-cap bundle](plugins.md#the-work-cap-bundle)), the bound a parent that keeps answering the step
limit's Continue doesn't otherwise have: `--set work-cap.tool_calls=400` (or `work-cap.minutes=60`, active minutes).

`chi answer` waits after answering, the same way `chi send --wait` does, so the
next question comes back as exit 3 again. What it waits for is the answered
turn: the turn that asked (or, for the step-limit question, the turn it
continues), so its reply comes back, not that of a turn queued behind it.
A worker older than this (its `bridge.json` doesn't name `turn_ids`) gets
the session's next reply instead. `--option` is 1-based or the label,
repeated on a multi-select question. `--text` is free text (where the question
allows it) or the reason for a Deny. `--dismiss` leaves the question
unanswered: the model doesn't do what it asked about and finishes its reply.

Exit codes, both commands:

| Exit | `status` | Meaning |
|---|---|---|
| 0 | `answered` | `text` is chi's reply |
| 0 | `command` | (`chi send`) the message was a session command (`/model x`): it ran as one, no reply comes |
| 0 | `not_continued` | (`chi answer`) a Stop answered the step-limit question; the turn's work so far stays |
| 3 | `question` | chi waits for an answer: `question`, `answer_with` |
| 3 | `waiting_for_owner` | (a participant's wait, `chi --remote NAME send --wait` with their link's token) their review turn waits on the session's owner: a question or an approval it raised, or the owner's step-limit Continue; wait again |
| 4 | `running` | `--timeout` passed; the turn goes on, wait again |
| 1 | `refused` | (a participant's wait) their queued review turn was refused before it ran: `cancel_reason` `revoked` (their link was revoked or expired) or `cap_reached` (they spent their cap); no turn ran for it |
| 1 | `failed`, `canceled`, `limit`, `removed`, `no_answer`, `error`, `worker_gone`, `stopped` | `detail` says what happened (`limit`: the turn ran out of steps and nobody can be asked, e.g. an older worker; `chi send ID -m '/continue yes'` continues it, except under `guardrails.parent_answers: hard`, where a parent's `/continue yes` is refused as its `chi answer --option Continue` is; `removed`: the `--queue` message waited for was taken back before it ran, no turn ran for it). `failed` adds `error_kind` (the provider error's kind: `credits`, `credits_held`, `rate_limited`, `server`, `auth`, `connection`, …) and `retryable` when known; `canceled` adds `cancel_reason` (`user`: a Stop in the web; `session_stopped`: a session stop, `chi sessions stop` or the web's; `worker_stopped`: the turn waited for (a `--queue` message's, or a message's to an idle session) died with its worker (detail "its worker exited mid-turn"), settled by the next one; `hook`; `ctrl_c`; `manual`) and `stopped_by` (the hook that stopped it, e.g. `loop-guard`) when known |
| 2 | (no JSON) | usage error, or an option the question doesn't offer |
| 130 | `running` | Ctrl-C; the turn goes on |

With `--format json` stdout is one JSON object (see
[Starting a session](sessions.md#starting-a-session) for every field):
when the wait is about a known turn, it includes `turn_id`. Use
`chi send --wait --format json --turn <turn_id> <session_id>` to wait for
that exact turn again after exit 4, or after exit 3 if someone else will
answer the question. A turn id can name the running turn, a queued turn or
the last turn that ended; any other id is an error.

```json
{"status":"question","session_id":"297da360-…","question":{"id":"3f1c…","kind":"question",
  "text":"Which file should I read?","options":["README.md","NOTES.md"],"multi_select":false,
  "allow_freeform":false},"answer_with":"chi answer 297da360-… --question 3f1c… --option N"}
```

`kind` is `question` (the model's), `hook`, `approval`, which adds the tool,
command, folder, rule and reason, or `continue`, the step-limit question below.

## The step limit

A turn that runs out of steps (`turn.max_iterations`, default 300) before it
answers waits as a question of kind `continue` (`"limit": 300`, options
`Continue` and `Stop`). `answer_with` continues it:
`chi answer ID --question QID --option Continue`, and the continued turn's
reply (or its next question) comes back on that same wait. With
`--text "…"` the text joins the continued turn as a steer, labelled for the
model as coming from the parent agent that started the session, so one answer
continues and redirects it. (A `chi send -m` into a running turn joins it too,
labelled as sent with chi send.) To stop it:
`--option Stop`, with `--text "why"` for the model;
that wait ends with `status: not_continued`, exit 0, and the turn's work so far
stays in the session. A message instead (`chi send ID -m "…"`) drops the
question and starts a new turn. It can't be dismissed.

A parent may Continue by default: Continue grants no permission (every tool
call still meets the guardrails), it only spends time and tokens. With
`guardrails.parent_answers: hard` in chi's config.yml (config.yml only, no
environment variable; a session's own `parent_answers` may tighten it, see
[Guardrails](guardrails.md#a-sessions-own-level)) a parent may only Stop: `chi answer` and the worker
refuse a Continue (exit 1, `a parent agent may only stop this turn here`), the
question block's command is the Stop, and the user continues it from the web or
the terminal. See [Guardrails](guardrails.md#answers-from-a-parent-agent).

A chi parent's `delegate_result` gets a child's step-limit question back as a
`question` with these commands, for its model to decide: continue it (the
`chi answer` command, through `execute`), send a narrower follow-up with
`delegate session:` (which drops the question), or report back. It isn't
relayed to the parent's user the way approvals are.

A session at its cost cap (the [cost-cap bundle](plugins.md#the-cost-cap-bundle)) waits the same way, as a
question of kind `hook` with header "Cost cap" and options `Continue` and `Stop`: `--option Continue` raises the cap
by another cap's worth and the turn goes on, `--option Stop` ends it `canceled` with `stopped_by: cost-cap`. A session at its work cap (the
[work-cap bundle](plugins.md#the-work-cap-bundle)) asks the same, header "Work cap", the question naming the
session's totals (`Work cap reached: 412 tool calls of 400 (6 turns, 47 min active, $1.20). Continue raises it to
800.`); `stopped_by: work-cap` on Stop.

## Approvals

A chi parent (the `delegate` tool) doesn't go through any of this: its
children's approvals go to its own user as its own approvals, and its model
sees only how each was answered. See
[Sessions: Delegating](sessions.md#delegating). What follows is for other
parents (Claude Code, Codex, a script), and for a chi parent that can't host
the relay (a `--no-shared` REPL, `--non-interactive`).

An approval is a guardrail rule with `verdict: ask`: its user said "ask me". A
parent may always deny it (`--option Deny --text "why"`, `--text` alone, or
`--dismiss`). By default (`guardrails.parent_answers: soft` in chi's
config.yml, which has no environment variable, unless the session's own
`parent_answers` is stricter) it may also give "Allow once";
the wider scopes never go, and neither does any allow on chi's own config,
hooks or guardrail rules: `chi answer` refuses those with exit 1 and a line
like `only Allow once (guardrails.parent_answers: soft) can be given here: deny
it (--option Deny --text WHY), and tell your user`. With `standard` or `hard`
no allow goes (`allowing a tool call is up to the user: …`). The question
block lists what the parent may give: the Allow once command when it may, and
the deny command (`answer_with` is the deny), never `chi --attach`. The block
also offers to leave it open: tell your user it waits in chi web (the bell and
badge show it there), and `chi send --wait --format json --turn <turn_id> ID`
waits until they answer it. A plugin's question names the options a parent may
pick when the strategy leaves some out (`allowed_options` in the JSON). See
[Guardrails](guardrails.md#answers-from-a-parent-agent).

Start a child in the folder it should change (`chi send --new --dir PATH`):
writes and mutating git outside its own repo ask (`write-outside-repo`,
`git-outside-repo`), which a parent can at most allow once per call.

An answer typed into `chi --attach` or the REPL counts as a parent's too when
stdin isn't a terminal or an agent marker (`CLAUDECODE`, `AI_AGENT`,
`CODEX_THREAD_ID`, `SAMAGOTCHI_PARENT_SESSION`) is set.

The same holds for another machine's session in this terminal (`chi --remote
NAME --attach ID`, `--resume ID`, `--dir DIR -p TEXT` from a pipe): the answers
go as chi answer's and are held to that machine's `guardrails.parent_answers`;
a question left waiting at the pipe's end is exit 3, its report read with that
machine's parent strategy (asked again then) and its commands spelled `chi
--remote NAME answer …`. For one turn and no terminal, use `chi --remote NAME
send --new --dir D -m TEXT --wait` (`--non-interactive` is this machine's only).

Through `chi web` (`POST /api/sessions/:id/answer`, what chi answer uses against
another machine's sessions) the answer keeps chi answer's mark: the route passes
on `client_id: "cli:answer"` and drops any other id, so a forwarded answer can
only be held to the parent rules, never pass for the user's own. The worker's
refusal (403 `parent_answer_refused`) comes back as it said it. A parent's
`/continue yes` and a loosening `/parent-answers` sent through `chi web`'s create
and turn routes are refused there too, held to that machine's config.yml.

The worker checks it again with its own config.yml. The guardrails settings
have no environment variables, and a worker drops any `SAMAGOTCHI_GUARDRAILS_*`
it inherits; but a parent that sets `XDG_CONFIG_HOME` picks which config.yml a
worker it starts or wakes reads. Still, this guards a parent that follows its instructions,
not a security boundary: the worker's Bridge and `chi web` on localhost take
answers from any local process.

## Things to know

- A question waits for as long as it takes: the worker doesn't idle-exit while
  one is open. `chi sessions list` shows such sessions as `waiting`
  (`--format json`: `waiting_id` is the question's id);
  `chi sessions stop ID` ends one.
- If the worker dies while a question waits, the question goes with it.
  `chi answer` then exits 1 and says to send the task again
  (`chi send --wait -m "…" ID`); a wait ends with `worker_gone` (exit 1).
- A follow-up (`chi send --wait -m "…" ID`) to a session waiting for an answer
  isn't sent: it exits 1 with the `chi answer` command for the question. The
  step-limit question is the exception: it waits between turns, so a message
  goes in, drops it and starts a new turn.
- A follow-up to a session whose turn still runs (`busy: a turn is running`,
  exit 1, say you waited on with `--timeout` and got exit 4) goes in with
  `chi send --queue --wait -m "…" ID`: it runs as a turn of its own after the
  running one, and the wait is for that turn's answer alone, never the running
  turn's (`--format json` adds `"delivery": "queue"`). A question the running
  turn asks meanwhile isn't yours: the wait goes on through it (until your
  `--timeout`); one the queued turn asks comes back as exit 3. `chi answer`
  on the running turn's question gets that turn's reply, not your queued one.
- `chi send --wait ID` with no message waits past a question already reported
  (the step-limit question too), until someone answers it. It waits for the
  turn running when it starts (or the one the step-limit question continues),
  and prints that turn's reply, not a queued one's after it. To an idle
  session whose last turn already ended (no question standing), that ended
  turn is the answer: its reply comes back (`answered`), or its end when it
  left no reply (`failed`, `canceled`, `limit`, …) — so a turn that finished
  in the gap between waits is reported, not waited for.
- An answer to a question that is no longer open (you answered it in the web
  first) isn't sent; `chi answer` says so and waits for what comes next. Its
  JSON then has `"answered_here": false` (absent when the answer went in), so
  an `answered` status there is someone else's answer's turn, not yours.
- `chi send --wait` and `chi answer` don't read stdin unless it's a pipe or a
  file. Agent shells usually pass `/dev/null`, which is fine.

## Instructions for the parent agent

Paste this into the parent's `CLAUDE.md` or `AGENTS.md`:

```markdown
## Using chi as a sub-agent

Start a task: `chi send --new --wait --format json --timeout 500 -m "<task>"`
(add `--dir <project>`). Read the JSON on stdout:

- `status: answered` (exit 0): `text` is chi's reply.
- `status: question` (exit 3): chi is paused, waiting for an answer. If the answer
  is clear from your task and context, answer it yourself. Otherwise ask your
  user, showing them the question and its options; if you can't ask (no user in
  this run), stop and report the question and options instead of guessing. To
  answer, run the `answer_with` command with `--option N` (1-based, repeat for
  multi-select) and/or `--text "…"`. It returns the same JSON. If you leave it
  open for someone else to answer, wait again with `--turn <turn_id>` from the
  JSON. If you won't answer, add `--dismiss` instead: chi does nothing it asked
  about, finishes with what it found, and the reply comes back (exit 0).
- `question.kind: approval`: chi wants to run something its user's guardrails
  flagged. What you may give follows chi's `guardrails.parent_answers` (or the
  session's own, stricter `parent_answers`), and the
  question says it: when its `allowed_options` (and the text block's `allow:`
  line) list "Allow once" (`soft`, the default), you may allow that one call if
  your task clearly needs it; never a wider scope (this session, a repo, a
  rule), and never a call on chi's own config, which lists only Deny. Otherwise
  (`standard`, `hard`, or anything wider) allowing it is up to your user: deny
  it (the `answer_with` command: `--option Deny --text "why"`), and tell your
  user what it wanted to run and why. Or leave it open: tell your user it waits
  in chi web (the session's short id), then
  `chi send --wait --format json --timeout 500 --turn <turn_id> <session_id>`
  waits until they answer it there. Never give an answer the question doesn't
  offer you by another route (a piped `chi --attach`, `chi send -m '/continue
  yes'`, chi's web API).
- `status: running` (exit 4): still working. Wait for that same turn again:
  `chi send --wait --format json --timeout 500 --turn <turn_id> <session_id>`.
- `question.kind: continue`: chi ran out of steps before it answered. If it is
  getting somewhere, continue it (`answer_with`, `--option Continue`, with
  `--text "…"` to steer it on the way); if not,
  stop it (`--option Stop --text "why"`, exit 0, status `not_continued`) or send
  a narrower follow-up instead. Ask your user when unsure.
- Anything else (exit 1): report `detail` to your user. `chi --attach <session_id>`
  shows the session.

Run each chi command on its own, nothing chained after it: the exit code comes
back with the output. Talk to chi only through these commands; never call its
Bridge or web API directly. Follow-ups in the same session:
`chi send --wait --format json --timeout 500 -m "…" <session_id>`; if that says
`busy` (a turn still runs), add `--queue`: the follow-up runs after that turn
and you get its own answer.
Keep `--timeout` under your shell tool's limit (Claude Code: 600 s per call).
```
