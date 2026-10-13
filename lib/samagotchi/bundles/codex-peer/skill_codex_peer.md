# Skill: codex peer (send a part to the paired Codex session)

A Codex CLI session the user works with can be paired with this chi
session. Codex pairs from its side (its `chi-peer` skill): it attaches the
`codex-inbox` context (its thread id) and `codex-review` (where its answers
come). Then `codex_send` sends it a part of the work, for a **validate**, as
**context**, or with a **question**.

This is not a fresh review run (a headless `codex exec` that starts from
nothing). It is a Codex that already knows the work: send it a part, not the
session.

## When

Only when the user asks: "send this to Codex", "validate this with Codex",
"give Codex this as context", "ask Codex whether…". Never after each turn,
never on your own initiative.

## Steps

1. Is `codex-inbox` attached (`context_read` with no name lists it)? If not,
   say so and don't call the tool: the user pairs from Codex. Once:
   `/codex install-skill` (it installs Codex's `chi-peer` skill); then they
   tell Codex "pair with chi <this session's id>".
2. Pick exactly the part the user means (a plan step, a diff, a finding, your
   last answer), not the whole conversation. Name the files, functions and
   diff ranges Codex should look at, so it can check them itself.
3. Call `codex_send`:
   - `kind`: `validate` (check this, answer with a verdict), `context` (for
     Codex to know; it answers only if something is wrong) or `question`.
   - `title`: one short line; Codex's answer names it.
   - `text`: the part, then what to check or ask and what you are unsure of.
     A long text goes to a file Codex reads; you don't have to do anything.
4. Tell the user it was sent, then go on. Don't wait, don't poll, don't send
   it again.
5. A validate's answer comes as an update of the `codex-review` context and
   wakes you. `context_read codex-review`, check that its title matches what
   you sent, and act on it with the user: its last line is
   `VERDICT: OK`, `VERDICT: CHANGES` or `VERDICT: UNSURE (why)`. Codex's
   verdict is advice; the user decides.

## When it fails

- "that Codex session is gone": Codex has no record of that thread. Tell the
  user to pair again from Codex. A Codex session that was only closed is not
  "gone": the send succeeds and the message waits for it (below).
- "no codex on the PATH" or "no Codex CLI at …": the chi that runs this
  session can't find `codex`; the user installs it or sets `CODEX=` to its
  path where chi runs.
- "Codex didn't take the message in 10 s": the Codex side didn't answer the
  queue; the send was stopped. Say so; don't retry in a loop.
- No answer to a validate after a while (the user asks where it is): say so
  plainly. The Codex session may have been closed: the message waits for it;
  the user runs `codex resume` there or pairs again from a new Codex
  session. Codex may be mid-turn (a queued message runs after its turn), or
  its sandbox can't write chi's state: its `~/.codex/config.toml` needs the
  `writable_roots` line for chi's context folder (`/codex install-skill`
  shows it), and Codex must be restarted after adding it.

## Don't

- Don't send secrets, tokens or whole conversations.
- Don't answer Codex's reply with a thanks or an acknowledgement: that starts
  a loop. One send per request.

The user can send without you: `/codex validate <text>`,
`/codex context <text>`, `/codex last` (your last answer, as context), and
`/codex` shows whether a Codex is paired.
