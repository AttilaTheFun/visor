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
   unzip the bundle from `bazel cquery --output=files`, copy it to
   `/Applications/Visor Menu Bar.app`, open it: Settings opens on its
   own and a password MUST be saved before it serves (a generated one is
   offered). Then the clients: `tools/deploy_clients.sh [iPhone UDID]`.
   Clients add a Mac with its connection code: the menu bar's "Copy
   Connection Code", or the QR code in its Settings scanned with a
   phone's camera (opens `visor://connect?code=…`).
   **Signing.** The bundle ids and the Apple team id are constants at the
   top of applications/visor_ios/BUILD.bazel (and the bundle ids in the
   other two apps' BUILD files): change them to your own. For a phone,
   Xcode must be signed into your Apple ID (Settings → Accounts); then,
   with the phone plugged in, `tools/mint_profile/mint_profile.sh
   <bundle id> <team id> <UDID>` makes the development certificate and
   the "iOS Team Provisioning Profile: <bundle id>" rules_apple looks for
   (`xcrun devicectl list devices` gives the UDID). Free-team profiles
   last 7 days: re-run it when installs start failing. After one install
   over USB the phone is paired, and `devicectl` reaches it over Wi-Fi on
   the same LAN when unplugged.
6. Xcode: `bazel run //:xcodeproj` generates Visor.xcodeproj
   (rules_xcodeproj); it is not committed.
7. Keeping the server up: a LaunchAgent with RunAtLoad that runs
   `open -a "/Applications/Visor Menu Bar.app"` starts it at login (no
   KeepAlive — the server's relauncher owns restarts).

## 3. Architecture, as built

**Server** (`libraries/visor_server`, `applications/visor_menubar`).
`VisorServer` (@MainActor) holds `SessionRecord`s. Each record owns an
`AgentProcess` made by an `AgentBackend` (`AgentBackends.standard`:
`ClaudeBackend` → `ClaudeProcess` (`claude -p --input-format stream-json
--output-format stream-json --include-partial-messages`, one process per
session, `--resume`), `CodexBackend` → `CodexAppServerProcess` (`codex
app-server`, JSON-RPC over stdio, thread/start|resume, turn/start,
turn/interrupt), `OpenRouterBackend` → `ClaudeProcess(tool: "openrouter")`
(the openrouter CLI speaks the same stream-json; its sessions are
`~/.openrouter/sessions/<id>.json`, read by `SessionCatalog` for
resumable/transcript). Its catalog is every tool-calling model in the
CLI's `~/.openrouter/models.json` (priced subtitles, `group` = maker);
`listed` marks the suggestions — `OpenRouterBackend.coding`, a hand-kept copy
of the top ten at openrouter.ai/collections/programming (update it from
the page; the API's `category=programming` order does not match it) — the default (the CLI's config, else gpt-5-nano) is not a suggestion.
The model sheet, for a catalog with unlisted models, shows Current Model
(what the session runs), then Suggested, then an All Models sheet
grouped by maker with search. The server runs `openrouter models
--refresh` at launch when the file is a day old; Visor never calls
OpenRouter itself). Backends are injectable
(`VisorServer.backends`) so a different adapter layer can be swapped in.

The **record** is the transcript in memory (`entries`, a window of 600
rows served) plus the ephemeral state. Every change bumps `revision`;
each row is stamped with the revision it changed at; a rebuild (a row
gone or moved) bumps `generation`. Clients sync over HTTP long-poll
`GET /api/sessions/<id>/transcript?since=<revision>` (held ≤25 s, released
on change; answered with rows past `since`, or the whole with a new
generation) and get the ephemeral state over the WebSocket (`ephemeral`
snapshot on subscribe: streams, status items, activity, busy, approval,
queue, notice; then `delta`, `status`, `activity`, `busy`, … envelopes).
The archive `~/Library/Application Support/Visor/sessions.json` keeps the
session list and a suffix of rows; the queue is NOT archived (ephemeral).

**Claude's transcript comes from the file.** For tool "claude" the process
emits deltas, status and busy only; rows come from Claude Code's own
`~/.claude/projects/<cwd-slug>/<session>.jsonl`, read by a `SessionIndexer`
(own serial queue) into the **message cache** and handed to the record.
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
Server cache: `~/Library/Application Support/com.LoganShire.Visor.MenuBar/
messages.sqlite`, keyed by Visor session id; Codex/OpenRouter rows are
written from `apply(.entry)`/`appendUser`. Client cache: `…/com.LoganShire.
Visor.macOS/messages.sqlite` (iOS in its container), keyed
`<host id>/<session id>`; a session opens from it synchronously
(`HostConnection.transcript(for:)`, called from `AgentScreen.init`) and
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

**Client** (`libraries/visor_client`): `HostConnection` per computer
(`HostTransport` = TailscaleTransport: wss + https bearer), `SessionTranscript`
(entries, streams by message id, `sending` = optimistic rows that stay the
last row until the record carries the same words at a later revision AND
every stream present when sent has landed — `shadowed` hides the matched
record row meanwhile; `turnStatus: [StatusItem]`). Sent text is trimmed.
`catalogs` envelope refreshes the agent list (e.g. after a key is saved).

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
Clients (`HostConnection.open`) do `hello` first — 401 → state
`.needsPassword`, no retry until a password is saved — then the socket
with the token. There is no automatic discovery (manual, one-step
adding keeps Visor from depending on Tailscale's device list): the
connection code (`ConnectionCode` in visor_protocol, base64url JSON of
name/host/password) is made by `VisorServer.connectionCode` and taken by
`VisorStore.open(_:)`, from the connect form (code, link or bare name)
or the apps' `onOpenURL`. Nothing opens by itself: the sidebar's last
section is always "Add Computer…", which opens the connect sheet
(`store.addingComputer`; the Mac also has it in its Computers menu).

**Claude's models.** `ClaudeBackend.refreshModels` (at launch, then
every 6 h) starts `claude -p` with stream-json, sends the SDK's
`initialize` control request, takes the answer's `models` (value,
resolvedModel, description, supportedEffortLevels; the "default" entry
names the account's default) and ends the process — no turn, no session
file. That list is the Claude catalog (ids like `opus[1m]` go to
`--model`); the hardcoded list is the fallback. `AgentCatalog.model(
matching:)` also matches without the `[1m]` mark, so a reported
`claude-opus-5-5` or an older session's `fable` finds its row.

**Codex's models.** `CodexBackend.refreshModels` (same schedule) runs
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

- Build: `bazel build //applications/visor_menubar //applications/visor_macos`
  (fastbuild). `bazel-bin` points at the LAST configuration built — always
  locate outputs with `bazel cquery [-c opt] --output=files <target>`.
- Test: `bazel test //tests/visor_server_tests //tests/visor_client_tests
  //tests/message_cache_tests //tests/claude_transcript_tests`.
  Server tests set `VisorServer.storeRoot` and `ServerCache.shared` to
  scratch; a `VisorServer()` built over the real archive KILLS every agent
  it lists as an orphan (it has: "claude exited 143").
  `RealFileIndexTests` indexes a real file when `--test_env=VISOR_REAL_FILE=…`.
- Deploy the server from inside a session: `tools/deploy_server.sh`. The
  current turn is cut; the new server resumes the session with the nudge;
  carry on from there. Verify with `shasum` of the installed binary vs
  the staged one and exactly one `claude -p` per session. Never `pkill`
  the menu bar app (endAll kills every agent).
- Deploy clients: `tools/deploy_clients.sh <UDID>`. A running Mac
  client keeps old code until relaunched (the script relaunches it).
- agent_ui changes: commit+push there, put the revision in
  third_party/swift_packages/Package.swift, `swift package resolve` in that
  folder (updates Package.resolved), then build here.
- Rules (AGENTS.md): commit straight to main, no attribution lines; no
  Combine; visor_client/visor_ui stay Foundation-free of networking,
  JSON, UserDefaults (they build for the web — `String.trimmingCharacters`
  is not available there; see `HostConnection.trimmed`); Apple-only
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
- `node tools/probes/ephemeral.mjs <visor session id>` — the snapshot a
  subscribing client gets (busy, activity, status count, held streams).
  Stale streams here = a bug.
- `node tools/probes/earlier.mjs <visor session id>` — pages earlier rows.
- REST locally is plain HTTP: `http://127.0.0.1:7434/api/...` with
  `Authorization: Bearer <password>` (`defaults read
  com.LoganShire.Visor.MenuBar visor.password`). Node's http needs an
  explicit Content-Length on POST bodies (the server ignores chunked).
- The indexer logs to the unified log: `log show --predicate 'subsystem ==
  "com.LoganShire.Visor"' --last 10m`. `lsof -p <server pid> | grep jsonl`
  shows which files are being tailed.
- Caches: `sqlite3 "~/Library/Application Support/com.LoganShire.Visor.
  MenuBar/messages.sqlite"` — output is `|`-separated. `pragma user_version`
  is the schema version (`MessageCache.schemaVersion`; bump to rebuild).
- `osascript`/System Events hang from a headless agent; no UI automation.
  Screenshots of the apps are not available this way. The iOS simulator
  probe (`tests/ios_probe`) exists for UI checks. rules_apple 5's runner
  makes its own simulator (`--ios_simulator_device="iPhone 17"
  --ios_simulator_version=27.0`; `--destination` is NOT accepted).
  `--test_filter=VisorProbe/testClaudeSession` is the connect-and-chat
  run; an empty `VISOR_PROBE_PASSWORD` works on the host Mac because the
  simulator shares its Tailscale identity. The other cases (`*Look`)
  expect particular sessions on the host and fail elsewhere.

## 6. Gotchas that cost time

- A subagent's plain `sleep` is blocked by the harness; use
  `python3 -c "import time; time.sleep(N)"` to make one actually wait.
- The `-p` SDK session has no task-list tool (TodoWrite) in this harness
  version, so a Claude session driven by Visor cannot show the task
  checklist yet; the rendering is there for when it does.
- rspm `use_repo` names keep the package identity's dot.
- `SQLite.Expression` must be qualified (Foundation has `Expression` too).
- An indexer/watcher not retained is gone (weak self in the callback).
- `swift package resolve` in third_party/swift_packages must be re-run
  after editing a revision; delete `.build` if it argues.
- Messages typed on a phone end in a space (autocorrect): every word
  comparison with the file is trimmed on both sides.
- Claude Code appends metadata blocks (`last-prompt`, `pr-link`, …) with
  no uuid at the end of the file; they are nodes without parents and are
  ignored by the branch logic.

## 7. Open items

Bugs seen and not yet fixed are in docs/KNOWN_ISSUES.md.

- Search has no client UI (`/api/search` works).
- Slash commands pass through to the agent but the composer offers no
  picker. Claude's `system/init` lists the commands it takes
  (`slash_commands`) and `system/commands_changed` sends them with
  descriptions; typing `/` could offer them. `/remote-control` is not one:
  headless Claude answers that it "isn't available in this environment".
- The web client's cache is in memory (an IndexedDB `MessageStorage`
  would persist it).
- Codex plan updates are not mapped to the tasks checklist.
- The openrouter CLI runs its tools without asking (no manual mode); its
  `--permission-mode` is accepted and ignored.
- A model fallback (Fable → Opus under rate limits) is recorded as
  `reportedModel` but not surfaced in the UI.
- Every Claude turn bumps the generation once (the user row's id swap
  reads as a rebuild), so one full sync per turn instead of a delta.
- The first "earlier" page after a resume can be short (in-memory rows
  before the window), then 600 a page.
- A 212 MB session file indexes in ~9 s on first build (off the main
  thread); resumes after that are lookups.

## 8. Working conventions

- Changes go through pull requests into `main`; keep them focused, with
  the probes and tests that verify them named in the description.
- The record is the truth; optimistic rows stay last until confirmed.
- Verify fixes with probes on throwaway sessions, and say plainly what was
  found, what changed, and what is not verified.
