# The Visor protocol

Two channels on one endpoint (`http(s)://<address>`, port 7433 by default
on the server itself, or wherever a front puts it): a WebSocket at `/` for
login and the live stream, and a REST API under `/api` for everything
else. Both carry the same JSON envelopes (`Envelope`
in libraries/visor_protocol): `{"type": …}` plus the fields that type uses
on the socket; the same fields as request and response bodies over HTTP,
where the route names the type.

## Who gets in

The server has one listener (7433 by default), which tells a WebSocket
upgrade from a request by its first bytes: the live channel at `/`, the
REST side under `/api`. By default it listens on loopback only, so the
road in from the network is something on the same computer — a reverse
proxy, a tunnel — forwarding one address to it; opened to the network
(`reachableFromNetwork`, in the menu bar app's Settings or
`visor-server network on`), it listens on every interface, for a LAN, a
VPN or a tunnel to reach directly. It serves plain TCP, or TLS with a
PKCS#12 identity where the system can (the Mac); otherwise TLS is the
front's. The server does not listen at all without a password set.
With `sshEnabled` (the default; `visor-server ssh on|off`) it also
serves the same on a socket file only its user can open,
`~/.visor/server.sock`: a client that comes through the computer's own
SSH as that user reaches it there (running `nc -U ~/.visor/server.sock`
per connection) and is already signed in.

A request is answered when `Authorization: Bearer` is the password from
the menu bar app, or a token from `hello` — or when it came on the
socket file, where no bearer is needed. Nothing else about the road is
trusted: no header names a user, and every device on the network signs
in the same way, with the password the connection code carries. The API
reads the same under a mount path a front forwards whole
(`/visor/api/sessions`).

