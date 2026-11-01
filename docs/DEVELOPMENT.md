# Developing Visor

How Visor is built, how it fits together, and how to work on it: the
setup, the architecture as built, the build/test/deploy loop, the probes,
and the gotchas. Read it whole once; keep it current as things change.

## 1. What this is

Visor is a Mac menu bar app that runs coding agents (Claude Code, Codex,
OpenRouter models) as sessions on the Mac and serves them to clients on
iPhone, iPad, Mac and the web, over whatever reaches the Mac. Clients chat
with a session and watch it work. The agent doing this work can drive its
own development through Visor: you talk to an agent in the Visor client;
the agent edits, builds, tests, and redeploys the very server it is
running under.

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
   already signed in, served on `~/.visor/server.sock`), and a reverse
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
   BUILD.bazel: change them to your own. Your Apple team id is not in
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
7. Keeping the server up: a LaunchAgent with RunAtLoad that runs
   `open -a "/Applications/Visor Server.app"` starts it at login (no
   KeepAlive — the server's relauncher owns restarts; the agents are under
   their own hosts and outlive it).

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
snapshot on subscribe: streams, status items, activity, busy, approval,
queue, notice; then `delta`, `status`, `activity`, `busy`, … envelopes).
The archive `~/Library/Application Support/Visor/sessions.json` keeps the
session list and a suffix of rows; the queue is NOT archived (ephemeral).

