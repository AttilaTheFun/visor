# The Visor protocol

Two channels on one HTTPS endpoint (the Mac's Tailscale Serve name, 443):
a WebSocket at `/` for login and the live stream, and a REST API under
`/api` for everything else. Both carry the same JSON envelopes (`Envelope`
in libraries/visor_protocol): `{"type": …}` plus the fields that type uses
on the socket; the same fields as request and response bodies over HTTP,
where the route names the type.

## Who gets in

The server listens on loopback only; the one road in from the network is
Tailscale Serve on 443, which proxies to it from the same Mac and adds
`Tailscale-User-Login` naming the tailnet user behind each request. A
request is answered when that user is the Mac's own (`tailscale status`
says whose the Mac is), or when `Authorization: Bearer` is the password
from the menu bar app, or a token from `hello`. So the user's own devices
need no password; another user's device on a shared tailnet, an older
client, or a tool on the Mac itself (loopback, no headers) uses the
password. The server does not listen at all without a password set.

A client connects in two steps: `GET /api/hello` (with whatever password
it has, possibly none) — 401 means "this device needs the password";
200 gives `host` (the Mac's name), `login` (whose it is) and `token` —
then the WebSocket, logged in with `token` (or `password`).

## Connection codes

Computers are added by hand, in one step. The menu bar app shows a
connection code — URL-safe base64 (no padding) of
`{"v":1,"name":…,"host":<tailnet name>,"password":…}` — as a string to
copy and as a QR code of `visor://connect?code=<code>`. A client takes
the code, the link, or a bare tailnet name (`ConnectionCode` in
libraries/visor_protocol; the apps register the `visor` URL scheme).

## REST (`https://<host>/api`, `Authorization: Bearer <password or token>`)

| method and path | body | answer |
|---|---|---|
| `GET /hello` | | `hello`: `host`, `login`, `token` — or 401 |
| `GET /sessions` | | the `welcome` envelope: `host`, `sessions`, `catalogs` |
| `POST /sessions` | `id` (client-chosen, optional), `agent`, `cwd`, `title`, `skipPermissions`, `resume` (the agent's own session id to continue; its past conversation is imported into the transcript) | `sessions` with the new one |
| `POST /sessions/{id}/send` | `text` | `sessions` with that one |
| `POST /sessions/{id}/stop` `…/archive` `…/unarchive` | | same |
| `POST /sessions/{id}/permissions` | `skipPermissions` | same |
| `POST /sessions/{id}/settings` | `model`, `effort` | same |
| `POST /sessions/{id}/approve` | `id`, `allow` | same |
| `POST /sessions/{id}/rename` | `title` | same |
| `DELETE /sessions/{id}` | | the remaining `sessions` |
| `GET /folders?path=` | | `path` (resolved, `~` expanded) and `folders` (subfolders, hidden ones skipped) — the project picker |
| `POST /folders` | `path` | creates the folder with its parents; answers like GET |
| `GET /resumable?agent=&cwd=` | | `resumable`: the agent's own sessions started in `cwd` (Claude's `~/.claude/projects`, Codex's `~/.codex/sessions`), newest first, `id`/`title` (first prompt)/`timestamp` |

401 when nothing lets the request in, 404 for an unknown session. The socket's `sessions`
broadcast follows every change, so other clients see it too. Behind the
Mac's Serve the API is at port 7434 (`/api` is stripped or not — both
accepted), the socket at 7433.

## WebSocket (`wss://<host>/`)

Every envelope is `{"type": …}` plus the fields that type uses. The server
speaks first only in reply. The socket still accepts every command below
(the same handler serves both channels); the clients use it for `login`
and `subscribe` and stream the rest.

## Client → server

| type | fields | meaning |
|---|---|---|
| `login` | `token` (from `hello`) or `password` | Must be the first message. Neither accepted: `error` "Wrong password", then the socket closes. |
| `start` | `id`, `agent` (`claude`/`codex`), `cwd`, `title`, `skipPermissions` | Create a session (the client picks the id; an empty title means the directory's name). Nothing is spawned until the first `send`. The client is subscribed to it. |
| `send` | `session`, `text` | A user turn. |
| `stop` | `session` | Kill the agent's process; the transcript stays and the next `send` resumes the agent's own session. |
| `subscribe` | `session` | Replay the transcript, then stream. |
| `permissions` | `session`, `skipPermissions` | Switch the session between auto (no prompts) and manual. Codex applies it next turn; Claude's process restarts (resumed by id) once the current turn ends. `sessions` follows. |
| `settings` | `session`, `model`, `effort` | Change the model and/or effort (nil keeps the current one). Codex applies it next turn; Claude restarts (resumed by id) once idle. `sessions` follows. |
| `approve` | `session`, `id`, `allow` | Answer a pending permission request (manual mode). |
| `archive` | `session` | End the agent gracefully (stdin closed, then terminated), keep the transcript and the agent's own session id on disk; the session lists as archived with its `resumeCommand`. |
| `unarchive` | `session` | Bring it back; the next `send` resumes the agent's own session with the same agent, directory and permission mode. A `send` to an archived session unarchives it too. |
| `end` | `session` | Stop and forget the session (archived or not). |

## Server → client

| type | fields | meaning |
|---|---|---|
| `welcome` | `host`, `sessions`, `catalogs` | Login accepted. `catalogs`: each provider's models (`id`, `title`, `subtitle`, `efforts`, `defaultEffort`) and default — Claude's aliases, Codex's from `~/.codex/models_cache.json` + `config.toml`, OpenRouter's every tool-calling model from the CLI's list, priced in `subtitle`, maker in `group`, `listed: false` for those outside the short list. |
| `error` | `message` | Rejected (before or after login). |
| `sessions` | `sessions` | The session list changed (a start, an end, busy flipped). |
| `transcript` | `session`, `entries`, `streaming`, `activity`, `busy`, `error` | The whole state, on subscribe. |
| `delta` | `session`, `id`, `text` | More of the reply being written; `id` is the message's, which its first row on the record also has. |
| `entry` | `session`, `entry` | A finished entry, or a replacement for the entry with the same id (an assistant message grows as its tool calls arrive). An assistant entry clears `streaming`. |
| `activity` | `session`, `activity` | What the agent is doing ("Bash: ls"), or null. |
| `busy` | `session`, `busy` | The turn started / ended. |
| `approval` | `session`, `approval` | A tool call is waiting for Allow/Deny (`id`, `tool`, `summary`), or null once answered. `SessionInfo.pendingApproval` mirrors it. |
| `failure` | `session`, `message` | Something went wrong; shown under the transcript until the next user turn. |

`SessionInfo`: `id`, `agent` (`claude`, `codex`, `openrouter`), `cwd`, `title` (given, or the agent's name numbered within the folder),
`busy`, `ended`, `skipPermissions`, `model`, `effort` (nil: the provider's / model's default; Claude fills `model` with what it actually runs), `archived`, `resumeCommand` (once the agent's own id is known: `cd <cwd> && claude --resume <id>` / `codex resume <id>`), `created`. Every session (live or archived) persists in `~/Library/Application Support/Visor/sessions.json` on the host, so a relaunch of the menu bar app brings them back idle, resumable by the agent's own id. `TranscriptEntry`: `id`, `role`
(`user`/`assistant`/`tool`), `text`, `activities`, `toolName` — the shape of
AgentUI's `TranscriptMessage`, which the client maps one to one. Tool
entries (`toolName: "tool_result"`) carry the first 400 characters of a
tool's output; the transcript view hides them, the assistant's
`activities` row is what the user sees.

## Agents

- **Claude Code**: `claude -p --input-format stream-json --output-format
  stream-json --verbose --include-partial-messages --permission-mode
  bypassPermissions|acceptEdits [--resume <id>]`, one process per session,
  a `{"type":"user","message":{…}}` line per turn on stdin. `system/init`
  gives the session id; `stream_event` text deltas become `delta`;
  `assistant` messages (one event per content block, same message id)
  become one growing `entry`; `tool_use` blocks become activity labels
  (`Name: first line of the input`); `user` tool results become tool
  entries; `result` ends the turn.
- **OpenRouter**: the `openrouter` CLI (github.com/AttilaTheFun/open_router_cli)
  speaks Claude Code's stream-json protocol, so it is driven exactly as
  Claude is (`openrouter -p --input-format stream-json …`, `--resume`),
  with its own sessions under `~/.openrouter/sessions`. Its key is its
  own (`openrouter auth login`); Visor never holds one.
- **Codex**: `codex exec --json --skip-git-repo-check -C <cwd>
  [--dangerously-bypass-approvals-and-sandbox | -s workspace-write] -` per
  turn (`codex exec resume <thread> …` after the first), the prompt on
  stdin. `thread.started` gives the thread id; `item.*` events with
  `agent_message`, `command_execution`, `file_change`, `web_search`,
  `mcp_tool_call` items become the turn's entry and activities;
  `turn.completed` / `turn.failed` end the turn.

## Approvals (manual mode)

In manual mode Claude runs with `--permission-mode acceptEdits` and
`--permission-prompt-tool mcp__visor__approve`, a tool of the MCP server the
menu bar app bundles (`visor_mcp.js`, run with node). Each permission request
becomes a WebSocket connection from the shim to the app carrying
`{"type":"approval_request","token":<agent token>,"session":…,"id":…,"text":<tool>,"prompt":<summary>}`;
the app shows it to subscribers as `approval` and lists the session as
waiting; the client's `approve` is answered back to the shim as
`{"type":"approval_result","id":…,"busy":<allow>}`, which the shim turns into
Claude's allow/deny. The token is generated per app launch and is not the
password. Codex's headless runs never ask; its manual mode is the
workspace-write sandbox.

## Sessions messaging each other

Every Claude and Codex session the menu bar app starts gets the same MCP
server (Claude by `--mcp-config`, Codex by `-c mcp_servers.visor.*`), with
three tools: `list_sessions`, `send_message(session, text)` and
`read_messages(session, count)`. Each call is a WebSocket connection from the
script to the app carrying
`{"type":"agent","token":<agent token>,"client":<calling session>,"mode":"sessions"|"send"|"read","session":<other session>,"text":…,"rows":<count>,"id":…}`,
answered with `{"type":"agent_result","id":…,"text":…}` or `…,"error":…}`.
A session is never offered itself, nor ended or archived ones. A message is
delivered as a new turn (queued while the other session works), prefixed
`[Message from the Visor session "<title>" (<id>), not from the user. …]`.
Only sessions on the same computer are reachable. Node must be on the PATH
(as it already is for approvals).
