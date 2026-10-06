# Broadcast

`chi broadcast` shares one piece of information with every session it may
concern, without picking them: "payments API returns 500 since 14:00 (PAY-123)",
"the PRD for checkout v2 changed: no guest checkout". Each session it reaches
gets it as a [context note](sessions.md#context-notes) from `broadcast`, and
that session's agent decides whether it affects its work. Sessions it doesn't
concern never see it.

```sh
chi broadcast -m "payments API returns 500 since 14:00 (PAY-123)"
pbpaste | chi broadcast              # the note from stdin
chi broadcast --dry-run -m "…"       # who would get it and why; nothing is delivered
chi broadcast --all -m "deploy freeze until 18:00"   # every recipient, tag or not
```

To tell one session or a few you picked, use `chi note ID...` instead.

## Who it reaches

The recipients are your own sessions, in every project:

- a worker or a chi REPL runs them now, or their last turn ended within
  `broadcast.active_hours` (default 8). A session with no turn yet counts
  by its last save;
- not a delegate child: its parent relays what concerns it (the
  `coordinator`'s builders included). A fork is your session and counts;
- not a `chi scratch` session, not an archived one, and not a test run
  (unless `chi broadcast` itself runs as one, `SAMAGOTCHI_ENV=test`).

A session open in a plain chi REPL (`--no-shared`) can't take notes: it is
listed as skipped, "open in a chi REPL".

## Tags: which sessions it concerns

A recipient gets the note when the note and the session share a tag:

| Tag | In the note | About the session |
|---|---|---|
| ticket | an id like `PAY-123` (`broadcast.ticket_pattern`) | its branch (any case: `feat/pay-123-retry`), your prompts there |
| pr | `PR #42`, a GitHub pull request URL | an attached `pr-42` source (the github-pr bundle), a PR URL in your prompts there |
| link | a URL, by host and path | a URL in your prompts there or in an attached context source's hint |

A link is compared without its scheme, `www.`, query, fragment or trailing
slash; a bare host (`https://github.com/`) is no tag. A PR URL names its repo,
so `acme/shop#42` doesn't match `acme/other#42`; `PR #42` with no repo matches
pull request 42 of any repo. Words the default ticket pattern would take that
are no ticket (`UTF-8`, `SHA-256`, `ISO-8601`, `GPT-4`, …) are left out.

A session that shares no tag is skipped for now, listed as "no tag match (not
checked: no triage yet)": a small triage model that reads the note and each
session's scope card is the next step. Until then, `--all` reaches them all.

## What it prints

One line per recipient, the ones that got it first, then a summary:

```
broadcast  "payments API returns 500 since 14:00 (PAY-123)"
3f2a1c9e  delivered  ticket PAY-123 matches (branch)
91ab02c4  delivered  link notion.so/team/checkout-v2 matches (messages); waits for its next start
c0ffee12  skipped    no tag match (not checked: no triage yet)
d00dad00  skipped    open in a chi REPL
delivered 2 · skipped 2
```

A session a worker runs adds the note within a few seconds (after a running
turn); one with no worker gets it at its next start ("waits for its next
start"). Nothing starts a turn anywhere.

`--dry-run` prints the note's tags, each recipient's verdict ("would get it" or
"skipped") and its scope card: what chi knows about it from local state, and
what a triage model will read.

```
3f2a1c9e  would get it  ticket PAY-123 matches (branch)
          project: shop (folder ../shop-pay, branch feat/pay-123-retry)
          title:   shop-pay · now the retry spec
          tags:    ticket PAY-123 · pr acme/shop#42
          started: Fix the payments retry …
          recap:   Fixing the payments retry. Specs next.
          recent:  now the retry spec
```

Exit status: 0 when it ran (skipped sessions included), 1 when it was refused,
no session is active or a delivery failed, 2 for a usage error.

## What a session gets

The note is your text, then one line chi adds:

```
[CONTEXT NOTE from broadcast, 14:20]
payments API returns 500 since 14:00 (PAY-123)
(Shared by your user on 2026-10-06 14:20 with the sessions it may concern; it reached you because ticket PAY-123 matches your branch.)
[END NOTE]
```

With `--all` the line says "with every active session". The date is there
because a session with no worker may read it days later. The system prompt
tells the model what a note from `broadcast` is: if it affects its current
work, it says so briefly in its next answer, otherwise it ignores it, and it
doesn't act on it unless you ask. Other notes keep their rule (background,
not mentioned on their own). `chi note --source broadcast` is refused, so a
plain note can't pass for a broadcast.

The note and its line together are capped at 16 KiB like any note; the text
may take up to 15872 bytes.

## For you, not for an agent

`chi broadcast` refuses to run inside a chi session (where
`SAMAGOTCHI_PARENT_SESSION` is set): "chi broadcast is for your user, not an
agent". With the guardrails bundle, the `chi-broadcast` rule also asks before
any shell command that runs it, once at a time, and only you may allow it
(a parent agent's `chi answer` can't). See [Guardrails](guardrails.md).

## Settings

| Setting | Default | What it does |
|---|---|---|
| `broadcast.active_hours` | `8` | A session with no worker or REPL counts when its last turn ended within this many hours. |
| `broadcast.ticket_pattern` | `\b[A-Z][A-Z0-9]+-\d+\b` | A Ruby regex for ticket ids; an invalid one warns and the default is used. |

```yaml
broadcast:
  active_hours: 12
  ticket_pattern: '\b(?:PAY|OPS)-\d+\b'
```