**Claude's transcript comes from the file.** For tool "claude" the process
emits deltas, status and busy only; rows come from Claude Code's own
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
messages.sqlite`, keyed by Visor session id; every agent's rows are
written by the indexer from its log. Client cache: `…/com.LoganShire.
VisorClient.macOS/messages.sqlite` (iOS in its container), keyed
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
its process starts over) and the sessions list broadcasts it; the
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
rows: title / status dot-or-spinner • computer • project / two-line
preview), `AgentScreen` (chat: `AgentView(messages:streams:activity:
status:…)`), `SessionInspector`, `ComposeSessionSheet`. In agent_ui,
`TranscriptView` renders the record, then ONE always-present
`EphemeralFooter` cell (id "bottom": streams, queued, sending,
`ActivityList` of `ActivityItem`s with task checklists, error, the 18 pt
gap) — the only scroll target; the first population is not animated; the
scroll after the composer grows waits for layout (`afterLayout`).

**Who gets in (2026-10-06).** `VisorServer.authorized(request)`: the
bearer is the password, or a token `GET /api/hello` issued (kept in
memory, 512 newest); no header names a user. The socket's `login` takes
`token` or `password`. One listener (`FrontDoor` tells an upgrade from a
request by its first bytes), on loopback or every interface
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
relauncher (`AppRelauncher`) keeps the running bundle aside (`Previous/` in
the data directory) and watches the new one for two minutes: if it quits,
crashes or never answers on its port, the previous build is put back and
opened, carrying the same sessions, and `relaunch-rollback.txt` says why,
which the server shows in its menu (`updateNotice`) once.

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

**Moving a session.** "Migrate…" in a session's menu lists the other
computers connected now. The client (`SessionMigration`) asks the
session's server for an offer (VisorServer+Migration.swift: the agent's
own files for the conversation, found by `SessionCatalog+Migration`, and
the projects — its folder's repository, and the repositories its
conversation names most, by `ProjectSurvey`), the other for a plan
(VisorServer+MigrationArrival.swift: each project here already, cloned
from its remote when it has nothing the remote does not, copied when it
does or has no remote, or made), and carries the files across a piece at
a time. Paths under one home folder land under the other's. The new
session resumes the same conversation; the old one is left for the user
to remove.

**The server on every system.** `libraries/visor_server` has no
conditional compilation and imports nothing of a system: what differs —
listening on loopback, signals to process ids, where secrets are kept,
outgoing HTTPS, signing pushes, reading a picture's header, word of a file
being written, where the agents' tools are, the host's name and data
directory, relaunching, the path in — is a protocol (`LoopbackListening`,
`ProcessSignals`, `SecretStore`, `HTTPFetching`, `PushSigning`,
`ImageMeasuring`, `FileWatching`, `ToolLocating`, `HostDetails`,
`ServerLifecycle`, `ServerExposure`), gathered in a `ServerPlatform` the
binary sets as `ServerPlatform.current` before anything else. HTTP and the WebSocket
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
for clients in place of the container's own; `run` and `start` take the same as options (`--password`,
`--auth`, `--lan`, `--vpn`, `--ssh`, `--address`, `--standalone`, `--front`,
`--container-host`, `--container-image`), for a
server set up wholly by its command line; it serves no TLS
(a proxy does). The Windows server
is built and tried in CI (a throwaway session over its WebSocket); it has
not been run against real agents.

**Containers.** A session's agent may run in a Linux container on its
Visor server's own computer rather than on it directly, made by the
server's **container host** (docs/container-host.md): the program set
(`visor-server containers host <command…>`, the menu bar app's Containers,
settings' `containerHost`), else `visor-container-host` on the PATH (Visor's
own, applications/visor_container_host, over Apple's `container`, carried
in Visor Server's Contents/Helpers to be linked there); with neither,
sessions run on the computer only and New Session offers no containers
(`containersAvailable`, from the
host's `health`). VisorServer+Containers.swift asks the host to `create`
one from Visor's image (tools/containers/visor-agent, published by CI's
agent-image job as `ghcr.io/attilathefun/visor-agent:<version>` and
`:<MAJOR.MINOR>`; a server asks for its own version's, `visor-server
containers image <ref>` for another) with the size the session asked for
(ContainerSize: 6 cores, 16 GB of memory and 128 GB of disk unless asked
otherwise, fitted to the host's `limits`, else what the computer has; the disk is a volume,
`visor-<session>-build` at /var/cache/bazel, where the image keeps Bazel's
output), with Rosetta for x86_64 programs, labelled with the session and
this server (`visor.session`, `visor.server`). It sees: the session's folder
at the same path (so its files, git and the agent's own log are the
computer's), the agent's log folder for that folder (Claude's
`~/.claude/projects/<folder>`, Codex's `~/.codex/sessions`, openrouter's
`~/.openrouter/sessions`), and Visor's MCP script read-only at `/opt/visor`
(ContainerTools). The agents' sign-ins for containers are the server's own,
never the image's (ContainerSignIns: `<data>/containers/agent.env` with
CLAUDE_CODE_OAUTH_TOKEN; Codex's home for every container,
`<data>/containers/codex`, mounted at `/root/.codex` with the computer's
sessions folder in it, signed in once on its own — `container run -it --rm
--mount type=bind,source=<that folder>,target=/root/.codex
ghcr.io/attilathefun/visor-agent:<version> codex login --device-auth` —
never a copy of the computer's, since Codex rotates its refresh token and
the first copy to refresh signs out the other; openrouter's the same way,
`<data>/containers/openrouter` at `/root/.openrouter`; and
`<data>/containers/home/`, other files put into each container's home with
the host's `put`, dotfiles too); the container makes its own SSH key (the
host's `exec`). A container's builds reach a Bazel cache and a file server
(an OS Server's cache, read-only, and its /files, for the SDK archive and
the ported tools) only through what is in that folder: a `.bazelrc`
(`build --remote_cache=http://<host>:7490 --noremote_upload_local_results`)
and a `.netrc` with each server's read token, put there by whoever runs
the computer (`oss cache use` writes both into a home of its own). Visor
itself knows no cache: until 0.43 it wrote them from the OS Servers it
knew (VisorServer+BuildCache).
No Xcode is mounted: the Apple apps build in a container with
rules_applecross (§4), and the Android app's x86_64 SDK and NDK tools run
under Rosetta. The agent runs under its host like any other (HostedChild),
as the container host's `exec <id> --interactive --workdir=… --env-file=…
-- <agent>`, which becomes the agent, its variables in a file only this
user reads (`hosts/<session>.env`, never on a command line): a restart of
this server leaves it working, and this server picks it up the native way.
A session starts in a container with `container: true` and a folder, and
moves into or out of one with `contain` (its agent made again on the other
side, the container it leaves removed with its disk; not while it works).
Ending the session removes its container. When a turn of an agent in a
container fails on the network (EAI_AGAIN and the like;
VisorServer+ContainerNetwork.swift), the host is asked the container's
`network`; with none, the container is made again with its disk kept, the
agent started again there, and the session says so — not twice in five
minutes. At start the server removes the host's containers of sessions it
no longer has, and a session still in a container OS Server lent (0.43 and
before, `SessionContainer.socket`) runs on the computer from then on. An
agent in a container reaches this server over the network (VISOR_URL:
this computer's LAN address unless `visor-server containers callback
<ws-url>` says otherwise), so containers need “Reachable from the network”.
Bazel in the image keeps its output on the container's disk for builds and
makes no convenience links in the mounted repository (/etc/bazel.bazelrc).

**Machines.** Sessions — in containers or not — lease machines (macOS,
Linux and Windows VMs, iOS simulators, Android emulators) through the MCP
servers their Visor server passes on to them (docs/protocol.md, Proxied MCP
servers): an OS Server's own MCP port, set as an endpoint with a key of the
server's (`<session>@<application>` is each lease's holder), whose tools
the agent calls as `<endpoint>__oss_lease` and so on. Visor itself knows
nothing of OS Server (0.44 dropped `visor machine` and OSSClient).

**Visor Runner's MCP proxy.** A Visor server in a container (or any server
that shouldn't hold the MCP servers' keys) sets its MCP servers to
`visor-runner-agent` on the Mac (applications/visor_runner_agent,
libraries/visor_runner; docs/co-tenancy.md). The proxy keeps the secret
headers, in `runner-secrets.json` in Visor's data folder (this user's
alone). Each server it serves has a token of its own, sent with every call
(`X-Visor-Proxy`). A call to `/mcp/<name>` with a known token goes on to
that MCP server with the secret headers added, and its answer comes back
as it came (JSON or SSE). Set up on a Mac:

```sh
visor-runner-agent endpoint set gh http://127.0.0.1:7470/mcp --header 'CLIENT_ID=$SESSION_ID' --secret API_KEY  # the key on stdin
visor-runner-agent server add co-tenant --host <the Mac's name as the container reaches it>  # prints the server's PUT /api/mcp body
visor-runner-agent status
visor-runner-agent serve   # port 7439, every interface; a LaunchAgent keeps it running
```

The printed body goes to the server's `PUT /api/mcp` with its password.
The token is kept there as a secret header, and no key goes into the
container.

## 4. The working loop

- Every target compiles in the Swift 6 language mode with warnings as
  errors (`STRICT_SWIFT`, tools/swift): a warning fails the build, here and
  in CI. A closure handed to a dispatch source or another callback-on-its-
  own-queue API from inside a `@MainActor` type is main-actor isolated
  unless it is written in a `nonisolated` function, and is checked when it
  runs: it compiles, and traps on the first callback
  (`_dispatch_assert_queue_fail`). The staging server and the probes are
  how that is found before a deploy.
- Build: `bazel build //applications/visor_menubar //applications/visor_macos`
  (fastbuild). `bazel-bin` points at the LAST configuration built — always
  locate outputs with `bazel cquery [-c opt] --output=files <target>`.
