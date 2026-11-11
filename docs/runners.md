# Agents, runners and a server that relays (design, Visor 0.50+)

Logan, 11 Nov 2026 (via Manager), in his words:

> the visor server can just be a dumb http server embedded in the mac app
> which is a menu bar app plus client and has three types of clients:
> wrapped agents dialing in through multipass either natively or from a
> container; client apps like the mac's own client or a phone client; agent
> runners asking should start a new agent from a queue.

> agents are just agents that have advertised themselves to the visor server
> and the visor server is caching their state and relaying clients to them.

His motivation is **agent jobs** in Shireworks. An agent job is a container CI
job that runs one agent session: for example, implementing a GitHub issue,
opening a pull request and merging it. The job is archived automatically when
the task reaches a terminal state. While it runs it shows in Visor, to be
watched and steered, and it can be unarchived afterwards. Neither the server
nor a client asks for such a session. The job creates it.

This document is the outline Logan asked for before building. It changes
docs/server-proxy.md (#329) in one place: the Visor server no longer runs or
owns agents. MultiPass, the egress proxy, DNS and sign-in all stay as #329 has
them. Containers dial out only, through MultiPass, at
`SHIREWORKS_HOST_ADDRESS` (Shireworks, 11 Nov). Nothing reaches into a
container.

## Logan's answers (11 Nov, later)

Where this section and the rest of the document differ, this section wins.
The sections below have been brought into line with it.

- **No server has auth of its own.** The Visor server, the runners and
  Shireworks are plain HTTP servers on native ports, never exposed directly.
  MultiPass is the one authenticated way in, for remote clients over the LAN
  or tailnet and for agents in containers alike. It switches paths, signs
  people and agents in, and decides which credentials to add when it proxies,
  so nothing untrusted is ever handed a secret. It is also the one port a
  container reaches, mapped from the container to the host.
- **A session's logic lives in the wrapped agent.** That also makes a session
  easy to move between runners.
- **Runners own their sessions' data.**
  - Data lives in the Sessions volume, but the runner that created a session
    manages it: Shireworks' agent runner for container sessions, Visor.app's
    native runner for native ones.
  - A runner is fairly dumb. It keeps track of the sessions it has started and
    where their data is.
  - Archiving goes client → server → wrapped agent. The agent archives itself
    and tells its runner, which tells the Visor server.
  - **Migrate** copies a session's data from one runner to another, and the
    receiving runner starts the copy.
  - **Backup…**, from a session's context menu, copies the same data to a
    folder the user picks.
- **Placement:**
  - The MacBook has a Shireworks server with no primary container, and
    Visor.app with its native runner.
  - The mini has a Shireworks server with the primary container.
  - Shireworks' agent runner is enabled only where Shireworks has a primary
    container, so container sessions run in the mini's primary container and
    native ones on the MacBook.
  - In the medium term, native sessions are avoided where possible on
    Logan's own pure MacBook. That's his choice for his machine, not
    Visor's: see "The native runner" below.
- **Progress and done:** a wrapped agent reports to the runner that started it
  over that runner's MCP: agent → wrapper → MultiPass → Shireworks' agent
  runner. It reports progress from time to time, and says complete or blocked.
  A runner may stop an agent that has been stuck for some time and mark it
  blocked.
- **Merging:**
  - A pull request that touches no code-owned file: the agent merges it, as
    agents do today.
  - One that touches a code-owned file: the agent marks itself blocked on code
    review. Logan moves the issue back to a status the runner watches, and the
    runner resumes the agent.
- **Scope:** every repository that isn't archived. For the pilot, agent jobs
  are started by hand only. Picking up and implementing issues automatically,
  with a cap on concurrent agent and CI jobs, comes when the Mac Studio
  arrives.

## The native runner, and Visor on its own

Logan, 11 Nov: "I think 3rd parties may still want to use the native visor
agents either because they don't care as much about the purity of the machine
or their build process is more complex and requires tools that can't work on
linux."

And, in his words: "it's not that it's the default. you can use Visor.app
without Shireworks.app and then you'd be limited to native sessions, or some
custom deployment you create like the enterprise deployment with abox and
sandcastle."

So **no placement is Visor's default.** A session runs wherever the user's
paired runners are:
- **Visor.app alone** brings its native runner, and only native sessions.
- **Shireworks** adds its container and macOS VM runners.
- **A custom deployment** brings runners of its own, for example an
  enterprise one on abox and sandcastle.

Visor.app's native runner is a first-class, supported part of Visor, not a
step on the way to containers. Visor works out of the box with it alone, with
no Shireworks and no MultiPass:
- **Visor.app on its own:** the server, the native runner and the client in
  one app. The Mac's own client reaches the server on loopback. New Session
  starts a native session at once, in a folder the user picks, as today.
- **Permissions:** Claude Code's own approval modes, auto or manual, the
  session's choice (#341). There's no bypass on the computer itself.
- **The network:** with no MultiPass, agents use the Mac's network as they do
  today. With MultiPass installed, the native runner gives its agents
  `HTTP(S)_PROXY` and the CA bundle pointing at it, for the egress log,
  credentials and GitHub's rules.
- **Reaching it from elsewhere** (a phone, another Mac) needs MultiPass, the
  only authenticated way in. Without it, Visor is a single-Mac app.
- Runners in containers (Shireworks') and agent jobs are additions on top,
  for those who have them.

## The runner protocol, for anyone's runner

The runner protocol is a documented, stable interface that anyone's runner
implements, not a private contract between Visor and Shireworks. It covers:
- pairing;
- the runner's hello and its starts;
- the queue;
- the wrapped agent's dial-in and hello;
- the reports;
- session data, archiving, Migrate… and Backup….

- **Versioned.** Both hellos say `protocol: 2`.
  - A server answers with the version it speaks and refuses one it can't.
  - Within a version, what's added is optional, and a reader ignores fields
    it doesn't know and reads unknown values as defaults (visor_protocol's
    types do).
  - A change that isn't compatible is a new version, and the server speaks the
    old one for a release.
- **Written down** in docs/protocol.md (from step 2 on, alongside the types in
  visor_protocol), as the client protocol is.
- **Implementations, as references:**
  - Visor.app's native runner (this repository);
  - Shireworks' container and macOS VM runners (AttilaTheFun/shireworks).

  A custom runner needs only the protocol, MultiPass for the way in, and a
  wrapped agent (`visor-agent-host`, which ships with Visor) for its sessions.

## Three places a session runs

Logan, 11 Nov. The runners Visor and Shireworks bring:
- **Natively on the Mac:** Visor.app's native runner.
- **In the primary Linux container:** Shireworks' container agent runner,
  below.
- **In the primary macOS VM:** a Shireworks macOS VM agent runner, for work
  that needs macOS and Xcode. Xcode comes from the VM's image.
  - It's the container runner's twin, on the same contract: pairing, hello
    as `kind: macos-vm` with labels `macos`, `xcode`, `shireworks`, starts,
    the reports MCP, archive, Migrate… and Backup….
  - It's enabled where Shireworks has its primary macOS VM. Its sessions run
    as a slot user of that VM, their data on Sessions shared into the VM by
    name.
  - The VM's only way out is a macOS `multipass-client` over a vsock relay. Its
    network card stays, host-only, for Shireworks' SSH and VNC (server-proxy.md,
    "In a macOS VM"), if Shireworks' spike holds. If not, the fallback is NAT to the host only,
    with the system's and HTTP(S) proxy settings.
  - It comes after the container runner.

