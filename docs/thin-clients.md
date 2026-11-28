# Thin clients

A thin client is anything small that talks to chi web over HTTP: an iOS
Shortcut, a shell script, a watch app. It sends a message to a session and gets
the answer back, without running chi itself. The session is an ordinary one:
you can watch it in `chi web` while the client talks to it.

Every call below is the owner's: it needs chi web's access token, the same one
`chi remote add` takes (the part of chi web's LAN link after `token=`, or its
`$XDG_STATE_HOME/samagotchi/web-token` file), sent as
`Authorization: Bearer <token>`. To reach chi web from your phone outside the
LAN, use [Tailscale Serve](configuration.md#tailscale-serve-your-tailnet) or
an [auth proxy](configuration.md#behind-an-auth-proxy) (`web.public_url`).
A client holding the token can do anything you can do in chi web, so keep it
safe.

Check that chi web has these routes first: `GET /api/info` lists `"ask"` in
its `features`. An older chi web lacks it (and answers 404 for `/ask`): update
chi there (`chi update`). A new session answered in one call needs
`"ask_create"`, and your last session `"ask_last"` (both below).

## Ask

```sh
T=$(cat ~/.local/state/samagotchi/web-token)
curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -X POST http://192.168.1.29:4567/api/sessions/3fa2/ask -d '{"prompt": "what changed today?"}'
# {"status": "done", "session_id": "3fa2…", "text": "…", "turn_id": "…", …}
```

The id can be a prefix. A continued session's message goes to the newest link
of its chain; `session_id` is where it ran, and `asked` is the id you gave when
another link ran it. Body fields:

- `prompt` (required): the message, at most 16 KiB. A terminal-only command such
  as `/stats` is refused (400 `local_command`); a session command such as
  `/model x` runs and answers `{"status": "command"}`, with no token.
  `/continue yes` on a session whose turn ran out of steps, while its worker
  runs, continues that turn and answers as a message does (its reply, or a
  `token`); if the offer was answered elsewhere first you get what came of it.
  A continue offer still shown as a question (409 `waiting`) is answered
  through `/answer`.
- `timeout`: seconds to wait for the answer, at most 30 (the default).
- `queue`: `true` (the default) means a session running a turn queues your
  message as its own turn, and you get that turn's answer. `false` refuses a
  running session with 409 `busy`.
- `client_id`: who is asking. Leave it out for yourself (the line is the
  owner's, as from the web composer). An agent sends `"agent:NAME"`: see
  [An agent over HTTP](#an-agent-over-http).
- `request_id`: your own key for this ask, 1 to 128 printable ASCII
  characters. Send the same ask again with the same `request_id` (a retry
  after a dropped connection) and you get the first one's turn instead of
  sending it again. It is for messages only: a session command with one (a
  line starting `!`, or `/name` then a space or nothing) is 400
  `invalid_ask`; a path such as `/Users/me/a.rb fails` is a message. It holds
  while that turn is running, queued, or has replied or ended, and otherwise
  while the session's worker remembers the key; it does not hold across a
  continue to a new link. Use a new key for a new message: while the first
  turn is running, queued, or has replied or ended, the same key with another
  prompt gets that turn's answer and nothing is sent; otherwise a worker that
  remembers the key answers 409 `enqueued_id_conflict`. An answer that echoes
  `request_id` means chi web used it (an older chi web ignores the field).
- `reply_for`: what your surface can show, so the reply fits it. See
  [Replies that fit the surface](#replies-that-fit-the-surface).

A question that is waiting for an answer refuses the ask with 409 `waiting` and
the `question`. Answer it first (below).

## Replies that fit the surface

A voice Shortcut can't show a table, and a widget has room for one line. Say so
with `reply_for` on the ask: a name, or the values themselves.

```sh
curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -X POST http://192.168.1.29:4567/api/sessions/3fa2/ask -d '{"prompt": "status?", "reply_for": "voice"}'
# {"status": "done", "text": "Three commits are in. The rm command works, …", …}
```

The values (a missing one is the full value, as the web has):

| value | full | restricted |
|---|---|---|
| `formatting` | `markdown` | `plain`: no markdown, no emoji, no links |
| `room` | `long` | `short` (at most 60 words), `one_line` (at most 80 characters, one sentence of 15 words or fewer) |
| `choices` | `many` | `0` to `9`: how many options a question may offer |
| `detail` | `true` | `false`: no commands, code or diffs, and no approvals (below) |

`"reply_for": "voice"` is `{"formatting": "plain", "room": "short", "choices": 3,
"detail": false}`. Name your own in config.yml's
[`surfaces:`](configuration.md#surfaces-names-for-reply_for), for example
`"reply_for": "watch"`. A name is read when the ask comes in, and the session
saves its values, so a later config edit doesn't change old turns. An unknown
name, key or value is 400 `invalid_ask`.

What happens:

- chi tells the model in a line with your message, and the reply is written
  for the surface. The session keeps one answer per turn: the web shows this
  short one too. Ask again on the web for the long one.
- With `formatting: plain` the answer you get has its markdown taken out (list
  bullets, bold, code marks, headings, tables, link URLs, emoji; a numbered
  list keeps its numbers). So does a question's text and header; its options
  stay exactly as they are, since you answer by label. Only your answer: the
  session, the web and the terminal keep the model's text. A `token` you wait
  on keeps doing this.
- The next message from the web or the terminal gets full formatting again: chi
  tells the model once.
- Each message declares its own: send `reply_for` on every ask from that
  surface. A message with it always runs as its own turn (with `queue: false`,
  a running session is 409 `busy` as usual).

**Questions.** A surface with `detail: false` gets the model's own questions and
the "continue or stop?" question as usual. An approval, a spending question
(cost-cap, work-cap) or a question whose options only you may pick answers
`"status": "waiting_for_answer"` with `"needs": "detail"`, a `text` to speak
("chi needs an approval: open it on a full screen.") and the question's `id` and
`kind` only. Open it in chi web (the phone notification takes you there). The 409
`waiting` of a later ask says the same. `POST …/answer` takes `reply_for` too:
with `detail: false` such a question is 403 `needs_detail`, nothing answered.
Like `client_id`, this is a convention for an honest client: the token itself
can still answer anything.

**Older chi.** Check `GET /api/info` lists `"reply_for"` in its `features`. An
older chi web ignores the field and answers 200 with a full reply. A chi web
that has it refuses a session whose worker is older with 409
`reply_for_unavailable`, and nothing is sent: update chi if needed, then
restart the session (`chi sessions restart ID`). A session restarts on the chi
that made it, so a restart alone may not be enough.

## When the answer takes longer

Each call answers within **35 seconds** of its request, whatever it waits for
(a continue in flight, a worker starting, the answer), so a proxy or a Shortcut
with a 60 s limit is safe. A worker that hangs while it takes the message in
is given at most 8 s past that, then the call answers 504 `worker_timeout`; the
message was not taken. A turn still running then answers
`"status": "timeout"` with a `"token": "w1.…"`. Send that token back until the
status is something else:

```sh
curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -X POST http://192.168.1.29:4567/api/sessions/<session_id>/wait -d '{"token": "w1.…"}'
```

That is the whole protocol: one string to carry and no order to get wrong. A
token is for its own session only (400 `invalid_wait` for another's); the id
in the URL can be a prefix of it.

## The answers

`status` is one of:

- `done`: `text` is the reply.
- `waiting_for_answer`: the turn asks something. `question` has its `id`,
  `question` and `options`.
- `no_reply`: the turn ended without a reply. `outcome` says how (`failed`,
  `canceled`, `exhausted`, …).
- `timeout`: still running. Wait with the `token`.
- `error`, `stopped`, `worker_gone`: the session's worker failed or went away.

## Answering a question

```sh
curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -X POST http://192.168.1.29:4567/api/sessions/<session_id>/answer \
  -d '{"id": "<question id>", "selected": ["Yes"], "wait": 30}'
# {"status": "answered", "session_id": "…", "id": "…", "reply": {"status": "done", "text": "…"}}
```

With `wait`, the answer also waits for what comes next. `reply` holds the same
fields as an ask's answer, with a `token` while the turn is still running. If
someone answered the question first, you get `"status": "not_pending"` and
`reply` holds what came after their answer.

The answer goes in before the wait starts, so a wait that fails afterwards
(chi web stopping, the session deleted meanwhile) still answers 200 with your
`status`, and a `wait_error` (`error`: `server_stopping`, `not_found` or
`wait_failed`, and a `detail`) in place of `reply`. Don't answer again (that
would be 409): ask or wait on the session instead.

Ask waits also return 409 `busy` / `waiting` / `continuing` / `owned_by_tui`, or 503
`server_stopping` (ask again).

## An agent over HTTP

An agent (Claude Code, Codex, a script acting on its own) should drive chi
with `chi send --wait` and `chi answer` first, and `chi --remote NAME` for
another machine's chi web ([chi as a sub-agent](sub-agent.md)): they name
the sender for it. An MCP host can add chi as an MCP server instead
([chi as an MCP server](mcp-server.md): `chi mcp serve`, or `POST /api/mcp`
on chi web), which names it too. An agent that calls these routes itself must name itself
the same way:

- `"client_id": "agent:NAME"` on every ask (and on `POST /api/sessions`), NAME
  lowercase letters, digits, `-` and `_`: its turns are labelled "agent NAME" and
  it is a driver or a visitor as `chi send`'s agents are ([driver and
  visitor](sub-agent.md#an-agents-messages-driver-and-visitor)); `POST
  /api/sessions` also takes `"driver": "agent:NAME"`;
- `"client_id": "cli:answer"` on every answer.

`"cli:send"` still works and is held the same way, but it is the owner's row: it
restarts a stopped session and runs `!` lines.

Then `guardrails.parent_answers` applies as it does to `chi send` and `chi
answer` ([Answers from a parent agent](guardrails.md#answers-from-a-parent-agent)):
a `/continue yes` is held to it (403 `parent_continue_refused`), a
`/parent-answers` that loosens it is refused (403 `parent_answers_refused`),
and the worker checks an answer's option (403 `parent_answer_refused`).
Without a `client_id`, the ask and the answer are the owner's (`web:unnamed`)
and none of this holds: the token can do anything you can. It is a
convention for an honest agent, not a barrier, so tell your agent to send it.

## A new session

`POST /api/sessions {"prompt": "…", "dir": "/Users/me/projects/app"}` starts a
session. Its 201 carries a `token`: `POST /api/sessions/<id>/wait {"token": …}`
answers the first turn.

## A new session in one call

Send any of `reply_for`, `timeout` or `request_id` with the create and its 201
is the first message's answer, as an ask gives it:

```sh
curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -X POST http://192.168.1.29:4567/api/sessions \
  -d '{"prompt": "plan my day", "reply_for": "voice", "request_id": "20261128093012345"}'
# {"status": "done", "session_id": "…", "text": "…", "created": true, "request_id": "…", …}
```

- The body takes the ask's fields (`prompt`, `timeout`, `client_id`,
  `request_id`, `reply_for`) and the create's (`dir`, `model`, `toolkit`, …).
  `idle` and `continues` don't go with them (400 `invalid_ask`).
- `dir` is optional: without it the session starts in
  [`web.ask_dir`](configuration.md#all-settings) when that is set, else in the
  folder chi web starts in. A `web.ask_dir` that isn't a folder is 400
  `invalid_dir`, nothing started.
- The answer is the ask's (`status`, `text`, a `token` while it runs, …) with
  `session_id`, `created` (`true`: this call started it), `model_warning` and
  `parent_answers_warning`. A refusal after the session started (504
  `worker_timeout`, 503 `server_stopping`) keeps its code and also carries
  `session_id` and `created`.
- With a `request_id` a retry lands on the same session: the session's id
  comes from the key, so the same create again starts nothing (`created:
  false`) and answers the first one's turn. Use a new key for each message.
- A create without those fields answers as it always did (the session's
  summary, `first_turn_id` and a `token`).
- An older chi web ignores the fields: its 201 is the summary, with no `text`
  (its `status` is the session's, `idle` or `running`). Check that `features`
  lists `"ask_create"`.

## Your last session

`POST /api/sessions/last/ask` (the ask's body) continues the session you last
asked from a thin client:

- What counts: your own asks (`client_id` left out, or yours) that were
  answered, and your one-call creates. An agent's asks (`agent:NAME`), `chi
  send`'s and a refused ask don't move it; the MCP server's don't either.
- A continued session's message goes to the newest link, as any ask does.
- When that session is gone, or archived with nothing continuing it, `last`
  is your most recently updated session that isn't archived, a delegate, a
  `chi scratch` one, one an agent drives (`driver`) or a test run. None: 404
  `not_found`.
- Wait on a `token` with the answer's `session_id`, not `last`
  (`…/last/wait` is 404): `last` may move meanwhile.
- A participant's token can't use it (404).

## Pick from recent

`GET /api/sessions/summaries?limit=30&tests=0&delegates=0` lists your recent
sessions, newest first, as `chi sessions list` has them: each row's `desc` (its
folder's name · its title, or its first message), `short_id`, `id` and
`updated_at`.
`delegates=0` leaves out delegates and `chi scratch` sessions; `tests=0` test
runs. Ask one with `POST /api/sessions/<id or short_id>/ask`.

## iOS Shortcut recipe

One Shortcut with a menu: a new session, your last one, or one picked from
your recent ones. `<chi>` is your chi web's address (`https://…` through
[Tailscale Serve](configuration.md#tailscale-serve-your-tailnet)), and every
**Get Contents of URL** has method POST (GET for the list), the header
`Authorization: Bearer <token>` and a JSON body. Set
[`web.ask_dir`](configuration.md#all-settings) so New needs no folder (or add
`dir` to its body).

1. **Choose from Menu** with New, Last and Pick.
2. In each: **Dictate Text**, then **Format Date** (Current Date, custom
   format `yyyyMMddHHmmssSSS`) and **Set Variable** `key` to it.
   - New: **Get Contents of URL** `<chi>/api/sessions` with `prompt` = the
     dictated text, `reply_for` = `voice`, `request_id` = `key`.
   - Last: the same body to `<chi>/api/sessions/last/ask`.
   - Pick: **Get Contents of URL** (GET)
     `<chi>/api/sessions/summaries?limit=30&tests=0&delegates=0`, then
     **Repeat with Each** row: **Text** `desc · short_id` (the row's values);
     **Choose from List** over the texts; **Split Text** the choice by ` · `
     and **Get Item from List** (Last Item: `desc` has a ` · ` of its own):
     that is the session's short id.
     Then the same body to `<chi>/api/sessions/<short id>/ask`.
   **Set Variable** `answer` to the result.
3. After the menu: **If** `answer`'s `error` is `worker_timeout` or
   `server_stopping`, send the same request once more with the same `key` (it
   answers the first one's turn, nothing sent twice) and set `answer` again.
   Any other `error`: **Speak Text** its `detail` and stop.
4. **Repeat** 10 times: **If** `answer`'s `status` is `timeout`, **Get Contents
   of URL** `<chi>/api/sessions/<answer's session_id>/wait` with `token` = the
   answer's `token`, and set `answer` to it.
5. **Get Dictionary Value** `text`, then **Speak Text**. With `needs` =
   `detail` the text says to open chi on a full screen: an approval waits.

Judge success by `text` (and `created` for New), not by `status`: an older chi
web's create answers a `status` of its own. Shortcuts can't catch a **Get
Contents of URL** that fails outright (no connection): the shortcut stops
there, so the `request_id` retry covers only an answer with an `error`; run
the shortcut again with a new message. This recipe has not been checked on a
device step by step.

For running chi from another agent instead (`chi send --wait`, `chi answer`),
see [chi as a sub-agent](sub-agent.md). The routes in full are in
[architecture.md](architecture.md) (chi web's routes for the session
commands).
