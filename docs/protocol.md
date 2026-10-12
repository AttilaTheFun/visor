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
REST side under `/api`. Its network paths are each on or off in the
settings (the menu bar app's Settings; `visor-server lan|vpn|ssh on|off`,
`address <url>`): this computer itself, always (loopback); the LAN; a
VPN (a tailnet: the interfaces such networks make, or 100.64.0.0/10);
the computer's own SSH (the socket file, below); and a reverse proxy or
tunnel of your own, at the address you set, which clients are told
first. With the LAN or a VPN on it listens on every interface and admits
each connection by the address it arrived on. It serves plain TCP, or
TLS with a PKCS#12 identity where the system can (the Mac); otherwise
TLS is the front's. The server does not listen at all without a password
set, unless it is set to ask nothing.
With `sshEnabled` (the default; `visor-server ssh on|off`) it also
serves the same on a socket file only its user can open,
`~/.visor/server.sock`: a client that comes through the computer's own
SSH as that user reaches it there (running `nc -U ~/.visor/server.sock`
per connection) and is already signed in.

A request is answered when `Authorization: Bearer` is the password from
the menu bar app, or a token from `hello` — or when it came on the
socket file, where no bearer is needed — or when the server is set to
ask nothing (`authentication: none` in its settings; `visor-server auth
none`), the path being the proof: a LAN or VPN of one's own, SSH alone,
or a front that signs users in before requests reach Visor. On the
client, how it proves itself is apart from how it reaches the server: an
authenticator (none, the password, or a fork's own — a company's SSO
whose token goes in a header) gives the headers every request carries. Nothing else about the path is
trusted: no header names a user, and every device on the network signs
in the same way, with the password the connection code carries. The API
reads the same under a mount path a front forwards whole
(`/visor/api/sessions`).