## The parts

| Part | Where | What it does |
|---|---|---|
| **Server** | Visor.app (menu bar app and client), the nested `visor-server`; on Linux, alone | The session registry and its cached state; relays clients to agents; the start queue; the runners it knows. Plain HTTP on a native port with no auth of its own, reached only through MultiPass. Owns no process and no session's data. |
| **Wrapped agent** | `visor-agent-host`, wrapping `claude` or `codex`, wherever it runs | One session's brain: runs the agent, reads its output into Visor's transcript, asks for approvals, keeps going if the server goes away. Dials the server and advertises itself. |
| **Runner** | Visor.app's own (native, on the Mac); Shireworks' container agent runner (in its primary Linux container); Shireworks' macOS VM agent runner (in its primary macOS VM, with Xcode) | Takes starts from the server's queue and launches wrapped agents. Owns its sessions' data and knows where each is. Serves an MCP its agents report to. Plain HTTP, no auth of its own. |
| **Client** | Visor on the Mac, iPhone, Android, the web; Shireworks' Visor tab | Shows every session, wherever it runs, and the runners. Steers a session through the server. |
| **MultiPass** | Each Mac | The only authenticated way in, for clients, agents and containers: path switching, sign-in, and the credentials it adds when it proxies. One port a container reaches, mapped to the host. |

