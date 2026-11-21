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
Visor.app's own server (the Mac's, in the app's process or as its server
agent) serves the socket file always, from its start, whether or not it
has a password yet and whatever `sshEnabled` says: Visor.app is its
client there, its window, menu and Settings alike (a client's address
`http+unix://<the socket file's path, percent-encoded>`, its channel
`ws+unix://…/`). The app shows its app key, `X-Visor-App-Key`, on every
request and the channel's upgrade: a key kept with the server's keychain
items, which macOS gives Visor's own processes alone. With `sshEnabled`
off, a connection there without the key is taken as one on the port
(the password, or a token, wanted).

A request is answered when `Authorization: Bearer` is the password from
the menu bar app, a token from `hello`, or the admin token (below) — or
when it came on the socket file, where no bearer is needed (while
`sshEnabled`, or with the app key) — or when the
server is set to
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

No agent's token is ever taken here, on any route (401, saying so),
even where the server asks nothing: not a native session's (below,
"Agents' tokens"), and not a runner's agent's (agent_protocol's
`Job.token`, docs/runners.md), which is only the driver's and
dispatcher's, on their gRPC port. Every REST route is the computer's
owner's: none is a session's own, so none takes a session's token. Nor is
a runner's own token (the one its `Claim` shows as `authorization:
Bearer`, minted with `POST /runners/tokens`) taken here: it too is only
the dispatcher's.

### The admin token

An opaque random secret (32 bytes, as 64 hex digits; not a JWT), a REST
credential beside the password and the socket file (`Authorization:
Bearer <admin token>`), and taken by the socket's `login` as the password
or the token too. Every REST route takes it: restarts, backups, approving
or ending any session, settings, runner tokens, the MCP and push proxy
settings. Only its SHA-256 is held, and there is one at a time: rotating
replaces it, and the old one stops working at once. It is compared in
constant time. Tools that need the admin side (a deploy, a restart, a
backup, the probes) read it from `$VISOR_ADMIN_TOKEN`, which Visor never
gives an agent (it is stripped from every agent's environment, and a
runner's agent's loses `SHIREWORKS_SESSION` too); a native session finds
it only where its owner's own shell sets it.

- **The menu bar app (and Visor on the Mac):** its hash is kept with the
  server's secrets (the keychain). The first one is made only when there
  is none, by `POST /admin-token` (`visor-server admin-token` over the
  socket file, or Settings › Create Admin Token…), and shown once. It is
  rotated only by presenting it: `POST /admin-token/rotate` with
  `Authorization: Bearer <current>` (`visor-server admin-token rotate`
  reads `$VISOR_ADMIN_TOKEN`), which answers the new one once. Without it,
  only the menu's Reset Admin Token… replaces it: no REST route, CLI or
  socket call does.
- **The command-line server (Linux, and a headless Mac):** it is given at
  launch, in `VISOR_ADMIN_TOKEN` or `--admin-token-file <file>|-` (`-`:
  standard input), never as an argument's value. Its hash is held in
  memory alone and never written. Launched without one, there is none, and
  the log says so: admin REST takes only the password and the socket file.
  A new one is a relaunch with it; `visor-server admin-token generate`
  prints a fresh one and keeps nothing.
- **`hello` tokens:** `GET /api/hello` answers a token for the socket's
  login that lasts as long as the server runs (it is a REST credential
  too). Those handed out to a request the admin token let in (or one of
  those tokens) go when the admin token is rotated or reset, so the old
  token's holder keeps no way in through them; those the password led to
  stay.
- **The command-line server's environment:** it unsets `VISOR_ADMIN_TOKEN`
  from its own environment as soon as it has read it, so nothing it starts
  (an agent's host, git, a tool) inherits it; a relaunch (an update) is
  given it back for its start alone. On Linux, `/proc/<server>/environ`
  still shows the environment it was started with, to its own user:
  `unsetenv` changes only the C library's copy (agent_protocol#13 is the
  same finding for the wrapper's `AGENT_TOKEN`). `--admin-token-file`
  keeps it out of the environment altogether.
- **The menu bar's Copy:** the token shown once can be copied; it is
  marked concealed (`org.nspasteboard.ConcealedType`) so clipboard
  managers that honour that don't keep it, but it is on the pasteboard,
  for any process of the user's to read, until something else is copied.
- **Its limit:** where agents run as the server's own user (every native
  session's agent shares Logan's uid), they can read the signing keys (in
  the secrets file on Linux), forging sessions' tokens; any other
  session's token file (mode 600 is the same user's); the server's
  environment through /proc on Linux; and they can reach the trusted
  socket file, which is the full admin REST side: `POST /api/admin-token`
  while there is none, key rotation, everything (but the reset of the
  admin token and an emergency rotation, which want Visor.app's app key
  from the keychain on a Mac). The admin token protects
  against containers, the network and other devices, not against a native
  agent of the same user; running the server as a user of its own is
  optional hardening.

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
`GET /sessions/<id>/earlier`. Pushes are optional the same way: a device
whose server sends none notifies itself. A server with no APNs key of its
own (on Linux, in a container) sends them through a push proxy that holds
one (`PUT /push-proxy`; Visor Runner's): each APNs request as it would
be, unsigned, at `<proxy>/apns/<APNs's host>/3/device/<token>` with the
server's token for the proxy in `X-Visor-Proxy`, and APNs's answer back.

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

## REST (`https://<host>/api`, `Authorization: Bearer <password, token or admin token>`)