A client connects in two steps: `GET /api/hello` (with whatever password
it has, possibly none) — 401 means "this device needs the password";
200 gives `host` (the Mac's name), `login` (whose it is) and `token` —
then the WebSocket, logged in with `token` (or `password`).

The WebSocket is an accessory. A client whose road does not carry
WebSockets (or whose host has no socket service) follows the server by
polling instead, with the same effect a little later: the list of
sessions (`GET /sessions?since=`) and each open session's state
(`GET /sessions/<id>/state?since=`), each held by the server until it
changes, as the transcript's sync always is; the rows before one from
`GET /sessions/<id>/earlier`. Only a terminal session's bytes need the
socket. Pushes are optional the same way: a device whose server sends
none notifies itself.

## Connection codes

Computers are added by hand, in one step. The menu bar app shows a
connection code — URL-safe base64 (no padding) of
`{"v":1,"name":…,"host":<address>,"password":…}` — as a string to
copy and as a QR code of `visor://connect?code=<code>`. A client takes
the code, the link, or an address typed by hand (`ConnectionCode` in
libraries/visor_protocol; the apps register the `visor` URL scheme).
The address is any `http(s)://` URL with a port and a mount path as the
server or its front gives it, or a bare name meaning HTTPS at the root
(`ServerAddress`): the socket is `ws(s)://` at that root, the REST side
under `/api`.

## REST (`https://<host>/api`, `Authorization: Bearer <password or token>`)

| method and path | body | answer |
|---|---|---|
| `GET /hello` | | `hello`: `host`, `login`, `token` — or 401 |
| `GET /sessions` | `since=<revision>` | the `welcome` envelope: `host`, `sessions`, `catalogs`, `revision`; with `since` at the current revision, held until the list changes (or for 25 s) |
| `GET /sessions/<id>/state` | `since=<revision>` | the session's `ephemeral` envelope with `revision`; held the same way while nothing ephemeral changed |
| `GET /sessions/<id>/earlier` | `before=<row id>` | the `earlier` envelope: the rows before that row, `more` |
| `POST /sessions/<id>/acknowledge` | | the user has read the session's notice |
| `POST /unlink` | `text`: a linked computer's host | forgets that link |
| `GET /sessions/<id>/commands` | — | `commands`: the slash commands the session's agent takes (`name`, `description`, `argumentHint`), as it last listed them, or as the same agent last did |
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
| `POST /restart` | `path` (a new build to install over this one, optional), `session` (one to carry on besides the busy ones) | `restart`: the sessions carried on; the server then relaunches |
| `POST /quit` | | `quit`; the server then ends its agents (what was running is written down as running, for the next start) and exits — how `visor-server stop` stops it |

A client asks `GET /sessions` once a minute as the backup for the socket:
the list is taken as a `sessions` broadcast would be, and an answer while
the socket is down reopens it at once.

401 when nothing lets the request in, 404 for an unknown session. The socket's `sessions`
broadcast follows every change, so other clients see it too.

## WebSocket (`wss://<host>/`)

Every envelope is `{"type": …}` plus the fields that type uses. The server
speaks first only in reply. The socket still accepts every command below
(the same handler serves both channels); the clients use it for `login`
and `subscribe` and stream the rest.

## Client → server

| type | fields | meaning |
|---|---|---|
| `login` | `token` (from `hello`) or `password`; neither on the socket file | Must be the first message. Neither accepted: `error` "Wrong password", then the socket closes. |
| `start` | `id`, `agent` (`claude`/`codex`/`openrouter`, or `shell` for a terminal session), `cwd`, `title`, `skipPermissions` | Create a session (the client picks the id; an empty title means the agent's name, numbered). Nothing is spawned until the first `send` — for a terminal, until a window takes it (`mode`). The client is subscribed to it. |
| `send` | `session`, `text` | A user turn. To a terminal session: the text typed into its shell and entered; nothing is written down. |
| `stop` | `session` | Kill the agent's process; the transcript stays and the next `send` resumes the agent's own session. |
| `subscribe` | `session` | Replay the transcript, then stream. |
| `permissions` | `session`, `skipPermissions` | Switch the session between auto (no prompts) and manual. Codex applies it next turn; Claude's process restarts (resumed by id) once the current turn ends. `sessions` follows. |
| `settings` | `session`, `model`, `effort` | Change the model and/or effort (nil keeps the current one). Codex applies it next turn; Claude restarts (resumed by id) once idle. `sessions` follows. |
| `approve` | `session`, `id`, `allow` | Answer a pending permission request (manual mode). |
| `archive` | `session` | End the agent gracefully (stdin closed, then terminated), keep the transcript and the agent's own session id on disk; the session lists as archived with its `resumeCommand`. |
| `unarchive` | `session` | Bring it back; the next `send` resumes the agent's own session with the same agent, directory and permission mode. A `send` to an archived session unarchives it too. |
| `end` | `session` | Stop and forget the session (archived or not). A terminal session's shell ends with it. |
| `mode` | `session`, `mode: "tui"`, `cols`, `rows` | Take a terminal session for this client's window: its shell is drawn at this size, for this client only, from now on — started if it is not running, kept if another window had it (that window is sent nothing more). The taker is sent a replay (`tty` with `cols` and `rows` set). Ignored for a chat session. `sessions` follows, with `mode` naming the client and size. |
| `input` | `session`, `data` (base64) | Keystrokes, from the client the terminal is drawn for (from any other, ignored). With the shell exited, a key starts a new one. |
| `resize` | `session`, `cols`, `rows` | The window that has the terminal changed size. |
| `ping` | | The client's heartbeat, every 16 s once logged in. Answered at once with `pong`. A client that hears nothing — the `pong` or anything else — within 8 s takes the socket as dropped and reconnects (after 2, 4, 8, 16 s, then every 30). A server from before 0.18 answers `error` "Unknown message ping", which a client takes as an answer too. An envelope, not a WebSocket ping frame: a browser cannot send those. |

## Server → client

| type | fields | meaning |
|---|---|---|
| `welcome` | `host`, `sessions`, `catalogs` | Login accepted. `catalogs`: each provider's models (`id`, `title`, `subtitle`, `efforts`, `defaultEffort`) and default — Claude's aliases, Codex's from `~/.codex/models_cache.json` + `config.toml`, OpenRouter's every tool-calling model from the CLI's list, priced in `subtitle`, maker in `group`, `listed: false` for those outside the short list — and its `account`, once a session of it has said (below). |
| `account` | `agent`, `account` | An agent's account changed: its plan, or how near its limits it is. Replaces the `account` of that agent's catalog. |
| `error` | `message` | Rejected (before or after login). |
| `pong` | | The answer to `ping`, to that client only. |
| `sessions` | `sessions` | The session list changed (a start, an end, busy flipped). |
| `transcript` | `session`, `entries`, `streaming`, `activity`, `busy`, `error` | The whole state, on subscribe. |
| `delta` | `session`, `id`, `text` | More of the reply being written; `id` is the message's, which its first row on the record also has. |
| `entry` | `session`, `entry` | A finished entry, or a replacement for the entry with the same id (an assistant message grows as its tool calls arrive). An assistant entry clears `streaming`. |
| `activity` | `session`, `activity` | What the agent is doing ("Bash: ls"), or null. |
| `busy` | `session`, `busy` | The turn started / ended. |
| `approval` | `session`, `approval` | A tool call is waiting for Allow/Deny (`id`, `tool`, `summary`), or null once answered. `SessionInfo.pendingApproval` mirrors it. |
| `failure` | `session`, `message` | Something went wrong; shown under the transcript until the next user turn. |
| `tty` | `session`, `data` (base64); `cols`, `rows` on a replay | What a terminal session's shell drew, to the window it is drawn for only. With `cols` set it is the whole screen so far (on taking the terminal, or subscribing again while holding it): the client starts its screen over. |

`SessionInfo`: `id`, `agent` (`claude`, `codex`, `openrouter`, `shell`), `mode` (absent, or — for a terminal session a window has — `{"kind":"tui","controller":<client>,"cols":…,"rows":…}`), `cwd`, `title` (given, or the agent's name numbered within the folder),
`busy`, `ended`, `skipPermissions`, `model`, `effort` (nil: the provider's / model's default; Claude fills `model` with what it actually runs), `archived`, `resumeCommand` (once the agent's own id is known: `cd <cwd> && claude --resume <id>` / `codex resume <id>`), `created`, `contextUsed`/`contextLimit` (the last request's tokens and the model's window), `usage` (what the session has used in all: `input` tokens, cache reads included, `cached`, `output`, and `cost` in dollars where the agent prices its turns — Claude Code at API prices even on a subscription, the openrouter CLI at OpenRouter's). Every session (live or archived) persists in `~/Library/Application Support/Visor/sessions.json` on the host, so a relaunch of the menu bar app brings them back idle, resumable by the agent's own id. `TranscriptEntry`: `id`, `role`
(`user`/`assistant`/`tool`), `text`, `activities`, `toolName` — the shape of
AgentUI's `TranscriptMessage`, which the client maps one to one. Tool
entries (`toolName: "tool_result"`) carry the first 400 characters of a
tool's output; the transcript view hides them, the assistant's
`activities` row is what the user sees.

`AgentAccount` (an agent's, per computer): `plan` in words ("Subscription", "ChatGPT Pro", "API key"), `subscription` (paid for by a plan, so a session's `cost` is what it would have cost), `limits`, `updated` (when an agent last said, seconds since 1970). Each limit: `name` ("5-hour", "Weekly", "Key limit", "Credits"), `used` (the share, 0–1), `resets` (seconds since 1970), and for an amount `left`, `total`, `unit` (`dollars` or `credits`). The server keeps the last of each agent's in `accounts.json` beside the sessions.

## Agents

- **Claude Code**: `claude -p --input-format stream-json --output-format
  stream-json --verbose --include-partial-messages --permission-mode
  bypassPermissions|acceptEdits [--resume <id>]`, one process per session,
  a `{"type":"user","message":{…}}` line per turn on stdin. `system/init`
  gives the session id; `stream_event` text deltas become `delta`;
  `tool_use` blocks become activity labels (`Name: first line of the
  input`); `result` ends the turn, with the process's running totals
  (`modelUsage`, `total_cost_usd`: the server adds up their differences,
  and the whole of a total that started over); `system/init`'s
  `apiKeySource` ("none": a subscription's login) is the plan, and
  `rate_limit_event`'s `unifiedWindows` the subscription's five-hour and
  weekly windows. The rows themselves come from Claude
  Code's session file, followed as it is written — as every agent's do
  from its own log (the transcript sync, in DEVELOPMENT.md).
- **OpenRouter**: the `openrouter` CLI (github.com/AttilaTheFun/open_router_cli)
  speaks Claude Code's stream-json protocol, so it is driven exactly as
  Claude is (`openrouter -p --input-format stream-json …`, `--resume`),
  with its own sessions under `~/.openrouter/sessions`, where it also keeps
  `<id>.jsonl`, a line per message appended as it lands, which Visor
  follows. Its key is its own (`openrouter auth login`); Visor never holds
  one. Its result carries the run's tokens and cost as Claude Code's does,
  and after each turn a `system/usage_limits` line gives the key's limit
  and the account's credits, as OpenRouter's `/key` and `/credits` say.
- **Codex**: `codex app-server`, one per session, a thread started or
  resumed by id and each message a turn. Its events give the thread id,
  the reply's words as they stream, and what is running; the rows come
  from the thread's rollout
  (`~/.codex/sessions/<y>/<m>/<d>/rollout-*-<thread>.jsonl`), followed as
  Codex writes it. `thread/tokenUsage/updated` gives the context (`last`)
  and the thread's tokens (`total`); `account/read` and
  `account/rateLimits/read`, asked at launch, and
  `account/rateLimits/updated` give the plan, its windows and credits.

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
Node must be on the PATH (as it already is for approvals).

Sessions on other computers are reachable once the computers are linked:
Visor Server's Settings → Linked computers takes the other computer's
connection code, keeps it in the keychain, and sends this computer's code to
the other's `POST /api/link` (`{"type":"link","text":<code>}`), so the link
goes both ways. `list_sessions` then lists each linked computer's sessions as
`<computer>/<id>`, the computer's name in lower case with dashes
(`logans-macbook-pro/1tzn…`). Asks about such a session are forwarded to that
computer's `POST /api/agent`, over HTTPS with its password, as the same
envelope with `client` set to the caller as `<computer>/<id>`, `title` its
name and `host` its computer; the answer is the `agent_result`. Messages from
another computer are prefixed `[Message from the Visor session "<title>"
(<computer>/<id>) on <computer name>, not from the user. …]`, and are
answered with `send_message` to that id.

A client connected to several computers links them all in one step (Link
These Computers, in the sidebar): it takes each server's code from
`GET /api/code` (`{"type":"code","text":<code>}`, for a client already let
in) and gives each server the others' codes through `POST /api/link`.