### What moves where

The code that is today one server's, `SessionRecord`, the harnesses
(`ClaudeProcess`, `CodexAppServerProcess`, OpenRouter), transcripts,
approvals, subagents and model lists, moves into the **wrapped agent**. It
becomes a library, `visor_agent`, that `visor-agent-host` runs for one session.

The server keeps:
- what clients read: sessions, their latest rows, their state;
- the relay of what clients say;
- the queue, runners and pairing;
- push notifications, and messages between sessions (the relay and mail, now
  within one server).

The agent-host processes of today, which outlive a server restart, become the
whole of an agent. That is what makes a server restart, a container or a CI
job all the same thing.

## The wire

Every connection is a WebSocket (an HTTP/1.1 upgrade) to the server's one port,
through MultiPass. The server checks nothing itself. MultiPass signs the
caller in (a client by its account, an agent or a runner by the token
MultiPass gave it) and passes on who it is in `X-Visor-Caller`
(`client:<user>`, `agent:<session>`, `runner:<runner id>`). Tokens are
MultiPass's alone: the server and the runners hold none.
The envelopes are today's (`Envelope`, docs/protocol.md) wherever their meaning
is the same.

### A wrapped agent (`/api/v2/agents`)

1. **Hello.** `{type: "agent", session, token, agent, cwd, title, runner,
   links, place}`.
   - `session`: the id its creator gave it.
   - `runner`: the runner that started it, or none for a job.
   - `links`: the issue or pull request.
   - `place`: `native` or `container`, with the runner's name.
2. **State, agent to server.** What the server sends clients today, with the
   agent as its source:
   - `session` (its `SessionInfo`);
   - transcript deltas (`TranscriptDelta`: rows, revision);
   - `ephemeral` (busy, activity, the queue);
   - approvals and questions waiting;
   - its end (`ended`, with a terminal state: below).

   The server caches the latest of each, and the last few hundred rows.
3. **Actions, server to agent.** A client's `send`, `stop`, `approve`,
   `settings`, `restartAgent`, `side`, `fork` and so on, relayed as they
   come, each with the asking client's id. Earlier rows than the server keeps
   are asked of the agent (`earlier`).
4. **Gone and back.** If the connection drops, the agent keeps working and
   buffers what it says. The server marks the session `away`, and shows its
   cached state. The agent redials and resends from the revision the server
   last acknowledged. That is how a server restart, an update and a laptop
   lid are all the same event.

### A runner (`/api/v2/runners`)

1. **Pairing.** Add Runner… on a client shows a pairing code (like a
   connection code). The runner is given the code once and trades it, through
   MultiPass, for a runner token that MultiPass keeps. Visor.app's native
   runner pairs itself with its own server.
2. **Hello.** `{type: "runner", id, name, kind: native | container, agents:
   [claude, codex], capacity, labels, repositories}`.
   - `capacity`: how many agents at once.
   - `labels`: for example `macbook`, `container`, `shireworks`.