- Build on Linux (a container, say): the same targets, with no Xcode. The
  Apple apps build with rules_applecross (MODULE.bazel, `apple_on_linux` in
  .bazelrc) from Xcode 27.0's SDK archive and its ported tools, both pinned
  by SHA-256 (the tools in third_party/applecross/ported_tools.sha256).
  `.bazelrc.user` turns it on, `build:linux --config=apple_on_linux`, and
  says where they are, on Linux alone (`common:linux`: CI's Mac runner
  copies .bazelrc.user for its signing team, and none of these is there):
  `common:linux --distdir=<folder>` for each folder holding
  `apple-sdks-27.0.tar.gz` or the tools' archives (named by their hashes),
  or `common:linux --downloader_config=.bazel_downloader.user` (ignored by
  git, like .bazelrc.user) with the lines `rewrite
  apple-sdks\.invalid/.* http://<oss host>:7490/files/sha256/<the SDK's sha256>`
  and `rewrite ported-tools\.invalid/sha256/(.*)
  http://<oss host>:7490/files/sha256/$1`, for an OS Server that serves
  them (a container's `.netrc`, from `<data>/containers/home/`, has the
  token). Without it (CI's Linux
  runners) Linux builds what runs on Linux. The iPhone app, the Mac apps,
  the Linux client (`//applications/visor_client_linux`; the server is
  `swift build --product visor-server`), the web site and the Android APK
  build there as on a Mac.
- Test: `bazel test //tests/visor_server_tests //tests/visor_client_tests
  //tests/message_cache_tests //tests/claude_transcript_tests`.
  Server tests set `VisorServer.storeRoot` and `ServerCache.shared` to
  scratch; a `VisorServer()` built over the real archive KILLS every agent
  it lists as an orphan (it has: "claude exited 143").
  `RealFileIndexTests` indexes a real file when `--test_env=VISOR_REAL_FILE=…`.
- Try a server build against real agents without touching the installed
  one: `bazel run //tools/staging_server -- [port] [password]` (7533,
  `staging`) runs a `VisorServer` of its own — its own ports, a scratch
  folder for what it keeps, the password in memory, loopback only, nothing
  put in front of it — and the probes take its port:
  `VISOR_PORT=7533 VISOR_TOKEN=staging node tools/probes/order.mjs`.
  Ctrl-C ends it, its agents first. Its agents get Visor's MCP server
  from the source tree (`VISOR_MCP_SCRIPT`, which the menu bar app has no
  use for: its copy is in its bundle). Do this before deploying a change to
  the agent processes: a deploy that cannot start agents cannot resume
  the session that deployed it.
