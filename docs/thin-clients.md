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
chi there (`chi update`).

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
  owner's, as from the web composer). An agent sends `"cli:send"`: see
  [An agent over HTTP](#an-agent-over-http).

A question that is waiting for an answer refuses the ask with 409 `waiting` and
the `question`. Answer it first (below).

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

- `"client_id": "cli:send"` on every ask (and on `POST /api/sessions`);
- `"client_id": "cli:answer"` on every answer.

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

## iOS Shortcut recipe

1. **Dictate Text** (or **Ask for Input**).
2. **Get Contents of URL**: `https://<your chi web>/api/sessions/<id>/ask`,
   method POST, header `Authorization: Bearer <token>`, JSON body `prompt` =
   the dictated text.
3. **Repeat** while the answer's `status` is `timeout`: **Get Contents of URL**
   for `…/api/sessions/<session_id>/wait` with the JSON body `token` = the
   answer's `token`.
4. **Get Dictionary Value** `text`, then **Speak Text**.

For running chi from another agent instead (`chi send --wait`, `chi answer`),
see [chi as a sub-agent](sub-agent.md). The routes in full are in
[architecture.md](architecture.md) (chi web's routes for the session
commands).
