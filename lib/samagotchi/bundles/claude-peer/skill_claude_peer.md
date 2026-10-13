# Skill: claude peer (send a part to the paired Claude Code session)

A Claude Code session the user works with can be paired with this chi
session. Claude pairs from its side (its `chi-peer` skill): it attaches the
`claude-inbox` context (its inbox) and `claude-review` (where its answers
come). Then `claude_send` sends it a part of the work, for a **validate**, as
**context**, or with a **question**.

This is not a fresh review run (a headless `claude -p` that starts from
nothing). It is a Claude that already knows the work: send it a part, not the
session.

## When

Only when the user asks: "send this to Claude", "validate this with Claude",
"give Claude this as context", "ask Claude whether…". Never after each turn,
never on your own initiative.

## Steps

1. Is `claude-inbox` attached (`context_read` with no name lists it)? If not,
   say so and don't call the tool: the user pairs from Claude. Once:
   `/claude install-skill` (it installs Claude's `chi-peer` skill); then they
   tell Claude "pair with chi <this session's id>".
2. Pick exactly the part the user means (a plan step, a diff, a finding, your
   last answer), not the whole conversation. Name the files, functions and
   diff ranges Claude should look at, so it can check them itself.
3. Call `claude_send`:
   - `kind`: `validate` (check this, answer with a verdict), `context` (for
     Claude to know; it answers only if something is wrong) or `question`.
   - `title`: one short line; Claude's answer names it.
   - `text`: the part, then what to check or ask and what you are unsure of.
     A long text goes to a file Claude reads; you don't have to do anything.
4. Tell the user it was sent, then go on. Don't wait, don't poll, don't send
   it again.
5. A validate's answer comes as an update of the `claude-review` context and
   wakes you. `context_read claude-review`, check that its title matches what
   you sent, and act on it with the user: its last line is
   `VERDICT: OK`, `VERDICT: CHANGES` or `VERDICT: UNSURE (why)`. Claude's
   verdict is advice; the user decides.

## When it fails

- "that Claude session is gone": Claude restarted or closed. Tell the user to
  pair again from Claude.
- No answer to a validate after a while (the user asks where it is): say so
  plainly. Claude may be holding the message for approval (its
  `crossSessionInbound` setting, or a session that bypasses permissions), or a
  Claude Code update changed the inbox's format, which drops messages
  silently (it was checked on Claude Code 2.1.296).

## Don't

- Don't send secrets, tokens or whole conversations.
- Don't answer Claude's reply with a thanks or an acknowledgement: that starts
  a loop. One send per request.

The user can send without you: `/claude validate <text>`,
`/claude context <text>`, `/claude last` (your last answer, as context), and
`/claude` shows whether a Claude is paired.