- Deploy the server from inside a session: `tools/deploy_server.sh`. The
  current turn is cut; the new server resumes the session with the nudge;
  carry on from there. Verify with `shasum` of the installed binary vs
  the staged one and exactly one `claude -p` per session. Never `pkill`
  the menu bar app (endAll kills every agent).
- Upgrade to a released build from inside a session the same way: copy
  `Visor Server.app` out of the disk image to a staging folder and
  `POST /api/restart {path, session}` with it (bearer `$VISOR_TOKEN`).
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
- CI (ci.yml), self-hosted: the repository's runners lease a macOS VM,
  a Windows VM or a Linux container from OS Server for each job
  (tools/ci). A pull request gets the fast checks, all at once, in under
  ten minutes each: every app and the Mac's libraries built on Linux
  (`container`, tools/ci/container_build.sh, Bazel's tree in a kept
  volume), the tests with nothing of Apple's in them on Linux (`linux`),
  the command-line server on Windows, the tests that need a Mac in a macOS
  VM (`test`), and blue's web client in headless Chromium in a Linux
  container (`blue-web`). A diff of documentation alone skips them (the
  `changes` job), and a newer push cancels a run that hasn't finished.
  Each commit merged to main (a squash is a commit of its own) gets them
  too, then what a release is made of: its build number (one past the
  version's highest on the release server, `$PIPELINE_CI number`, stamped
  into the Info.plists), the iPhone app and the Mac's disk images built,
  signed and notarized on the release Mac (`build`,
  tools/build_packages.sh; what the runner does with them is
  `$PIPELINE_CI`'s), the agent image and blue's iPhone snapshots. The
  proof (`proof`) runs only by hand (workflow_dispatch, since 2026-11-01,
  for CI's time): an agent runs CI on main to propose a release, compared
  with the previous release. main
  requires every job green (or skipped) on a pull request's head, up to
  date with main; an agent merges its own pull request then. A release is
  of a commit on main: an agent proposes it as a draft GitHub release
  (`agent-token gh claude release create v<version> --draft --target <sha>`),
  the owner reviews it in Reviews (its CI, builds, proof, and the pull
  requests since the last release) and approves it there, which makes the
  tag and promotes that commit's builds in Releases; nothing is built from
  the tag (releases: docs/RELEASE_PROCESS.md).
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
  another (a staging server). From inside a Visor session `VISOR_TOKEN`
  is the agent token, which the REST side takes and the socket's login
  does not: run them against a staging server, or with the password.
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
  `<path> (deleted)`; the successor starts from the path), `stop`. CI runs
  it; on the Mac, in a container: a podman machine of your own, an image
  with `swift:6.4-noble` and Node 22, the checkout
  mounted, `swift build --product visor-server` then this.
- REST locally is plain HTTP: `http://127.0.0.1:7433/api/...` with
  `Authorization: Bearer <password>` (`security find-generic-password -s
  com.LoganShire.VisorServer.macOS -a password -w`), or, inside a Visor
  session, its `$VISOR_TOKEN`. Node's http needs an
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

CI makes the proof: its `proof` job, on the repository's own runner
(`visor-ci`, which a fork's pull request never reaches), runs
`tools/ci/mac_vm_proof.sh`. That leases a macOS VM from OS Server
(`xcode_27_2`), copies the committed tree and Bazel in, and takes the
fixture's screens in each orientation there (the probe's
`testFixtureScreens` and `testFixtureScreensLandscape` through
`tools/ios_ui_tests.sh`, on an iPhone 17 simulator made new, its status bar
held still, keyboard suggestions off), and the UI cases. It runs only by
hand (CI's workflow_dispatch, since 2026-11-01, for CI's time; pull
requests and main's commits run their builds and tests only): an agent
runs it on main to propose a release (`kind` full, the default, or
quick). Each screen is compared with its picture kept at the previous
release (the newest `v*` tag before the commit, else the commit before:
`tests/proof/ios`, `tests/proof/ios-landscape`: red's own, as
`tests/snapshots` holds blue's), so it shows every change since, and the
run's `proof` artifact holds `proof.json`, `screens/`, `diffs/` and the
probe's logs. Reviews reads it from GitHub by commit: no release is made
without a proof of its commit, and that proof is the one reviewed. To
bisect a regression, prove an earlier commit after the fact: push a branch
at it and run the workflow on that branch. A change meant to look different takes its new screens
into `tests/proof` in its pull request (`tools/proof.sh` makes them), or
right after from main's proof artifact. The lab's phones are for what needs
real hardware (a sensor, or a benchmark on a device).

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
  the Mac client's LAN paths failed that way until 0.23.
- The client's connection log is in UserDefaults while it runs
  (`defaults read com.LoganShire.VisorClient.macOS visor.connectionLog`),
  and a failed keychain call is in the system log
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