| method and path | body | answer |
|---|---|---|
| `GET /health` | | `ok: true` and the server's `version`, without credentials: what a keep-alive asks (Shireworks' primary container), answered from the server's own loop, so a hung server doesn't answer. Nothing else is answered without them |
| `GET /hello` | | `hello`: `host`, `login`, `token`, the server's `version` (its build, "0.31 (9)"), its `id` and own `addresses` — or, from a server that stands alone, `standalone: true` and no addresses — `keepMessages: false` from a server that asks clients to keep its sessions' messages in memory only (its `clientsKeepMessages` setting, `visor-server keep-messages off`: a client then forgets what it kept of them on disk, writes nothing more, and asks `earlier` again for the rows it lets go of; absent, it may keep them); or 401. (A server of 0.49 or before also said `container: true` here, in `welcome` and in every `sessions` list, where it could start a session in a container of its own, and took `containerSize` with `start` and `contain`; a server of 0.50 or later never says it, and a client passes it over.) |
| `GET /sessions` | `since=<revision>` | the `welcome` envelope: `host`, `sessions`, `catalogs`, `revision`; with `since` at the current revision, held until the list changes (or for 25 s) |
| `GET /sessions/<id>/state` | `since=<revision>` | the session's `ephemeral` envelope with `revision`; held the same way while nothing ephemeral changed |
| `GET /sessions/<id>/transcript` | `since=<revision>`, `generation=<generation>`, `after=<row id>` | the session's rows as the client is to bring its own up to date: in its generation, a delta — the rows new, changed or moved since `since`, each with the row it follows (`after`), and the rows `removed` — at most 50 at a time, in order, `later: true` while more follow (the client asks again with the same `since` and `after` its last row, and takes the first page's `revision` once the last is in); otherwise the whole, `reset: true`, the latest 100 rows, with `follows`, the row the first of them follows ("" for the thread's first; a client that keeps that row keeps what is before it). Held, while the client has exactly what there is, until the rows move (or for a while). |
| `GET /sessions/<id>/earlier` | `before=<row id>` | the `earlier` envelope: the 50 rows before that row, `more` |
| `POST /sessions/<id>/acknowledge` | | the user has read the session's notice |
| `POST /ssh/keys` | `text`: an SSH public key line (this device's, or one scanned from another device's `visor://authorize?key=` QR code) | `ssh`; the key is in the user's `authorized_keys`, so that device comes in over SSH next |
| `GET /codes` | | `codes`: the server's connection codes — `qr` (the QR code's), and `http`, `https`, `ssh` (each leading with that kind of path; absent when it has none) |
| `POST /relay` | `report`: the client's `DirectoryReport` — its `client` id and `clientName`, its `clientVersion` and `clientPlatform`, and each server it is connected to with that server's `version` and sessions | `relay` with `relayed`: the messages waiting for the servers the report names |
| `GET /versions` | | the builds as this server knows them: its own (`server`: `id`, `name`, `version`), its `clients` (`name`, `platform`, `version`, when they `reported`), and the other `servers` (`id`, `name`, `version`, `reportedBy`, `reported`) as its clients reported them; agents get the same in `list_sessions` |
| `POST /relay/deliver` | `relayed`: one `RelayMessage` | `relay` with `receipt`: what became of it — the same however often it is carried; 409 for a message to another server |
| `POST /relay/receipt` | `receipt`: what became of a message from this server | `relay` |
| `GET /sessions/<id>/commands` | — | `commands`: the slash commands the session's agent takes (`name`, `description`, `argumentHint`), as it last listed them, or as the same agent last did |
| `GET /sessions/<id>/mail` | — | `mail`: the session's `inbox` and `outbox` (docs/agent-mail.md), oldest first, each a `MailMessage`: `id`, `from` and `to` (`RelayEndpoint`), `text`, `sent`, `state` (`waiting`, `delivered`, `read`, `failed`, `expired`), `changed`, `problem`?. The session's info carries `unreadMail` (how many wait unread) and `mailChanged` (when either box last changed), which tell a client to read them again. A server before 0.47 answers 404 |
| `POST /sessions` | `id` (client-chosen, optional), `agent`, `cwd`, `title`, `skipPermissions`, `resume` (the agent's own session id to continue; its past conversation is imported into the transcript). `container: true` (a session whose agent ran in a Linux container of its own on the server's computer) was removed in 0.50: a server of 0.50 or later answers it 410 with `error`, and makes nothing | `sessions` with the new one |
| `POST /jobs` | `agent` (claude, for now), `title`, `text` (its first prompt), `cwd`, `model`, `effort`, `runsOn` (the kind of runner that may take it: `native`, `container`; absent for any), `skipPermissions` (true: its agent acts without asking; absent or false: it asks, its prompts this server's) | `job` with `id`: its agent's id, queued on this server's agent_protocol dispatcher (docs/runners.md) for a runner to claim; the session appears once the runner's agent-wrapper dials the server; and `deprecated`, saying so. 404 when the server has no dispatcher, 400 with `error` for a job no runner can run. From 0.51. **Deprecated (19 Nov 2026):** agent jobs move to CI, as plain jobs on Nimbus's runners that never connect to Visor; removed once they run there. The first job queued in a server's run is logged as deprecated |
| `POST /sessions/{id}/send` | `text` | `sessions` with that one |
| `POST /sessions/<id>/contain` | `container` (true: into a container on its computer; false: out of it) | Removed in 0.50: a server of 0.50 or later answers 410 with `error`. (Before: `sessions` with that one, once its agent had moved.) |
| `GET /admin-token` | | `exists`: whether there is an admin token; `holding`: `kept` (with the secrets: the menu bar app's) or `givenAtLaunch` (the command-line server's, in memory). Never the token. |
| `POST /admin-token` | | 201 `token`: the first admin token, shown this once; only where it is `kept` and there is none (409 otherwise, saying why). |
| `POST /admin-token/rotate` | (the current admin token as the bearer) | `token`: its replacement, shown this once; the old one stops working at once. 403 when the bearer isn't the current one (the password and the socket file don't rotate it); 409 where it is given at launch. |
| `POST /admin-token/reset` | | `token`: a new admin token without the current one, shown this once; the old one stops working at once. Visor.app's menu's alone (Reset Admin Token…): only on the socket file with the app key (Who gets in), 403 otherwise; 409 where it is given at launch. |
| `GET /keys` | | `current`: the signing key's id (`kid`) agents' tokens are signed with now; `kids`: the keys that verify every token they signed (the current one, and those rotated out less than a day ago); `grace`: those rotated out a day to two days ago, which verify only a runner's Renew and Release (Agents' tokens, below); `problem`: why the kept keys can't be used, while they can't. Never the keys. |
| `POST /keys/rotate` | `dropPrevious`? | as `GET /keys`, with a new current key; the one before is kept a day, as long as the tokens it signed last, then a day more for a runner's Renew and Release alone. 503 while the kept keys can't be read, but for an emergency rotation, which replaces them. `dropPrevious: true` (an emergency) drops every other key at once, and every token signed with one: only on the command-line server (`visor-server keys rotate --drop-previous`); the Mac's server answers 403 but to Visor.app's own Emergency Key Rotation… (on the socket file with the app key). Native sessions' token files are re-minted at once; after an emergency, each runner's agent is restarted on a new job. Never the admin token. |
| `GET /settings` | | `settings`: the server as its owner's menu and Settings show it — `host`, `id`, `version`, `port`, `password`, `listening`, `lastError`?, `updateNotice`? (an update rolled back), `reachableAddress`?, `codes`? (as `GET /codes`), `clientCount`, `servesTLS`, `sshPaths`, `detachingSet`? (VISOR_DETACH_AGENT_HOST in its environment), `apnsKeyID`, `apnsTeamID`, `apnsConfigured`, `pushDevices`, `hasAdminToken`, and `settings`: `authentication` (`password` or `none`), `lan`, `vpn`, `sshEnabled`, `proxyEnabled`, `publicAddress`, `tlsIdentityPath`, `detachAgents`, `clientsKeepMessages`. Never the admin token, the APNs key or the TLS identity's password. From 0.62 (Visor.app's own server and visor-server alike). |
| `PUT /settings` | any of `password` (never empty), `authentication`, `lan`, `vpn`, `sshEnabled`, `proxyEnabled`, `publicAddress`, `tlsIdentityPath`, `tlsPassword` (the identity's, kept with the secrets), `detachAgents`, `clientsKeepMessages` | as `GET /settings`, once the fields given are set (one save; the server listens again where how it listens changed). 400 with `error`, and nothing changed, for an empty password or an `authentication` that is neither. |
| `GET /session-table` | | `text`: every session as a markdown table (the computer, each project and its folder, the session, its agent, the agent's own id that resumes it): the menu's Copy Session Table. |
| `GET /runners/tokens` | | **Deprecated (19 Nov 2026), as are the three below:** runner tokens go with the dispatcher once agent jobs run on Nimbus CI; each answer says so (`deprecated`), and the first mint or list in a server's run is logged. `required`: whether agent_protocol's `Claim` must show its runner's token (the `runnerTokensRequired` setting; off unless turned on), and `runners`: each `runner` name with a token, when it was `created`, and `own: true` for this server's own native runner's (held in memory, new each start). Never the tokens. |
| `POST /runners/tokens` | `runner`: the name its claims say (`container@mini`; no slash) | `runner`, `token` (shown this once: kept with the server's secrets), `created`, `replaced` (it had one, which no longer works). The runner shows it on `Claim` as `authorization: Bearer <token>`, with its `runner` field the same name (docs/runners.md). Deprecated (above). |
| `PUT /runners/tokens` | `required` (true or false) | as `GET /runners/tokens`: on, a `Claim` with no runner token is refused (UNAUTHENTICATED); off, it is let in and logged once per runner. A token that isn't a runner's, or is another runner's, is refused either way. Deprecated (above): `runnerTokensRequired` goes with them. |
| `DELETE /runners/tokens/<runner>` | | `runner`, `revoked: true`: its token no longer claims; 404 for a runner with none. Deprecated (above). |
| `GET /mcp` | | `endpoints`: the MCP servers passed on to the sessions' agents (see Proxied MCP servers), each `name`, `url`, `onByDefault` and `headers` (`name`, `secret`, and `value`, or for a secret one only `kept`) |
| `PUT /mcp` | `endpoints`: all of them, each `name`, `url`, `onByDefault`?, `headers` (`name`, `value`?, `secret`?) | as `GET /mcp`. A secret header's `value` is kept with the server's secrets; sent without one, the value kept stays. |
| `POST /push` | `deviceToken`, `platform` (`ios`, `macos`, …), `pushEnvironment` (`sandbox`, `production`), `pushTopic` (the app's bundle id), `pushMuted`? (the kinds it doesn't want, of `waiting`, `failed`, `goal`, `turn`; from 0.48) | `exists`: whether this server sends pushes. Kept per token, replacing an earlier registration; a silent state push for the widget goes whatever is muted. A server before 0.48 ignores `pushMuted` and sends every kind; a client before it sends none, and is sent every kind |
| `GET /push-proxy` | | `url`: where pushes go when this server has no APNs key of its own (empty for nowhere), and `kept`: whether its token for the proxy is kept |
| `PUT /push-proxy` | `url` (empty for none, which forgets the token too), `token`? | as `GET /push-proxy`. The token is kept with the server's secrets; sent without one, the token kept stays. |
| `POST /sessions/{id}/stop` `…/archive` `…/unarchive` | | same |
| `POST /sessions/{id}/restartAgent` | | same: a running agent (`agentState` `running`) is ended and a new one made and started on the same conversation (`stopping`, then `starting`, then `running`); a turn it was working on is carried on by a nudge that goes first. A stopped agent is started (what a client of 0.34 or before means by it) |
| `POST /sessions/{id}/stopAgent` `…/startAgent` | | same: a running agent is ended (`stopping`, then `stopped`) and kept so, through a launch of the server too, its turn in flight cut short and not carried on; what is sent meanwhile waits in `queued`. A stopped one is started (`starting`, then `running`, its process up at once) and what waited goes over. Anything else is left as it is |
| `POST /sessions/{id}/keepBranch` `…/continueBranch` | | same: when the conversation went on elsewhere (`otherBranch` in the session's info: the other branch's latest prompt), keep to the branch shown — the next message carries it on, resumed there with `--resume-session-at` — or continue the newest branch: the chat is read again from it (a new generation) and the agent is made again, resuming there |
| `POST /sessions/{id}/moveBack` | `resume`?, `cwd`? | same, once the session is back: a session moved to a runner (driven) made native again on this computer, its job let go. Its runner's agent, when its wrapper said protocol 2 or more (agent_protocol's `WrapperHello.protocol`), is asked to hand the session back (`DriverMessage.hand_back`): it ends, and returns its conversation (`AgentDriver.ReturnConversation`), which is put under this computer's key for the session's folder here, and the session resumes on it (`agentState` `stopping` meanwhile). An older wrapper is told to stop, as is one that hasn't begun returning within 2 minutes (or finished within 5 once it has), and then the session carries on from `resume`, its notice saying its turns on the runner (once its agent had begun there) weren't returned. `resume`, unless given, is the conversation known here: the runner's own when this computer has it, else the one it had before it moved, so `{}` does. `cwd`, unless given, is its folder as it is. 400 with `error` for a session that isn't driven, or whose conversation isn't known. From 0.61 |
| `POST /sessions/{id}/permissions` | `skipPermissions` | same |
| `POST /sessions/{id}/notifications` | `on` | same: the session's notifications on or off (its info's `notifications`), for every device. From 0.61 |
| `POST /sessions/{id}/settings` | `model`, `effort` | same |
| `POST /sessions/{id}/approve` | `id`, `allow`, `answers` | same |
| `POST /sessions/{id}/rename` | `title` | same |
| `DELETE /sessions/{id}` | | the remaining `sessions` |
| `GET /folders?path=` | | `path` (resolved, `~` expanded) and `folders` (subfolders, hidden ones skipped) — the project picker |
| `POST /folders` | `path` | creates the folder with its parents; answers like GET |
| `GET /resumable?agent=&cwd=` | | `resumable`: the agent's own sessions started in `cwd` (Claude's `~/.claude/projects`, Codex's `~/.codex/sessions`), newest first, `id`/`title` (first prompt)/`timestamp` |
| `GET /account?agent=` | | `account` (`agent`, `account`): the agent's account as it stands now — Codex asked afresh by a `codex app-server` of its own (a read begun in the last 30 s is shared), the others as their sessions last said. A change also goes out to every channel as `account`. Clients ask whenever the inspector shows a session |
| `POST /restart` | `path` (a new build to install over this one, optional), `session` (one to carry on besides the busy ones) | `restart`: the sessions carried on; the server then relaunches |
| `POST /quit` | | `quit`; the server then ends its agents (what was running is written down as running, for the next start) and exits — how `visor-server stop` stops it |
| `POST /migration/offer` | `session` | `migration` with `offer`: the session (`cwd` absolute), the agent's own id for its conversation (`resumeID`), the computer's name (`from`) and home folder, and the agent's own files for the conversation (`files`: `id`, `place` under the agent's folder — `{project}` for Claude's project folder — `size`, `packed`): its transcript, the folder beside it (Claude's subagents and long tool results, packed), and Claude's memory (id `memory`, packed, no place). Refused when a file is over 2 GiB or they come to over 4 GiB. (A server before 0.61 also listed the session's `projects`, which a server of 0.61 or later passes over.) |
| `POST /migration/read` | `migration` (the offer's `token`), `file` (`id`, and in `size` how much is wanted), `offset` | `migration` with `data` (base64, at most 4 MB) and `offset` (where the next piece starts) |
| `POST /migration/pack` | | Removed in 0.61: a server of 0.61 or later answers 410 with `error`. (Before: a project of the offer's packed for copying.) |
| `POST /migration/plan` | `offer` | `migration` with `plan`: its `id`, where the session runs here (`cwd`: a new, empty folder this server chooses — `<sessions>/<Agent>/<id>` where it keeps a folder for each session, else under its data folder's `Sessions` — never a path of the offer's), and `agentInstalled`. Refused for an offer that is not only the agent's own files for one conversation, is over the caps, or would not fit: the files' size and 1 GiB more must be free where the move keeps them as they come and under the agent's folder. (A server before 0.61 also gave a `step` per project.) |
| `POST /migration/write` | `migration` (the plan's `id`), `file`, `offset`, `data` | `migration` with the next `offset`; a piece must follow on from the last, be of a file the offer named, and end within the size it was offered as |
| `POST /migration/clone` | | Removed in 0.61: 410 with `error`. (Before: a project cloned where its step said.) |
| `POST /migration/unpack` | | Removed in 0.61: 410 with `error`. (Before: a project carried as an archive unpacked where its step said.) |
| `POST /migration/finish` | `migration` | `migration` with `session` (the new one's id) and `sessions`: the conversation's files put where the agent here keeps that conversation for the plan's folder, Claude's memory under that folder's project (when it has none), the folder made, new and empty, and the session started there resuming the same conversation, its model and effort kept (a Codex goal comes too, paused), with a notice of where it came from. (A client before 0.61 also sent the projects' `steps` and a `cwd` of its choosing, which are passed over.) |
| `POST /backups` | `sessionIDs` (else every session not archived), `path` (a folder of its own, else a new one under Visor's data folder's `backups`, by when it was made) | `backup`: its `path`, `created`, `from` (the computer's name), `size`, and its `sessions`, each with whether it was `kept` and its `outcome`. Each session's folder holds its offer (`offer.json`, as `POST /migration/offer` makes it) and the agent's own files for its conversation, to their last whole line: one half of a move, written to a folder. No project: since 0.61 a backup carries what a move carries, and a request's `projects` is passed over |
| `GET /backups` | | `backups`: those under the data folder's `backups`, newest first; one `imported` from a session archive says so |
| `POST /sessions/{id}/export` | `path` (a file, or a folder for it by its own name, on the server's computer; optional, never over a file) | `export` with `file` (`id` `archive`, `place` its name, `<title>-<date>.visorsession`, and `size`) and either `path` (where it was written) or `migration` (a token: read it as a move's file, `POST /migration/read` with `file.id` `archive`, for as long as an offer is kept). The session as a session archive (below). Refused, naming the file, its size, the cap and what would help, when its conversation is more than a move carries |
| `POST`, `GET`, `DELETE /sessions/{id}/super-compact` | | Super Compact (docs/super-compact.md): start a job condensing the session's conversation into HANDOFF.md (`202`; `409` while one runs: one at a time per server), read how it stands (`superCompact`: `phase`, `chunk` of `chunks`, `mergeStep` of `mergeSteps`, `error`, `warnings`, `handoff`), or cancel it (`DELETE` on a job done and waiting for its review discards its handoff: `discarded`). Once cut over, the job's `continuedAs` names the new session |
| `GET`, `PUT /sessions/{id}/super-compact/handoff` | | The done job's HANDOFF.md, for the person's review: `GET` answers `{"type":"handoff","text":…,"path":…}`; `PUT` `{"text":…}` saves their edits in its place (at most 8 MiB, else `413`) and answers the job, its check run again on the edit. `409` once the handoff has been started from or discarded, or while the job runs; `404` without a done job |
| `POST /sessions/{id}/super-compact/cutover` | | Super Compact's cut-over, once the job is done and its handoff reviewed (`409` before then, once it has been, after a discard, or while the session is mid-turn): a new session in a fresh folder (the server's folder for each session, as a move's), with the same agent, model, effort and permissions, titled "‹title› (continued)", HANDOFF.md and Claude's project memory copied in, and its first prompt to read HANDOFF.md in full; the old session archived (never deleted), its unread mail moved to the new one and its later mail forwarded there; `continuedAs` and `continuedFrom` set on the two. Answers `{"type":"cutover","session":‹new id›,"cwd":…,"message":‹what was copied and moved›,"sessions":[…]}` |
| `POST /import` | `path` (a session archive on the server's computer), or `file` (`size`, and its name in `place`) to upload one | with `path`: as `/import/finish`. With `file`: `import` with `migration`, the upload's token. Refused past 4 GiB (and 16 MiB for its offer and tar's own) or the room to keep it |
| `POST /import/write` | `migration`, `offset`, `data` (base64, a piece of at most 4 MB) | `import` with the next `offset`; a piece follows on from the last and ends within the size the upload began with |
| `POST /import/finish` | `migration` | `backup`: the archive, held to what a move takes and a restore applies, kept under the data folder's `backups` as a backup of its own (`imported`), its one session `Imported.`. Refused, nothing kept, when it holds anything but its one folder, an entry that leads out or a link that does, more than 16 entries, an offer a plan would refuse, a file the offer doesn't name (or one it names missing, not a plain file, or not the size it says), or an archive inside that a restore would refuse (its names, its 200,000 entries, its sizes). `POST /backups/restore` of it puts the session back on this computer, as a backup's, but is refused (`Not restored: … Remove it first, then restore it.`) while a session by its id is here; nothing is ever done to the computer it came from |
| `POST /backups/restore` | `path` (a backup's folder), `sessionIDs` (else all it kept) | `backup`, each session's `outcome` saying what was done, and `sessions`. The other half of a move, read from the folder, and held to what a move takes: the offer as a plan checks it (and the session's own, by its id), its archives checked and walked as a move's are. The session's folder (the server's own for it, where it keeps one; else where it was, under this home folder) is made empty when it is gone; a conversation file missing or shorter here is put back (a shorter one set aside as `.before-restore-<time>`, never removed), one as long or longer left as it is; Claude's memory is put back where the folder's project has none; a session gone from here is started again under its own id on the same conversation, told it was restored, and one still here is left as it is. The project archives a backup from before 0.61 holds (`project-<n>`) are left out, said in the server's log |

Moving a session (`SessionMigration` in the client): the user chooses only
the computer. The client asks the session's server for an offer and the
other for a plan, carries each file across a piece at a time (read from
the one, written to the other), then finishes. A move carries the agent's
own files for the conversation and nothing else (Logan, 2026-11-17): its
transcript, the folder the agent keeps beside it, and Claude's memory —
no project, working tree, archive of one or clone URL. The session runs
in a new, empty folder there; if its agent needs a repository, it clones
one itself. The session where it was is left as it was, for the user to
remove. A refusal at any step is a 400 with an `error` envelope saying
why.

Peers are only the user's own paired servers: a move goes between two
servers the same client is signed in to, and nothing else offers or plans
one. Claude Code runs a project's hooks by default, which is accepted for
that reason (and most sessions are moving into containers); with no
project files carried, a peer can't bring hooks along anyway.

The offer is still the other server's word, held to what a move takes
(`VisorServer+MigrationContainment.swift`): a plan (and a restore, and the
finish again) refuses an offer whose `resumeID` is not a UUID (as Claude
Code, Codex and the openrouter CLI make a conversation's id, so never
`memory` or `rollout`), whose file `id`s are not plain names (1 to 64
letters, digits, `-` and `_`, not starting with `-`; ids are unique), whose
session `cwd` is not a full path with nothing to resolve (no `.`, `..` or
empty part), or whose files are not the agent's own for that conversation:
each at a `place` where the agent keeps it (Claude's
`projects/{project}/<resumeID>.jsonl` and the folder `<resumeID>` beside
it, Codex's `sessions/<year>/<month>/<day>/rollout-<stamp>-<resumeID>.jsonl`
exactly, OpenRouter's `sessions/<resumeID>.json` or `.jsonl`), or Claude's
memory (`memory`, packed, no place). No path of the peer's is used: the
receiver makes every destination of the agent, the `resumeID` and the
session's new folder (`{project}` is that folder's project). `write` takes
a file `id` only as a plain name the offer named, kept in the move's own
folder.

Sizes (`VisorServer+MigrationSize.swift`): a file of a move (or a backup)
is at most 2 GiB and all of them at most 4 GiB — a long Claude transcript
runs to hundreds of megabytes, so the per-file cap is several times the
longest seen; a move has at most three files, so the total is two at the
cap — and a piece is
refused past its file's declared size. A plan is refused unless the
files' size and 1 GiB to spare are free where the move keeps them as they
come and under the agent's own folder (when the system says how much is
free). An archive among them (the conversation's folder, the memory) is
held to the same caps by what it unpacks to, and to 200,000 entries
(files, folders and links: each an inode, bytes or none): refused before
it is unpacked when its listing says more, and stopped while it unpacks
when it makes more than it declared or a cap.

The finish writes over nothing but the same conversation come back: where
a file of it is here already (for Codex, its thread's rollout anywhere
under `sessions`), the move goes on only when every log carried (`.jsonl`)
is here as the start of the one carried, the same agent's under the same
id gone on since; then a log is replaced and anything else (the
conversation's folder, OpenRouter's `.json`, a rollout of another day) set
aside as `<name>.before-move-<time>`. Otherwise the move is refused before
anything is made. Every archive (the conversation's folder, Claude's
memory, a backup's) is listed before anything is written and refused for
an entry at an absolute path, through `..` or outside the one folder it
holds, unpacked into a folder of its own inside where it goes
(`--no-same-owner --no-same-permissions`), walked — each folder opened to
its owner (`u+rwx`) before it is listed, and one that still can't be
listed refused — and refused for a link that leads outside it (an
absolute one always), a hard link to a file outside it or anything but
files, folders and links (a device, a fifo), and only then moved into
place; it must hold that folder alone, and never takes the place of one
there.

### Session archive v1

One session in one file, `<title>-<date>.visorsession` (the date UTC,
`YYYY-MM-DD`): what `POST /sessions/{id}/export` writes, `POST /import`
takes, and a CI agent job writes for its session. It is a tar, gzipped
(an importer takes it plain too, as tar finds it), holding one folder,
`session`, which is a backup's folder for the session:

```
session/offer.json              the session as POST /migration/offer makes it
session/conversation-0.jsonl    the transcript, to its last whole line
session/conversation-1.tgz      the folder beside it (Claude's subagents and
                                long tool results), a gzipped tar of that
                                folder by its own name (the conversation's id)
session/memory.tgz              Claude's memory for the project: a gzipped
                                tar of the folder `memory`
```

- `offer.json`: `token` (any), `from` (the computer's or the job's name),
  `session` (a `SessionInfo`: `id`, `agent`, `cwd` absolute, `title`,
  `model`, …), `resumeID` (the agent's own id for the conversation, a
  UUID), `home` (the home folder `cwd` was under) and `files`, each `id`,
  `place`, `size` and `packed`, as a move's offer has them. Claude's
  transcript's `place` is `projects/{project}/<resumeID>.jsonl`, its
  folder's `projects/{project}/<resumeID>`, the memory's empty (id
  `memory`); Codex's is its rollout under `~/.codex`, OpenRouter's
  `sessions/<resumeID>.json(l)`.
- Each file is named `<id>.<suffix>`: `tgz` when `packed`, else its
  place's extension (`data` when it has none). Its `size` is its size in
  the archive, exactly; nothing else is in the folder.
- Caps, a move's: 2 GiB a file, 4 GiB all of them, 200,000 entries in an
  archive inside, 16 entries in the archive itself. An export of a
  conversation past them is refused with what would help (carry on in a
  new session, whose transcript starts small).
- Gzip rather than zstd: the tar on a stock Mac (bsdtar 3.5 without
  libzstd) and Windows' read zstd only through a `zstd` program, which
  neither has; every tar Visor runs on reads and writes gzip.

A CI job writes one with `tar -czf <title>-<date>.visorsession -C <dir>
session`, its `session` folder as above.

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
| `login` | `token` (from `hello`, or the admin token) or `password` (or the admin token); neither on the socket file | Must be the first message. Neither accepted: `error` "Wrong password", then the socket closes. |
| `start` | `id`, `agent` (`claude`/`codex`/`openrouter`), `cwd`, `title`, `skipPermissions` | Create a session (the client picks the id; an empty title means the agent's name, numbered). Nothing is spawned until the first `send`. The client is subscribed to it. With `container: true` (a session in a container of its own, removed in 0.50), answered with `error` and nothing made. |
| `contain` | `session`, `container` | Removed in 0.50 (it moved a session's agent into a container of its own, or out of it): answered with `error`. |
| `fork` | `id`, `parent`, `origin` (`fork`/`branch`/`subagent`), `at`?, `text`?, `title`?, `subagent`? | A fork or branch of `parent` (docs/sub-sessions.md): a session of its own on the parent's folder, computer, agent, model and permissions, showing the parent's conversation (up to `at`, a row's id, for a branch). Its agent copies the conversation under an id of its own when it starts: with `text` at once (a fork's prompt), else with the first `send`. An empty title means "Fork of …" / "Branch of …". With the `subagent` origin, the conversation is that of `subagent`, one of the parent's subagents that has finished (Claude Code's: a copy of its transcript made a session of its own; Codex's: its own thread, resumed), titled with what the subagent was sent to do; it takes the subagent's place under the parent, and `text` is said to it at once. |
| `mcp` | `session`, `id`, `allow` | One of the proxied MCP servers (by its name, `id`) on (`allow`) or off for the session; `sessions` follows, and its agent's next look at its tools has it or not. |
| `side` | `session`, `id`, `text` | A side question about the session's conversation (`/btw`), answered on its `side` without going into the conversation, even while the agent works. Claude (its `side_question`) and Codex (a turn on an ephemeral copy of its thread); another agent's is answered with a `failure`. |
| `endSide` | `session` | The session's side questions go. |
| `send` | `session`, `text` | A user turn. While the agent works it waits in the session's queue (`queued`); handed to the agent, and until its log has the message (Codex can compact its context for minutes first), it is in the session's `delivered` while the agent works, which a client shows as the user's row until the transcript carries it (handed to an agent that went before its log had it, it never was taken: it leaves `delivered` at once, and a few seconds later the session's `notice` names it, to be sent again); when the turn ends (or `stop` ends it) the queue goes over a message at a time, never joined, each turn but the last stopped as soon as it starts (once the agent says it began: Claude's `system/init`, Codex's turn id — a stop sent before that is taken and ignored), so the agent answers the last. `/goal clear` sent during a turn goes ahead of the queue and stops the turn. |
| `stop` | `session` | Kill the agent's process; the transcript stays and the next `send` resumes the agent's own session. |
| `subscribe` | `session` | Replay the transcript, then stream. |
| `signIn` | `session`, `text` | The code the sign-in page showed (`<code>#<state>`), for the session's sign-in (`/login`). `send` of `/login` (with `claude auth login`'s options, `--console`, `--sso`; `/login cancel` to give up) to a Claude session starts one beside the agent, which takes no turn: the session's state (`ephemeral`) carries `signIn`, the page to sign in at, until it ends; signed in, the agent is made again on the new sign-in, and a notice says how it ended. Also `POST /sessions/{id}/signIn`. Visor lists `login` among a Claude session's commands. |
| `unsubscribe` | `session` | The client left the session: nothing more of it is sent until it subscribes again. A server before 0.33 answers `error` "Unknown message unsubscribe", which a client lets pass. |
| `permissions` | `session`, `skipPermissions` | Switch the session between auto-approving and manual. On the computer itself auto-approving is Claude Code's own auto mode and Codex in its workspace sandbox, never a bypass; in a container (the server's own, `inContainer`) a session always skips its prompts (Claude's bypassPermissions, Codex's full access), and an ask for manual is refused (from 0.50; before, auto was a bypass everywhere). Codex applies it next turn; Claude's process restarts (resumed by id) once the current turn ends. `sessions` follows. |
| `notifications` | `session`, `on` | Switch the session's notifications on or off, the session's own setting, kept with it in sessions.json and the same on every device. Off, its server sends it no push (a turn finished, failed or a goal achieved, an approval or a question waiting) but the widget's silent state push, which goes on, and clients make no notifications of their own for it; its list row, preview, unread mail and activity update as ever. `sessions` follows. From 0.61; a server before it answers `error` "Unknown message notifications". |
| `settings` | `session`, `model`, `effort` | Change the model and/or effort (nil keeps the current one). Codex applies it next turn; Claude restarts (resumed by id) once idle. `sessions` follows. |
| `approve` | `session`, `id`, `allow`, `answers` | Answer a pending permission request (manual mode), or the agent's questions (`answers`: answer by question; several to one joined with ", "; no answers is a refusal). |
| `archive` | `session` | End the agent gracefully (stdin closed, then terminated), keep the transcript and the agent's own session id on disk; the session lists as archived with its `resumeCommand`. |
| `unarchive` | `session` | Bring it back; the next `send` resumes the agent's own session with the same agent, directory and permission mode. A `send` to an archived session unarchives it too. |
| `end` | `session` | Stop and forget the session (archived or not). |
| `ping` | | The client's heartbeat, every 16 s once logged in. Answered at once with `pong`. A client that hears nothing — the `pong` or anything else — within 8 s takes the socket as dropped and reconnects (after 2, 4, 8, 16 s, then every 30). A server from before 0.18 answers `error` "Unknown message ping", which a client takes as an answer too. An envelope, not a WebSocket ping frame: a browser cannot send those. |

Servers from 0.18 to 0.31 also had terminal sessions (agent `shell`,
driven by `mode`, `input` and `resize`, drawn from `tty`). A client
leaves such a session out of the list it reads; a server now ignores
those three from an older client, and drops a terminal session it finds
in its store.

## Server → client

| type | fields | meaning |
|---|---|---|
| `welcome` | `host`, `sessions`, `catalogs` | Login accepted. `catalogs`: each provider's models (`id`, `title`, `subtitle`, `efforts`, `defaultEffort`) and default — Claude's aliases, Codex's from `~/.codex/models_cache.json` + `config.toml`, OpenRouter's every tool-calling model from the CLI's list, priced in `subtitle`, maker in `group`, `listed: false` for those outside the short list — and its `account`, once a session of it has said (below). |
| `account` | `agent`, `account` | An agent's account changed: its plan, or how near its limits it is. Replaces the `account` of that agent's catalog. |
| `error` | `message` | Rejected (before or after login). |
| `pong` | | The answer to `ping`, to that client only. |
| `sessions` | `sessions` | The session list changed (a start, an end, busy flipped). |
| `transcript` | `session`, `entries`, `streaming`, `activity`, `busy`, `error` | The whole state, on subscribe. |
| `turn` | `session`, `turn` | Where the session's turn stands now, whenever that changes (The turn's state, below). After 0.64.1; a server of 0.64.1 or before sent the reply's words instead (`delta`), which a client now passes over. |
| `ephemeral` | `session`, `turn`, `status`, `activity`, `busy`, `approval`, `queued`, `notice`, `signIn` | Everything about the session that is not the record, whole: on subscribing, after a notice, and as `GET /sessions/<id>/state` answers. `turn`: where its turn stands (absent from a server of 0.64.1 or before, which sent `streams`, the replies being written, instead). |
| `entry` | `session`, `entry` | A finished entry, or a replacement for the entry with the same id (an assistant message grows as its tool calls arrive). An assistant entry clears `streaming`. |
| `activity` | `session`, `activity` | What the agent is doing ("Bash: ls"), or null. |
| `busy` | `session`, `busy` | The turn started / ended. |
| `approval` | `session`, `approval` | A tool call is waiting for Allow/Deny (`id`, `tool`, `summary`), or the agent asks the user something (`tool` "AskUserQuestion", `questions`: `[{question, header, options: [{label, description}], multiSelect}]`), or null once answered. `SessionInfo.pendingApproval` mirrors it. |
| `failure` | `session`, `message` | Something went wrong; shown under the transcript until the next user turn. |

`SessionInfo`: `id`, `agent` (`claude`, `codex`, `openrouter`), `cwd`, `title` (given, or the agent's name numbered within the folder),
`busy`, `ended`, `skipPermissions`, `model`, `effort` (nil: the provider's / model's default; Claude fills `model` with what it actually runs), `archived`, `resumeCommand` (once the agent's own id is known: `cd <cwd> && claude --resume <id>` / `codex resume <id>`), `created`, `agentState` (where its agent is, and so what may be done with it: `starting` and `stopping`, nothing; `running`, `stopAgent` or `restartAgent`; `stopped`, `startAgent`. An archived session's is `stopped`; absent from a server of 0.34 or before, which offers `restartAgent` alone), `contextUsed`/`contextLimit` (the last request's tokens and the model's window), `usage` (what the session has used in all: `input` tokens, cache reads included, `cached`, `output`, and `cost` in dollars where the agent prices its turns — Claude Code at API prices even on a subscription, the openrouter CLI at OpenRouter's), `container` (from a server of 0.49 or before, when its agent ran in a Linux container of its own on the computer: `id`, `image` and `size`; never set by a server of 0.50 or later, which runs a session saved with one on the computer, and still read by clients), `inContainer` (true when its agent runs in a container the server didn't make for it, the server's own, shared by every session there: a co-tenant container), `parent` and `origin` (a fork, a branch or a subagent's conversation gone on with: the session it was made from, and how; a client lists it under that session), `side` (its side questions, each `id`, `question`, `answer` once answered or `failure`, and `asked`), `mcp` (the MCP servers its computer passes on to agents, each `name` and whether this session has it, `on`), `notifications` (false when its notifications are switched off; absent is on, as from a server before 0.61), `turnOrigin` (where its latest turn — the one running, or the last — came from: `user`, a client's `send`; `mail`, another session's message or the inbox's notice; `system`, the server's own nudge or a turn the agent began itself, a goal's or a loop's; absent before its first turn, and from a server before 0.61, which a client takes as `user`), `turn` (where its turn stands, as `turn` says it, for the line under a session at work or waiting; absent when idle, and from a server of 0.64.1 or before; never kept in sessions.json), `continuedAs` and `continuedFrom` (Super Compact's cut-over, from 0.64: on the archived session, the session that carries its work on, which its mail goes to from then on; on that session, the one it carries on; absent otherwise), `preview` and `updated` (the start of its latest message, and when it came: the thread's last regular message, the person's or the agent's, whichever is newer, whatever began its turn; never a tool row, the server's own nudge, nor mail — Turns of mail, below). Every session (live or archived) persists in `~/Library/Application Support/Visor/sessions.json` on the host, so a relaunch of the menu bar app brings them back idle, resumable by the agent's own id. `TranscriptEntry`: `id`, `role`
(`user`/`assistant`/`tool`), `text`, `activities`, `toolName` — the shape of
AgentUI's `TranscriptMessage`, which the client maps one to one. Tool
entries (`toolName: "tool_result"`) carry the first 400 characters of a
tool's output; the transcript view hides them, the assistant's
`activities` row is what the user sees.

`AgentAccount` (an agent's, per computer): `plan` in words ("Subscription", "ChatGPT Pro", "API key"), `subscription` (paid for by a plan, so a session's `cost` is what it would have cost), `limits`, `updated` (when an agent last said, seconds since 1970). Each limit: `name` ("5-hour", "Weekly", "Key limit", "Credits"), `used` (the share, 0–1), `resets` (seconds since 1970), and for an amount `left`, `total`, `unit` (`dollars` or `credits`). The server keeps the last of each agent's in `accounts.json` beside the sessions.

### The turn's state

A session's thread is its record (the rows, synced) and one line under
it, where its turn stands: the ephemeral state's `turn`, a `TurnState`,
`{phase, waits}`. The reply's words are not streamed: the reply appears
when its row syncs, like any row.

- **Phases:** `sending` (the person's message is on its way: the server
  has handed it to the agent, which hasn't begun its turn), `thinking`
  (the agent has it, and is thinking or hasn't said anything yet),
  `responding` (the reply's words are coming), `waiting` (on `waits`), and
  `idle`.
- **What a waiting turn waits on** (`waits`, each `kind`, `id`, `label`,
  `work`): `approval` or `question` (the person's Allow or answers;
  `label` the approval's summary), `signIn` (Claude's sign-in, once its
  page is known), `tool` (a call running, until its result comes, failed
  or not; `label` its name and the gist of its input, "Bash: bazel test
  //tests:linux"), `subagent` (an Agent or Task call, or one left in the
  background; `label` its description), `background` (a command run in
  the background, a monitor, left running when the turn ended; `label` its
  description). `work` (`shell`, `monitor`, `subagent`, `tool`) is what
  sort of work, for its symbol.
- **Precedence**, when several are true (TurnState+Precedence): an
  approval, a question or a sign-in; then a tool call or a subagent
  running; then the reply being written; then thinking; then sending;
  then, with no turn running, the work in the background; then idle. The
  background doesn't count while a turn runs: what the turn does then
  says more.
- **Where each comes from (Claude Code's stream-json):** `sending` from
  the server's `send` to the agent until `system/init` begins its turn;
  `thinking` from then, and from each `thinking` block, until something
  else; `responding` from the first `stream_event` text delta of a block
  until the next block begins (`content_block_start`: thinking, a tool's
  call, more words), a tool starts, or the turn ends; `waiting` on a tool
  from its `tool_use` to its `tool_result` (the call's `id`; a result with
  `is_error` ends it the same way); `idle` at `result`. The background is
  `system/background_tasks_changed`'s list (`local_bash`, `monitor`,
  `local_agent`), whole, whenever it changes. A subagent's own messages
  (`parent_tool_use_id`) are its, not the session's. Codex: `turn/start`'s
  answer or `turn/started` begins a turn, its reply's deltas are
  `responding`. A driven session (agent_protocol's `EphemeralState`): its
  `busy` going true begins the turn, `thinking` and `tools` as they are;
  it has no reply's words, so it is never `responding`, and no background.
- **What isn't known:** which of the background tasks the agent waits on
  (every one it lists wakes it when it ends, so every one counts); a
  background task of an agent a launch picked up past what its host kept
  of what it said (`background` unknown: none counted).
- **Pace:** a few changes a turn. The server tells a change as `turn` to
  the session's subscribers and to those polling `GET /state`, and with
  the sessions list (`SessionInfo.turn`, at most every 400 ms). The reply's
  pieces after the first do nothing at all.
- **The client** (SessionTranscript's `turnState`, TurnState+Words) says
  it in one line under the thread, and under the session's row in the
  list: "Sending…", "Thinking…", "Responding…", "Running Bash: bazel
  test …" (and "and N more"), "Waiting for a subagent: ‹description›",
  "Waiting for 2 subagents", "Waiting on ‹background work›", "Waiting for
  approval", "Waiting for your answer", "Waiting for sign-in". A message it
  has just put in the thread is "Sending…" until the server says the turn
  has moved on. From a server of 0.64.1 or before (no `turn`), it reads
  the state from `busy`, `status`, `approval`, `signIn` and the session's
  `background` by the same precedence, and passes `delta` over.

## Agents

- **Claude Code**: `claude -p --input-format stream-json --output-format
  stream-json --verbose --include-partial-messages --permission-mode
  bypassPermissions|acceptEdits [--resume <id>]`, one process per session,
  a `{"type":"user","message":{…}}` line per turn on stdin. `system/init`
  gives the session id and begins each turn; `stream_event` text deltas
  make the turn `responding` (their words are not kept: the row has them);
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
  `account/rateLimits/read`, asked at launch (and by `GET /account`), and
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

## Approvals and questions

Claude runs with `--permission-prompt-tool mcp__visor__approve`, a tool of
Visor's MCP server (`visor-agent-host mcp`; where there is no agent host,
the Node script `visor_mcp.js`), in either
mode: in manual mode (`--permission-mode acceptEdits`) every tool call that
is not an edit comes to it; auto-approving (`bypassPermissions`) only the
agent's questions do (AskUserQuestion, which Claude Code offers only where a
prompt can answer it; from 0.35). Each request becomes a WebSocket connection
from the shim to the app carrying
`{"type":"approval_request","token":<the session's agent token>,"session":…,"id":…,"text":<tool>,"prompt":<summary>}`,
with `questions` (the tool's own, as Claude Code gives them) for a question;
the app shows it to subscribers as `approval` and lists the session as
waiting; the client's `approve` is answered back to the shim as
`{"type":"approval_result","id":…,"busy":<allow>,"answers":{…}}`, which the
shim turns into Claude's allow/deny — for a question, allow with the tool's
input and `answers` (`{<question>: <answer>}`), which Claude takes as the
user's. Codex asks through its app server instead (`item/tool/requestUserInput`,
an experimental request: the server runs Codex with
`features.default_mode_request_user_input` and initializes with
`experimentalApi`); the server shows it as the same `approval` (id `codex-<n>`,
tool `request_user_input`) and answers Codex by its question ids. The
token is the session's own (below, "Agents' tokens"), taken only as that
session, so one session's agent can't ask or be answered as another's.
Codex's headless runs never ask; its manual mode is the workspace-write
sandbox.

A runner's agent (one run under agent_protocol's wrapper, whose driver
this server is) asks the same way through its wrapper: its
`mcp__visor__approve` comes as `WrapperMessage.approval` and is shown as
the same `approval`, and the client's `approve` goes back as
`DriverMessage.approval` (`allow`; a question's answers in
`updated_input_json`, the tool's input with `answers`; or `reason`). A
prompt it withdraws is cleared (`approval` with none). Its MCP server's
other tools are answered by the driver as its session's: Visor's own
tools, never the proxied MCP servers below, whatever the session's `mcp`
switches say (docs/runners.md).

A session moving back from a runner (`POST /sessions/{id}/moveBack`) is
handed back by its runner's agent when its wrapper takes it (protocol 2):
the turns it took there come back with it, its conversation's files
returned over the driver's `ReturnConversation` with the agent's own token
and held to a move's rules (Moving to another computer, above): only that
conversation's own places (`projects/<key>/<session>.jsonl`, and under
`projects/<key>/<session>/` and `projects/<key>/memory/`, its key and
session the header's), within a move's caps on each file, all of them and
how many, and the room free; staged, and put under this computer's key for
the session's folder only once whole. A file already here that is shorter
is set aside (`.before-handback-<time>`), never removed; one as long or
longer is left as it is. Refused, nothing is written, and the session
carries on from where it was before it moved (docs/runners.md).

### Agents' tokens

A native session's agent, and a runner's agent through its wrapper, each
hold a JWT of the server's: compact JWS, HS256 (HMAC-SHA256), verified
with the server's signing keys alone, no table of tokens kept.

- **Header:** `alg` (`HS256`; a token saying anything else, `none`
  included, is refused), `typ` (`JWT`), `kid` (the signing key's id).
- **Claims:** `iss` (the server's id), `aud` (`visor.session` for a native
  session's agent, `visor.runner-agent` for a runner's), `sub` (the
  session it acts as), `agent` (a runner's agent's id, which its wrapper's
  hello must name; absent from a session's), `scope` (an array:
  `messages` for the sessions' messages, `approvals` for its permission
  prompts, `mcp` for the passed-on MCP servers, and `job` for a runner's
  agent's own Connect, Conversation, Report and Renew), `iat`, `exp`,
  `jti`.
- **Verified:** its signature by `kid`; `iss` is this server; `aud` is the
  use's; `exp` hasn't passed; its `sub` session exists and isn't archived
  (or, for a runner's agent whose wrapper hasn't dialled in yet, its job
  is held); `agent` is the hello's; its `scope` allows the call. An
  envelope's own `client` (an `agent` ask) or `session` (an
  `approval_request`) must be the token's `sub`.
- **A session's:** lasts a day. The server writes it to
  `<Visor's data>/hosts/<name>/token` (the folder 700, the file 600),
  where `<name>` is the session's id when that is 1 to 64 letters,
  digits, `-` and `_` (every UUID), and otherwise `+` and 32 hex digits of
  its SHA-256: a client's id of `.`, `..`, empty or holding a `/` never
  names `hosts/` itself, anything outside it, or another session's folder.
  Nothing is written or removed unless its path is strictly inside
  `hosts/`; removing it removes the `token` file alone, then its folder
  only if nothing else is in it. A failed write leaves no staged
  `token.*.new` behind. It is re-minted every hour, and the agent is given the path as
  `VISOR_TOKEN_FILE`; `visor-agent-host mcp` (and the Node script on
  Windows) reads it on each call, taking `VISOR_TOKEN` (the token as the
  agent started) only where there is no file. Codex's `-c` overrides carry
  the file's path, never the token. Archiving a session removes its file;
  ending it does too.
- **A runner's agent's:** deprecated (19 Nov 2026) on the dispatcher's
  side alone: its `job` scope's `Report` and `Renew`, and its minting at a
  `Claim`, go once agent jobs run on Nimbus CI; the token on the driver's
  `Connect` and `Conversation` stays. `Job.token`, lasting an hour, minted when its
  job is queued and again when it is claimed, and sent fresh over its
  driver stream (`DriverMessage.token`) a sixth of its life before each
  ends (ten minutes of an hour); docs/runners.md. Past its `exp` it is
  taken only by the dispatcher, only on its runner's `Renew` and its
  `Released` report, and only for a day after (`expiredTokenGrace`), a
  stopgap until runners read agent_protocol's `RenewResponse.token`.
- **Signing keys:** random 32-byte keys, each named by a `kid`, kept with
  the server's secrets (the keychain on a Mac, the secrets file elsewhere)
  as one set with a current key. Rotating (`visor-server keys rotate`,
  `POST /keys/rotate`, the menu's Rotate Signing Keys) makes a new current
  key and keeps the one before for a day, the longest a token it signed
  lasts; then, for the grace a day more, it verifies only a runner's
  `Renew` and `Released` report (as an expired token is taken), so an
  ordinary rotation never ends a long job sooner than its token's own end
  would; then it is dropped. A key is never signed with once it isn't
  current. Keys are made only when the secrets hold none: kept keys that
  can't be read (the keychain refused) or decoded are never written over;
  nothing is minted, and the log says why, until they read again or an
  emergency rotation replaces them. An emergency rotation (`--drop-previous`, the
  menu's Emergency Key Rotation… on a Mac) drops every other key at once:
  every session's and runner's agent's token is refused from then on,
  native sessions are given new ones in their files, and runners' agents
  are restarted on new jobs. It never touches the admin token.
- **Agents from before:** an agent a build before this one left under its
  host keeps the token it was started with, taken only as its own session
  and only until that agent is gone: the shared token of 0.59 and earlier,
  and each session's random token of 0.60 and 0.61. Its host's record
  (`sessions.json`) says which it holds. A restarted agent holds a JWT.
- **What they don't separate:** every native agent runs as the same Unix
  user (Logan's), which can read the signing keys (on Linux, the secrets
  file), every other session's token file (600 is that same user's), the
  others' environments, and on Linux the server's own through
  `/proc/<server>/environ`; and which can reach the server's trusted
  socket file, the full admin REST side (`POST /api/admin-token` while
  there is none, key rotation, everything). So a native agent that sets
  out to act as another session, or as the admin, can. The tokens keep
  sessions apart by name, and containers, other devices and the network
  apart for real.
- **What isn't checked yet:** `jti` and `iat` are carried but not
  checked, and there is no denylist: a token is good until its `exp`
  whatever happened since, so a session archived and then unarchived takes
  its old tokens again until they end. `scope` is checked, but every
  token of an audience is granted every scope of it today, so scopes
  separate audiences and restrict nothing within one yet. A runner's
  agent's token is taken while its job is held even when its session isn't
  known to the server (`liveSession` answers nil: a job whose wrapper
  hasn't dialled in yet, or a queue without a server); a session that ends
  takes its jobs, and so its tokens, with it.

## Sessions messaging each other

Every Claude and Codex session the menu bar app starts gets the same MCP
server (Claude by `--mcp-config`, Codex by `-c mcp_servers.visor.*`). Claude's
MCP servers inherit its environment, which has `VISOR_PORT`, `VISOR_TOKEN_FILE`,
`VISOR_TOKEN` and `VISOR_SESSION`, so its `--mcp-config` carries only
`VISOR_APPROVALS` and the token never shows in `ps`; Codex gives a stdio MCP
server only an allowlist of its environment, so its `-c` overrides still carry
them, the token file's path in place of the token. Should Claude Code
stop passing its environment on, the MCP server (`visor-agent-host mcp`)
answers every request with a JSON-RPC error (-32002) naming the missing
variables and saying that Claude Code must pass the agent's environment to
its MCP servers, and writes the same to stderr. The server has
six tools: `list_sessions`, `send_message(session, server, text)`,
`read_messages(session, server, count)`, `message_status(message_id)`,
`read_inbox(unread_only, count)` and `read_outbox(count)`:
a session is always named with its computer's server id (the server also
takes the session id alone, for scripts from before 0.31).
Each call is a WebSocket connection from the script to the app carrying
`{"type":"agent","token":<the calling session's agent token>,"client":<calling session>,"mode":"sessions"|"send"|"read"|"status"|"inbox"|"outbox","session":<other session>,"server":<its server's id or name>,"messageID":…,"text":…,"rows":<count>,"version":"mail","id":…}`,
answered with `{"type":"agent_result","id":…,"text":…,"messageID":…}` or `…,"error":…}`.
`version` `"mail"` (since 0.47) says the agent's MCP server has `read_inbox`;
for `inbox`, `text` `"all"` asks for the read messages too.
A session is never offered itself, nor ended or archived ones.

Every session has an inbox and an outbox (docs/agent-mail.md), kept with the
session in the server's store for as long as the session is kept. A message
goes into the other session's inbox and a copy into the sender's outbox, by
one message id (the relay's, between servers); its state there is `waiting`,
`delivered`, `read`, `failed` or `expired`. The other agent is not handed the
message as a turn of the user's: it is told, in a turn whose whole input is
one line, how many messages are unread, never their words —
`[Visor: you have <n> unread message(s) in your inbox; read them with read_inbox]` —
queued while it works. One such notice waits at a time, and it counts what is
unread when its turn comes (none: it goes as nothing). `read_inbox` gives the
messages oldest first, each headed with who sent it and who it is for, by
name, id and computer:
`[Message from the Visor session "<title>" (<id>) on <computer> (server <server id>), to this session "<title>" (<id>) on <computer> — not from the user. To answer, use send_message with session <id> and server <server id>.]`;
those unread are marked read, and a sender on the same server sees it in its
outbox. A session whose agent may not have `read_inbox` (one an earlier
launch left running under its host, until it asks with `version` `"mail"` or
its agent is made again) is handed the message as before: a new turn of its
own, headed as above, queued while it works.
Node must be on the PATH (as it already is for approvals).

### Turns of mail

The server hands an agent every input itself, and tags the turn each starts
with where it came from (`turnOrigin` in the session's info): `user` for a
client's `send`, `mail` for the notice above, a message handed over headed
with its sender or beginning `@@from`, and `system` for its own nudges and a
turn the agent begins with nothing handed to it. A message waiting in the
queue keeps its origin (kept with the session), so the person's words sent
during a turn of mail start a turn of their own, `user`, once it ends.

A turn of mail tells the person nothing when it ends — no push and no
client notification that it finished, failed or met a goal — and neither
its prompt nor a reply that is itself a message to another session
(`@@to`) becomes the session's `preview`, which the thread shows as mail
rows, not messages. The agent's reply to the person in it does: the
preview is the thread's last regular message, the person's or the
agent's, and a turn's origin plays no part in it (from 0.64; 0.61 to 0.63
passed over the whole turn of mail, the reply too). An approval or a
question asked during it is told as any is, and its unread mail, activity
and state update as ever. The rows carry no origin: the preview passes
over a prompt in one of mail's forms (the notice, the header, `@@from`)
and an `@@to` reply, so it holds for rows read back from the store or the
agent's own file after a restart.

## Proxied MCP servers

A server can pass MCP servers of its own choosing on to its sessions'
agents (`GET`/`PUT /api/mcp`): each a
name, a Streamable HTTP address, and headers whose values may name the
session (`$SESSION_ID`, `$SESSION_TITLE`, and `$SESSION_REPOSITORY`: owner/name
of the GitHub repository its folder is a checkout of), a secret one kept with the
server's secrets. The agent never sees an address or a secret header:
Visor's MCP script lists each endpoint's tools as `<name>__<tool>` beside
its own (`"mode":"mcp_tools"`, answered with the list as JSON in `text`),
and passes a call on (`"mode":"mcp_call"`, `text` the JSON
`{"tool","arguments"}`, answered with the endpoint's result as JSON); the
server makes the request with the session's headers, under an MCP session
of its own for each session and endpoint, begun again if the endpoint
forgets it. The script looks again every 30 s and sends
`notifications/tools/list_changed` only when the tools really changed:
each one's name, description and schema held, as values, against what the
agent was last given (0.64 compared their JSON as text, whose objects' keys
come in no set order, and so told the agent on every look). `tools/list` is
answered at once from the last look: Visor's own tools always, and the
passed-on ones as last listed; a look the server doesn't answer within 15 s
(restarting, say) keeps them, and is tried again after 2 s, doubling up to
the 30 s. The server asks every endpoint at once, each within 5 s, and
lists the last good tools of one that fails or is slow (a call to it fails
with why), asking it again after 2 s, doubling up to a minute; only once it
has failed for 15 minutes are its tools left out (one `list_changed`), and
they are back when it answers (one more). `visor-agent-host mcp` holds no
connection between calls: each dials the server's port afresh with the
token file as it is then, so a server restarted or updated in place, or a
token re-minted, is simply reached again; a dial the server doesn't answer
is tried again for about 8 s (0.25 s, doubling) before a call says Visor is
not reachable, and a request is never sent twice. It reaches the server on
loopback TCP (`VISOR_PORT`), never its socket file, so the socket's place
(`~/.visor/server.sock`, or the Visor volume's `run/server.sock`) is no
matter to it. Each endpoint is
on for a session unless it, or its `onByDefault`, says otherwise (`mcp`).
They are the computer's native sessions' only: a runner's agent (a driven
session) gets none of them (`mcp_tools` answered `[]`, `mcp_call` refused),
whatever its switches say; its container gives it its own (docs/runners.md).

Sessions on other computers are reached through a client connected to
both: servers never talk to one another, and none learns another's address
or password. Every server, client and session has an id and a name. A
client tells each server it is connected to what it is connected to, every
20 seconds and whenever a server connects or a record changes
(`POST /api/relay` with a `DirectoryReport`: `client`, `clientName`, and
`servers`, each `DirectoryServer` an `id`, `name` and `sessions`, each
`DirectorySession` an `id`, `name`, `agent` and `busy`; archived sessions
left out). A server keeps the last report of each client by
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
headed the same way, its sender's computer being that server, and goes
into the inbox with the relay's id, as the sender's outbox has it.

When a message from another server is read (`read_inbox`), its server sends
a read receipt back the same way: a `RelayMessage` of `kind` `receipt`
(since 0.47), from the reader to the sender, `text` the id of the message
read. The sender's server marks that message `read` in the sender's outbox
and answers `sent`. A server sends receipts only to a server reported at
0.47 or later; a client from before 0.47 doesn't know the kind and leaves it
uncarried.

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
