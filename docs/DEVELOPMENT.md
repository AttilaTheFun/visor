# Developing Visor

How Visor is built, how it fits together, and how to work on it: the
setup, the architecture as built, the build/test/deploy loop, the probes,
and the gotchas. Read it whole once; keep it current as things change.

## 1. What this is

Visor is Visor.app, on iOS and macOS (Logan, 24 Nov 2026: there's no
separate "client" app). On the Mac, Visor's server runs in Visor.app's own
process, the menu bar app (0.72.1; Logan, 25 Nov 2026: "The background
process IS the menu-bar app, so that I can always tell when it's running,
and its windows are the clients."), which runs coding agents (Claude Code, Codex,
OpenRouter models) as sessions, natively or in the containers it manages,
whose files are only on the Visor, Sessions and Sources volumes (Visor
Disk Utility creates them and checks they're as they should be:
docs/containers.md). Visor on the iPhone, iPad and Mac (and on Android
and the web) reaches a Mac's server over whatever reaches the Mac, chats
with a session and watches it work. The agent doing this work can drive
its own development through Visor: you talk to an agent in Visor; the
agent edits, builds, tests, and redeploys the very server it is running
under.

The repos (github.com/AttilaTheFun):

| Repo | What |
| --- | --- |
| `visor` | This repo: server, protocol, client, UI, caches, Apple apps. Bazel module `visor`. |
| `agent_ui` | SwiftPM package: AgentUI (the chat: transcript, composer, footer), NavigationUI, InboxUI, MessagesUI. Pinned by version in third_party/swift_packages/Package.swift (a revision only on a branch, before its release). |
| `open_router_cli` | SwiftPM: OpenRouterKit (client, streaming, ORAgent loop, coding tools, sessions, config, Claude's stream-json) and the `openrouter` CLI, which Visor drives. |

Third-party: swift-nio-ssh 0.9 (SSH for the client and the server,
through libraries/visor_ssh; it parses OpenSSH key lines but writes none,
so `NIOSSHPublicKey+OpenSSH.swift` writes the kept host key from the
key's bytes, read through reflection — a line to offer upstream instead),
SQLite (the caches, through swift_sql: the system's on Apple's
systems, its vendored amalgamation 3.53.4 elsewhere, WebAssembly included; a
Swift package, by version in third_party/swift_packages like agent_ui),
rules_swift_package_manager (rspm) brings SwiftPM packages into Bazel as `@swiftpkg_<identity>` — the
identity keeps its dot: `@swiftpkg_agent_ui//:AgentUI`.

The client's gRPC link (from 0.64) is protos/visor/client/v1. Bazel
generates its Swift as it builds: `swift_proto_library`
(libraries/visor_client_proto) with tools/proto's compilers, the plugins
from the SwiftPM graph and protobuf's prebuilt protoc
(`--incompatible_enable_proto_toolchain_resolution`). SwiftPM builds a
copy that is kept in libraries/visor_client_proto/Sources. After a proto
changes, write it again with `bazel run //tools/proto:generate`; `--check`
fails when the copy differs from what the protos make.

## 2. Setting up a Mac

1. Xcode 27 with the iOS 27 runtime; `xcode-select` to it. Bazelisk
   (`brew install bazelisk`); Bazel version from `.bazelversion`.
2. Clone this repo; Bazel and SwiftPM fetch agent_ui and the third-party
   packages themselves. Clone open_router_cli beside it to build the CLI.
3. A network path from your devices to the Mac. The server has one
   listener, port 7433 (the WebSocket at `/`, the REST side under
   `/api`), and Settings → Network paths switches each path on, showing
   its address to copy: this Mac (always, `http://127.0.0.1:7433`), the
   LAN and a VPN (`http://<address>:7433` on each address of that kind;
   a connection is admitted by the address it arrived on), SSH (on by
   default: `ssh://<user>@<address>`, the Mac's Remote Login as you,
   already signed in, served on the server's socket file: `/Volumes/Visor/run/server.sock`
   on a Mac with the Visor volume, else `~/.visor/server.sock`), and a reverse
   proxy or tunnel of your own at the URL you set, told to clients
   first. None on: this Mac alone reaches the port. TLS: a
   PKCS#12 identity in Settings, or the front's. Every client, and every
   tool on the Mac (the probes), signs in with the password; the server
   trusts nothing about the path.
4. Agents, each configured on its own — Visor holds no keys: `claude`
   (Claude Code CLI, logged in), `codex` (`codex login`; Visor drives
   `codex app-server`), `openrouter` (build open_router_cli with
   `swift build -c release`, copy `.build/release/openrouter` to
   `~/.local/bin`, `openrouter auth login <key>`; it speaks Claude's
   stream-json so `ClaudeProcess(tool: "openrouter")` drives it), Node
   22+ for the probes.
5. Build and install the server: `tools/deploy_server.sh` needs a running
   server; the first time, `bazel build //applications/visor_menubar`,
   unzip the bundle from `bazel cquery --output=files`, sign it
   (`tools/sign_mac_app.sh`), copy it to `/Applications/Visor Server.app`,
   open it: Settings opens on its
   own and a password MUST be saved before it serves (a generated one is
   offered). Then the clients: `tools/deploy_clients.sh [iPhone UDID]`.
   Clients add a Mac with its connection code: the menu bar's "Copy
   Connection Code", or the QR code in its Settings scanned with a
   phone's camera (opens `visor://connect?code=…`).
   **Signing.** The bundle ids are constants at the top of each app's
   BUILD.bazel: change them to your own. Visor is one id on the iPhone and
   the Mac, `com.LoganShire.Visor`, in every build; which build it is, its
   Info.plist's `BuildVariant` says (tools/variant, AttilaTheFun/applications'
   docs/VARIANTS.md): Alpha by default, `--config=prod` a release's
   Production. Your Apple team id is not in
   the repository: put it in `.bazelrc.user` at the workspace root (not
   checked in), `common --repo_env=VISOR_TEAM_ID=<team>`; without it
   device builds use the placeholder `YOUR_TEAM_ID` (tools/signing). No
   team id, certificate or profile belongs in the repository. For a phone,
   Xcode must be signed into your Apple ID (Settings → Accounts); then,
   with the phone plugged in, `tools/mint_profile/mint_profile.sh
   <bundle id> <team id> <UDID>` makes the development certificate and
   the "iOS Team Provisioning Profile: <bundle id>" rules_apple looks for
   (`xcrun devicectl list devices` gives the UDID). A paid team's
   profiles last a year and list the team's registered devices; a free
   team's last 7 days: re-run it when installs start failing. After one install
   over USB the phone is paired, and `devicectl` reaches it over Wi-Fi on
   the same LAN when unplugged.
6. Xcode: `bazel run //:xcodeproj` generates Visor.xcodeproj
   (rules_xcodeproj); it is not committed.
7. Keeping the server up: Visor.app registers its own launchd agent,
   which starts the app at login and again after a crash (Start at Login,
   on by default: section 3, The server in the app).

## 3. Architecture, as built

**Server** (`libraries/visor_server`, `applications/visor_menubar`). One
type per file: `VisorServer.swift` is the class and its state, and what it
does is in `VisorServer+<Topic>.swift` (Access, Persistence, Listening,
REST, Messages, Agents, Broadcast, Lifecycle, Links, Commands, Push);
`SessionRecord.swift` likewise, with `+File`, `+Events`, `+Revisions`,
`+Marks`, `+Queue`. A REST route or a socket command is one small method
(`restHello`, `performSend`), named in the dispatch table of `route` or
`perform`.
`VisorServer` (@MainActor) holds `SessionRecord`s. Each record owns an
`AgentProcess` — driven on the main actor; what the agent says is read
and parsed off it (`PipedChild.swift`, `AsyncStream+Lines.swift`) and reaches the record as one
`AsyncStream` of `AgentEvent`s, in the order said. An agent is ended with
`stop()` (asked, then made to, not waited for) or `await end(within:)`;
one is never started on a session while the one before is still going
(`SessionRecord.held`), and quitting waits for all of them
(`applicationShouldTerminate` → `endAll`). Processes are made by an
`AgentHarness` (`AgentHarnesses.standard`:
`ClaudeHarness` → `ClaudeProcess` (`claude -p --input-format stream-json
--output-format stream-json --include-partial-messages`, one process per
session, `--resume`), `CodexHarness` → `CodexAppServerProcess` (`codex
app-server`, JSON-RPC over stdio, thread/start|resume, turn/start,
turn/interrupt), `OpenRouterHarness` → `ClaudeProcess(tool: "openrouter")`
(the openrouter CLI speaks the same stream-json; its sessions are
`~/.openrouter/sessions/<id>.json`, read by `SessionCatalog` for
resumable/transcript). Its catalog is every tool-calling model in the
CLI's `~/.openrouter/models.json` (priced subtitles, `group` = maker);
`listed` marks the suggestions — `OpenRouterHarness.coding`, a hand-kept copy
of the top ten at openrouter.ai/collections/programming (update it from
the page; the API's `category=programming` order does not match it) — the default (the CLI's config, else gpt-5-nano) is not a suggestion.
The model sheet, for a catalog with unlisted models, shows Current Model
(what the session runs), then Suggested, then an All Models sheet
grouped by maker with search. The server runs `openrouter models
--refresh` at launch when the file is a day old; Visor never calls
OpenRouter itself). Harnesses are injectable
(`VisorServer.harnesses`) so a different adapter layer can be swapped in.

The **record** is the transcript in memory (`entries`: a window of the
latest 100 rows when read in, and every row since; the latest 100 served
whole, changes 50 at a time) plus the ephemeral state. Every change bumps `revision`;
each row is stamped with the revision it last changed or moved at, and a
removed row is remembered (a tombstone) with the revision it went at.
Every agent's transcript is its own log, followed as it is written:
Claude Code's session JSONL, Codex's rollout
(`~/.codex/sessions/<y>/<m>/<d>/rollout-*-<thread>.jsonl`) and the openrouter
CLI's `~/.openrouter/sessions/<id>.jsonl` are each read into lines of Claude's
shape (`AgentLog.swift` and the parsers beside it) and go through the one indexer, cache and assembler.
Rows the agent processes report are not taken. What the user sends is no row
until the log writes it (the server remembers the words as sent; the
composer shows them, sending, until then), so rows are never renamed;
Codex's and OpenRouter's records get the row when it is handed over. Clients
sync over HTTP long-poll
`GET /api/sessions/<id>/transcript?since=<revision>&generation=<generation>`
(held ≤25 s, released on change) and are answered with a delta: the rows
new, changed or moved past `since`, each with the id of the row it follows
(`after`), and the ids `removed` since. The whole window, marked `reset`
(the client replaces its rows and cache), is sent only to a client of
another generation: a first sync, a server that started again (each run
starts at a random generation), a fork found in the log (a new branch,
with a notice to the user), or a server that let go of its tombstones
(after 2000). Clients get the ephemeral state over the WebSocket (`ephemeral`
snapshot on subscribe: the turn's state, status items, activity, busy,
approval, queue, notice; then `turn`, `status`, `activity`, `busy`, …
envelopes). The reply's words are not streamed to clients: the turn's
state says `responding`, and the reply comes with its row.
The archive `~/Library/Application Support/Visor/sessions.json` keeps the
session list and a suffix of rows; the queue is NOT archived (ephemeral).

**Claude's transcript comes from the file.** For tool "claude" the process
emits deltas (taken only as `responding`), status and busy only; rows come from Claude Code's own
`~/.claude/projects/<cwd-slug>/<session>.jsonl`, read by a `SessionIndexer`
(an actor) into the **message cache**; the record reads its events in order.
The file is a tree (uuid/parentUuid); `ClaudeBranch.current` keeps to
the branch the session was on — its head, the prompt its latest turn
began with, kept in sessions.json — and follows whatever carries on from
it; without a head, the branch holding the newest message (never a line
that is not a message: Claude Code hangs attachments and snapshots off
older messages). Prompts off it are abandoned. When the file's newest
message is on another branch (something else resumed the session), the
session offers the choice (`SessionInfo.otherBranch`, that branch's latest
prompt; an alert in the chat): keep this branch — the agent is resumed at
its newest message (`--resume-session-at`, Claude Code's own option), and
the next message makes it the newest again — or continue that one, which
reads the file again from its start on the newest branch and makes the
agent again. A line with no parent that is not the first
(compaction boundary) CONTINUES from the line before it; a line whose
parent was never seen is a missed line, not a fork. The indexer starts the
tail at a line boundary (never the file size mid-write — that orphaned
everything after). User rows the server appends (`user-N-…`) are settled
in place when the file's copy arrives (`user-file-<uuid>`, words compared
trimmed); file rows insert before trailing unsettled user rows.

**Message cache** (`libraries/message_cache`, module `MessageCache`): one
API over a `MessageStorage` — `SQLiteStorage` on every host (swift_sql's
`SwiftSQL`, `@swiftpkg_swift_sql//:SwiftSQL`: the system's SQLite on Apple's
systems, its amalgamation with FTS5 elsewhere, WebAssembly included), or
`MemoryStorage` for tests and the fixture. `MessageCache.directory` is
where a host keeps the file (else Application Support). The SwiftPM build
(Linux and Windows servers) takes the same package.
Tables: sources (path, identity=inode and the reading's version — a new
version reads every file again once, bytes,
nextSeq), syncs (revision, generation), nodes (the source tree), messages
(seq, id, role, text, source key, JSON of the row), messages_fts (FTS5).
Server cache: `~/Library/Application Support/com.LoganShire.VisorServer.macOS/
messages.sqlite` (Visor.app's: `…/com.LoganShire.Visor/Server/
messages.sqlite`), keyed by Visor session id; every agent's rows are
written by the indexer from its log. Client cache: Visor.app's
`…/com.LoganShire.Visor/Client/messages.sqlite` (iOS in its container), keyed
`<host id>/<session id>`; a session opens from it synchronously
(`AgentServerConnection.transcript(for:)`, called from `AgentScreen.init`)
with its latest 100 rows, and syncs only what moved; earlier pages are 50
rows, from the cache until it has none, then from the server (all of the
server's page kept). Every change a sync brings is written as a change
(`SessionTranscript.CacheWrite`): rows at the end or changed in place
upserted, a structural change rewriting from the first row whose place
changed, a whole answer in a new generation carrying on from the row it
`follows` — never the rows in memory in place of the history kept, so a
thread reads back offline as far as it was seen. A session left
(`AgentScreen` disappearing) is let go of 20 s later unless opened again:
its rows go from memory, its sync stops and the server is told
`unsubscribe`; opened again, it fills from the cache. A client behind
catches up 50 rows at a time (`later`, `after=`). Both are disposable: client rebuilds from server,
server from the files. `GET /api/search?q=words` searches the server cache.

**Ephemeral vs persisted.** Persisted = what
the JSON log says (the record). Ephemeral = thinking, task list, running
shells, monitors, subagents, tool calls, queued messages, the streaming
reply, a message being sent — memory only on the server, over the
socket. `TurnStatus` (server) builds `[StatusItem]` (kind thinking |
shell | monitor | subagent | tool | tasks; running/done; TodoWrite → a
tasks item with `[TaskItem]`) from `AgentEvent.thinking/.toolStarted/
.toolFinished`, which all three processes emit (Claude: tool_use id ↔
tool_result tool_use_id; Codex: item/started|completed by id; OpenRouter:
call id). What the agent has in the background between turns — a command
run in the background, a monitor, an agent of its own — is different:
Claude Code reports the whole list whenever it changes
(`system/background_tasks_changed` → `AgentEvent.background`), the
session carries it (`SessionInfo.background: [StatusItem]`, cleared when
its process goes or starts over: a new process has nothing there and says
nothing until that changes, so the list is known from its start, and a
Claude subagent its files leave unfinished runs only while it is on the
list or its call goes on) and the sessions list broadcasts it; the
sidebar row shows a clock and "Waiting on …" while the session is idle,
and the chat's status lines carry the items under the turn's own. A
streamed delta for a message the record already carries is
ignored (both ends); the turn's end sweeps served streams.

**Client** (`libraries/visor_client`): `AgentServerConnection` per server,
over the provider's `AgentServer` (`VisorAgentServer`: `hello`, ws(s) +
http(s) bearer at a `ServerAddress`, each operation mapped to the wire
protocol in `VisorAgentServer+Operations.swift`, and polling in its
place when the socket cannot be had, `VisorAgentServer+Polling.swift`;
an SSH address (`SSHAddress`, `user@host[:port]`, `?via=user@jump,…`
for jump hosts) is the same server reached through the computer's own
SSH, `VisorAgentServer+SSH.swift`: the route opened through the host's
`VisorSSHService` with the device's key, each hop's host key kept in the
settings the first time (`ssh.hostkey.<user@host:port>`) and compared
after, the server's port 7433 forwarded from a local port, and `address`
then `http://127.0.0.1:<port>` for everything else; only where
`VisorHost.ssh` is set, so not on the web or Android yet; a
fork's maps the same operations to its own service), `SessionTranscript`
(entries, streams by message id, `sending` = optimistic rows that stay the
last row until the record carries the same words at a later revision AND
every stream present when sent has landed — `shadowed` hides the matched
record row meanwhile; `turnStatus: [StatusItem]`). Sent text is trimmed.
`catalogs` envelope refreshes the agent list (e.g. after a key is saved).

**Keeping the connection** (0.18). The retry: after a drop
`AgentServerConnection` signs in and opens the channel again after 2, 4,
8, 16 s, then every 30 (`retryDelay(afterAttempt:)`). Each step has a
limit, so a try that hangs (a request riding a connection that died while
the app was away) becomes a drop and a retry: the sign-in has 5 s
(`signInTimeout`; 2 s on the first round for a path on the device's own
network, `localSignInTimeout`, which answers in milliseconds or not at
all), the socket 4 s to open and have its login answered
(`VisorAgentServer.loginTimeout`). A channel that was up and goes (a
socket error, a heartbeat unanswered) is opened again at once, by the
paths from the best, and the server is still shown as connected
(0.34: a connection is not disconnected unless no heartbeat came back in
time): only when every path
has failed is it offline and on the schedule, and a reopen that takes
longer than `quietHold` (6 s) shows it as connecting. The heartbeat
(`VisorAgentServer.watch`): a `ping` envelope every 16 s, and a
channel that says nothing for 8 s after one is closed and reported as
dropped, so a socket that died quietly (a sleep, a change of network) is
found in seconds rather than when TCP gives up. The poll
(`startPolling`): `AgentServer.sessions()` once a minute, taken as the
list while the channel is up, and the cue to reopen it at once when it is
down and the server answers.

The app's place on screen drives the rest (`VisorRootView` on
`scenePhase`). Leaving for the background (`VisorStore.suspend`) starts
every server's schedule over and keeps the log. Coming back
(`VisorStore.resume`) tries every server at the same moment, each on its
own: one not connected is opened at once, and a try that fails follows
the schedule from 2 s. One that was connected stays shown so and is asked
outright (`AgentServer.verifyChannel`: a ping, 1 s); one that does not
answer is opened again underneath, as a drop is. After time in the
background on a host whose sockets do not outlive it
(`VisorSocketService.dropsInBackground`: an iPhone) the host's HTTP
connections are let go first (`VisorHTTPService.reset`). Until 0.34 such a
host opened every channel afresh without asking, and showed it connecting.

The timed parts wait on the host's timer (`delay`), so the tests drive
them by hand (`ScriptedSocket.elapse`, `ScriptedServer.elapse`).

**The connection log** (`ConnectionLog.shared`): a line per event, with
the device's local time to the millisecond — the app in front, inactive
or in the background; per server, each sign-in and how long it took, the
socket opening, the welcome and how long after the channel was asked for,
each drop with its reason and the retry it schedules, the minute poll
when it finds something. The newest 1,500 lines, kept in the host's
settings when the app leaves the front. The computer's settings
page shares it as `visor-connection-log.txt` (the share sheet: AirDrop,
Files), copies it, or clears it. A fork's settings view can offer the
same from `ConnectionLog.shared.text`.

**Pushes and the widget** (0.18). A push's data carries the session's
state in a word (`state`: working, waiting, goal, idle), its `title`, the
computer's `name` and `updated`, beside `computer` and `session`. A change
that is not worth a notification (a turn beginning, a goal set) goes as a
silent push (`APNsSender.statusRequest`: background type, priority 5,
`content-available`); the notifications carry the state too. On the
iPhone `PushDelegate.application(_:didReceiveRemoteNotification:)` hands
the data to `WidgetFeed.take(push:)`, which rewrites the widget's kept
JSON through `WidgetSessions.json(_:applying:)` and reloads it — with the
app in front, behind, or woken for the push alone (`UIBackgroundModes`:
`remote-notification`). iOS delivers silent pushes when it chooses and
not at all to an app the user swiped away; the notifications still
arrive.

**Another kind of agent server** (a fork hosting agents on its own
service, behind its own sign-in) adds three things and changes nothing
else: an `AgentServer` conformance, which is the whole of what the
client asks of a server — `authenticate` (throw
`AgentServerError.needsAuthentication` to have the user sign in),
`openChannel` delivering `AgentServerEvent`s (`.welcome` first, then
`.sessions`/`.catalogs`/`.session(envelope)`), and the one-shot
operations (`sessions`, `startSession`, `act(SessionAction)`, `sendMessage`,
`transcript(of:since:generation:)`, folders, files, search; pushes and
linking have defaults); an `AgentServerProvider` that makes it for a
record (`AgentServerProviders.register`, before the store is made); and
an `AgentServerProviderUI` in VisorUI (`AgentServerProviderUIs.register`)
whose `addView` is the sign-in — any view; it calls `add` with the
`AgentServerRecord` once the user is in, `address` and `secret` meaning
whatever the provider wants — and whose `settingsView` is the saved
server's detail. With one provider view the add sheet is its sign-in;
with more, a list of them first. A record's `provider` id picks its
settings view; an add view may add another provider's records (a front's
entry, registered under an id of its own, that adds Visor Server
records). How a server sets up new sessions is its `starting`: in folders
(a computer's), or from its own `startChoices` (a hosted backend's
templates, whose id goes in `cwd`), and only with a first message
(`startSession(…firstMessage:)`; the server may give the session an id of
its own); the compose sheet follows. A server whose `managesSessions` is
false has renaming, archiving and removing kept on the device for its
record (`LocalSessionEdits`), laid over every list it sends.
The session-side values a server hands back (`SessionInfo`,
`TranscriptEntry`, the transcript and ephemeral envelopes) are the
protocol library's, so a fork's server produces those from its own API.