3. **Starts, server to runner.** `{type: "start", session, agentToken, agent,
   repository?, branch?, cwd?, prompt?, title, links, resume?}`.
   - `session`: a new id, or an archived session's, to resume.
   - `resume`: the agent's conversation id, and where its files are (below).
   - `agentToken`: a one-time token for that session's agent, which the
     server asks of MultiPass for the start. MultiPass alone checks it, when
     the agent dials.

   The runner launches `visor-agent-host` with the token. It answers
   `started` or `failed` with why. A start carries no sign-in: the agent gets
   its sign-ins (its kind's `agents/<kind>.env` on the server) over its own
   dial connection, once it has said hello with its token. They never pass
   through a runner, and a container never keeps them at rest (Shireworks, 11
   Nov).
4. **Capacity and health.** The runner says what it is running, and the server
   shows it in the runner's row.

### A client

As today: the REST and WebSocket of docs/protocol.md, with the server's cached
state for reads and relayed actions for writes. New for clients:
- `runners`: the list, with each runner's settings and Remove;
- `pair`: a pairing code for Add Runner…;
- `start`: now an entry in the queue, naming a runner or labels.

## The queue

A start is an entry, kept by the server in its SQLite store (swift_sql):
- `id`, which becomes the session's id;
- `agent`, `title`, `prompt`;
- `repository` and `branch`, or `cwd` for a native runner;
- `runner`, or `labels` to match one;
- `links`;
- `archiveWhen` (below);
- `createdBy`, and `state` (`waiting`, `starting`, `running`, `failed`).

The server gives each entry to the first connected runner that matches it and
has room, oldest first. A client's New Session is one such entry for the
runner chosen, the Mac's own by default. The entry is done when its agent says
hello. An entry no runner takes waits, and the client shows that it waits and
why.

## Sessions: identity, ending, archiving

- **Identity.** A session is its id, minted by whoever made it: a queue entry,
  or an agent job. It stays the same through reconnects, server restarts, a
  move to another runner, and an archive and unarchive. The agent's own
  conversation id (Claude's or Codex's) is inside it, as `resumeID` is today.
- **Ending.** The agent ends with a state:
  - `stopped` (by a client);
  - `exited`;
  - a job's terminal state: `merged`, `closed` or `blocked`, which the agent or
    its job declares through the wrapper (`visor-agent-host` takes it from the
    agent's own tool call, or the job's script).
- **Archiving.** A session whose entry or job said `archiveWhen: terminal` is
  archived when it reaches a terminal state. Any session can be archived by
  hand.
- **Where its data lives.** On the Sessions volume, managed by the runner that
  started the session: its folder, its conversation, its memory. It's the data
  a Migrate… carries today. The server keeps none of it, only its cached view.
- **Archiving, by hand or at a terminal state.** The client asks the server,
  which relays it to the wrapped agent. The agent archives itself and tells its
  runner, and the runner tells the server. The runner keeps the data.
- **Unarchiving.** A start entry with `resume`, for the runner that holds the
  data. The agent goes on in the same conversation, under the same session id.
- **Moving to another runner (Migrate…).** The holding runner sends the
  session's data to the other runner, which starts the copy. That is today's
  offer and arrival code, runner to runner.
- **Backup….** From a session's context menu: the holding runner's copy of the
  same data, saved to a folder the user picks. A backup can be started again
  on any runner, as today's restore does.

## Shireworks' agent runner and agent jobs

Agreed with Shireworks on 11 Nov, then placed by Logan's answers:

- **The runner** is a part of the Shireworks server, enabled only where
  Shireworks has a primary container, which is the mini. Its sessions run in
  that primary container.
  - It says hello to the Visor server through MultiPass as `kind:
    container`, with its images and agents and how many sessions it can run
    now. Capacity comes from Shireworks' memory budget, like CI's admission,
    and is sent again as it changes.
  - It takes a start only when it has room, and starts the session's wrapped
    agent (`visor-agent-host`) in the primary container. The agent's folder
    is `/Volumes/Sessions/<Claude|Codex>/<session id>` (#340); a fresh clone
    goes in Sources (#345).
  - It keeps the sessions it started and where their data is, and serves the
    MCP its agents report to.
  - Pairing: Shireworks' Server Settings › Pair with Visor…, with the code from
    Add Runner…. MultiPass keeps what that pairing gives; Shireworks keeps it
    in its Keychain only to reach MultiPass.
  - Per-session `agent` leases, a container per job, come with automation
    once the Mac Studio arrives.
- **Reporting: the runner's MCP** (Shireworks' proposal, agreed 11 Nov).
  Agent → wrapper → MultiPass → runner. The session is never an argument:
  MultiPass names the caller (the agent's token maps to its session), so an
  agent reports only on itself.
  - `task()` → `{session, repository, issue, branch, pull_request?, state}`:
    what it's working on, useful after a resume too.
  - `report_progress(summary, step?)`, from time to time. `summary` is a
    sentence or two for Visor's list. `step` is free text (`tests`,
    `review`). The runner keeps the last few.
  - `report_complete(pull_request, summary, merged)`. `merged: true` when it
    merged its own pull request; `false` when the pull request is open and
    nothing is left for the agent.
  - `report_blocked(reason, detail, pull_request?)`, the reason one of:
    - `code_review`: the pull request touches code-owned files;
    - `question`: it needs Logan's answer, and `detail` is the question;
    - `failure`: CI or tooling it can't fix;
    - `stuck`: the runner's own, never the agent's.

    Each blocked report also comments on the issue with the reason, as
    logan-shire-agent[bot] through MultiPass.

  The runner sends every report to the Visor server as it comes
  (`AgentReport`), and the server shows it on the session.
  - **Stuck:** after 45 minutes with no report and no output from the
    wrapper (its keepalive doesn't count), the runner stops the agent and
    reports it `blocked: stuck`. The 45 minutes is a setting in Shireworks'
    Server Settings.
  - **Resuming a blocked agent:** on blocked, the runner adds the label
    `agent: blocked` to the issue. Logan resumes it by removing the label, or
    by answering on the issue: a new comment from him after the block. The
    runner checks each blocked session's issue every few minutes, through
    MultiPass, and resumes the agent with that comment as its prompt, if there
    is one. If Logan uses a Projects board instead, its "Ready" column takes
    the label's place.
  - **On the runner's side:** a complete report with `merged` archives the
    session; a blocked report stops the agent and keeps its data; a resume
    starts the same session again in the primary container with `--resume`.
- **Merging:** an agent merges its own pull request when it touches no
  code-owned file, as agents do today. Otherwise it reports blocked on code
  review. Logan moves the issue back to a status the runner watches, and the
  runner resumes the agent.
- **Triggering:**
  - **During the pilot:** by hand only, from Visor's UI or MCP tool,
    queuing an issue for the runner.
  - **Once the Studio arrives:** a labeled issue's workflow asks Shireworks with
    its job grant (`POST /v1/ci/jobs/<id>/agent-session`), and Shireworks
    queues the start, with a cap on concurrent agent and CI jobs. The agent
    never runs inside an Actions job.
  - **Scope:** every repository that isn't archived.
- **Network:** none. The container's only way out is `multipass-client` over
  its one relayed socket (server-proxy.md, "Containers: no network"). That
  covers DNS, HTTP(S), MCP and the agent's dial-in. Shireworks' cache and API
  are reached the same way. MultiPass logs every host, and filters by the
  repository's allowlist later.
- **No secrets at rest.** The agent's model sign-in comes over its own
  connection. GitHub goes through MultiPass as logan-shire-agent[bot], so no
  GitHub token is in the container.
- **The lifecycle:**
  - Queued, running, a pull request linked, then complete or blocked.
  - On complete, the agent archives itself, as any archive goes: agent →
    runner → server. The server comments on the issue.
  - Blocked stays live, to be resumed.
  - The runner keeps the session's data, and an archived session can be
    unarchived on it.
- **Who builds what:**
  - Shireworks: the runner (its hello and capacity, starting wrapped agents in
    the primary container, keeping its sessions' data, its MCP for reports,
    stopping the stuck) and host-only egress.
  - Visor: the queue, the dial protocol, the wrapper's report tools, the
    server's handling of reports and archiving, and the workflow template for
    later.

## Permissions

A wrapped agent knows its place. In a container (`place: container`), it always
skips permission prompts: Claude's bypassPermissions, Codex's full access. On
the Mac, the session's choice of Claude Code's own auto mode or manual (#341).
The rule moves from the server to the wrapper, keyed on the place.

## What becomes of what is there now

- **Computers.** The client's list of computers goes. Sessions are one list,
  wherever they run, and runners are the second section. Add Computer… becomes
  Add Runner…. A MultiPass account is what a client adds (#329).
- **Several Macs (Logan's placement).** One Visor server, in Visor.app on the
  MacBook, with its native runner. The MacBook's Shireworks has no primary
  container, so it runs no agent runner. The mini's Shireworks has the primary
  container and its agent runner, which pairs with the MacBook's Visor
  server. Each Mac has its own MultiPass. The relay between Visor servers
  (`/relay`, mail between computers) goes: every session is on one server.
  Native sessions are to be avoided in the medium term, so most sessions run
  in the mini's primary container.
- **Migrate…** stays, as a move between runners. The holding runner sends the
  session's data, which today's offer and arrival code already packs, and the
  other runner starts the copy. The session keeps its id. #340's folder per
  session and #345's clone-only sources stay, as what a runner gives each
  start. **Backup…** saves the same data to a folder.
- **The co-tenant's cut-over.** Once the server, the wrapper and Shireworks'
  agent runner are in:
  1. each co-tenant session, made idle and pushed (#345's rule), is migrated
     from the co-tenant's server into the agent runner, keeping its id;
  2. it resumes in the primary container;
  3. the co-tenant's own server stops, and the co-tenant goes.

- **The server's auth, TLS, SSH, fronts** go as in #329's step 6. The server
  binds loopback; MultiPass is the way in.
- **Kept as they are:** pushes (the server sends, MultiPass signs), messages
  between sessions (now within one server), and the MCP and GitHub proxies
  (MultiPass's).

## Pull requests, in order

Each one is its own pull request with its tests. Logan may take any of them.

1. **This design** (docs/runners.md), and #329's "The server's contract" and
   "Steps" pointed here.
2. **The v2 wire types** in visor_protocol: agent hello, runner hello, start,
   queue entry, the relay envelopes. Encode and decode tests.
3. **`visor_agent`, extracted.** The session, harness, transcript and approval
   code moves out of visor_server into a library. The server still uses it in
   process, so behaviour doesn't change. The largest PR: a move.
4. **`visor-agent-host` wraps a whole session and dials** (`/api/v2/agents`).
   The server accepts dialed agents beside its own and shows both. A native
   wrapped agent dials the server on loopback. A container's waits for
   MultiPass's dial-in (step 2e there).
5. **Runners and the queue.** The server's queue (SQLite), `/api/v2/runners`,
   pairing, and Visor.app's native runner. New Session becomes an entry for a
   runner. From here the server starts no agent itself.
6. **The client.** Sessions as one list, the Runners section, Add Runner…,
   runner settings and Remove. Computers go from the UI.
7. **Ending, archiving, Migrate… and Backup….** Terminal states and reports
   (progress, complete, blocked), archiving through agent and runner,
   unarchive as a start with `resume` on the holding runner, Migrate… as a
   copy between runners, and Backup… to a folder.
8. **Shireworks' agent runner.** In Shireworks: the runner in the primary
   container, its MCP for reports, stopping the stuck. In Visor: queuing an
   issue by hand from the UI and the MCP tool. The labeled-issue workflow
   follows once the Studio arrives.
9. **What goes:** the server's own agents, its auth, the relay between
   servers, Add Computer…, servers' connection codes; then the co-tenant,
   migrated into the agent runner, and its end.

MultiPass's steps (#329: 2c egress, 2d the app, 2e the dial-in relay) run beside
these. 4's containers and 8 need 2e.

## Open questions

Logan answered the first round, and Shireworks proposed the runner's MCP.
Left for Logan:
- **Resuming a blocked agent:** the `agent: blocked` label (the default), or a
  Projects board's "Ready" column?
