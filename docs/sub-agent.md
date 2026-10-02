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

## The commands

```sh
chi send --new --wait --format json [--dir D] [--model M] [--timeout S] -m "task"
chi send --wait --format json [--timeout S] [-m "follow-up"] ID
chi answer ID --question QID (--option N|LABEL)... [--text T] [--timeout S] [--format json]
chi answer ID --question QID --dismiss [--timeout S] [--format json]
```

`chi answer` waits after answering, the same way `chi send --wait` does, so the
next question comes back as exit 3 again. `--option` is 1-based or the label,
repeated on a multi-select question. `--text` is free text (where the question
allows it) or the reason for a Deny. `--dismiss` leaves the question
unanswered: the model doesn't do what it asked about and finishes its reply.

Exit codes, both commands:

| Exit | `status` | Meaning |
|---|---|---|
| 0 | `answered` | `text` is chi's reply |
| 3 | `question` | chi waits for an answer: `question`, `answer_with` |
| 4 | `running` | `--timeout` passed; the turn goes on, wait again |
| 1 | `failed`, `canceled`, `no_answer`, `error`, `worker_gone`, `stopped` | `detail` says what happened |
| 2 | (no JSON) | usage error, or an option the question doesn't offer |
| 130 | `running` | Ctrl-C; the turn goes on |

With `--format json` stdout is one JSON object (see
[Starting a session](sessions.md#starting-a-session) for every field):

```json
{"status":"question","session_id":"297da360-…","question":{"id":"3f1c…","kind":"question",
  "text":"Which file should I read?","options":["README.md","NOTES.md"],"multi_select":false,
  "allow_freeform":false},"answer_with":"chi answer 297da360-… --question 3f1c… --option N"}
```

`kind` is `question` (the model's), `hook`, or `approval`, which adds the tool,
command, folder, rule and reason.

## Approvals

An approval is a guardrail rule with `verdict: ask`: its user said "ask me". So
a parent may deny it (`--option Deny --text "why"`, `--text` alone, or
`--dismiss`) but not allow it: `chi answer` refuses an Allow with exit 1 and
`allowing a tool call is up to the user: deny it (--option Deny --text WHY),
and tell your user`. For an approval, the question block and `answer_with` give
the deny command, not `--option N` or `chi --attach`. With
`guardrails.parent_approvals: once` in chi's config.yml (it has no environment
variable), "Allow once" goes through; the wider scopes never do,
and neither does any allow on chi's own config, hooks or guardrail rules. See
[Guardrails](guardrails.md#approvals-from-a-parent-agent).

An answer typed into `chi --attach` or the REPL counts as a parent's too when
stdin isn't a terminal or an agent marker (`CLAUDECODE`, `AI_AGENT`,
`CODEX_THREAD_ID`, `SAMAGOTCHI_PARENT_SESSION`) is set.

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
  isn't sent: it exits 1 with the `chi answer` command for the question.
- An answer to a question that is no longer open (you answered it in the web
  first) isn't sent; `chi answer` says so and waits for what comes next.
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
  multi-select) and/or `--text "…"`. It returns the same JSON. If you won't
  answer, add `--dismiss` instead: chi does nothing it asked about, finishes
  with what it found, and the reply comes back (exit 0).
- `question.kind: approval`: chi wants to run something its user's guardrails
  flagged, and allowing it is up to your user. Deny it (the `answer_with`
  command: `--option Deny --text "why"`), and tell your user what it wanted to
  run and why. Or leave it open: tell your user it waits in chi web (the
  session's short id), then `chi send --wait --format json --timeout 500 <session_id>`
  waits until they answer it there. Never allow it yourself, through
  `chi answer`, a piped `chi --attach` or chi's web API.
- `status: running` (exit 4): still working. Wait again:
  `chi send --wait --format json --timeout 500 <session_id>`.
- Anything else (exit 1): report `detail` to your user. `chi --attach <session_id>`
  shows the session.

Run each chi command on its own, nothing chained after it: the exit code comes
back with the output. Talk to chi only through these commands; never call its
Bridge or web API directly. Follow-ups in the same session:
`chi send --wait --format json --timeout 500 -m "…" <session_id>`.
Keep `--timeout` under your shell tool's limit (Claude Code: 600 s per call).
```
