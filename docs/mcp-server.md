# chi as an MCP server

An MCP host (Claude Code, Codex, any client of the Model Context Protocol) can drive chi sessions as tools: list
them, send one a message and read its answer, answer the question it waits on. The sessions are ordinary ones: you
watch them in `chi web` or attach to them while the host talks to them.

This is chi as an MCP **server**. The `mcp` bundle is the other direction: chi as an MCP client, using other
servers' tools in its own sessions (see [Bundles](bundles.md)).

## Adding it to a host

```sh
claude mcp add chi -- chi mcp serve                      # this machine's sessions, stdio
claude mcp add chi-cloud -- chi --remote cloud mcp serve # another machine's, through its chi web
claude mcp add --transport http chi http://127.0.0.1:4567/api/mcp   # chi web, loopback
```

Codex, in its `config.toml`:

```toml
[mcp_servers.chi]
command = "chi"
args = ["mcp", "serve"]
```

- **stdio** (`chi mcp serve`): the host starts chi; JSON-RPC lines on its stdin and stdout. Under `chi --remote
  NAME` (see [Remote sessions](cli.md#remote-sessions)) the tools reach that machine's sessions through its chi web.
- **HTTP** (`POST /api/mcp` on chi web): on loopback with no `web.public_url`, no token, as every owner route of
  chi web. On the LAN, or a public URL chi web serves directly, send chi web's access token:
  `--header "Authorization: Bearer <token>"` (a request without it gets a 401 with `WWW-Authenticate: Bearer`).
  A participant's token is refused. `GET /api/info` lists `"mcp"` in its `features`; an older chi web answers 404.
- **Behind an auth proxy** (Okta, oauth2-proxy): not yet. The proxy stops an MCP host before chi sees it: use `chi
  --remote NAME mcp serve` there.

Both revisions of the protocol are served: the current one (2026-07-28, stateless: Claude Code) and the earlier
`initialize` one (2025-11-25, 2025-06-18, 2025-03-26: Codex). The answers are plain JSON, never a stream.

## The tools

| Tool | Arguments | What it does |
|---|---|---|
| `chi_sessions` | `dir?`, `live?`, `limit?` | the sessions, newest first: id, title, status, whether a question waits, project |
| `chi_ask` | `session`, `prompt` | sends the prompt as its own turn (queued behind a running one) and waits for the answer |
| `chi_wait` | `token` | keeps waiting for a turn that was still running |
| `chi_answer` | `session`, `question_id`, `option?` / `options?` / `text?` | answers the question a session waits on, then waits |

A call waits at most 25 seconds (a `chi_ask` 35 in all). Then:

- the turn still runs: `Still running. Call chi_wait with this token to keep waiting.` with a `token`;
- a question waits: the question, its numbered options and `Call chi_answer with session, question_id and option
  (or text).` An option is its label or its number (1-based); several only on a question that takes several.

Every result is text plus the same facts as `structuredContent` (`status`: `done`, `running`, `waiting_for_answer`,
`command`, or `error` with `detail`). A refusal, a bad argument and a turn that ended without a reply are results
with `isError: true` and chi's own words; only an unknown tool is a protocol error.

## Who the caller is

The host is an agent driving a session, as `chi send --wait` and `chi answer` are (see [chi as a
sub-agent](sub-agent.md)): its messages go in as `chi send`'s, its answers and a `/continue yes` as `chi answer`'s.
So `guardrails.parent_answers` holds it (see [Guardrails](guardrails.md#answers-from-a-parent-agent)): what it may
pick on an approval or a step-limit question, and whether it may continue a turn that ran out of iterations. The
page shows its turns with the "chi send" label.

`chi_ask` takes a message for the model, not a command: a line starting with `!` (a shell line) or with `/` (a
session command; `/continue …` is the one exception) is refused. That is narrower than `chi send` on purpose: a
host approves an MCP tool once, not each line.

## Not yet

Starting a session (`chi_new`), stopping, archiving or deleting one; OAuth (claude.ai and ChatGPT connectors, a chi
web behind an auth proxy); progress notifications and streamed answers; resources and prompts; images; a
participant's token. A second `chi_ask` while the first still runs queues another turn: nothing stops a model from
asking twice.
