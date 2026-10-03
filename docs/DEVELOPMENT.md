# Developing Visor

How Visor is built, how it fits together, and how to work on it: the
setup, the architecture as built, the build/test/deploy loop, the probes,
and the gotchas. Read it whole once; keep it current as things change.

## 1. What this is

Visor is a Mac menu bar app that runs coding agents (Claude Code, Codex,
OpenRouter models) as sessions on the Mac and serves them over Tailscale to
clients on iPhone, iPad, Mac and the web. Clients chat with a session,
watch it work, and can hand it to a real terminal. The agent doing this
work can drive its own development through Visor: you talk to an agent
in the Visor client; the agent edits, builds, tests, and redeploys the
very server it is running under.

The repos (github.com/AttilaTheFun):

| Repo | What |
| --- | --- |
| `visor` | This repo: server, protocol, client, UI, caches, Apple apps. Bazel module `visor`. |
| `agent_ui` | SwiftPM package: AgentUI (the chat: transcript, composer, footer), NavigationUI, InboxUI, MessagesUI. Pinned by revision in third_party/swift_packages/Package.swift. |
| `open_router_cli` | SwiftPM: OpenRouterKit (client, streaming, ORAgent loop, coding tools, sessions, config, Claude's stream-json) and the `openrouter` CLI, which Visor drives. |

Third-party: SwiftTerm 1.10.1 (terminal on Apple), SQLite.swift 0.15.3 (the
caches), rules_swift_package_manager (rspm) brings SwiftPM packages into
Bazel as `@swiftpkg_<identity>` — the identity keeps its dot:
`@swiftpkg_sqlite.swift//:SQLite`, `@swiftpkg_agent_ui//:AgentUI`.

## 2. Setting up a Mac

1. Xcode 27 with the iOS 27 runtime; `xcode-select` to it. Bazelisk
   (`brew install bazelisk`); Bazel version from `.bazelversion`.
2. Clone this repo; Bazel and SwiftPM fetch agent_ui and the third-party
   packages themselves. Clone open_router_cli beside it to build the CLI.
3. Tailscale, logged into your tailnet with HTTPS certificates enabled. The menu bar app puts
   `tailscale serve` in front on launch (443 → ws 7433 at `/`, REST 7434
   at `/api`; both listeners are loopback-only). Clients connect to
   `<machine>.<tailnet>.ts.net`. Serve adds `Tailscale-User-Login` to
   each proxied request; a request from the Mac's own tailnet user is
   let in on that, everyone else (and loopback tools, the probes) uses
   the password. There is no Funnel any more.
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
   KeepAlive — the server's relauncher owns restarts).

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

The **record** is the transcript in memory (`entries`, a window of 600
rows served) plus the ephemeral state. Every change bumps `revision`;
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
The file is a tree (uuid/parentUuid); `ClaudeBranch.current` picks the
branch holding the last line; prompts off it are abandoned forks (the
user gets a notice); a line with no parent that is not the first
(compaction boundary) CONTINUES from the line before it; a line whose
parent was never seen is a missed line, not a fork. The indexer starts the
tail at a line boundary (never the file size mid-write — that orphaned
everything after). User rows the server appends (`user-N-…`) are settled
in place when the file's copy arrives (`user-file-<uuid>`, words compared
trimmed); file rows insert before trailing unsettled user rows.

**Message cache** (`libraries/message_cache`, module `MessageCache`): one
API over a `MessageStorage` — `SQLiteStorage` (SQLite.swift; defines
`MESSAGE_CACHE_SQLITE`, selected on iOS/macOS in the BUILD) or
`MemoryStorage` (web). Tables: sources (path, identity=inode, bytes,
nextSeq), syncs (revision, generation), nodes (the source tree), messages
(seq, id, role, text, source key, JSON of the row), messages_fts (FTS5).
Server cache: `~/Library/Application Support/com.LoganShire.VisorServer.macOS/
messages.sqlite`, keyed by Visor session id; every agent's rows are
written by the indexer from its log. Client cache: `…/com.LoganShire.
VisorClient.macOS/messages.sqlite` (iOS in its container), keyed
`<host id>/<session id>`; a session opens from it synchronously
(`AgentServerConnection.transcript(for:)`, called from `AgentScreen.init`) and
syncs only what moved. Both are disposable: client rebuilds from server,
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
call id). A streamed delta for a message the record already carries is
ignored (both ends); the turn's end sweeps served streams.

**Client** (`libraries/visor_client`): `AgentServerConnection` per server,
over the provider's `AgentServer` (`TailscaleAgentServer`: `hello`, wss +
https bearer, each operation mapped to the wire protocol in
`TailscaleAgentServer+Operations.swift`; a fork's maps the same
operations to its own service), `SessionTranscript`
(entries, streams by message id, `sending` = optimistic rows that stay the
last row until the record carries the same words at a later revision AND
every stream present when sent has landed — `shadowed` hides the matched
record row meanwhile; `turnStatus: [StatusItem]`). Sent text is trimmed.
`catalogs` envelope refreshes the agent list (e.g. after a key is saved).