**Agents across computers** (`VisorServer+AgentAsks`, `+Directory`,
`+RelayOutbox`, `+RelayDelivery`, `+RelayRoutes`; `RelayCourier` in the
client): servers never talk to one another. Every server has an id
(`ServerSettings.serverID`, made once; `hello` carries it and the server's
own addresses, `ownAddresses`: the public address, each address with the
port while the network reaches it, `ssh://user@address` while SSH is let
in). The client's `RelayCourier`, owned by `VisorStore`, reports to each
server that takes part what the device is connected to (`report()`: the
servers taking part and their sessions, archived ones left out)
every 20 s, when a server connects (`joined`), when a record changes, and
at once for a server's `relay` push (`AgentServerEvent.relay`, the
connection's `onRelay`); the server keeps it by client id
(`directory`, ten minutes) and answers with its outbox's messages for the
servers named, which the courier carries (`deliver`, then `confirm` back
to the source). A server's `answerAgent` answers its own sessions as
before (`agentReply`, `answer`); one on another server becomes a
`RelayRecord` in `relayOutbox` (kept in `relay-outbox.json`, expired after
a day, dropped a day after it finished), and the asking agent waits on
`awaitRelay` (8 s for a send, 20 for a read; tests shorten them) or is
given the message id for `message_status`. The destination's
`takeRelayed` keeps every receipt in `relayLedger` (`relay-ledger.json`,
two days), so a message carried twice is answered from it. Taking part is
the record's `relay` (nil: `RelayCourier.onByDefault`; the toggle in a
computer's settings), never for a server that stands alone or an
`isolated` authenticator's; a server turned off is sent one empty report.
Enrolling a device is by the server's own codes (`GET /api/codes`,
`ConnectionCodes`: the QR code's and one leading with each kind of path),
shown the same by the menu bar app (its menu and Settings) and by a
client's computer settings (`ConnectionCodeSection`), so a code can go
from the menu bar to a Mac's client to a phone.