A client connects in two steps: `GET /api/hello` (with whatever password
it has, possibly none) — 401 means "this device needs the password";
200 gives `host` (the Mac's name), `login` (whose it is) and `token` —
then the WebSocket, logged in with `token` (or `password`).

The WebSocket is an accessory. A client whose path does not carry
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
`{"v":1,"name":…,"host":<address>,"password":…,"id":…,"paths":[…],"auth":…}` (`paths`: the server's other network paths, `ssh://` ones among them; the SSH code puts one of those in `host`; `auth`, optional: how a client signs in — `password`, `none`, or a fork's authenticator — and a code without it leaves a computer already held signing in as it did) — as a string to
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
| `GET /hello` | | `hello`: `host`, `login`, `token`, the server's `version` (its build, "0.31 (9)"), its `id` and own `addresses` — or, from a server that stands alone, `standalone: true` and no addresses — or 401 |
| `GET /sessions` | `since=<revision>` | the `welcome` envelope: `host`, `sessions`, `catalogs`, `revision`; with `since` at the current revision, held until the list changes (or for 25 s) |
| `GET /sessions/<id>/state` | `since=<revision>` | the session's `ephemeral` envelope with `revision`; held the same way while nothing ephemeral changed |
| `GET /sessions/<id>/earlier` | `before=<row id>` | the `earlier` envelope: the rows before that row, `more` |
| `POST /sessions/<id>/acknowledge` | | the user has read the session's notice |
| `POST /ssh/keys` | `text`: an SSH public key line (this device's, or one scanned from another device's `visor://authorize?key=` QR code) | `ssh`; the key is in the user's `authorized_keys`, so that device comes in over SSH next |
| `GET /codes` | | `codes`: the server's connection codes — `qr` (the QR code's), and `http`, `https`, `ssh` (each leading with that kind of path; absent when it has none) |
| `POST /relay` | `report`: the client's `DirectoryReport` — its `client` id and `clientName`, its `clientVersion` and `clientPlatform`, and each server it is connected to with that server's `version` and sessions | `relay` with `relayed`: the messages waiting for the servers the report names |
| `GET /versions` | | the builds as this server knows them: its own (`server`: `id`, `name`, `version`), its `clients` (`name`, `platform`, `version`, when they `reported`), and the other `servers` (`id`, `name`, `version`, `reportedBy`, `reported`) as its clients reported them; agents get the same in `list_sessions` |
| `POST /relay/deliver` | `relayed`: one `RelayMessage` | `relay` with `receipt`: what became of it — the same however often it is carried; 409 for a message to another server |
| `POST /relay/receipt` | `receipt`: what became of a message from this server | `relay` |
| `GET /sessions/<id>/commands` | — | `commands`: the slash commands the session's agent takes (`name`, `description`, `argumentHint`), as it last listed them, or as the same agent last did |
| `POST /sessions` | `id` (client-chosen, optional), `agent`, `cwd`, `title`, `skipPermissions`, `resume` (the agent's own session id to continue; its past conversation is imported into the transcript) | `sessions` with the new one |
| `POST /sessions/{id}/send` | `text` | `sessions` with that one |
| `POST /sessions/{id}/stop` `…/archive` `…/unarchive` | | same |
| `POST /sessions/{id}/restartAgent` | | same: the session's agent is ended and a new one made on the same conversation; a turn it was working on is carried on by a nudge that goes first |
| `POST /sessions/{id}/keepBranch` `…/continueBranch` | | same: when the conversation went on elsewhere (`otherBranch` in the session's info: the other branch's latest prompt), keep to the branch shown — the next message carries it on, resumed there with `--resume-session-at` — or continue the newest branch: the chat is read again from it (a new generation) and the agent is made again, resuming there |
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
| `POST /migration/offer` | `session` | `migration` with `offer`: the session (`cwd` absolute), the agent's own id for its conversation (`resumeID`), the computer's name (`from`) and home folder, the conversation's `files` (`id`, `place` under the agent's folder — `{project}` for Claude's project folder — `size`, `packed`), and its `projects` (the session's own folder first, then the git repositories under the home folder its conversation names most: `remote`, `branch`, `commit`, `unshared`, `size`, `mentions`) |
| `POST /migration/read` | `migration` (the offer's `token`), `file` (`id`, and in `size` how much is wanted), `offset` | `migration` with `data` (base64, at most 4 MB) and `offset` (where the next piece starts) |
| `POST /migration/pack` | `migration`, `path` (a project of the offer's) | `migration` with `file`: the project packed (what git tracks and does not ignore, and its `.git`), to read like the others |
| `POST /migration/plan` | `offer` | `migration` with `plan`: its `id`, where the session runs here (`cwd`: the same place under this home folder), `agentInstalled`, and a `step` per project — `present`, `clone`, `copy` or `create`, with a `note` and whether it is `chosen` |
| `POST /migration/write` | `migration` (the plan's `id`), `file`, `offset`, `data` | `migration` with the next `offset`; a piece must follow on from the last |
| `POST /migration/clone` | `migration`, `steps` (the one) | `migration`, or the git error (the client then copies the project instead) |
| `POST /migration/unpack` | `migration`, `file`, `steps` (the one) | `migration`, once the project is unpacked where its step says |
| `POST /migration/finish` | `migration`, `steps` (those chosen), `cwd` (the folder the session runs in there, when the user chose one rather than the plan's: one of its projects, or another) | `migration` with `session` (the new one's id) and `sessions`: the conversation's files put where the agent here looks for them, the chosen folders made, and the session started resuming the same conversation, its model and effort kept (a Codex goal comes too, paused), with a notice of where it came from |

Moving a session (`SessionMigration` in the client): the client asks the
session's server for an offer and the other for a plan, the user chooses
which projects to bring, and the client carries each file across a piece
at a time (read from the one, written to the other), has projects cloned
(or packed, carried and unpacked when they cannot be), then finishes. The
session where it was is left as it was, for the user to remove. A refusal
at any step is a 400 with an `error` envelope saying why.

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
| `send` | `session`, `text` | A user turn. While the agent works it waits in the session's queue (`queued`); when the turn ends (or `stop` ends it) the queue goes over a message at a time, never joined, each turn but the last stopped as soon as it starts (once the agent says it began: Claude's `system/init`, Codex's turn id — a stop sent before that is taken and ignored), so the agent answers the last. `/goal clear` sent during a turn goes ahead of the queue and stops the turn. To a terminal session: the text typed into its shell and entered; nothing is written down. |
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

Each agent runs under a host of its own, `visor-agent-host` (on a Mac in
Visor Server's bundle under `Contents/Helpers`; beside the command-line
server elsewhere), so the server can restart, update or crash while it
works. The host starts the agent on pipes, keeps its latest 32 MB of
output numbered by line, and listens on a socket in the data folder's
`hosts/`; the server talks to it in frames (libraries/agent_host_wire:
the host's `hello`, the agent's lines, errors and exit, notices; the
server's `attach` from a line, input, end of input, signals, a memory
limit, `release`). Going for a restart, the server lets its hosts go and
writes down each socket and the next line it had not heard; the next
launch connects again and is sent what it missed, so a turn in flight
carries on. A plain quit still ends the agents. Each host also guards its
agent's memory: past the limit (half the computer's memory), the process
holding the most in the agent's tree — usually a command it ran — is
stopped, and the session is told; `memory` in a session's info is what
the agent and what it runs use now.

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
four tools: `list_sessions`, `send_message(session, server, text)`,
`read_messages(session, server, count)` and `message_status(message_id)`:
a session is always named with its computer's server id (the server also
takes the session id alone, for scripts from before 0.31).
Each call is a WebSocket connection from the script to the app carrying
`{"type":"agent","token":<agent token>,"client":<calling session>,"mode":"sessions"|"send"|"read"|"status","session":<other session>,"server":<its server's id or name>,"messageID":…,"text":…,"rows":<count>,"id":…}`,
answered with `{"type":"agent_result","id":…,"text":…,"messageID":…}` or `…,"error":…}`.
A session is never offered itself, nor ended or archived ones. A message is
delivered as a new turn of its own (queued while the other session works,
and never joined to other queued messages), headed with who sent it and who
it is for, each by name, id and computer:
`[Message from the Visor session "<title>" (<id>) on <computer> (server <server id>), to this session "<title>" (<id>) on <computer> — not from the user. To answer, use send_message with session <id> and server <server id>.]`.
Node must be on the PATH (as it already is for approvals).

Sessions on other computers are reached through a client connected to
both: servers never talk to one another, and none learns another's address
or password. Every server, client and session has an id and a name. A
client tells each server it is connected to what it is connected to, every
20 seconds and whenever a server connects or a record changes
(`POST /api/relay` with a `DirectoryReport`: `client`, `clientName`, and
`servers`, each `DirectoryServer` an `id`, `name` and `sessions`, each
`DirectorySession` an `id`, `name`, `agent` and `busy`; archived sessions
and terminals left out). A server keeps the last report of each client by
the client's id, for ten minutes; `list_sessions` gives this server's
sessions and then each other server's as last reported, with who reported
it and how long ago.

An ask about a session on another server (named by `server`, by id or by
name — two servers of one name are an error naming their ids — or found
by the session's id alone; a `<computer>/<id>` from before ids still
reads) goes into this server's relay outbox as a `RelayMessage`: `id`,
`kind` (`send` or `read`), `from` and `to` (`RelayEndpoint`: `server`,
`serverName`, `session`, `sessionName`), `text`, `rows`, `created`,
`expires` (a day on). The outbox is kept on disk. The server tells the
clients on a live channel to come for it (`{"type":"relay"}`), and answers
a client's next report with the messages for the servers it named. The
client carries each to its server (`POST /api/relay/deliver`), which takes
it once — it keeps what became of each message by id for two days, so two
clients racing to carry one, or one carrying it again, change nothing —
and answers with a `RelayReceipt`: `message`, `outcome` (`sent`, `queued`
while the agent works, `read` with the rows in `text`, `failed` with why),
which the client brings back (`POST /api/relay/receipt`). The first
receipt is kept; the agent that asked is answered with it (a send waits up
to 8 seconds, a read 20), or told the message waits, with its id for
`message_status` (`waiting`, `sent`, `queued`, `read`, `failed`, or
`expired` after a day uncarried). A message carried from another server is
headed the same way, its sender's computer being that server.

A client takes part with each server unless its user turned that off for
that computer (`AgentServerRecord.relay`; on by default, and a fork may
turn the default off with `RelayCourier.onByDefault`): one turned off is
told once that the client reports nothing, then nothing more, and is left
out of what the others are told.

A server can stand alone (its `standalone` setting, `visor-server
standalone on`, or `VISOR_STANDALONE=1`): one reached only through a
front, which must not be reached around it. Its `hello` says
`standalone: true` and gives no addresses. A client then reaches it only
at the address it was added at, learns no paths for it, and keeps it out
of the relay. An authenticator can say the same of every server it signs
in to (`isolated`), for a front that cannot change the server behind it.