**Another kind of agent server** (a fork hosting agents on its own
service, behind its own sign-in) adds three things and changes nothing
else: an `AgentServer` conformance, which is the whole of what the
client asks of a server — `authenticate` (throw
`AgentServerError.needsAuthentication` to have the user sign in),
`openChannel` delivering `AgentServerEvent`s (`.welcome` first, then
`.sessions`/`.catalogs`/`.session(envelope)`), and the one-shot
operations (`startSession`, `act(SessionAction)`, `sendMessage`,
`transcript(of:since:generation:)`, folders, files, search; pushes and
linking have defaults); an `AgentServerProvider` that makes it for a
record (`AgentServerProviders.register`, before the store is made); and
an `AgentServerProviderUI` in VisorUI (`AgentServerProviderUIs.register`)
whose `addView` is the sign-in — any view; it calls `add` with the
`AgentServerRecord` once the user is in, `address` and `secret` meaning
whatever the provider wants — and whose `settingsView` is the saved
server's detail. With one provider the add sheet is its sign-in; with
more, a list of providers first. A record's `provider` id picks both.
The session-side values a server hands back (`SessionInfo`,
`TranscriptEntry`, the transcript and ephemeral envelopes) are the
protocol library's, so a fork's server produces those from its own API.

**UI** (`libraries/visor_ui` on AgentUI): `RootView` sidebar (flat session
rows: title / status dot-or-spinner • computer • project / two-line
preview), `AgentScreen` (chat: `AgentView(messages:streams:activity:
status:…)`; watching mode when a terminal holds the session: persisted
rows + "Being driven from another window" bar with Take control /
Return to chat), `SessionInspector`, `ComposeSessionSheet`. In agent_ui,
`TranscriptView` renders the record, then ONE always-present
`EphemeralFooter` cell (id "bottom": streams, queued, sending,
`ActivityList` of `ActivityItem`s with task checklists, error, the 18 pt
gap) — the only scroll target; the first population is not animated; the
scroll after the composer grows waits for layout (`afterLayout`).

**Who gets in (2026-09-24).** `VisorServer.authorized(request)`: the
exposure's `requester(headers:)` (Serve's `tailscale-user-login`) equals
`hostLogin` (from `tailscale status`, read when the front is set up), or the
bearer is the password, or a token `GET /api/hello` issued (kept in
memory, 512 newest). The socket's `login` takes `token` or `password`.
Clients (`AgentServerConnection.open` → `AgentServer.authenticate`) do
`hello` first — 401 → `AgentServerError.needsAuthentication` → state
`.needsAuthentication`, no retry until the record changes — then the
socket with the token. There is no automatic discovery (manual, one-step
adding keeps Visor from depending on Tailscale's device list): the
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
(required), the network (whose the Mac is, the front's state).
`POST /api/restart {path, session}` installs a bundle over itself via
a detached relauncher and resumes named sessions with a nudge
("[Visor] The Visor server restarted while you were working…").

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
- Rules (AGENTS.md): commit straight to main, no attribution lines; no
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
- `node tools/probes/lifecycle.mjs` (`AGENT=codex|openrouter`, `TUI=1` to
  also switch to the terminal and back, `MCP=1` to also have the agent
  call Visor's MCP `list_sessions` and, in a second session with manual
  permissions, ask for a tool call's approval and be given it) — a throwaway session interrupted
  mid-turn, carried on, optionally handed to its terminal and back, then
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
- REST locally is plain HTTP: `http://127.0.0.1:7434/api/...` with
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
  (`--ios_simulator_device="iPhone 17" --ios_simulator_version=27.0`;
  `--destination` is NOT accepted). The simulator shares the host Mac's
  Tailscale identity, so no password is needed. The `*Look` cases expect
  a session on the host (`VISOR_LOOK_SESSION` names it); the fixture and
  send-frames cases bring or are given their own.

### Snapshot fixture

For screenshot tests, the client can show a canned computer instead of
real ones (`libraries/visor_client/Sources/VisorFixture.swift`). The setting
`fixture` = `snapshot` turns it on; `fixture.screen` opens a screen:
`sessions`, `chat`, `goal`, `inspector`, `models`, `search` or `connect`. On Apple
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
run. The iOS probe's `testFixtureScreens` takes all six.

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

## 6. Gotchas that cost time

- A subagent's plain `sleep` is blocked by the harness; use
  `python3 -c "import time; time.sleep(N)"` to make one actually wait.
- The `-p` SDK session has no task-list tool (TodoWrite) in this harness
  version, so a Claude session driven by Visor cannot show the task
  checklist yet; the rendering is there for when it does.
- rspm `use_repo` names keep the package identity's dot.
- `SQLite.Expression` must be qualified (Foundation has `Expression` too).
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
  before the window), then 600 a page.
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
- `SessionTranscript` throttles its own `objectWillChange` (one change
  told per frame of `SessionTranscript.frame`); it is tied to the send
  motion fix and measured by `send_motion.sh`.
- `VisorServer` and `SessionRecord` are `ObservableObject`s. The server is
  Apple-only and could use Observation; the client cannot until Isomer has
  it.
- AgentUI's `TranscriptActions` and `TranscriptImages` are
  `nonisolated(unsafe)` statics, and its views are not marked
  `@MainActor`, until Isomer's SwiftUI isolates views to the main actor.
- The scripts in tools/ repeat how the team id is read, pass a keychain's
  password as an argument to `security`, and filter `xcodebuild`'s output
  through `grep … || true`, which hides why a profile was not made.
- The terminal pane's keyboard inset and input order were changed without
  a device to try them on (#79).
- The openrouter CLI, signalled, leaves the command it was running; a
  reply interrupted mid-stream is not kept in its session.

## 8. Working conventions

- Changes go through pull requests into `main`; keep them focused, with
  the probes and tests that verify them named in the description.
- The record is the truth; optimistic rows stay last until confirmed.
- Verify fixes with probes on throwaway sessions, and say plainly what was
  found, what changed, and what is not verified.