**Another kind of sign-in** (a fork whose users sign in with a
company's SSO, the server itself being Visor's behind a front that
checks the token): transport and sign-in are apart. The transport is the
address (HTTP, HTTPS, the computer's SSH); the sign-in is an
`AgentServerAuthenticator` (`libraries/visor_client`), named in the
record (`authentication`: `password` unless said), which gives the
headers every request carries from the record's `secret` — the password
as a bearer, none as nothing, a fork's as whatever its front wants — and
throws `needsAuthentication` when the user must sign in again (a token
expired). A fork registers one (`AgentServerAuthenticators.register`)
with its rows for the forms (`AgentServerAuthenticatorUIs.register`: a
button that runs the SSO and sets `secret` to the token), and nothing
else changes. An authenticator may also find the other servers behind
its front once one has connected (`discover(from:)`: the store adds
those it does not hold), say every server it signs in to stands alone
(`isolated`), and, having signed in once for many records (one SSO
session per front, its token its own), call
`AgentServerAuthenticators.signedIn(_:serving:)` so that every record
waiting for it connects again. The headers go on the REST calls and on the socket's
opening request (`VisorHTTPService.request(…headers:)`,
`VisorSocketService.open(url:headers:)`; a host with only the bearer
forms sends the bearer out of them, a browser opens the socket without).
**Onboarding** (`VisorOnboarding`, visor_ui): what a new user is shown
before the app is set up, in place of everything else while its
`isNeeded(store)` says so. The default (`DefaultOnboarding`) shows while
there are no computers and the app has no account: Visor Server on a
computer, a VPN of one's own to reach it away from home, and Add Computer.
A fork with a more involved setup sets `VisorOnboardings.current` at
launch. `-visor.fixture snapshot -visor.fixture.screen onboarding` shows it.

**An account for the whole app** (a fork whose one single sign-on reaches
several servers behind its front): a `VisorAccount` set at launch as
`VisorAccounts.current`. Signed out, `VisorRootView` shows its sign-in
(`AccountSignInView`) in place of the computers; signed in, the store adds
the servers its `servers()` lists (`fromAccount`, named as the account
names them, signed in to by `AccountAuthenticator`, which asks the
account's `headers(for:)`), follows `VisorAccounts.changed()`, and takes
them away at Sign Out (the sidebar's `AccountSection`). None by default;
`-visor.account fixture` (or `fixture-signed-in`) uses `FixtureAccount`,
three canned computers behind one front. The client's models are
`@Observable` (the iPhone app targets iOS 18 from 0.35, 26 before); `SessionTranscript` keeps
its state untracked behind one counter, so views hear of a frame's changes
once.
The server's side is `ServerSettings.authentication`: `password` (the
default), or `none`, which lets in whoever reaches it — for paths of
one's own, or a front that has signed the user in.

**Which path fits where the device is** (`VisorNetworkService`,
`NativeVisorNetworkService`; `AgentServerConnection.pathsToTry`, `fit(of:)`,
`networkChanged`): the host says which hosts are on a network the device
is on now (each interface's address and mask) and whether it has a
tailnet address, and calls back when the networks change (NWPathMonitor).
Paths are ranked loopback, local, overlay, other, unlikely (this
device's own 127.0.0.1 first, for a server on it — a server gives its
loopback path last among its own, and one whose id isn't the record's
there is another computer, so that path goes; a LAN's address when away,
a tailnet's with no tailnet; a link's own 169.254 address counts as a
LAN's) — the one that answered last first among its equals, kept in the
record (`lastPath`) so a launch starts with it — and `VisorStore` has
every connection re-rank on a change: a server connected by a path that
is no longer the best is connected again by the one that is, and one
already signing in by the best is left to finish (the monitor's first
word at launch). A host without the service (the web, Android) tries
paths in the order kept, the last one that answered first. The paths are
the server's own word at each sign-in (`AgentServerRecord.takePaths`): an
IP it no longer gives goes (a lease that moved, a link-local address, a
bridge to a virtual machine, each of which was tried and waited out on
every launch before 0.34); a name stays after them, as does the path last
answered on. A Visor server is signed in to by the round's paths at once
(`AgentServer.racesPaths`, `VisorAgentServer+PathRace`): the first at
once, the next when it has had its head start alone (400 ms; an SSH path,
the way in, 1 s), or at once when every one before has failed, each with
its own timeout, and the first to get in taken — so a path that says
nothing costs its head start, not its timeout. A 401 is the answer only
when no path gets in. Another provider's server is signed in to one path
at a time.

**Bootstrapping SSH** (`VisorServer+SSHKeys`, `AgentServerConnection.
useSSH`, `enrollSSHIfWanted`): a client that is in by any path hands its
SSH public key to `POST /api/ssh/keys`, which puts it in the user's
`authorized_keys` (0700/0600, once). A record whose address is an SSH
path that refuses the device's key is not a sign-in to redo: the
connection tries its other paths, and once in by one of them hands the
key over and connects again over SSH, once. "Use SSH" in Computer
Settings makes the SSH path on the same host the address and does that;
the connection code carries every path (`ConnectionCode.paths`), and
the SSH connection code (`preferringSSH`, in the menu bar and in
Computer Settings) puts an SSH path first, so a new device scanned in
with it comes in by another path once and uses SSH from then on. With no
other path (HTTP off everywhere), the new device shows its key as a QR
code (`SSHKeyLink`, `visor://authorize?key=`, in the device key section);
a device that holds the computers scans it and `VisorStore.authorize`
hands the key to every computer connected, after which the new device
scans the SSH connection code and comes in over SSH at once.

**UI** (`libraries/visor_ui` on AgentUI): `RootView` sidebar (flat session
rows: title / status dot-or-spinner, or the raised hand or question of a
prompt or question waiting, ahead of the spinner of the turn it holds up
• computer • project / two-line preview), `AgentScreen` (chat: `AgentView(messages:streams:activity:
status:…)`), `SessionInspector`, `ComposeSessionSheet`. In agent_ui,
`TranscriptView` renders the record, then ONE always-present
`EphemeralFooter` cell (id "bottom": streams, queued, sending,
`ActivityList` of `ActivityItem`s with task checklists, error, the 18 pt
gap) — the only scroll target; the first population is not animated; the
scroll after the composer grows waits for layout (`afterLayout`).

**Who gets in (2026-10-06).** `VisorServer.authorized(request)`: the
bearer is the password, a token `GET /api/hello` issued (kept in
memory, 512 newest), or the admin token (`AdminToken`: its SHA-256 alone,
in the secrets for the menu bar app, in memory when the command-line
server is given it at launch); never an agent's token
(`AgentTokens`, JWTs signed with `SigningKeys`; docs/protocol.md, "The
admin token" and "Agents' tokens", with what they don't protect against);
no header names a user. The socket's `login` takes
`token` or `password`. Each is compared whole (`SecretToken.same`), and
wrong ones are counted per peer address (`PasswordThrottle`, from the
stream's `remoteAddress`: `HTTPRequest.peer`, `ClientConnection.peer`;
none on Windows yet): five in a minute lock the address out for five
minutes (429, `Retry-After`); an IPv6 address by its /64, but a
tailnet's (fd7a:115c:a1e0::/48, one /64 for all its nodes) whole. From
loopback, `X-Forwarded-For`'s right-most entry is the address instead
(`ForwardedFor`, `clientAddress`: `tailscale serve`'s clients would
otherwise all be this computer); the header from anywhere else is
ignored. Those clients arrive on loopback, so `ServerSettings.lan` and
`vpn` don't apply to them: `tailscale serve` is the owner's own choice to
open the server to the tailnet. One listener (`FrontDoor` tells an upgrade from a request by its
first bytes), on loopback or every interface
(`ServerSettings.lan || vpn`; `admits(localAddress:)` closes a connection
on a path that is off, `NetworkAddress.Kind` by interface or range),
plain or TLS (`tlsIdentityPath`,
Apple only; elsewhere `ListeningError.tlsUnavailable`); and a second on
the socket file `VisorServer.socketPath` while `sshEnabled`
(`ListeningOptions.unixPath`; Apple and POSIX, not Windows:
`ListeningError.unixUnavailable`), whose connections are trusted —
`HTTPRequest.trusted`, `ClientConnection.trusted`: no bearer, no
password at login. The client over SSH tries the file first
(`VisorAgentServer+SSH`: `nc -U` over an exec channel per connection,
`VisorSSHSession.attach`) and falls back to the port with the password
(`forward`) when hello fails there.
Clients (`AgentServerConnection.open` → `AgentServer.authenticate`) do
`hello` first — 401 → `AgentServerError.needsAuthentication` → state
`.needsAuthentication`, no retry until the record changes — then the
socket with the token. There is no automatic discovery (manual, one-step
adding keeps Visor from depending on any network's device list): the
connection code (`ConnectionCode` in visor_protocol, base64url JSON of
name/host/password) is made by `VisorServer.connectionCode` and taken by
`VisorStore.open(_:)`, from the connect form (code, link or bare name)
or the apps' `onOpenURL`. Nothing opens by itself: the sidebar's last
section is always "Add Computer…", which opens the connect sheet
(`store.addingComputer`; the Mac also has it in its Computers menu).

**Claude's models.** `ClaudeHarness.refreshModels` (at launch, then
every 6 h) starts `claude -p` with stream-json, sends the SDK's
`initialize` control request, takes the answer's `models` (value,
resolvedModel, description, supportedEffortLevels; the "default" entry
names the account's default) and ends the process — no turn, no session
file. That list is the Claude catalog (ids like `opus[1m]` go to
`--model`); the hardcoded list is the fallback. `AgentCatalog.model(
matching:)` also matches without the `[1m]` mark, so a reported
`claude-opus-5-5` or an older session's `fable` finds its row.

**Codex's models.** `CodexHarness.refreshModels` (same schedule) runs
`codex app-server`, `initialize`, `model/list`, and ends it: the visible
models, their efforts and default effort, and `isDefault`. A `model` in
~/.codex/config.toml still wins as the default; ~/.codex/models_cache.json
(which Codex only writes once it has run) is the fallback.

**Sidebar.** Inset grouped (`insetGroupedList()` in Compat: `.insetGrouped`
on iOS, `.sidebar` on macOS): a `HostSection` per computer (observes the
host; header = badge dot, name, state), its sessions newest first, an
"Archived · project" row per project with ended sessions, and "Computer
Settings" last (edit or remove). Compose offers only
`store.connectedHosts`.

**Menu bar app** Settings: the connection code (QR + copy), the password
(required), the network (whose the Mac is, the front's state). Its menu
never shows the password: Copy Password puts it on the pasteboard.
`POST /api/restart {path, session}` installs a bundle over itself via
a detached relauncher and resumes named sessions with a nudge
("[Visor] The Visor server restarted while you were working…"). The
relauncher (`AppRelauncher`, its script AppRelaunchWatch's) keeps the
running bundle aside (`Previous/` in the data directory) and watches the
new one for two minutes: if it quits, crashes or never answers (on its
port from its own process, or at its socket file while it has no password
to listen with), the previous build is put back and started, and
`relaunch-rollback.txt` says why, which the server shows in its menu
(`updateNotice`) once. Once the new build has stayed up, the one it
replaced is removed (no backups left behind).

**The server in the app** (0.72.1; Logan, 25 Nov 2026: "The background
process IS the menu-bar app, so that I can always tell when it's running,
and its windows are the clients."). Visor's server runs in Visor.app's own
process: the menu bar app (LSUIElement, with a Dock icon only while one of
its windows is open), whose window, menu and Settings are the server's
clients at its socket file, as before (LocalServer, MacServer): the
sessions and their agents' hosts, the native runner, the driver on 7434,
REST and WebSocket on 7433, the socket file, pushes, MCP, agent-proxy
folded in (MacAgentProxy.foldIn: its separate launchd job is removed), and
the Sessions container's engine, whose VM is in this process
(docs/containers.md). The eye in the menu bar is the server: if it's
there, Visor runs. Its lines go to the system log and to `Visor-server.log`
in Visor's logs. The server agent of the builds before (`Visor --server`, 0.65 on) is no
longer a place it runs, and the `ServerAsAgent` default isn't read.
- **The app's own launchd agent** (AppAgentJob, AppAgentService in
  libraries/visor_launch_agent): `com.LoganShire.Visor.app`, its plist the
  bundle's own (`Contents/Library/LaunchAgents/com.LoganShire.Visor.app.plist`,
  from applications/visor_mac/LaunchAgents), registered with
  SMAppService.agent: BundleProgram and ProgramArguments the app's own
  executable with no argument (the app itself, menu bar and all), RunAtLoad,
  `KeepAlive {SuccessfulExit: false}`, LimitLoadToSessionType Aqua,
  ProcessType Interactive, AbandonProcessGroup (the agents' hosts and the
  update's watcher outlive it), and `VISOR_APP_AGENT=1` in its environment,
  so the app knows launchd started it (and takes it out of its own
  environment at once). launchd starts Visor at login, and again after a
  crash (a signal, or an exit that isn't 0); never after Quit Visor, which
  exits 0. **Start at Login** (the menu, and Settings › Where it runs: the
  `StartsAtLogin` default, on unless turned off) registers or unregisters
  it; only for an app in /Applications. There's no SMAppService.mainApp
  login item.
- **One instance, launchd's where it can be** (MacAppInstance, at the
  launch before anything else): a lock (InstanceLock: flock on
  `<bundle id>.instance.lock` in the user's temporary folder, let go by the
  system when the process ends, however it ends) keeps one Visor running. A
  second instance exits 0 at once (so KeepAlive doesn't start it again) and
  brings the first forward with its window (a distributed notification),
  unless launchd started it: a crash's restart that met a person's open.
  An instance a person opened (the Finder, the Dock, `open`), with the agent
  wanted, hands itself to launchd: `launchctl kickstart` of the agent, else
  the agent registered afresh from the bundle (lsregister, unregister,
  bootout, register, as SMAppService's launch constraint wants after the
  bundle changed), which starts the app as the agent; it exits 0 once that
  one holds the lock, so a crash of the Visor that runs is answered. If
  launchd doesn't start it within a few seconds (Login Items waiting for
  the person, a refusal), Visor runs where it is and says why in the system
  log. Launches by launchd, and the update watcher's fallback open
  (`--without-agent`), run where they are; as second instances they're
  quiet, the window mid-update being the present marker's alone. An open
  while an update's watch holds `relaunch-watch.lock` (a live watcher, its
  start time checked: RelaunchWatchHolder) doesn't hand itself to launchd
  (AppAgentJob's `runWhileWatched`): that is the open of a build before
  0.72.1's watcher, which follows the app by its full path and would take
  the hand-off for a quit (NCH's lease test of 0.72.1, from 0.71.1: the
  watcher put 0.71.1 back in /Applications while launchd ran 0.72.1 from
  the replaced bundle), or the server agent's watch, which the hand-back
  waits out. Visor runs as the process that was opened until the watch has
  ended and the server runs in the app (after the hand-back, if there was
  one), then hands itself to launchd with a restart through its agent
  (LocalServer, AppAgentJob.handOff), which this build's watcher follows;
  until then a crash isn't restarted, as before 0.72.1. A copy
  outside /Applications (a build to run here, one in Downloads) is a
  client alone, with no server and no lock, unless
  `ServesOutsideApplications` (a default) or
  `VISOR_SERVE_OUTSIDE_APPLICATIONS=1` (CI's launch check) says it may
  serve. With the agent wanted, the app opts out of macOS's relaunch at
  login (`disableRelaunchOnLogin`: launchd's is the one start), and its
  window is never restored from the launch before (`restorationBehavior
  (.disabled)`), so a login keeps to the menu bar.
- **The window at launch** (Logan, 25 Nov 2026; AppAgentJob.showsWindow):
  launchd's own launches, at login and after a crash (and so the start of
  an update's new build), keep to the menu bar (the window scene's
  `.suppressed`). A person's open shows it, and so does launchd's process
  a person's open was handed to: the opener writes a marker beside the
  lock (`<bundle id>.present`, the time) before it asks launchd, and
  launchd's process reads it and takes it away; one older than three
  minutes says nothing. An update's relaunch gives back the window it
  found: with a window open as the app went, the watcher writes the same
  marker just before each start (AppRelauncher, AppRelaunchWatch's
  `present`); with none, the new build keeps to the menu bar. Opening
  Visor again while it runs shows the window, as before
  (applicationShouldHandleReopen).
- **Failing closed** (NCH's check of #537): an instance lock that can't
  be had at all (its file can't be opened or locked) has that copy run as
  a client alone, with no server of its own, saying why in the menu,
  Settings and the system log: it can't know it's the only one. A lock
  left by an update's watch whose process id now names another process
  (its start time, from the system, isn't when the lock says the watcher
  started: RelaunchWatchHolder) holds the hand-back up for nothing.
- **Quitting** (Quit Visor in the menu; ⌘Q in the window only closes it):
  the server ends its agents (`/api/quit`), then the app exits 0, which the
  agent leaves stopped until the next login or the next time Visor is
  opened.
- **A crash** restarts the app through launchd: the agents' hosts outlive
  it and are picked up; the Sessions container's VM, in the process, goes
  with it and its placed sessions' agents start again on their latest
  conversations (docs/containers.md, A server's start).
- **Updates and rollback** (AppRelauncher, its watcher's script
  AppRelaunchWatch, tested on Linux): `POST /api/restart {path}` (Visor's
  own updates through Shireworks Kit, VisorUpdates, the only update path)
  checks the bundle and starts a detached watcher; the server lets its
  hosts go and the app exits 0. The watcher, once it has gone, moves the
  running bundle aside (`Previous/<token>/`), copies the new one in, and
  starts it through launchd: `<new executable> app-agent start` registers
  the agent afresh from the bundle in place (its launch constraint is the
  bundle it was registered from: launchd won't start the job from another
  until it is) and waits until launchd runs the app. Exiting 0 first, and
  the watcher starting it, means launchd and the watcher never race: KeepAlive
  never answers an exit of 0. With Start at Login off it unregisters the
  agent and ends 1, and the watcher opens the app itself (`open -a …
  --without-agent`, in the background: `open -g`), as it does if launchd
  doesn't start it and its copy hasn't come up meanwhile. The app that goes
  has a minute to end, then TERM, then KILL ten seconds on (each logged).
  An `app-agent start` that ends other than 0 or 1 (an exit of 3, a crash)
  is a build whose executable doesn't run at all: no open is tried, and it's
  undone at once ("it didn't run"), not after ten minutes' wait for a
  process (NCH's lease test of 0.72.1: a broken bundle was opened instead,
  then nothing). The watch follows the app's process by its pid, the
  instance lock's holder (the lock file's pid), never by its command line:
  launchd runs the app by a path relative to the bundle
  (`Contents/MacOS/Visor`), which no search by the full path finds, and a
  second copy that loses the race and exits 0 is never a crash (NCH's
  check of #537). The full path finds only an opened copy, for the stop.
  What the watch runs to start, stop and find the app is
  AppRelaunchCommands (libraries/visor_server, apart from AppKit): the
  tests on Linux run those very words with stand-ins for launchctl and the
  app, and the Mac's tests (visor_launch_agent_mac_tests, CI's test job)
  read every script the watchers build with macOS's own `/bin/sh -n`. That
  shell is bash 3.2, which reads a case's `pattern)` inside `$( … )` as
  the substitution's end: 0.72.1's watcher died of it before it could say
  a build stayed up or roll one back. Case patterns are written
  `(pattern)`. The pid stays in the file after its holder ends, and a
  pid is reused, so a live process by that pid counts only while the lock
  is held (AppRelaunchWatch.lockHolder: a try to take it at once fails,
  `/usr/bin/lockf -t 0` on a Mac, util-linux's `flock -n` in the tests);
  otherwise a stranger would skip the fallback's open ("launchd's copy came
  up after all"), be watched, or be stopped. The app that goes is waited
  for by `kill -0`; on Linux (the tests) /proc's `State: Z` says an
  unreaped one has gone, and a Mac, with no /proc, asks `kill -0` alone
  (launchd, the app's parent, reaps it at once). Up to ten minutes for a process to appear at all (the
  system's first checks of a new build), then two minutes for its first
  answer, on 7433 from that process (lsof's listener), or at its socket
  file while it has no password to listen with, then two minutes up: a
  build that runs and never serves is undone about five minutes after its
  start began. `served` starts at 0 whatever the app was doing (until
  0.72.1 it started at 1 for an app that didn't listen on its port, so
  "never answered" couldn't be said). If the process goes (launchd's
  restart after a crash is another process) or never answers, it's stopped
  (`launchctl bootout` of the agent first, what launchctl said logged, so
  KeepAlive starts nothing while the bundle is put back; then the lock's
  holder, TERM then KILL, and one that can't be stopped is said to run
  still), the previous bundle is put back, `relaunch-rollback.txt` says
  why, and it's started again the same way.
  Every session that was running is carried on (launchd starts the app
  with no `--resume-sessions` list). A plain restart (Restart Server, and
  the hand-off's restart through the agent once an old watch has ended:
  LocalServer.handOffOnceWatched) has nothing to put back: one that
  doesn't come up is stopped, started once more and watched again, and
  the watch ends with "stayed up" or "did not come up again". Quit Visor
  during a plain restart's watch is left alone: the app writes its pid to
  a Quit marker as AppKit ends it (`<bundle id>.quit` beside the lock,
  AppAgentJob.quitMarker; a crash never writes it), and a watch whose
  process went with the marker naming it says "was quit" and starts
  nothing, as launchd's KeepAlive leaves an exit of 0 (NCH's lease test of
  0.72.2: a Quit within two minutes of the hand-off's restart was taken
  for a start that failed, and Visor came back). The marker, not
  `launchctl print`'s "last exit code": that's the job's, not the
  process's (the fallback's opened copy is no job's, and `app-agent
  start` registers the job afresh), and launchctl's manual says its output
  is no API. An update's new build that goes within its watch is undone,
  quit or not: it's unproven. The watcher's lines ("starting", "stayed
  up", "rolled back", "was quit", launchctl's word) go to
  `visor-relaunch.log` in Visor's logs (AppLifecycle), not to
  `Visor-server.log`: look there for how an update or a restart ended.
  From 0.71.1 (historical): an update that 0.71.1's server agent
  installed is watched by that agent's own watch (ServerAgentWatch, its
  script 0.71.1's), which asks only 7433. On a Mac with no password yet the
  server listens on no port, serving at its socket file alone, so that
  watch never hears it and rolls back ("it never answered on port 7433").
  This build's watcher asks the socket file then.
- **The hand-back** (ServerHandBack, LaunchdHandBackSteps, at the app's
  launch before it makes a server; tested with fakes on Linux): on the
  first launch of 0.72.1 after an update that the server agent installed
  (its watcher starts the new build as the agent, `Visor server-agent
  register`, then the app of the build before reopens), the app finds the
  server agent registered (or 0.64's plist, or a server answering at the
  socket file or on 7433). It leaves its data where it is (MacPlaces.settle
  only once the server is its own), waits out an update's watch still
  holding `relaunch-watch.lock` (an agent gone mid-watch would be taken for
  a crash and rolled back; the app opened meanwhile runs where it is,
  handing itself to launchd only after: One instance, above), unregisters
  the agent and boots it out of
  launchd (TERM: it steps aside, leaving the agents' hosts running; not
  `/api/quit` first, which ends them), removes 0.64's plist, and waits up to
  40 seconds for the socket file and the port to be free; a server still
  answering is then asked to quit (`/api/quit`, as the app's client), the
  last resort. Then the server starts in the app and picks the hosts up.
  Each step is logged (`hand-back: …`). A copy outside /Applications, which
  may not remove the agent, and an app that finds a server still answering
  after all that, are its clients and serve nothing themselves. The
  `ServerAsAgent` default is removed.
- **Kept one release** for the hand-back and for safety, then removed:
  `Visor --server` (MacServerAgent), `Visor server-agent register`, the
  server agent's bundled plist (`com.LoganShire.Visor.server.plist`, which
  SMAppService needs in the bundle to unregister it), ServerAgentJob,
  ServerAgentService, ServerAgentRestart and ServerAgentWatch. Nothing new
  uses them.
- **Shireworks Kit (0.70; Logan, 24 Nov 2026):** every Apple app (Visor
  for iOS, Visor.app, Visor Disk Utility) links shireworks_kit's
  `ShireworksKit` in place of update_kit and shake_kit, and has
  `.shireworks()` on its window's root view: at its first appearance it
  starts crashes (filed as issues) and updates (the build written for
  Shireworks; on a Mac, Shireworks' offers answered), once a process, and
  puts shake to report on the view. On a Mac, Help › Report a Bug… is
  `ShakeKitCommands`; Visor.app, a menu bar app, adds
  `ShakeKitReportWindow` and the menu's `ShakeKitReportButton`, and starts
  the kit from VisorUpdates too (its window may never open), after
  registering its own answer to offers (`.installMyself`), which wins over
  the kit's update sheet. The server agent (`Visor --server`, until
  0.72.1) started `ShireworksCrashes` alone: `ShireworksKit.start()` would
  write the build for Shireworks from it too, which is the app's. The keys
  (`ShireworksRepository`, `UpdateKitAppGroup` and, on a Mac,
  `UpdateKitApplicationsBundleIDs`, `BuildVariant`, the `GitHubShared…`
  keys) are stamped in by CI's builds to publish, never committed
  (tools/signing, tools/variant, tools/shared_sign_in); a build without
  them files nothing and writes no build. builds.json's Visor macOS line
  `replaces` the retired Mac client app's bundle id.
- **What phones and the other Mac see:** an ordinary server restart. The
  data folder (`/Volumes/Visor/Data` on the Visor volume, else
  `~/Library/Application Support/Visor`: docs/containers.md, Visor's
  volumes), the keychain items
  (the app's own executable reads them, the same signature), the server id,
  the ports (7433, 7434), the socket file, `tailscale serve`'s target
  (127.0.0.1:7433) and the admin token are the same, so they reconnect to
  the same address and identity, with no re-pairing.
- **The volumes given to the person (0.65):** Visor Disk Utility follows
  each `diskutil apfs addVolume` with `chown <user>:staff` and `chmod 775`
  of the new mount point, in the same administrator prompt (as Nimbus
  does: a volume made as root is root's at its root). VolumeGuard passes
  them only as exactly that, at a role's mount point, for a volume made
  earlier in the same run, or for an adopted one of Visor's own when its
  card's Fix (or `fix-owner <role>`) names it in `fixing`.
- **A case-insensitive volume is a note, not a conversion (Logan, 24 Nov
  2026):** Visor Disk Utility only creates the three volumes and checks
  them. A Sessions or Sources made by hand as plain APFS is adopted as it
  is, never reformatted or converted; its card (and `status`) says it
  should be case-sensitive and how to remake it: move what's on it
  elsewhere, delete it in Apple's Disk Utility, Create it again, and move
  the contents back (VolumePlanner.caseNote). VolumeGuard passes only the
  creation's, Fix's and Spotlight's commands: nothing that deletes,
  erases, renames or mounts a volume.
- **The Visor volume out of backups and search (0.65):** Visor Disk
  Utility makes Visor with Spotlight off (`mdutil -i off /Volumes/Visor`
  after `diskutil apfs addVolume`, one administrator prompt; VolumeGuard
  passes `mdutil` only so, at Visor's own volume), reads back both
  exclusions (`tmutil isexcluded`, `mdutil -s`, as the user) for the
  volume's card and `status`, and turns Spotlight off again where it's
  found on (Leave Out of Backups…, `exclude-visor`). Time Machine's
  exclusion of a whole volume is the person's on macOS 27 (no app may, as
  Nimbus found), in Time Machine's settings, which the button opens.
  Sessions and Sources are left in both.
- **One update's watch at a time (0.65; NCH's check of #491):** an
  update 43 seconds after another had the first watcher, still watching,
  take the second's restart for a crash and undo it over the second's
  install, leaving no Visor.app. Now the watcher (AppRelauncher's; the
  server agent's ServerAgentWatch until 0.72.1) holds `relaunch-watch.lock` beside the rollback
  note while it watches (RelaunchWatchLock: `<pid> <started>`), stopping an
  earlier watcher still holding it as it starts; the server answers
  `/api/restart` with 409 ("An update is still being watched; try again in
  N s"), and the menu's restart likewise, while a live watcher holds it: a
  process by the lock's pid that started within 30 s of the time the lock
  records (`ProcessSignals.startTime`, as the hand-back's
  RelaunchWatchHolder asks; NCH's check of #537: a live pid alone may be
  another process's since, and would refuse every restart for a whole
  watch).
  Each watch keeps the bundle it replaced in `Previous/<token>/`, and puts
  it back only if that copy is there, whole, and the bundle in place is
  still the one it installed (its executable's checksum): otherwise the
  bundle in place is left as it is, and the log says so.
- **The first registration after 0.64's plist (NCH's check of #491):**
  for a while after 0.64's plist is removed, Background Items keeps 0.64's
  item of the same identifier and macOS refuses the registration
  ("Operation not permitted": the job "is not allowed to bootstrap").
  ServerAgentJob.reregister waits that out, trying again after 2, 4, 8 and
  then 15-second pauses (about a minute and a half), the menu saying
  calmly "Handing Visor's server to macOS Login Items (this can take a
  minute or so)…", with no raw error; only then does it give
  up, saying so, and the app stays the agent's client, never its own
  server.
- **The socket file's move (0.65):** with the Visor volume, the server
  listens at `/Volumes/Visor/run/server.sock` (VisorServer.placedSocketPath,
  set by MacServer) and makes `~/.visor/server.sock` a link to it, for SSH
  clients of 0.64, whose command is `nc -U ~/.visor/server.sock`. A client
  of 0.65 asks `sh -c` for the volume's socket first, then `~/.visor`'s
  (VisorAgentServer.attachCommand), and `/api/hello` doesn't name the path.
  The link stays through 0.66, whose socket file may move again, to the
  app group's container (below). **Remove in 0.67:** the links
  (VisorServer.linkLegacySockets, `legacySocketLinks`, and the legacy
  socket in MacServerAgent.otherServerGone).
- **Visor on the Mac (0.66's groundwork; the design of 24 Nov 2026).**
  docs/sandboxed.md is Logan's model: Visor.app bundles its notarized
  server, which runs native and container sessions itself, container
  files only on the Visor, Sessions and Sources volumes (from 0.72.1 in the
  app's own process: The server in the app, above). It replaced the 22 Nov design (a sandboxed
  Visor.app with its server in-process, and Visor Agent Utility for native
  sessions), which is dropped. What 0.66 laid down for it still holds: the
  app groups `group.com.LoganShire.Visor` and
  `group.com.LoganShire.Shireworks` (Logan, 23 Nov 2026, in place of
  `group.com.LoganShire.Applications`), the keychain group
  `<team>.com.LoganShire.Visor`, and:
  - **Sockets in the app group's container**, behind a setting until
    every profile grants the group (`defaults write com.LoganShire.Visor
    VisorGroupSockets -bool true`, or VISOR_GROUP_SOCKETS=1; MacPlaces'
    `groupSockets`). VisorPlaces (libraries/visor_disk_volumes) puts them
    in `~/Library/Group Containers/group.com.LoganShire.Visor/r/`:
    `server.sock`, the Sessions container's `relay.sock` and `driver.sock`,
    and the agents' hosts' `h-<8 hex>.sock`, every path under the 104 bytes
    a socket's may have (PlacesTests); with no container, or a home too
    long for them, they stay where they were. The volume's
    `run/server.sock` and `~/.visor/server.sock` are links to it for a
    release. The server's SSH addresses carry the path
    (`ssh://user@host?socket=<percent-encoded>`), so the connection code
    does, and `/api/hello` says it (`socket`); a client runs `nc -U` on
    the path it's given (SSHAddress.attachCommand), and with none tries the
    volume's, the group's and `~/.visor`'s in turn.
  - **The client's keychain items in Visor's keychain group**
    (MacClientSettings): every item of the client's service
    (`com.LoganShire.Visor`: `password.<server id>`, `ssh.key`, and what's
    kept with them) copied from the login keychain, which a sandboxed app
    can't read, to the data-protection keychain under
    `<team>.com.LoganShire.Visor`: all at the app's start, and any left
    when first read (ProtectedSecrets' `keepsLegacy`: written and read
    back). Reads ask the group first, then the login keychain, whose item
    is copied; writes go to the group alone; a secret removed is removed
    from the group, its login-keychain copy noted as forgotten (by hash) so
    a read doesn't bring it back. **The login keychain's copies are kept**,
    for a rollback through the prep release (0.66.1, or the update
    watcher's undo, read them alone): nothing is ever deleted or updated
    there, since a legacy-flavoured delete reaches the group's item (#502)
    and an update may too. They go stale after the prep release, and stay
    until a person removes them in Keychain Access (there's no Uninstall…
    since 24 Nov 2026); sandboxed Visor can't read or delete them.
    The server's own items keep #502's move. Without the group (signed ad
    hoc) the client's stay where they are.
  - **The agent hosts' spawner** (AgentHostSpawner): AgentChildren and
    HostedChild start a host through one, given an AgentHostSpawnRequest
    (libraries/agent_host_wire: the session, folder, harness, command,
    environment, JWT or token file, socket; JSON, documented there).
    The one there is is the server's own (ProcessAgentHostSpawner, as
    before): the server runs native sessions itself, and no other takes
    its place.
- **No Uninstall… (Logan, 24 Nov 2026):** "as long as everything is self
  contained they can just delete the volumes in Disk Utility". Visor Disk
  Utility's Uninstall… (libraries/visor_uninstall) and `Visor server-agent
  unregister`, which it ran, are gone: a person removes Visor by quitting
  it, moving the apps to the Trash and deleting Sessions, Sources and
  Visor in Apple's Disk Utility. What's still outside the volumes (the
  app's agent's registration, the keychain items, the apps' defaults, the
  `authorized_keys` lines, which Forget This Device takes out) is for
  Visor's own self-containment to bring onto them or drop.
- **`Visor admin-token`** prints the admin token to standard output, from
  the keychain (MacAdminTokenCommand), for a script, so `.zshrc` needn't
  export it: from 0.65 Visor.app keeps the token itself beside its hash, in
  the data-protection keychain under the app's group (AdminToken's
  `keepingToken`). A token made before 0.65 isn't kept: rotate it once.
- **The app is the server's client alone** (0b). Whichever process
  runs the server, the app reaches it the one way, at its socket file,
  as an SSH client does: no password, through the client stack that
  reaches every other computer (VisorAgentServer, with the host's HTTP
  and socket services wrapped by libraries/visor_socket_file to send
  `http+unix://` and `ws+unix://` there). The window holds this Mac at
  `http+unix://<the socket file>` (a computer held from before at
  loopback with the password, or at 0.64's `~/.visor/server.sock`, is
  moved there); the menu, Settings, the
  welcome, the token alerts, updates (`/api/restart {path}`) and the
  rollback note (`updateNotice`, reported to Applications once) use
  `/api/settings`, `/api/sessions`, `/api/session-table`,
  `/api/admin-token…`, `/api/keys/rotate`, `/api/push/…`, `/api/restart`
  and `/api/quit`. Nothing in the app touches a server object: the server
  in the app's process is made and started by LocalServer and asked like
  any other. The Mac's server serves its socket file from its start
  (password or none, `sshEnabled` or not: `VisorServer.appKey`), and
  Visor.app shows its app key there (`X-Visor-App-Key`, kept in the
  data-protection keychain under Visor.app's own access group,
  `<team>.com.LoganShire.Visor`, which its Developer ID profile grants:
  another process of the user's is told there's none, with no prompt to
  allow. A build without the group, signed ad hoc, keeps it with the
  server's items in the login keychain, and the log says so; a signed
  build moves it over the first time it's read, MacSecrets): the app
  is let in with `sshEnabled` off, and the menu's Reset Admin Token… and
  Emergency Key Rotation… are taken from it alone, as they were only the
  menu's in the app's process. One key for every process of the app's
  (AppKeyKeeper, 0.66): the server takes the one kept at its start,
  whichever process runs it, and makes one only when none is; the app
  reads the kept one for each call; a call that doesn't show the server's
  key has the server ask the keychain again (a key kept since is taken,
  none kept has its own kept again), and the app's call is made once more
  when its key changed meanwhile. Before 0.66 the agent's key was deleted
  as it was kept (a delete from the login keychain reaches the
  data-protection keychain too: ProtectedSecrets deletes the old copy
  first now), so with the server as the agent the app showed none. Quit Visor: in the app's process,
  `/api/quit` (the agents ended, then the app, AppLifecycle; a quit from
  outside waits for it the same way); with the agent, the app alone. The
  agent's menu also has Restart Server, Stop Server (`/api/quit`, which
  launchd leaves stopped) and, while it doesn't answer, Start Server
  (`launchctl kickstart`). Notifications are the client's, as for any
  other computer: the app's connection to its own server registers its
  push token there and notifies itself when the server sends none. Agents
  started by the agent are launchd's grandchildren, not the app's: macOS's
  privacy grants (Files and Folders) follow the app's signature, to be
  checked on a signed build.

**Agents apart from the server.** Unless turned off — Visor Server's
"Run agents apart from the server" (`ServerSettings.detachAgents`, on by
default), or `VISOR_DETACH_AGENT_HOST=0` in a server's environment, which
overrides the setting — every chat agent runs under a host of its own,
`visor-agent-host`. An agent that is to be detached and cannot be (no host
program, one that does not run) is not started some other way: it fails,
saying how to turn detaching off, and the menu says so too. Windows has no
host, so its agents are the server's own children unless the variable
says 1. The host is libraries/visor_agent_host (in the bundle at
`Contents/Helpers`, signed with the app by tools/sign_mac_app.sh). The
server starts the host as its child — so the agent keeps the app's
privacy grants (a launchd job would not: a job reading ~/Downloads is
refused) — and the host calls `setsid`, so it outlives the server. The
agent's adapter drives a `HostedChild` as it would a `PipedChild`: lines
in, lines out, an exit. `relaunch` lets the hosts go (`leaveAgents`) and
writes each socket and the next line not yet heard into sessions.json
(`StoredSession.host`); the next launch picks each up (`pickUp`, while the
session is held) and is sent what it missed, Codex's turn in flight
carried by the adapter (`HostableProcess.carried`). A host that is gone
leaves the session as a restart used to: resumed with the nudge. A quit
ends the agents. A host with no server for a day ends its agent; one
whose agent has gone waits ten minutes for a server to tell. The host's
memory guard holds the agent's tree to `AgentChildren.memoryLimit` (half
the computer's memory) by stopping its largest process, with a notice;
the session's `memory` is shown in the inspector. A session's agent
has a state (`SessionInfo.agentState`, kept with the session), and its
menu and inspector offer what that state allows (AgentStateButtons):
running, "Stop Agent" and "Restart Agent"; stopped, "Start Agent";
starting or stopping, nothing. Restart (`restartAgent`) ends just that
session's agent and starts a new one at once (`AgentProcess.start`), a
turn it was working on carried on by a nudge. Stop (`stopAgent`) ends
it and keeps it ended, through a launch too, what is sent meanwhile
waiting in the queue (`SessionRecord.waits`) until Start (`startAgent`).
Hosts log to `hosts/hosts.log` in the data folder.

**Sessions on runners across a restart** (visor#424). A session moved to
a runner (`moveToRunner`) is `driven`, and keeps its move on its record in
sessions.json (`SessionRecord.move`: the agent id its job is for, its
conversation and folder here, its folder and conversation on the runner
once its wrapper and Started say). Only `moveBack` makes it this
computer's again, with a dated notice and a push; a wrapper of protocol 2
hands it back first, its conversation returned and re-keyed here
(VisorServer+HandBack, docs/runners.md). A relaunch (`leaveAgents`)
and a quit (`endAll`) leave its runner's agent working: the driver's
stream closes and the wrapper redials. The new process opens 7434 before
it reads its sessions (`VisorDriver.Listening.listen`), and serves calls
once `serve` has handed the queue the moves kept on the sessions
(`takeUpDrivenSessions` → `JobQueue.adopt`). jobs.json may lack them.
A claim taken up at a start holds for three minutes
(`JobQueue.redialGrace`). If its runner hasn't renewed it by then, its
job goes out again and the session says so. Neither that, nor a release
whose words say the dispatcher or driver was out of reach or something
restarted (`JobQueue.mayBeStartFailure`), counts toward the three
returns. Start Agent and Restart Agent on a driven session queue a resume
job for a runner of its kind (`resumeDriven`), under a new agent id, with
the runner's conversation in the folder it worked in there. Settings that
restart Claude do the same. Stop Agent lets its job go (`stopDriven`), so
its runner ends it. None of them starts an agent here.

**Moving a session.** "Migrate…" in a session's menu lists the other
computers connected now; the user picks one, and nothing else. The client
(`SessionMigration`) asks the session's server for an offer
(VisorServer+Migration.swift: the agent's own files for the conversation,
found by `SessionCatalog+Migration` — its transcript, the folder beside
it, Claude's memory — and nothing else: no project, working tree or
clone), the other for a plan (VisorServer+MigrationArrival.swift: a new,
empty folder of that server's choosing, `<sessions>/<Agent>/<id>`, under
`VISOR_SESSIONS_DIR` or its data folder's `Sessions`), and carries the
files across a piece at a time. The receiver makes every destination of
the agent, the conversation's id and that folder, holds the offer to the
containment rules and the size caps (VisorServer+MigrationContainment,
+MigrationSize; docs/protocol.md), and in a container whose computer
shares folders with it (`HostDetails.sharedFolders`) refuses a folder in
none. The new session resumes the same conversation and clones what it
needs; the old one is left for the user to remove. Backups carry the
same files.

**The server on every system.** `libraries/visor_server` has no
conditional compilation and imports nothing of a system: what differs —
listening on loopback, signals to process ids, where secrets are kept,
outgoing HTTPS, signing pushes, reading a picture's header, word of a file
being written, where the agents' tools are, the host's name and data
directory, relaunching, the path in — is a protocol (`LoopbackListening`,
`ProcessSignals`, `SecretStore`, `HTTPFetching`, `PushSigning`,
`ImageMeasuring`, `FileWatching`, `ToolLocating`, `HostDetails`,
`ServerLifecycle`, `ServerExposure`), gathered in a `ServerPlatform` the
binary sets as `ServerPlatform.current` before anything else. Those the
code below the server shares (`libraries/visor_system`: the tools,
processes, host, pictures, file watching, agents' hosts and the log) are
its `SystemPlatform`, which setting `ServerPlatform.current` installs as
`SystemPlatform.current`; that library, and `libraries/visor_agent` (the
agents' processes, harnesses and transcripts) between it and the server, hold to the same rule. HTTP and the WebSocket
(RFC 6455, with its own SHA-1) are read and written by the server over
the plain bytes a `ByteStream` carries, so every system speaks them the
same way. The platforms:

- the Mac's (`ServerPlatform.apple()`, libraries/visor_server_apple): the
  Network framework's TCP, the keychain, CryptoKit and URLSession for
  APNs, ImageIO, a vnode dispatch source, the app's relauncher, os_log;
- POSIX (libraries/visor_server_posix, shared by the Mac and Linux):
  signals, loopback sockets and daemons, with the calls whose shape
  differs between macOS and Linux in C (`c/visor_posix.c`), so the Swift
  is the same on both;
- Linux's, Windows's and a headless Mac's (libraries/visor_server_linux,
  …_windows, …_mac), each a `CommandLineSystem` for `visor-server`
  (libraries/visor_server_cli: run, start, stop, status, password, code):
  POSIX and FoundationNetworking;
  Winsock and the Win32 process calls. Neither sends pushes yet
  (`pushSigning` is nil), pictures are measured from their headers
  (`HeaderImageMeasuring`), files are polled (`PollingFileWatching`), the
  password is in a file only its user reads (`FileSecrets`), and Windows
  keeps the message cache in memory (no SQLite there). The Mac's
  (`//applications/visor_server_mac:visor-server`, no menu bar app) is
  POSIX with the Mac's own fetching, push signing, picture measuring and
  file watching, its data in `$VISOR_DATA_DIR` or
  `~/Library/Application Support/visor-server`; it does not take the SSH
  socket file from a server already answering there.

The command-line server keeps its sessions, secrets, pid file
(`<pid> <port>`) and background log in `$XDG_DATA_HOME/visor`
(`~/.local/share/visor`) or `%LOCALAPPDATA%\Visor`; `stop` asks the server
through `POST /api/quit`, so it ends its agents first on every system.
`visor-server network on` opens it to the network, `visor-server ssh
on|off` serves the socket file for SSH clients (Linux; not Windows),
`visor-server address <url>` names a front of your own, `visor-server
standalone on` keeps it to itself (see the protocol's network of
computers), `visor-server front <url>…` gives a server in a container its
front's paths (Visor Runner's on the computer: its loopback, LAN and VPN)
for clients in place of the container's own; `visor-server keep-messages
off` asks clients to keep its sessions' messages in memory only; `run` and
`start` take the same as options (`--password`, `--auth`, `--lan`, `--vpn`,
`--ssh`, `--address`, `--standalone`, `--front`, `--keep-messages`), for a
server set up wholly by its command line; it serves no TLS
(a proxy does). The Windows server
is built and tried in CI (a throwaway session over its WebSocket); it has
not been run against real agents.

**Containers.** Sessions in containers of their own (New Session ›
Runs › In a Container, Move into / out of a Container, the server's
container host and `visor-container-host`, the `containers` command and
settings) were removed in 0.50. A server of 0.50 answers `start` with
`container: true`, and `contain`, with an error (REST: 410), never says
containers are on offer, and passes over the containers' settings in an
older settings file; a session saved while it ran in one (`info.container`)
comes back running on the computer, its container left to whoever made it
(`container delete --force <id>` removes an Apple one). The protocol keeps
`SessionContainer`, `ContainerSize` and the `container`/`containerSize`
fields, so older clients and files still decode. A server that itself runs
in a container (`HostDetails.inContainer`, VISOR_IN_CONTAINER=1, a
co-tenant or Shireworks' primary container) is another thing, and stays:
its sessions say `inContainer`.

**Machines.** Sessions lease machines (macOS,
Linux and Windows VMs, iOS simulators, Android emulators) through the MCP
servers their Visor server passes on to them (docs/protocol.md, Proxied MCP
servers; a runner's agent gets none of these, and has Shireworks' MCP from
its container instead, docs/runners.md): a Shireworks server's own MCP port, set as an endpoint with a key of the
server's (`<session>@<application>` is each lease's holder), whose tools
the agent calls as `<endpoint>__lease` and so on (Shireworks' `/shireworks`
MCP path; its first path, still the sessions' until they move, prefixes
each tool with the old name). Visor itself knows
nothing of Shireworks (0.44 dropped `visor machine` and Shireworks' Swift
client).

**MCP servers' keys, pushes and fronts.** A server that shouldn't hold the
MCP servers' keys or the APNs key (Linux, a container) passes its MCP
servers and pushes on through its proxy (`VISOR_PROXY`, `VISOR_MCP`), which
adds them. The old Visor Runner that did this (`visor-runner-agent`) moved
to MultiPass, which is now retired; Shireworks' agent-proxy fronts
container agents.

## 4. The working loop

- Every target compiles in the Swift 6 language mode with warnings as
  errors (`STRICT_SWIFT`, tools/swift): a warning fails the build, here and
  in CI. A closure handed to a dispatch source or another callback-on-its-
  own-queue API from inside a `@MainActor` type is main-actor isolated
  unless it is written in a `nonisolated` function, and is checked when it
  runs: it compiles, and traps on the first callback
  (`_dispatch_assert_queue_fail`). The staging server and the probes are
  how that is found before a deploy.
- Build: `bazel build //applications/visor_mac //applications/visor_disk_utility`
  (fastbuild). `bazel-bin` points at the LAST configuration built — always
  locate outputs with `bazel cquery [-c opt] --output=files <target>`.
- Build on Linux (a container, say): the same targets, with no Xcode. The
  Apple apps build with rules_applecross (MODULE.bazel, `apple_on_linux` in
  .bazelrc) from Xcode 27.2's SDK archive and its ported tools, both pinned
  by SHA-256 (the tools in third_party/applecross/ported_tools.sha256).
  `.bazelrc.user` turns it on, `build:linux --config=apple_on_linux`, and
  says where they are, on Linux alone (`common:linux`, so that the same
  .bazelrc.user serves a Mac's own builds):
  `common:linux --distdir=<folder>` for each folder holding
  `apple-sdks-27.2.tar.gz` or the tools' archives (named by their hashes),
  or `common:linux --downloader_config=.bazel_downloader.user` (ignored by
  git, like .bazelrc.user) with the lines `rewrite
  apple-sdks\.invalid/.* http://<Shireworks host>:7490/files/sha256/<the SDK's sha256>`
  and `rewrite ported-tools\.invalid/sha256/(.*)
  http://<Shireworks host>:7490/files/sha256/$1`, for a Shireworks server that serves
  them (a container's `.netrc`, from `<data>/containers/home/`, has the
  token). Without it (CI's Linux
  runners) Linux builds what runs on Linux. The iPhone app, the Mac apps,
  the Linux client (`//applications/visor_client_linux`), the Linux
  server (`//applications/visor_server_linux:visor-server`; the static
  release build is SwiftPM's, tools/linux_programs.sh), the web site and the Android APK
  build there as on a Mac. The iPhone app for Apple silicon's simulator
  says so, `--ios_multi_cpus=sim_arm64` (Linux's own default, x86_64, an
  Apple-silicon simulator refuses), and a device build says arm64: the
  flag accumulates, so `apple_on_linux` names neither.
- Test, on Linux: `bazel test //tests:linux` — the server's, the
  driver's, the message cache's, the transcript parser's and the Runner
  agent's, `swift_test` targets in Swift Testing. The server's suites are
  each one of `ServerTests`, which is `.serialized`: they set the server's
  process-wide state. On a Mac: the client's, the UI's and SSH's bundles
  (`macos_unit_test`), and the server's Apple system's own tests
  (`//tests/visor_server_tests:visor_server_tests`, apple/; tagged manual,
  by hand). Server tests set `VisorServer.storeRoot` and `ServerCache.shared` to
  scratch; a `VisorServer()` built over the real archive KILLS every agent
  it lists as an orphan (it has: "claude exited 143").
  `RealFileIndexTests` indexes a real file when `--test_env=VISOR_REAL_FILE=…`.
  CI's `linux` job runs `//tests:linux`. Its `test` job builds the Mac's
  .xctest bundles (`macos_unit_test` under tests/, not the manual ones:
  tools/ci/build_mac_tests.sh) and runs each with `xcrun xctest`
  (tools/ci/mac_tests_run.sh) on one of GitHub's own Macs (`xcode-27`),
  which a public repository has for free. A test whose server listens takes
  `ServerTestCase.freePort()`.
- Test the client's screens, on Linux: `bazel test --config=headless
  //tests/feature_map_tests/...` — FEATURE_MAP.md walked through Isomer's
  driver (Swift Testing, `HeadlessApp`) against the client built headless
  (`//applications/visor_headless`) in its fixture: every screen opened
  and recognised, every solid edge taken and its destination checked, at
  a phone's width and an iPad's. About two minutes once built. Its own invocation: `--config=headless` doesn't go with
  `--config=drive` (isomer's AGENTS.md), and without it the targets are
  skipped (incompatible), so `//...` builds pass them by. What can't be
  taken (the agent asking, what the fixture hasn't: an archived session,
  a second computer, a fork) is a disabled test in
  `FeatureMapTests+Gaps.swift` saying why. Every step runs on every
  platform: since isomer#234 a long press and an alert's buttons are
  driven on the iPhone too.
  "Driving the client" below has the rest.
- The same suite headful, against an app built with `--config=drive`:
  `//tests/feature_map_tests:feature_map_headful_{ios,android,macos}_test`
  (manual: each in an invocation of its own, where the simulator, the
  emulator's adb or the Mac's screen is; never on this Mac's own disk or
  screen). Each launch is Isomer's launcher for the platform
  (`@isomer//drive/launchers`), started fresh (`HeadlessApp(…, fresh:
  true)`, the launcher's `ISOMER_FRESH`: the app's data cleared, as a
  headful app keeps the computer a test added), which passes a test's
  settings as `visor.<key>=<value>` (the iPhone's simulator gets them as
  `SIMCTL_CHILD_visor.<key>`, which the iPhone app reads:
  `VisorLaunchSettings`) or, by their own names, as Android's intent
  extras (VisorLaunch.swift leaves out the `visor.` there). On a Shireworks Mac
  slot with a simulator of its own (the slot's user can create and boot
  one), with Visor's
  `--config=drive` build installed:

  ```sh
  bazel test --test_env=ISOMER_SIMULATOR=<udid> //tests/feature_map_tests:feature_map_headful_ios_test
  # an `android` lease, `adb connect`ed (from a slot: <the VM's gateway>:<port>)
  bazel test --test_env=ADB=<adb> --test_env=ANDROID_SERIAL=<serial> \
      //tests/feature_map_tests:feature_map_headful_android_test
  ```

  The regular width's suite is headless alone (a device's width is its
  own). Every element is taken by the identifier the map names, on every
  platform (isomer#228 and #231); FEATURE_MAP.md's "Not wired yet" has
  what still fails on the iPhone.
- Try a server build against real agents without touching the installed
  one: `bazel run //tools/staging_server -- [port] [password]` (7533,
  `staging`) runs a `VisorServer` of its own — its own ports, a scratch
  folder for what it keeps, the password in memory, loopback only, nothing
  put in front of it — and the probes take its port:
  `VISOR_PORT=7533 VISOR_ADMIN_TOKEN=staging node tools/probes/order.mjs`
  (a staging server's password stands for its admin token: both are REST
  credentials; the probes stop, saying so, when `VISOR_ADMIN_TOKEN` is
  unset).
  Ctrl-C ends it, its agents first. Its agents get Visor's MCP server
  from the source tree (`VISOR_MCP_SCRIPT`, which the menu bar app has no
  use for: its copy is in its bundle). Do this before deploying a change to
  the agent processes: a deploy that cannot start agents cannot resume
  the session that deployed it.
- Deploy the server from inside a session: `tools/deploy_server.sh`, with
  the server's admin token in `$VISOR_ADMIN_TOKEN` (Visor Server ›
  Settings › Create Admin Token…, or `visor-server admin-token`; it stops,
  saying so, without one). A session's own `$VISOR_TOKEN` (and the file
  `$VISOR_TOKEN_FILE` names) is that session's token, for its own actions
  over Visor's socket only: the REST side refuses it. The
  current turn is cut; the new server resumes the session with the nudge;
  carry on from there. Verify with `shasum` of the installed binary vs
  the staged one and exactly one `claude -p` per session. Never `pkill`
  the menu bar app (endAll kills every agent).
- Before an update that might lose sessions (a server swapped, a
  container made again), back them up: `curl -X POST
  http://127.0.0.1:7433/api/backups -H "Authorization: Bearer
  ${VISOR_ADMIN_TOKEN:?the admin token}"` (body `{"path": "<a folder of its own>"}` to keep them
  off the disk at risk), or Back Up Sessions in the computer's settings.
  `POST /api/backups/restore {"path": …}` puts back what is gone and
  leaves what is there (docs/protocol.md).
- Upgrade to a released build from inside a session the same way: copy
  `Visor Server.app` out of the disk image to a staging folder and
  `POST /api/restart {path, session}` with it (bearer `$VISOR_ADMIN_TOKEN`).
  Never quit the server from a script an agent runs: quitting ends the
  agent and everything it started, the script included, and the server
  stays quit. A server started from the disk image, or from a quarantined
  copy (App Translocation), cannot install over itself: run it from
  /Applications.
- Deploy clients: `tools/deploy_clients.sh <UDID>`. A running Mac
  client keeps old code until relaunched (the script relaunches it).
- agent_ui changes: commit+push there, put the revision in
  third_party/swift_packages/Package.swift, `swift package resolve` in that
  folder (updates Package.resolved), then build here.
- CI (ci.yml) follows Reviews' policy (AttilaTheFun/reviews
  docs/CI_POLICY.md; Logan, 7 Nov 2026: automated CI only builds), with
  one exception: the client's screens, walked headless through Isomer's
  driver (FEATURE_MAP.md, `//tests/feature_map_tests`), run before and
  after every merge (Logan, 15 Nov 2026: "run all our tests headlessly
  from containers pre and post merge"). It runs on GitHub's own standard
  runners and cache alone, as every public app repository's (Logan, 15
  Nov 2026): no Shireworks runner, lease, cache, files or signing service;
  no paid larger runner. The header of ci.yml has it whole.
  - **Release builds: rules_applecross, not Xcode** (pinned). A
    proposal's and a release's iPhone app and Visor.app (`alpha-apple`,
    `release-apple`) are built with rules_applecross's toolchain, not
    Xcode's own Swift, on GitHub's `xcode-27` Mac (`--config=apple_cross_mac`
    in .bazelrc: swift.org's Swift 6.4.2 and LLVM's ld64.lld compile and
    link; the Mac's Xcode 27.2 gives the SDKs, actool, ibtool and the macro
    plugins; MODULE.bazel gives a Mac no ported tools, which it never runs),
    because of the 18–19 Nov 2026 crash: 0.62.1,
    the first built by Xcode 27.2 (Apple's Swift 6.4.2, on GitHub's
    `xcode-27` Mac), aborted at launch on macOS 27.0 in
    `swift_task_dealloc`, from the short-lived deadline tasks of
    `Command.ask` and `JobQueue.claim` (code 0.61.1 had too, which
    rules_applecross built on Linux and which runs; built from one commit
    on a macOS 27.0.1 VM, Xcode's Visor.app aborts the same way and
    apple_cross_mac's runs). Every proof passed it: they run the client in
    fixture mode, with no server. Don't move them back to Xcode's Swift
    without tools/ci/launch_check passing on macOS 27.0 against such a
    build of the Mac app (`bazel run //tools/ci/launch_check --
    <Visor.app or its .zip>`, on a Mac where Visor was never set up: it
    opens the app for real with a stand-in `claude` and a data folder of
    its own whose server asks nothing, waits for its server's
    `/api/hello` on 7433, holds it a minute, and on a failure prints the
    crash report's exception, `asi` and faulting frames, a running but
    silent app's main thread, and the app's log; an app signed otherwise
    than the one before it on the same Mac waits on a keychain dialog for
    the items that one left). CI runs it on the signed Visor.app before a proposal
    (`alpha-launch`) and before a release's assets are attached
    (`release-launch`).
  - **Where**: Linux and Android on GitHub's x86_64 `ubuntu-24.04`, in
    Swift's image (`swift:6.4.0-noble`, by digest) with what
    tools/ci/job_tools.sh adds (Bazelisk, the Linux client's libraries,
    clang), Bazel's tree on the runner's second disk (Google's Android SDK
    and NDK tools are x86_64, and GitHub's arm runners have no Rosetta);
    the Apple targets on GitHub's `xcode-27` Macs with their own Xcode
    (27.2 where the image has it; a proposal's and a release's apps with
    rules_applecross's Swift, above): Apple's SDKs may not be
    redistributed, so CI never builds them on Linux (`apple_on_linux` is a
    builder's own). tools/ci/container_build.sh builds the platform's apps
    where it runs. Visor's Linux programs (`linux-programs`) build on
    GitHub's arm64 Ubuntu in Visor's agent image (by digest).
  - **Caches**: Bazel's settings are tools/ci/ci_bazel.sh's
    (.github/actions/bazel_cache): GitHub's cache (actions/cache) holds
    the disk and repository caches, outside the checkout (Bazel 9 refuses
    a repository contents cache inside it), with no `bazel-*` links in the
    checkout (`--experimental_convenience_symlinks=ignore`), written by
    main's builds alone (.github/actions/bazel_cache_save). BuildBuddy's
    remote cache (`--config=buildbuddy` in .bazelrc, with no key) is turned
    on with the `BUILDBUDDY_API_KEY` secret in every job, before a merge
    and after it, each reading and writing (Logan, 2026-11-23: outside
    contributors' runs wait for his approval), in a file of the job's own
    in its home (mode 600, the key unset once written). main's and a
    release's runs, which alone sign, use the default instance; a pull
    request's or a branch's its own, `visor-unreviewed`, so nothing
    unreviewed lands by mistake where a signed build reads.
  - **A pull request** runs `container`, main's required check (the rules,
    tools/check_rules.py; the Linux client and blue Visor's APK built; the
    client's screens walked headless, `bazel test --config=headless
    //tests/feature_map_tests/...`; the command-line server built with
    SwiftPM). A diff of documentation alone checks the rules and stops
    there; a newer push cancels the run before. A fork's pull request runs
    it too, with no secret and writing no cache. **No Mac at a pull
    request** (Logan, 13 Nov 2026: Apple runners for release verification
    alone, as they are the bottleneck): `container-apple` on an `xcode-27`
    Mac (the iPhone and Mac apps, the Mac's test bundles, libraries and
    servers) runs by hand on a branch that touches Apple code (`gh workflow
    run ci.yml --ref <branch> -f run=container-apple`), and `verify` builds
    and tests them all.
  - **Each commit on main** runs `populate`: the merged tree built as the
    pull request's Linux jobs build it and its screens walked headless,
    into GitHub's cache and BuildBuddy's; nothing published.
    `populate-apple`, the same for the Apple apps, runs **nightly** (06:00Z,
    on main) and by hand (`-f run=populate`), not at each push: GitHub gives
    a public repository's account 5 macOS runners in all, and a populate on
    every merge held one while a prerelease waited (25 Nov 2026). A
    `container-apple` by hand, and verify's Apple jobs, read the last
    night's cache.
  - **By hand on main** (`gh workflow run ci.yml --ref main -f run=…`, or
    the gh tools' run_dispatch; a container agent's goes through
    agent-proxy's GitHub gate, `run` one of verify, prerelease and release,
    at most 4 an hour (a soft limit, reset when agent-proxy restarts), each
    a line of its log; on its own branch, `run: verify` alone:
    docs/agent-proxy.md, "Release proposals on main"): `verify` runs the
    tests on Linux
    (`//tests:linux`, and the headless screens), those that need a Mac
    (`test`: their bundles built and run on an `xcode-27` Mac), tries the
    command-line server on Linux (tools/ci/linux_tests.sh), builds blue
    Visor's web client (tools/ci/container_blue_web.sh `--build-only`) and
    makes the proof below, and keeps the `proof` artifact; `prerelease`
    builds and signs the commit's Alphas and proposes a draft pre-release;
    `release` verifies first, with the pins (tools/released_pins.sh), then
    does as `prerelease` and proposes a draft release naming its run. A
    proposal's version comes from the repository's releases and tags
    (tools/ci/version_from_tags.sh: one past the line's highest, the same
    again for the same commit). The iPhone app and Visor.app are built on
    an `xcode-27` Mac (`alpha-apple`) with rules_applecross's Swift
    (`--config=apple_cross_mac`, above), optimized, with `--config=alpha`
    and `--config=ci_device` (the iPhone's a device build signed ad hoc
    with a placeholder profile; Visor.app signed ad hoc asking for push,
    `app.ci.entitlements`), with the update settings from the
    `VISOR_UPDATE_APP_GROUP` and `VISOR_UPDATE_APPLICATIONS_BUNDLE_IDS`
    secrets. The `alpha` job, on Ubuntu, builds Visor for Android (arm64,
    `--config=alpha`) with the same version (tools/ci/stamp_android.sh:
    its versionName and versionCode), gives Visor.app Visor's Linux
    programs (tools/ci/mac_app_linux_programs.sh), and signs every build
    in its `Sign` step (tools/ci/sign_builds.sh), the one step the GitHub
    environment `release`'s secrets reach (deployments from main and `v*`
    tags alone; Logan, 15 Nov 2026: a public repository signs with keys in
    its GitHub secrets), with the signers copied byte for byte from
    AttilaTheFun/shireworks: the iPhone app with its development profiles
    and Visor.app with Developer ID, notarized and stapled, on Linux
    (tools/ci/apple_sign.sh and apple_profiles.py: `APPLE_DEVELOPMENT_P12`
    and `_PASSWORD`, `APPLE_DEVELOPER_ID_P12` and `_PASSWORD`,
    `APPLE_NOTARY_KEY`, `_KEY_ID` and `_ISSUER`, `APPLE_PROFILES`), the
    APK with its private release key (never Isomer's public debug key;
    tools/ci/android_sign.sh: `ANDROID_SIGNING_KEYSTORE` and
    `ANDROID_SIGNING_PASSWORD`, the JDK Visor's Bazel pins and
    @android_build_tools' apksigner), its certificate checked against the
    workflow's `VISOR_ANDROID_PIN`. The draft is CI's
    (tools/ci/propose_release.sh, the run's token): no agent makes a draft
    or a tag. Before it, `alpha-launch` opens the signed Visor.app on an
    `xcode-27` Mac (tools/ci/launch_check), and `alpha-propose` proposes
    only once it passed. The signed builds are attached to the draft
    (`Visor-<version>-ios.ipa`, `-macos.zip`, `-android.apk` and
    `builds.json`: tools/ci/attach_release.sh), which is what Applications
    lists (AttilaTheFun/applications' docs/RELEASE_ASSETS.md). Visor Disk
    Utility (applications/visor_disk_utility) is built, signed, notarized
    and released beside Visor.app as its own asset,
    `Visor-Disk-Utility-<version>-macos.zip` (no disk image), with its own
    builds.json line (tools/ci/sign_builds.sh); `alpha-launch` and
    `release-launch` check it's signed and opens
    (tools/ci/mac_app_opens.sh). Nothing else: the separate Mac client
    app retired (Logan, 24 Nov 2026), so no release carries its .zip, icon
    or builds.json line. Every release, drafts included,
    still carries builds.json, with Visor's lines (iOS and macOS, their
    `urlSchemes` naming `visor`) and Visor Disk Utility's, and each app's
    icon, `Visor-<version>-icon.png` and
    `Visor-Disk-Utility-<version>-icon.png`, which Shireworks'
    Applications tab is drawn from. The agent
    image of that version follows when tools/containers/ changed
    (`agent-image`, built with buildah on GitHub's arm64 Ubuntu, arm64
    alone). A branch's builds are experiments only (Logan, 12 Nov 2026):
    nothing publishes them.
  - **Released**: Logan's Release in Reviews publishes a proposed
    release's draft, which makes its tag. Production comes from the tag:
    `release-apple` (an `xcode-27` Mac, `--config=apple_cross_mac`) and
    `release-android` (Ubuntu)
    build the tag's commit with `--config=prod` and the tag's version
    (never the Alphas stamped again). `release` checks the commit is on
    main and that a `verify` run of it passed and kept its proof
    (tools/ci/verified_run.sh), gives Visor.app its Linux programs, and
    signs them in its `Sign` step as the alpha's are, the iPhone app with
    its production (ad hoc) profiles and Visor.app with its disk image
    (`Visor-<version>-macos.dmg`), signed, notarized and stapled. Android
    never holds Apple's back (New Container Helper, 15 Nov 2026):
    `release` signs Apple's whatever `release-android`'s result
    (tools/ci/promote_release.sh), and `release-android-result` turns the
    run red afterwards if the APK wasn't made. Re-run failed jobs then
    signs the APK alone: Apple's, Production already, are left as they
    are, and only the APK and builds.json are attached again.
    `release-launch` opens the signed Visor.app on an `xcode-27` Mac
    (tools/ci/launch_check) and `release-assets` waits for it, then
    attaches the Production builds to the release in
    place of the Alphas, under the same names, with the disk image and
    builds.json, then that proof (tools/ci/release_proof.sh). A
    pre-release is never released: its commit is proposed as a release,
    which verifies it (releases: docs/RELEASE_PROCESS.md in
    AttilaTheFun/reviews).
  - Until the Mac Studio (Logan, 5 Nov 2026: Visor is iOS, macOS and
    Android for now), the web client is only built. The command-line
    server on Windows and blue Visor's iPhone snapshots have no CI job
    (their Shireworks leases went with Shireworks' runners, 17 Nov 2026).
  - Other workflows: `Site` (pages.yml) and `Proof diff backfill` run on
    `ubuntu-24.04`; `Screenshots` (by hand) pictures the site's images on
    an `xcode-27` Mac (tools/ci/hosted_screenshots.sh).
  - main is strict: a pull request merges once its CI is green on main's
    head. One that touches a path CODEOWNERS gives Logan is his to merge;
    any other its agent squash-merges.
- Rules (AGENTS.md): every change through a pull request, no attribution lines; no
  Combine; visor_client/visor_ui stay Foundation-free of networking,
  JSON, UserDefaults (they build for the web — `String.trimmingCharacters`
  is not available there; see `AgentServerConnection.trimmed`); Apple-only
  SwiftUI through Compat.swift.
- NEVER send test turns into your own working sessions. Start a throwaway
  session over the protocol and end it — that is what the probes do.

## 5. Probes and diagnostics (tools/probes, Node 22+)

- `node tools/probes/order.mjs [M1] [M2]` (`AGENT=openrouter` for the
  CLI) — starts a throwaway Claude session, sends two messages, logs socket events (deltas, busy, status
  items) and every long-poll answer (revision, generation, row order), then
  the final record and the ephemeral snapshot, and ends the session. The
  expected tail: `user | assistant ONE | user | assistant TWO`, streams
  empty. Try a trailing space on a message: that used to freeze the record.
- `node tools/probes/lifecycle.mjs` (`AGENT=codex|openrouter`, `MCP=1` to
  also have the agent call Visor's MCP `list_sessions` and, in a second
  session with manual permissions, ask for a tool call's approval and be
  given it) — a throwaway session interrupted mid-turn, carried on, then
  ended; the expected tail is `failures 0`, and a few seconds later the
  server has no agent left as a child (`pgrep -lP <server pid>`).
- The probes talk to the installed server unless `VISOR_PORT` names
  another (a staging server), with `VISOR_ADMIN_TOKEN`: the server's admin
  token (taken by its REST side and its socket's login), or a staging
  server's password. Without it they stop, saying so. From inside a Visor
  session, `VISOR_TOKEN` (and `VISOR_TOKEN_FILE`) is the session's own
  token, for its own actions only: neither the REST side nor the socket's
  login takes it (docs/protocol.md, "Agents' tokens").
- `node tools/probes/ephemeral.mjs <visor session id>` — the snapshot a
  subscribing client gets (busy, activity, status count, held streams).
  Stale streams here = a bug.
- `node tools/probes/earlier.mjs <visor session id>` — pages earlier rows.
- `node tools/probes/server.mjs` — any server, no agent needed: the REST
  side and the socket answer, the heartbeat is answered, and a throwaway
  session is started, followed and ended; `QUIT=1` then stops the server
  through `/api/quit`.
- `node tools/probes/noweb_proxy.mjs` — a reverse proxy on 8099 that
  carries HTTP only (`/visor/api` → 7534, the rest → 7533, every WebSocket
  upgrade refused): a path with no WebSockets in front of a staging
  server. Then the polling fallback against it, over the native services:
  `bazel test //tests/visor_client_tests --test_filter=PollingProbeTests
  --test_env=VISOR_POLL_URL=http://127.0.0.1:8099/visor
  --test_env=VISOR_POLL_PASSWORD=staging --spawn_strategy=local
  --nocache_test_results` (skipped without the URL). It connects by
  polling, starts a throwaway session, watches it work and ends it.
- SSH against a real `sshd`, over the native service (`SSHProbeTests`,
  skipped without the address): a throwaway sshd of your own, so your
  `~/.ssh` is not touched — `ssh-keygen -t ed25519 -N "" -f
  /tmp/sshprobe/hostkey`, an empty `/tmp/sshprobe/authorized_keys` (mode
  600), a config with `Port 2299`, `ListenAddress 127.0.0.1`, that
  `HostKey` and `AuthorizedKeysFile`, `PasswordAuthentication no`,
  `UsePAM no`, `StrictModes no`, `PerSourcePenalties no`, a `PidFile`
  there; `/usr/sbin/sshd -D -e -f /tmp/sshprobe/sshd_config`. Then
  `bazel test //tests/visor_client_tests --test_filter=SSHProbeTests
  --test_env=VISOR_SSH_ADDRESS=$USER@127.0.0.1:2299
  --test_env=VISOR_SSH_AUTHORIZED_KEYS=/tmp/sshprobe/authorized_keys
  --test_env=VISOR_SSH_PASSWORD --nocache_test_results` with the local
  server's password exported (and `VISOR_SSH_TARGET_PORT` if it is not
  on 7433). The device's key is refused before it is in the file and
  taken after; `hello` is answered through the forwarded port; another
  host key is refused; the whole client connects over the provider and
  sees the sessions; then the same through a jump host (the sshd jumped
  through to itself). Kill the sshd by its pid file afterwards.
- `tools/probes/command_line_server.sh [binary]` — `visor-server` on Linux
  as its user would run it: a password, `run` checked with the server
  probe, then `start`, a restart through `/api/restart`, another after
  its program file is replaced (Linux then names the running program
  `<path> (deleted)`; the successor starts from the path; a port the
  server it replaces still holds is tried again for ten seconds), `stop`. CI runs
  it; on the Mac, in a container: a podman machine of your own, an image
  with `swift:6.4-noble` and Node 22, the checkout
  mounted, `swift build --product visor-server` then this.
- REST locally is plain HTTP: `http://127.0.0.1:7433/api/...` with
  `Authorization: Bearer <password>` (`security find-generic-password -s
  com.LoganShire.VisorServer.macOS -a password -w`; Visor.app's service is
  `com.LoganShire.Visor.server`), or the admin token,
  `$VISOR_ADMIN_TOKEN` (never a session's `$VISOR_TOKEN`). Node's http needs an
  explicit Content-Length on POST bodies (the server ignores chunked).
- The indexer logs to the unified log: `log show --predicate 'subsystem ==
  "com.LoganShire.Visor"' --last 10m`. `lsof -p <server pid> | grep jsonl`
  shows which files are being tailed.
- Caches: `sqlite3 "~/Library/Application Support/com.LoganShire.
  VisorServer.macOS/messages.sqlite"` — output is `|`-separated. `pragma user_version`
  is the schema version (`MessageCache.schemaVersion`; bump to rebuild).
- `osascript`/System Events hang from a headless agent; no UI automation
  of the Mac apps. `screencapture -x` works from a session once Visor
  Server has Screen Recording (Privacy & Security), which is how the Mac
  apps are looked at. The iOS simulator probe (`tests/ios_probe`) drives
  the phone client. rules_apple 5's runner makes its own simulator
  (`--ios_simulator_device="iPhone 17" --ios_simulator_version=27.2`;
  `--destination` is NOT accepted). It adds the host by `VISOR_PROBE_HOST`
  and `VISOR_PROBE_PASSWORD`. The `*Look` cases expect
  a session on the host (`VISOR_LOOK_SESSION` names it); the fixture and
  send-frames cases bring or are given their own.

### Snapshot fixture

For screenshot tests, the client can show a canned computer instead of
real ones (`libraries/visor_client/Sources/VisorFixture.swift`). The setting
`fixture` = `snapshot` turns it on; `fixture.screen` opens a screen:
`sessions`, `chat`, `question`, `goal`, `inspector`, `models`, `search`,
`connect` or `new-session` (the New Session sheet over the sessions)
(`earlier` is `goal` with a page of earlier rows that loads as its spinner
row shows). On Apple
these are `visor.fixture` and `visor.fixture.screen` in UserDefaults, so
launch arguments set them: `-visor.fixture snapshot -visor.fixture.screen
chat`. The web and Android set them through their settings services. The
store then holds only "Snapshot Mac", keeps its rows in memory, and saves
nothing over the real computers. The `fixture` provider's
`FixtureAgentServer` answers the sign-in, the channel, subscribe, the
transcript's sync, commands, files and search from fixed data, so
everything above the server runs as usual. The inspector and model sheets open 1.5 s after the chat, once
the thread has settled; take screenshots at least 4 s after launch (8 s
lets every sheet's glass finish easing in). The busy session shows a static glyph instead of
a spinner. Pin the simulator's status bar (`xcrun simctl status_bar booted
override --time 9:41 …`) and the same screen gives the same pixels every
run. The iOS probe's `testFixtureScreens` takes all of them in portrait,
`testFixtureScreensLandscape` in landscape.

### Driving the client

FEATURE_MAP.md is the client's screens and the ways between them, each an
Isomer driver command (isomer's docs/drive.md: `ls`, `tap <target>`,
`type`, `back`, `dismiss`, `wait`; a target is an element's name, its
accessibility identifier or its label). Two builds can be driven:

- **Headless** (`--config=headless`, `--@isomer//headless`): the client
  with nothing drawn, its screen read and used through Isomer's runtime,
  on the building machine (a Linux container: no build on a Mac's own
  disk). `//applications/visor_headless` is `VisorRootView` with settings
  in memory, given at launch in its environment by their own names
  (`fixture=snapshot`, `fixture.screen=chat`, `account=fixture`, as
  Android's launch intent takes them; a native app takes `visor.<key>`
  alone) or as the iPhone's arguments (`-visor.fixture snapshot`); it
  has no network, so it is for the fixture (or the onboarding and Add
  Computer with no computer). Its
  window is 390 by 844 points (a phone) unless `ISO_HEADLESS_WIDTH` and
  `ISO_HEADLESS_HEIGHT` say otherwise (1180 by 820: the iPad's layout).
  The feature map's tests (`//tests/feature_map_tests`, above) drive it.
- **Headful** (`--config=drive`, `--@isomer//drive:headful`): every
  client carries the driver. Android and the web are Isomer's and link it
  with the flag; the iPhone, iPad and Mac apps take `@isomer//:isomer`
  with it alone (`ISOMER_APPLE_DRIVER`, tools/swift/defs.bzl), which brings
  Isomer's accessibility driver. Launched with `ISO_DRIVER=<a hub's ws://
  URL>` (Android: `-e ISO_DRIVER …`; a simulator: `SIMCTL_CHILD_ISO_DRIVER`)
  the app dials out to it; without it, to `iso hub` on its machine. Never
  in a release: such an app obeys whoever its launch names. Every client
  takes the launch settings (`VisorLaunchSettings.keys`: `fixture`,
  `fixture.screen`, `fixture.appearance`, `fixture.orientation`,
  `fixture.go`, `account`, `probe.open`; none secret): the iPhone, Mac,
  Linux and Windows apps from their environment as `visor.<key>` alone
  (`visor.fixture=snapshot`; on a simulator
  `SIMCTL_CHILD_visor.fixture=snapshot`, set with `env`: a shell takes no
  dotted name as an assignment), never a bare `fixture` or `account`,
  which a shell or a container may have for something else, before
  UserDefaults (the `-visor.<key> <value>` launch arguments); Android from
  its launch intent's extras by their own names (`--es fixture snapshot
  --es account fixture`); the headless client from its environment by
  their own names (`fixture=snapshot`).

An agent finding its way around the client, in a leased Linux container
with the repository cloned:

```sh
bazel build --config=headless //applications/visor_headless
bazel build @isomer//xplat/iso          # Isomer's CLI
root="$(bazel info execution_root)"
visor="$root/$(bazel cquery --config=headless --output=files //applications/visor_headless)"
cp "$root/$(bazel cquery --output=files @isomer//xplat/iso)" /tmp/iso
# The client on a Unix socket, in the fixture, on its chat:
env fixture=snapshot fixture.screen=chat \
    ISO_DRIVE_LISTEN=unix:/tmp/visor.sock ISO_HEADLESS_PROTOCOL=serve "$visor" &
iso() { /tmp/iso --url unix:/tmp/visor.sock "$@"; }
iso ls                                  # where am I: its elements (#identifier), then its texts
iso tap session-title                   # → Session details
iso dismiss
iso back                                # → Sessions (a phone's width)
iso tap settings                        # → Settings
iso tap "settings-computer-Snapshot Mac"
```

Or with no socket, a command a line on its standard input
(`{"cmd": "ls"}`, `{"cmd": "tap", "target": "settings"}`). A headful
client, on Android's emulator, say (a `--config=drive` APK, then `iso hub`
and `adb reverse tcp:7710 tcp:7710`), is `iso --app android ls`, and the
same commands. FEATURE_MAP.md's "Driving it" has the launch lines.

### Fixture look check

`tools/probes/look/fixture_look.sh` photographs each fixture screen on a
simulator of its own (erased first, shut down after) and compares it with
its reference in `tests/look/ios`. That covers the bars' soft edge, the
glass composer, wrapped list items, pictures and the sheets. It then records
the `earlier` screen as a page of earlier rows goes in, and fails if the
list does not come to rest on the rows it showed, or shows anywhere else for
more than three frames (`look.swift`). Runs of one build give the same
pixels, so the limit is tight (0.1% of pixels). What differs is drawn red in
the output folder. After a change that is meant to look different, look at
the new screens and take them with `--accept`. It needs no computer and
works with the Mac locked. Shut down any other simulator of yours first.

### Send motion check

`tools/probes/frames/send_motion.sh` records the simulator while the iOS
probe sends a message of several lines into a throwaway session, then
measures how the thread moved frame by frame around the send
(`motion.swift`) and fails if it ever steps down by more than 6 points. A
send done right only moves the thread up, in small steps. Run it after
touching the composer, the transcript's scrolling or how a sent message
reaches the thread; it leaves contact sheets of the frames (`sheet.swift`)
to look at. `SendIsImmediateTests` holds the client's half in CI: the sent
message is in the thread before `sendMessage` returns, and a repeated
message waits for its own row.

Its options give the send other shapes (each in the script's header): a
model and message (`VISOR_FRAMES_MODEL`, `VISOR_FRAMES_TEXT`) and a longer
measure (`VISOR_FRAMES_AFTER`) for turns with tools and long replies;
sending from up the thread (`VISOR_FRAMES_READ`); the moment the app is
back from the background (`VISOR_FRAMES_AWAY`); after the app is ended
and launched again onto the thread it kept (`VISOR_FRAMES_RELAUNCH`); a
long thread, from a conversation file the session resumes
(`VISOR_FRAMES_RESUME`, `VISOR_FRAMES_CWD`). The relaunch onto a long
thread is what found the jump on the first send after a launch (0.26).

The iOS probe's `testLearningOfEarlierRowsMovesNothing` guards that jump
with no computer: the fixture's `learns-earlier` screen opens the chat
with no earlier rows known and, ten seconds on, answers its sync with
word of some, as a server's first answer after a launch can; the test
fails if the last row moves. The proof runs it (`tools/proof.sh`, in the
simulator, through `tools/ios_ui_tests.sh`, which goes by what the tests
say; xcodebuild gathers no simulator diagnostics after them, which took
minutes and read as a timeout). To run it here (or in a VM),
after touching the thread's rows or its scrolling, `tools/ios_ui_tests.sh`
or:
`bazel test //tests/ios_probe:visor_probe --ios_multi_cpus=sim_arm64
--ios_simulator_device="iPhone 17" --ios_simulator_version=27.2
--spawn_strategy=local --test_filter=VisorProbe/testLearningOfEarlierRowsMovesNothing`.

The thread follows its end only while the end is in view (AgentUI 0.29):
rows that come in while it is read further up leave what is read where it
is, and a pill above the composer counts them. The fixture's `arrivals`
screen brings rows in twelve and twenty-six seconds after it opens;
`testRowsArrivingWhileReadingAboveMoveNothing` scrolls up and checks that
nothing moves, the pill's count, its going, and its tap;
`testRowsArrivingAtTheEndAreScrolledTo` stays at the end and checks the
rows are scrolled to. `tools/ios_ui_tests.sh` runs all three (and the proof).

CI makes the proof in its `verify` run, only by hand: on main
(`gh workflow run ci.yml --ref main -f run=verify`), and in every
`release` run, which proposes a release once it passes, never on a push or
a pull request. Its apps are built where their tools run, the iPhone's and
Visor.app on an `xcode-27` Mac and Android's on Ubuntu
(`tools/ci/container_build.sh` with `VISOR_CI_PACKAGE`), and pictured on
GitHub's own runners, which a public repository has for free:

Five jobs side by side: the iPhone and Android, each upright and on its
side, and the Mac. The iPhone's and Android's take their pictures through
Isomer's driver, from apps built with `--config=drive` (the proof's builds
alone, never a release's): `//tests/feature_map_tests:feature_map_proof_ios`
and `…_android` (`proof/FeatureMapProof.swift`), built on the job's runner
by Bazel while its simulator or emulator boots. One launch of the fixture
walks FEATURE_MAP.md to the screens it reaches by a tap (Sessions, Add
Computer, New Session, the chat, its details, the goal's chat), and each
screen whose fixture's data differs (the question, the machines, the
earlier rows) or that
the fixture opens without a tap (the model sheet over the chat's approval,
"/" in the composer, the search's words: a field typed into shows its
caret and keyboard) is a launch of its own. Each is pictured
(`HeadlessApp.picture`, by Isomer's launcher: simctl's masked screenshot,
adb's screencap) once the driver has found the screen's node (its
"you're there when") and two pictures in a row are the same. The screens
and their ids are as before (proof_ios.sh's SCREENS, snapshots.py's for
Android), and each script names its pictures as the proof's parts are
named, so `proof_make.sh` is unchanged. A walk that stops (an element not
found) leaves its screens to launches of their own, and fails the test.

- The iPhone (`tools/ci/proof_ios.sh <apps> <out> portrait|landscape`, on
  an `xcode-27` Mac): the app on an iPhone 17 simulator of iOS 27.2, made
  for the run, its status bar held still, keyboard suggestions off and the
  light look. GitHub rolls a new image out over days, and the older one had
  iOS 27.0 alone, whose pictures differ from 27.2's in most screens: where
  the image hasn't got 27.2, it is downloaded. No XCUITest: its launches
  made the proof take 26 minutes and, on a slow runner, fail. On its side
  the app turns itself (its `fixture.orientation` setting, which its
  delegate answers with landscapeRight alone), and the picture, the
  device's upright frame, is turned to stand.
- The Mac (`tools/ci/proof_mac.sh`, on another `xcode-27` Mac):
  Visor.app, signed ad hoc as its build left it, opened on each of the
  fixture's screens in the light look and pictured cropped to its window.
  Not through the driver yet: Isomer's Mac launcher takes no launch
  arguments (the caret held lit, visor#244) and its screen is the
  runner's 1024 by 768 unless the script makes it 1920 by 1080. So the
  app, built with the driver, is opened with it off (`ISO_DRIVER=none`):
  left on, it dials a hub that isn't there every second, reading the whole
  window through accessibility each time, and the settings screen never
  settled (50% CPU, 0.63's release run). A screen whose log shows the
  driver dialling fails.
- Android (`tools/ci/proof_android.sh <apps> <out> portrait|landscape`, on
  Ubuntu): blue Visor's APK, built for x86_64, on an emulator under the
  runner's KVM, made as Isomer's hermetic one is (API 34, 1080 by 1920 at
  420 dpi), its status bar held still by System UI's demo mode, and on its
  side turned a quarter (auto-rotate off, held so while the test runs).
  Each picture is cut below the status bar. By hand, against a device adb
  already reaches (a Shireworks `android` lease): `PROOF_ANDROID_SERIAL=<serial>
  ADB=<adb> tools/ci/proof_android.sh <apps> <out>`.

The driver's proof takes about as long as the launches it replaced on the
iPhone, and less on Android (15 Nov 2026; the screens alone, the test
built): on a Shireworks Mac slot the iPhone's 13 screens took 130 s
upright and 151 s on its side, against the old script's 136 s and 142 s
on the same slot; on an `android`
lease Android's 11 took 77 s upright and 78 s on its side, where the old
script's fixed eight seconds a screen took 108 s and 139 s on GitHub's
runner. Isomer's picture (a request its launcher polls for, then simctl's
or adb's) and a launch's attaching (about 5 s on the iPhone, 1 s on
Android) cost what the fixed waits did. On its side the iPhone walks
nothing: the app turns itself on an upright simulator, where Isomer's
Apple driver's taps on a list's rows don't take, so each screen is a
launch of its own. The gains are that a screen is pictured once it is
there rather than after a guess (the search's 20 s are gone), that the
walk is the feature map's, and the pictures are the same: upright on the
iPhone, the walked screens differ from the launched ones by a few hundred
pixels at most (the sheet's Cancel or Done, as a tap leaves it), the
others not at all.

The iPhone's UI cases are not in the proof: `tools/ios_ui_tests.sh` runs
them, by hand.

`tools/ci/proof_make.sh` then makes the proof in AttilaTheFun/reviews'
format 2 (docs/PROOF_FORMAT.md there): each screen an item under a stable id
(`ios/phone/chat`, `ios/phone-landscape/chat`, `macos/window/chat`,
`android/phone/chat`, `android/phone-landscape/chat`, …), with its SHA-256 and size, in `proof.zip` with its
`proof.json`, the run's `proof` artifact. Nothing compares it in CI, so
`verify` runs in a container: Reviews compares a release's proof with the
prior release's, item by item (Logan, 8 Nov 2026), and shows what was added,
removed, changed and unchanged. A release's proposal (`run: release`) puts
the proof among the draft's assets, saying its version
(`tools/ci/proof_version.sh`), so the release keeps it however long ago it
was; at publishing, `tools/ci/release_proof.sh` checks it is of the tag's
commit, or attaches the verified run's where the draft has none. A screen
keeps its id from release to release: rename a fixture screen only on
purpose, as Reviews then shows it removed and another added. No release is
made without a proof of its commit, and that proof is the one reviewed. To bisect a regression, prove an earlier commit after the
fact: push a branch at it and run the workflow on that branch. No
pictures are kept in the tree for it (`tests/proof` went in 0.46): a
release is compared with the release before, in Reviews. The lab's phones are for
what needs real hardware (a sensor, or a benchmark on a device).

`tools/proof.sh` still makes the same screens and UI cases on your own
Mac, to look at before pushing, and the Mac's screens with `PROOF_MAC=1`
(the tool draws a window and makes it key, so only in a test VM, never on
a Mac someone uses).

The same cases can run on a phone, for what needs one: a test phone
leased from a device lab (one agent at a time), for example
`device-lab run --device <name> -- tools/ios_device_tests.sh`. The
phone runs `//tests/ios_probe:visor_probe_device`, whose host is the app
signed with the team's wildcard profile (no push, no widget): the test's
runner app is signed with its host's profile, and only the wildcard covers
the runner. rules_apple's runner is patched
(third_party/patches/rules_apple_device_xctrunner.patch) to name that
runner `<app>.xctrunner` on a device, as Xcode does; a device finds no data
container for the simulator's `com.apple.test.` name. The phone must be in
the team's profiles (`tools/mint_profile/mint_profile.sh` with its UDID, for
the app's and the wildcard). Every case starts in portrait (the probe's
`setUp`), whichever way the phone lies; a landscape case turns it itself.

`tools/probes/resync.mjs` (REST only) reports rows from before a send
that the send replaces on the server.

### Opening frames look

`tools/probes/frames/open_frames.sh <session id>` records the simulator
while the iOS probe opens a session for the first time (the simulator
erased first: nothing cached, the rows come from the first sync) and
lays the frames around the tap out as contact sheets. The thread must
appear once, at its end. Rows laid out from the top and scrolled to
their end a frame later showed the thread's top for that frame — the
flicker seen on first opens (7 October); AgentUI's TranscriptView
now keeps such rows invisible until the scroll has landed. A pixel
measure would be fooled by the push animation under way at the same
moment, so this is a look, not a gate.

### Return frames look

`tools/probes/frames/return_frames.sh [calls] [seconds away]` records the
simulator while the app comes back to a thread that moved on without it:
the probe opens a throwaway session, sends a turn of many separate tool
calls, leaves the app at once and comes back once the turn is done, and
the ten seconds after the return are laid out as contact sheets. The
thread must not step through what it caught up on (`SessionTranscript`
tells a catch-up's pages together once the last is in, and at most once a
frame until then). Against this Mac's own server the pages come too fast
to step anyway; a phone away on another network is where it showed.

## 6. Gotchas that cost time

- A Mac app that reaches LAN addresses needs NSLocalNetworkUsageDescription
  and the user's yes (System Settings → Privacy & Security → Local
  Network). Without it macOS refuses its connections with "No route to
  host" (errno 65) and never asks, while Terminal reaches the same address:
  Visor's LAN paths on the Mac failed that way until 0.23.
- The client's connection log is in UserDefaults while it runs
  (`defaults read com.LoganShire.Visor visor.connectionLog`), and a failed
  keychain call is in the system log
  (`log show --predicate 'subsystem == "com.LoganShire.VisorClient"'`).

- A subagent's plain `sleep` is blocked by the harness; use
  `python3 -c "import time; time.sleep(N)"` to make one actually wait.
- The `-p` SDK session has no task-list tool (TodoWrite) in this harness
  version, so a Claude session driven by Visor cannot show the task
  checklist yet; the rendering is there for when it does.
- rspm `use_repo` names keep the package identity's dot.
- A file is followed for as long as its stream is read (`FileTail.batches`,
  `SessionIndexer.events()`): stop reading (cancel the task) and the
  following stops with it.
- `swift package resolve` in third_party/swift_packages must be re-run
  after editing a revision; delete `.build` if it argues.
- Messages typed on a phone end in a space (autocorrect): every word
  comparison with the file is trimmed on both sides.
- Claude Code appends metadata blocks (`last-prompt`, `pr-link`, …) with
  no uuid at the end of the file; they are nodes without parents and are
  ignored by the branch logic.

## 7. Open items

Bugs seen and not yet fixed are in docs/KNOWN_ISSUES.md.

- Slash commands are offered for Claude only (its `system/commands_changed`
  lists them with descriptions); Codex and the openrouter CLI list none.
  `/remote-control` is not one: headless Claude answers that it "isn't
  available in this environment".
- The web client's cache is in memory (an IndexedDB `MessageStorage`
  would persist it).
- Codex plan updates are not mapped to the tasks checklist.
- The openrouter CLI runs its tools without asking (no manual mode); its
  `--permission-mode` is accepted, said to do nothing, and ignored.
- The first "earlier" page after a resume can be short (in-memory rows
  before the window), then 50 a page.
- After an Xcode update, Bazel fails in rules_swift's `system_sdk`
  extension ("xcode-locator failed. version: <the old one>"): its result is
  cached in the output base's own MODULE.bazel.lock. Remove the
  `system_sdk` and `xcode_configure_extension` entries from
  `$(bazel info output_base)/MODULE.bazel.lock` (after `bazel shutdown`).
- A 212 MB session file indexes in ~9 s on first build (off the main
  thread); resumes after that are lookups.

From the code-quality pass of October 2026, found and left:

- The wire reuses three `Envelope` fields for other meanings (`busy` for
  an approval's allow, `folders` for the queue, `exists` for "the server
  has an APNs key"). Giving each its own field is a protocol change every
  client has to follow.
- Marks in the transcript are strings by convention: goal and loop rows
  by id prefix and text (`goal-file-…`, `wake N`), an attachment as prose
  after the words (`Attached image:`), a picture reference as
  `host|path`, a notification's target as `computer/session`.
- `AgentScreen`'s initializer calls `host.transcript(for:)`, which starts
  the session's sync: building the view is what subscribes it.
- `SessionTranscript` tells views of its changes a frame at a time
  (`SessionTranscript.frame`, a second since 0.29: longer than the
  thread's own motions; through one tracked `tick`), and a send
  starts the frame over (`flush`), so the computer's answer to it lands
  after the thread has moved for it, not in the middle. The chat reads its
  session's `SessionInfo` through the transcript (`info`), not the
  connection's whole list, which changes whenever any session on the
  computer does. Both are measured by `send_motion.sh`: an answer landing
  mid-slide shows as a stutter in its steps (−11, −4, −13) rather than a
  step down.
- `VisorServer` and `SessionRecord` are `ObservableObject`s. The server is
  Apple-only and could use Observation; the client cannot until every
  SwiftUI it is built with has it.
- The openrouter CLI, signalled, leaves the command it was running; a
  reply interrupted mid-stream is not kept in its session.
- SSH addresses work on Apple hosts only: the web has no SSH, and
  Android's host does not provide a `VisorSSHService` yet; the
  Linux and Windows clients, when there are some, can give one over
  swift-nio-ssh. The address still needs Visor Server running on the
  computer; a computer with only SSH could be served by starting the
  command-line server there over an exec channel, which is not done.
  The device's key is one per device, kept in the settings' secrets
  (`ssh.key`); there is no way yet to see or forget a computer's kept
  host key but forgetting the computer's record does not clear it
  (`ssh.hostkey.<user@host:port>` in the settings).

## 8. Working conventions

- Changes go through pull requests into `main`; keep them focused, with
  the probes and tests that verify them named in the description.
- The record is the truth; optimistic rows stay last until confirmed.
- Verify fixes with probes on throwaway sessions, and say plainly what was
  found, what changed, and what is not verified.
