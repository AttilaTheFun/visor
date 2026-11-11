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

## The parts

| Part | Where | What it does |
|---|---|---|
| **Server** | Visor.app (menu bar app and client), the nested `visor-server`; on Linux, alone | The session registry and its cached state; relays clients to agents; the start queue; the runners it has paired. Plain HTTP on loopback, behind MultiPass. Owns no process. |
| **Wrapped agent** | `visor-agent-host`, wrapping `claude` or `codex`, wherever it runs | One session's brain: runs the agent, reads its output into Visor's transcript, asks for approvals, keeps going if the server goes away. Dials the server and advertises itself. |
| **Runner** | Visor.app's own (native); Shireworks' container agent runner; any other | Takes starts from the server's queue and launches wrapped agents: as processes on the Mac, or as containers. |
| **Client** | Visor on the Mac, iPhone, Android, the web; Shireworks' Visor tab | Shows every session, wherever it runs, and the runners. Steers a session through the server. |
| **MultiPass** | The Mac | The only way in, for all four: who is who (tokens, sign-in), and relaying containers' dial-ins. |

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
through MultiPass. MultiPass checks the token and passes on who it is in
`X-Visor-Caller` (`client:<user>`, `agent:<session>`, `runner:<runner id>`).
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
3. **Starts, server to runner.** `{type: "start", session, agent, repository?,
   branch?, cwd?, prompt?, title, links, resume?, signIns}`.
   - `session`: a new id, or an archived session's, to resume.
   - `resume`: the agent's conversation id, and where its files are (below).
   - `signIns`: the agent's sign-ins (its kind's `agents/<kind>.env` on the
     server), sent with each start, never kept by a container.

   The runner launches `visor-agent-host` with a one-time agent token for that
   session. It answers `started` or `failed` with why.
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
- **Where its conversation lives.** For a native runner, on the Mac's disk, as
  today. A container's disk goes when the job ends, so on its end the wrapper
  uploads the conversation's files to the server. They're the same files a
  Migrate… carries today, conversation and memory, and the server keeps them
  with the archived session.
- **Unarchiving.** Unarchive is a start entry with `resume`. Any matching
  runner takes it, gets the files from the server, and the agent goes on in
  the same conversation, under the same session id.

## Agent jobs (with Shireworks)

- **A job.** A Shireworks CI job, for example on an issue being opened, runs
  in a container. Its step is `visor-agent-host job --agent claude
  --repository <owner/name> --issue <url> --prompt-file <file>`, with
  `VISOR_DIAL` and the job's agent token. The wrapper makes a session id, dials
  the server, says hello with the issue in `links` and `archiveWhen:
  terminal`, and runs the agent in the job's checkout.
- **Watching and steering.** The session shows in Visor at once, among all the
  others, marked as a job with its issue. A client can steer it as any other.
- **The end.** The job ends when the session reaches a terminal state. The
  agent declares merged or blocked, or the pull request is merged. Then the
  wrapper uploads the conversation, the session is archived, and the
  container goes.
- **Who mints the job's token.** Shireworks asks the server, through
  MultiPass, for an agent token of a new session id, with its runner token. A
  job is then a runner's start, made by the runner itself rather than from the
  queue.
- **Shireworks' container agent runner.** A runner like any other (`kind:
  container`, labels `container`, `shireworks`). It takes queued starts and
  makes a container of Visor's agent image for each. The container's command
  is `visor-agent-host` with the start, and the container's egress goes through
  MultiPass. Agent jobs are the same containers, started by CI rather than the
  queue.

## Permissions

A wrapped agent knows its place. In a container (`place: container`), it always
skips permission prompts: Claude's bypassPermissions, Codex's full access. On
the Mac, the session's choice of Claude Code's own auto mode or manual (#341).
The rule moves from the server to the wrapper, keyed on the place.

## What becomes of what is there now

- **Computers.** The client's list of computers goes. Sessions are one list,
  wherever they run, and runners are the second section. Add Computer… becomes
  Add Runner…. A MultiPass account is what a client adds (#329).
- **Several Macs.** One Visor server per person, on the Mac that runs
  MultiPass. Another Mac (the mini) runs Visor.app's native runner, paired to
  that server, and its own MultiPass only if it serves clients of its own. The
  relay between servers (`/relay`, mail between computers) goes: every session
  is on one server.
- **Migrate….** It goes. Moving a session to another runner is stop, then
  start it on that runner with `resume`, the server carrying its files. That
  is today's offer and arrival code, reused as the server's upload and the
  runner's download. The session keeps its id. #340's folder per session
  (`/Volumes/Sessions/<Claude|Codex>/<id>`) and #345's clone-only sources stay,
  as what a container runner gives each start.
- **The co-tenant's cut-over.** Once the server, the wrapper and Shireworks'
  container agent runner are in:
  1. each co-tenant session, made idle and pushed (#345's rule), is uploaded
     to the new server by a one-off import (its conversation, memory and
     info), keeping its id;
  2. it's started with `resume` on the container agent runner;
  3. the co-tenant's own server stops, and the co-tenant goes.

  The primary container becomes Shireworks' container agent runner's place,
  or is replaced by it.
- **The server's auth, TLS, SSH, fronts** go as in #329's step 6. The server
  binds loopback; MultiPass is the way in.
- **Kept as they are:** pushes (the server sends, MultiPass signs), messages
  between sessions (now within one server), the MCP and GitHub proxies
  (MultiPass's), and backups (now of the server's store and archived files).

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
7. **Ending and archiving.** Terminal states, `archiveWhen`, the wrapper's
   upload of a conversation at its end, and unarchive as a start with `resume`
   on any runner.
8. **Shireworks:** the container agent runner, then agent jobs, `visor-agent-host
   job`, and the job's token from its runner.
9. **What goes:** the server's own agents, the relay between servers,
   Migrate…, Add Computer…, connection codes of servers; and the co-tenant's
   import, then its end.

MultiPass's steps (#329: 2c egress, 2d the app, 2e the dial-in relay) run beside
these. 4's containers and 8 need 2e.

## Open questions for Logan

- **Where a session's brain lives.** This outline puts it in the wrapped agent:
  the server only caches and relays, as he said. The other way keeps the
  harness in the server and makes the wrapper a pipe for the agent's input and
  output. That makes the server less dumb, and a server restart less
  invisible.
- **Archived conversations on the server.** Is the server's store the place
  for an ended container session's files, or a Shireworks volume (Sessions)
  the runner writes to?
- **One server per person.** Is the mini a runner of the MacBook's server, or
  does it keep a server of its own for its own clients?
- **Who declares a job done.** The agent, through a tool the wrapper gives it,
  or the job, by watching the issue or pull request?
